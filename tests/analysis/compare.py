#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Compare a static-analysis run with the accepted findings.

usage: compare.py BASELINE REPORT...

The report files are the raw tool outputs. Each finding is keyed by
(tool, file, check) and counted, so a finding that moves a line does not
break the comparison, and a finding that appears or disappears does.

The baseline is a text file, one accepted finding per line:

    tool | file | check | count | the reason it is accepted

The count is what the baseline ACCEPTS of that finding: a finding that is
not in the baseline, or one the run reports more often than the baseline
accepts, is a NEW finding and the run fails. A baseline entry the run
reports less often, or not at all, is STALE: it is reported, so the
baseline can be trimmed, but the run still passes.

The count is a budget, not a measurement, because the tools do not report
the same findings on every platform: clang-tidy's va_list check fires on
x86_64 and not on aarch64, where va_list is an array type. A baseline that
had to match every platform exactly could not hold that entry at all.

usage: compare.py --update BASELINE REPORT...   writes the baseline skeleton
"""
import os
import re
import sys
from collections import Counter

# The tools and how their output is read.
TOOLS = ("gcc-fanalyzer", "clang-tidy", "cppcheck")

# A finding's key: the tool, the file (relative to the repository root)
# and the check's name. The message is not part of the key: it changes
# with the wording of the tool, and the count is what says whether
# something moved.
LINE = re.compile(r"^(?P<file>[^:]+):(?P<line>\d+)(?::\d+)?:\s*(?P<sev>warning|error):\s*(?P<msg>.*)$")
CLANG_TIDY_CHECK = re.compile(r"\[([a-zA-Z0-9_.\-]+(?:,[a-zA-Z0-9_.\-]+)*)\]\s*$")
CPPCHECK = re.compile(r"^(?P<file>[^:]+):(?P<line>\d+):(?:\d+)?:\s*(?P<sev>[a-z]+):\s*(?P<msg>.*?)\s*\[(?P<check>[a-zA-Z0-9_]+)\]\s*$")


def findings(tool, path, root):
    out = Counter()
    details = {}
    if not os.path.exists(path):
        return out, details
    for raw in open(path, errors="replace"):
        line = raw.rstrip("\n")
        if tool == "clang-tidy":
            m = LINE.match(line)
            if not m:
                continue
            c = CLANG_TIDY_CHECK.search(m.group("msg"))
            if c:
                # A finding can carry more than one check name; the
                # first one is the check that reported it.
                check = c.group(1).split(",")[0]
            else:
                check = "unknown"
            msg = CLANG_TIDY_CHECK.sub("", m.group("msg")).strip()
        elif tool == "gcc-fanalyzer":
            m = LINE.match(line)
            if not m:
                continue
            c = re.search(r"\[([-A-Za-z0-9_.]+)\]\s*$", m.group("msg"))
            check = c.group(1) if c else "unknown"
            msg = re.sub(r"\[([-A-Za-z0-9_.]+)\]\s*$", "", m.group("msg")).strip()
        elif tool == "cppcheck":
            m = CPPCHECK.match(line)
            if not m:
                continue
            check = m.group("check")
            msg = m.group("msg").strip()
        else:
            continue
        f = os.path.relpath(m.group("file"), root) if os.path.isabs(m.group("file")) else m.group("file")
        # A tool that reports a path relative to its own working
        # directory gets the same spelling as one that reports an
        # absolute path.
        if not os.path.isabs(m.group("file")) and not os.path.exists(os.path.join(root, f)):
            if os.path.exists(os.path.join(root, "service", f)):
                f = os.path.join("service", f)
        key = (tool, f, check)
        out[key] += 1
        details.setdefault(key, []).append("%s:%s: %s" % (f, m.group("line"), msg))
    return out, details


def main(argv):
    update = False
    if argv and argv[0] == "--update":
        update = True
        argv = argv[1:]
    if len(argv) < 2:
        print(__doc__)
        return 2
    baseline_path = argv[0]
    reports = argv[1:]
    root = os.environ.get("FSQL_ANALYZE_ROOT", os.getcwd())

    found = Counter()
    details = {}
    ran = []
    for tool in TOOLS:
        path = None
        for r in reports:
            if os.path.basename(r).startswith(tool):
                path = r
                break
        if path is None or not os.path.exists(path):
            # The tool was not installed: its findings are not compared
            # at all, and its baseline entries are not stale.
            continue
        ran.append(tool)
        c, d = findings(tool, path, root)
        found.update(c)
        details.update(d)

    if update:
        with open(baseline_path, "w") as fh:
            fh.write("# The accepted static-analysis findings: tool | file | check | count | the reason it is accepted.\n")
            fh.write("# One line per (tool, file, check); the count is how many findings of that kind are accepted.\n")
            for (tool, f, check), n in sorted(found.items()):
                fh.write("%s | %s | %s | %d | TODO: the reason this is accepted\n" % (tool, f, check, n))
        print("baseline skeleton written: %d finding kind(s)" % len(found))
        return 0

    accepted = {}
    for raw in open(baseline_path, errors="replace"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 4:
            continue
        tool, f, check, count = parts[0], parts[1], parts[2], parts[3]
        try:
            n = int(count)
        except ValueError:
            continue
        accepted[(tool, f, check)] = (n, parts[4] if len(parts) > 4 else "")

    new = []
    stale = []
    for key, n in sorted(found.items()):
        if key not in accepted:
            new.append((key, n))
        elif n > accepted[key][0]:
            new.append((key, n))       # more of it than the baseline accepts
    for key, (n, _) in sorted(accepted.items()):
        if key[0] not in ran:
            continue          # that tool was not run: nothing to say about it
        if key not in found:
            stale.append((key, n))
        elif found[key] < n:
            stale.append((key, n))

    for key, n in new:
        print("NEW %s | %s | %s | %d finding(s)" % (key[0], key[1], key[2], n))
        for d in details.get(key, [])[:3]:
            print("    " + d[:200])
    for key, n in stale:
        print("STALE %s | %s | %s | the baseline accepts %d, the run found %d"
              % (key[0], key[1], key[2], n, found.get(key, 0)))
    print("%d finding kind(s) reported, %d new, %d stale" % (len(found), len(new), len(stale)))
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
