#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""service/tests/test_precision.py -- the precision contract of this host's SQL-visible
distances (gate 45).

The precision contract (precision plan R2/R3/R5/R7/R8):

  * every SQL-visible distance, norm and dot product accumulates in DOUBLE, in a
    fixed sequential order, with no fused multiply-add and no vectorised
    reduction, and is returned as a double (no rounding to float32 on the way
    out);
  * there is ONE cosine implementation in this repo
    (service/adapter/src/fsql_precision.h), so every SQL-visible cosine agrees
    to the last bit;
  * the canonical vector text round-trips bit-identically for float32;
  * ties break on the row id.

The reference here is the same arithmetic in Python floats (IEEE double, no
fused multiply-add), so the results must be BIT-identical to it.

The driver talks to fractalsqld over the FSQ v2 socket -- the SQL-visible
functions of this host are the daemon's function bodies -- so it needs no
database and no Druid.

Scenarios:
  G1  the cosine distance / similarity, the L2 distance, the squared L2, the
      negative inner product and the norm are bit-identical to the sequential
      double reference, at 16, 128 and 768 dims;
  G2  an adversarial near-tie set: the FULL ranking by the SQL distance
      equals the reference ranking (this is the check that detects a float32
      accumulator);
  G3  cross-function consistency: the cosine distance and the cosine
      similarity agree to the last bit, and the dot product and the negative
      inner product agree;
  G4  the text round trip: vector -> text -> vector is bit-identical;
  G5  degenerate inputs keep their documented conventions (a zero vector, a
      NULL argument, a dimension mismatch).

