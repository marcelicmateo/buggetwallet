#!/usr/bin/env python3
"""Generates the inputs and the golden outputs of the report tests by running tools/build_log.py and tools/stage_summary.py
on synthetic data (no real logs). Run once from the repository root:  python3 -I tools/wallet-build/internal/report/testdata/gen_golden.py
The Go tests (report_test.go) must produce the same files; only the "ts" values differ and are masked there."""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
OUT = HERE


def w(name, text):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(text)


def ev(**kw):
    return json.dumps(kw, separators=(",", ":"), ensure_ascii=False)


def reporter(tests, done_time):
    """tests: (name, start, end, result, skipped, skip_message)"""
    lines = [ev(protocolVersion="0.1.1", runnerVersion="1.33.0", pid=1, type="start", time=0)]
    lines.append(ev(suite={"id": 0, "platform": "vm", "path": "test/x_test.dart"}, type="suite", time=0))
    lines.append(ev(test={"id": 1, "name": "loading test/x_test.dart", "suiteID": 0}, type="testStart", time=3))
    lines.append(ev(testID=1, result="success", skipped=False, hidden=True, type="testDone", time=90))
    for i, (name, start, end, result, skipped, msg) in enumerate(tests, start=2):
        lines.append(ev(test={"id": i, "name": name, "suiteID": 0}, type="testStart", time=start))
        if msg:
            lines.append(ev(testID=i, messageType="skip", message=msg, type="print", time=start + 1))
        lines.append(ev(testID=i, result=result, skipped=skipped, hidden=False, type="testDone", time=end))
    lines.append("not json at all")
    lines.append(ev(success=True, type="done", time=done_time))
    return "\n".join(lines) + "\n"


t1 = [
    ("adds up", 100, 104, "success", False, None),
    ("parses the Kontoauszug äöü line", 110, 125, "success", False, None),
    ("slow database \"open\"", 130, 5500, "success", False, None),
    ("fails on purpose", 5500, 5530, "failure", False, None),
    ("throws an error", 5530, 5700, "error", False, None),
    ("skipped for now", 5700, 5701, "success", True, "BUG: rounding differs"),
    ("plain skip", 5701, 5702, "success", True, "not on this platform"),
    ("medium test", 5702, 5802, "success", False, None),
    ("half a second", 5802, 6602, "success", False, None),
    ("tiny a", 6602, 6603, "success", False, None),
    ("tiny b", 6603, 6605, "success", False, None),
    ("fifty", 6605, 6655, "success", False, None),
]
t2 = [
    ("shard two first", 50, 60, "success", False, None),
    ("shard two slower", 60, 1260, "success", False, None),
    ("BUG: named skip", 1260, 1261, "success", True, None),
]
w("reporter1.json", reporter(t1, 9000))
w("reporter2.json", reporter(t2, 1500))
empty = reporter([], 0)
w("reporter-empty.json", empty)

drive = """\
I/flutter ( 4242): 00:01 +0: loading integration_test/a_test.dart
I/flutter ( 4242): 00:03 +0: first screen shows
I/flutter ( 4242): 00:07 +1: second screen opens
I/flutter ( 4242): 00:08 +2 ~1: skipped one
I/flutter ( 4242): 00:20 +2 ~1 -1: broken screen
I/flutter ( 4242): 01:02 +2 ~1 -1: (tearDownAll)
some other line
I/flutter ( 4242): 01:03 +2 ~1 -1: Some tests failed.
"""
w("drive.log", drive)

perf = [
    {"time": "2026-10-19T14:45:00", "commit": "abc1234", "action": "spending_scroll", "frame_count": 189, "build_p90_ms": 1.362,
     "build_max_ms": 11.365, "raster_p90_ms": 13.28, "raster_max_ms": 17.686, "missed_build_frames": 0, "missed_raster_frames": 4,
     "ok": True, "shader_events": 0},
    {"time": "2026-10-19T14:45:09", "commit": "abc1234", "action": "tab_switch", "frame_count": 40, "build_p90_ms": 20.0,
     "build_max_ms": 61.0, "raster_p90_ms": 0.0001, "raster_max_ms": 1e-05, "missed_build_frames": 9, "missed_raster_frames": 0,
     "ok": False, "shader_events": 3},
]
w("perf-records.jsonl", "\n".join(json.dumps(r) for r in perf) + "\nbroken line\n")

