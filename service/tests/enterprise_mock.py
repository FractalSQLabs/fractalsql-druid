#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Drive the daemon's enterprise seam against the stand-in library (mock_enterprise.c), through answers the real library never gives.

usage: enterprise_mock.py SOCKET KEYFILE MODEFILE VARIANT
  VARIANT  full      the stand-in exports every symbol: the answers are checked
           nopf      the optional portfolio symbols are missing: those calls decline, the ledger calls work
           noreq     a required symbol is missing: the library is refused, every enterprise call errors
The daemon must answer afterwards in every case.
"""
import json
import sys

import fsq_client as fc

sock, keyfile, modefile, variant = sys.argv[1:5]
key = fc.load_key(keyfile)
failures = []

MU = "0.10,0.12,0.08,0.15,0.11,0.09"
COV = ",".join("%.4f" % (0.04 if i == j else 0.005) for i in range(6) for j in range(6))


def mode(**kv):
    with open(modefile, "w") as f:
        for k, v in kv.items():
            f.write("%s=%s\n" % (k, v))


def call(name, *args):
    c = fc.Client(sock, key, timeout=60)
    try:
        return c.call(name, *args)
    except Exception as e:
        return -1, str(e)
    finally:
        try:
            c.close()
        except Exception:
            pass


def expect(label, cond, detail=""):
    if not cond:
        print("FAIL " + label + "  " + str(detail)[:200])
        failures.append(label)


def calls_all():
    """Every call that reaches the library, once; returns {name: (status, value)}."""
    out = {}
    for fn in ("fractal_ledger_flush", "fractal_ledger_load", "fractal_ledger_compact", "fractal_ledger_reset_soft",
               "fractal_ledger_truth_count", "fractal_ledger_shadow_count"):
        out[fn] = call(fn, 1)
    out["audit_unpack"] = call("fractal_audit_unpack", "blob")
    out["audit_unpack_latest"] = call("fractal_audit_unpack", "")
    out["multimodal"] = call("fractal_optimize_portfolio_multimodal", MU, COV, 3, 4, 0.5, 0.9, 2)
    out["multimodal_ex"] = call("fractal_optimize_portfolio_multimodal_ex", MU, COV, 3, 4, 0.5, 0.9, 2, 1, "levy")
    out["multimodal_ex0"] = call("fractal_optimize_portfolio_multimodal_ex", MU, COV, 3, 4, 0.5, 0.9, 2, 0, "gaussian")
    out["pareto"] = call("fractal_optimize_portfolio_multimodal_pareto", MU, COV, 3, 4, 3, 2, 1, "gaussian")
    out["pareto0"] = call("fractal_optimize_portfolio_multimodal_pareto", MU, COV, 3, 4, 3, 2, 0, "levy")
    out["audit_log"] = call("fractal_audit_log", "mock", json.dumps({"i": 1}), 1, "ci")
    out["verify"] = call("fractal_ledger_verify", 1)
    return out


def ok_count(r):
    return sum(1 for v in r.values() if v[0] == 0)


# ---- the library answers normally
mode()
base = calls_all()
if variant == "full":
    expect("a count answers", base["fractal_ledger_truth_count"][0] == 0 and str(base["fractal_ledger_truth_count"][1]) in ("3", "3.0"), base["fractal_ledger_truth_count"])
    expect("the audit blob is decoded", base["audit_unpack"][0] == 0 and "mock" in str(base["audit_unpack"][1]), base["audit_unpack"])
    for k in ("multimodal", "multimodal_ex", "multimodal_ex0"):
        expect(k + " reports its candidates", base[k][0] == 0 and '"n_found":2' in str(base[k][1]), base[k])
    for k in ("pareto", "pareto0"):
        expect(k + " answers", base[k][0] == 0, base[k])
elif variant == "nopf":
    expect("the ledger works without the portfolio symbols", base["fractal_ledger_truth_count"][0] == 0, base["fractal_ledger_truth_count"])
    for k in ("multimodal", "multimodal_ex", "pareto"):
        expect(k + " declines", base[k][0] != 0 or base[k][1] in (None, "", "null"), base[k])
else:
    for k in ("fractal_ledger_flush", "audit_unpack", "fractal_ledger_truth_count"):
        expect(k + " errors with a required symbol missing", base[k][0] != 0, base[k])

# ---- the library fails every call, with several different codes
for rc in (-1, -45, -47, -57, 7, 2147483647, -2147483647):
    mode(ret=rc)
    r = calls_all()
    if variant == "full":
        for k in ("fractal_ledger_flush", "fractal_ledger_truth_count", "multimodal", "multimodal_ex", "pareto"):
            expect("%s reports a library failure (%d)" % (k, rc), r[k][0] != 0, r[k])

# ---- counts, and candidates, out of range
for count in (0, 1, 2 ** 31, 2 ** 40, 2 ** 62):
    mode(count=count)
    r = calls_all()
    if variant == "full":
        expect("a count of %d is reported or refused" % count, r["fractal_ledger_truth_count"][0] in (0, 3), r["fractal_ledger_truth_count"])
for nfound in (0, 1, 4, 5, 999, 2 ** 30, -1, -999):
    mode(nfound=nfound)
    r = calls_all()
    if variant == "full":
        for k in ("multimodal", "multimodal_ex", "pareto", "pareto0"):
            expect("%s with a library count of %d still answers" % (k, nfound), r[k][0] == 0, r[k])
        if nfound > 4:
            expect("a count above the restarts is clamped", '"n_found":4' in str(r["multimodal"][1]), r["multimodal"])
        if nfound < 0:
            expect("a negative count is clamped to zero", '"n_found":0' in str(r["multimodal"][1]), r["multimodal"])
mode(nan=1)
r = calls_all()
mode(nan=1, nfound=4)
r = calls_all()

# ---- the audit decoder: growing, refusing, overclaiming
for unpack in ("grow", "grow", "huge", "overclaim", "fail", "empty", "ok"):
    mode(unpack=unpack)
    r = calls_all()
    if variant == "full":
        want_err = unpack in ("huge", "overclaim", "fail")
        expect("audit_unpack in mode %s" % unpack, (r["audit_unpack"][0] != 0) == want_err or unpack == "empty", r["audit_unpack"])

# ---- a mix of everything at once, then back to normal
mode(ret=-45, nfound=999, unpack="huge", count=2 ** 40)
calls_all()
mode()
final = calls_all()
if variant == "full":
    expect("the library recovers once it answers normally again", final["fractal_ledger_truth_count"][0] == 0, final["fractal_ledger_truth_count"])

st, v = call("fractal_version")
expect("the daemon still answers", st == 0, (st, v))
print("enterprise mock (%s): %d answers ok of %d on the last pass" % (variant, ok_count(final), len(final)))
sys.exit(1 if failures else 0)
