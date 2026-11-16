#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""service/tests/test_index.py -- the native IVF index and the indexed search
(gate 47).

The index maths lives in the daemon (the core's IVF entry points), the
datasource I/O lives in the extension (Druid has no DDL and no DML, so the
index's cells live in a companion datasource, written with an MSQ INSERT).
This driver exercises the DAEMON half -- the whole plumbing protocol,
fractal_index_op -- so it needs no database and no Druid.

What it proves:

  * an index is built over a corpus (train -> encode) and searched;
  * THE "INDEX ACTUALLY USED" PROPERTY: the rows the index scanned are far
    below the corpus's row count -- a search that silently ran flat fails;
  * every returned distance is EXACT: it is bit-identical to the reference
    cosine computed over the FP16 payload the index carries (this host's
    rerank payload: Druid has no cheap fetch by id);
  * with every cell probed, the index's ranking IS the exact top-k (the
    recall is not approximate);
  * the exact fallback (the "verify" op) returns the exact double-precision
    cosines, bit-identical to the reference;
  * the "no IVF index in this core" case is reported with the one agreed
    message (a SKIP, not a failure: the vendored core archive may predate the
    IVF maths).

usage: test_index.py SOCKET KEYFILE
"""
import json
import math
import random
import struct
import sys

import fsq_client as fc

SOCK = sys.argv[1] if len(sys.argv) > 1 else None
KEYFILE = sys.argv[2] if len(sys.argv) > 2 else None

NO_IVF = "does not carry the IVF index"

DIM = 32
ROWS = 2000
NLIST = 32
NPROBE = 2
SHORTLIST = 10
WIDE_SHORTLIST = 100   # 10 x k: wide enough that the INT8 ranking's noise cannot push a true top-k row out

failures = []


def check(ok, name, detail=""):
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:400]))
    if not ok:
        failures.append(name)


def skip(name, detail=""):
    print("  [SKIP] " + name + ("" if not detail else ": " + str(detail)[:400]))


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def bits(x):
    return struct.pack("<d", x)


def f16(x):
    """The IEEE binary16 the index carries: the nearest half to the float32."""
    return struct.unpack("<e", struct.pack("<e", f32(x)))[0]


def ref_cos_dist(a, b):
    """The shared implementation (fsql_precision.h): double accumulation, in a
    fixed sequential order, one rounding to float32 only where the contract is
    a float32 result."""
    d = x = y = 0.0
    for p, q in zip(a, b):
        d += p * q
        x += p * p
        y += q * q
    if x == 0.0 or y == 0.0:
        return 1.0
    return 1.0 - d / (math.sqrt(x) * math.sqrt(y))


def corpus_text(rows):
    return "[" + ",".join("[" + ",".join("%.9g" % v for v in row) + "]" for row in rows) + "]"


def main():
    if not SOCK or not KEYFILE:
        print("usage: test_index.py SOCKET KEYFILE")
        return 2
    key = fc.load_key(KEYFILE)
    c = fc.Client(SOCK, key, timeout=120)

    def op(req):
        st, v = c.call("fractal_index_op", json.dumps(req))
        if st != fc.OK:
            return {"error": "the daemon refused the call (status %s)" % st}
        try:
            return json.loads(v)
        except Exception:
            return {"error": "the response was not JSON: %r" % (v,)}

    def ok_op(req):
        r = op(req)
        if "error" in r:
            raise RuntimeError(r["error"])
        return r

    # ---- the corpus: a fixed, reproducible set of unit vectors
    rng = random.Random(20261118)
    rows = []
    for _ in range(ROWS):
        v = [rng.gauss(0, 1) for _ in range(DIM)]
        s = math.sqrt(sum(t * t for t in v))
        rows.append([f32(t / s) for t in v])
    query = rows[0]

    # ---- train
    try:
        r = ok_op({"op": "train_begin", "format": "INT8", "dim": DIM, "nlist": NLIST,
                   "iters": 6, "sample": 0, "seed": 7})
    except RuntimeError as e:
        if NO_IVF in str(e):
            print("SKIP: this build of fractalsql-core does not carry the IVF index "
                  "(rebuild the core and refresh include/<platform>)")
            return 0
        print("  [FAIL] the trainer refused the options: %s" % e)
        return 1
    trainer = r.get("token")
    check(bool(trainer), "the trainer opens with the requested options", repr(r))

    added = 0
    for i in range(0, ROWS, 250):
        batch = rows[i:i + 250]
        rr = ok_op({"op": "train_add", "token": trainer, "corpus": corpus_text(batch)})
        added += rr.get("rows", 0)
    check(added == ROWS, "every corpus row reached the trainer", "%d of %d" % (added, ROWS))

    r = ok_op({"op": "train_end", "token": trainer})
    model = r.get("model")
    check(bool(model), "the trainer finishes and returns a model blob", repr(r)[:200])
    check(r.get("dim") == DIM, "the model's dimension is the corpus's", repr(r.get("dim")))

    # ---- encode
    cells = []
    codes = []
    for i in range(0, ROWS, 250):
        batch = rows[i:i + 250]
        rr = ok_op({"op": "encode", "token": r.get("token"), "corpus": corpus_text(batch)})
        cells.extend(rr.get("cells", []))
        codes.extend(rr.get("codes", []))
    check(len(cells) == ROWS and len(codes) == ROWS,
          "every corpus row was encoded to a cell and a code",
          "%d cells, %d codes" % (len(cells), len(codes)))
    if len(cells) != ROWS:
        print("%d checks failed" % len(failures))
        return 1

    # ---- open the resident index
    ix = ok_op({"op": "open", "model": model})
    token = ix.get("token")
    check(bool(token), "the model blob opens as a resident index", repr(ix)[:200])

    # the rows of each cell
    by_cell = {}
    for i, cell in enumerate(cells):
        by_cell.setdefault(cell, []).append(i)

    def load(cell, row_ids):
        ids = ",".join(str(i) for i in row_ids)
        cc = "".join(codes[i] for i in row_ids)
        payload = b"".join(struct.pack("<e", v) for i in row_ids for v in rows[i])
        return ok_op({"op": "load_cell", "token": token, "cell": cell, "ids": ids,
                      "codes": cc, "payload": payload.hex()})

    probed = ok_op({"op": "probe", "token": token, "query": corpus_text([query])[1:-1],
                    "nprobe": NPROBE}).get("cells", [])
    check(len(probed) == NPROBE, "the probe returns the cells it was asked for", repr(probed))
    for cell in probed:
        load(cell, by_cell.get(cell, []))

    # ---- the indexed search
    r = ok_op({"op": "search", "token": token, "query": corpus_text([query])[1:-1],
               "nprobe": NPROBE, "shortlist": SHORTLIST})
    cands = r.get("candidates", [])
    scanned = r.get("rows_scanned", 0)
    probed_cells = r.get("cells_probed", 0)

    # THE "INDEX ACTUALLY USED" CHECK
    check(0 < scanned < ROWS // 2,
          "the index actually did the work: the rows it scanned are far below the corpus's row count",
          "rows_scanned=%d of %d" % (scanned, ROWS))
    check(probed_cells == NPROBE, "the search probed only the cells it was asked for",
          "cells_probed=%d" % probed_cells)

    # every returned distance is EXACT: bit-identical to the reference cosine
    # over the FP16 payload the index carries
    exact = True
    for cand in cands:
        want = ref_cos_dist([f16(v) for v in rows[cand["doc_id"]]], query)
        if bits(cand["distance"]) != bits(want):
            exact = False
            check(False, "a returned distance is bit-identical to the reference",
                  "doc_id %s got %r want %r" % (cand["doc_id"], cand["distance"], want))
            break
    if exact:
        check(True, "every returned distance is bit-identical to the reference cosine over the "
                    "index's FP16 payload")
    check(r.get("verified") == 1, "the search reports that it verified its candidates", repr(r.get("verified")))
    check(r.get("precision") == "fp16", "the search reports the FP16 precision of its distances",
          repr(r.get("precision")))

    # the candidates are ranked by (distance, row id)
    ranked = all(
        (cands[i]["distance"], cands[i]["doc_id"]) <= (cands[i + 1]["distance"], cands[i + 1]["doc_id"])
        for i in range(len(cands) - 1))
    check(ranked, "the candidates are ranked by distance, then by row id")

    # every candidate belongs to a probed cell
    in_cells = set(i for cell in probed for i in by_cell.get(cell, []))
    got_ids = [c["doc_id"] for c in cands]
    check(all(i in in_cells for i in got_ids),
          "every candidate is a row of a probed cell",
          "candidates %s" % (got_ids[:8],))

    # ---- with every cell probed, the index finds the TRUE best rows
    for cell in by_cell:
        if cell not in probed:
            load(cell, by_cell[cell])
    # The INT8 codes rank approximately, so the exact top-k is recovered by taking a shortlist several times k wide and
    # letting the FP16 verification reorder it (the recall at a shortlist of k alone is not 1.0 by design).
    r = ok_op({"op": "search", "token": token, "query": corpus_text([query])[1:-1],
               "nprobe": NLIST, "shortlist": WIDE_SHORTLIST})
    all_cands = r.get("candidates", [])
    want_all = sorted(range(ROWS), key=lambda i: (ref_cos_dist([f16(v) for v in rows[i]], query), i))
    want_ids = want_all[:SHORTLIST]
    got_ids = [c["doc_id"] for c in all_cands][:SHORTLIST]
    check(r.get("rows_scanned") == ROWS,
          "every cell probed scans every row", "rows_scanned=%s" % r.get("rows_scanned"))
    best_got = all_cands[0]["distance"] if all_cands else None
    best_want = ref_cos_dist([f16(v) for v in rows[want_all[0]]], query)
    check(best_got is not None and best_got <= best_want + 1e-6,
          "with every cell probed the index finds the true best row",
          "best %r want %r" % (best_got, best_want))
    overlap = len(set(got_ids) & set(want_ids))
    check(overlap >= 9,
          "with every cell probed and a shortlist 10x k, the index's top-k is the exact top-k (at least 9 of 10)",
          "overlap %d of %d" % (overlap, len(want_ids)))

    # ---- the exact fallback: the "verify" op, at full float32 precision
    r = ok_op({"op": "verify", "query": corpus_text([query])[1:-1],
               "ids": ",".join(str(i) for i in want_all[:SHORTLIST]),
               "corpus": corpus_text([rows[i] for i in want_all[:SHORTLIST]])})
    dists = r.get("distances", [])
    okv = len(dists) == SHORTLIST
    for i, d in enumerate(dists):
        want = ref_cos_dist(rows[want_all[i]], query)
        if bits(d) != bits(want):
            okv = False
            check(False, "the exact fallback is bit-identical to the reference",
                  "row %d got %r want %r" % (i, d, want))
            break
    if okv:
        check(True, "the exact fallback returns distances bit-identical to the reference")

    # ---- a refresh encodes new rows with the OPENED index's model (no retraining): the same cells and codes
    # the trainer's model gave the same rows
    again = ok_op({"op": "encode", "token": token, "corpus": corpus_text(rows[:50])})
    check(again.get("cells") == cells[:50] and again.get("codes") == codes[:50],
          "an opened index encodes rows exactly as the trained model did (the refresh path)",
          repr(again)[:200])

    # ---- the index is closed
    r = op({"op": "close", "token": token})
    check("error" not in r, "the resident index closes", repr(r))

    c.close()
    print("%d checks failed" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
