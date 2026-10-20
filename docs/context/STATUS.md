# Budget Wallet — Status (source of truth since 2026-10-19; no personal figures here)

**Plan (owner, 2026-10-16):** automated tests now → M3 Views → M4 Habits → M5 Polish → web version → cross-device
sync (works on Android, Linux and web) → **M6 live test** by the owner. Platforms: Linux, Android, web.

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
- 2026-10-19: Stage "automated tests" done: core/importer hardening (~290 core tests), Android emulator + Linux desktop
  integration tests (8 files, both platforms), desktop release smoke in CI. Bugs found and fixed: 9 core, rent cash
  threshold as a synced setting, wishlist "24h left", Plan save/stale/negative wait, overflows at 320 dp / text 2.0,
  amounts mid-row on wide windows, synced settings validation, manual-entry matching (only bank rows the adding
  device hadn't seen, deleted targets reopen, no sync churn, matching once per sync), delivery panel currency.
- 2026-10-19: Live mode (`tools/live.sh`: app in Podman on the owner's Wayland desktop, hot reload, screenshots,
  profile traces) + Dart MCP server in the container (`.mcp.json`). Official `dart-flutter` plugin installed.
- 2026-10-19: Agents: feature-builder split into core-builder (Opus/high) and ui-builder (Sonnet/high); model and effort
  set before every orchestration (owner rule).
- 2026-10-19: Planning session (claude.ai): data-flow review, web plan, proposals, 10 UI directions (6 kept). Summary in
  `docs/context/DESIGN_DECISIONS.md`; kept screens in `docs/design/directions/`.
- 2026-10-20: Stage A landed (perf test + budgets, ~450 edge-case tests, 23 bug fixes, € after the amount, live mode).
- 2026-10-20: Stage B: goal contributions as synced rows (`payGoals(period:)`, paid once per period on any device); sync
  bad-file quarantine (`SyncReport.problems`, device-local, survives the schema replay); adaptive layout (rail from 600 dp,
  two columns from 1040, sheets as dialogs, keyboard shortcuts, web-safe platform checks); parallel desktop tests
  (`BW_JOBS`); single-test-file runs (`tools/build.sh app <file>`); bank profiles in the importer (PBZ/Revolut as
  `BankProfile`, `kindHint`/`account`, golden tests prove ids unchanged); run pruning keeps in-progress runs. Bugs fixed:
  month chip scrolled off screen (and the fix scrolling the page), desktop plan test typing a missing folder, payGoals
  defaulting to a stale periodStart. Orchestration runbook `docs/context/PIPELINE.md` (cap 4 agents, token rules).

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
- 2026-10-16: Planning docs copied to git as redacted `docs/context/` (superseded 2026-10-19: git is now the source of truth).
- 2026-10-16: Local builds with rootless Podman, not Docker.
- 2026-10-16: One fixed Android signing key for every build; builds refuse to publish a debug-signed APK.
- 2026-10-16: Milestones after M2: M3 Views → M4 Habits (weekly review, recurring bills, nudges) → M5 Polish (backup/export, search, settings).
- 2026-10-16: Scope: Linux, Android and web. Mac, iPhone, Windows parked (existing CI jobs untouched).
- 2026-10-16: Owner live test moved to M6 (last). Sync must work across devices incl. web: new transport, designed last.
- 2026-10-16: As many automated tests as possible; new shared code stays web-friendly.
- 2026-10-16: Logs at debug level by default during testing; logs never contain amounts, descriptions, merchants, names, keys, paths.
- 2026-10-19: Git `docs/context/` is the source of truth for plan, status, decisions and workflow. The claude.ai Project keeps only personal figures (bank analysis, payday plan); chat sessions there clone the repo and read this file first.
- 2026-10-16: Multi-agent sessions: lead + feature-builder + test-writer in parallel, reviewer before push, ci-watcher after. Still one feature at a time.
- 2026-10-19: Money format: € after the amount with a non-breaking space (`14 €`); design system updated, app `format.dart` still to change.
- 2026-10-19: Numbers keep the current style (decimal point, thousands comma): `+1,450.00 €`; no ISO space grouping, no Croatian `1.250,00`.
- 2026-10-19: Final design direction: **D3 Ledger** (paper, IBM Plex, ruled rows, mono number columns). Applied after the adaptive layout.
- 2026-10-19: Adaptive layout: sheets open as dialogs (≤480 dp) on wide windows; Today and Spending get two columns at ≥1040 dp.
- 2026-10-19: Order after the perf/edge-test stage: € after the amount → adaptive layout → D3 Ledger theme → gap fixes (DESIGN_DECISIONS §2) → bank profiles.
- 2026-10-19: UI directions kept: D1 Baseline, D3 Ledger, D5 Soft Blocks, D6 Receipt, D8 Calendar (+ calendar integration and future spending), D10 Voice First. Parked: D2, D4, D7, D9.
- 2026-10-19: Projects (research projects and ongoing trackers for a car / home server) proposed; they live under the Goals tab. Bank profiles, bills database and calendar/future spending also proposed (not scheduled).

## Open questions for owner
- Test v2 on phone and computer; feedback (✅ / ❌ / ✏️).
- Merge `v2` into `master` once happy (master also has the Docker dev setup).
- Make the repo public? Then all-platform builds are free on every push.

## Known limits
- Importer: v1-compatible rounding changed ids of rows with an exact negative half cent (3-decimal amounts, very rare);
  such rows imported by earlier v2 builds may re-import once as duplicates.
- Manual-entry matching edge cases with two out-of-sync devices: listed in `packages/wallet_core/CLAUDE.md`
  ("Known limits"), to solve in the sync redesign.

## Next
- Owner installs Android APK + desktop build, creates wallet, imports bank files, sets up Syncthing (APKs before the signing
  fix used throwaway keys: uninstall that one once; later updates install in place). After testing: Plan › Diagnostics
  "Save logs…", send the file; summarise with `tools/log-summary.py`.
- Owner checks on the phone after Stage C: Ledger theme at large text (stat strip, stacked rows), bottom bar accent mark,
  dark mode, sheets with the double rule, Plex digits and €; on desktop: rail, two columns, dialogs, margin line.
- Then: merge v2 to master; budget vs actual (after §4.5 approval); M4 Habits.

## In flight (2026-10-20)
- Stage C on branch `stage-c`: D3 Ledger theme (IBM Plex, paper/ink tokens, ruled rows, night ledger) + `kindHint`
  categorizer and generic own-transfer pairing (3 days, cross-source). Review and full run pending, then merge to `v2`.
- Proposal waiting for the owner: budget vs actual per category (DESIGN_DECISIONS.md §4.5).
- Queue and procedure: `docs/context/PIPELINE.md`.
