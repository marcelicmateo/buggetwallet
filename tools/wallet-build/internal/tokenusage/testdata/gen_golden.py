"""Builds testdata/home (SYNTHETIC Claude Code transcripts, no real ones) and testdata/cases.json: what tools/token-usage.py prints
for them. Run from the repo root on a host with git:

    python3 -I tools/wallet-build/internal/tokenusage/testdata/gen_golden.py

The script creates a throw-away git repo and HOME in a temp dir, runs the real tools/token-usage.py there, and stores the stdout,
the exit code, the --json file and the number of lines `git log` printed. The Go test copies testdata/home to a temp HOME, runs
the Go port for the same arguments (git faked with the stored line count) and compares.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, *[".."] * 5))
PROJECT = "PROJECT"  # directory name inside .claude/projects; the generator and the test map it to the real mangled name


def line(rid, ts, model, out, inp=1, cw=0, cr=0, typ="assistant", mid=None, extra=None):
    rec = {"type": typ, "timestamp": ts, "requestId": rid, "message": {"id": mid or ("msg_" + str(rid)), "model": model,
           "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr, "output_tokens": out}}}
    if rid is None:
        del rec["requestId"]
    if model is None:
        del rec["message"]["model"]
        rec["requestedModel"] = "claude-requested-x"
    if extra:
        rec.update(extra)
    return json.dumps(rec)


MAIN1 = [
    line("r1", "2026-10-20T08:00:00.000Z", "claude-opus-x", 5, inp=10, cw=1000, cr=2000),  # first block of r1: 5 output
    line("r1", "2026-10-20T08:00:01.000Z", "claude-opus-x", 1500, inp=10, cw=1000, cr=2000),  # final count wins
    line("r1", "2026-10-20T08:00:02.000Z", "claude-opus-x", 40, inp=10, cw=1000, cr=2000),  # a smaller later line is ignored
    line("r2", "2026-10-20T23:59:59.999Z", "claude-sonnet-x", 700, inp=3, cw=0, cr=123456),
    line("r3", "2026-10-21T00:00:00.000Z", "claude-sonnet-x", 700, inp=1, cw=5, cr=7),  # same output as r2: model order is stable
    line(None, "2026-10-21T10:00:00.000Z", "claude-haiku-x", 90, inp=2, mid="m_noreq"),  # no requestId: message id is the key
    line(None, "2026-10-21T10:00:01.000Z", "claude-haiku-x", 95, inp=2, mid="m_noreq"),
    line("r4", "2026-10-22T12:00:00.000Z", None, 12, inp=4, cw=8, cr=16),  # model from requestedModel
    line("r5", "2026-10-22T12:00:00.000Z", "claude-opus-x", 3000000, inp=1234567, cw=89012345, cr=678901234),  # big numbers
    line("r6", "2026-10-23T09:00:00.000Z", "mödel-ünï-x", 1, inp=0),  # non-ASCII model name (the JSON file escapes it)
    json.dumps({"type": "user", "timestamp": "2026-10-20T08:00:00.000Z", "message": {"content": "has \"usage\" in text", "usage": {"output_tokens": 99}}}),
    json.dumps({"type": "assistant", "timestamp": "2026-10-20T08:00:00.000Z", "requestId": "r7", "message": {"usage": {}}}),  # empty usage
    json.dumps({"type": "system", "timestamp": "2026-10-20T08:00:00.000Z", "requestId": "r8", "message": {"usage": {"output_tokens": 1}}}),
    "this line mentions \"usage\" but is not JSON",
    json.dumps({"type": "assistant", "requestId": "r9", "message": {"model": "claude-opus-x", "usage": {"output_tokens": None, "input_tokens": None}}}),  # no timestamp
    line("r10", "2026-10-24T00:00:00.000Z", "claude-opus-x", 8, inp=1) + "\r",  # a CRLF line
]
MAIN2 = [
    line("q1", "2026-10-21T15:00:00.000Z", "claude-opus-x", 250, inp=5, cw=10, cr=20),
    line("q2", "2026-10-22T15:00:00.000Z", "claude-haiku-x", 60, inp=6, cw=0, cr=1),
]
AGENT1 = [
    line("a1", "2026-10-21T11:00:00.000Z", "claude-haiku-x", 33, inp=7, cr=1000),
    line("a2", "2026-10-22T11:00:00.000Z", "claude-sonnet-x", 44, inp=8, cw=3),
]
AGENT2 = [line("a3", "2026-10-20T11:00:00.000Z", "claude-haiku-x", 22, inp=9)]

SID1 = "0123abcd-1111-2222-3333-444455556666"
SID2 = "feedbeef-1111-2222-3333-444455556666"


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(lines) + "\n")


def build_home(home, project_name):
    p = os.path.join(home, ".claude", "projects", project_name)
    write(os.path.join(p, SID1 + ".jsonl"), MAIN1)
    write(os.path.join(p, SID2 + ".jsonl"), MAIN2)
    write(os.path.join(p, SID1, "subagents", "agent-a.jsonl"), AGENT1)
    write(os.path.join(p, SID1, "subagents", "agent-b.jsonl"), AGENT2)
    write(os.path.join(p, ".hidden.jsonl"), [line("h1", "2026-10-20T08:00:00.000Z", "claude-opus-x", 999999)])  # glob skips dot files
    write(os.path.join(p, "notes.txt"), ["not a transcript"])


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def main():
    tmp = tempfile.mkdtemp()
    try:
        env = dict(os.environ, HOME=os.path.join(tmp, "home"), TZ="UTC", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
        repo = os.path.join(tmp, "repo.d")  # a dot in the path: it becomes '-' in the project dir name
        os.makedirs(repo)
        gitenv = dict(env, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        run(["git", "init", "-q", repo], env=gitenv)
        for i, day in enumerate(["2026-10-19T12:00:00", "2026-10-20T12:00:00", "2026-10-21T12:00:00", "2026-10-21T13:00:00", "2026-10-23T12:00:00", "2026-10-25T12:00:00"]):
            open(os.path.join(repo, "f"), "w").write(str(i))
            run(["git", "-C", repo, "add", "f"], env=gitenv)
            run(["git", "-C", repo, "commit", "-q", "-m", "c%d" % i], env=dict(gitenv, GIT_AUTHOR_DATE=day + " +0000", GIT_COMMITTER_DATE=day + " +0000"))
        repo = os.path.realpath(repo)
        mangled = repo.replace("/", "-").replace(".", "-")
        build_home(env["HOME"], mangled)
        shutil.rmtree(os.path.join(HERE, "home"), ignore_errors=True)
        build_home(os.path.join(HERE, "home"), PROJECT)

        cases = []

        def case(name, args, json_file=None, home=None, fix_since=None):
            e = dict(env, HOME=home or env["HOME"])
            a = list(args)
            out_json = None
            if json_file:
                out_json = os.path.join(tmp, json_file)
                a += ["--json", out_json]
            r = run(["python3", "-I", os.path.join(ROOT, "tools", "token-usage.py")] + a, env=e, cwd=repo)
            stdout = r.stdout.replace(out_json, "{JSON}") if out_json else r.stdout
            stdout = stdout.replace(os.path.join(e["HOME"], ".claude", "projects", mangled), "{PDIR}")
            c = {"name": name, "args": args, "json": bool(json_file), "exit": r.returncode, "stdout": stdout, "stderr": r.stderr.replace(e["HOME"], "{HOME}").replace(mangled, "{MANGLED}")}
            if json_file:
                c["json_text"] = open(out_json, encoding="utf-8").read()
            # the commits line comes from this git call; the Go test fakes git with the same number of lines
            days = [l for l in r.stdout.splitlines() if l.startswith("  commits on this branch in ")]
            if days:
                rng = days[0].split(" in ")[1].split(":")[0]
                a1, b1 = rng.split("..")
                if a1 != "-":
                    g = run(["git", "log", "--oneline", "--since=%s 00:00" % a1, "--until=%s 23:59:59" % b1], cwd=repo, env=gitenv)
                    c["git_args"] = ["log", "--oneline", "--since=%s 00:00" % a1, "--until=%s 23:59:59" % b1]
                    c["git_stdout"] = g.stdout
            cases.append(c)

        case("all", [], "all.json")
        case("window", ["--since", "2026-10-21", "--until", "2026-10-22"], "window.json")
        case("since-only", ["--since", "2026-10-22"])
        case("until-only", ["--until", "2026-10-20"], "until.json")
        case("empty-range", ["--since", "2030-01-01"], "empty.json")
        empty_home = os.path.join(tmp, "empty-home")
        os.makedirs(empty_home)
        case("no-transcripts", [], home=empty_home)
        out = {"project": PROJECT, "cases": cases}
        with open(os.path.join(HERE, "cases.json"), "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1, ensure_ascii=False)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


main()
