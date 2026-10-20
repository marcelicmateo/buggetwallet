#!/usr/bin/env python3
"""Build and test timing history for tools/build.sh, tools/emulator.sh and CI. Standard library only.

  python3 -I tools/build_log.py tests <suite> <reporter.json>...  summarise `dart test`/`flutter test` JSON reports (several
                                                                = shards of one suite, run in parallel)
  python3 -I tools/build_log.py drive <suite> <drive.log>       same for a `flutter drive` log (1 s resolution)
  python3 -I tools/build_log.py perf <perf-records.jsonl>       profile-mode perf test: table + history/perf.jsonl
  python3 -I tools/build_log.py times [-n RUNS] [--cmd C] [--step S] [--commit SHA] [--source local|ci] [--ci-file F]
                                                                last runs + median per step (tools/build-times.sh)
  python3 -I tools/build_log.py trend [-n RUNS] [--top N] [--step SUITE]   slowest tests over the last runs
  python3 -I tools/build_log.py ci-history <times.txt>          CI: history lines for the ci-logs branch
  python3 -I tools/build_log.py order <name>[:<shards>]...      desktop-test units (name:index:total), slowest first by
                                                                recent history, so parallel workers finish together

`tests` and `drive` print the summary, write tests-<suite>-summary.txt into the run dir and append to
history/steps.jsonl (one line per suite) and history/tests.jsonl (one line per test) in the data dir; layout and
run metadata (BW_DATA_DIR, BW_RUN_DIR, BW_RUN_ID, BW_COMMIT, BW_CMD, ...) are described in tools/timing.sh.
"""

import argparse
import datetime
import json
import os
import re
import statistics
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Same layout as tools/timing.sh: shared history outside the repo, per-run artifacts in the run dir
DATA = os.environ.get("BW_DATA_DIR") or os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share"), "budget-wallet")
LOGS = os.environ.get("BW_RUN_DIR") or os.path.join(ROOT, "dist", "logs")
HISTORY = os.path.join(DATA, "history", "steps.jsonl")
PERF_HISTORY = os.path.join(DATA, "history", "perf.jsonl")
TEST_HISTORY = os.path.join(DATA, "history", "tests.jsonl")
BUCKETS = [(10, "<10 ms"), (50, "10-50 ms"), (100, "50-100 ms"), (500, "100-500 ms"),
           (1000, "0.5-1 s"), (5000, "1-5 s"), (float("inf"), ">5 s")]


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def meta():
    return {
        "ts": now(),
        "run": os.environ.get("BW_RUN_ID") or os.environ.get("BW_RUN") or now(),
        "source": os.environ.get("BW_SOURCE", "local"),
        "worktree": os.environ.get("BW_WORKTREE", os.path.basename(ROOT)),
        "commit": os.environ.get("BW_COMMIT", "unknown"),
        "cmd": os.environ.get("BW_CMD", "?"),
        "image": os.environ.get("BW_IMAGE", ""),
        "cold": os.environ.get("BW_COLD") == "1",
    }


