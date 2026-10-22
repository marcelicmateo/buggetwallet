#!/usr/bin/env python3
"""Failing tests and BUG: skips of the stage's sub-runs, for tools/build.sh stage.

Reads run directories (one per line) on stdin, parses their tests-*.json (package:test JSON reporter) and prints
the names of failed tests and of skipped tests whose skip reason or name mentions BUG:.
"""
import glob
import json
import os
import sys


def scan(path):
    names, skips, failed, bug = {}, {}, [], []
    skipped = set()
    with open(path, errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = e.get("type")
            if t == "testStart":
                names[e["test"]["id"]] = e["test"]["name"]
            elif t == "print" and e.get("messageType") == "skip":
                skips[e["testID"]] = e.get("message", "")
            elif t == "testDone" and not e.get("hidden"):
                i = e["testID"]
                if e.get("skipped"):
                    skipped.add(i)
                elif e.get("result") not in ("success",):
                    failed.append(names.get(i, "?"))
    for i in skipped:
        if "BUG:" in skips.get(i, "") or "BUG:" in names.get(i, ""):
            bug.append(names.get(i, "?"))
    return failed, bug


def main():
    dirs = [d.strip() for d in sys.stdin if d.strip()]
    failed, bug = [], []
    for d in dirs:
        for p in sorted(glob.glob(os.path.join(d, "tests-*.json"))):
            suite = os.path.basename(p)[len("tests-"):-len(".json")]
            f, b = scan(p)
            failed += [f"{suite}: {n}" for n in f]
            bug += [f"{suite}: {n}" for n in b]
    print("--- failing tests" + ("" if failed else ": none"))
    for n in sorted(set(failed)):
        print("  " + n)
    print("--- BUG: skips" + ("" if bug else ": none"))
    for n in sorted(set(bug)):
        print("  " + n)


if __name__ == "__main__":
    main()
