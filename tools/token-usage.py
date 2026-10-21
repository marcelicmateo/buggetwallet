#!/usr/bin/env python3
"""Token usage of Claude Code sessions in this repo, from the local transcripts.

Reads ~/.claude/projects/<repo dir>/*.jsonl (main sessions) and */subagents/*.jsonl (agents),
counts each API request once (by requestId) and prints totals per day, per session and per model,
plus tokens per commit on the current branch. Only counts and ids are read; no message text.

  python3 -I tools/token-usage.py [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--json FILE]
"""

import argparse
import collections
import glob
import json
import os
import subprocess
import sys

FIELDS = ("input", "cache_write", "cache_read", "output")


def project_dir(repo):
    return os.path.expanduser("~/.claude/projects/" + repo.replace("/", "-").replace(".", "-"))


def requests(path):
    # One request is logged as several lines (one per content block); only the last has the final output count,
    # so keep the line with the most output tokens per requestId.
    best = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"usage"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            msg = rec.get("message") or {}
            usage = msg.get("usage")
            rid = rec.get("requestId") or msg.get("id")
            if not usage or rec.get("type") != "assistant":
                continue
            if rid not in best or (usage.get("output_tokens") or 0) > best[rid][1].get("output_tokens", 0):
                best[rid] = (rec, usage)
    for rec, usage in best.values():
        msg = rec["message"]
        yield {
            "day": (rec.get("timestamp") or "")[:10],
            "model": msg.get("model") or rec.get("requestedModel") or "?",
            "input": usage.get("input_tokens") or 0,
            "cache_write": usage.get("cache_creation_input_tokens") or 0,
            "cache_read": usage.get("cache_read_input_tokens") or 0,
            "output": usage.get("output_tokens") or 0,
        }


def add(acc, r):
    for k in FIELDS:
        acc[k] += r[k]
    acc["requests"] += 1


def new():
    return collections.Counter()


def table(title, rows):
    print(f"\n{title}")
    print(f"  {'':38} {'requests':>9} {'input':>10} {'cache_wr':>12} {'cache_rd':>14} {'output':>11} {'total':>14}")
    for name, a in rows:
        total = sum(a[k] for k in FIELDS)
        print(f"  {name:38} {a['requests']:>9,} {a['input']:>10,} {a['cache_write']:>12,} {a['cache_read']:>14,} {a['output']:>11,} {total:>14,}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="")
    ap.add_argument("--until", default="9999")
    ap.add_argument("--json", help="also write the summary to this file")
    args = ap.parse_args()

    repo = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    pdir = project_dir(repo)
    by_day, by_session, by_model, total = (collections.defaultdict(new), collections.defaultdict(new), collections.defaultdict(new), new())
    sessions = sorted(glob.glob(os.path.join(pdir, "*.jsonl")))
    if not sessions:
        sys.exit(f"no transcripts in {pdir}")
    for main_file in sessions:
        sid = os.path.basename(main_file)[:-6]
        files = [(main_file, "main")] + [(p, "agent") for p in sorted(glob.glob(os.path.join(pdir, sid, "subagents", "*.jsonl")))]
        for path, kind in files:
            for r in requests(path):
                if not (args.since <= r["day"] <= args.until):
                    continue
                for acc in (by_day[r["day"]], by_session[f"{sid[:8]} {kind}"], by_model[r["model"]], total):
                    add(acc, r)

    days = sorted(by_day)
    commits = 0
    if days:
        out = subprocess.run(["git", "log", "--oneline", f"--since={days[0]} 00:00", f"--until={days[-1]} 23:59:59"],
                             capture_output=True, text=True, cwd=repo).stdout
        commits = len(out.splitlines())

    table("Per day", sorted(by_day.items()))
    table("Per session (main = lead, agent = subagents)", sorted(by_session.items()))
    table("Per model", sorted(by_model.items(), key=lambda kv: -kv[1]["output"]))
    table("Total", [("all", total)])
    grand = sum(total[k] for k in FIELDS)
    print(f"\n  commits on this branch in {days[0] if days else '-'}..{days[-1] if days else '-'}: {commits}")
    if commits:
        print(f"  per commit: {grand // commits:,} tokens, {total['output'] // commits:,} output, {total['requests'] // commits:,} requests")

    if args.json:
        summary = {
            "range": [days[0], days[-1]] if days else [],
            "commits": commits,
            "total": dict(total),
            "per_day": {k: dict(v) for k, v in sorted(by_day.items())},
            "per_session": {k: dict(v) for k, v in sorted(by_session.items())},
            "per_model": {k: dict(v) for k, v in by_model.items()},
        }
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=1)
        print(f"\n  wrote {args.json}")


if __name__ == "__main__":
    main()
