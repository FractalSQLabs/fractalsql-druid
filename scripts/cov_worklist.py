#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Coverage worklists from an lcov .info file or a JaCoCo XML report.

  cov_worklist.py lcov  IN.info OUT.txt [--filter-scope-exit] [--root DIR]
  cov_worklist.py jacoco IN.xml OUT.txt

lcov: writes a per-file table and, per file, the functions with uncovered lines or
branches, ordered by missed branches. With --filter-scope-exit, branch records whose
source line is only closing punctuation ("}", "} );") or a tool-table registration
row ("t.push_back( ToolSpec{") are dropped first: they are compiler-generated
destructor and cleanup edges with no source-level decision. The filtered totals
are printed so the report states what it did.
jacoco: per class, the methods with missed lines or branches, ordered by missed branches.
"""
import re, sys, xml.etree.ElementTree as ET

CLOSE = re.compile(r'^[ \t]*[})\];,]+[ \t})\];,]*$')


def parse_lcov(path):
    files, cur = [], None
    for ln in open(path, errors="replace"):
        ln = ln.rstrip("\n")
        if ln.startswith("SF:"):
            cur = {"f": ln[3:], "fn": {}, "fnda": {}, "da": {}, "br": []}
        elif cur is None:
            continue
        elif ln.startswith("FN:"):
            a, b = ln[3:].split(",", 1)
            cur["fn"][b] = int(a)
        elif ln.startswith("FNDA:"):
            a, b = ln[5:].split(",", 1)
            cur["fnda"][b] = int(a)
        elif ln.startswith("DA:"):
            p = ln[3:].split(",")
            cur["da"][int(p[0])] = int(p[1])
        elif ln.startswith("BRDA:"):
            p = ln[5:].split(",")
            cur["br"].append((int(p[0]), p[3] if p[3] != "-" else "0"))
        elif ln == "end_of_record":
            files.append(cur)
            cur = None
    return files


def lcov(inp, out, filt, root):
    files = parse_lcov(inp)
    dropped = 0
    rows, per_file = [], {}
    for f in files:
        try:
            src = open(f["f"], errors="replace").read().split("\n")
        except OSError:
            src = []
        br = []
        for ln, hit in f["br"]:
            text = src[ln - 1] if 0 < ln <= len(src) else ""
            if filt and (CLOSE.match(text) or "t.push_back( ToolSpec{" in text):
                dropped += 1
                continue
            br.append((ln, int(hit)))
        f["brk"] = br
        # function ranges: sorted by start line, a function runs to the next one's start
        starts = sorted((l, n) for n, l in f["fn"].items())
        spans = []
        for i, (l, n) in enumerate(starts):
            end = starts[i + 1][0] - 1 if i + 1 < len(starts) else 10 ** 9
            spans.append((l, end, n))
        funcs = []
        for l, end, n in spans:
            d = [h for ln, h in f["da"].items() if l <= ln <= end]
            b = [h for ln, h in br if l <= ln <= end]
            funcs.append({"name": n, "line": l, "called": f["fnda"].get(n, 0),
                          "ml": sum(1 for h in d if h == 0), "lines": len(d),
                          "mb": sum(1 for h in b if h == 0), "branches": len(b)})
        per_file[f["f"]] = funcs
        lf, lh = len(f["da"]), sum(1 for h in f["da"].values() if h)
        ff, fh = len(f["fn"]), sum(1 for n in f["fn"] if f["fnda"].get(n))
        bf, bh = len(br), sum(1 for _, h in br if h)
        rows.append((f["f"], lh, lf, fh, ff, bh, bf))
    pc = lambda h, t: ("%5.1f%%" % (100.0 * h / t)) if t else "   -  "
    with open(out, "w") as o:
        o.write("# coverage worklist (%s)%s\n" % (inp, "; scope-exit branches dropped: %d" % dropped if filt else ""))
        T = [0] * 6
        o.write("%-44s %-16s %-16s %-16s\n" % ("file", "lines", "functions", "branches"))
        for r in sorted(rows, key=lambda r: -(r[6] - r[5])):
            name = r[0].replace(root, "") if root else r[0]
            o.write("%-44s %s %4d/%-4d %s %3d/%-3d %s %4d/%-4d\n" % (name, pc(r[1], r[2]), r[1], r[2], pc(r[3], r[4]), r[3], r[4], pc(r[5], r[6]), r[5], r[6]))
            for i in range(6):
                T[i] += r[i + 1]
        o.write("%-44s %s %4d/%-4d %s %3d/%-3d %s %4d/%-4d\n" % ("TOTAL", pc(T[0], T[1]), T[0], T[1], pc(T[2], T[3]), T[2], T[3], pc(T[4], T[5]), T[4], T[5]))
        need = int(0.8 * T[5] + 0.999) - T[4]
        o.write("branches still needed for 80%%: %d\n\n" % max(need, 0))
        for f in sorted(per_file, key=lambda k: -sum(x["mb"] for x in per_file[k])):
            fx = [x for x in per_file[f] if x["ml"] or x["mb"] or not x["called"]]
            if not fx:
                continue
            o.write("== %s\n" % (f.replace(root, "") if root else f))
            for x in sorted(fx, key=lambda x: (-x["mb"], -x["ml"])):
                o.write("  %5d  %-44s called=%-6d missed lines %3d/%-3d  missed branches %3d/%-3d\n" % (x["line"], x["name"][:44], x["called"], x["ml"], x["lines"], x["mb"], x["branches"]))
    print("worklist: %s  (%d files, %d scope-exit branches dropped)" % (out, len(rows), dropped))


def jacoco(inp, out):
    root = ET.parse(inp).getroot()
    with open(out, "w") as o:
        o.write("# jacoco worklist (%s)\n" % inp)
        cls = []
        for pkg in root.findall("package"):
            for c in pkg.findall("class"):
                cnt = {x.get("type"): (int(x.get("covered")), int(x.get("missed"))) for x in c.findall("counter")}
                ms = []
                for m in c.findall("method"):
                    mc = {x.get("type"): (int(x.get("covered")), int(x.get("missed"))) for x in m.findall("counter")}
                    ms.append((m.get("name") + m.get("desc"), m.get("line"), mc.get("LINE", (0, 0)), mc.get("BRANCH", (0, 0))))
                cls.append((c.get("name"), cnt, ms))
        cls.sort(key=lambda c: -(c[1].get("LINE", (0, 0))[1]))
        for n, cnt, ms in cls:
            l, b = cnt.get("LINE", (0, 0)), cnt.get("BRANCH", (0, 0))
            o.write("== %s  lines %d/%d  branches %d/%d\n" % (n, l[0], sum(l), b[0], sum(b)))
            for name, line, ml, mb in sorted(ms, key=lambda m: (-m[3][1], -m[2][1])):
                if ml[1] or mb[1]:
                    o.write("  %5s  %-60s missed lines %3d/%-3d  missed branches %3d/%-3d\n" % (line, name[:60], ml[1], sum(ml), mb[1], sum(mb)))
    print("worklist: %s" % out)


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "lcov":
        root = a[a.index("--root") + 1] if "--root" in a else ""
        lcov(a[1], a[2], "--filter-scope-exit" in a, root)
    elif len(a) == 3 and a[0] == "jacoco":
        jacoco(a[1], a[2])
    else:
        sys.exit(__doc__)
