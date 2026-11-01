# Stage GO design — build tooling in Go (pre-design 2026-11-01, Plan agent on Opus)

Status: ready to start the day Stage UX ends (PIPELINE "Stage GO": GO1 tool, GO2 emulator/live, GO3 CI). Owner
answers to §7 are recorded at the end. Host has `go1.26.10`.

## 1. Goals and non-goals
**Goals.** One static Go binary replaces the build orchestration (build.sh, timing.sh, build_log.py,
stage_summary.py, build-times.sh, ci-status.sh, `.github/scripts/*`; then emulator.sh, live.sh, live_vm.py). Same
commands, steps, logs, status files, history lines and exit codes, proven by a parity test per command. Built in:
`-q`, a log per step, timeouts that kill hung process trees, parallel workers, unit tests. CI slimmed: one composite
setup action, a reusable workflow shared with release.yml, the `log` job as one command, no pipes.
**Non-goals.** No change to what steps do (same flutter/dart commands, Containerfile, image). No new Dart packages.
No Mac/iOS/Windows work. No push or scheduled triggers. No rewrite of the non-build Python (mutate.py,
make_fixtures.py, token-usage.py, log-summary.py, lsp.py, web_shot.py). relay-deploy.sh out of scope.

## 2. The Go tool
**Name/location.** `bwt` (`bw` clashes with the Bitwarden CLI). Own module `tools/bwt/` (`module bwt`, `go 1.26.0`,
`toolchain go1.26.10`), standard library only (no go.sum). Binary `dist/bin/bwt` (git-ignored, one per worktree).
Launcher `tools/bwt.sh` (~20 lines): `GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -o dist/bin/bwt ./` then
`exec` (no-op build when current, ~0.2 s); a failed build exits 3 with the compiler output in `dist/bwt-build.log`.
`bwt version` = embedded VCS stamp + Go version.
**Two levels, kept from bash.** Host `bwt <cmd>`: run dir, image tag, image build, `podman run` (exec of the podman CLI;
same volumes, env list and signing mount, plus `--init` and `--name bwt-<worktree>-<runid>`). Inside:
`/work/dist/bin/bwt <cmd>` with `BW_NATIVE=1`. Static binary (`CGO_ENABLED=0`): a Fedora-glibc binary would not run in
Ubuntu 24.04. CI runs `BW_NATIVE=1` on the runner as now.

