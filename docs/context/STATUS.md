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
    - **perf over budget, cause is the host, not the code:**
      - `spending_scroll` misses 3–5 frames against a limit of 2; build p90 is 2.2–2.8 ms (was 1.1).
      - The same old commits (d99db16, bfb7388) that measured 1.1 ms / 0 missed on 10-22 and 10-23 measure 2.4–2.8 ms / 3–5 missed today. No app commit stands out; the whole perf step is ~14 % slower on the same image.
      - Host changes since 10-23 include a 55-package `dnf install`, Steam, and kernel split-lock / iwlwifi warnings.
      - Next: after a reboot, rerun `tools/build.sh perf` on bfb7388. The budget is not loosened.
- 2026-10-25: **Stage P1: your own categories** (PATH_FORWARD P1, spec + owner decisions in `P1_SPEC.md`, schema 10).
  - **What's built:**
    - The 20 built-in categories stay as ids. They can be renamed, hidden and reordered, never deleted.
    - Your own categories: a synced `category` entity, one level of subcategories. A subcategory has its parent's kind and rolls up into it in Spending, budgets (top-level only) and the monthly CSV; the drill-down shows the subcategories.
    - Plan › Categories: add, add subcategory, rename, hide, move, delete with Undo. A sync duplicate is "not offered".
    - Pickers use the table, with subcategories indented. CSV and search use labels.
  - **Owner decisions:**
    - Your own fixed categories get their own payday plan line (`plan:<id>`, Plan › Edit). Until a line is filled in, that money is not taken off the daily amount.
    - Your own income categories count like salary.
    - A deleted category falls back automatically, and nothing is rewritten:
      - a bill reads its paying row's category, else the payee's latest bank row, else the rules;
      - deleting a category that has a plan line asks first ("its bills then count under the automatic category").
    - Money limit, by owner choice: a bill that was in a deleted plan line and falls back to Bills & subscriptions is neither set aside nor subtracted unless the subs figure includes it.
  - **Built and checked:**
    - Core builder and independent test-writer from one spec: 117 spec tests; 4 test-setup mistakes fixed.
    - Three review rounds: 2 high, 6 medium, about 12 low.
      - High: Rent/Loan/subs matched by exact name, so children and custom fixed were missed; a deleted-category bill fell back differently from its own rows (counted twice).
      - Medium: an untouched Save could write a fallback over the stored id.
      - All fixed, with tests.
  - **Stage run:** importer 335, core 1965, relay 206, app 1461 (1468 after the last fixes), desktop 12 files (plan and layout rerun after the last fixes), emulator screens.