# history seeds: bash-style compact step lines, python-style suite lines
def step(ts, run, cmd, name, secs, result="ok", cold="false", commit="abc1234", source="local", worktree="wt"):
    return ('{"ts":"%s","run":"%s","source":"%s","worktree":"%s","commit":"%s","cmd":"%s","step":"%s","seconds":%s,"result":"%s",'
            '"image":"img:1","cold":%s}') % (ts, run, source, worktree, commit, cmd, name, secs, result, cold)


hist = []
for i, (cmd, steps) in enumerate([("test", [("format", "1.4", "ok"), ("core", "40.2", "ok"), ("app", "100.0", "ok")]),
                                  ("test", [("format", "1.5", "ok"), ("core", "42.0", "FAILED"), ("app", "98.5", "ok")]),
                                  ("desktop-test", [("desktop-layout", "300.0", "ok"), ("desktop-screens", "60.0", "ok")]),
                                  ("desktop-test", [("desktop-layout", "310.0", "ok"), ("desktop-screens", "58.5", "ok"),
                                                    ("desktop-new", "12.0", "ok")]),
                                  ("test", [("format", "1.3", "ok", "true"), ("core", "39.9", "ok")])]):
    run = "2026110%d-10000%d-%s-abc1234" % (i + 1, i, cmd)
    for st in steps:
        hist.append(step("2026-11-0%dT10:00:0%d+00:00" % (i + 1, i), run, cmd, st[0], st[1], st[2], st[3] if len(st) > 3 else "false"))
    hist.append(json.dumps({"ts": "2026-11-0%dT10:00:0%d+00:00" % (i + 1, i), "run": run, "source": "local", "worktree": "wt",
                            "commit": "abc1234", "cmd": cmd, "image": "img:1", "cold": False, "step": "core", "kind": "tests",
                            "count": 10 + i, "failed": 0, "total_ms": 4000 + i, "p50": 5, "p90": 20, "p99": 90, "max": 300,
                            "slowest": "a very slow test " * 6, "slowest_ms": 300}, ensure_ascii=False))
hist.append("garbage line")
w("hist-steps.jsonl", "\n".join(hist) + "\n")

tests_hist = []
for i in range(4):
    for name, ms in [("alpha", 10 * (i + 1)), ("beta", 900 - 100 * i), ("gamma: odd é name", 5 if i != 2 else 7000)]:
        tests_hist.append(json.dumps({"ts": "2026-11-0%dT10:00:00+00:00" % (i + 1), "run": "run%d" % i, "source": "local", "commit": "abc1234",
                                      "suite": "core" if name != "beta" else "app", "test": name, "ms": ms, "result": "success"}, ensure_ascii=False))
w("hist-tests.jsonl", "\n".join(tests_hist) + "\n")

w("ci-times.txt", "lint 12 0\nunit 130.5 1\nbad line\napk 400 0\n")

# ---- run the Python tools ----
os.makedirs(os.path.join(OUT, "golden"), exist_ok=True)


def golden(name, text):
    with open(os.path.join(OUT, "golden", name), "w", encoding="utf-8") as f:
        f.write(text)


def py(args, env_extra, stdin=None, data=None, logs=None):
    env = {"PATH": os.environ["PATH"], "TZ": "UTC", "HOME": "/nonexistent", "BW_SOURCE": "local", "BW_WORKTREE": "wt",
           "BW_COMMIT": "abc1234", "BW_CMD": "app", "BW_IMAGE": "img:1", "BW_RUN_ID": "20261101-100000-app-abc1234"}
    env.update(env_extra)
    return subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools", args[0])] + args[1:], env=env, input=stdin,
                          capture_output=True, text=True, encoding="utf-8", check=True).stdout


