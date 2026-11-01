"""Builds testdata/logs/*.log (SYNTHETIC app logs, no real data) and testdata/cases.json: what tools/log-summary.py prints for them.
Run from the repo root:

    python3 -I tools/wallet-build/internal/logsummary/testdata/gen_golden.py

The Go test runs the port on the same files and compares stdout and exit code. Python runs with -I like the real tool.
"""
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, *[".."] * 5))
LOGS = os.path.join(HERE, "logs")
os.makedirs(LOGS, exist_ok=True)


def ts(i):
    return "2026-10-16T19:%02d:%02d.%03d+02:00" % (i // 60 % 60, i % 60, (i * 37) % 1000)


def rec(i, level, logger, event, fields=None, extra=()):
    s = "%s %s %s %s" % (ts(i), level, logger, event)
    if fields is not None:
        s += " " + fields
    return [s] + ["  " + e for e in extra]


def write(name, lines, newline="\n"):
    with open(os.path.join(LOGS, name), "w", encoding="utf-8", newline="") as f:
        for ln in lines:
            f.write(ln + newline)


main = []
i = 0
def add(*a, **k):
    global i
    i += 1
    main.extend(rec(i, *a, **k))

add("INFO", "bw.app", "app.info", '{"version":"2.0.1","build":57,"debug":true,"nothing":null,"ratio":0.25,"list":[1,"two",null,{"k":"v"}],"obj":{"a":1,"b":[]},"empty":{},"q":"it\'s","dq":"say \\"hi\\"","uni":"čć€"}')
add("INFO", "bw.app", "app.info", '{}')
add("DEBUG", "bw.app", "app.start", '{"phase":"logs","ms":3}')
add("DEBUG", "bw.app", "app.start", '{"phase":"db","ms":41.5,"rows":120}')
add("DEBUG", "bw.app", "app.start", '{"phase":"ui","ms":12.0,"cold":true}')
add("DEBUG", "bw.app", "app.start", '{"phase":"db","ms":9}')  # a repeated phase: a new run
add("DEBUG", "bw.app", "app.start", '{"phase":"ui"}')  # no ms
add("DEBUG", "bw.app", "app.start", '{"phase":"logs","ms":"slow"}')  # 'logs' always starts a run; ms not a number
add("DEBUG", "bw.app", "app.start", '{"ms":7}')  # no phase
for k, ms in enumerate([12, 15, 900, 14, 13, 2500, 11, 12, 16, 18]):
    add("WARNING" if ms > 1000 else "DEBUG", "bw.perf", "repo.load", '{"ms":%s}' % ms)
for k, ms in enumerate([1.5, 2.25, 3, 0.4, 100.75]):
    add("DEBUG", "bw.perf", "chart.build", '{"ms":%s}' % ms)
add("DEBUG", "bw.perf", "import.done", '{"rows":312,"dupes":4,"ms":41}')
add("DEBUG", "bw.perf", "import.done", '{"rows":10,"dupes":0,"ms":true}')  # a bool is not a number
add("DEBUG", "bw.perf", "bogus", '{"ms":"12"}')
add("DEBUG", "bw.perf", "tie.a", '{"ms":10}')
add("DEBUG", "bw.perf", "tie.b", '{"ms":10}')
add("INFO", "bw.import", "import.start")
add("INFO", "bw.import", "import.done", '{"rows":312,"dupes":4,"ms":41}')
add("WARNING", "bw.sync", "sync.retry", '{"attempt":3,"why":"timeout","name":"čć","n":1.0,"big":12345678901234567890}', extra=["error: SocketException", "#0 a", "#1 b", "#2 c", "#3 d", "#4 e", "#5 f"])
add("SEVERE", "bw.db", "db.fail", '{"code":-1,"dup":1,"dup":2}', extra=["error: boom"])
add("SHOUT", "bw.db", "db.shout")
add("FINE", "bw.db", "fine.thing")
add("MYLEVEL", "bw.zzz", "weird")
for k in range(6):
    add("DEBUG", "bw.frames", "frames.window", '{"tab":"spending","frames":%d,"janky":%d,"build_p99_ms":%s,"raster_p99_ms":%s,"build_max_ms":20,"raster_max_ms":33.5}' % (100 + k, k, 10 + k, 8.5))
add("DEBUG", "bw.frames", "frames.window", '{"tab":"insights","frames":50,"janky":0,"build_p99_ms":4,"raster_p99_ms":3}')
add("DEBUG", "bw.frames", "frames.window", '{"frames":0,"janky":0}')
for k in range(12):
    add("WARNING", "bw.frames", "frames.slow", '{"ms":%d,"tab":"spending"}' % (101 + k))
for k, (a, b) in enumerate([(120, 150), (125.5, 150), (118, 151.25)]):
    add("DEBUG", "bw.mem", "mem", '{"rss_mb":%s,"max_rss_mb":%s}' % (a, b))
add("DEBUG", "bw.mem", "mem", '{"rss_mb":"x"}')
for k in range(25):
    add("INFO", "bw.app", "lifecycle", '{"state":"%s"}' % ["resumed", "inactive", "paused"][k % 3])
add("INFO", "bw.app", "lifecycle")
main.append("garbage line that is not a record")
main.append("")
main.append("   ")
add("DEBUG", "bw.app", "no.fields.here", '{"broken":')  # bad JSON: no match as a record, counted as unparsed
write("main.log", main)

second = []
i = 1000
add2 = add
main_backup = main
main = second
add("INFO", "bw.app", "app.info", '{"version":"2.0.2"}')
add("DEBUG", "bw.perf", "repo.load", '{"ms":20}')
add("ERROR", "bw.app", "x", '{"a":{"b":{"c":[1,2,{"d":null}]}}}')
write("second.log", second)
write("crlf.log", ["%s INFO bw.app lifecycle {\"state\":\"resumed\"}" % ts(1), "%s WARNING bw.app w {\"a\":1}" % ts(2), "  error: crlf"], newline="\r\n")
write("lone-cr.log", [], newline="\n")
with open(os.path.join(LOGS, "lone-cr.log"), "w", encoding="utf-8", newline="") as f:
    f.write("%s INFO bw.app lifecycle {\"state\":\"a\"}\r%s INFO bw.app lifecycle {\"state\":\"b\"}\r" % (ts(1), ts(2)))
write("noise.log", ["nothing here", "  indented but no record yet", "2026-13-99 not a date"])
write("empty.log", [])
with open(os.path.join(LOGS, "bad-utf8.log"), "wb") as f:
    f.write((ts(1) + " WARNING bw.app w {\"a\":\"x").encode() + b"\xff\xfe" + "y\"}\n".encode())

cases = []


def case(name, files):
    r = subprocess.run(["python3", "-I", os.path.join(ROOT, "tools", "log-summary.py")] + [os.path.join(LOGS, f) for f in files],
                       capture_output=True, text=True, cwd=ROOT)
    out = r.stdout.replace(LOGS, "{LOGS}")
    cases.append({"name": name, "files": files, "exit": r.returncode, "stdout": out, "stderr_empty": r.stderr == ""})


case("main", ["main.log"])
case("two-files", ["main.log", "second.log"])
case("crlf", ["crlf.log"])
case("lone-cr", ["lone-cr.log"])
case("noise", ["noise.log"])
case("empty", ["empty.log"])
case("bad-utf8", ["bad-utf8.log"])
case("second-only", ["second.log"])
with open(os.path.join(HERE, "cases.json"), "w", encoding="utf-8") as f:
    json.dump({"cases": cases}, f, indent=1, ensure_ascii=False)