usage: test_precision.py SOCKET KEYFILE
"""
import math
import random
import struct
import sys

import fsq_client as fc

SOCK = sys.argv[1] if len(sys.argv) > 1 else None
KEYFILE = sys.argv[2] if len(sys.argv) > 2 else None

failures = []


def check(ok, name, detail=""):
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok:
        failures.append(name)


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def bits(x):
    return struct.pack("<d", x)


def vtxt(v):
    """The canonical vector text this host uses: the numbers printed with the
    shortest float32 round-tripping form, comma separated."""
    return ",".join("%.9g" % f32(t) for t in v)


def seq_parts(a, b):
    d = x = y = 0.0
    for p, q in zip(a, b):
        d += p * q
        x += p * p
        y += q * q
    return d, x, y


def ref_cos_dist(a, b):
    d, x, y = seq_parts(a, b)
    return 1.0 if x == 0.0 or y == 0.0 else 1.0 - d / (math.sqrt(x) * math.sqrt(y))


def ref_cos_sim(a, b):
    d, x, y = seq_parts(a, b)
    return 0.0 if x == 0.0 or y == 0.0 else d / (math.sqrt(x) * math.sqrt(y))


def ref_l2(a, b):
    s = 0.0
    for p, q in zip(a, b):
        t = p - q
        s += t * t
    return math.sqrt(s)


def ref_l2_sq(a, b):
    s = 0.0
    for p, q in zip(a, b):
        t = p - q
        s += t * t
    return s


def ref_dot(a, b):
    d = 0.0
    for p, q in zip(a, b):
        d += p * q
    return d


def ref_norm(a):
    s = 0.0
    for p in a:
        s += p * p
    return math.sqrt(s)


def unit(rng, n):
    v = [rng.gauss(0, 1) for _ in range(n)]
    s = math.sqrt(sum(t * t for t in v))
    return [f32(t / s) for t in v]


def main():
    if not SOCK or not KEYFILE:
        print("usage: test_precision.py SOCKET KEYFILE")
        return 2
    key = fc.load_key(KEYFILE)
    c = fc.Client(SOCK, key, timeout=60)

    def call(name, *args):
        st, v = c.call(name, *args)
        if st != fc.OK:
            return None
        return v

    rng = random.Random(20261118)

    # ---- G1: every distance is bit-identical to the sequential double reference
    for dim in (16, 128, 768):
        a = unit(rng, dim)
        b = unit(rng, dim)
        ta, tb = vtxt(a), vtxt(b)
        cases = (
            ("fractal_vector_cosine_distance", ref_cos_dist(a, b)),
            ("fractal_vector_cosine_similarity", ref_cos_sim(a, b)),
            ("fractal_vector_l2_distance", ref_l2(a, b)),
            ("fractal_vector_l2_squared", ref_l2_sq(a, b)),
            ("fractal_vector_negative_inner_product", -ref_dot(a, b)),
        )
        for name, expect in cases:
            got = call(name, ta, tb)
            ok = got is not None and bits(got) == bits(expect)
            check(ok, "G1 %s at %d dims is bit-identical to the sequential double reference" % (name, dim),
                  "got %r want %r" % (got, expect))
        got = call("fractal_vector_norm", ta)
        expect = ref_norm(a)
        check(got is not None and bits(got) == bits(expect),
              "G1 fractal_vector_norm at %d dims is bit-identical to the sequential double reference" % dim,
              "got %r want %r" % (got, expect))

    # ---- G2: an adversarial near-tie set -- the FULL ranking must agree
    dim = 64
    base = unit(rng, dim)
    near = []
    for _ in range(12):
        v = [f32(p + rng.gauss(0, 1e-7)) for p in base]
        near.append(v)
    got_all = []
    ref_all = []
    for v in near:
        g = call("fractal_vector_cosine_distance", vtxt(base), vtxt(v))
        got_all.append(g if g is not None else float("nan"))
        ref_all.append(ref_cos_dist(base, v))
    order_got = sorted(range(len(near)), key=lambda i: (got_all[i], i))
    order_ref = sorted(range(len(near)), key=lambda i: (ref_all[i], i))
    check(order_got == order_ref,
          "G2 the full ranking of an adversarial near-tie set matches the reference ranking",
          "got %s want %s" % (order_got, order_ref))
    check(all(bits(got_all[i]) == bits(ref_all[i]) for i in range(len(near))),
          "G2 every near-tie distance is bit-identical to the reference")

    # ---- G3: cross-function consistency
    a = unit(rng, 128)
    b = unit(rng, 128)
    ta, tb = vtxt(a), vtxt(b)
    d = call("fractal_vector_cosine_distance", ta, tb)
    s = call("fractal_vector_cosine_similarity", ta, tb)
    check(d is not None and s is not None and bits(d) == bits(1.0 - s),
          "G3 the cosine distance and the cosine similarity agree to the last bit",
          "d=%r s=%r" % (d, s))
    dot = call("fractal_vector_negative_inner_product", ta, tb)
    check(dot is not None and bits(dot) == bits(-ref_dot(a, b)),
          "G3 the negative inner product is bit-identical to the negated reference dot")

    # ---- G4: the text round trip
    v = unit(rng, 64)
    norm = call("fractal_vector_normalize", vtxt(v))
    check(norm is not None, "G4 fractal_vector_normalize returns a vector")
    if norm is not None:
        again = call("fractal_vector_normalize", norm)
        check(again is not None and again == norm,
              "G4 the canonical vector text round-trips bit-identically",
              "got %r want %r" % (again, norm))
        # and the round trip preserves the float32 values exactly
        parsed = [f32(float(x)) for x in norm.strip("[]").split(",")]
        want = [f32(p) for p in v]
        same = len(parsed) == len(want) and all(bits(p) == bits(q) for p, q in zip(parsed, want))
        check(same, "G4 the normalised vector holds the same float32 values")

    # ---- G5: the degenerate conventions
    zero = call("fractal_vector_cosine_distance", vtxt([0.0] * 8), vtxt(unit(rng, 8)))
    check(zero is not None and bits(zero) == bits(1.0),
          "G5 a zero vector has cosine distance 1.0", "got %r" % (zero,))
    st, v = c.call("fractal_vector_cosine_distance", None, vtxt(unit(rng, 8)))
    check(st == fc.OK and v is None, "G5 a NULL argument gives NULL", "status %s value %r" % (st, v))
    bad = call("fractal_vector_cosine_distance", vtxt(unit(rng, 8)), vtxt(unit(rng, 9)))
    check(bad is None, "G5 a dimension mismatch is refused", "got %r" % (bad,))

    c.close()
    print("%d checks failed" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
