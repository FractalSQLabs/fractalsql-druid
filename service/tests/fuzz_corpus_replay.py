#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""The UDF fuzz corpus, replayed through a live daemon.

usage: fuzz_corpus_replay.py SOCKET KEYFILE CORPUS_DIR

The in-process fuzz harness (tests/fuzz/fuzz_svc_udf.c) calls one function
per input, in one process. This replays the same corpus through a real
daemon, one call per input, on a connection that stays open: what it adds
is the state the daemon keeps BETWEEN calls -- the session registry, the
configuration overlay, the diversifier's per-session state -- which the
in-process harness cannot see.

The corpus format is the one the harness reads (tests/fuzz/fuzz_svc_udf.c):
a byte for the name's length, the name, a byte for the argument count, and
then per argument a byte (bit 0: NULL, bits 1-2: the type), a u32 length and
the value.

A refusal is a refusal: the daemon is supposed to refuse most of these.
What this checks is that no input leaves the daemon in a state where the
NEXT call fails in a way the daemon does not explain.
"""
import os
import struct
import sys

import fsq_client as fc

sock, keyfile, corpus = sys.argv[1:4]
key = fc.load_key(keyfile)


def parse(data):
    if len(data) < 2:
        return None
    namelen = data[0]
    if namelen == 0 or namelen + 2 > len(data):
        return None
    name = data[1:1 + namelen].decode("utf-8", "replace")
    nargs = data[1 + namelen]
    off = 2 + namelen
    args = []
    for _ in range(nargs):
        if off >= len(data):
            break
        spec = data[off]
        off += 1
        ln = 0
        if off + 4 <= len(data):
            ln = struct.unpack_from("<I", data, off)[0]
            off += 4
        if ln > len(data) - off:
            ln = len(data) - off
        raw = data[off:off + ln]
        off += ln
        if spec & 1:
            args.append(None)
        elif (spec >> 1) & 3 == 1:
            args.append(struct.unpack("<q", raw[:8].ljust(8, b"\0"))[0])
        elif (spec >> 1) & 3 == 2:
            args.append(struct.unpack("<d", raw[:8].ljust(8, b"\0"))[0])
        else:
            args.append(raw)
    return name, args


def main():
    files = sorted(os.listdir(corpus))
    c = fc.Client(sock, key, timeout=30)
    calls = 0
    errors = []
    try:
        for f in files:
            path = os.path.join(corpus, f)
            if not os.path.isfile(path):
                continue
            parsed = parse(open(path, "rb").read())
            if parsed is None:
                continue
            name, args = parsed
            try:
                st, v = c.call(name, *args)
                calls += 1
                # A refusal is fine. An internal error is not: it means the
                # daemon itself went wrong on the input.
                if st == 6:
                    errors.append("%s: the daemon reported an internal error: %r" % (f, v))
            except Exception as e:
                errors.append("%s: the connection failed: %s" % (f, e))
                try:
                    c.close()
                except Exception:
                    pass
                c = fc.Client(sock, key, timeout=30)
        # The daemon must still be serving.
        st, v = c.call("fractal_version")
        if st != 0 or not v:
            errors.append("the daemon does not answer after the corpus replay")
    finally:
        try:
            c.close()
        except Exception:
            pass
    print("%d call(s) from %d corpus file(s), %d problem(s)" % (calls, len(files), len(errors)))
    for e in errors[:10]:
        print("FAIL " + e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
