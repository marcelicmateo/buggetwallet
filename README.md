# Budget Wallet

Personal finance tracker and budgeting app for one person. Offline first, runs on Android, iPhone, Windows, macOS and Linux, and syncs between your devices through Syncthing with end-to-end encryption.

## What it does
- Imports bank exports: PBZ (.xls) and Revolut (.xlsx / .csv), plus quick manual entry for card payments.
- Home screen shows one number: **safe to spend today**, which rolls over day to day until payday.
- Payday plan: salary minus bills minus savings goals = spending money.
- Wishlist with a cooling-off period for impulse buys, and a "Can I afford it?" check.
- Goals for big purchases and an emergency fund.
- Views: saving or losing per month, where the money goes by category, top places.

## Structure
- `app/` — Flutter app
- `packages/wallet_importer/` — bank file importer (pure Dart, synthetic test fixtures)
- `packages/wallet_core/` — local database, change log, encrypted sync, budget engine
- `artifact/` — v1 web app (claude.ai artifact), kept for reference
- `docs/architecture.md` — how it fits together
- `docs/setup.md` — install, first run, Syncthing setup

## Privacy
This repo holds **code only**. Bank exports, statements, keys and any real transaction data must never be committed. `.gitignore` blocks the common export formats; only synthetic fixtures under `test/fixtures` are allowed.

## Development
Builds run in a rootless [Podman](https://podman.io) container, so Podman is the only thing to install.
The scripts need a Linux host with Bash 5+ (they use `EPOCHREALTIME`, `mapfile`, associative arrays), GNU tools
(`grep -P`, `sha256sum`, `base64 -w0`), Python 3 and Podman; macOS hosts are not supported.
The script runs the same steps as CI.

```sh
tools/make-signing-key.sh       # once: the Android signing key, kept in ~/.config/budget-wallet/
tools/install-hooks.sh          # once, optional: pre-commit hook that runs `tools/build.sh lint`
tools/build.sh test             # lint, then importer + core + app: analyze and tests
tools/build.sh lint             # quick: Dart format check, shellcheck, actionlint
tools/build.sh format           # reformat Dart code (dart format)
tools/build.sh apk              # Android APK   -> dist/BudgetWallet-android.apk
tools/build.sh linux            # Linux bundle  -> dist/BudgetWallet-linux-x64.tar.gz
tools/build.sh desktop-test     # integration tests on the Linux desktop app (Xvfb) -> dist/screens/linux/<test>/
tools/build.sh desktop-test screens   # only app/integration_test/screens_test.dart
tools/build.sh desktop-smoke    # build the Linux bundle, start it headless with an empty HOME for 10 s, check its log
tools/build-times.sh            # recent build/test timings and medians (trend: slowest tests)
tools/build.sh all              # tests, then both builds
tools/build.sh shell            # shell inside the container
tools/build.sh lsp              # Dart language server for your editor (stdin/stdout)
tools/emulator.sh screens       # Android emulator: demo wallet (fake data), screenshot of every tab -> dist/screens/
tools/emulator.sh start --window  # an emulator on your desktop; then `install`, `shot <name>`, `stop`
```

- The first run builds the image (~15 min).
- **Logs and timings** live outside the repo, in `~/.local/share/budget-wallet/` (override with `BW_DATA_DIR`),
  shared by every worktree and never committed to a code branch:
  - `runs/<YYYYMMDD-HHMMSS>-<cmd>-<commit>/`: one folder per run with each step's log (start/end stamps), image
    build logs, the emulator log, test reports and per-test timing summaries, screenshots. The newest 30 are kept.
    `dist/logs` is a link to this checkout's latest run.
  - `history/steps.jsonl`, `history/tests.jsonl`: one JSON line per step / per test per run, append-only.
  - `device-logs/`: reserved for logs exported from the app.

  Every run prints seconds per step and per-test p50/p90/p99/max. `tools/build-times.sh` shows the last runs and
  the median per step (`--step app`, `--commit`, `--ci` adds CI's history from the `ci-logs` branch);
  `tools/build-times.sh trend` shows the slowest tests over time.
- **Linux desktop tests** run in the same container on a virtual display (Xvfb, Mesa software OpenGL, a private
  D-Bus session). `desktop-test` runs every `app/integration_test/*_test.dart` with `flutter test -d linux`, each file
  with its own empty wallet folder; screenshots go to `dist/screens/linux/<test>/` and the app's log to
  `dist/logs/app-linux-<test>.log`. On desktop, `binding.takeScreenshot()` is served by
  `app/integration_test/flutter_test_config.dart` (the integration_test plugin only captures on Android/iOS); a test
  that only makes sense on Android should skip itself. `desktop-smoke` unpacks the release tarball and checks that it
  starts, logs `app.start` with no SEVERE line and exits on SIGTERM. CI runs both (`BW_NATIVE=1`); the Ubuntu
  packages for this are listed once in `dev/linux-packages.txt` (image and CI).
- The first `tools/emulator.sh` run downloads the emulator and system image (~2 GB) into Podman volumes and saves a
  clean-boot snapshot; later runs boot from it in seconds. `tools/emulator.sh reset` deletes them.
- **Code style.** `dart format` with page width 140, and stricter analyzer rules (strict casts/inference/raw
  types plus extra lints) shared by the app and both packages in the root `analysis_options.yaml`. Infos fail the
  build too. Shell scripts are checked by shellcheck, workflows by actionlint; both are pinned in
  `dev/install-lint-tools.sh`, which the container image and CI both use, so local and CI results match.
- **Editor.** Point your editor's Dart LSP client at `tools/build.sh lsp` (for example Neovim, Helix, Zed, Emacs).
  It runs the analysis server in the container with the repo mounted at the same path, so diagnostics, completion
  and format-on-save need no local SDK. Jumping into SDK or pub package sources does not work (those live in the
  container). The VS Code Dart extension needs a local Flutter SDK and can't use this. `.editorconfig` covers the basics.
- `.git-blame-ignore-revs` hides the bulk reformat from blame: `git config blame.ignoreRevsFile .git-blame-ignore-revs`.
- **Back up `~/.config/budget-wallet/`** (a password manager is fine). Every APK must be signed with that key, or
  Android refuses the update and the app has to be uninstalled, which deletes the wallet on the phone.
- CI signs with the same key from GitHub secrets: run `tools/make-signing-key.sh --upload` once.
- iPhone / macOS builds need a Mac with Xcode. CI builds every platform on `master`, tags, or `[release]` commits.

## Milestones
- M0 Setup
- M1 Core (v1 web app)
- M2 Standalone app: offline database, encrypted Syncthing sync, importer — in progress
- M3 More views and graphs
- M4 Polish