def append(path, records):
    """One os.write per line on an O_APPEND file, so concurrent runs never interleave lines."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        for r in records:
            os.write(fd, (json.dumps(r, ensure_ascii=False) + "\n").encode())
    finally:
        os.close(fd)


def read(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except FileNotFoundError:
        pass
    return out


def pct(sorted_ms, p):
    """Nearest-rank percentile."""
    if not sorted_ms:
        return 0
    k = max(0, min(len(sorted_ms) - 1, -(-p * len(sorted_ms) // 100) - 1))
    return sorted_ms[int(k)]


def parse_reporter_json(path):
    """[(name, ms, result)] from the JSON reporter, skipping hidden entries (loading, setUpAll)."""
    starts, tests, total = {}, [], None
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = e.get("type")
            if t == "testStart":
                starts[e["test"]["id"]] = (e["test"]["name"], e.get("time", 0))
            elif t == "testDone" and not e.get("hidden"):
                name, start = starts.get(e["testID"], ("?", 0))
                result = "skipped" if e.get("skipped") else e.get("result", "?")
                tests.append((name, e.get("time", 0) - start, result))
            elif t == "done":
                total = e.get("time")
    return tests, total


DRIVE_LINE = re.compile(r"I/flutter \(\s*\d+\): (\d+):(\d+) \+(\d+)(?: ~\d+)?(?: -(\d+))?: (.*)$")


def parse_drive_log(path):
    """Per-test durations from the compact reporter lines that `flutter drive` relays (second resolution)."""
    events = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = DRIVE_LINE.search(line.rstrip())
            if m:
                events.append((int(m[1]) * 60 + int(m[2]), int(m[3]), int(m[4] or 0), m[5]))
    tests = []
    for (sec, ok, bad, name), nxt in zip(events, events[1:]):
        if name.startswith("(") or "tests passed" in name or "tests failed" in name:
            continue
        result = "success" if nxt[1] > ok else ("failure" if nxt[2] > bad else "?")
        tests.append((name, (nxt[0] - sec) * 1000, result))
    total = events[-1][0] * 1000 if events else None
    return tests, total


def summarise(suite, tests, total):
    ms = sorted(t[1] for t in tests)
    failed = [t for t in tests if t[2] not in ("success", "skipped")]
    stats = {
        "count": len(tests), "failed": len(failed), "total_ms": total if total is not None else sum(ms),
        "p50": pct(ms, 50), "p90": pct(ms, 90), "p99": pct(ms, 99), "max": ms[-1] if ms else 0,
    }
    slow = sorted(tests, key=lambda t: -t[1])[:10]
    stats["slowest"], stats["slowest_ms"] = (slow[0][0], slow[0][1]) if slow else ("", 0)
    lines = [f"--- {suite}: {stats['count']} tests, {stats['failed']} failed, total {stats['total_ms'] / 1000:.1f} s; "
             f"per test p50 {stats['p50']} ms, p90 {stats['p90']} ms, p99 {stats['p99']} ms, max {stats['max']} ms"]
    counts = [0] * len(BUCKETS)
    for v in ms:
        counts[next(i for i, (hi, _) in enumerate(BUCKETS) if v < hi)] += 1
    width = max(counts) or 1
    for (_, label), c in zip(BUCKETS, counts):
        lines.append(f"  {label:>10} {c:5}  {'#' * round(40 * c / width)}")
    lines.append("  slowest:")
    lines += [f"  {t[1]:8} ms  {t[0]}{'' if t[2] == 'success' else '  [' + t[2] + ']'}" for t in slow]
    return stats, "\n".join(lines)


def record(suite, tests, total, kind):
    stats, text = summarise(suite, tests, total)
    print(text)
    os.makedirs(LOGS, exist_ok=True)
    with open(os.path.join(LOGS, f"tests-{suite}-summary.txt"), "w", encoding="utf-8") as f:
        f.write(text + "\n")
    m = meta()
    append(HISTORY, [{**m, "step": suite, "kind": kind, **stats}])
    keep = ("ts", "run", "source", "commit")
    append(TEST_HISTORY, [{**{k: m[k] for k in keep}, "suite": suite, "test": n, "ms": v, "result": r} for n, v, r in tests])


def cmd_order(args):
    """Units for tools/build.sh desktop-test, longest first (greedy scheduling ends evenly): one `name:index:total` line per
    shard. A file's weight is the median of its last 5 history seconds (step desktop-<name>, the sum over its shards)
    divided by its shards; files without history come first."""
    secs = {}
    for r in read(HISTORY):
        step = str(r.get("step", ""))
        if step.startswith("desktop-") and r.get("kind") is None and isinstance(r.get("seconds"), (int, float)):
            secs.setdefault(step[len("desktop-"):], []).append(r["seconds"])
    units = []
    for spec in args.names:
        name, _, n = spec.partition(":")
        shards = max(1, int(n or 1))
        weight = statistics.median(secs[name][-5:]) / shards if name in secs else float("inf")
        units += [(weight, name, i, shards) for i in range(shards)]
    for _, name, i, shards in sorted(units, key=lambda u: -u[0]):
        print(f"{name}:{i}:{shards}")


def cmd_perf(args):
    """Frame numbers of tools/build.sh perf (app/test_driver/perf_driver.dart writes the records, frames only, no wallet
    data): print a table, save it as perf-summary.txt in the run dir and append the records to history/perf.jsonl."""
    recs = read(args.path)
    if not recs:
        print(f"--- perf: no records at {args.path}")
        return
    m = meta()
    keep = {k: m[k] for k in ("run", "source", "worktree")}
    append(PERF_HISTORY, [{**keep, **r} for r in recs])
    rows = [[r["action"], r["frame_count"], f"{r['build_p90_ms']:.1f}", f"{r['build_max_ms']:.1f}", f"{r['raster_p90_ms']:.1f}",
             f"{r['raster_max_ms']:.1f}", r["missed_build_frames"], r["missed_raster_frames"], r.get("shader_events", ""),
             "ok" if r.get("ok") else "OVER"] for r in recs]
    header = ["perf action", "frames", "build p90", "build max", "raster p90", "raster max", "missed b", "missed r", "shader ev", ""]
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        table(rows, header)
    text = buf.getvalue()
    print(text, end="")
    os.makedirs(LOGS, exist_ok=True)
    with open(os.path.join(LOGS, "perf-summary.txt"), "w", encoding="utf-8") as f:
        f.write(text)


def table(rows, header):
    cols = [header] + rows
    widths = [max(len(str(r[i])) for r in cols) for i in range(len(header))]
    for r in cols:
        print("  ".join(str(c).ljust(w) if i == 0 else str(c).rjust(w) for i, (c, w) in enumerate(zip(r, widths))))


def when(r):
    """Step start in local time (containers write UTC)."""
    try:
        return datetime.datetime.fromisoformat(str(r.get("ts"))).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return str(r.get("ts", ""))[:16]


def load(args):
    """Step history (local, plus CI files) filtered by --cmd/--step/--commit/--source."""
    hist = read(HISTORY)
    for path in args.ci_file or []:
        hist += read(path)
    keep = []
    for r in hist:
        if args.cmd and r.get("cmd") != args.cmd:
            continue
        if args.commit and not str(r.get("commit", "")).startswith(args.commit):
            continue
        if args.source and r.get("source", "local") != args.source:
            continue
        keep.append(r)
    return keep


def cmd_times(args):
    hist = load(args)
    runs = {}  # run id -> records; lines of runs that overlapped are interleaved in the file
    for r in hist:
        if r.get("kind") not in ("tests", "drive") and "seconds" in r:
            runs.setdefault((r.get("source", "local"), r.get("run")), []).append(r)
    if args.step:
        runs = {k: v for k, v in runs.items() if any(r["step"] == args.step for r in v)}
    runs = list(runs.items())[-args.n:]
    if not runs:
        print(f"no matching history in {HISTORY}" + (" or the CI history" if args.ci_file else ""))
        return
    names = [args.step] if args.step else list(dict.fromkeys(r["step"] for _, rs in runs for r in rs))
    rows = []
    for (source, _), rs in runs:
        by = {r["step"]: r for r in rs}
        cells = ["" if n not in by else f"{by[n]['seconds']:.1f}" + ("" if by[n].get("result") == "ok" else "!") for n in names]
        rows.append([when(rs[0]), source, rs[0].get("cmd", ""), rs[0].get("commit", ""),
                     "cold" if any(r.get("cold") for r in rs) else ""] + cells)
    print(f"last {len(runs)} runs, seconds per step (! = failed):")
    table(rows, ["started", "source", "cmd", "commit", ""] + names)
    print("\nmedian seconds per step (successful, not cold):")
    med = []
    for n in names:
        for source in dict.fromkeys(k[0] for k, _ in runs):
            vals = [r["seconds"] for (src, _), rs in runs if src == source for r in rs
                    if r["step"] == n and r.get("result") == "ok" and not r.get("cold")]
            if vals:
                med.append([n, source, f"{statistics.median(vals):.1f}", len(vals)])
    table(med, ["step", "source", "median", "runs"])
    run_ids = {k[1] for k, _ in runs}
    suites = [r for r in hist if r.get("kind") in ("tests", "drive") and r.get("run") in run_ids
              and (not args.step or r["step"] == args.step)]
    if suites:
        print("\ntest suites (per-test ms):")
        table([[when(r), r.get("source", "local"), r["step"], r.get("count"), r.get("p50"), r.get("p90"), r.get("p99"),
                r.get("max"), f"{r.get('slowest_ms')} {str(r.get('slowest'))[:60]}"] for r in suites],
              ["started", "source", "suite", "tests", "p50", "p90", "p99", "max", "slowest"])


def cmd_trend(args):
    hist = [r for r in read(TEST_HISTORY) if not args.step or r.get("suite") == args.step]
    runs = list(dict.fromkeys(r["run"] for r in hist))[-args.n:]
    if not runs:
        print(f"no history in {TEST_HISTORY}")
        return
    last, started = {}, {}
    for r in hist:
        if r["run"] in runs:
            last.setdefault((r["suite"], r["test"]), {})[r["run"]] = r["ms"]
            started.setdefault(r["run"], when(r)[5:])
    top = sorted(last.items(), key=lambda kv: -max(kv[1].values()))[:args.top]
    print(f"slowest {len(top)} tests over the last {len(runs)} runs (ms, oldest -> newest):")
    rows = [[f"{s}: {t}"[:70]] + [str(v.get(run, "")) for run in runs] for (s, t), v in top]
    table(rows, ["test"] + [started[run] for run in runs])


def cmd_ci_history(args):
    """History lines for the ci-logs branch: one per CI step (from timed.sh) plus the test-suite stats."""
    meta_ci = {"ts": now(), "run": os.environ.get("GITHUB_RUN_ID", "?"), "source": "ci", "worktree": "",
               "commit": os.environ.get("GITHUB_SHA", "unknown")[:7], "cmd": "ci", "image": os.environ.get("ImageOS", ""),
               "cold": False}
    out = []
    try:
        with open(args.times, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3:
                    out.append({**meta_ci, "step": parts[0], "seconds": float(parts[1]),
                                "result": "ok" if parts[2] == "0" else "FAILED"})
    except FileNotFoundError:
        pass
    for r in read(HISTORY):
        if r.get("kind") == "tests":
            out.append({**r, **{k: meta_ci[k] for k in ("run", "source", "worktree", "commit", "cmd")}})
    for r in out:
        print(json.dumps(r, ensure_ascii=False))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="action", required=True)
    for name in ("tests", "drive"):
        s = sub.add_parser(name)
        s.add_argument("suite")
        s.add_argument("path", nargs="+" if name == "tests" else 1)
    for name in ("times", "trend"):
        s = sub.add_parser(name)
        s.add_argument("-n", type=int, default=10, help="number of runs")
        s.add_argument("--step", help="only this step (trend: this suite)")
        if name == "times":
            s.add_argument("--cmd", help="only runs of this command (test, apk, screens, ci, ...)")
            s.add_argument("--commit", help="only this commit (prefix)")
            s.add_argument("--source", choices=["local", "ci"])
            s.add_argument("--ci-file", action="append", help="also read this history file (CI history)")
        else:
            s.add_argument("--top", type=int, default=10)
    s = sub.add_parser("perf")
    s.add_argument("path")
    s = sub.add_parser("ci-history")
    s.add_argument("times")
    s = sub.add_parser("order")
    s.add_argument("names", nargs="+")
    args = p.parse_args()
    if args.action in ("tests", "drive"):
        found = [p for p in args.path if os.path.exists(p)]
        if not found:
            print(f"--- {args.suite}: no test report at {args.path[0]}")
            return 0
        parse = parse_reporter_json if args.action == "tests" else parse_drive_log
        tests, total = [], None
        for path in found:  # shards: the tests add up, and so does the time (seconds of work, not of waiting)
            t, tt = parse(path)
            tests += t
            if tt is not None:
                total = (total or 0) + tt
        record(args.suite, tests, total, args.action)
    elif args.action == "perf":
        cmd_perf(args)
    elif args.action == "order":
        cmd_order(args)
    elif args.action == "times":
        cmd_times(args)
    elif args.action == "trend":
        cmd_trend(args)
    else:
        cmd_ci_history(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