**Packages** (`tools/bwt/`)
| package | does |
|---|---|
| `main.go`, `internal/cli` | hand-written args (positional + passthrough), usage (exit 2), quiet, command table |
| `internal/run` | run dir `runs/<YYYYMMDD-HHMMSS>-<cmd>-<commit>[-n]`, `.running`, prune to 30 under `flock(.prune.lock)` (same lock as bash), `dist/logs` link, `last.status`, `last-failed.txt` |
| `internal/step` | `Step{Name, Cmd, Timeout, Cold, Live}`; sequential/parallel runners; log stamps; `<step>.status` = `<secs> <exit> <started>`; process-group kill; secret redaction |
| `internal/history` | `steps.jsonl`, `tests.jsonl`, `perf.jsonl` (one O_APPEND write per line, today's field order, seconds one decimal); `times`, `trend`, `order`, `ci-history` |
| `internal/report` | dart/flutter JSON reporter, drive log, perf records, `tests-<suite>-summary.txt`, percentiles, `stage-summary` |
| `internal/container` | image tag (Flutter version from `app/pubspec.yaml` + 8 hex of sha256 over Containerfile, install-lint-tools.sh, linux-packages.txt), `podman build/run` args, BW_* pass-through, TTY, pod for mcp |
| `internal/pkgs` | pub ready/stale, dart files, format check, LINT/SUITE tables, `:one` runs, analyze, env-selftest |
| `internal/desktop` | headless chain (`timeout`/`dbus-run-session`/`xvfb-run -n`), workers, shards, merge, smoke, perf, jobs from `/proc` |
| `internal/web` | sqlite3mc.wasm fetch + pin check, wasm build with JS fallback, web-test |
| `internal/ci` | `step` (timed.sh), `job-log`, `merge`, `publish-log` (git exec, token scrubbed, 5 retries), `status`/`wait`/`log` (gh api check-runs only), `keystore`, `android-key` |
| `internal/emulator` (GO2) | emulator.sh |
| `internal/live`, `internal/vmservice` (GO2) | live.sh; minimal stdlib WebSocket JSON-RPC client (ports live_vm.py), shot, xshot, trace, forward |

**CLI** (1:1; old spellings keep working through wrappers): `bwt [-q|--quiet] <cmd> …` (`BW_QUIET=1`), commands as
build.sh today (`test lint analyze stage outdated format apk linux relay-bin relay-native-test web web-test all
desktop-test desktop-smoke perf importer|core|sync|relay|app [files] mutate shell image lsp mcp image-name`);
`bwt emulator …`, `bwt live …`, `bwt times …`, `bwt ci status|log|step|job-log|merge|keystore|android-key`,
`bwt log tests|drive|perf` (internal), `bwt version`. No `--json` in GO1: status files are the contract. Env vars as
today; new `BW_STEP_TIMEOUT` and `BW_TIMEOUT_<STEP>`.
**Exit codes.** 0 ok; 1 a step failed; 2 usage; 125–127 podman; 130/137/143 interrupted/killed; `shell -c` returns the
command's code; new 3 = the tool did not build. A timed-out step writes 124 in its `.status`; the run exits 1.
**Quiet.** bwt's stdout/stderr → /dev/null; children never inherit them (log file or /dev/null). `lsp`, `mcp`,
`image-name` exempt (`syscall.Exec` into podman like bash `exec`).
**Files** (paths unchanged): `dist/logs` → run dir with `<step>.log`, `<step>.status`, `last.status` (`<step> ok|failed
<secs>`, start order), `last-failed.txt` (`<step> <ROOT>/dist/logs/<step>.log`, or `run <dir> (exit N, no failed step
recorded)`), `tests-*.json`, `tests-*-summary.txt`, `image-dev.log`, `stage-summary.txt`; history under `BW_DATA_DIR`.
**Timeouts.** `Setpgid` + `Pdeathsig=SIGKILL`; on timeout SIGTERM to the group, 10 s grace, SIGKILL, log line
`# <n>: timed out after N s`. Defaults: lint/analyze 300 s, full suite and `:one` 900 s (app:one took 321.6 s on 2026-10-22), desktop unit + perf 1200 s
(= BW_HEADLESS_TIMEOUT), linux/web 1200 s, apk 2400 s, image 3600 s, mutate and shell none. Host SIGINT/SIGTERM →
`podman stop -t 10 <name>`; `--init` reaps orphans.
**Parallel desktop-test.** One goroutine per worker, `BW_XDISPLAY=100+w`, own copy of `app/` under
`dist/desktop-test/w<N>` (exec'd `tar` keeps mtimes); units from a channel ordered slowest-first by history; `layout`
as 5 shards merged into `desktop-layout`; workers = `BW_JOBS` or min((NumCPU − load)/4, MemAvailable/3 GB, 6) ≥ 1.
Xvfb exec chain kept for parity (direct `-displayfd` later).
**`stage`** re-execs itself per sub-run with `BW_RUN*` env removed; writes `stage-summary.txt` + slowest-10.
**Lint.** New host step `go-check`: `gofmt -l`, `go vet`, `go test ./...`, `go version -m dist/bin/bwt` shows
`CGO_ENABLED=0` (the image has no Go; CI gets it from setup-go). shellcheck keeps the wrappers.
**Unit tests** (no Podman): fake exec runner with golden argument vectors per command; helper processes for timeout kill
of a grandchild, quiet = zero bytes, exit mapping; status/stamp/last.* formats; prune under flock with bash + Go in
parallel; 8 processes × 500 concurrent history appends (all valid JSON); history field order and `12.0`; report-parsing
goldens made once by build_log.py; desktop jobs from fake `/proc`; shard merge; image-tag hash equals bash's; redaction
(no BW_KEYSTORE_PASSWORD value in any log); env-selftest; CI merge goldens (latest.txt lines 3–4, history.jsonl);
usage → 2 for every command.
**Parity tests** (test-writer, from this contract): `tools/bwt/parity/`, build tag `parity`, host
`go test -tags parity -run 'Parity/<case>'`; each case runs `BW_IMPL=bash` and `BW_IMPL=go` into separate temp
`BW_DATA_DIR`s. Compared after masking times/run ids/temp paths: exit code, run-dir file names, `last.status`,
`last-failed.txt`, each `.status` exit, log first/last lines, history lines (all fields but ts/run/seconds), summary
structure, artifact and screenshot name lists, stdout step table. Cases: lint (clean + unformatted), usage errors, `-q`
(test_quiet.sh cases), `core <file>`, `core`, `analyze core app`, `test`, `desktop-test <small>`, `BW_JOBS=2
desktop-test a b layout`, `linux`, `desktop-smoke`, `apk` (local key), `web-test`, `relay-bin x64`, `shell -c 'exit 3'`,
`mutate --list`, `image-name`, an `lsp` initialize round trip, `stage` (once, background); GO2: emulator screens/test,
live start --headless --demo/reload/shot/status/stop. Screenshots compared by file names only (never UI goldens).

## 3. The new CI
**Job graph unchanged.** `lint importer core relay app` parallel, gated by `inputs.tests` (dead `[ci tests]` conditions
dropped: `head_commit` is empty on workflow_dispatch); `desktop` needs `app`; `apk` and `linux` always; `publish` needs
all, condition unchanged plus `!inputs.release`; `log` `if: always()`. No matrix (it would rename check runs and `needs`).
**`.github/actions/setup`** (composite, ~45 lines; inputs `flutter`, `linux-libs`, `android`): setup-go
(`go-version-file: tools/bwt/go.mod`) → `tools/bwt.sh version`, `dist/bin` on `GITHUB_PATH` → flutter-action
(`flutter-version-file: app/pubspec.yaml`, cache) → apt from `dev/linux-packages.txt` (linux-libs) → android:
`bwt ci android-key` (NDK version/paths, replaces `grep -oP`) + Gradle/NDK/CMake cache, key
`android-<ndk>-<hash of gradle files + pubspec.lock>`. Checkout stays a job step.
**`.github/actions/job-log`** (~20 lines): `bwt ci job-log --job J --outcomes "…"` → outcome.txt, times.txt, ci.log,
history.jsonl, then upload `ci-log-<job>`.
**A job (~10 lines):**
```yaml
  core:
    if: ${{ inputs.tests }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup
        with: { linux-libs: true }
      - { id: core, run: bwt ci step core -- bwt core }
      - { id: sync, if: '!cancelled()', run: bwt ci step sync -- bwt sync }
      - uses: ./.github/actions/job-log
        if: always()
        with: { job: core, outcomes: "core=${{ steps.core.outcome }} sync=${{ steps.sync.outcome }}" }
```
**apk:** `bwt ci keystore` decodes `ANDROID_KEYSTORE_BASE64` to `$RUNNER_TEMP/release.jks`, sets `BW_KEYSTORE` (missing
secret → exit 1 + `::error::`, key never printed); then `bwt ci step apk -- bwt apk` (`BW_APK_ABIS=arm64`, password/alias
from env). Adds the local keytool signature check to CI; the `| tail -40` pipes go.
**linux:** `bwt linux` then `bwt desktop-smoke`; tarball packed on success on any ref.
**log job:** `bwt ci merge --artifacts "$RUNNER_TEMP/logs" --needs-json '${{ toJSON(needs) }}' --publish "${{
inputs.release && 'release-android-linux' || 'latest' }}"`; canonical job list in Go; latest.txt layout unchanged (line
3 step outcomes with seconds, line 4 job results); history.jsonl appended.
**Reusable workflow.** ci.yml: `workflow_dispatch` (input `tests`) + `workflow_call` (inputs `tests`, `release`; secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` declared, no `secrets: inherit`).
release.yml (~138 → ~90): `build: uses: ./.github/workflows/ci.yml` with `{tests: false, release: true}`; Windows/Apple
jobs as they are; dead `gate`/`SHOULD_RUN` removed. Concurrency group `ci-${{ github.workflow }}-${{ github.ref }}` (a
called workflow sees the caller's name, so release never cancels a running ci).
**Caching:** Flutter SDK + pub (flutter-action), Gradle/NDK/CMake (as today), Go (setup-go, go.mod hash). No image
layers (CI stays native). A separate tool-build job was rejected (serializes every job).
**Secrets:** env only, masked; keystore in `$RUNNER_TEMP`; bwt redacts BW_KEYSTORE_PASSWORD, BW_KEY_PASSWORD and
GH_TOKEN values in everything it writes; `publish-log` scrubs the token from git output.
**Sizes:** ci.yml ~356 → ~150–165; actions/setup ~45; job-log ~20; release.yml ~90; `.github/scripts/` deleted.

## 4. Migration (rollback at every step)
- **M0 skeleton:** `tools/bwt/`, `tools/bwt.sh`, `bwt version`, unit-test scaffold, `go-check`; nothing switched.
  ci.yml sets `BW_IMPL: bash` until GO3 (runners have no setup-go yet).
- **M1 switch per command:** top of build.sh: `case "${BW_IMPL:-auto}:$cmd" in go:*|auto:<ported list>) exec
  "$ROOT/tools/bwt.sh" "$@";; esac`, bash body untouched below. `BW_IMPL=bash` = instant rollback for one run,
  `BW_IMPL=go` = try the new one. A command joins the ported list only when its parity case passes.
- **M2 order:** (1) `bwt times`, `bwt ci status` (read-only); (2) build_log.py subcommands in the container; (3) run
  machinery + `lint` + `-q`; (4) package suites, `:one`, `analyze`, `test`, `format`, `shell`; (5) `lsp`, `mcp`,
  `image`, `image-name`; (6) `apk`, `linux`, `desktop-smoke`; (7) `desktop-test`; (8) `perf`, `web`, `web-test`,
  `mutate`, `outdated`, `relay-bin`, `relay-native-test`; (9) `all`, `stage`.
- **M3 flip:** `auto` covers every command; soak one stage (one green `bwt stage` + the owner's next `ci` with tests,
  still bash in CI). Rollback: one-line revert of the list.
- **M4 (GO2):** same scheme for `bwt emulator`, `bwt live`; live_vm.py stays until `live` passes parity.
- **M5 (GO3):** new CI in one commit on a branch; the owner runs `gh workflow run ci --ref go3 -f tests=true` (publish
  only on v2, so safe) and one release; compare latest.txt lines 3–4 and history with the last bash run; merge, drop
  `BW_IMPL: bash`. Rollback: revert that commit (`.github/scripts` deleted only in M6).
- **M6 cleanup** (after one more green stage + CI): delete the bash bodies, build_log.py, stage_summary.py, live_vm.py,
  `.github/scripts/*`; keep the entry scripts as 3-line `exec` wrappers; keep timing.sh while web.sh sources it; update
  CLAUDE.md, devops.md, PIPELINE.
- **Worktrees:** each builds its own `dist/bin/bwt`; a worktree from before M1 is pure bash; `BW_DATA_DIR` formats and
  the prune lock are shared, so mixed runs are safe. From GO1 start no build.sh edits outside the GO agents (an
  unavoidable one gets a parity case).

## 5. Risks → tests
1. Binary won't run in Ubuntu 24.04 (glibc/cgo) → `CGO_ENABLED=0`, `go-check`, `image-name` parity runs `bwt version` in
   the container. 2. History format drift → goldens vs bash/Python lines; `bwt times` reads both. 3. Concurrent appends
   and prune across worktrees/versions → multi-process append test, mixed prune on one lock. 4. Leaked processes
   (flutter, Gradle, Xvfb) → group-kill unit test; parity case killing `desktop-test` mid-run, `podman ps` empty, status
   124/143. 5. Quiet leaks → zero-bytes test; test_quiet.sh on both. 6. stdio/TTY for shell/lsp/mcp → `syscall.Exec`;
   LSP round trip; `.mcp.json` start checked by hand once. 7. Secrets in logs → redaction test; apk parity greps the run
   dir; CI log grep in M5. 8. Desktop scheduling differences → compare sets and results, not order/seconds.
   9. Reusable-workflow details (concurrency, artifacts across the call, secrets, permissions) → actionlint + the
   owner's branch ci and release in M5. 10. Go missing/mismatched → `GOTOOLCHAIN=local`, exit 3; CI pins via
   `go-version-file`. 11. Env pass-through drift → env-selftest checks the Go list. 12. Stale binary in a worktree →
   launcher always builds; test that `bwt version` revision = HEAD.

## 6. Delegation (cap 4; scout first; reviewer before push)
| # | agent | model/effort | worktree | order | output |
|---|---|---|---|---|---|
| GO-0 | scout | haiku/low | – | 1 | every file format with examples, env list, command table + line ranges |
| GO1-T | test-writer | sonnet/medium | A | 2 ∥ | `tools/bwt/parity/` + goldens, green as bash vs bash first |
| GO1-D | devops | sonnet/high | B | 2 ∥ | M0–M2: packages + unit tests, the `BW_IMPL` switch |
| GO1-W | watcher | haiku/low | lead checkout | 3 | full parity + `stage` in background; failing cases only |
| GO1-R | reviewer | session/high | – | 4 | whole GO1 diff before the M3 flip commit and push |
| GO2-D | devops | sonnet/high | C | 5 | emulator, live, vmservice |
| GO2-T | test-writer | sonnet/medium | D | 5 ∥ | emulator/live parity |
| GO3-D | devops | sonnet/medium | E | 5 ∥ | CI files; actionlint green; handed to the owner for the branch run |
| GO-R | reviewer + watcher | as above | – | 6 | GO2+GO3 review, one full run, then M6 cleanup (devops sonnet/medium) |

Facts: CI does not use Podman today (`BW_NATIVE=1` on flutter-action; the apk job calls `flutter build apk` directly);
`tools/web.sh` sources `timing.sh`; `[ci tests]` conditions never match on dispatch; called workflows see the caller's
`github.workflow`. The lead never starts a workflow; the owner runs ci and release in M5.

## 7. Open questions (★ = recommended) and owner answers
1. Tool name: ★ `bwt` · `bw` · `wallet-build`.
2. Old entry points at the end: ★ keep build.sh, emulator.sh, live.sh, build-times.sh, ci-status.sh as 3-line wrappers ·
   delete and call `tools/bwt.sh` · delete and put `bwt` on PATH.
3. Bash bodies deleted: ★ after one green stage + one green CI on bwt · after two stages · never.
4. Go dependencies: ★ standard library only · also golang.org/x/sys, x/term · any vetted module with go.sum + licence check.
5. Go version: ★ `go 1.26.0`, `toolchain go1.26.10`, raised with the host · `go 1.25` · always latest.
6. relay-deploy.sh: ★ stays bash · moves in GO2 · later stage.
7. Python/small bash helpers: ★ move only build_log.py, stage_summary.py, live_vm.py · also mutate.py and web.sh · all.
8. CI build environment: ★ runner directly as today · the dev image in CI via GHCR · image only for desktop and linux.
9. Scheduled CI: ★ none (manual only) · weekly with tests · nightly.
10. release.yml: ★ separate file calling ci.yml; Windows/Apple jobs left · same but delete Windows/Apple · fold into ci.yml.
11. Step timeouts: ★ on, table above, env overrides · only BW_HEADLESS_TIMEOUT · medians × 4.

**Owner answers (2026-11-01)** — these override the ★ defaults above where they differ:
1. Name **`wallet-build`** (module `tools/wallet-build/`, binary `dist/bin/wallet-build`; read `bwt` above as
   `wallet-build`).
2. **A `Makefile` at the repo root is the entry point and the old scripts are deleted** (no wrappers): every command
   becomes a make target (`make test`, `make lint`, `make app T=test/x_test.dart`, `make desktop-test N="a b"`,
   `make live-start ARGS=--demo`, `make emulator-screens`, `make ci-status`, …) that builds and calls `wallet-build`;
   `Q=1` (or `make -s … Q=1`) = quiet. CLAUDE.md, `.mcp.json`, the no-poll hook, agent files and PIPELINE switch to
   make targets in M6.
3. Bash bodies deleted **after two stages** (each with one green stage run) **and** one green CI on wallet-build.
4. Go deps: standard library **plus `golang.org/x/sys` and `golang.org/x/term`** (go.sum committed; nothing else).
5. Go `1.26.0`, `toolchain go1.26.10`, raised with the host.
6. `relay-deploy.sh` **stays bash** (the only tool left as a script besides the Makefile).
7. **Everything else in tools/ moves into Go** (owner: "everything"): build_log.py, stage_summary.py, live_vm.py,
   mutate.py, make_fixtures.py, log-summary.py, token-usage.py, lsp.py, web_shot.py, relay.sh, web.sh,
   relay-native-test.sh, make-signing-key.sh, timing.sh, build-times.sh, ci-status.sh, test_quiet.sh → subcommands
   (`wallet-build mutate|fixtures|log-summary|token-usage|lsp|web …|relay …|signing-key`). Order: after GO1/GO2 as
   GO4 (helpers), each with a parity or golden test; make_fixtures output must stay byte-identical (seeded).
8. CI on the **runner directly**, as today.
9. **No scheduled CI** (manual only).
10. **release.yml stays separate and reuses ci.yml** (`workflow_call`); Windows/Apple jobs left as they are.
11. **Step timeouts on** with the defaults in §2, env overrides `BW_STEP_TIMEOUT` / `BW_TIMEOUT_<STEP>`.

**GO4 owner answers (2026-11-01 evening):**
12. `make_fixtures.py` → Go: JSON/XML/CSV fixtures byte-identical (CPython MT19937 + `randrange`/`uniform`/`getrandbits`
    reproduced); the PDFs are regenerated once with Go's zlib (same decoded content, the importer tests prove it); the two
    Excel fixtures (`pbz_synthetic.xls`, `revolut_synthetic.xlsx`) stay committed as they are and are no longer generated.
13. `no-poll-hook.sh` → `wallet-build hook no-poll` (same pattern, same `--self-test`); the lead points
    `.claude/settings.json` at it once the Go self-test passes.

**GO4 command names (fixed for builders and tests):** `fixtures <out_dir> [all|banks|bills|generic]`,
`mutate …` (container side replaces mutate.py; same flags), `token-usage [--since D] [--until D] [--json F]`,
`log-summary <file>…`, `lsp-query refs|def <path:line:col>…` (`lsp` stays the server), `web-shot <url> <out.png> <W>x<H>
[wait]` (container side), `relay start|stop|status|logs [-f]|reset|image`, `web serve [port]|stop|status|shot <path>
<out.png> [WxH]`, `relay-native-test [fedora|debian]` (port of the script body), `relay-native-check`, `signing-key
[--upload]`, `times …`/`trend …` (build-times.sh flags incl. `--ci`), `ci status [--wait] [sha]` / `ci log [name]`
(ci-status.sh, incl. `--log`), `hook no-poll [--self-test]`; test_quiet.sh becomes a Go parity test. The old scripts stay
until M6 (deleted after the green go3 CI); `timing.sh` stays while build.sh's bash body and the run_test oracle use it.
