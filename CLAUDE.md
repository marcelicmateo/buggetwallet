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
- `tools/` — `build.sh` (local builds, lint, format, LSP), `ci-status.sh` (CI results), `make-signing-key.sh`,
  `install-hooks.sh`, `make_fixtures.py`. `dev/` — `Containerfile` and `install-lint-tools.sh` (pinned linters).

## Local builds (owner's laptop)
`tools/build.sh test|lint|format|apk|linux|all|shell|lsp` runs the CI steps in a rootless **Podman** container
(not Docker), image from `dev/Containerfile`, Flutter version pinned by `environment: flutter:` in `app/pubspec.yaml`
(CI reads the same line). Outputs and logs land in `dist/` (git-ignored). Run `tools/build.sh test` before pushing.
- `test` = `lint` + analyze (infos are fatal) + tests. `lint` = `dart format` check, shellcheck, actionlint (fast).
  Unformatted code fails: run `tools/build.sh format`. Shared analyzer/lint/formatter rules (page width 140) are in
  the root `analysis_options.yaml`; fix lints rather than ignoring them, tune the rule there if one is wrong for us.
- `tools/build.sh lsp` is a Dart language server over stdin/stdout (container, repo at the same path).
  `tools/install-hooks.sh` adds an opt-in pre-commit hook running `lint`.
- **See the app:** `tools/emulator.sh screens` boots an Android emulator (Podman + /dev/kvm, `dev/Containerfile.emulator`),
  runs `app/integration_test/screens_test.dart` with a synthetic demo wallet and saves every tab to `dist/screens/*.png`
  — read them to check UI changes before pushing. `start`/`install`/`shot`/`adb`/`stop` drive a running emulator.
  Known emulator 37.x limits: renderer `lavapipe`, and Flutter runs with `--no-enable-impeller` (Impeller trips an
  abort in the emulator's GLES decoder); real phones use Impeller.
Android release builds are signed with one fixed key (`tools/make-signing-key.sh`, kept in
`~/.config/budget-wallet/`, CI secrets `ANDROID_KEYSTORE_*`) so updates install over the app without wiping
the wallet. Never commit or print the key or its password; never fall back to debug signing for a published APK.

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
- `feature-builder` — builds the feature (core logic + UI) in its own worktree (`isolation: "worktree"`).
- `test-writer` — writes tests from the spec in parallel, without basing them on the implementation.
- `reviewer` — read-only review of the diff before every push.
- `ci-watcher` — waits for CI after a push and reports the result (`tools/ci-status.sh`).
- `devops` — only for build, CI, signing or version work.
Owner bug reports go before new features.

## Workflow
Owner sends one request or piece of feedback (often by voice: keep replies short). Claude builds,
gets CI green, commits code, and updates STATUS.md in the claude.ai Project and `docs/context/STATUS.md` (redacted).
