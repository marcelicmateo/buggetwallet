# Budget Wallet — Status (source of truth since 2026-10-19; no personal figures here)

**Plan (owner, 2026-10-16):** automated tests now → M3 Views → M4 Habits → M5 Polish → web version → cross-device
sync (works on Android, Linux and web) → **M6 live test** by the owner. Platforms: Linux, Android, web.

**Current milestone:** M2 Standalone app — v2.0 first builds published for all platforms (branch `v2`), waiting for owner testing. v1 web app still live.

**Sync:** relay (stage R, 2026-10-22); Syncthing is no longer used. Hosting: owner chose a Hetzner Cloud server (2026-10-24, guide docs/setup.md §6; not set up yet), home server (§5) stays documented.

**v2 downloads (GitHub releases, private repo):**
- All platforms: release tag `dev-all` (Android .apk, Linux .tar.gz, Windows .zip, macOS .zip unsigned, iPhone .ipa unsigned)
- Android + Linux, updated on every v2 push: release tag `dev`

**v1 app link:** https://claude.ai/artifact/BNYCWfCudgsreWnmXuhLfG (private: owner-only read/write db rules)

**Local builds:** `tools/build.sh test|apk|linux|all` in rootless Podman (`dev/Containerfile`), same steps and Flutter version (3.47.7, pinned in `app/pubspec.yaml`) as CI.

## v2 (standalone app) — what's built
- `packages/wallet_importer` (pure Dart): PBZ .xls via own BIFF8 reader, Revolut .xlsx/.csv → normalized transactions, v1-compatible ids. 10 tests, synthetic fixtures.
- `packages/wallet_core`: SQLite, field-level change log with hybrid logical clock (last writer wins), XChaCha20-Poly1305 encrypted sync files in a Syncthing folder (each device writes only its own subfolder), wallet key as `BW1-…` text + QR, budget engine ported from v1. 13 tests incl. two-device sync and wrong-key refusal.
- `app` (Flutter 3.47): onboarding (new wallet / join with key), Today, Spending (fl_chart), Wishlist, Goals, Plan (numbers, start month, import files, sync folder, show key). Analyze clean, tests pass.
- CI is **manual only** since 2026-10-21 (owner: no runs until a release is ready). `ci.yml` (start on `v2`: signed APK, Linux bundle + smoke, `dev` release; `tests` input adds lint/unit/desktop jobs) and `release.yml` (all 5 platforms, `dev-all`) run from the Actions tab or `gh workflow run ci --ref v2`. Logs on `ci-logs` branch.
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
- 2026-10-20: Stage C: **D3 Ledger theme** (six IBM Plex fonts +1.1 MB, OFL; paper/ink tokens with a contrast test; ruled
  Panel/SectionHead/TotalRule/TxHeaderRow/MoneyText; night ledger follows the system; margin line at x=22 from 600 dp;
  theme tests at three widths, dark, text scale 2.0); `kindHint` categorizer + generic own-transfer pairing (equal
  amounts across sources within 3 days, deterministic, schema 3); controller totals; perf step on a bus without
  activatable services + 20-min timeout (two hung runs today); run pruning keeps in-progress runs. Full run: unit 509/596/193,
  desktop 10 files, emulator screens green.
- 2026-10-20: Own-transfer pairing made exact (owner rule: never reclassify on amount alone): a pair needs a bank-hinted
  side, exchanges never pair, old loose pairs dissolve (schema 4). perf step rebuilt from clean state after a hang.
- 2026-10-20: **M3 Budget vs actual per category** (monthly): `categoryBudgets` synced setting, Plan › Budgets per
  category editor with "Suggest from the last 6 months", Spending rows with budget mark / "47.50 € left" / "over by" +
  hatch / "behind pace", summary line and budgeted total, Today line for the tightest budget. Exact amounts
  (`moneyExact`), one 6-month average for tick and suggestions. Core 637 / app 541 tests, desktop and emulator green.
- 2026-10-20: **M4 Habits**: weekly review (Today card from the review day until done, 4-step review screen: import,
  confirm categories, pace, wishlist; streak), expected bills (detected from the bank rows, confirmed by the owner only,
  Plan › Expected bills with Confirm / Not a bill / Paid / Overdue / Skip this cycle / Remove; confirmed flex-category
  bills are reserved from safe-to-spend, fixed-category ones are "covered by your plan"; Today "Due by payday" line),
  review day per user (Mon–Sun chips), nudges (Android, `flutter_local_notifications`, 15:00 weekdays + Sunday 11:00,
  funny lines without amounts or names, device-local switch). Review fixes before merge: next due date follows the paying
  row (no drift), confirmed bill category follows merchant rules, streak resets on a skipped week, skip action for an
  unmatched bill. Schema 5. Core 687 / app 593 tests, desktop and emulator green.
