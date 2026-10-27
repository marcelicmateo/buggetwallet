#!/usr/bin/env python3
"""Mutation testing for the pure Dart packages (stdlib only; run with `python3 -I`).

Normally started as `tools/build.sh mutate <importer|core> <lib file>… [options]`, which runs this in the build container.

  mutate.py <importer|core> <lib file>… [--max N] [--seed S] [--tests <test file>…] [--timeout SECS] [--list]

Per target file it lists simple one-token mutants (+/-, * and ~/, < <=, > >=, == !=, && ||, integer literals, true/false,
a trivially typed `return x;` replaced by a default), skipping comments, strings, imports and assert lines. A seeded sample
of --max mutants (default 60 per file) is then run serially: the mutant is written into the lib file, `dart test
--fail-fast` runs (the whole package suite, or only --tests), and the file is restored. The original is saved next to the
run output and restored on exit, SIGINT and SIGTERM. A mutant is `killed` (a test failed), `survived` (all passed),
`timeout`, or `invalid` (does not compile; not counted).

Result: dist/mutation/<package>-<file>.json and a table on stdout.
"""
import argparse
import atexit
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time

PKG_DIR = {"importer": "packages/wallet_importer", "core": "packages/wallet_core"}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (regex on a space-surrounded operator, replacement) pairs; spaces keep generics (List<int>) and `=>` out.
OPS = [
    (" + ", " - ", "+ -> -"), (" - ", " + ", "- -> +"), (" * ", " ~/ ", "* -> ~/"), (" ~/ ", " * ", "~/ -> *"),
    (" < ", " <= ", "< -> <="), (" <= ", " < ", "<= -> <"), (" > ", " >= ", "> -> >="), (" >= ", " > ", ">= -> >"),
    (" == ", " != ", "== -> !="), (" != ", " == ", "!= -> =="), (" && ", " || ", "&& -> ||"), (" || ", " && ", "|| -> &&"),
]
DEFAULTS = {"int": "0", "bool": "false", "double": "0.0", "String": "''"}


def code_mask(src):
    """True for each character that is code (not a comment, string, or string interpolation)."""
    n, mask, i = len(src), [True] * len(src), 0
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                mask[k] = False
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                mask[k] = False
            i = j
        elif c in "'\"" or (c == "r" and i + 1 < n and src[i + 1] in "'\"" and not (i and (src[i - 1].isalnum() or src[i - 1] == "_"))):
            raw = c == "r"
            s = i + 1 if raw else i
            q = src[s]
            triple = src.startswith(q * 3, s)
            ql = 3 if triple else 1
            j = s + ql
            while j < n:
                if src[j] == "\\" and not raw:
                    j += 2
                    continue
                if src.startswith(q * ql, j):
                    j += ql
                    break
                if src[j] == "\n" and not triple:
                    break
                j += 1
            for k in range(i, min(j, n)):
                mask[k] = False
            i = j
        else:
            i += 1
    return mask


def mutants_of(path):
    src = open(path, encoding="utf-8").read()
    mask = code_mask(src)
    lines = src.split("\n")
    starts, pos = [], 0
    for ln in lines:
        starts.append(pos)
        pos += len(ln) + 1
    out = []
    for idx, ln in enumerate(lines):
        stripped = ln.strip()
        if re.match(r"(import|export|part|library)\b", stripped) or stripped.startswith("assert") or stripped.startswith("@"):
            continue
        base = starts[idx]

        def code(a, b):
            return all(mask[base + k] for k in range(a, b))

        def add(a, b, new, op):
            out.append({"line": idx + 1, "col": a + 1, "start": base + a, "end": base + b, "op": op,
                        "orig": ln[a:b].strip() or ln[a:b], "mutant": new.strip() or new, "text": new})

        for old, new, op in OPS:
            for m in re.finditer(re.escape(old), ln):
                if not code(m.start(), m.end()):
                    continue
                if old in (" < ", " > ") and re.search(r"[=<>]$", ln[:m.start()]):
                    continue
                add(m.start(), m.end(), new, op)
        for m in re.finditer(r"(?<![\w.$])\d+(?![\w.])", ln):
            if not code(m.start(), m.end()) or re.match(r"\s*\.\d", ln[m.end():]):
                continue
            v = int(m.group())
            for new in ({"1"} if v == 0 else {"0", str(v + 1)} if v == 1 else {str(v + 1)}):
                add(m.start(), m.end(), new, "int %d -> %s" % (v, new))
        for m in re.finditer(r"(?<![\w.$])(true|false)(?![\w$])", ln):
            if code(m.start(), m.end()):
                new = "false" if m.group() == "true" else "true"
                add(m.start(), m.end(), new, "%s -> %s" % (m.group(), new))
        m = re.match(r"(\s*)return (.+);\s*$", ln)
        if m and code(len(m.group(1)), len(m.group(1)) + 6):
            ind = len(m.group(1))
            for j in range(idx - 1, -1, -1):  # nearest less indented line: the enclosing member
                if lines[j].strip() == "" or len(lines[j]) - len(lines[j].lstrip()) >= ind:
                    continue
                s = re.match(r"\s*(?:static\s+)?(int|bool|double|String)\s+[\w.]+\s*(?:<[^>]*>)?\s*(?:\(|=>|\{|get\b)", lines[j])
                if s and not m.group(2).strip().endswith(DEFAULTS[s.group(1)]):
                    add(ind + 7, len(ln.rstrip()) - 1, DEFAULTS[s.group(1)], "return -> default %s" % DEFAULTS[s.group(1)])
                break
    # operators inside `x = a + b` etc. can match twice through overlapping ops (e.g. " > " vs " >= "): they cannot, spaces differ
    return src, out


