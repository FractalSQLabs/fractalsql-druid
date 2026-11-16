#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Starts the MCP server in every way its command line, environment and Druid connection allow, and checks that it
always ends in an orderly way.

Five groups:

  one-shot   --version, --help, the lock and manifest writers and --list-tools with odd arguments, environments and
             working directories (no Druid needed)
  locks      the schema and safety lock checks at start-up: a lock that is missing, that disagrees, and the switches
             that relax or enforce them in every spelling (FSQL_MCP_ALLOW_MISSING_LOCKS, FSQL_MCP_REQUIRE_LOCKS,
             FSQL_MCP_STRICT_SCHEMA_HASH)
  stdio      the stdio server with each tuning knob at normal, edge and invalid values, against a stand-in Druid
  http       --http and --https with odd ports, hosts, tokens, token and policy files, paths, origins and TLS
             settings; started, asked one question where it listens, and stopped with SIGTERM
  druid      an unusable DRUID_URL, credentials, TLS and timeout settings, and listeners that are not a Druid
             (silent, hanging up, garbage), over stdio and over HTTP

What must hold for every run: it ends within its time limit (a server that does not stop on SIGTERM or end of
input is killed and counted), it is not killed by a signal it did not receive, and where the case states an exit
status it has it. What a particular misconfiguration is refused with is not asserted.

  MCP_SERVER_EXE      the server binary (required)
  MCP_HERE            the mcp/ directory with the committed lock files (default: this file's parent)

Zero dependencies beyond the stdlib."""

from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

EXE = os.environ.get("MCP_SERVER_EXE", "")
HERE = os.environ.get("MCP_HERE") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_FAILURES = 0
_COUNT = 0
_OFFENDERS: list = []
_IGNORED_TERM: list = []   # http servers still running 20 s after SIGTERM
_MOCK = {"url": ""}

_INIT = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cli", "version": "0"}}})
_LIST = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
_CALL = json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": {"name": "fractal_version", "arguments": {}}})

_SCRUB = ("FSQL_MCP_AUTH_TOKEN", "FSQL_MCP_AUTH_TOKEN_FILE", "FSQL_MCP_TOKEN_POLICY_FILE", "FSQL_MCP_ALLOWED_ORIGINS",
          "FSQL_MCP_HTTPS", "FSQL_MCP_TLS_CERT_FILE", "FSQL_MCP_TLS_KEY_FILE", "FSQL_MCP_HTTP_PATH", "FSQL_MCP_HTTP_HOST",
          "FSQL_MCP_HTTP_PORT", "FSQL_MCP_READ_ONLY", "FSQL_MCP_LOG_LEVEL", "FSQL_MCP_TOOL_WHITELIST",
          "FSQL_MCP_ENABLED_CATEGORIES", "FSQL_MCP_STRICT_SCHEMA_HASH", "FSQL_MCP_SCHEMA_LOCK", "FSQL_MCP_SAFETY_LOCK",
          "FSQL_MCP_ALLOW_MISSING_LOCKS", "FSQL_MCP_REQUIRE_LOCKS", "FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK",
          "FSQL_MCP_MAX_ROWS_CEILING", "FSQL_MCP_CONFIG_WRITES", "FSQL_MCP_AGENT_PARTIAL", "DRUID_USER", "DRUID_PASSWORD",
          "DRUID_TOKEN", "DRUID_TIMEOUT_MS", "DRUID_TLS_INSECURE", "DRUID_FRACTALSQL_URL")


def _check(label, cond):
    global _FAILURES
    print(("PASS " if cond else "FAIL ") + label, flush=True)
    if not cond:
        _FAILURES += 1
    return bool(cond)


def _env(extra):
    env = dict(os.environ)
    env.pop("LD_PRELOAD", None)
    for k in _SCRUB:
        env.pop(k, None)
    env["DRUID_URL"] = _MOCK["url"] or "http://127.0.0.1:1"
    env.update(extra or {})
    return env


def _record(ok, what):
    global _COUNT
    _COUNT += 1
    if not ok:
        _OFFENDERS.append(what)


def _ended_well(rc, termed=False):
    """An exit status, not a death by a signal nobody sent (negative) and not 'still running'. A server that was sent
    SIGTERM may end by it."""
    return rc is not None and (rc >= 0 or (termed and rc == -signal.SIGTERM))


def _session(args, env, send, cwd, grace=0.0, timeout=30):
    """Runs the server, writes the lines in `send`, closes stdin and returns
    (rc, stdout). rc is None for a server that had to be killed."""
    p = subprocess.Popen([EXE, *args], env=_env(env), cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    try:
        for line in send:
            p.stdin.write(line + "\n")
            p.stdin.flush()
            time.sleep(grace)
        p.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    p.stdin = None       # already closed; communicate() would try to flush it
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        return None, ""


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _http_run(args, env, cwd, ask=True):
    """Starts the HTTP server, probes it once, stops it with SIGTERM. Returns the
    exit status (None if it had to be killed) and whether it answered."""
    p = subprocess.Popen([EXE, *args], env=_env(env), cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    answered = False
    port = None
    for i, a in enumerate(args):
        if a == "--http" and i + 1 < len(args) and args[i + 1].isdigit():
            port = int(args[i + 1])
    deadline = time.monotonic() + 3.0
    while ask and port and time.monotonic() < deadline and p.poll() is None:
        try:
            c = socket.create_connection(("127.0.0.1", port), timeout=1)
            c.settimeout(2)
            c.sendall(b"GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            answered = bool(c.recv(64))
            c.close()
            break
        except OSError:
            time.sleep(0.1)
    if not (ask and port):
        # Nothing to ask: give a start-up that refuses its arguments time to say so
        # before the stop signal arrives.
        try:
            p.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            pass
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=20)
        return p.returncode, answered
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        _IGNORED_TERM.append(" ".join(args))
        return -signal.SIGTERM, answered


class _FakeDb(threading.Thread):
    """A TCP listener that is not a database. mode: silent (accepts and says
    nothing), hangup (closes at once), garbage (sends bytes that are not a
    handshake), partial (a few bytes of a plausible greeting, then closes)."""

    def __init__(self, mode):
        super().__init__(daemon=True)
        self.mode = mode
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.5)
        self.port = self.sock.getsockname()[1]
        self.stop = False
        self.start()

    def run(self):
        held = []
        while not self.stop:
            try:
                c, _ = self.sock.accept()
            except OSError:
                continue
            try:
                if self.mode == "hangup":
                    c.close()
                    continue
                if self.mode == "garbage":
                    c.sendall(b"\xff" * 64 + b"\x00\x01\x02garbage\r\n")
                    c.close()
                    continue
                if self.mode == "partial":
                    c.sendall(b"\x4a\x00\x00\x00\x0a" + b"5.5.5-fake\x00")
                    c.close()
                    continue
                held.append(c)       # silent
            except OSError:
                pass
        for c in held:
            c.close()
        self.sock.close()



def _repo(base, markers=(".git",), with_mcp=True):
    """A directory shaped like a checkout: markers, and (optionally) an mcp/ directory with the committed locks."""
    os.makedirs(base, exist_ok=True)
    for m in markers:
        if m == "Makefile":
            open(os.path.join(base, m), "w").close()
        else:
            os.makedirs(os.path.join(base, m), exist_ok=True)
    if with_mcp:
        d = os.path.join(base, "mcp")
        os.makedirs(d, exist_ok=True)
        for f in (".mcp-schema-lock", ".mcp-safety-annotations-lock", "manifest.json"):
            if os.path.exists(os.path.join(HERE, f)):
                shutil.copy(os.path.join(HERE, f), d)
    return base


def one_shot(cwd):
    """(args, env, expected) where expected is 'zero', 'nonzero' or 'any'."""
    tmp = tempfile.mkdtemp(prefix="fsqlmcp_cli_")
    lock = os.path.join(tmp, "lock")
    cases = [
        (["--version"], {}, "zero"), (["--help"], {}, "zero"), (["-h"], {}, "zero"),
        (["--no-such-flag"], {}, "nonzero"), (["--tool"], {}, "nonzero"), (["--category"], {}, "nonzero"),
        (["--schema-lock-path"], {}, "nonzero"), (["--safety-lock-path"], {}, "nonzero"), (["--host"], {}, "nonzero"),
        (["--path"], {}, "nonzero"), (["--tls-cert"], {}, "nonzero"), (["--tls-key"], {}, "nonzero"), (["x"], {}, "nonzero"),
        (["--list-tools"], {}, "zero"),
        (["--list-tools", "--tool", "fractal_version"], {}, "zero"),
        (["--list-tools", "--tool", "fractal_version,fractal_search,"], {}, "zero"),
        (["--list-tools", "--tool", ","], {}, "zero"), (["--list-tools", "--tool", "no_such_tool"], {}, "zero"),
        (["--list-tools", "--tool", ""], {}, "zero"),
        (["--list-tools", "--category", "admin"], {}, "zero"),
        (["--list-tools", "--category", "admin,discovery,agency,analytics,cognition,enterprise,vectorizer"], {}, "zero"),
        (["--list-tools", "--category", "no_such_category"], {}, "zero"),
        (["--list-tools", "--category", "admin", "--tool", "fractal_search"], {}, "zero"),
        (["--list-tools", "--category", "discovery", "--tool", "fractal_search,fractal_version"], {}, "zero"),
        (["--list-tools"], {"FSQL_MCP_TOOL_WHITELIST": "fractal_search,fractal_vector_norm"}, "zero"),
        (["--list-tools"], {"FSQL_MCP_ENABLED_CATEGORIES": "admin"}, "zero"),
        (["--list-tools"], {"FSQL_MCP_ENABLED_CATEGORIES": "", "FSQL_MCP_TOOL_WHITELIST": ""}, "zero"),
        (["--list-tools"], {"FSQL_MCP_STRICT_SCHEMA_HASH": "1"}, "any"),
        (["--list-tools"], {"FSQL_MCP_STRICT_SCHEMA_HASH": "1", "FSQL_MCP_SCHEMA_LOCK": os.path.join(tmp, "absent")}, "any"),
        (["--write-schema-lock", "--schema-lock-path", lock], {}, "zero"),
        (["--write-schema-lock", "--schema-lock-path", os.path.join(tmp, "no", "such", "dir", "lock")], {}, "any"),
        (["--write-schema-lock", "--schema-lock-path", tmp], {}, "any"),
        (["--write-schema-lock", "--schema-lock-path", ""], {}, "any"),
        (["--write-schema-lock"], {"FSQL_MCP_SCHEMA_LOCK": os.path.join(tmp, "env-lock")}, "any"),
        (["--write-safety-annotations-lock", "--safety-lock-path", os.path.join(tmp, "safety")], {}, "zero"),
        (["--write-safety-annotations-lock"], {"FSQL_MCP_SAFETY_LOCK": os.path.join(tmp, "safety2")}, "zero"),
        (["--write-safety-annotations-lock", "--safety-lock-path", os.path.join(tmp, "no", "dir", "safety")], {}, "any"),
        (["--write-safety-annotations-lock", "--safety-lock-path", tmp], {}, "any"),
        (["--write-schema-lock", "--write-safety-annotations-lock", "--schema-lock-path", lock], {}, "any"),
        (["--write-safety-annotations-lock", "--list-tools", "--safety-lock-path", os.path.join(tmp, "s2")], {}, "any"),
        (["--list-tools", "--version"], {}, "zero"), (["--version", "--no-such-flag"], {}, "zero"),
        (["--no-such-flag", "--version"], {}, "nonzero"),
        (["--list-tools", "--http", "1"], {}, "any"), (["--list-tools", "--https"], {}, "any"),
    ]
    for args, env, want in cases:
        e = _env(env)
        try:
            r = subprocess.run([EXE, *args], env=e, cwd=cwd, capture_output=True, text=True, timeout=30,
                               stdin=subprocess.DEVNULL)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = None
        ok = _ended_well(rc) and (want == "any" or (want == "zero") == (rc == 0))
        _record(ok, "one-shot %s %s -> rc %s (wanted %s)" % (args, sorted(env), rc, want))
    # The repository-root discovery: the one-shot writers find the committed locks from the working directory.
    where = []
    top = _repo(os.path.join(tmp, "with-git"))
    where.append((top, ["--write-schema-lock"], os.path.join(top, "mcp", ".mcp-schema-lock")))
    deep = os.path.join(top, "a", "b", "c")
    os.makedirs(deep)
    where.append((deep, ["--write-safety-annotations-lock"], os.path.join(top, "mcp", ".mcp-safety-annotations-lock")))
    mk = _repo(os.path.join(tmp, "with-makefile"), markers=("Makefile",), with_mcp=False)
    where.append((mk, ["--write-schema-lock"], None))   # no mcp/ here: it may land beside the executable instead
    far = os.path.join(tmp, "far")
    os.makedirs(os.path.join(far, "1", "2", "3", "4", "5", "6", "7", "8", "9"))
    where.append((os.path.join(far, "1", "2", "3", "4", "5", "6", "7", "8", "9"), ["--write-schema-lock"], None))
    bare = os.path.join(tmp, "bare")
    os.makedirs(bare)
    where.append((bare, ["--write-schema-lock"], None))
    for d, args, expect in where:
        try:
            r = subprocess.run([EXE, *args], env=_env({}), cwd=d, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = None
        ok = _ended_well(rc) and (expect is None or os.path.exists(expect))
        _record(ok, "one-shot in %s %s -> rc %s, wrote %s" % (d, args, rc, expect))
    _check("cli: %d one-shot command lines, environments and working directories ended as expected" % (len(cases) + len(where)),
           not [o for o in _OFFENDERS if o.startswith("one-shot")])


def locks(cwd):
    """The lock checks at start-up, in a checkout-shaped directory so the committed locks are found, then with each
    lock missing or wrong, and each switch in every spelling."""
    global EXE
    tmp = tempfile.mkdtemp(prefix="fsqlmcp_locks_")
    n0 = len(_OFFENDERS)
    # The server also looks for locks beside its own binary (the installed layout), so these cases run a copy of it in a
    # directory that has none; the committed locks come only from the checkout-shaped directory each case builds.
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    real_exe = EXE
    EXE = os.path.join(bindir, os.path.basename(real_exe))
    shutil.copy(real_exe, EXE)

    def run(label, env, setup=None, want=None):
        d = _repo(os.path.join(tmp, label))
        if setup:
            setup(os.path.join(d, "mcp"))
        rc, out = _session([], env, [_INIT, _LIST], d, timeout=30)
        ok = _ended_well(rc) and (want is None or rc in want)
        _record(ok, "locks %s -> rc %s (wanted %s)" % (label, rc, want))

    def rm(name):
        return lambda d: os.remove(os.path.join(d, name))

    def corrupt(name):
        def f(d):
            with open(os.path.join(d, name), "w") as fh:
                fh.write("0000000000000000000000000000000000000000000000000000000000000000\n")
        return f

    run("both-present", {}, want=(0,))
    run("schema-missing", {}, rm(".mcp-schema-lock"), want=(2,))
    run("safety-missing", {}, rm(".mcp-safety-annotations-lock"), want=(3,))
    run("both-missing", {}, lambda d: (rm(".mcp-schema-lock")(d), rm(".mcp-safety-annotations-lock")(d)), want=(2, 3))
    for i, v in enumerate(("true", "1", "on", "yes", "TRUE", "On", "YES")):
        run("allow-missing-%d" % i, {"FSQL_MCP_ALLOW_MISSING_LOCKS": v},
            lambda d: (rm(".mcp-schema-lock")(d), rm(".mcp-safety-annotations-lock")(d)), want=(0,))
    for i, v in enumerate(("false", "0", "off", "no", "", "garbage")):
        run("allow-missing-off-%d" % i, {"FSQL_MCP_ALLOW_MISSING_LOCKS": v},
            lambda d: (rm(".mcp-schema-lock")(d), rm(".mcp-safety-annotations-lock")(d)), want=(2, 3))
    for i, v in enumerate(("false", "0", "off", "no")):
        run("require-false-%d" % i, {"FSQL_MCP_REQUIRE_LOCKS": v},
            lambda d: (rm(".mcp-schema-lock")(d), rm(".mcp-safety-annotations-lock")(d)), want=(0,))
    for i, v in enumerate(("true", "1", "on", "yes", "")):
        run("require-true-%d" % i, {"FSQL_MCP_REQUIRE_LOCKS": v}, rm(".mcp-schema-lock"), want=(2,))
    run("allow-wins-over-require", {"FSQL_MCP_ALLOW_MISSING_LOCKS": "true", "FSQL_MCP_REQUIRE_LOCKS": "true"},
        lambda d: (rm(".mcp-schema-lock")(d), rm(".mcp-safety-annotations-lock")(d)), want=(0,))
    run("schema-wrong-strict", {}, corrupt(".mcp-schema-lock"), want=(2,))
    for i, v in enumerate(("false", "0", "off", "no", "true", "1", "")):
        run("schema-wrong-strict-%d" % i, {"FSQL_MCP_STRICT_SCHEMA_HASH": v}, corrupt(".mcp-schema-lock"))
    run("safety-wrong", {}, corrupt(".mcp-safety-annotations-lock"), want=(3,))
    run("safety-wrong-relaxed", {"FSQL_MCP_STRICT_SCHEMA_HASH": "false"}, corrupt(".mcp-safety-annotations-lock"), want=(3,))
    run("both-wrong-relaxed", {"FSQL_MCP_STRICT_SCHEMA_HASH": "false"},
        lambda d: (corrupt(".mcp-schema-lock")(d), corrupt(".mcp-safety-annotations-lock")(d)), want=(3,))
    # explicit paths, relative and absolute, to a lock that exists, is missing, or is a directory
    other = os.path.join(tmp, "other.lock")
    shutil.copy(os.path.join(HERE, ".mcp-schema-lock"), other)
    run("schema-path-env", {"FSQL_MCP_SCHEMA_LOCK": other}, rm(".mcp-schema-lock"), want=(0,))
    run("schema-path-env-missing", {"FSQL_MCP_SCHEMA_LOCK": os.path.join(tmp, "nope")}, want=(2,))
    run("schema-path-is-a-directory", {"FSQL_MCP_SCHEMA_LOCK": tmp})
    run("safety-path-env-missing", {"FSQL_MCP_SAFETY_LOCK": os.path.join(tmp, "nope")}, want=(3,))
    # a filtered tool surface changes the hash: the lock describes the full catalog
    d = _repo(os.path.join(tmp, "filtered"))
    for args in (["--tool", "fractal_version"], ["--category", "admin"], ["--tool", "fractal_version", "--category", "discovery"]):
        rc, _ = _session(args, {}, [_INIT, _LIST], d, timeout=30)
        _record(_ended_well(rc), "locks filtered %s -> rc %s" % (args, rc))
    # locks found beside the executable when the working directory has none (the installed layout)
    inst = os.path.join(tmp, "installed")
    os.makedirs(inst)
    exe2 = os.path.join(inst, os.path.basename(EXE))
    shutil.copy(EXE, exe2)
    for f in (".mcp-schema-lock", ".mcp-safety-annotations-lock"):
        if os.path.exists(os.path.join(HERE, f)):
            shutil.copy(os.path.join(HERE, f), inst)
    elsewhere = os.path.join(tmp, "elsewhere")
    os.makedirs(elsewhere)
    p = subprocess.Popen([exe2], env=_env({}), cwd=elsewhere, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    try:
        p.stdin.write(_INIT + "\n")
        p.stdin.close()
    except OSError:
        pass
    p.stdin = None
    try:
        p.communicate(timeout=30)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        rc = None
    _record(_ended_well(rc), "locks beside the executable -> rc %s" % rc)
    EXE = real_exe
    _check("cli: the lock checks ended in order for every missing, wrong and relaxed lock and every switch spelling",
           len(_OFFENDERS) == n0)


def stdio(cwd):
    knobs = [{}]
    for name, vals in (
            ("FSQL_MCP_LOG_LEVEL", ("normal", "info", "verbose", "debug", "bogus", "")),
            ("FSQL_MCP_READ_ONLY", ("true", "false", "1", "0", "on", "yes", "")),
            ("FSQL_MCP_CONFIG_WRITES", ("off", "safe", "all", "on", "1", "true", "yes", "0", "false", "no", "garbage", "")),
            ("FSQL_MCP_MAX_ROWS_CEILING", ("0", "1", "-1", "abc", "99999999999999999999", "")),
            ("FSQL_MCP_MAX_CONCURRENT_CHEAP", ("0", "1", "-1", "abc", "100000")),
            ("FSQL_MCP_MAX_CONCURRENT_EXPENSIVE", ("0", "1", "-1", "abc", "100000")),
            ("FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT", ("0", "1", "-1", "abc")),
            ("FSQL_MCP_MAX_QUEUE_WAIT_MS", ("0", "1", "-1", "abc", "99999999")),
            ("FSQL_MCP_SHUTDOWN_DRAIN_MS", ("0", "1", "-1", "abc", "50")),
            ("FSQL_MCP_AGENT_PARTIAL", ("on", "off", "true", "1", "0", "garbage", "")),
            ("FSQL_MCP_TOOL_WHITELIST", ("fractal_search", "no_such_tool", ",", "")),
            ("FSQL_MCP_ENABLED_CATEGORIES", ("admin", "no_such_category", "admin,agency")),
            ("DRUID_TIMEOUT_MS", ("1", "0", "-1", "abc", "5000")),
            ("DRUID_TLS_INSECURE", ("true", "false", "1", "0", "on", "yes"))):
        for v in vals:
            knobs.append({name: v})
    knobs.append({"FSQL_MCP_MAX_CONCURRENT_CHEAP": "1", "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE": "1",
                  "FSQL_MCP_MAX_QUEUE_WAIT_MS": "1", "FSQL_MCP_LOG_LEVEL": "verbose"})
    knobs.append({"DRUID_USER": "u", "DRUID_PASSWORD": "p"})
    knobs.append({"DRUID_TOKEN": "t"})
    knobs.append({"DRUID_USER": "u", "DRUID_PASSWORD": "p", "DRUID_TOKEN": "t"})
    knobs.append({"DRUID_FRACTALSQL_URL": _MOCK["url"]})
    knobs.append({"DRUID_FRACTALSQL_URL": "http://127.0.0.1:1"})
    n0 = len(_OFFENDERS)
    d = _repo(os.path.join(tempfile.mkdtemp(prefix="fsqlmcp_stdio_"), "repo"))
    for env in knobs:
        rc, out = _session([], env, [_INIT, _LIST, _CALL], d)
        ok = _ended_well(rc) and (rc != 0 or '"id":1' in out.replace(" ", ""))
        _record(ok, "stdio %s -> rc %s" % (env, rc))
    for args in (["--tool", "fractal_version"], ["--category", "admin"], ["--category", "no_such"],
                 ["--tool", ","], ["--host", "127.0.0.1"]):
        rc, out = _session(args, {}, [_INIT, _LIST, _CALL], d)
        _record(_ended_well(rc), "stdio %s -> rc %s" % (args, rc))
    # a call for every tool family, to reach each adapter's argument handling once per setting
    calls = [json.dumps({"jsonrpc": "2.0", "id": 10 + i, "method": "tools/call", "params": {"name": n, "arguments": a}})
             for i, (n, a) in enumerate((("fractal_version", {}), ("fractal_vector_norm", {"vector": [3, 4]}),
                                         ("fractal_configure_reasoning", {"key": "reasoning_model", "value": "m"}),
                                         ("fractal_ledger_verify", {}), ("fractal_session_list", {})))]
    for mode in ("off", "safe", "all"):
        for ro in ("", "true"):
            rc, out = _session([], {"FSQL_MCP_CONFIG_WRITES": mode, "FSQL_MCP_READ_ONLY": ro}, [_INIT] + calls, d)
            _record(_ended_well(rc), "stdio config writes %s read-only %s -> rc %s" % (mode, ro, rc))
    _check("cli: %d stdio server starts with tuning knobs at normal, edge and invalid values ended in order"
           % (len(knobs) + 5 + 6), len(_OFFENDERS) == n0)


def http(cwd):
    tmp = tempfile.mkdtemp(prefix="fsqlmcp_http_")
    d = _repo(os.path.join(tmp, "repo"))
    empty = os.path.join(tmp, "empty")
    open(empty, "w").close()
    tok = os.path.join(tmp, "tok")
    open(tok, "w").write("a-long-enough-token-value-0123456789\n")
    policy = os.path.join(tmp, "policy.json")
    open(policy, "w").write(json.dumps({"tokens": [{"name": "named", "sha256": "0" * 64}, {"sha256": "1" * 64}]}))
    badpolicy = os.path.join(tmp, "bad.json")
    open(badpolicy, "w").write("{ not json")
    unreadable = os.path.join(tmp, "dir")
    os.mkdir(unreadable)
    T = {"FSQL_MCP_AUTH_TOKEN": "t" * 32}
    cases = []
    for port in (None, "0", "70000", "-1", "abc"):
        p = str(_free_port()) if port is None else port
        cases.append((["--http", p], {}))
        cases.append((["--http", p, "--host", "127.0.0.1"], T))
        cases.append((["--https", p], T))
    port = str(_free_port())
    for env in ({"FSQL_MCP_AUTH_TOKEN": "short"}, {"FSQL_MCP_AUTH_TOKEN": ""}, {"FSQL_MCP_AUTH_TOKEN": "x" * 4096},
                {"FSQL_MCP_AUTH_TOKEN_FILE": tok}, {"FSQL_MCP_AUTH_TOKEN_FILE": empty},
                {"FSQL_MCP_AUTH_TOKEN_FILE": os.path.join(tmp, "absent")}, {"FSQL_MCP_AUTH_TOKEN_FILE": unreadable},
                {"FSQL_MCP_AUTH_TOKEN": "t" * 32, "FSQL_MCP_AUTH_TOKEN_FILE": tok},
                {"FSQL_MCP_TOKEN_POLICY_FILE": policy}, {"FSQL_MCP_TOKEN_POLICY_FILE": badpolicy},
                {"FSQL_MCP_TOKEN_POLICY_FILE": os.path.join(tmp, "absent")}, {"FSQL_MCP_TOKEN_POLICY_FILE": empty},
                {"FSQL_MCP_TOKEN_POLICY_FILE": policy, "FSQL_MCP_AUTH_TOKEN": "t" * 32},
                dict(T, FSQL_MCP_ALLOWED_ORIGINS="http://localhost:3000,https://example.com"),
                dict(T, FSQL_MCP_ALLOWED_ORIGINS=","), dict(T, FSQL_MCP_ALLOWED_ORIGINS=""),
                dict(T, FSQL_MCP_HTTP_PATH="/x"), dict(T, FSQL_MCP_HTTP_PATH=""), dict(T, FSQL_MCP_HTTP_PATH="no-slash"),
                dict(T, FSQL_MCP_HTTP_PATH="/" + "a" * 2000),
                dict(T, FSQL_MCP_HTTPS="true"), dict(T, FSQL_MCP_HTTPS="1"), dict(T, FSQL_MCP_HTTPS="0"),
                dict(T, FSQL_MCP_HTTPS="true", FSQL_MCP_TLS_CERT_FILE=os.path.join(tmp, "c"), FSQL_MCP_TLS_KEY_FILE=os.path.join(tmp, "k")),
                dict(T, FSQL_MCP_HTTPS="true", FSQL_MCP_TLS_CERT_FILE=empty, FSQL_MCP_TLS_KEY_FILE=empty),
                dict(T, FSQL_MCP_READ_ONLY="true", FSQL_MCP_LOG_LEVEL="verbose"),
                dict(T, FSQL_MCP_MAX_CONCURRENT_CHEAP="1", FSQL_MCP_MAX_CONCURRENT_EXPENSIVE="1", FSQL_MCP_MAX_QUEUE_WAIT_MS="1"),
                dict(T, FSQL_MCP_SHUTDOWN_DRAIN_MS="0"), dict(T, FSQL_MCP_SHUTDOWN_DRAIN_MS="abc"),
                dict(T, FSQL_MCP_HTTP_PORT="abc"), dict(T, FSQL_MCP_HTTP_PORT="0")):
        cases.append((["--http", port], env))
    # the plaintext non-loopback switch: every arm of its condition, in each spelling
    for host in ("0.0.0.0", "::", "192.0.2.1", "localhost", "127.0.0.1", "::1"):
        cases.append((["--http", port, "--host", host], T))
        for v in ("true", "1", "yes", "on", "false", "0", "", "garbage"):
            cases.append((["--http", port, "--host", host], dict(T, FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK=v)))
    for host in ("not-an-address", "", "999.1.1.1"):
        cases.append((["--http", port, "--host", host], T))
    cases.append((["--http"], T))
    cases.append((["--http", "--host", "127.0.0.1"], T))
    cases.append((["--http", port, "--path", "/m"], T))
    cases.append((["--http", port, "--tls-cert", empty, "--tls-key", empty], T))
    cases.append((["--https", port, "--tls-cert", empty], T))
    cases.append((["--https", port, "--tls-key", empty], T))
    cases.append((["--http", port, "--tool", "fractal_version"], T))
    n0 = len(_OFFENDERS)
    for args, env in cases:
        rc, _ = _http_run(args, env, d)
        _record(_ended_well(rc, True), "http %s %s -> rc %s" % (args, sorted(env), rc))
    holder = socket.socket()
    holder.bind(("127.0.0.1", 0))
    holder.listen(1)
    taken = holder.getsockname()[1]
    rc, _ = _http_run(["--http", str(taken), "--host", "127.0.0.1"], T, d, ask=False)
    holder.close()
    _record(_ended_well(rc, True), "http on a taken port -> rc %s" % rc)
    _check("cli: %d http server starts with odd ports, hosts, tokens, policy files, origins, paths and TLS settings ended in order"
           % (len(cases) + 1), len(_OFFENDERS) == n0)


def druid(cwd):
    d = _repo(os.path.join(tempfile.mkdtemp(prefix="fsqlmcp_druid_"), "repo"))
    cases = [
        {"DRUID_URL": "http://127.0.0.1:1"}, {"DRUID_URL": "http://%s:1" % "no-such-host.invalid"},
        {"DRUID_URL": "not a url"}, {"DRUID_URL": "ftp://127.0.0.1:8888"}, {"DRUID_URL": "http://"}, {"DRUID_URL": "https://"},
        {"DRUID_URL": "https://127.0.0.1:1"}, {"DRUID_URL": "https://127.0.0.1:1", "DRUID_TLS_INSECURE": "true"},
        {"DRUID_URL": "http://127.0.0.1:99999"}, {"DRUID_URL": "http://127.0.0.1:abc"}, {"DRUID_URL": "http://[::1]:1"},
        {"DRUID_URL": "http://127.0.0.1:1/"}, {"DRUID_URL": "http://u:p@127.0.0.1:1"}, {"DRUID_URL": "x" * 5000},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_FRACTALSQL_URL": "http://127.0.0.1:2"},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_FRACTALSQL_URL": "not a url"},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_USER": "u", "DRUID_PASSWORD": "p"},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_USER": "u"}, {"DRUID_URL": "http://127.0.0.1:1", "DRUID_TOKEN": "t"},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_TOKEN": "t", "DRUID_USER": "u", "DRUID_PASSWORD": "p"},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_TIMEOUT_MS": "1"}, {"DRUID_URL": "http://127.0.0.1:1", "DRUID_TIMEOUT_MS": "abc"},
        {"DRUID_URL": "http://127.0.0.1:1", "DRUID_USER": "u" * 5000, "DRUID_PASSWORD": "p" * 5000},
    ]
    # listeners that are not a Druid: silent, hang up at once, send garbage, a few bytes then close
    for mode in ("silent", "hangup", "garbage", "partial"):
        f = _FakeDb(mode)
        base = {"DRUID_URL": "http://127.0.0.1:%d" % f.port, "DRUID_TIMEOUT_MS": "1500"}
        cases.append(base)
        cases.append(dict(base, _http="1"))
        cases.append(dict(base, DRUID_USER="u", DRUID_PASSWORD="p"))
        cases.append(dict(base, DRUID_TOKEN="t"))
    bad = []
    for c in cases:
        c = dict(c)
        http_mode = bool(c.pop("_http", ""))
        if http_mode:
            rc, _ = _http_run(["--http", str(_free_port())], dict(c, FSQL_MCP_AUTH_TOKEN="t"), d)
        else:
            rc, _ = _session([], c, [_INIT, _LIST, _CALL], d, timeout=40)
        if not _ended_well(rc):
            bad.append("%s -> rc %s" % (c, rc))
    _check("cli: %d unusable Druid settings and listeners that are not a Druid ended in order" % len(cases), not bad)
    for b in bad[:8]:
        print("      offender: " + b)


def run():
    if not EXE or not os.path.isfile(EXE):
        print("FAIL MCP_SERVER_EXE is not set to a server binary")
        return 1
    cwd = os.environ.get("MCP_SERVER_CWD") or tempfile.mkdtemp(prefix="fsqlmcp_cwd_")
    if not os.path.isdir(cwd):
        os.makedirs(cwd, exist_ok=True)
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "mock_druid.py"), "0"],
                            stdout=subprocess.PIPE, text=True)
    _MOCK["url"] = "http://127.0.0.1:%d" % int(mock.stdout.readline())
    shown = 0
    try:
        for fn in (one_shot, locks, stdio, http, druid):
            try:
                fn(cwd)
            except Exception as e:  # noqa: BLE001
                _check("cli: %s raised %r" % (fn.__name__, e), False)
            for o in _OFFENDERS[shown:shown + 8]:
                print("      offender: " + o, flush=True)
            shown = len(_OFFENDERS)
    finally:
        mock.kill()
    _check("cli: every idle http server stopped on SIGTERM%s"
           % ("" if not _IGNORED_TERM else " (still running after 20 s: %d, first: %s)"
              % (len(_IGNORED_TERM), _IGNORED_TERM[0])), not _IGNORED_TERM)
    return 1 if _FAILURES else 0


if __name__ == "__main__":
    rc = run()
    print("mcp-cli: %s; %d failure(s), %d runs" % ("ALL GREEN" if not rc else "FAILED", _FAILURES, _COUNT))
    sys.exit(rc)
