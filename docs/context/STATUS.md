# Budget Wallet — Status (source of truth since 2026-10-19; no personal figures here)

**Plan (owner, 2026-10-16):** automated tests now → M3 Views → M4 Habits → M5 Polish → web version → cross-device
sync (works on Android, Linux and web) → **M6 live test** by the owner. Platforms: Linux, Android, web.

**Current milestone:** M2 Standalone app — v2.0 first builds published for all platforms (branch `v2`), waiting for owner testing. v1 web app still live.

**Sync:** relay on the home server (stage R, 2026-10-22); Syncthing is no longer used.

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
- Build order (owner 2026-10-22: every feature first, the owner tests last): future spending (done) → bills database
  (done) → outside reviews (done, `docs/review/`) → Stage G foundation (done 2026-10-23) → **Stage H hardening → Stage I UI quick wins → M6 owner live test**
  (plan with every review KEEP/CHANGE placed, delegation, owner decisions D1–D7 in `PATH_FORWARD.md`; queue in `PIPELINE.md` Stage G/H/I).
- M6 adds four disaster drills to the owner checks (`PATH_FORWARD.md` §4 M6): new phone with the relay alive; new phone
  with the relay dead + `.bwb`; relay address switched to a second relay and back; laptop clock a day ahead for one sync.

## In flight (2026-10-20)
- Queue and procedure: `docs/context/PIPELINE.md`.