def run_tests(pkg_dir, tests, timeout):
    """Returns (status, seconds). Runs in its own process group so a hung test is killed with its children."""
    cmd = ["dart", "test", "--fail-fast", "--timeout", "30s", "-r", "compact"] + tests
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=pkg_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return "timeout", time.time() - t0, ""
    dt = time.time() - t0
    if p.returncode == 0:
        return "survived", dt, out
    if re.search(r"Failed to load|Error: |Compilation failed|compiler|Unhandled exception", out) and not re.search(r"\[E\]|Some tests failed|-\d+: ", out):
        return "invalid", dt, out
    return "killed", dt, out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package", choices=sorted(PKG_DIR))
    ap.add_argument("files", nargs="+", help="lib files, relative to the repo root or the package")
    ap.add_argument("--max", type=int, default=60, help="mutants per file (sampled with --seed)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--tests", nargs="*", default=[], help="test files/dirs relative to the package (default: the whole suite)")
    ap.add_argument("--timeout", type=float, default=0, help="seconds per mutant (default: 3x the baseline run, at least 30; a timeout counts as killed, e.g. an endless loop)")
    ap.add_argument("--list", action="store_true", help="only list how many mutants each file has")
    a = ap.parse_args()

    pkg_dir = os.path.join(ROOT, PKG_DIR[a.package])
    targets = []
    for f in a.files:
        f = f[len(ROOT) + 1:] if f.startswith(ROOT + "/") else f
        f = f[len(PKG_DIR[a.package]) + 1:] if f.startswith(PKG_DIR[a.package] + "/") else f
        if not os.path.isfile(os.path.join(pkg_dir, f)):
            sys.exit("no such file in %s: %s" % (PKG_DIR[a.package], f))
        targets.append(f)

    plans = []
    for f in targets:
        src, ms = mutants_of(os.path.join(pkg_dir, f))
        random.Random(a.seed).shuffle(ms)
        sample = sorted(ms[:a.max], key=lambda m: (m["line"], m["col"]))
        print("%s: %d mutants, %d sampled" % (f, len(ms), len(sample)), flush=True)
        plans.append((f, src, len(ms), sample))
    if a.list:
        return

    out_dir = os.path.join(ROOT, "dist", "mutation")
    os.makedirs(out_dir, exist_ok=True)
    state = {"path": None, "src": None}

    def restore(*_):
        if state["path"] and state["src"] is not None:
            with open(state["path"], "w", encoding="utf-8") as fh:
                fh.write(state["src"])
            state["src"] = None
        if _:
            sys.exit(130)

    atexit.register(restore)
    signal.signal(signal.SIGINT, restore)
    signal.signal(signal.SIGTERM, restore)

    print("baseline run ...", flush=True)
    st, base_secs, out = run_tests(pkg_dir, a.tests, 1800)
    if st != "survived":
        print(out[-3000:])
        sys.exit("baseline tests do not pass (%s); nothing to mutate" % st)
    timeout = a.timeout or max(30.0, 3 * base_secs)
    print("baseline %.1fs, per-mutant timeout %.0fs" % (base_secs, timeout), flush=True)

    totals = []
    for f, src, total, sample in plans:
        path = os.path.join(pkg_dir, f)
        backup = os.path.join(out_dir, ".orig-" + f.replace("/", "_"))
        shutil.copyfile(path, backup)  # survives a kill -9: copy it back by hand
        state["path"], state["src"] = path, src
        rows = []
        for i, m in enumerate(sample, 1):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(src[:m["start"]] + m["text"] + src[m["end"]:])
            st, dt, _ = run_tests(pkg_dir, a.tests, timeout)
            restore_src = src
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(restore_src)
            rows.append({k: m[k] for k in ("line", "col", "op", "orig", "mutant")} | {"status": st, "seconds": round(dt, 1)})
            print("[%d/%d] %s:%d %-10s %s -> %s" % (i, len(sample), f, m["line"], st, m["orig"], m["mutant"]), flush=True)
        state["src"] = None
        os.remove(backup)
        counts = {s: sum(r["status"] == s for r in rows) for s in ("killed", "survived", "timeout", "invalid")}
        name = "%s-%s.json" % (a.package, f.replace("/", "_"))
        with open(os.path.join(out_dir, name), "w") as fh:
            json.dump({"package": a.package, "file": f, "seed": a.seed, "tests": a.tests, "mutants_total": total,
                       "sampled": len(sample), **counts, "mutants": rows}, fh, indent=1)
        totals.append((f, len(sample), counts))
        print("\n%s survivors:" % f)
        for r in rows:
            if r["status"] == "survived":
                print("  %s:%d  %s  %s -> %s  [%s]" % (f, r["line"], r["op"], r["orig"], r["mutant"], r["status"]))
    print("\nfile                     sampled killed survived timeout invalid")
    for f, n, c in totals:
        print("%-24s %7d %6d %8d %7d %7d" % (f, n, c["killed"], c["survived"], c["timeout"], c["invalid"]))


if __name__ == "__main__":
    main()
