#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Valid calls that take each argument-dependent path in the tool adapters and the Druid client.

usage: mcp_valid_calls.py PATH_TO_SERVER

mcp_mutate.py calls every tool with its arguments all present and then changes one at a time to a bad value, so
the bad shapes are covered. What it does not do is call a tool with a VALID, different argument set: the optional
arguments left out together, a boolean true and false, a mode string of each kind, an option object with and
without the key a route renames, a trim length that is shorter than the answer. Each of those is a branch in
the adapters (agency.cpp, analytics.cpp, discovery.cpp, vectors.cpp) and in db.h's mapping of a call to a Druid
SQL function or an extension endpoint. This table makes those calls against the stand-in Druid, each several times
over because the stand-in rotates the shape of its answers (numbers, text, a vector, a hex fingerprint, null,
nested values), so every way a result is turned into JSON is reached.

What must hold for every call: a well-formed answer with the same id, and the server still running at the end. The answers' content
is the stand-in's; what is asserted is how the server handles it.
"""
import json
import os
import select
import subprocess
import sys

binary = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
failures = []
calls_made = 0
classes = {}

MU = [0.1, 0.2, 0.15, 0.05]
COV = [0.1, 0.01, 0, 0, 0.01, 0.2, 0, 0, 0, 0, 0.15, 0, 0, 0, 0, 0.1]
SERIES = [round(0.1 * (i % 7) + 0.01 * i, 4) for i in range(48)]
PORT = {"mu": MU, "cov": COV, "k": 2}

TABLE = [
    # the portfolio: the six-argument form, mapped to the extended function (levy or not); the short forms
    ("fractal_optimize_portfolio", dict(PORT, seed=0, use_obl=True, diffusion_mode="levy")),
    ("fractal_optimize_portfolio", dict(PORT, seed=0, use_obl=False, diffusion_mode="gaussian")),
    ("fractal_optimize_portfolio", dict(PORT, seed=0)),
    ("fractal_optimize_portfolio", dict(PORT)),
    ("fractal_optimize_portfolio_multimodal", dict(PORT, n_restarts=3, quality_frac=0.5, overlap_threshold=0.3, seed=1)),
    ("fractal_optimize_portfolio_multimodal", dict(PORT)),
    ("fractal_optimize_portfolio_multimodal_pareto", dict(PORT, n_restarts=2, max_front=3, seed=1)),
    ("fractal_optimize_portfolio_multimodal_pareto", dict(PORT)),
    # agents that run a statement: auto_execute true and false, with and without the optional arguments
    ("fractal_sql_agent", {"question": "count the rows", "auto_execute": True, "max_retries": 2, "table_names": ["t"]}),
    ("fractal_sql_agent", {"question": "count the rows", "auto_execute": False}),
    ("fractal_sql_agent", {"question": "count the rows"}),
    ("fractal_agent_data_analyst", {"question": "q", "auto_execute": True, "context": "ctx", "max_retries": 1, "table_names": ["t"]}),
    ("fractal_agent_data_analyst", {"question": "q", "auto_execute": False}),
    ("fractal_agent_data_analyst", {"question": "q"}),
    # the vectorizer: an option object with the renamed key and without, and each action
    ("fractal_vectorizer_create", {"source_table": "t", "text_col": "body", "embedding_col": "emb", "id_col": "pk",
                                   "options": {"id_col": "pk", "batch_size": 10}, "context_id": "c1"}),
    ("fractal_vectorizer_create", {"source_table": "t", "text_col": "body", "embedding_col": "emb", "options": {"batch_size": 10}}),
    ("fractal_vectorizer_create", {"source_table": "t", "text_col": "body", "embedding_col": "emb"}),
    ("fractal_vectorizer_process_queue", {"batch_size": 5, "stale_after": 60, "context_id": "c1"}),
    ("fractal_vectorizer_process_queue", {}),
    ("fractal_vectorizer_pause", {"id": 1, "context_id": "c1"}), ("fractal_vectorizer_resume", {"id": 1}),
    ("fractal_vectorizer_drop", {"id": 1}),
    # analytics whose answer is cut to the length asked for
    ("fractal_periodogram", {"series": SERIES, "max_peaks": 1}), ("fractal_periodogram", {"series": SERIES}),
    ("fractal_spectrogram_entropy", {"series": SERIES, "window": 8, "hop": 4, "max_frames": 1}),
    ("fractal_spectrogram_entropy", {"series": SERIES}),
    ("fractal_change_point_detect", {"series": SERIES, "window": 8, "threshold": 2.0, "max_points": 1}),
    ("fractal_change_point_detect", {"series": SERIES, "window": 8}),
    ("fractal_dimension_dfa", {"series": SERIES}),
    ("fractal_state_fingerprint", {"vector": [1, 2, 3, 4], "n_bits": 64, "seed": 0}),
    ("fractal_state_fingerprint", {"vector": [1, 2, 3, 4]}),
    ("fractal_cycle_detect", {"fingerprints": ["00ff10ab", "0f0f0f0f", "00ff10ab"], "n_bits": 64, "hamming_threshold": 4}),
    ("fractal_cycle_detect", {"fingerprints": ["00ff10ab", "0f0f0f0f", "00ff10ab"], "n_bits": 64}),
    ("fractal_feedback_report", {"result_handle": 1, "kind": "click", "dwell_ms": 250, "context_id": "c1"}),
    ("fractal_feedback_report", {"result_handle": 1, "kind": "skip"}),
    ("fractal_hybrid_clinical_search", {"table_name": "t", "vector_col": "emb", "query": [1, 0, 0], "doc_ids": [1, 2, 3], "k": 3, "limit": 5}),
    ("fractal_hybrid_clinical_search", {"table_name": "t", "vector_col": "emb", "query": [1, 0, 0], "doc_ids": []}),
    ("fractal_version", {}),
    ("fractal_vector_quantize_int8", {"vector": [0.5, -0.5, 0.25]}), ("fractal_vector_quantize_binary", {"vector": [0.5, -0.5]}),
    ("fractal_vector_hamming_distance", {"a": "0f0f0f0f", "b": "f0f0f0f0"}),
    ("fractal_vector_lp_distance", {"a": [0, 0], "b": [3, 4], "p": 1}),
    ("fractal_search_debug", {"corpus": [0, 0, 1, 1, 2, 2, 3, 3], "query": [1, 1], "k": 2}),
    ("fractal_search_explore", {"table_name": "t", "vector_col": "emb", "query": [1, 1]}),
    ("fractal_ledger_verify", {}), ("fractal_ledger_truth_count", {}),
]
REPEAT = 14        # the stand-in rotates the shape of its answers; this is more than one full turn of its list

VARIANTS = [{}, {"FSQL_MCP_AGENT_PARTIAL": "off"}, {"FSQL_MCP_READ_ONLY": "true"}, {"FSQL_MCP_AGENT_PARTIAL": "on", "DRUID_TIMEOUT_MS": "3000"}]


def check(name, cond, detail=""):
    if not cond:
        print("FAIL " + name + "  " + str(detail)[:300])
        failures.append(name)


class Server:
    def __init__(self, env):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "valid", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params=None, timeout=60):
        self.n += 1
        try:
            self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params if params is not None else {}}) + "\n")
            self.p.stdin.flush()
        except (BrokenPipeError, ValueError):
            return None
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return "timeout"
        line = self.p.stdout.readline()
        if not line:
            return None
        try:
            return json.loads(line)
        except ValueError:
            return "garbled: " + line[:100]

    def alive(self):
        return self.p.poll() is None

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(10)
        except subprocess.TimeoutExpired:
            self.p.kill()


def main():
    global calls_made
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(here, "mock_druid.py"), "0"], stdout=subprocess.PIPE, text=True)
    url = "http://127.0.0.1:%d" % int(mock.stdout.readline())
    try:
        for variant in VARIANTS:
            env = dict(os.environ, DRUID_URL=url, DRUID_TIMEOUT_MS="2000")
            env.update(variant)
            s = Server(env)
            known = {t["name"] for t in s.rpc("tools/list")["result"]["tools"]}
            for name, args in TABLE:
                if name not in known:
                    check("%s is a registered tool" % name, False)
                    continue
                for rep in range(REPEAT):
                    r = s.rpc("tools/call", {"name": name, "arguments": args})
                    calls_made += 1
                    if not isinstance(r, dict):
                        check("%s %s: the server answered" % (name, variant), False, r)
                        break
                    check("%s: the id comes back" % name, r.get("id") == s.n, r)
                    check("%s: a result or an error, not both" % name, ("result" in r) != ("error" in r), r)
                    res = r.get("result")
                    if isinstance(res, dict) and res.get("isError"):
                        # The stand-in rotates through answers of the wrong type as well (a number where an object is
                        # promised, null, an error in a 200): the "server" class is the designed answer to those, as in
                        # mcp_mock_sweep.py, so the classes are counted, not forbidden.
                        cls = (res.get("structuredContent") or {}).get("error_class", "?")
                        classes[cls] = classes.get(cls, 0) + 1
            check("the server is still running (%s)" % variant, s.alive())
            s.close()
    finally:
        mock.kill()
    print("valid calls: %d calls over %d tools in %d settings; error classes %s" % (calls_made, len({n for n, _ in TABLE}), len(VARIANTS), classes))
    print("%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