- 2026-10-25: **Stage T1: tags** (owner request; spec and decisions in `T1_SPEC.md`; schema 11).
  - **Model:**
    - One **main tag** per payment. This is the category (built-in or your own). It decides every money path, which is unchanged.
    - Any number of **extra tags** for tracking. Their totals overlap, and the UI says so.
    - The suggested top 20 tags are the 20 categories, picked as before (bank hint, rules, never by amount).
    - Subcategories from P1 are replaced by tags (`parent` is refused and stored parents are ignored). Plan lines stay.
  - **Core:**
    - New entities: `tag`; `txtag` (a per-payment link, `on`/`off`, id `<tx>|<tag>`); `ruletag` (a payee rule, so every payment from that payee gets the tag).
    - Effective tags are worked out at read time: rule tags plus `on` links, minus `off` links. Nothing is written on import.
    - Suggestions are tags used on at least 2 rows of that payee, applied only on a tap. Recommended order puts the payee's tags first.
    - `tagShare`, `rowsForTag` and `tagTrend` power the graphs; search and the CSV `tags` column use tags too.
    - Sync duplicates are merged, and duplicate groups are edited as one (also for P1 categories). A matched hand entry passes its tags on to the bank row that replaces it.
  - **App:**
    - The picker: main tag (★) and extra tags (#), with "from rule" marks, faded suggestions and "New tag…".
    - "Also tag every payment from …".
    - The payment sheet writes the main tag and tags together on Save; closing the sheet writes nothing.
    - Plan › Tags (add, rename, hide, move, delete + Undo, counts). Plan › Categories is now "Main tags".
    - Up to 3 `#tag` chips on each row.
    - Insights › Tags, with a drill-down.
  - **Review:**
    - Core: 4 findings (2 medium), all fixed.
    - UI: 5 findings (1 medium, about Save versus close), all fixed.
    - The 68 independent spec tests turned up no core bug.
  - **Stage run:** importer 335, core 2029, relay 206, app 1494 (1499 after the last fixes), desktop 13 files (tags and plan rerun after the last fixes), emulator screens.
- 2026-10-25: **Stage P7: Rules screen** (spec + Clarifications `P7_SPEC.md`, no schema bump).
  - **Plan › Rules** lists, per rule, its text, main tag, `#tags`, range and "used by N":
    - payee rules (Delete with Undo is new: `removeMerchantRule`);
    - "description contains" rules (new: case- and accent-folded);
    - advanced regex patterns;
    - payee tag rules;
    - built-in rules (read-only, collapsed).
  - **Editing:** Add / Edit / Delete with Undo / move. An edit shows a Preview ("This changes the main tag of N payments"). The payment sheet has "Make a rule…".
  - **Owner rule (never by amount alone):** an amount range is allowed only on "description contains" rules, and only narrows the text match. A regex that matches every text (`.*`, `^`, empty) is refused when written and ignored when synced in.
  - **Review:** 1 high (catch-all regex + range = amount alone), 1 medium (a move after offline ties jumped two places), 2 low. All fixed.
  - **Known limit:** builds before P7 read a contains rule as a regex and ignore its range (text only).
  - **Stage run:** importer 335, core 2104, relay 206, app 1520, desktop 13 files, emulator screens.
- 2026-10-25: **Stage P4: recurring bills beyond monthly** (spec + decisions `P4_SPEC.md`, schema 12).
  - **Owner decisions:** quarterly/yearly bills hold their full amount from confirmation until paid (never covered by a monthly plan line); a range sets aside its highest amount; a bill paid in parts is done when the parts add up; weekly / every-2-weeks / quarterly / yearly bills are detected and suggested for confirmation.
  - **Core:** period classes (7/14/30/91/365 days, own tolerance each), amount ranges, parts (wide window only for manual and range bills), `dueCycles` (weekly bills reserve each week before payday), instalments ending on calendar months (`endsBy` = end + half an interval), manual bills (`addRecurring`, optional payee: without one it never matches a payment), `updateRecurring` with `own_category`, history per cycle.
  - **App:** Plan › Expected bills: Add bill / Edit sheet (period, range, payee, instalments), labels for period, range, "N payments left", "x of y paid", "Held in full until paid"; Mark paid with Undo; Today lists held long bills; bill history per cycle; demo wallet has a yearly and a weekly bill.
  - **Reviews:** core 2 high (a lone early part left a cycle open with no reserve later; monthly instalments ended early), 3 medium, 4 low; re-review 1 medium (late payment still ended a plan early), 1 low; UI 1 high (Edit rewrote the instalment end in 30-day steps), 1 medium, 3 low. All fixed with tests.
  - **Known limits:** the payee of a bill can't be changed after it is created; instalments are edited as "payments left"; `suggestPlan` still counts a weekly subscription as one monthly amount.
  - **Stage run:** importer 335, core 2272, relay 206, app 1555, desktop 13 files, web-test, emulator screens. Perf: spending_scroll over budget again (5 missed build frames) — the known host slowdown, not P4.
- 2026-10-25: **Stage P6: split transactions** (spec `P6_SPEC.md`, schema 13).
  - **Owner decisions:** parts must add up exactly before Save; each part has amount, main tag, tags, note; Spending shows one row per payment with the parts underneath; bank and hand-added payments can be split, transfers can't.
  - **Core:** synced `split` entity (id = the payment's id, all parts in one field, so two devices never mix parts); `Categorizer.expand` gives one row per part at read time; every total, budget, safe-to-spend, insight, CSV (one line per part) and search uses parts; matching, recurring, bills, balances, rule hits and pickers use whole payments. A split that no longer adds up is ignored ("Split doesn't add up"); a part whose main tag was deleted takes the payment's main tag. A bank row reads the split of the hand-added entry matched to it.
  - **App:** Split… on the payment sheet (editor with "Left to split", Save off until 0.00, Remove with Undo); Spending, Today and search show "Split · N"; category/tag/insight lists show parts ("part of …"); demo wallet has a split supermarket payment.
  - **Reviews:** core 2 medium (a part could fall back to a transfer and vanish from spending; a split made on another device after matching was lost), 2 low; UI 1 medium (search listed a split payment once per part), 7 low. All fixed with tests.
  - **Stage run:** importer 335, core 2367, relay 206, app 1577, desktop 13 files, web-test, emulator screens, perf ok (0 over budget).
- 2026-10-25: **Stage P13: Android widget, quick add, calendar permission, first-import plan** (spec `P13_SPEC.md`; no new packages, one removed).
  - **Home-screen widget** (2×1, resizable): "SAFE TO SPEND TODAY" with today's amount (as Today's hero) and "to 10 Nov" / "Over today" / "Over the plan"; only today's figure is ever shown — on another day it says "Open the app to update". Only the formatted amount, a status word and the date reach the widget (app-private prefs, not backed up). Tap opens the app. Cleared when no wallet is open, on forget and on join.
  - **Quick add:** long-press the app icon → "Add expense" (a dynamic shortcut with its own action; a running app opens the sheet without restarting).
  - **Calendar:** read through the app's own channel with READ_CALENDAR only; `device_calendar_plus` and WRITE_CALENDAR are gone.
  - **"Looks right?"** after the first import that adds rows: the suggested payday plan (salary, payday, rent, loan, subs) with Accept all / Choose… / Not now (same as Plan › Suggestions), once per wallet.
  - **Review:** 2 medium (the shortcut looked like a shared link to the share plugin; the widget could show yesterday's amount as today's), 4 low. All fixed with tests.
  - **Not verified on a device:** the widget and the shortcut (tests use mocked channels; the release APK builds).
  - **Stage run:** importer 335, core 2515, relay 206, app 1701, desktop 13 files, web-test, emulator screens, perf ok.
- 2026-10-25: **Stage P15: other currencies in the budget** (spec `P15_SPEC.md`, owner rates; no schema change, settings `fx:<CODE>`).
  - **Plan › Currencies:** one row per foreign currency seen in payments: set "1 USD = 0.9240 EUR" (both decimal styles, up to 6 decimals, max 100 per unit), edit, remove with Undo (keeps the original date). Payments in that currency then count in every total, budget, insight and CSV at the converted amount (rounded half away from zero, once per payment; split parts add up exactly); rows show the home amount with "100.00 $ at 0.9240" under it. A currency without a rate stays "not counted" as before (ForeignNote taps to Plan › Currencies).
  - **Kept raw on purpose:** matching, transfers (Revolut exchanges stay transfers), accounts, recurring bills/income matching (`matchRows`), paydays and plan suggestions, the payment sheet and the split editor (they work in the bank's amount and currency).
  - **A rate remembers its home currency:** after switching the wallet currency, old rates stop counting and show "Rate was set for EUR (set it again)".
  - **Bank EUR amount:** not in any export the importer reads; waits for the owner's Revolut header line (hook `Tx.homeAmount` ready).
  - **Reviews:** core 3 medium (split remainder with a partial list, rates not tied to the home currency, bill matching on converted rows), 2 low; round 2: 2 medium (converted rows set paydays, split editor used the converted amount), 4 low. All fixed with tests.
  - **Stage run:** importer 335, core 2515, relay 206, app 1669, desktop 13 files, web-test, emulator screens, perf ok (0 missed frames).
- 2026-10-25: **Stage P8: reports** (spec `P8_SPEC.md`, no schema change).
  - **Insights › Per pay period:** income, fixed, flexible and net for each of the last 6/12 pay periods (newest first, running period "so far", total line); the same numbers as Spending's pay-period chart.
  - **Insights › Main tag vs budget:** pick a spending main tag; one bar per pay period against its monthly budget, "over by …" rows, "No budget set".
  - **Review Done screen:** finishing the weekly review shows the streak and "Saved by waiting" (wishes skipped after their cooling-off) for this pay period and all time.
  - **Review:** 2 low (the panels used other settings than Spending's periods; saved figures recomputed on every redraw), fixed. A flaky desktop onboarding test (it checked the new wallet before the key write and database open finished) fixed to wait for it.
  - **Stage run:** importer 335, core 2489, relay 206, app 1646, desktop 13 files (onboarding rerun after the fix), web-test, emulator screens; perf: the known host tail (3 missed build frames).
- 2026-10-25: **Stages P9 + P10 + P11** (specs `P9_SPEC.md`, `P10_SPEC.md`, `P11_SPEC.md`; owner answers `NEXT_DECISIONS.md`; schema 14; built in parallel, verified together).
  - **P9 recurring income:** expected extra income (side job etc.) is detected from history (kind extra inflows) or added by hand (payee required, extra-kind main tag; a salary tag is refused), shown as "Expected, not counted yet" in the payday plan and on Today, and counts toward spending money **only once it lands**, and only payments that fit its usual amount (a one-off bonus from the same payer still goes to goals; refunds at the payer are taken off). Goals use `extrasForGoals`, so nothing counts twice. Incomes are stored with statuses older builds never act on.
  - **P10 merge from backup:** Plan › Backup › "Merge a backup…" (with data in the wallet): a preview ("This brings in 42 updates: 30 payments, …"), the newer change wins field by field, nothing doubled; merging the same file twice says "Nothing new". Bill files on this device go into backups (up to 16 MB, newest first) and come back on restore/merge. A damaged file says so instead of asking for a key. Backup format stays v1 (older builds ignore the files).
  - **P11 number style:** Plan › Look › 1,234.50 (default) or 1.234,50, this device only; every amount, field, hint and message follows it; typed amounts read both styles, "1.500" is 1500 € in the 1.234,50 style, and an amount with three decimals is refused instead of rounded. CSV stays machine format.
  - **Reviews:** P9 core 3 medium (one-off bonus counted as income, refunds ignored, old builds would reserve a synced income), 3 low; P9 UI 1 medium (Undo re-added with a new id), 2 low; P10 core 1 medium test gap, memory cap lowered to 16 MB; P10 UI 1 medium (damaged file asked for a key), 1 low; P11 1 money bug ("1.500" saved 1.50 € in the comma style), 3 low. All fixed with tests.
  - **Known limits:** two devices that detect the same income in separate imports before syncing can put it back to "suggested" (not counted until confirmed again); a backup cut in half reads like one made with another key; update every device together (schema 14).
  - **Stage run:** importer 335, core 2474, relay 206, app 1638, desktop 13 files, web-test, emulator screens. Perf: spending_scroll 3-5 missed build frames on this laptop for every branch tail (same commit varies 2-5 between runs; p90 identical at ~2.5 ms) = the known host slowdown; rerun after a reboot.
- 2026-10-26: **Stages P12 + P14 + P16a** (specs `P12_SPEC.md`, `P14_SPEC.md`, `P16_SPEC.md`; schema 15, relay api 4; built in parallel, verified together).
  - **P12 any CSV:** a CSV the app doesn't know opens **Map columns** (date, amount or debit/credit, description, currency, date format, decimal style, "spending shown as positive", header row, name) with the problems and a preview of 5 rows; Save & import only with no problems. The layout is remembered per file shape (synced setting `csvmap:<shape>`), Plan › Import › Saved file layouts (rename, change with confirm + Undo, delete with Undo). UTF-8 or Windows-1250, `;` `,` or tab, exact cents (a third decimal is refused). PBZ/Revolut ids unchanged.
  - **P14 bill files on the relay:** clients never delete files; a bill's changes go up only after its file is stored; each snapshot declares the files its live bills use (signed) and the relay deletes a file only when neither kept snapshot uses it and it is older than 30 days. Old clients/relays keep working (no GC with an old side). Local tables only (schema 15).
  - **P16a Pay + loan:** bill sheet **Pay** (confirmed bill with IBAN and a total above 0): payee, IBAN, amount "12,50", reference and description, each with Copy, plus Copy all; clipboard cleared after 60 s; nothing is sent. Payday plan: "12 payments left · 3,600 € at this rate" under the loan.
  - **Test fixes:** bills tests and the number-style test depended on the real date (went red on 26 Oct); now pinned / robust.
  - **Stage run:** importer 374, core 2549, relay 216, app 1758, desktop 13 files, web-test, emulator screens, perf ok.
  - **Update every device and the relay together** (schema 15, relay api 4).
- 2026-10-27: **Stages P16b + P5** (specs `P16_SPEC.md` P16b, `P5_SPEC.md`; schema 16; built overnight in parallel, verified together).
  - **P16b attachments:** a payment's sheet has "Attach photo or PDF" (Android: Take photo or Pick a file; desktop: file pick; jpg/png/pdf only, pictures sized down, 15 MB max), up to 5 per payment, each opens like a bill file, Remove with Undo in the sheet. Attachments never count as bills: no Bills lists, no money set aside, no matching, reminders or search. Files ride on P14 (upload before the change, kept on the relay, in backups). A hand-added entry's attachments move to its bank row when matched. Linked through a new column `attached_tx` so builds before P16b never mistake them for a bill payment (they show one under Bills › Unpaid, never reserved).
  - **P5 new tabs:** Today · Budget · Bills · Save · Settings (your approved mockup). Budget = payday plan on top of the old Spending page; Bills = Coming up (or "Held until paid: X"), To review, Expected bills, the bills list, Scan/Add bill; Save = Goals then Wishlist; Settings = every other Plan section, one page on the phone, two panes from 1040 dp. Today's lines, search results and the currency note open the right tab and section. Bills and Settings rebuild only while shown.
  - **Reviews:** P16b core 1 medium-high (old builds would unlink a real bill → money set aside again; fixed with `attached_tx`), 1 fix reverted after re-review (files of a deleted payment could be lost on undelete), matched-entry bug; P16b UI 1 medium (clock behind showed "couldn't save"), 6 low, 4 test gaps; P5 3 (search links, held heading, rebuild cost) + 3 follow-ups; emulator screens test order. All fixed with tests.
  - **Known limits:** a deleted payment's attachments keep their files on the relay and in backups (16 MB budget) until removed; more than 5 can exist after two offline devices attach to the same payment (nothing deleted, adding is refused until below 5).
  - **Stage run:** importer 374, core 2575, relay 216, app 1814, desktop 13 files, web-test, emulator screens, perf ok (all three actions in budget). **Update every device together** (schema 16).
- 2026-10-27: **Stage J1 + J2** (`PATH_FORWARD.md` J1–J2; refactor before the live test; no schema or protocol change, still schema 16 / relay api 4).
  - **J1:** `WalletControllerDeps` (immutable; replaces the mutable function seams and the `walletDbDirOverride` global), `KeyStore` as an instance, `CalendarState`/`SyncState` as Listenables, typed `MemoKey`s, `TodayView`/`UpcomingView` so those screens no longer get the controller.
  - **J2:** `pdf_text.dart` split into `bills/pdf/` parts; `SyncEngine` per-peer apply as `_applyPeer` with a sealed result and asserts (apply order, refused file changes nothing, forget after a complete pass); bill sheet, Today, search and Bills panel in sub-widgets; `readCalendars` flattened; `AsyncAction` mixin on six panels; `PickedFile` keeps `file_picker` out of screens; `WalletRepo.clockStats()`.
  - **Bug fixed (found in J2):** after a sync, a change from another device older than the newest clock here did not refresh the screen (stale numbers until the next reload). New `WalletRepo.dataVersion`; the app compares (repo, dataVersion). Tests: `data_version_test`, `sync_reload_test`.
  - **Small visible changes:** changing the relay address or "Forget this browser" now also clears the old relay's sync warnings (unreadable files, relay size) instead of keeping them until the next sync.
  - **J4 (`packages/sync`)** not clean yet (core's logs, local_db and repo import sync files): after M6. Counters as delta rows (J3) change the sync format: after M6.
  - **Reviews:** J2 core 0 blocking (1 medium for the app, 4 low), J1 0 blocking (5 low), J2 UI 0 blocking (2 drifts restored). All fixed.
  - **Stage run:** importer 374, core 2584, relay 216, app 1822, desktop, web-test, perf ok; emulator screens ok on rerun (first run: emulator went offline after the test passed).
  - **J3 mutation testing:** `tools/build.sh mutate <core|importer> <lib file>… [--max --seed --tests]` (`tools/mutate.py`) plants small errors in a copy of the package (never the tracked files) and lists the ones no test catches. First pass (seed 7): budget 29/60 survived, periods 7/60, loan 3/26, CSV detection 3/10. 34 new invariant tests (`j3_invariants_test`, `j3_csv_invariants_test`) catch all of them except 8 proven equivalent; no money bug found. Also: `BW_FUZZ_ITERATIONS`/`BW_FUZZ_SEED` now reach the container (were silently ignored), lint checks it. Review: 2 medium in the tool (a killed run could leave a mutant in lib/) → fixed. Tests: importer 377, core 2618, relay 216, app 1822.
- 2026-10-27: **Stage J4: sync in its own package** (`packages/sync`, `wallet_sync`; owner: before the live test; no schema, format or behaviour change).
  - Core no longer depends on sync: `isBlobHash` in `bills.dart`, logs classify errors through a `LogSafeError` marker (same log text). `sync_engine`, `sync`, `sync_problems`, `sync_relay`, `sync_memory`, `blob_store` + 18 sync tests moved (`git mv`); `vault`, `backup`, `repo_blobs` stay in core. Core's feature tests still sync two devices through `wallet_sync` as a **dev dependency only**; `layering_test` fails if core `lib/` ever imports sync.
  - `tools/build.sh sync [file]` and the `sync` step in test/stage; `ci.yml` runs sync in the core job (with `tests`); `tools/build.sh mutate core` also runs the sync suite. App: import lines + pubspec only.
  - Review: 0 blocking, 3 low (mutate coverage, layering check, docs) fixed.
  - **Stage run:** importer 377, core 2296, sync 326, relay 216, app 1822, desktop, web-test, emulator screens, perf ok.
- 2026-10-27: CI run 40501803217 (bd10966, apk + linux) green; `dev` release updated for the owner's test.
- 2026-10-27: **`tools/relay-deploy.sh`**: `bootstrap|install|upgrade|backup|status` for the Hetzner relay (setup.md §6 "Quick way"); `--dry-run`, offline `--self-test` in lint (`deploy-selftest`). Not yet run against a real server. Review: 1 blocker (dnf5 has no `dnf-automatic-install.timer`, also wrong in §6.2) + lockout/stdin/backup-trap fixes. Manual docs fixed: stopping `bw-relay` also stops Caddy (`Requires=`), so §6.4/6.5 start both.
- 2026-10-27: Research: Actual Budget + Cashew read for ideas (no code taken). Proposed, waiting on the owner: category suggestion chips, schema upgrade-from-every-version tests, bill weekend shift, hide-amounts toggle, total overflow guard; then statement reconciliation, import preview, search filters, rule suggestions, budget presets, IOU list; after M6: device state digest (sync change).

- 2026-10-27: **Stage Q: ideas from Actual Budget + Cashew** (plan `STAGE_Q_PLAN.md`; schema 17; update every device together).
  - **Wave 0 (structure):** `repo.dart` and `controller.dart` split into part files (moves only, same test counts).
  - **Add expense:** up to 3 suggested main-tag chips under the note (from your rules and earlier rows with the same word; only tags the picker offers, a tap is needed) and a list of recent payees/notes while typing.
  - **Rules:** after you set the same main tag by hand on a payee's bank rows, a toast asks "Always put X in Y?" (Make rule, then Undo); Settings › Rules › Suggested (Make rule / Dismiss, dismissed stays on this device).
  - **Search:** filter chips (amount, date, main tag, has attachment, split, uncategorised), matched text in bold, a search button on Today's Recent panel.
  - **Settings › Sync › Recent changes:** what changed, when, on this device or another (read-only, no values shown).
  - **Import preview** (Settings › Import › "Always show", on by default): "3 new · 3 already here · …" with Skip per row; Cancel writes nothing (no rows, no layout).
  - **Bank balance:** a Revolut file's own balance is checked automatically; for PBZ the app asks "What did the bank app show?" (Matches / Save this number / Skip); "off by X" offers Correct balance, never corrects by itself. Settings › Accounts shows the last check.
  - **Red warning:** Today says "PBZ goes below zero around <date> (<bill>)" / "is below zero now", only from a balance checked in the last 35 days; otherwise "Check your PBZ balance".
  - **Payday forecast:** Budget › under the payday plan "On payday: about X (after bills, before day-to-day spending)" with a step chart, from checked home-currency bank accounts only (the note says what is left out).
  - **Owed (IOU list):** Save tab › Owed: "People owe you X · You owe Y", IOUs with repayments, Close, Delete + Undo; on a payment "Lent to someone" / "Repayment". A linked payment counts as neither spending nor income (like a transfer) but stays in account balances and in the lists with a "lent"/"repaid" tag.
  - **Bills:** "Bills and subscriptions: X a month · Y a year" on Expected bills ("about" for a bill with a range).
  - **Safety:** one amount cap everywhere (see Known limits); database upgrade tests from every schema 8–17 (plain and encrypted) + a real schema-16 old build; sums stay exact.
  - **Bugs found and fixed in the stage:** after a schema bump that adds a record kind, a device that had skipped the new records could lose them for good when the relay had already pruned the file (now it starts from a snapshot of its own schema and waits for one if needed; two more data-loss orders found in the re-review and fixed); a cap check that let the smallest number through; suggestions that could offer "Internal transfer" for a cash expense; the rule toast offering a different tag than the one picked (and its Undo restoring the wrong one); a stale bank-balance question when two months are imported in one go; a skipped "read again" row lost for good; the forecast starting from cash and unchecked accounts; IOU links breaking after the bank row replaced a hand-added entry; a lent payment still in the monthly summary CSV and able to mark a bill paid.
  - **Reviews:** every half reviewed as it landed, sync fix re-reviewed, merge delta reviewed; all findings fixed with tests. Mutation testing on the forecast, bank checks, recurring cost and IOU code: every surviving mutant killed or shown equivalent.
  - **Stage run:** importer 400, core 2638, sync 327, relay 216, app 1949, desktop (all files), web-test, emulator screens, perf ok.

- 2026-10-28: **Stage V: sync format before M6** (plan `STAGE_V_PLAN.md`; schema 18, reader 3; statement ticking dropped by the owner; update every device together).
  - **Key id on sealed files (`BWOP3`):** sync files, snapshots, backups and bill files carry the key's id. The app now says exactly "This backup was made with another wallet key" / "That key doesn't open this backup" / "This backup file is damaged" (old `BWOP2` files keep the two-way sentence); a relay file of another key shows in Settings › Sync and is ignored. The web passphrase wrap stays `BWOP2`.
  - **Device state digest:** devices compare a fingerprint of their synced data when they hold the same files; a mismatch re-sends the whole state once (newer change wins as always). Same change time with different values (only a bug or damage) is **never decided by the app**: Settings › Sync › "Your devices have N different values. Choose the right ones." lists each with both values (This device / Other device); the choice syncs. Automatic repair pauses while one is open or after a second mismatch within 7 days ("devices disagree", Save logs). About 270 ms per digest on a 20k-row wallet, once per data change.
  - **Weekly review streak** is stored as one row per review date (two devices reviewing on different days before syncing both count); Recent changes says "Weekly review".
  - **Bugs found and fixed in the stage:** repair asks compared against the wrong clock (devicesDisagree never raised); a resend skipping the schema-15 bill-file re-upload list (files lost for other devices); repair re-uploading every bill file; a stale conflict blocking "agree" forever; the 500-entry cap hiding conflicts for good; a lost row restored by a repair coming back undeleted; a damaged review row for today never repaired; Recent changes showing "Item <date>".
  - **Reviews:** each half reviewed as it landed, VC re-reviewed, merge delta reviewed; all findings fixed with tests. Spec tests written before the code (48) all run.
  - **Stage run** (8dd1f55, before VC): importer 400, core 2722, sync 359, relay 216, app 1962, desktop, web-test, emulator screens, perf ok. Final run after VC (ccfba02): importer 400, core 2727, sync 365, relay 216, app 1978, desktop relay_sync.
- 2026-10-28: **Relay on the Raspberry Pi (PI1):** the owner will host the relay on a Pi at home as a native arm64 binary under systemd (no containers): `tools/build.sh relay-bin` cross-compiles it (Dart 3.13.5), hardened units + native Caddy config in `relay/deploy/native/`, lint step `native-units`. PI2 (OS setup, deploy script, setup.md) waits for the owner's Pi details.

- 2026-10-28: **Stage X: "Set up my wallet"** (spec `X_SPEC.md`; on-device, no AI: the owner chose no API key; no schema change).
  - After creating a wallet (and the save-key sheet) an 8-step guide: bank files → accounts and cash → payday plan → bills and subscriptions (with the month/year total) → extra income → payees without a main tag (top 10, pick a tag = payee rule, Undo) → budgets → "Here's your wallet" (safe to spend, payday, held for bills, accounts, a button per skipped step). Every step: Accept writes only that step, Skip writes nothing. A joined wallet never sees it.
  - Close it half-way → Today "Finish setting up" (Continue / No thanks); Settings › "Set up my wallet again". The welcome cash sheet moved into step 2; the one-off "Looks right?" sheet only shows when the guide never showed the payday plan.
  - Core: `uncategorisedPayees` (rows nothing decides: no rule, pattern or hint; never by amount).
  - Review: 0 blocking, 2 medium (P13 sheet lost after "No thanks"; a restore left "Finish setting up" on a full wallet), 5 low; all fixed with tests. Today and Done share one hero figure.
  - **Stage run** (b825cf2): importer 400, core 2737, sync 365, relay 216, app 2003, desktop, web-test 9, emulator screens, perf ok.

- 2026-10-28: **Stage C2: chart audit** (owner asked after seeing `/dataviz`; audit `tools`-free, by the dataviz guide and its palette validator).
  - Chart-only colours `chartPos`/`chartNeg`/`chart2` (light #3A559E/#A93A32/#A8650F, dark #6F8FE0/#D56F66/#C27F20), validated colour-blind safe in light and dark against the real surfaces (the old dark blue/red failed the lightness band and chroma). Text, buttons, meters (goal bar, pace bar) and status colours unchanged.
  - Income vs spending: "Went out" in amber `chart2`, no longer the status red. Saved/lost chart: legend (only what is drawn). Payday forecast: tap tooltip (date + balance), payday value at the end, screen-reader text. Bars: 4 px rounded data end, square baseline; end dots 4 px with a ring; solid ticks.
  - Review: 0 blocking, 2 medium (legend listed undrawn series; meters took the chart blue), 3 low; fixed with tests.
  - **Stage run** (6833ff6): all green except desktop big_wallet over its 1.5 s import budget while a builder's suite ran alongside (every figure ~3× slower, core imports too); rerun alone on 31878a9: 432 ms, green; desktop chart_dpr + layout green; app 2027.

- 2026-10-28: **Stage M (hardening before M6) + Stage BP (budget presets) + Pi relay groundwork** (owner away; plan `STAGE_Y_PLAN.md`).
  - **Budget presets:** Budget › Budgets › "Start from…": average of the last 3 / 6 / 12 months, spend 10 % less, fit my plan (the payday plan's monthly flexible money split by 6-month share), 50/30/20 (wants = 30 % of salary). Proposals only (current → suggested, Accept all / per row), nothing saved until Save; each shows its total and a one-line explanation; splits add up to the exact euro.
  - **Hardening:** mutation testing on the Stage V/X code (36 invariant tests, no bugs); the state digest now runs in a background isolate on native (UI stall 7–11 ms instead of ~300–550 ms on a 20k-row wallet; web unchanged); the wallet key can no longer reach a log line from a failing `PRAGMA key` (any path).
  - **Pi relay (PI2a):** native relay + Caddy proven on real systemd (Fedora 43, Debian trixie containers): active, health, localhost only, no syscall-filter hits, `systemd-analyze security` 1.3; `tools/relay-deploy.sh native-install|native-upgrade|native-backup|native-status` (token shown once at creation, upgrade rolls back on a failed start, data dir safety); `docs/setup.md` §5 rewritten for the Pi with the owner's open choices.
  - **M6 checklist:** `docs/context/M6_CHECKLIST.md` (159 items in order + disaster drills + known limits) replaces the scattered owner-check lists.
  - Bugs found and fixed: remainder tie-break relied on List.sort being stable; a flaky log test mistook `"ms":80` for an amount; key hex could appear in a database error log line; deploy rollback blocked by systemd's start limit.
  - **Stage run** (4657514): importer 400, core 2799, sync 379, relay 216, app 2042 (1 test failed: it assumed a tall window built all of Settings; fixed to scroll), desktop, web-test, emulator screens, perf ok.

- 2026-10-28: **Stage WS: web sync** (rescoped: the browser already synced through the relay since Stage R). Key wrap `bwk2` (PBKDF2-SHA256 600,000 rounds; a `bwk1` blob is re-wrapped on the next unlock, a failed re-wrap keeps the old one; a blob's round count is capped at 10 million); Content-Security-Policy meta (no inline/off-origin scripts, CanvasKit served from the app; fallback glyph fonts still come from Google: Flutter ships none); tests: two browser wallets and browser + native through one relay, the CSP string pinned. **Bug found and fixed:** a fresh browser showed a blank page (the pre-wallet placeholder database used a path that throws on the web). Review: 0 blocking, 2 medium (unbounded round count could hang the tab; a failed re-wrap reported a failed unlock), 3 low; fixed. Run: app 2053, web-test 13.

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
- Search matches the cleaned description, note and category, not merchant-rule names.
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
- Stage Q money limits (confirmed by the owner 2026-10-28):
  - **One amount cap:** a typed or newly imported amount over 1,000,000,000.00 is refused (the importer allowed 10× that before); an older import up to that old limit still syncs. Sums stay exact up to 90,000 rows at the cap.
  - **IOUs:** a payment can be linked only when its amount equals the IOU or repayment exactly (a payment that was partly a loan: add the IOU without a payment); closing an IOU with money still owed counts it as forgiven and the lent payment never becomes spending.
  - **Red warning per account** uses only bills/incomes whose last payment came from that account; planned costs and bills never paid from an imported account count only in the total forecast. Overdue expected income is never counted.
  - **Bank balance from the file:** none when one app account holds several bank accounts or Revolut pockets of the same currency, or when a one-day file's order is unclear.
  - **Schema 17:** update every device together; a device that stays on an older build for over 30 days after the others upgraded may miss IOUs until they are edited again.

## Next
- In progress (owner away, picked 2026-10-28): **device keys + revocation** (relay api 5). Then the **M6 live test** with `docs/context/M6_CHECKLIST.md`.
- Owner checks after Stage WS (laptop): `tools/build.sh web && tools/web.sh serve` → a fresh browser shows onboarding (no blank page); create a wallet, set the relay address, sync with the phone; reload → unlock with the passphrase.
- Owner checks after Stage C2 (phone): dark mode Spending bars (a deeper blue) and the legend under the saved/lost chart; rounded bar tops on Insights; amber "Went out" on Income vs spending; tap the payday forecast chart.
- Owner checks after Stage X (phone): new wallet → save key → the guide with a real bank file: import preview, accounts + cash, plan, bills, payees (pick a tag, Undo), budgets, Done vs Today; close half-way → Today "Finish setting up" → continue; Settings › Set up my wallet again; large text.
- **PI2 (waiting for the owner):** Pi model, OS (`/etc/os-release`), domain/DDNS name, router 80/443 forward, SSD for the data.
- Owner checks after Stage V (phone + laptop, update both first):
  - Restore a backup with another wallet's key → "made with another wallet key"; cut a `.bwb` in half → "damaged".
  - Sync phone ↔ laptop as usual: nothing new should appear. Settings › Sync shows no "different values" line.
  - Finish a weekly review on the phone, another on the laptop a few days later before syncing → the streak counts both.
- Owner checks after Stage Q (phone + laptop, update both first):
  - Add expense: type "lunch" → chips under the note; tap one; the payee list while typing.
  - Set the same main tag by hand on 3 payments of one bank payee → "Always put X in Y?" → Make rule → Undo. Settings › Rules › Suggested.
  - Search: filter chips (try Amount with 1.234,50 style), bold matches; the search button on Today's Recent panel.
  - Import a PBZ file: preview sheet (Skip one row, Cancel once), then "What did the bank app show?" → type a wrong number → "Off by" → Correct balance. Import a Revolut file: "matches the bank ✓".
  - Today: a red "goes below zero" line when a bill would overdraw a checked account; Budget: "On payday: about X" + chart.
  - Save › Owed: add an IOU, a repayment, Close, Delete → Undo; on an expense "Lent to someone" → it leaves the Budget totals but stays in the list with "lent".
  - Bills: "Bills and subscriptions: X a month · Y a year". Settings › Sync › Recent changes after a sync.
- **Plan for all the notes below + further development: `docs/context/OWNER_NOTES_PLAN.md`** (stages N0–N4, decisions D8–D12, delegation table).
  N0–N4 built 2026-10-25. Open: perf over budget on this laptop since 10-24 (host slowdown, not the code; rerun after a reboot). N4 ready (D10: slips + bank payments, one line per month).
- Owner checks after Stage J + J4 (phone): nothing should look different; sync phone ↔ laptop through the relay both ways (J4 moved the sync code). Try the bill sheet (confirm, save), the Today lines, import and backup buttons (busy while working), calendars refresh, search → delete → Undo; after a sync from the laptop, numbers update without reopening.
- Owner checks after P16b + P5 (phone):
  - Five tabs at the bottom; Budget starts with the payday plan, Edit plan saves/cancels; Save shows goals above the wishlist.
  - Bills: Coming up first, then slips to review, Expected bills, the bills list; Scan bill and Add bill work. Today's "Due by payday" and "N bills to review" open Bills.
  - Settings: one page with every section; Today's held-money and expected-income lines jump to their section. On the laptop (wide window) Settings has two panes.
  - Open a payment › Attach photo or PDF: take a photo (allow, then once refuse the camera), pick a PDF; open it; Remove → Undo; the button goes away at 5.
  - Attach a receipt to a hand-added expense, import the bank file → the receipt is now on the bank row.
- Owner checks after P12/P14/P16a (phone + relay):
  - Import a CSV from another bank or app: Map columns, fix a problem it shows, Save & import; import the same file again → nothing new; Settings › Import › Saved file layouts: rename, delete + Undo.
  - Update the relay to api 4 with the phones; scan a bill with a photo, sync, delete the bill → the file still opens on the other device until it syncs; Undo the delete → the photo is there.
  - A bill with an IBAN: Pay → copy the IBAN and amount into the bank app; Copy all. Payday plan shows the loan payments left.
- Owner checks after P13 (phone):
  - Add the "Safe to spend today" widget; it matches Today; tap opens the app; after midnight it says "Open the app to update" until you open the app.
  - Long-press the app icon → Add expense, with the app closed and with it open (it must not restart).
  - Plan › Calendars › allow access: Android asks for read access only; events still show in Upcoming.
  - Import a bank file into a new wallet: "Looks right?" appears once.
- Owner checks after P15 (phone):
  - Plan › Currencies: set a rate for a currency you paid in (e.g. 0,9240); Today and Spending totals change, the "not counted" line goes away; the payment shows both amounts; Remove, then Undo.
- Owner checks after P8 (phone):
  - Spending › Insights, last two panels: per pay period numbers and a main tag against its budget.
  - Finish a weekly review: the Done screen shows the streak and what waiting saved.
- Owner checks after P9-P11 (phone):
  - Plan › Expected income: confirm a suggested side income, or Add income; before it lands Today says "Expected income … (counts when it lands)" and safe-to-spend doesn't move; after the import the payday plan shows "Extra income received".
  - Plan › Backup › Merge a backup…: read the preview, Cancel changes nothing; merge, then merge the same file again ("Nothing new").
  - Plan › Look › 1.234,50: amounts change everywhere; type "1.500" as an expense → 1500 €.
- Owner checks after P6 (phone):
  - Open a supermarket payment › Split…: enter two parts, watch "Left to split"; Save stays off until it is 0.00.
  - Spending shows the payment once with its parts under it; the category view shows each part.
  - Remove split, then Undo: the parts come back with their tags and notes.
  - The split editor with 5+ parts at large text size.
- Owner checks after P4 (phone):
  - Plan › Expected bills › Add bill: a yearly bill (e.g. insurance) → Today shows "… held until paid" and safe-to-spend drops by the full amount.
  - Add a bill with "The amount changes" (from–to): it sets aside the top of the range.
  - Add a monthly bill with instalments (e.g. 12): "12 payments left"; Edit, rename, Save: the count stays.
  - A bill without payee: Mark paid, then Undo.
  - Check the add sheet fits at phone width with range and instalments on.
- Owner checks after P7 (phone):
  - Plan › Rules: add a "description contains" rule with a range, then Preview and Save.
  - Try a range with no text: it is refused.
  - Edit a rule and check the Preview count.
  - Delete a payee rule, then Undo.
  - "Make a rule…" from a bank payment.
- Owner checks after T1 (phone):
  - Open a bank payment:
    - pick a main tag and add two extra tags, tap a suggestion, and create a new tag;
    - close the sheet with X: nothing is saved. Then do it again and tap Save.
  - Remove a tag that came from a rule: it goes from that payment only.
  - Use "Also tag every payment from …".
  - Check Plan › Tags, the `#tag` chips on rows, Insights › Tags with its drill-down, and search by a tag.
- Owner checks after P1 (phone):
  - Plan › Categories:
    - add a category, then a subcategory under Groceries; add an expense in it;
    - check the subcategory is indented in the picker and rolled up in Spending › Where it goes, and that the drill-down lists it.
  - Rename and hide a built-in category.
  - Add your own fixed category, fill its line in Plan › Edit, and check today's amount drops; then delete it and read the warning.
  - Search by your category's name.
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
