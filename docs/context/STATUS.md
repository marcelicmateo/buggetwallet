# Budget Wallet — Status (redacted copy, 2026-10-16)

**Current milestone:** M2 Standalone app — v2.0 first builds published for all platforms (branch `v2`), waiting for owner testing. v1 web app still live.

**v2 downloads (GitHub releases, private repo):**
- All platforms: release tag `dev-all` (Android .apk, Linux .tar.gz, Windows .zip, macOS .zip unsigned, iPhone .ipa unsigned)
- Android + Linux, updated on every v2 push: release tag `dev`

**v1 app link:** https://claude.ai/artifact/BNYCWfCudgsreWnmXuhLfG (private: owner-only read/write db rules)

**Local builds:** `tools/build.sh test|apk|linux|all` in rootless Podman (`dev/Containerfile`), same steps and Flutter version (3.47.7, pinned in `app/pubspec.yaml`) as CI.

## v2 (standalone app) — what's built
- `packages/wallet_importer` (pure Dart): PBZ .xls via own BIFF8 reader, Revolut .xlsx/.csv → normalized transactions, v1-compatible ids. 10 tests, synthetic fixtures.
- `packages/wallet_core`: SQLite, field-level change log with hybrid logical clock (last writer wins), XChaCha20-Poly1305 encrypted sync files in a Syncthing folder (each device writes only its own subfolder), wallet key as `BW1-…` text + QR, budget engine ported from v1. 13 tests incl. two-device sync and wrong-key refusal.
- `app` (Flutter 3.47): onboarding (new wallet / join with key), Today, Spending (fl_chart), Wishlist, Goals, Plan (numbers, start month, import files, sync folder, show key). Analyze clean, tests pass.
- CI (`.github/workflows/ci.yml`): tests + analyze + Android/Linux builds on every push; publishes `dev` release from v2. `release.yml`: all 5 platforms on master, tags `v*`, or commits containing `[release]`; publishes a release. Logs on `ci-logs` branch.
- 2026-10-16 commit a20d0e6: all jobs green; `dev-all` and `dev` releases published.

## Done
- 2026-10-15: Workflow defined; brief started.
- 2026-10-16: Budgeting strategy approved; bank exports + loan plan analysed (figures in the Project only).
- 2026-10-16: Payday plan locked (figures in the Project and the owner's wallet settings).
- 2026-10-16: M1 app v1 published and seeded with history, settings and goals.
- 2026-10-16: GitHub repo connected; v1 code committed (personal defaults removed, merchant rules moved to db).
- 2026-10-16: Docker dev environment committed on master (650fd40).
- 2026-10-16: v2 standalone app built on branch `v2`; all platform builds green and published as releases.
- 2026-10-16: Project context docs copied (redacted) to `docs/context/` for Claude Code.
- 2026-10-16: master merged into v2. Local Podman builds; CI pinned to the same Flutter version.
- 2026-10-16: Fixed Android release signing key (local + CI secrets), backed up by the owner in 1Password. APKs now update in place.
- 2026-10-16: Android emulator in Podman (screenshot test with synthetic wallet); dev tooling (lint, format, LSP, hooks).
- 2026-10-16: App-wide logging + perf diagnostics (privacy-redacted, tested); build/test timing history and speedups.
- 2026-10-16: M3 started: saving or losing per pay period with savings rate and trend line (built + independently tested by agents, reviewed).
- 2026-10-16: Agent team set up (`.claude/agents/`: feature-builder, test-writer, reviewer, ci-watcher, devops), per-package CLAUDE.md, `tools/ci-status.sh`.

## Decisions log
- 2026-10-15: v1 as claude.ai web-app artifact with its own database; single user; EUR default.
- 2026-10-16: Strategy: pay yourself first + sinking funds + daily safe-to-spend + impulse cooling-off.
- 2026-10-16: Impulse threshold €50, cooling-off 72h (adjustable). Pace A — strict from day one.
- 2026-10-16: All employer payments = salary; planning figure = normal month; tax refunds/other = extras → goals.
- 2026-10-16: Budget period = salary-to-salary (salary lands 10th–15th).
- 2026-10-16: Rent = large ATM cash withdrawal (threshold in settings, auto-tagged). Other ATM cash counts as spending when withdrawn.
- 2026-10-16: PBZ → Revolut top-ups = internal transfers.
- 2026-10-16: Code in private GitHub repo; code only. Each session ends with tests + commit + push.
- 2026-10-16: Owner often works by voice: short spoken-friendly replies, one change at a time.
- 2026-10-16: v2 = standalone Flutter app (Android, iPhone, Windows, macOS, Linux), offline first, own SQLite database.
- 2026-10-16: Bank formats decoupled: importer package is the only code that knows them; app consumes only the wallet database.
- 2026-10-16: Sync via Syncthing shared folder (option D), end-to-end encrypted; importer runs on edge devices.
- 2026-10-16: All-platform builds only on master / tags / `[release]` commits (macOS minutes bill 10x on private repos); Android + Linux on every push.
- 2026-10-16: permission_handler dropped (needs compileSdk 37); small Android channel opens the All files access setting.
- 2026-10-16: Planning docs copied to git as redacted `docs/context/`; the claude.ai Project stays the source of truth.
- 2026-10-16: Local builds with rootless Podman, not Docker.
- 2026-10-16: One fixed Android signing key for every build; builds refuse to publish a debug-signed APK.
- 2026-10-16: Milestones after M2: M3 Views → M4 Habits (weekly review, recurring bills, nudges) → M5 Polish (backup/export, search, settings).
- 2026-10-16: Scope: Linux laptop + Android only; Mac, iPhone, Windows and web parked (existing CI jobs untouched).
- 2026-10-16: Logs at debug level by default during testing; logs never contain amounts, descriptions, merchants, names, keys, paths.
- 2026-10-16: Multi-agent sessions: lead + feature-builder + test-writer in parallel, reviewer before push, ci-watcher after. Still one feature at a time.

## Open questions for owner
- Test v2 on phone and computer; feedback (✅ / ❌ / ✏️).
- Merge `v2` into `master` once happy (master also has the Docker dev setup).
- Make the repo public? Then all-platform builds are free on every push.

## Next
- Owner installs Android APK + desktop build, creates wallet, imports bank files, sets up Syncthing.
  Note: APKs before the signing fix used throwaway keys — uninstall that one once; later updates install in place.
- Owner tests M3 "Saving or losing" on the Spending tab: bars per pay period (salary to salary), savings rate,
  3-period trend line. Paydays come from salary payments; a missing month assumes the payday setting.
- Logging is in: app-wide logs (debug level while testing), perf (startup, frames, timings, memory), Plan › Diagnostics
  "Save logs…". Owner: after testing, save logs and send the file; summarise with `tools/log-summary.py`.
- Fixed: Today and the "Salary landed" banner now start the period on the first salary part (same paydays as the chart).
- Then: merge v2 to master; budget vs actual and top merchants.