def fresh():
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "history"))
    os.makedirs(os.path.join(d, "run"))
    return d


def read(d, rel):
    p = os.path.join(d, rel)
    return open(p, encoding="utf-8").read() if os.path.exists(p) else ""


def seed(d):
    for n in ("steps", "tests"):
        with open(os.path.join(d, "history", n + ".jsonl"), "w", encoding="utf-8") as f:
            f.write(open(os.path.join(OUT, "hist-" + n + ".jsonl"), encoding="utf-8").read())


def envs(d):
    return {"BW_DATA_DIR": d, "BW_RUN_DIR": os.path.join(d, "run")}


# tests: one file, two files (shards), none, empty
for name, files in [("tests1", ["reporter1.json"]), ("tests-shards", ["reporter1.json", "reporter2.json"]), ("tests-empty", ["reporter-empty.json"])]:
    d = fresh()
    out = py(["build_log.py", "tests", "core", *[os.path.join(OUT, f) for f in files]], envs(d))
    golden(name + ".stdout", out)
    golden(name + ".summary", read(d, "run/tests-core-summary.txt"))
    golden(name + ".steps", read(d, "history/steps.jsonl"))
    golden(name + ".tests", read(d, "history/tests.jsonl"))
d = fresh()
golden("tests-missing.stdout", py(["build_log.py", "tests", "core", "/nonexistent/x.json"], envs(d)))

d = fresh()
golden("drive.stdout", py(["build_log.py", "drive", "screens", os.path.join(OUT, "drive.log")], envs(d)))
golden("drive.summary", read(d, "run/tests-screens-summary.txt"))
golden("drive.steps", read(d, "history/steps.jsonl"))
golden("drive.tests", read(d, "history/tests.jsonl"))

d = fresh()
golden("perf.stdout", py(["build_log.py", "perf", os.path.join(OUT, "perf-records.jsonl")], envs(d)))
golden("perf.summary", read(d, "run/perf-summary.txt"))
golden("perf.history", read(d, "history/perf.jsonl"))

d = fresh()
seed(d)
golden("order.stdout", py(["build_log.py", "order", "layout:5", "screens", "new", "other"], envs(d)))
golden("times.stdout", py(["build_log.py", "times"], envs(d)))
golden("times-n2.stdout", py(["build_log.py", "times", "-n", "2", "--cmd", "test"], envs(d)))
golden("times-step.stdout", py(["build_log.py", "times", "--step", "core"], envs(d)))
golden("times-none.stdout", py(["build_log.py", "times", "--commit", "zzz"], envs(d)).replace(d, "DATA"))
golden("trend.stdout", py(["build_log.py", "trend"], envs(d)))
golden("trend-top2.stdout", py(["build_log.py", "trend", "--top", "2", "-n", "3", "--step", "app"], envs(d)))
ci = dict(envs(d), GITHUB_RUN_ID="777", GITHUB_SHA="0123456789abcdef", ImageOS="ubuntu24")
out = py(["build_log.py", "ci-history", os.path.join(OUT, "ci-times.txt")], ci)
golden("ci-history.stdout", out)

# stage summary over two run dirs holding reporter files (the Go test builds the same dirs)
dirs = []
for n, f in [("a", "reporter1.json"), ("b", "reporter2.json")]:
    dd = tempfile.mkdtemp()
    open(os.path.join(dd, "tests-core.json"), "w", encoding="utf-8").write(open(os.path.join(OUT, f), encoding="utf-8").read())
    dirs.append(dd)
golden("stage-summary.stdout", py(["stage_summary.py"], {}, stdin="%s\n%s\n\n" % tuple(dirs)))
print("goldens written to", os.path.join(OUT, "golden"))