- 2026-10-20: **M5 Polish**: Plan › Backup ("Back up now" writes an encrypted `bw-backup-<date>.bwb` into the sync folder's
  `budget-wallet/backups/`, one per day; "Restore from backup…" only while the wallet is empty; a restored wallet syncs out
  with its original clocks, so other devices see no change), Plan › Export (transactions CSV for this period / this year /
  everything and a monthly summary CSV, cleaned data, exact decimals, saved through the system dialog with a UTF-8 BOM for
  spreadsheets), search over transactions, goals, wishlist and expected bills (Spending icon or Ctrl+F; text with accent
  folding, or an exact amount such as `12,50`). Core 770 / app 634 tests. CI now builds only the APK, the Linux bundle and
  the dev release (test jobs on demand with `[ci tests]`), each as its own job.
- 2026-10-21: `v2` (M4 Habits + M5 Polish, 4b16240) merged into `master` by fast-forward (owner request). That push still ran
  `release.yml` for all five platforms (about 133 billed minutes: macOS 10x, Windows 2x); since then a master push builds only
  the APK and Linux bundle in `ci.yml`, and Windows/macOS + `dev-all` need a `v*` tag, `[release]` or a manual start.
- 2026-10-21: **Stage W: web version (localhost only).** `wallet_core` barrel compiles with dart2js + dart2wasm (io code
  behind conditional exports; gzip via `archive`, old phone sync files still unseal); app runs in a browser: SQLite wasm on
  IndexedDB, wallet key wrapped by a passphrase (PBKDF2 310000), memory logs + download, Backup download/upload, "Forget this
  browser", unlock screen, one tab at a time (Web Lock; a second tab shows "open in another tab"); no sync or nudges on web.
  `tools/build.sh web|web-test`, `tools/web.sh serve|shot` (127.0.0.1 only). Fixed in stage: nudge slots already past in the
  phone zone failed the whole schedule; unpinned sqlite3.wasm no longer pinned on first download. Full run green (app 707,
  core 789, importer 193, desktop 25, web smoke, perf 0 missed frames). First stage with `scout` context packs.
- 2026-10-22: **Stage R: sync redesign** (spec DESIGN_DECISIONS §4.9, protocol `RELAY_PROTOCOL.md`). A self-hosted
  **relay** (`relay/`, pure Dart, Podman image `dev/Containerfile.relay`, `tools/relay.sh`, setup in `docs/setup.md` §5)
  replaces the Syncthing folder on every device incl. web; it stores only sealed files, auth by a token derived from the
  wallet key. `SyncEngine` + `RelayTransport`/`MemoryTransport`: files apply strictly in order per device, matching and
  transfer pairing (also on local imports) run only when caught up, snapshots (7 days / 500 ops) with relay pruning
  (both kept snapshots + acks of devices seen in 90 days), uploads split into ≤8 MiB parts, a stuck peer is unstuck by a
  snapshot from any caught-up device after 24 h. Fixes known limits S1/S2. **Local database encrypted** (sqlite3 3.x +
  SQLite3MultipleCiphers on Android, Linux, web) with a key derived from the wallet key; old wallets convert on first
  start (crash-safe side copy); the database opens only once the key is known; a file the key does not open is set
  aside, never deleted or merged. App: Plan › Sync (relay address, test connection, status, devices), join with key +
  relay address, backups and logs through the save dialog, no storage permissions (Android: INTERNET + cleartext for
  LAN/VPN). Review: 0 high, 3 medium, 5 low, all fixed with tests. Full run: importer 193, core 882, relay 99, app 755,
  desktop 12 files (incl. relay_sync), web 9, perf 0 missed frames, emulator screens.
- 2026-10-22: **Stage S: relay hardening.** Relay protocol v2: every request signed with an Ed25519 key derived from the
  wallet key (relay keeps only the public key; a captured request can only repeat unchanged for 5 minutes, which changes
  nothing; clock offset capped at 24 h), old folder backups removed. **Save-your-wallet-key prompt** after creating a wallet
  and as a Today row until confirmed by the key's last 4 characters ("Later" = 7 days; Copy key clears the clipboard after
  60 s, also from the background). User docs (README, setup, architecture) describe the relay, the encrypted database and
  the key. Review: 0 high, 1 medium, 4 low, all fixed. Full run: importer 193, core 885, relay 115, app 774, desktop,
  web, perf 0 missed frames, emulator screens, `tools/relay.sh` health on /v2.
- 2026-10-23: **Stage H: hardening** (every reviewer item H1–H13 of `PATH_FORWARD.md`; one schema bump to 8, relay api 3).
  Money: rows in another currency are left out of every sum and shown as "Other currencies, not counted"; an explicit
  "payday passed" state (an ended period counts only its own rows; "Start new period" catches up over missed months in
  one tap); no screen prints a negative allowance or "0 days"; over-budget amounts in plain words; salary in parts
  (7-day window) and low income in core; one settings row per category budget and per merchant pattern (schema 8,
  migration keeps removals removed); bank import caps (20 MB, xlsx inflate), password-protected PBZ files named,
  PBZ header check, id collisions counted. Sync: relay instance id, self-healing device streams (a relay restored from an
  older copy, a restored database or a cloned install converge; acks that went backwards = relay rolled back), device id
  per install next to the key, clock drift held and a clock gone back refuses owner edits, BWOP2 with associated data,
  pinned SQLite cipher, relay host in the signature, bill-link and planned-payment field repairs. Relay and Android: creation
  token (podman secret), `--trust-proxy`, `--public-host`, HEAD, 404 for a missing file, health check, read-only
  container, Caddy + Let's Encrypt quadlets for sync away from home (D5), backup off, system CAs only, release build
  refuses the debug key, `FLAG_SECURE` key screens with the QR first, restore a backup made with another key (key
  rotation). Tests: the H12 list (sync scenarios, invariants, property test, relay fault injection and fuzz, crypto
  vectors, decompression bombs, old-build schema-7 database and `.bwb` fixtures). Every half reviewed as it landed
  (sync twice more after its redesign); real bugs found and fixed in the stage: a relay restored from an older copy lost
  edits, a payment could pay two bills and a planned row kept its payment after an unlink, a stale settings map could
  revive a removed budget, a foreign-currency bill was reserved as euros, the same id twice in one import overwrote the
  first, an ended period counted the next period's rows. Stage run: importer 335, core 1444, relay 200, app 1200, desktop
  12 files, web, perf, emulator screens.
