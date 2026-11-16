#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Compares a SpotBugs (with find-sec-bugs) XML report to the accepted findings.

usage: spotbugs_check.py REPORT.xml BASELINE.txt [--write]
A finding is "TYPE class" (no line number, so an edit above it does not move it). A finding not in the baseline fails the run;
a baseline entry that no longer occurs is reported so it can be removed. --write replaces the baseline with the report.
"""
import sys
import xml.etree.ElementTree as ET

report, baseline = sys.argv[1], sys.argv[2]
found = set()
for b in ET.parse(report).getroot().findall("BugInstance"):
    cls = b.find("Class")
    found.add("%s %s" % (b.get("type"), cls.get("classname") if cls is not None else "?"))
if "--write" in sys.argv:
    open(baseline, "w").write("".join(sorted(x + "\n" for x in found)))
    print("wrote %d findings to %s" % (len(found), baseline))
    sys.exit(0)
accepted = {l.strip() for l in open(baseline) if l.strip() and not l.startswith("#")}
new, gone = sorted(found - accepted), sorted(accepted - found)
for x in new:
    print("NEW  " + x)
for x in gone:
    print("GONE " + x + "   (no longer reported: remove it from the baseline)")
print("%d finding(s), %d new, %d accepted entries no longer reported" % (len(found), len(new), len(gone)))
sys.exit(1 if new else 0)
