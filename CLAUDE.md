# Budget Wallet — notes for Claude

## Privacy (hard rule)
This repo holds **code only**. Never commit bank exports, statements, real transactions, balances,
salary/rent/loan figures, merchant lists derived from the owner's spending, keys or seed data.
- Real numbers live only in the user's local wallet database (and v1's artifact database).
- Personal merchant rules live in the `merchantPatterns` setting; built-in rules cover only well-known chains and brands.
- Test fixtures are synthetic: `tools/make_fixtures.py` generates them. Plan, status, decisions and workflow live in `docs/context/` (source of truth; read `docs/context/STATUS.md` first). Personal figures live only in the claude.ai Project; keep them out of git.

## Layout
- `app/` — Flutter app (Android, iOS, Windows, macOS, Linux).
- `packages/wallet_importer/` — bank files → normalized transactions. The only code that knows bank formats.
- `relay/` — the sync relay server (pure Dart, stores sealed sync files; `relay/CLAUDE.md`, protocol in `docs/context/RELAY_PROTOCOL.md`); `tools/relay.sh` runs it locally in Podman, `dev/Containerfile.relay` builds its image.
- `packages/wallet_core/` — SQLite repo, change log + HLC, encrypted folder sync, categories, budget engine.
- `artifact/` — v1 single-file web app (claude.ai artifact) and its JS tests (`npm test`).
- `docs/architecture.md`, `docs/setup.md`.
- Each package has its own short `CLAUDE.md` (files, rules, how to test). Read the one for the code you touch.
- `tools/` — `build.sh` (local builds, lint, format, LSP, MCP), `emulator.sh`, `live.sh` + `live_vm.py`, `build-times.sh` + `build_log.py` +
  `timing.sh` (run logs and timing history), `ci-status.sh` (CI results), `make-signing-key.sh`, `install-hooks.sh`,
  `make_fixtures.py`, `log-summary.py` (summary of an app log), `token-usage.py` (Claude token use per day/session/model/commit,
  from local transcripts). `dev/` — `Containerfile` and `install-lint-tools.sh`.
- **App logs:** the app logs to `<app support dir>/logs/bw-YYYY-MM-DD.log` (debug level by default while testing; Plan ›
  Diagnostics changes the level and saves all logs as one file). `tools/emulator.sh screens` also writes
  `dist/logs/app-emulator.log`. Read one with `python3 -I tools/log-summary.py <file>`; logs the owner sends go in
  `~/.local/share/budget-wallet/device-logs/`. Logs must never contain amounts, descriptions, merchants, notes,
  names, the key, paths or file names (see package `CLAUDE.md`s).

