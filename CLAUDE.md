# Budget Wallet — notes for Claude

## Privacy (hard rule)
This repo holds **code only**. Never commit bank exports, statements, real transactions, balances,
salary/rent/loan figures, merchant lists derived from the owner's spending, keys or seed data.
- Real numbers live only in the user's local wallet database (and v1's artifact database).
- Personal merchant rules live in the `merchantPatterns` setting; built-in rules cover only well-known chains and brands.
- Test fixtures are synthetic: `tools/make_fixtures.py` generates them. Planning docs live in the claude.ai Project; redacted copies are in `docs/context/` (read `docs/context/STATUS.md` first). Keep personal figures out of them.

## Layout
- `app/` — Flutter app (Android, iOS, Windows, macOS, Linux).
- `packages/wallet_importer/` — bank files → normalized transactions. The only code that knows bank formats.
- `packages/wallet_core/` — SQLite repo, change log + HLC, encrypted folder sync, categories, budget engine.
- `artifact/` — v1 single-file web app (claude.ai artifact) and its JS tests (`npm test`).
- `docs/architecture.md`, `docs/setup.md`.
- Each package has its own short `CLAUDE.md` (files, rules, how to test). Read the one for the code you touch.
- `tools/` — `build.sh` (local builds, lint, format, LSP, MCP), `emulator.sh`, `live.sh` + `live_vm.py`, `build-times.sh` + `build_log.py` +
  `timing.sh` (run logs and timing history), `ci-status.sh` (CI results), `make-signing-key.sh`, `install-hooks.sh`,
  `make_fixtures.py`, `log-summary.py` (summary of an app log). `dev/` — `Containerfile` and `install-lint-tools.sh`.
- **App logs:** the app logs to `<app support dir>/logs/bw-YYYY-MM-DD.log` (debug level by default while testing; Plan ›
  Diagnostics changes the level and saves all logs as one file). `tools/emulator.sh screens` also writes
  `dist/logs/app-emulator.log`. Read one with `python3 -I tools/log-summary.py <file>`; logs the owner sends go in
  `~/.local/share/budget-wallet/device-logs/`. Logs must never contain amounts, descriptions, merchants, notes,
  names, the key, paths or file names (see package `CLAUDE.md`s).

## Local builds (owner's laptop)
`tools/build.sh test|lint|format|apk|linux|desktop-test|desktop-smoke|all|shell|lsp` runs the CI steps in a rootless **Podman** container
(not Docker), image from `dev/Containerfile`, Flutter version pinned by `environment: flutter:` in `app/pubspec.yaml`
(CI reads the same line). Outputs land in `dist/` (git-ignored). Run `tools/build.sh test` before pushing.
The scripts assume a Linux host: Bash 5, GNU tools (`grep -P`, `sha256sum`, `base64 -w0`), Python 3, Podman.
Mac, iPhone, Windows and web are out of scope for now (owner's decision): don't spend effort on them.
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
  screenshots come from `integration_test/flutter_test_config.dart`). Android-only tests must skip themselves on
  desktop. `tools/build.sh desktop-smoke` starts the release bundle headless and checks its log. CI runs both.
  Ubuntu packages: `dev/linux-packages.txt` (image and CI).
- **Live mode (fast UI work):** `tools/live.sh start [--demo] [--headless] [--profile] [--fresh]` runs `flutter run -d linux`
  in the container in the background (window on the owner's desktop; `--demo` = synthetic demo wallet). Then
  `reload`, `restart`, `shot [file]`, `trace start|stop [name]` (timeline + frame summary in the run dir; use
  `--profile` for real numbers), `status`, `stop`. Wallet data is a throwaway folder in `dist/live/`, never the real one.
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
A cloud Claude workspace cannot download Flutter/Dart. Push to `v2` (or `master`); CI runs tests, analyze and
builds, then pushes the full log to the `ci-logs` branch:
`git fetch origin ci-logs:refs/remotes/origin/ci-logs && git show origin/ci-logs:latest.txt`.
Job status: `gh api repos/marcelicmateo/buggetwallet/commits/<sha>/check-runs`. The Actions API itself is blocked.

## Conventions
- Amounts are integers in minor units (cents). Dates are `YYYY-MM-DD` strings.
- All writes go through `WalletRepo._write` so they become sync ops; never write tables directly.
- Transaction ids must stay compatible with v1 (`transactionId` in wallet_importer).

## Team (subagents in `.claude/agents/`)
The main session is the lead: it takes the owner's request, splits it, merges results, runs
`tools/build.sh test`, commits, pushes and updates STATUS. One feature at a time (the owner tests each one).
- `core-builder` — logic half: `wallet_core` / `wallet_importer` + unit tests, own worktree (`isolation: "worktree"`).
- `ui-builder` — UI half: `app/` screens, widgets, controller wiring, widget tests; iterates in live mode.
  For a feature with both halves, the lead fixes the core API (names, params, result fields) in both specs and
  runs them in parallel; UI-only or core-only work uses just one.
- `test-writer` — writes tests from the spec in parallel, without basing them on the implementation.
- `reviewer` — read-only review of the diff before every push.
- `ci-watcher` — waits for CI after a push and reports the result (`tools/ci-status.sh`).
- `devops` — only for build, CI, signing or version work.
**Model and effort first (owner rule):** before starting agents, check each one's `model:` and `effort:` in its
`.claude/agents/*.md` frontmatter and fit them to the task (cheapest that does the job well; current defaults:
ci-watcher haiku/low, test-writer and devops sonnet/medium, ui-builder sonnet/high, core-builder and reviewer high
on the session model).
Agents without a file (general-purpose, Explore, Plan) get `model` set on the Agent call. Say the choice in one line.
Owner bug reports go before new features. **Bugs are fixed as soon as they're found** (owner rule), in the same
stage: a test that reproduces the bug (may start as `skip: 'BUG: …'`) plus the fix that makes it pass. Agents that
find bugs outside their own scope report them to the lead immediately (SendMessage to "main").
**Resources (owner rule):** agents share one laptop. While developing, run only the targeted check
(`tools/build.sh core|importer|app|lint`, a single test file, `tools/emulator.sh test <name>`) and batch changes
before each run. Full `tools/build.sh test` and full emulator/desktop runs happen once per agent at the end, and the
lead runs the complete verification once per **stage** (several features/test sets merged together), not per change.

## Workflow
Owner sends one request or piece of feedback (often by voice: keep replies short). Claude builds,
gets CI green, commits code, and updates STATUS.md in the claude.ai Project and `docs/context/STATUS.md` (redacted).
