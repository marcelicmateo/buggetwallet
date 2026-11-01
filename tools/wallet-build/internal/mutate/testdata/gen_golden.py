"""Golden file of mutate.py for mutants_test.go: every mutant of testdata/real/*.dart (copies of real importer and core lib files,
frozen so that later edits of the packages do not matter) and of testdata/sample.dart, in find order, and the sample mutate.py
draws for seeds 1 and 7 (max 60 and 5).

Run in the build container from the repo root (python 3.12, the same as the real mutate.py):
    tools/build.sh shell -c 'python3 -I tools/wallet-build/internal/mutate/testdata/gen_golden.py > dist/mutate-golden.json'
then copy dist/mutate-golden.json to testdata/golden.json.

mutate.py's int mutants of a literal 1 come out of a set ({"0", "2"}), whose order changes from run to run with the hash seed
(python -I randomizes it). The reference makes it the list ["0", "2"]; wallet-build uses that order.
"""
import json
import os
import random
import types

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 5))
src = open(os.path.join(ROOT, "tools", "mutate.py"), encoding="utf-8").read()
assert '{str(v + 1)}' in src and '{"0", str(v + 1)}' in src
src = src.replace('{"0", str(v + 1)}', '["0", str(v + 1)]')
mod = types.ModuleType("mutate_ref")
mod.__file__ = os.path.join(ROOT, "tools", "mutate.py")
exec(compile(src, mod.__file__, "exec"), mod.__dict__)

HERE = "tools/wallet-build/internal/mutate/testdata"
FILES = [(HERE + "/real", f) for f in (
    "csv_generic.dart", "text_codec.dart", "ids.dart", "periods.dart", "dates.dart", "splits.dart", "repo_blobs.dart")] + [(HERE, "sample.dart")]


def row(m):
    return [m["line"], m["col"], m["start"], m["end"], m["op"], m["orig"], m["mutant"], m["text"]]


out = {}
for pkg, f in FILES:
    path = os.path.join(ROOT, pkg, f)
    _, ms = mod.mutants_of(path)
    entry = {"total": len(ms), "all": [row(m) for m in ms], "sample": {}}
    for seed in (1, 7):
        for mx in (60, 5):
            s = list(ms)
            random.Random(seed).shuffle(s)
            sample = sorted(s[:mx], key=lambda m: (m["line"], m["col"]))
            entry["sample"]["%d/%d" % (seed, mx)] = [row(m) for m in sample]
    out[pkg[len(HERE) + 1:] + "/" + f if pkg != HERE else f] = entry
# one entry per line keeps the diff readable
print("{")
keys = list(out)
for i, k in enumerate(keys):
    e = out[k]
    print(" %s: {\"total\": %d," % (json.dumps(k), e["total"]))
    print('  "all": [')
    print(",\n".join("   " + json.dumps(r, ensure_ascii=False) for r in e["all"]))
    print("  ],")
    print('  "sample": {')
    print(",\n".join("   %s: %s" % (json.dumps(sk), json.dumps(sv, ensure_ascii=False)) for sk, sv in e["sample"].items()))
    print("  }}" + ("," if i < len(keys) - 1 else ""))
print("}")