## Local builds (owner's laptop)
`tools/build.sh test|lint|format|relay|apk|linux|desktop-test|desktop-smoke|perf|web|web-test|all|shell|lsp` runs the CI steps in a rootless **Podman** container
(not Docker), image from `dev/Containerfile`, Flutter version pinned by `environment: flutter:` in `app/pubspec.yaml`
(CI reads the same line). Outputs land in `dist/` (git-ignored). Run `tools/build.sh test` before pushing.
The release APK is 64-bit only: `--target-platform` plus `packaging.jniLibs.excludes` in `app/android/app/build.gradle.kts` (the ML Kit AARs ship armeabi-v7a libs anyway). Local `tools/build.sh apk` keeps arm64 + x86_64 (~86 MB) so `tools/emulator.sh install` works; `BW_APK_ABIS=arm64` (set in ci.yml and release.yml, so the published APK) drops x86_64 too (~44 MB).
The scripts assume a Linux host: Bash 5, GNU tools (`grep -P`, `sha256sum`, `base64 -w0`), Python 3, Podman.
Mac, iPhone, Windows and web are out of scope for now (owner's decision): don't spend effort on them.
- **Mutation testing:** `tools/build.sh mutate <importer|core> <lib file>… [--max N --seed S --tests <test file>…]` (`tools/mutate.py`) runs a seeded sample of one-token mutants against the package tests and lists survivors; results in `dist/mutation/`.
- **One test file:** `tools/build.sh core|importer|app <test file or dir>…` runs only those tests (paths relative to the package or repo root; no analyze; step `<pkg>:one`, kept apart from full-suite medians); `tools/build.sh shell -c '<command>'` runs a command non-interactively in the container.
- **Logs and timings** are kept outside the repo in `~/.local/share/budget-wallet/` (`BW_DATA_DIR`), shared by all
  worktrees and never committed: `runs/<time>-<cmd>-<commit>/` (step logs, image build logs, emulator log, test
  reports, screenshots; newest 30 kept; `dist/logs` links to this worktree's latest run, so `dist/logs/<step>.log`
  works), `history/steps.jsonl` and `history/tests.jsonl` (append-only timings per step and per test),
  `device-logs/` (reserved for app logs). Each run ends with a seconds-per-step table and per-test p50/p90/max.
  `tools/build-times.sh [--ci] [--step app]` shows recent runs and medians, `tools/build-times.sh trend` the slowest
  tests; CI appends its own lines to `history.jsonl` on the `ci-logs` branch.
- `test` = `lint` + analyze (infos are fatal) + tests. `lint` = `dart format` check, shellcheck, actionlint (fast).
  Unformatted code fails: run `tools/build.sh format`. Shared analyzer/lint/formatter rules (page width 140) are in
  the root `analysis_options.yaml`; fix lints rather than ignoring them, tune the rule there if one is wrong for us.
- `tools/build.sh lsp` is a Dart language server over stdin/stdout (container, repo at the same path).
  `tools/install-hooks.sh` adds an opt-in pre-commit hook running `lint`.
- **See the app:** `tools/emulator.sh screens` boots an Android emulator (Podman + /dev/kvm, `dev/Containerfile.emulator`),
  runs `app/integration_test/screens_test.dart` with a synthetic demo wallet and saves every tab to `dist/screens/*.png`
  — read them to check UI changes before pushing. `start`/`install`/`shot`/`adb`/`stop` drive a running emulator.
  The emulator, system image and AVD live in Podman volumes (`bw-emulator*`), set up once (~2 GB download, then a
  cold boot saved as a snapshot); runs boot that snapshot read-only in ~3 s. `tools/emulator.sh reset` starts over.
  Known emulator 37.x limits: renderer `lavapipe`, and Flutter runs with `--no-enable-impeller` (Impeller trips an
  abort in the emulator's GLES decoder); real phones use Impeller.
- **Linux desktop:** `tools/build.sh desktop-test [name…]` runs `app/integration_test/*_test.dart` on the Linux app under
  Xvfb in the build container (screenshots `dist/screens/linux/<test>/`, log `dist/logs/app-linux-<test>.log`; desktop
  screenshots come from `integration_test/flutter_test_config.dart`). Files run in parallel on `BW_JOBS` workers (default
  min(idle cores/4, free RAM/3 GB, 6); `BW_JOBS=1` = one after another in `app/`), each in its own copy of `app/` under
  `dist/desktop-test/w<N>` (delete it to reset) with its own Xvfb display; `layout` runs as 5 shards. Android-only tests must skip themselves on
  desktop. `tools/build.sh desktop-smoke` starts the release bundle headless and checks its log. CI is manual only (see below).
  Ubuntu packages: `dev/linux-packages.txt` (image and CI).
- **Frame performance:** `tools/build.sh perf` runs `app/integration_test/perf_test.dart` in profile mode on the Linux app
  under Xvfb (`flutter drive --profile`; big synthetic wallet, Spending scroll + tab switches), saves each action's
  `<action>.timeline.json` (DevTools/Perfetto) and `.timeline_summary.json` in the run's logs, appends `history/perf.jsonl`
  and fails on budget overruns (`app/test_driver/perf_budget.dart`). Not in `test`/`all`/CI. It rebuilds the profile bundle from scratch each time (stale build state after a killed run made `flutter drive` stall after "Built"); a headless step that hangs is killed after 20 min (`BW_HEADLESS_TIMEOUT`). Software GL under Xvfb: raster
  numbers are not a GPU's.
- **Web (local only, never published):** `tools/build.sh web` builds `flutter build web --wasm` (JS fallback) into `dist/web/` (fetches `sqlite3.wasm`, pinned in `dev/sqlite3-wasm.sha256`, git-ignored); `tools/web.sh serve|stop|status` serves it on 127.0.0.1, `tools/web.sh shot <path> <out.png>` screenshots it with the image's Chrome; `tools/build.sh web-test` runs `app/test/web/` with `flutter test --platform chrome`.
- **Live mode (fast UI work):** `tools/live.sh start [--demo] [--headless] [--profile] [--fresh]` runs `flutter run -d linux`
  in the container in the background (window on the owner's desktop; `--demo` = synthetic demo wallet). Then
  `reload`, `restart`, `shot [file]`, `trace start|stop [name]` (timeline + frame summary in the run dir; use
  `--profile` for real numbers), `status`, `stop`. Wallet data is a throwaway folder in `dist/live/`, never the real one.
  File pickers work: a portal + GTK backend run on the container's private bus (nothing from the host bus); the dialog sees
  only the container (repo, this run's logs, `history/`; not `device-logs/`) and `/files` = `~/.local/share/budget-wallet/live-files`
  (copy test bank files in; saved logs land there).
  The `dart` MCP server (`.mcp.json` → `tools/build.sh mcp`, same pod) reaches it: `dtd` tool, `connect` with the dtd
  URI from `tools/live.sh status`, then `hot_reload`, `get_runtime_errors`, `widget_inspector`. **Privacy:** the
  window uses the Wayland socket only (never X11). Drive the app only through the VM service / MCP server, never
  host input tools (xdotool, ydotool, uinput); screenshots only from `tools/live.sh shot`, never a host screen grab.
Android release builds are signed with one fixed key (`tools/make-signing-key.sh`, kept in
`~/.config/budget-wallet/`, CI secrets `ANDROID_KEYSTORE_*`) so updates install over the app without wiping
the wallet. Never commit or print the key or its password; never fall back to debug signing for a published APK.

**Flutter/Dart skills:** the official `dart-flutter` plugin (flutter/agent-plugins) is installed. Use its skills'
guidance, but there is no Flutter/Dart on the host: run every `flutter`/`dart` command through `tools/build.sh`
(or `tools/build.sh shell`) and `tools/emulator.sh`, never directly. Keep this repo's own choices (no Riverpod,
go_router, mockito/build_runner or new packages unless the owner asks).

## Building without a local Flutter SDK (cloud sessions)
A cloud Claude workspace cannot download Flutter/Dart. **Nothing runs on push** (owner, 2026-10-21): the owner starts the
`ci` workflow by hand when a release is ready (`gh workflow run ci --ref v2`, or the Actions tab). It builds what the laptop
does not verify: jobs `apk` (signed release APK), `linux` (release bundle + smoke test), `publish` (dev release when run
on `v2`) and `log`. Lint, importer/core/app tests and the desktop tests run only with the `tests` input (jobs `lint`,
`importer`, `core`, `app`, `desktop`; `publish` then waits for them and is skipped if one fails). `release.yml` (all
platforms, `dev-all`) is manual too. Claude never starts a workflow; cloud sessions without Flutter report that the change is
unverified and ask the owner to run `ci` with `tests`. Each job runs on its own runner and stores its log as an artifact; the `log` job merges them and pushes the result to
the `ci-logs` branch:
`git fetch origin ci-logs:refs/remotes/origin/ci-logs && git show origin/ci-logs:latest.txt`
(line 3 = step outcomes with seconds, line 4 = job results). `tools/ci-status.sh [--wait] [<sha>]` shows the check runs.
Job status: `gh api repos/marcelicmateo/buggetwallet/commits/<sha>/check-runs`. The Actions API itself is blocked.

## Conventions
- Amounts are integers in minor units (cents). Dates are `YYYY-MM-DD` strings.
- All writes go through `WalletRepo._write` so they become sync ops; never write tables directly.
- Transaction ids must stay compatible with v1 (`transactionId` in wallet_importer).

## Team (subagents in `.claude/agents/`)
The main session is the lead: it takes the owner's request, splits it, merges results, runs
`tools/build.sh test`, commits, pushes and updates STATUS. **Cap: 4 agents at once.** On each agent report the lead reads
`docs/context/PIPELINE.md` (queue, dependencies, token rules, stage procedure), marks the item and starts the next ready one if a slot is free. One feature at a time; the owner tests at the end (2026-10-19), so stages go on without waiting for owner checks.
- `core-builder` — logic half: `wallet_core` / `wallet_importer` + unit tests, own worktree (`isolation: "worktree"`).
- `ui-builder` — UI half: `app/` screens, widgets, controller wiring, widget tests; iterates in live mode.
  For a feature with both halves, the lead fixes the core API (names, params, result fields) in both specs and
  runs them in parallel; UI-only or core-only work uses just one.
- `scout` — haiku/low, read-only: before each builder/test-writer, returns a context pack (files, line ranges, APIs, tests)
  that goes into the brief, so builders don't explore the codebase themselves (token rule in PIPELINE.md).
- `test-writer` — writes tests from the spec in parallel, without basing them on the implementation.
- `reviewer` — read-only review of the diff before every push.
- `ci-watcher` — waits for a CI run the owner started and reports the result (`tools/ci-status.sh`); not used after pushes.
- `devops` — only for build, CI, signing or version work.
**Model and effort first (owner rule):** before starting agents, check each one's `model:` and `effort:` in its
`.claude/agents/*.md` frontmatter and fit them to the task (cheapest that does the job well; current defaults:
scout and ci-watcher haiku/low, test-writer and devops sonnet/medium, ui-builder sonnet/high, core-builder and reviewer high
on the session model).
Agents without a file (general-purpose, Explore, Plan) get `model` set on the Agent call. Say the choice in one line.
Owner bug reports go before new features. **Bugs are fixed as soon as they're found** (owner rule), in the same
stage: a test that reproduces the bug (may start as `skip: 'BUG: …'`) plus the fix that makes it pass. Agents that
find bugs outside their own scope report them to the lead immediately (SendMessage to "main").
While test agents are writing tests, the lead only collects bugs. When all of them are done: merge, one low-effort
test-watcher run (haiku/low) lists failures and `BUG:` skips, then the lead plans the fixes and runs them.
**Resources (owner rule):** agents share one laptop. While developing, run only the targeted check
(`tools/build.sh core|importer|app|lint`, a single test file, `tools/emulator.sh test <name>`) and batch changes
before each run. Full `tools/build.sh test` and full emulator/desktop runs happen once per agent at the end, and the
lead runs the complete verification once per **stage** (several features/test sets merged together), not per change.
**No polling (owner rule):** never wait with `sleep`/`until` loops on local work. Start long commands with `run_in_background`
and wait for the completion notification; to wait for another process use the Monitor tool. Only CI (external) is checked
on an interval (`tools/ci-status.sh`).

## Workflow
Owner sends one request or piece of feedback (often by voice: keep replies short). Claude builds,
verifies locally (`tools/build.sh test`, desktop, emulator), commits code, pushes and updates `docs/context/STATUS.md`; CI runs only when the owner starts it. No copy back to the claude.ai Project is needed;
it holds only personal figures (payday plan, bank analysis) and is updated only when one of those changes.
