#!/usr/bin/env python3
"""tests/test_run_demo_columns.py — the demo runner's column extraction.

The runner waits for a datasource to become queryable by asking for the
COLUMNS the write produced, rather than for the object: a datasource
can exist and be queryable while the broker's cached schema for it
still lacks the column that was just added. So the extraction has to
name the columns a write PRODUCES.

Getting that wrong is expensive in both directions. Asking for a column
the datasource does not have -- the INPUT of a write's expression, say
-- fails forever, and the wait burns its whole timeout on every such
write. Asking for too few makes the probe weaker than it needs to be.

This is a pure-function test: no cluster, no model, no Druid.

Usage:
    python3 tests/test_run_demo_columns.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNNER = os.path.join(HERE, "..", "demo", "run_demo.py")


def load_runner():
    spec = importlib.util.spec_from_file_location("run_demo", RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    rd = load_runner()
    failures = []

    def check(name, sql, expected):
        got = rd.written_columns(sql)
        if got != expected:
            failures.append("{}: expected {}, got {}".format(name, expected, got))

    # An aliased expression: the ALIAS is the output name. The
    # expression's own argument is an input, and the datasource does
    # not have it -- asking for it would fail forever.
    check(
        "aliased expression",
        'REPLACE INTO ag_drift OVERWRITE ALL\n'
        'SELECT FRACTAL_DIMENSION_DRIFT("series", 32) AS "d"\n'
        'FROM "ag_series" WHERE "host" = \'host-1\'\n'
        'PARTITIONED BY ALL;',
        ["d"],
    )

    # A fixture: every column is aliased.
    check(
        "fixture aliases",
        'REPLACE INTO "x" OVERWRITE ALL\n'
        "SELECT FRACTAL_JSON_VALUE(j, '$.host') AS \"host\",\n"
        "       FRACTAL_JSON_VALUE(j, '$.v') AS \"v\"\n"
        "FROM UNNEST(ARRAY[1]) AS t(j)",
        ["host", "v"],
    )

    # A hand-written write with no aliases: the bare identifiers ARE
    # the output names.
    check(
        "no aliases",
        'REPLACE INTO "y" OVERWRITE ALL SELECT "t", "conn_rate" FROM "z"',
        ["t", "conn_rate"],
    )

    # Mixed: the aliased term takes its alias, the plain one its own
    # name.
    check(
        "mixed",
        'REPLACE INTO "w" OVERWRITE ALL SELECT "a", "b" AS "bee" FROM "z"',
        ["a", "bee"],
    )

    # A function call's own commas do not split the list.
    check(
        "function arguments",
        'REPLACE INTO "q" OVERWRITE ALL '
        'SELECT FRACTAL_VECTOR_COSINE_SIMILARITY("a", "b", 3) AS "s" FROM "z"',
        ["s"],
    )

    # A write with no FROM at all: the list ends at the PARTITIONED BY,
    # not at whatever statement follows.
    check(
        "no FROM",
        "REPLACE INTO afm_opt OVERWRITE ALL\n"
        "SELECT FRACTAL_JSON_TEXT(FRACTAL_OPTIMIZE_PORTFOLIO('0.05,0.1', "
        "'1,0,0,1', 2), '$.weights') AS \"weights\"\n"
        "PARTITIONED BY ALL;",
        ["weights"],
    )

    # A subquery in the projection has a FROM of its own. The write's
    # output is the OUTER alias; the subquery's columns are not.
    check(
        "subquery in the projection",
        "REPLACE INTO pps_opt OVERWRITE ALL\n"
        "SELECT FRACTAL_OPTIMIZE_PORTFOLIO((SELECT \"mu\" FROM \"pps_mu\"),\n"
        "       ARRAY_TO_STRING(ARRAY_AGG(CAST(\"v\" AS VARCHAR), 16384), ','),\n"
        "       3) AS \"rj\"\n"
        "FROM \"pps_cov_rows\"\n"
        "PARTITIONED BY ALL;",
        ["rj"],
    )

    # An apostrophe in a COMMENT must not open a string literal: the
    # parenthesis counting after it would be at the wrong depth.
    check(
        "apostrophe in a comment",
        "REPLACE INTO rfs_capture OVERWRITE ALL\n"
        "SELECT x.channel,\n"
        "       -- ARRAY_AGG's size guardrail; a 256-sample series is 2048.\n"
        "       ARRAY_AGG(x.level, 8192) AS levels\n"
        "FROM ( SELECT s.channel FROM \"rfs\" s) x\n"
        "PARTITIONED BY ALL;",
        ["channel", "levels"],
    )

    # An unquoted alias, and a qualified column reference.
    check(
        "unquoted alias",
        'REPLACE INTO "u" OVERWRITE ALL SELECT "a" AS bare FROM "z"',
        ["bare"],
    )

    if failures:
        for failure in failures:
            print("FAIL: " + failure, file=sys.stderr)
        return 1
    print("ok: the runner names the columns a write produces")
    return 0


if __name__ == "__main__":
    sys.exit(main())