- 2026-10-23: **Stage G: foundation** (structure and practices first, owner 2026-10-22; every reviewer KEEP/CHANGE placed in
  `PATH_FORWARD.md` §10). Core: typed entity schema (`schema.dart`) drives DDL, migration, type check, snapshot and search;
  `repo.dart` split into part files; `show` lists on every export; one verb vocabulary (`addTransaction`, `markBlobUploaded`,
  `BudgetKind`, `PlannedCost.isBill`); `parseMoneyCents` with the one amount cap (`WalletSettings.maxAmount`, 1 billion
  units: the UI now refuses what the repo refused); importer `ReadResult`. App: `openPageOrDialog`, `DialogAppBar`,
  `GatePage`, `RuledRow`, `MoneyField(fieldKey:)`, one invalid-amount sentence, `WalletController.now`, `_io` file names;
  four sweep bugs fixed with tests. Tests by contract: `ValueKey`s instead of texts, importer messages, font-size probe and
  contrast control (`guidelines_test.dart`; 44 known I6 failures skipped by widget name = Stage I6 targets). Local CI
  (D1: nothing in GitHub): 60 s per-test cap, `tools/build.sh analyze|stage|outdated`, no-poll hook, `tools/lsp.py refs|def`
  for the scout, `tools/stage_summary.py`, release-notes template. Four halves reviewed as they landed (all findings
  fixed); merge delta reviewed. Stage run: importer 296, core 1233, relay, app 1094, desktop 12 files, web, perf,
  emulator screens (two stale tests fixed: old 10-billion cap, privacy check matching a log timestamp). Follow-up:
  `searchRows` not yet wired into `searchAll` (J1).

- 2026-10-23: **Stage I: UI quick wins** (`PATH_FORWARD.md` §4 I1–I9; no schema change, relay api stays 3). Today: "You're X over
  for today. Nothing more today; tomorrow starts at Y." (core `PeriodBudget.allowanceTomorrow`) and "You're X over the plan for
  this period."; one setup panel under the hero (save key, salary, payday) that folds to one line and opens again when a step
  is added; Plan's ledger in exact cents with "Set aside for coming costs" and "Over by X" (rows add up to the total, no
  negative anywhere). Undo after deleting a transaction or a goal (core `undeleteTransaction`/`undeleteGoal`, synced; links to a
  bill, a matched cash entry or a transfer partner come back from a device-local record, also while a sync is pending);
  toasts 2.5 s with actions, cleared on navigation, kept for screen readers; a wish needs its own name ("Open" jumps to it);
  forms: floating labels, filled expected action, X on phone sheets, pinned "Confirm bill", last-used category (none = pick
  one first), explainers above the CTA. Type tokens (`BwType`, nothing under 12 dp but eyebrows), 48 dp targets, add button
  on every tab (FAB / rail "+"), search icon in the app bar, explainers shown once then behind an info icon, Plan › Look
  (system / light / dark, device-local), compact rows below 400 dp, delivery-hour panel only after a delivery order in 90
  days. Honest states: "Couldn't save. Nothing was changed." dialog for a refused write (core marks it: `isWriteError`),
  "Stored on your relay", backup note on bill files, relay space "X of Y used" (relay `GET state` adds `bytes`/`maxBytes`),
  "Matched with your bank" mark. Each half reviewed as it landed (found and fixed: undo while not caught up counted money
  twice; theme rebuilt with a fade on every sync; "Couldn't save" hidden under phone sheets and raised for reads; disk-full
  write lost its notice; ledger rounding; explainers marked seen on hidden tabs), merge delta reviewed. Fixed on v2: a
  core test that used the real date. Stage run: importer 335, core 1501, relay 206, app 1282, desktop 11 files, web, perf,
  emulator screens, dark frames read. Unlink of a matched expense waits for owner decision D2.
- 2026-10-23: M6 build: `ci` on d33ca66 (started on the owner's request) green: signed APK, Linux bundle + smoke, `dev` release published.
- 2026-10-25: **Stage N0: quick fixes** (`OWNER_NOTES_PLAN.md`). Wallet key: a typed `0` reads as the letter `O` (join and the "last 4"
  check; `1` still refused), key text letter-spaced with a "no zero or one" hint. Wide windows (≥600 dp, incl. a phone in landscape): no app bar;
  add, search (Ctrl+F), the period badge and the sync spinner sit in the rail (fixed slot, the rail never jumps; badge grows with text).
  Chart: widths snapped to whole device pixels, opaque line/dots/bars (blur at 1.25/1.5 scale; the owner's exact grain was not reproduced
  under software GL). Review: 2 medium, 2 low, three fixed with tests, landscape-phone app bar left to the owner. Custom-range date picker
  moved to N3 (needs core range maths). Stage run: importer 335, core 1506, relay 206, app 1293, desktop 11 files / 29 tests.
- 2026-10-25: **Stage N1 + N2 core.**
  - **N1 (app):**
    - Softer Ledger theme (owner D8): warmer off-white paper, graphite ink, mid-grey `lineStrong`, calmer accent, softer dark. Section and total rules are lighter; the double rule appears only under totals. Contrast test unchanged and green.
    - Plan: "Payday plan" and "Numbers" are one section with Edit / Save / Cancel. Same fields and validation; only edited fields are written.
    - Plan › "Join another wallet…" (not on web):
      - It needs the open wallet's key to be confirmed saved first.
      - The old key is kept in a second key-store slot, and the new key is written before the old `wallet.db` is set aside (never deleted).
      - The app waits for any sync in progress and pushes pending changes before setting the wallet aside; no sync runs while joining.
      - Joining the wallet that is already open is refused.
      - A "join pending" marker finishes an interrupted join at start-up.
      - Every failure path rolls back with the old key kept. Two review rounds: 1 high, 3 medium, 7 low, all fixed with tests.
  - **N2 core (schema 9, spec `N2_SPEC.md`, owner D9):**
    - Synced `account` entity: owner-named, a bank source or cash, own currency, opening cents plus an as-of date.
    - `correctBalance`; the opening and its date are always written together.
    - `accountBalances` and `balanceTotals`:
      - a bank account counts its source's imported rows; cash counts hand-added rows that are not matched or pending; ATM never adds to cash;
      - the total is kept per currency;
      - a duplicate created through sync is counted once.
    - `suggestPlan` / `planProposals`:
      - salary and payday day from complete payday groups; rent and loan from categorised rows; subs from confirmed bills;
      - last 6 complete months only; never written by itself.
    - `budgetProposals` (the Suggest diff).
    - Tests written independently from the spec found the sync-duplicate rule; the review found stale months, a partial first payday and the opening/date pair, all fixed.
  - **Stage run:** importer 335, core 1623, relay 206, app 1321 (1330 after the last join fixes), desktop 12 files, emulator screens.
  - **Still to build:** N2 UI (welcome balance, accounts overview, plan proposals, Suggest dialog).
- 2026-10-25: **Stage N2 UI + N3 core.**
  - **N2 UI:**
    - Plan › Accounts:
      - exact balance per account, "as of" its last row, one total per currency;
      - Add (Cash / PBZ / Revolut, currency, opening balance, "Below zero", date up to today), Rename, Correct balance, Delete with Undo;
      - a sync duplicate is marked "not counted", with Remove.
    - Today: a "Held: …" line, one figure per currency.
    - New wallet: an optional "How much cash do you have right now?" step after the save-key prompt (never when joining).
    - Plan › Suggestions from your imports: current → suggested with the reason, Accept / Not now / Accept all, nothing written without a tap.
    - Budgets Suggest: empty fields are filled at once; changes to existing numbers are asked per entry; only Save writes.
    - Review fixes: 1 medium, 2 low. Undo errors always show; Budgets/Calendars keep typed text; joining never shows the cash step.
  - **N3 core** (spec `N3_SPEC.md`, owner D11/D12):
    - `ranges.dart`: this pay period / month / 3 / 6 / 12 months / custom; step back and forward; labels.
    - `insights.dart`:
      - spending per month, category share (permille sums to 1000), income vs spending, budget vs actual per month (whole calendar months, as budgets are monthly);
      - drill-down: merchants in a category, the rows behind each total, merchant trend, this vs last month vs the 6-month average, biggest rows (outflows only).
    - Spending is decided by one shared rule (`countsAsSpending`). Every function stays under 500 ms on 10k rows, about 100 ms.
    - Independent spec tests: 112. One test mistake fixed (a 6-month window).
    - Review: a pay-period step forward then back skipped the running period (fixed); custom ranges stop at the end of this month.
  - **Stage run:** importer 335, core 1777, relay 206, app 1365, desktop 12 files, emulator screens.
  - **In progress:** N3 UI (range control, four graphs, drill-down).
- 2026-10-25: **Stage N3 UI + N4.**
  - **N3 UI:**
    - Spending › Insights (page on phones, dialog from 600 dp): spending per month, category share, income vs spending, budget vs actual (whole calendar months), and biggest payments.
    - Each graph has the shared range control: this pay period, month, 3/6/12 months, custom (tap the dates), ‹ ›; the kind is remembered on the device.
    - Drill-down from a "Where it goes" row or a share row: this month vs last month vs the 6-month average, per-month bars, merchants, then the rows (editable).
    - Results are memoized per data version and day.
    - Review fixes: 3 medium, 3 low. A refund-only category total now matches its rows; the net shows exact cents; TalkBack taps work on share rows and dates; Custom from a pay period that runs into next month works; category bars are computed in one pass; Back works after an edit.
  - **N4** (D10, spec `N4_SPEC.md`):
    - Plan › Expected bills › History for each confirmed bill: one line per month, newest first, with Paid / Bill only / Bill paid (not from the bank) / Missing / Coming up / Paid in <month>.
    - Each month shows the exact paid amount and billed when known; slips still in review are marked "(to check)".
    - A month expands to its payments and slips.
    - Matching is by payee key and dates, never by amount.
    - Review fixes:
      - core: the window is counted from today, so a far-future slip can't hide the past; "paid nearby" for payments booked a few days into the next month; invalid dates are skipped;
      - UI: cash-paid slips, (to check) marks, transfers left out.
  - **Stage run:**
    - importer 335, core 1810, relay 206, app 1412 (1418 after the N4 fixes), desktop 12 files, emulator screens.
    - **perf fails:** `spending_scroll` misses 3 frames against a limit of 2; build p90 went from 1.1 ms to 2.2–2.7 ms. The regression came between bfb7388 and e774b2d (N0–N2). It is being bisected and fixed in this stage.

## Decisions log
- 2026-10-22: Matching window (gap 5) closed by the owner: ±3 days stays fixed, no setting; revisit only if M6 shows later postings.
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
- 2026-10-21: Master pushes no longer build Windows/macOS (parked platforms; ~133 billed minutes per push). Then, same day: **no CI on push at all**; the owner starts `ci`/`release` by hand when a release is ready. Local verification (`tools/build.sh test`, desktop, emulator) is the gate before every push.
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

- 2026-10-22: **Stage F: future spending.** Planned costs (synced, schema 6) reserve money before payday (Today's
  safe-to-spend drops; Rent/Loan/Bills costs are listed as "covered by your plan", never reserved twice). Upcoming: month
  grid + list of planned costs, confirmed bills and calendar suggestions (amount from the title/notes or an earlier cost
  of the same name; Confirm / Change / No cost — never reserved until confirmed), Paid (pick the payment, same category
  ±3 days) / Skip with Undo / Delete. Today: "Coming up" line + heads-up lines (≥100 €, 3 days, editable). Plan ›
  Calendars: Android calendars (read-only, asked on tap; plugin `device_calendar_plus` needs READ+WRITE_CALENDAR declared,
  the app never writes), `.ics` file and link (60 s limit, https never downgraded, warning on http), all device-local.
  Heads-up notifications at 09:00 (no amount or title). Export "Planned costs (.ics)", search. Calendar events are
  matched across devices by name + date. Review: 2 high, 3 medium, 5 low, all fixed with tests. Full run: importer 193,
  core 1036, relay 115, app 853, desktop 11 files, web, perf 0 missed frames, emulator screens.
- 2026-10-22: **Stage B: bills database.** Scan bill on Android (receipt QR, HUB-3 slip barcode, photo through the system camera
  + on-device OCR), Share to app (PDF, photo), Plan › Bills (To review / Unpaid / Paid, import PDF / e-invoice XML / image),
  bill sheet with "Unsure" marks, line items, photo/PDF kept encrypted on the relay (new blob routes) and fetched on demand,
  Paid by… (never on amount alone; auto link only by reference/JIR/invoice number + exact amount, when caught up), Paid in
  cash → expense, warranty / return-by dates in Upcoming with reminders. An unpaid slip with a due date is a planned cost:
  it needs a category, reserves until paid, is never counted twice with an expected bill or the fixed plan; one rule
  (`plannedReserves`) feeds safe-to-spend, Today's "Coming up" and Upcoming's "Set aside". New packages (owner):
  mobile_scanner, google_mlkit_text_recognition, receive_sharing_intent. Published APK arm64 only (44 MB; local builds
  keep x86_64 for the emulator). Reviews: 3 high / 4 medium / 3 low, then 2 medium / 3 low on the fixes; all fixed with
  tests. Full run: importer 296, core 1217, relay 138, app 955, desktop 11 files, web, perf 0 missed frames, emulator.
  Review package: `docs/TECHNICAL_SPEC.md`, `RUNNING.md`, branch `review`.
## Open questions for owner
- Test v2 on phone and computer; feedback (✅ / ❌ / ✏️).
- Make the repo public? Then all-platform builds are free on every push.

- 2026-10-22: Six outside reviews read (system design, architecture, security, code, parity, UI/UX; `docs/review/`).
  Verdict: continue, no restart; edges to fix before M6 (money: foreign rows, past payday, negative flex; sync identity:
  relay id, device id, bounded HLC; per-key settings; AAD/cipher pin; Android backup/cleartext/keystore; relay token/proxy/TLS).
  Plan in `docs/context/PATH_FORWARD.md`.

## Known limits
- Upgrade every device together past the 2026-10-20 `dev` build 5b8fc13: that build paired transfers on amount alone;
  newer builds dissolve such pairs, but a device still on 5b8fc13 would re-create them on every sync.
- Importer: v1-compatible rounding changed ids of rows with an exact negative half cent (3-decimal amounts, very rare);
  such rows imported by earlier v2 builds may re-import once as duplicates.
- Search matches the cleaned description, note and category, not merchant-rule names, and opens from Spending only (not from Today's Recent list).
- Sync: a device stays stuck on a damaged sync file only if no device that applied it before the damage still syncs
  and is caught up (details in `packages/wallet_core/CLAUDE.md` "Known limits"). Devices on a pre-relay build cannot
  sync with relay devices: update all devices together.

- Calendar suggestions: two events with the same name on the same day show as one; renaming an event in the
  calendar suggests it again; a planned cost reserves until marked Paid/Skipped or its day passes (even if the bank row
  already landed: the app offers "Paid by this?").
- Bills: two devices that "Add as new bill" the same slip before syncing make one bill; a slip whose payee is written
  differently from the bank text is not matched to its expected bill (its required category still keeps a fixed-category
  slip from being reserved twice); Upcoming's "Set aside" leaves out an overdue expected bill that Today still reserves;
  photos are not in `.bwb` backups (they stay on the relay).
## Next
- **Plan for all the notes below + further development: `docs/context/OWNER_NOTES_PLAN.md`** (stages N0–N4, decisions D8–D12, delegation table).
  N0–N4 built 2026-10-25. Open: the Spending scroll perf regression (being fixed). N4 ready (D10: slips + bank payments, one line per month).
- Owner checks after N2 (phone):
  - new wallet → Skip the cash question, then a second wallet with Add cash (Today shows "Held");
  - Plan › Accounts: add PBZ with today's real balance, import, then check the balance and its "as of" date; Correct balance; Delete → Undo;
  - after an import, Plan › Suggestions: Accept one, Not now another;
  - Budgets › Suggest with some fields filled: you are asked before any number you typed changes.
- Owner checks after N1 (phone + laptop):
  - The softer colours, in sun and in dark mode.
  - Plan › Payday plan: Edit, change a field, Save; Cancel.
  - Plan › Join another wallet…:
    - with the key not yet confirmed, it asks you to confirm it first;
    - Cancel at each step;
    - a real join, after which the old wallet is set aside (it cannot be reopened in the app yet).
- Owner checks after N0 (laptop): Spending chart at your normal display scaling (still grainy = compositor scaling); the rail at 1280/1920
  (search, period badge, no top bar); type a key with `0` for `O` on join and in "Save your wallet key"; phone in landscape now has no top bar: OK?
- Owner notes (2026-10-25, later): tapping the date on a graph/range opens a date picker for a custom range; the Ledger theme is responsive and nice
  but heavy and a little hard on the eyes (soften it, D8).
- Owner note (2026-10-25): somewhere in the app, show how much is currently held in each bank and in cash (an accounts overview). Builds on the
  welcome-screen balance note: one opening balance per account, then the balance = opening + the account's rows since. Design points: rows carry
  `source` (bank profile) but the importer's `account` is never stored (it names the owner's account), so accounts would be owner-named labels
  (e.g. "Cash", "Bank 1") mapped to sources; own transfers between accounts (`transfer_to`) move money without changing the total; foreign-currency
  accounts shown in their own currency, never summed with home currency; bank balances can drift from the real ones (unimported rows), so show an
  "as of last import" date and let the owner correct a balance. New synced entity (schema bump, `entitySchema`, `sim.dart`), exact cents.
- Owner note (2026-10-25): a welcome screen on first run where the owner sets the current cash balance (the starting point). Open: does the app
  have a balance concept at all today (it counts flows per pay period, not a running balance)? Decide with the owner whether this is an opening
  balance row (cents, dated, synced like any entry, never mixed with imported bank rows) or a setting, and whether it feeds the plan defaults
  above. Fits onboarding (new wallet / join with key): welcome → balance → import files → plan proposals. Exact cents, own currency.
- Owner note (2026-10-25): the payday plan should set itself up with sensible defaults taken from what the imports show (salary and payday from
  detected salary rows, rent and loan from the recurring fixed rows, bills and subscriptions from confirmed recurring bills, budgets from the
  6-month averages). Shown as proposals the owner accepts or edits (like the Suggest note above), never saved silently over numbers already
  entered. Core: pure functions over transactions (`detectPaydays`, `detectRecurring`, `suggestBudgets` exist; rent/loan/salary suggestions are
  new). Each value from exact evidence (importer `kindHint`, recurring detection), never from an amount alone; foreign-currency rows left out.
- Owner note (2026-10-25): Spending needs more detailed views and more categories, so more can be drawn from the data and concluded. Ideas to
  confirm with the owner: drill from a category into its merchants and rows; per-merchant totals and trends; subcategories (finer than the
  fixed/flex list); month vs month and average comparisons; biggest rows and recurring vs one-off. Categories live in `categories.dart`
  (`spendingCategories`, built-in merchant patterns; the owner's own rules stay in the `merchantPatterns` setting, never in git). Adding a
  category touches budgets, reports and CSV export: check each. Money rule: never reclassify on amount alone.
- Owner note (2026-10-25): on the laptop the date and the search stay pinned at the top of the page and only waste space. Let them scroll away with
  the content (or sit in the nav rail / one slim row on wide windows). Check Today and Spending headers (`SearchPane` pinned field, the header with
  the date) at 1280 and 1920 wide with `tools/build.sh desktop-test adaptive` screenshots.
- Owner note (2026-10-25): every graph should let the owner change the date range it shows (e.g. this pay period, a month, 3 / 6 / 12 months,
  custom from–to, step back and forward). Applies to the existing charts and the new ones above; one shared range control in `widgets/charts.dart`,
  range math in `wallet_core` (pure, tested), currency rule as everywhere (home-currency rows only).
- Owner note (2026-10-25): (1) add more graphs (which ones: ask the owner; candidates from existing data: spending per month, category share,
  income vs spending, budget vs actual, savings/goals over time; `widgets/charts.dart`, fl_chart). (2) The graph on the laptop looks grainy:
  reproduce with `tools/live.sh shot` and the Linux bundle (check device pixel ratio / HiDPI scaling, stroke and dot sizes, antialiasing;
  software GL under Xvfb is not the cause on the owner's real desktop). Bug: fix with a test or a screenshot check in the same stage.
- Owner note (2026-10-25): rework Plan and the settings mode as a whole. Details not given yet; the notes above on Payday plan + Numbers,
  Budget "Suggest", join-while-a-wallet-exists, the key display and Expected bills all touch the same screen, so design them together
  (one mockup in the design-system artifact first) before building them one by one.
- Owner note (2026-10-25): Plan's "Payday plan" (read-only ledger, `plan.dart` ~l.178) and "Numbers" (edit fields + "Save numbers", ~l.226) are two
  sections and it is unclear what each does. Merge them into one "Payday plan" section: the ledger lines (salary, rent, loan, bills, set aside,
  left to spend) with an **Edit** button that turns the lines into the fields and shows Save / Cancel. Same fields and validation as now
  (`_keys`, `_savePlan`); no new screen. Keep the widget keys the tests use (or update those tests).
- Owner note (2026-10-25): a monthly (recurring) bill should list all the bills that belong to it. Read as: Plan › Expected bills, per confirmed
  recurring bill, show every stored bill (bills database) and the paying bank rows of that payee, one line per month. Not decided yet: whether
  "bills" here means slips in the bills database, the bank payments, or both; ask the owner before building. Match by payee key (`billPayeeKey`) and
  exact evidence only, never by amount alone.
- Owner note (2026-10-25): Plan › Budgets per category "Suggest" (6-month average, `suggestBudgets`) should apply by itself to every empty
  field. For a field that already has a number, ask per entry whether to overwrite (show old → suggested), with an "Accept all" choice.
  Today it only fills empty fields (`BudgetsPanel`, `app/lib/src/screens/budgets.dart`). Nothing is saved until the owner accepts; only edited
  fields are written, as now.
- Owner note (2026-10-25): let the owner join an existing wallet (key + relay) even when this device already has a wallet. Today the app opens
  straight into the local wallet and the join screen is not reachable, so I moved the data folder aside by hand to join. Needs an in-app path
  (e.g. Plan: "Join another wallet…") that sets the current wallet aside first, never deletes it (see `setAsideWalletDb` in the app notes), and
  warns that the old data stays only on this device.
- Owner note (2026-10-25): the wallet key text is easy to misread (a letter O typed as 0 gave "characters that are not allowed" on join).
  Make 0 and O clearly different in the key display (`key_backup.dart` `keyText`, now IBM Plex Mono) and/or let `VaultKey.parse` read `0` as `O`
  (`0` is not in the base32 alphabet, so it is unambiguous; `1` could be I or L, leave it). Test in `vault` tests.
- Owner installs Android APK + desktop build, creates wallet, imports bank files, sets up the relay (`docs/setup.md` §5; APKs before the signing
  fix used throwaway keys: uninstall that one once; later updates install in place). After testing: Plan › Diagnostics
  "Save logs…", send the file; summarise with `tools/log-summary.py`.
- Owner checks on the phone after Stage C: Ledger theme at large text (stat strip, stacked rows), bottom bar accent mark,
  dark mode, sheets with the double rule, Plex digits and €; on desktop: rail, two columns, dialogs, margin line.
- Owner checks on the phone after M4: Plan › Nudges on → allow notifications (Android 13 asks) → one arrives around 15:00
  with no amounts (battery saver may delay it a few minutes); Plan › Expected bills shows the real standing orders as
  candidates → Confirm the true ones, "Not a bill" the rest; Today shows the review card on Sunday and "Due by payday".
- Owner checks on the phone after M5: Plan › Backup "Back up now" with the real Syncthing folder (the file appears under
  `budget-wallet/backups/`); an export through the Android save dialog opens in a spreadsheet with Croatian letters intact;
  Spending search by a word and by an amount.
- Owner checks after Stage W (web): `tools/build.sh web && tools/web.sh serve`, open http://127.0.0.1:8080 → new wallet with a
  passphrase; reload → unlock screen, wrong passphrase refused; open a second tab → "open in another tab", close the first,
  Reload works; Plan › Backup "Back up now" downloads a `.bwb`, "Forget this browser" returns to onboarding, restore that file.
- Owner checks after Stage R (sync redesign): run the relay on the home server (`docs/setup.md` §5) or locally with
  `tools/relay.sh start`; update the phone over the existing install → the wallet opens with all data (it is encrypted on
  first start); Plan › Sync: relay address (`http://<server>:8787` over LAN/VPN) → Test connection → Sync now → "Up to date";
  the laptop joins with the key + the same address and sees the phone's data; an expense on one shows on the other;
  Back up now / Restore from backup… through the Android file dialogs (storage permissions are gone); Diagnostics "Save logs…".
- Owner checks after Stage S: create a wallet → "Save your wallet key" sheet; wrong then right last 4; "Later" hides the
  Today row; Copy key → paste in the password manager → after 60 s back in the app the clipboard is empty.
- Owner checks after Stage F: add a planned cost (Upcoming "+") → Today's safe-to-spend drops by it; Plan › Calendars
  "Allow calendar access" → switch a calendar on → its events show as suggestions in Upcoming → Confirm one (Today drops),
  "No cost" another (gone on the other device after sync too); import an `.ics` file and add an `.ics` link, break the link
  → "Showing what was saved"; an `http://` link shows the warning; Paid → pick the payment → Undo; Skip → Undo; a cancelled
  phone event is not suggested; Plan › Nudges heads-up on → a notification at 09:00 before a ≥100 € cost (no amount);
  Plan › Export "Planned costs (.ics)" opens in the phone's calendar.
- Owner checks after Stage B (phone): Add expense › Scan bill → a shop receipt QR, then a payment slip barcode, then
  Take photo of a receipt without a code (the phone's camera app opens; fields marked "Unsure"); deny the camera once and
  check the hint; Share a PDF bill from email and a photo from the gallery (app closed and open); Plan › Bills: confirm a
  slip (it asks for a category; a utility in Bills & subscriptions shows "covered by your plan"), see it in Upcoming and
  Today's safe-to-spend, then "Paid by…" the bank row and check the receipt mark in Spending; scan the same slip next
  month → "Add as new bill"; open the photo/PDF on the laptop after a sync; set a return-by date and wait for the 09:00
  reminder (no payee or amount in it); install the 44 MB APK from the `ci` run over the old app.
- Owner checks after Stage H (hardening): set up the relay away from home per `docs/setup.md` §5 (your domain or a
  dynamic-DNS name, router forward of 443 and 80, firewalld step, `podman secret create bw-relay-create-token`, the two
  quadlets) → on the phone Plan › Sync: `https://<domain>` address, the creation token, Test connection → Sync now; the
  fingerprint shows under the address. Type a public `http://` address → refused with the https hint (a home address
  still works). Open Show wallet key → QR first, a screenshot is blocked and the recent-apps thumbnail is blank. Set the
  phone's clock back 2 h and add an expense → the clock dialog; set it right again. Today after a payday you have not
  started yet → "Left this pay period", the "Start new period" panel (one tap, even after missed months). A card payment
  in another currency → "Other currencies, not counted: … spent" on Today and Spending. Key rotation drill once
  (`docs/TECHNICAL_SPEC.md` §9 limit 2: back up, clear storage, new wallet, "Restore a backup made with another key…").
  Layout call for you (KEEP K19, Today's order): the over-budget line sits between the stat strip and the pace bar, and
  a "period ended" panel with its own button sits above the hero like the "Salary landed" panel: OK, or fold the
  over-budget line into the sentence?
- Build order (owner 2026-10-22: every feature first, the owner tests last): future spending (done) → bills database
  (done) → outside reviews (done, `docs/review/`) → Stage G foundation (done 2026-10-23) → Stage H hardening (done 2026-10-23) → Stage I UI quick wins (done 2026-10-23) → **M6 owner live test** (owner starts `ci` for the M6 build)
  (plan with every review KEEP/CHANGE placed, delegation, owner decisions D1–D7 in `PATH_FORWARD.md`; queue in `PIPELINE.md` Stage G/H/I).
- Owner checks after Stage I (phone): Add expense on a fresh wallet waits for a category; the add button never covers the
  last rows (Today, Spending, Plan, search results); 320 dp app bar (logo, search, period chip); Plan › Look Dark switches at
  once and survives a restart; spend past today's money and past the plan → both sentences, no negative figure; Plan's ledger
  rows add up to the total; delete an expense and a goal → Undo (also from Weekly review); a big buy → name the wish → "Open";
  bill sheet: "Confirm bill" stays in view; with storage full, saving shows "Couldn't save. Nothing was changed." over the
  sheet; Plan › Sync against the updated relay shows "X of Y used"; TalkBack: the Undo toast stays until handled.
- M6 adds four disaster drills to the owner checks (`PATH_FORWARD.md` §4 M6): new phone with the relay alive; new phone
  with the relay dead + `.bwb`; relay address switched to a second relay and back; laptop clock a day ahead for one sync.

## In flight (2026-10-20)
- Queue and procedure: `docs/context/PIPELINE.md`.
