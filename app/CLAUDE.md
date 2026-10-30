# app — notes for Claude

Flutter UI for Android, iOS, Windows, macOS, Linux. **No money logic here**: calculations belong in
`wallet_core` (with unit tests); the app formats and displays them.

## Files
- `lib/main.dart` — app shell (`HomeShell`): bottom bar on compact windows, `NavigationRail` from 600 dp, one shared destinations
  list (the app bar with search icon, sync spinner and pay-period chip exists on compact windows only; from 600 dp the rail holds `appBarSearch`, `periodBadge`
  and the spinner, so nothing stays pinned above the page), Ctrl shortcuts (Ctrl+1..5 tabs, Ctrl+N add expense (Today's `addExpense` button is the only add button: no FAB, nothing in the rail; owner 2026-10-30), Ctrl+R/F5 sync, Ctrl+, Settings; logged as `nav.key`).
  The pages are built once (see below) and the body keeps the same widget shape at every size (keyed `Expanded`), so a
  resize keeps every page's State: never build pages in `build()` or a `LayoutBuilder`.
- Tabs (P5; spec `docs/context/P5_SPEC.md`): `Today · Budget · Bills · Save · Settings` (`lib/src/tabs.dart`: `Tabs.today|budget|bills|save|settings` = 0..4 and `Tabs.names`; bar/rail destination keys `tab:today|budget|bills|save|settings`;
  Ctrl+1..5, Ctrl+, = Settings; `wc.openTab(Tabs.x)`, `wc.openSettings(SettingsSection, via:)` = the tab then `wc.settingsRequest` (a `JumpRequest`); `openWish` = Save). **Where the old Plan went** (every older "Plan ›" in these notes means the new place):
  Payday plan + suggestions (`screens/payday_plan.dart` `PaydayPlan`, the old `PlanScreen` state with its keys) = on top of **Budget** (`SpendingScreen(header: [PaydayPlan])`, in the left column of `TwoCol`; Budget = the old Spending tab under it);
  Expected bills + the bills database (`BillsPanel(showReview: false)`) + `ComingUpPanel` (core's `dueCycles`, `comingUp:<bill>:<due>`, `comingHeld:<bill>`) + a "To review" panel (`billsReviewPanel`, rows `BillRow`) + `billsScan` / `billsAdd` = **Bills** (`screens/bills_tab.dart`, one `SingleChildScrollView`;
  `BillsAnchor.comingUp|review|expected|slips` through `JumpRequest`, Today's "Due by payday" = comingUp, "N bills to review" = review); Goals panel then Wishlist (both `embedded: true`, no list of their own) = **Save** (`screens/save.dart`);
  everything else = **Settings** (`screens/settings.dart`: `SettingsSection` order Accounts [+ Currencies], Main tags and tags, Rules, Budgets per category, Expected income, Import [+ layouts], Sync [+ Another wallet / This browser],
  Backup and export, Calendars and reminders [+ Nudges, Weekly review day], Month, Look, Diagnostics; `settingsPanels(context, wc, section)` builds a section's panels; small panels in `screens/settings_panels.dart`).
  Below 1040 dp of content one page (`settingsPage`, a lazy ListView; a link scrolls with `widgets/scroll_to.dart` `scrollToKey`); from `twoColMin` two panes: `settingsList` (`settingsNav:<section>` rows: title, one-line sub, chosen = tint + bold + arrow) and `settingsPane` (the chosen section; a link selects it, `currencies` selects Accounts).
  Tests: `test/p5_tabs_test.dart`; tests of what a moved panel does (not where it sits) pump `test/support/plan_page.dart` `PlanPage` (all the old Plan panels in one list); integration tests use `goSettings(t, section)` / `settingsSection` / `pageList(SettingsScreen)` from `integration_test/support/harness.dart`.
- `lib/src/layout.dart` — `LayoutSize` (compact < 600, medium 600–1023, expanded ≥ 1024) and `sizeFor(width)`; decide on the
  window width (`MediaQuery.sizeOf`/`LayoutBuilder`), never on the device type. Content max width 720 (medium) / 1040 (expanded);
  `TwoCol(left, right)` = two columns when the content is ≥ 1040 wide (Today, Spending), `NarrowPage` = 720 (Wishlist, Plan).
  `showSheet` opens a dialog (max 480) from 600 dp, a bottom sheet below; callers don't change.
  Shared UI helpers: `rowMin`/`touchMin`/`buttonMin` (44/48/52 dp minimum heights), `gapped()`; `widgets/sheets.dart` `openPageOrDialog<T>(context, screen, {width, maxHeight, logName})`
  + `DialogAppBar(title, actions)` for full-screen pages that are dialogs on wide windows; `widgets/common.dart` `MoneyField` (decimal keyboard; `fieldKey` for tests), `RuledRow`,
  `GatePage` (first run / unlock / in use); `format.dart` `centsToFieldText`, `invalidAmountMessage`; widgets read the clock as `wc.now`, never `DateTime.now()`.
- `lib/src/platform.dart` — `isAndroid/isIOS/isWindows/isMobile/isDesktop/hasKeyboard` from `kIsWeb` + `defaultTargetPlatform`.
  Use these, not `Platform.isX`. Tests set `debugDefaultTargetPlatformOverride` (and must unset it before the test body ends).
- `lib/src/controller.dart` — `WalletController` (ChangeNotifier): owns the `WalletRepo`, the cached lists,
  sync timers. Screens call controller methods; the controller calls the repo and `notifyListeners()`.
- Smaller files: `lib/src/conflict_text.dart` (texts for one sync conflict row: item, field, both values; also which integer columns are times, not money), `lib/src/hero.dart` (`HeroFigure`: the one number under Today's heading and on the setup wizard's last step, so the two cannot drift), `screens/sync_conflicts.dart` (Settings › Sync › "Choose the right values": same field, same clock on two devices; two buttons write the owner's choice), `controller_rules.dart` (the Add / Edit rule form's state and preview, amount-only rules shown but never classifying), `controller_splits.dart` (`SplitsDb`: split payments, a `part` of controller.dart; the core checks every rule), `log_stats.dart` (`LogStats`: log file count, bytes and failed writes since start, for Diagnostics).
- Q0 split of `controller.dart` (moves only): `controller_sync.dart` (`WalletSync`), `controller_import.dart` (`ImportAndBackup`: import, backup/restore/merge, CSV exports), `controller_review.dart` (`ReviewHabits`: review, habits, recurring marks), `controller_settings.dart` (`DeviceSettings`), `controller_tx.dart` (`TxEdits`). Public members that tests reach without importing `controller.dart` (`createWallet`, `syncNow`, `importFiles`, `addExpense`, `updateSettings`, key-backup prompt) stay on the class: an extension member is visible only where its library is imported. Inside an extension an unqualified name resolves to top-level functions before class members (`this.budgetVsActual`).
- Stage Q2 UI X (docs/context/STAGE_Q_PLAN.md Q4, Q5, Q8, Q10, Q11): `controller_forecast.dart` (`ForecastDb`: `bankChecks()`, `recordBalanceCheck`, `appBalanceOn`, `balanceWarningList()`, `paydayForecast()` -> `PaydayForecast`, `billsCost()`; core does the sums) and
  `controller_iou.dart` (`IouDb`: `iousAll/iousOpen/owedTotals/iouById/iouTags/iouTagOf/repayableBy` + add/update/close/delete(+undelete) of IOUs and parts; core's `ArgumentError` text is shown). **Q4:** `importFiles(confirmPreview:)` (`ConfirmPreview` returns the skip set, null = Cancel);
  the preview runs after the CSV layout is decided and with the same revive set as the import. A new layout that removes no payments is saved only after Import (`_ReadFile.commit`), so Cancel writes nothing; a layout that replaces earlier payments must be saved first (the preview needs the revive set) and Cancel undoes it (`_ReadFile.revert`, `undoCsvRemap`).
  `screens/import_preview_sheet.dart` (`importPreview`, `importPreviewSummary`, `previewGroup:<status>`, `previewSkip:<txId>`, `importPreviewImport|Cancel`); Settings › Import `importPreviewAlways` (device-local `importPreview`, default on; `pickAndImport` passes the callback only when on). **Q5:** the import result line says "X matches the bank ✓" or "X is off by Y: see rows since D" + the pending note
  (from `ImportSummary.bankChecks`); `ImportLine.questions` (`BankQuestion`) = accounts the file gave no balance for, asked by `pickAndImport` with `accounts_panel.dart` `BankCheckSheet` (`bankCheckMatches|Save|Skip|Amount|Correct|Leave`; "Off by" opens `CorrectBalanceSheet(prefill:, date:)`, nothing is corrected by itself); Settings › Accounts `accountCheck:<id>`, `accountChecked:<id>`;
  Today `balanceWarn:<accountId>` (`TodayView.balanceWarnings()`). **Q8:** `screens/owed.dart` `OwedPanel` (Save tab; `owedPanel|owedAdd|owedSummary|owedShowClosed|iou:<id>`), `IouSheet` (`iouSheet|iouPerson|iouDirection|iouAmount|iouDate|iouNote|iouSave|iouAddPart|iouPartAmount|iouPart:<id>|iouPartDelete:<id>|iouClose|iouDelete|iouProgress|iouError`),
  `RepaymentSheet` (`repayPick:<iouId>`); TxSheet `txLent` (expense) / `txRepayment` (income) or `iouLinked`; `TxTile(iouTag:)` shows lent/borrowed/repaid on Spending, category and tag lists. **Q10:** `recurringCost` header on Expected bills. **Q11:** `ForecastPanel` under the payday plan (`forecastPanel|forecastLine|forecastAfter|forecastChart`), `charts.dart` `ForecastStepChart`. Tests: `test/q_import_preview_test.dart`, `q_balance_ui_test.dart`, `q_owed_test.dart`, `q_forecast_test.dart`.
- J1 (controller seams): `controller_deps.dart` `WalletControllerDeps` = one immutable object with the clock, the `KeyStore` instance, the platform objects and every function seam (sync, health check, backup, key, join marker,
  database files, device id, clipboard, `.ics`, PDF, bill category). `WalletController.load({deps, claim})` / `forTest(repo, deps:, clock:, …)`; `WalletControllerDeps.platform({dbDir, keyStore, …})` holds the real ones, `copyWith` replaces some.
  Nothing is reassigned after the controller exists: tests that swap a seam mid-test use `test/support/seams.dart` (`seamedController(...)` / `seamedLoad(deps)` instead of `forTest`/`load`, then `wc.seams.syncRunner = …`; the deps forward to those fields).
  `tabHook` stays a plain field (the home shell registers itself). `KeyStore` is an instance (`KeyStore(keyDir:)` on native). `wc.sync` (`SyncState`) and `wc.cal` (`CalendarState`) are `Listenable`s (`sub_state.dart`): their setters mark them
  changed and the controller's `notifyListeners()` tells them right after its own listeners, so the controller notifies exactly as before (`test/sub_state_test.dart`); the old `wc.syncError` etc. forward to `wc.sync`.
  Memo keys are `MemoKey(name, args)` (`memo_key.dart`), never joined strings. `screens/today_view.dart` `TodayView` and `screens/upcoming_view.dart` `UpcomingView` are the read-only facades `TodayScreen(view:)` / `UpcomingScreen(view:)` take instead of the controller (`Listenable`; they launch the sheets those pages open).
- Budgets (E1): `categoryBudgets` (monthly cents per category), `budgetVsActual(month)`, `suggestedBudgets(month)`, `tightestBudget()`
  (cached like `spending()`), `saveCategoryBudgets(map)` (logs `budgets.saved` with the count only). Spending's "Where it goes" bars use the
  budget as the 100 % mark (`CategoryBars(budget:)`: ruled track, hatched `bad` stretch and "over by 12 €" when over, "48 € left" otherwise,
  summary line and a total row under a `TotalRule`); Today shows one tappable line for `tightestBudget()` (`TodayScreen.openSpending`).
- Money screens (stage H): never print a negative allowance or "0 days". Today reads `PeriodBudget`: `paydayPassed` = eyebrow "Left this pay period", `periodEnded` label, the
  `startNewPeriod` button in its own `periodEndedPanel` above the main panel (`startNewMonth(currentPeriodStart(...))`: one tap over several missed paydays; hidden when a salary row already offers a new month) and "today's money" texts (delivery-hour panel too) say the period ended, never "used";
  `overToday` = "Over today by" and the amount; `overBy`/`overBudget` = the `overBudget` line ("Over the plan" label, never green "On plan"; no pace bar when `planDaily` ≤ 0); small overs show to the cent; plan per day shows 0 when core says it is ≤ 0, and Plan's heading says "Nothing to spend: the plan is X over". Plan uses `p.lowIncome` (the 7-day
  window is core's) and sends the payday as typed (core clamps 29–31 to 28). Wishlist shows `Verdict.overBudget` (`verdictOverBudget`) and, once the payday passed, `verdictEnded`.
  `ForeignNote(map)` (`foreignNote`) = one muted "Other currencies, not counted: 12 $ spent" line (`moneyExact` of the absolute value, spent/received, sorted by code) from `PeriodBudget.foreignByCurrency` on Today and
  `MonthSummary.foreignByCurrency` on Spending's month panel, only when non-empty. Tests: `test/money_screens_test.dart`.
- Today day dots (DD; spec `docs/context/DD_SPEC.md`): right of the hero number, `widgets/charts.dart` `DayDots(days:)` (key `dayDots`) = one 13 dp square per day of the pay period in Monday-first weekday columns (`dayDot:<date>`: within = accent fill, over = `bad` fill with a thin hatch, today = thick accent outline, to come = thin `lineStrong` outline) and one muted line `dayDotsCounts` ("12 within · 3 over", omitted while both are 0); one spoken label for the whole grid (`DayDots.label`), squares and counts are not read. `wc.periodDays()` (memo `periodDays`) / `TodayView.periodDays()` hold core's `periodDays`; the widget does no verdicts. `_HeroNumber` (today.dart) measures the number at the current text scale and keeps the dots beside it whenever it can: the number may scale down to 65 % (`_minScale`) and the squares to 11 dp (`DayDots(compact: true)`); only if even that does not fit (320 dp at large text, a huge amount) the grid goes under the number, left-aligned. Tests load the real Plex fonts (the test font is far wider). `PaceBar` is gone from Today (Period reports keeps it); `_PaceSummary` stays. Tests: `test/dd_day_dots_test.dart`.
- Derived values (`period()`, `payPeriods()`, `spending(month)`) are cached in the controller per `dataVersion` (bumped by
  `reload()`) and day: never compute from `txs` in `build()`. `HomeShell` builds the five pages once per data version and day
  (`'${dataVersion}|${today()}'`), so a tab switch only moves the `IndexedStack` (keep it that way: 20,000 rows made every
  switch miss frames). The controller takes a clock (`forTest(clock:)`); `checkDay()` (resume, 2-minute timer) notifies when
  the day changed, so a wallet without a relay also moves on at midnight.
- Background work (stage PF, owner 2026-10-30; 60 Hz target, frame budget in the root `CLAUDE.md`): `HomeShell` fades the opened page in (`TabFade`, 180 ms, `tabFade:<tab>` keys; at once with `MediaQuery.disableAnimationsOf`; the `IndexedStack` and every page's State stay; a page that is not ready stays invisible until it is).
  On a new data version or day only the shown page is built; the other four are built one at a time when the app is idle (`_stageNext`, after the warm-up), an unbuilt slot holds `tabPlaceholder`. A tab opened before its page is ready for the current data (`_go`) works its data out one task per frame (`WarmUp.perFrame`, `wc.warmUpTasksFor(tab)`) while the fade runs, then builds the page (`_prepare`); a page built for older data stays shown meanwhile.
  **A request to a page that may not exist** (a link, a search, an anchor): `JumpRequest` keeps a request nobody listened to as pending and a page collects it in initState with `jumpWhenBuilt(request, () => mounted, _jump)` (`widgets/jump_when_built.dart`; Bills, Settings; Wishlist reads `highlightWish` in initState); a plain notifier goes through `HomeShell._goThen(tab, via, then)`, which runs `then` once the page is built (search). A new screen with a jump target (the RX4 Budget switch) uses one of the two.
  `warm_up.dart` `WarmUp` runs the task lists of `controller_warmup.dart` (`warmUpTasksFor(tab)`, `warmUpTasks()` = all tabs + the default Insights ranges; one memo per task, a month of the Spending figures per task) as separate event-loop turns, started after the first frame is rasterized and after every data/day change (`wc.startWarmUp`), ended when the data version changes. `WarmUp.whenIdle` runs a task only when nothing animates, no frame is scheduled, frames are on (app shown), no pointer is down and none was busy for 300 ms (a global pointer route); while hidden it looks every 500 ms.
  Logs `warmup.done {tasks, ms, slowest, slowestMs, wallMs}` and `warmup.slow {task, ms}` (a task over 16 ms: split it; fixed names only). Known unsplittable: core's `recurringPayments` (~90 ms at 20k rows). A new derived value that a tab reads first belongs in `warmUpTasksFor`. `WarmUp.enabled` is false in `app/test` (`test/flutter_test_config.dart`: an idle task is a pending timer to fake async; `WarmUp.resetPointerState()` clears the quiet-period timer); `test/pf_warm_up_test.dart` switches it on. In an integration test frames come only when pumped, so give the pages pump time (`integration_test/adaptive_test.dart`).
- Habits (M4): `screens/review.dart` (`openReview` = page on phones, 560 dp dialog from `dialogMin`; `ReviewScreen` = four ruled steps with a
  square tick: Import (`screens/import_flow.dart` `pickAndImport`, shared with Plan), Confirm categories (`reviewRows()`: the rows core counts;
  "Looks right"/"Change" call `confirmCategory` = pin the category + teach the merchant, so the row leaves), Pace (`paceRows()`, tap → Spending),
  Wishlist (`readyWishes()`, `buyWish`/`skipWish` from wishlist.dart); Done → `markReviewDone()`). Today shows the "Weekly review" card while
  `reviewState().due`, "Reviewed · N weeks in a row" after Done, and "Due by payday: 3 bills, 182.40 €" from `period().dueBills`/`reservedBills`
  (bills in a fixed category are named "covered by your plan" and left out of the sum; an unpaid bill past its date says "overdue").
  `screens/habits_panels.dart` = Plan's review-day chips (`setReviewDay`), Expected bills (`recurringBills()`: candidates → Confirm / Not a
  bill; confirmed rows with Paid/Overdue/Covered and Remove) and Nudges (a device-local switch, `setNudges`). The "Due by payday" tap
  switches to Plan and scrolls to Expected bills (`PlanScreen.showBills`, a notifier owned by `HomeShell`).
  Controller log events (counts and enum words only): `review.done`, `review.day`, `recurring.confirm|dismiss|delete`, `nudges.enabled|scheduled`.
- Recurring bills beyond monthly (P4; spec `docs/context/P4_SPEC.md`): `controller_recurring.dart` (a `part`: `extension RecurringDb`) = `recurringPayments()` (core's `planRecurringPayments`, cached),
  `billPartsPaid(b)`, `addRecurringBill` / `updateRecurringBill` (throw core's `ArgumentError` text; both run `refreshRecurring`; logs `recurring.added|edited` with period word and flags only),
  `restoreRecurringDue` (the Undo of Mark paid). `screens/recurring_sheet.dart` = `RecurringFormSheet` (`recurringSheet`: name, main tag, amount or "The amount changes" From/To (the highest is saved as the amount),
  how often chips `recurringPeriod:<name>`, first/next due, payee from `recentPayees()` (add only), "Instalments"/"Payments left"; `recurringSave`, error `recurringError`) + the period/range/instalment texts.
  Plan › Expected bills: `addRecurring` button, per row period (not for monthly), `billRange:`, `billInstalments:`, `billParts:` ("60 of 100 € paid"), `billHeld:` ("Held in full until paid"), `recurringEdit:`,
  and `recurringMarkPaid:` (replaces Skip when parts are paid or the bill has no payee; Undo through `restoreRecurringDue`). Today's bills line reads `p.dueCycles`: "1 bill (4 payments), 120 €" and one
  "Name 600 € held until paid" line per long bill due after payday (`billHeld:<id>`). Bill history lines of a non-monthly bill are keyed `historyMonth_<due>` ("Due 14 Jan 2027"; parts shown as "Part").
  Tests: `test/recurring_ui_test.dart`; the demo wallet has a yearly and a weekly bill (`seedDemoBills`).
- Recurring income (P9; spec `docs/context/P9_SPEC.md` §6): `recurringBills()` also holds incomes; widgets and controllers that treat rows as bills read `expectedBills()` (no incomes), the income panel `expectedIncomes()` (both cached).
  `screens/habits_panels.dart` `ExpectedIncomePanel` (`expectedIncomePanel`; `incomeCandidate:|incomeConfirm:|incomeDismiss:|income:|incomeEdit:|incomeDelete:<id>`, `addIncome`) opens `RecurringFormSheet(income: true)` (`incomeSheet`: main tags of kind extra, payee from `incomePayees()` required, no instalments;
  core's text shows as `recurringError`). Delete's Undo is core's `undeleteRecurring(id)` (same id; `wc.undeleteRecurring`); `incomePayees()` offers only payees whose incoming rows are all kind extra. Plan ledger: `ledgerLandedIncome` ("Extra income received +300 €", `p.landedIncome`) and `ledgerExpectedIncome` (one muted "Expected, not counted yet: …" line per `p.expectedIncome` cycle);
  Today `expectedIncomeLine` (tap = `openIncome` → Plan scrolls to Expected income via `PlanScreen.showIncome`; no chevron without it); Goals reads `p.extrasForGoals`. Tests: `test/p9_income_ui_test.dart`; the demo wallet confirms its monthly side income (`seedDemoBills`).
- Insights (N3): Spending's **Insights** button (`insightsOpen`) opens `screens/insights.dart` `InsightsScreen` (page on phones, 760 dp dialog from `dialogMin`): five
  panels (`insightGraphs`: spending per month, category share, income vs spending, budget vs actual, biggest payments), each with its own **`RangeControl`**
  (`widgets/charts.dart`: chips This pay period / Month / 3 / 6 / 12 months / Custom, ‹ › steps (forward off at the current range), the dates button opens
  `showDateRangePicker` for a custom range, core's `ArgumentError` text shows inline as `rangeError_<id>`; arrow keys on the dates step; keys
  `rangeChip_<id>_<kind>`, `rangeBack_|rangeLabel_|rangeForward_<id>`). Range state = `InsightRange` (`lib/src/insights_api.dart`, one per graph from
  `wc.insightRange(id)`; kind remembered device-local as `insightRange:<id>`, the offset is not). The same file's `WalletInsights` extension holds the graph data
  per range (`spendingBars`, `shareFor`, `incomeBars`, `budgetBars`, `merchantsFor`, `rowsOf`, `merchantBars`, `categoryBars`, `compareFor`, `biggestIn`), all memoized by
  `wc.memo` per data version + day (key = range dates): never call wallet_core's insights functions from a widget. Drawing: `widgets/insight_charts.dart`
  (`MonthlyBars` = fl_chart grouped bars, snapped strokes, a partial month faded + dashed; `ShareBars` = horizontal rows with permille percent; `Legend`).
  Every graph has its exact amounts as rows under it and a spoken summary; `ForeignNote` (`foreign_<id>`) when core reports other currencies.
  Budget bars are whole calendar months, the running one "so far". Drill-down: `screens/category_detail.dart` `openCategory(context, wc, category, range)` from a
  share row or a "Where it goes" row on Spending (`categoryRow_<name>`, month range): compare (this/last month, 6-month average), per-month bars (the merchants'
  trends added up), merchants (`merchantRow_<key>`) -> one merchant's rows (`TxTile`, editable) with `detailBack`. Tests: `test/insights_test.dart`;
  perf action `insights` in `integration_test/perf_test.dart`.
- Plan (N1): one "Payday plan" section. It lists the ledger lines (`planHeading`, `ledgerSetAside`, `ledgerSpendingMoney`) with an **Edit** button (`planEdit`); Edit swaps in the number
  fields (same `_keys`, same `_savePlan`) with **Save** (`planSave`, closes the editor on success or "Nothing to save", stays open on an error) and **Cancel** (`planCancel`, restores the
  shown values and the currency). Tests tap Edit first: `openPlanEdit(tester)` in `test/support/wallet.dart`, `edit(t)` in `integration_test/plan_test.dart`; `test/plan_edit_test.dart`.
  Plan › "Another wallet" › **Join another wallet…** (`joinAnother`, not on the web: no set-aside path there): `screens/join_another.dart` shows the warning sheet, then pushes
  `OnboardingScreen(replaceCurrent: true)` (join step only; its "Cancel" pops and changes nothing). Continue is offered only after this wallet's own key was saved (`keyBackupConfirmed`; the sheet sends the owner through the last-four `openKeyBackup` first; the controller throws `KeyNotSaved` too).
  Only the join itself calls `wc.joinAnotherWallet(text, relay:)`: key, relay, `KeyNotSaved` and `WalletAlreadyOpen` (same key) are checked, then `_setAsideOpenWallet`: wait for a running sync (`_syncRun`) and push pending
  changes once, then `_joining` = true (`syncNow` skips; `_syncRun` is checked again right before `old.close()`), `keyAsideWriter` stores the old key in a second slot (`KeyStore.writeAside(stamp, key)` → `wallet.key.aside.<stamp>[-n]` /
  secure-storage `budget_wallet_key_aside.<stamp>`; never read yet, kept by `forget`), a **join-pending marker** is written (`KeyStore.writeJoinMarker`: `join.pending` beside `wallet.key` / secure-storage `budget_wallet_key_join_pending`;
  JSON `{v, relay, id}` = relay address and a fresh device id, no key, never in the database), the new key is written, then the database is closed and `dbSetAside`d (`wallet.db.unopened-<date>`, `db.setAside {reason: join}`, never
  deleted; `setAsideWalletDb` renames what it already moved back if a later rename fails), sync status is reset, then `joinWallet(keyWritten: true)`, then the marker is cleared.
  **The old key never leaves the device while the old database exists** (a slot is removed only once the old wallet is open again): a failed key write writes the old key back first and drops slot + marker only if that worked; a failed set-aside
  checks `dbExists()` (wallet.db gone = partial move: no reopen, onboarding + `hasUnopenedDb`, slot kept, marker cleared), else writes the old key back, reopens, and only then drops slot + marker; if the reopen fails too: `key = null`,
  `hasUnopenedDb = true`, slot kept. **Crash recovery:** `WalletController.load` reads the marker (`joinMarkerReader`); marker + key that opens no `wallet.db` (absent, or a mismatch: the old file is set aside now) → the new wallet opens with the
  marker's device id, the marker's relay is saved, `keyBackupConfirmed` is set, the marker is cleared and the normal start-up sync follows (`wallet.joinResumed`); marker + a wallet that opens → just clear it (relay filled in if missing). A failure
  after the set-aside sets `key = null`, marker kept. Tests: `test/join_another_test.dart`, `test/key_store_file_test.dart`, `test/wallet_db_io_test.dart`.
- Accounts and plan suggestions (N2; core API in `docs/context/N2_SPEC.md`): `controller_accounts.dart` (a `part`: `extension AccountsDb`) = `accountsAll()`, `accountBalanceList()`,
  `heldTotals()` (cached per data version), `addAccount/renameAccount/correctAccountBalance/deleteAccount/undeleteAccount` (async; an `ArgumentError` carries the owner-readable text),
  `planSuggestion()`, `planProposalList()` (core's `planProposals` minus the ones put off), `acceptPlanProposals({only})` (`updateSettings` with the setting keys, salary also sets
  `salaryConfirmed`; `plan:<id>` proposals go to `setPlanLine` through `savePlanLines`), `putOffPlanProposal(key)` ("Not now": device-local `planNotNow:<key>` = the suggested value, hidden until that value changes). Logs `accounts.*`, `plan.suggestion.*`
  (keys and `cash` flag only). Screens: `screens/accounts_panel.dart` (Plan › Accounts, after Payday plan: a row per account with `MoneyText` balance in its own currency and
  "as of <last row or opening date>", Rename / Correct balance / Delete with the Stage I Undo toast, a muted "X: duplicate of Y, not counted" row for `duplicateOf`, a `Total <CUR>` line per
  currency, never mixed; `AccountFormSheet` type = Cash or an importer bank profile, name follows the type until edited, currency, balance + "Below zero" box, date not after today;
  `ArgumentError` text shown under the field or as `accountError`), `screens/plan_suggestions.dart` (Plan › "Suggestions from your imports", shown only when proposals exist: current →
  suggested, a basis sentence, Accept / Not now per row, Accept all from 2 rows; nothing is written without a tap), the cash question lives in the setup wizard's step 2 (stage X; the old `welcome_balance.dart` sheet is gone: Cash account in the wallet currency dated today, only with a tap), Today's `heldLine` ("Held: 1,234.56 € · 80 $", only with accounts; `TodayScreen.openAccounts` → Plan scrolls to Accounts through `PlanScreen.showAccounts`).
  Budgets Suggest (`budgets.dart` + `suggest_budgets_dialog.dart`): core's `budgetProposals(fields as typed, suggested)`; empty fields are filled at once, fields with a number open a
  dialog (checkbox per row, Accept ticked / Accept all / Cancel); a field with text that is no number is left alone; only Save writes. Tests: `test/accounts_ui_test.dart`,
  `test/plan_suggestions_ui_test.dart`, `test/budgets_plan_test.dart`, `integration_test/onboarding_test.dart` + `plan_test.dart`; demo accounts: `seedDemoAccounts`.
- Other currencies (P15; spec `docs/context/P15_SPEC.md` §3): `reload` makes `wc.txs` = core's `inHomeCurrency(expanded, settings)` (rows with an owner-set rate are in the wallet currency, `originalAmount`/`originalCurrency` kept);
  `wc.rawExpanded` is the unconverted list, `wc.wholeTxs` stays raw (matching, accounts, pickers, TxSheet) and `wc.shown(t)` gives a whole row converted for lists (Spending, Today). `controller_fx.dart` (`extension FxDb`) = `fxCurrencies()` (a row per
  currency other than the wallet's seen in `wholeTxs` or holding a rate), `setFxRate(code, rate)` / `removeFxRate(code)` (core's `ArgumentError`; logs `fx.set|remove|open`, no values), `openCurrencies()` (tab 4 + `currenciesRequest`, which Plan scrolls to).
  `screens/currencies_panel.dart` = Plan › Currencies (after Accounts; `currenciesPanel`, hidden with no foreign currency or rate; row `fx:<CODE>`: "USD — 1 $ = 0.9240 €, set 25 Oct" with `fxEdit:`/`fxRemove:` (Undo sets the same rate again), or "USD — Not counted" with `fxSet:`;
  `FxSheet` `fxSheet`: field `fxRateField` "1 USD = [ ] EUR", `fxSave`, error `fxError`). `format.dart` `parseFxRate` (exact from the digits, either separator, ≤ 6 decimals) and `rateText` (≥ 4 decimals, the style's separator). `TxTile/PartTile(fxRates:)` show `txOriginal` "−12.00 $ at 0.9240"
  under a converted amount. `ForeignNote(onSetRate:)` adds the tap `foreignSetRate` "Set a rate in Plan › Currencies" (Today, Spending, Insights). Tests: `test/p15_fx_ui_test.dart`.
- Own categories (P1; spec `docs/context/P1_SPEC.md`): `wc.categoryTable` (`controller_categories.dart`, `extension CategoriesDb`; = `categorizer.table`, rebuilt on every `reload`) is passed as `table:` to every core
  call that can meet a custom id (`computePeriod`/`plannedReserves` required; `effectiveSettings`, `averageByCategory`, `suggestBudgets`, `budgetVsActual`, `reviewState`, `monthlySummaryCsv`, `categoryShare(rollUp: true)`,
  `budgetVsActualSeries`, `billHistory`, `suggestBillCategory`) and `coveredByPlanIn(table)` replaces the built-in `coveredByPlan` getter in widgets. Names are shown with `table.label(id)` (`TxTile(table:)`,
  `CategoryBars(table:)`, `ShareBars(table:)`, `SuggestBudgetsDialog(table:)`). Actions: `addOwnCategory(name, kind)`, `renameCategory`, `setCategoryHidden`, `moveCategory(id, ±1)` (hands the group's positions out
  again, writes only changes), `deleteOwnCategory` / `undeleteOwnCategory`; an `ArgumentError` carries core's text. Logs `categories.*` (counts and enum words only). `SpendingView.byTopLevel` = `byCategory`
  (the "Where it goes" rows). Insights API: `categoryTotal`, `rowsOf(cat, merchant)`, `compareFor` (`rowsFor`/`merchantsIn`/`merchantTrend`/`compareCategory` take `table:`). T1 removed subcategories: no `parent`, no
  "Subcategories" panel, no `ownTotal`/`childTotals`/`ownRowsOf`.
  Plan lines: Plan › Edit has a field per `table.planLineIds` (`planLine_<id>`; only edited ones are saved; empty clears), the ledger a line each (`ledgerPlanLine_<id>`, hint while 0); deleting a category with a line asks first (`categoryDeleteConfirm`) and Undo brings the line back.
  Own-category logs never carry ids (`_logCategory`: built-in name or `custom`). The transaction sheet's Save, the planned-cost edit and the bill sheet write a category only when the owner picked one (Confirm bill also accepts the shown suggestion, except over a deleted own category). Screens: `screens/categories_panel.dart`
  (Plan › Main tags (was Categories): groups Spending fixed / flexible, Income, Transfers; a row per category with a `categoryMenu:<id>` popup: Rename, Hide/Show, Move up/down, Delete (own only) with Undo toast;
  `CategoryFormSheet` for add / rename, core's message under the field; a sync duplicate row `categoryDuplicate:<id>` "same name as X, not offered" + Delete), `widgets/category_picker.dart`
  (`pickerIds`, `categoryMenuItems` = dropdown items (`pick:<id>`), `categoryChips`; `MainTagPicker` = the main tag picker of the transaction sheet (dropdown `txCategory`) and the add-expense sheet (chips `cat:<id>`): ids in `wc.recommendedMainFor` order, the first 20, then `mainTagMore`; the current value stays in the list even when hidden).
  Budgets panel lists `table.spending` (main categories only). Search, CSV and the drill-down pass `table:`, so they know custom labels. Tests: `test/p1_categories_ui_test.dart`, `integration_test/plan_test.dart` (Categories).
- Tags (T1; spec `docs/context/T1_SPEC.md`): the UI says **main tag** for the category (it decides the money) and **tags** for the extras. `controller_tags.dart` (`extension TagsDb`): `wc.tagTable` / `wc.tagContext` (= the categorizer's,
  rebuilt on every `reload`; `CategorizedTx.tags` is filled by core), `ruleTagsOf(tx)`, `addTag` / `renameTag` / `setTagHidden` / `moveTag(id, ±1)` / `deleteTag` / `undeleteTag` (an `ArgumentError` carries core's text; logs
  `tags.*` with counts only), `setPaymentTag(txId, tag, on)` (off for a rule's tag = this payment only), `setPayeeTag(tx, tag, on)` (`setRuleTag`), `addExpense(..., tags:)`. Ordering and suggestions read every row, so they are
  memoized per data version: `recommendedMainFor(tx|null, kinds:)`, `recommendedTagsFor`, `suggestedTagsFor`; a widget reads them once (in `late final`), never per row or per keystroke. Insights: `tagShareFor(range)`, `rowsOfTag`, `tagBars`.
  `widgets/tag_picker.dart`: `TagChip` / `rowTagChips` (a row shows 3 `#tag` chips then `+N`: `TxTile(tagTable:)`), `ExtraTagsEditor` (a draft in both sheets: taps change only what it holds and `onChanged(on, rule)` reports them; the transaction sheet's Save calls
  `saveTagChanges(row, on:, rule:)` = only the differing links and rule tags, none for an untouched draft; closing writes nothing; the add-expense sheet passes `addExpense(tags:)`; a tag no longer live or a failed write is counted
  in `takeTagFailures()` and the toast says `tagFailureText`; only "New tag" writes at once): chosen tags `tagOn:<id>` (a rule's tag says "from rule"; removing it shows `ruleOffNote`), faded suggestions `tagSuggest:<id>` (applied only on a tap), `tagAdd` opens the list `tagPick:<id>`
  (20, `tagMore`) and `tagNew` / `tagNewGo`; "Also tag every payment from <payee> with…" = `ruleTag:<id>` chips. `screens/tags_panel.dart` = Plan › Tags (`tag:<id>` rows with the payment count, `tagMenu:<id>` Rename /
  Hide / Move / Delete with Undo, `tagDuplicate:<id>` "same name as X, merged", `TagFormSheet`). Insights has a sixth panel `insightPanel_tags` (`TagBars`, `tagsOverlapNote`, `tagsUntagged`); a tag row opens
  `screens/tag_detail.dart` (`tagDetailTotal` = the sum of `tagRows`, per-month bars). Search and the transactions CSV pass `tags: wc.tagTable`. Tests: `test/t1_tags_ui_test.dart`.
- Dashboard kit (RX2; design `docs/design/dashboard/CONCEPT.md` §5, "Paper Tiles"; no screen uses it yet, RX3–RX6 build on it): tokens `WalletColors.desk` (ground behind tiles, darker than `surface`), series `s1` flexible spending / `s2` bills and fixed / `s3` saved and goals (charts and fills only, never text; status stays `bad`/`good`), chip grounds `goodSoft`/`badSoft` (`test/theme_contrast_test.dart`).
  `widgets/dash.dart` (layout contract in its header: the grid asks tiles for no intrinsics, so no IntrinsicWidth/AlertDialog in a tile; a tile gets unbounded height, so no Spacer/Expanded in its column; `visual`/`dots` slots are `IgnorePointer`): `DashGrid(children, gap, minColumn=130)` (own render object; 2 columns on compact/medium, 4 from `LayoutSize.expanded`, dropping 4 → 2 → 1 while a column is under `minColumn` × text scale, so 320 and 360 dp at 2.0 get one; `DashGrid.columnsFor`/`minColumnFor`; same reading order at every size; a row is as tall as its tallest tile), `DashItem(span, rowSpan)` (a 2×2 desktop hero; rowSpan is ignored where the tile fills the row), `Tile(child, onTap, padding, semanticLabel, attention)` (12 dp radius, `surface`, 1 px `line`, no shadow; `attention` = 2 px accent border + "Needs action" spoken), `TileLabel`, `StatTile(label, value, sub, visual, visualSpoken, chip, trailing, onTap, valueColor, attention)`, `HeroTile(label, value, sub, chip, dots, dotsSpoken, paceUsed, paceExpected, paceOver, paceSpoken, onTap)`, `DeltaChip(trend, text, good)` (▲/▼ + a check or warning icon, "better/worse" spoken), `StateChip.onPace|over|date|held` (icon + word), `TileNote(text)` and `TileAction(label, onTap)` (label-row `trailing`; all `DashChip` with `spoken`), `DashRows(rows: [DashRowData])` (ruled rows, mono amount, tappable ≥ 48 dp), `AddTile(label)`, `dashNumStyle`.
  `widgets/dash_charts.dart` (exported by dash.dart): `Ring`, `RingTile(…, compact, trailing, attention)` (compact = 44 dp ring beside the value), `Sparkline`, `SplitBar`/`Donut` (`DashSegment`, `DashLegend` with the values, 2 dp gaps; a weight that is not finite counts 0), `BarList(rows: [BarRow(label, value, note, fraction, color, onTap)])` (`over` = fraction > 1: solid to the budget tick, hatched beyond, warning icon + bold words), `PaceMeter(used, expected, over)`, `NetBars(bars: [NetBar(label, value, cents, running)])` (value text per bar, preformatted), `CalendarStrip(days: [CalDay(label, kind, today, amount)], startWeekday, semanticLabel)` (bill filled, planned dashed, payday dashed teal with a flag, today a bar; `startWeekday` 1..7 = Monday-first weekday columns), `HatchPainter`, `DashedBorderPainter`.
  Rules: values arrive formatted (`moneyExact`: always exact cents, tiles scale the number down with `FittedBox`, never round; NetBars/CalendarStrip amounts too); no controller access and no money logic in the kit. Tests: `test/dash_kit_test.dart` (all components at 320 dp × 2.0, 360, 1280, light and dark; uses the gallery `integration_test/support/dash_gallery.dart`), screenshots `tools/build.sh desktop-test dash_gallery` → `dist/screens/linux/dash_gallery/<mode>-<width>.png` (not shipped).
- Theme (N1, softer Ledger): graphite ink, warmer paper, `lineStrong` is a mid grey (3:1 on bg: inputs, buttons, panel top rule, double rule), `line` is used for row separators,
  `SectionHead` underlines, `TotalRule`'s top line, header rules and the rail border; the double rule (1 px, 2 px gap) sits under totals only. Values: `docs/design/ledger-spec.md` §1.
- Sync (R5): `controller.dart` keeps `relayUrl` (device-local `relayUrl` value; `setRelay(Uri?)` validates http/https + host, saves, syncs with trigger `relay`;
  `parseRelayAddress(text)`), `syncRunner(Uri relay, key, repo)` (default: `SyncEngine` over `RelayTransport`; tests inject a fake or a `MemoryTransport` run),
  `healthCheck(Uri)` / `testRelay(Uri)` ("Test connection"), `syncNow`, and after each run `syncCaughtUp`, `syncWaiting`, `syncDevices`, `syncError`
  (a `SyncException` shows its message, anything else a generic one), `syncBadFiles`, `lastSync`. Runs: start, resume, 3 s after a change, every 5 min (the
  2-minute timer only checks the day), Ctrl+R/F5 (toast without an address), on web too. Logs say `sync.relay {set}`, never the address.
  `sync_status.dart` = pure texts (`syncStatusLine`, `lastSeenText`, `clockText`, `relayTestFailureText`); `screens/sync_panel.dart` = Plan › Sync (address field, Save
  address, Test connection, Sync now, status line, devices, Show wallet key). Onboarding join takes the key plus an optional relay address (`joinWallet(…, relay:)`).
  Android: INTERNET permission; no storage permission, no `budget_wallet/storage` channel. **Address rule (D5, HU 10):** the relay is reached over HTTPS
  on the owner's domain (Caddy + Let's Encrypt, no VPN). Plain `http://` is accepted only for this device (`localhost`, `127.x`, `::1`), the emulator's `10.0.2.2`,
  private IPv4 (10/8, 172.16/12, 192.168/16), `.local` names and names without a dot (`homeserver`); any other `http://` host is refused with "Use the https://
  address of your relay. http:// is only for your home network." (`WalletController.relayAddressIssue` → `RelayAddressIssue.needsHttps | notAnAddress`;
  `parseRelayAddress`, `setRelay` and `joinWallet` use it; octets with a leading zero and all-digit or `0x…` dotless hosts are never private; the stored address is read leniently so an upgrade never drops it, but Plan › Sync then says to switch to https and `createTokenFor` never sends the token to it). The manifest still allows
  cleartext for the LAN case. **Sync panel (H5–H8):** after each run the controller keeps `syncRelayInstance` (shown as `relayFingerprintText`, `xxxx-xxxx`, under the
  address), `syncRelayChanged` (device-local notice kept until OK, like `syncDeviceIdInUse`; a new address clears both; "This relay is new or was reset; this device sent everything again."), `syncProblems` (`syncDeviceIdInUse`: information only, "Another
  install used this device id; this device now syncs under a new stream."; `syncClockDrift`: "A device's clock is ahead; its changes wait until the clocks
  agree."); `TransportFailure.createToken` → "The relay needs its creation token." (`relayTestFailureText`; a sync run says it through core's message). Creation token:
  device-local value `relayCreateToken` (`relayCreateToken`, `setRelayCreateToken`; obscured field `relayCreateToken` + `relayCreateTokenSave` in Plan › Sync),
  passed to `RelayTransport(createToken:)`, never synced, in no backup, never logged (`sync.createToken {set}`). **Clock behind (H7):** an owner write refused with
  `ClockBehindException` is caught by the error hooks in `logging.dart` (`clock_notice.dart` `noticeClockBehind`; logged `write.clockBehind`, not a crash) and
  `BudgetWalletApp` shows one dialog sentence (`clockBehindDialog`): "This device's clock is behind. Set the date and time, then try again.". Catch-alls around owner writes (`importFiles`, bill imports → `BillImportKind.clockBehind`, `skipRecurring`) catch `ClockBehindException` first and call `noticeClockBehind`.
- Device keys (stage DK; core: `packages/sync/CLAUDE.md`, protocol `RELAY_PROTOCOL.md` api 5): each install has a relay device key (32-byte Ed25519 seed) beside the device id: `KeyStore.readDeviceKey/writeDeviceKey`
  (secure storage `budget_wallet_device_key`, file `device.key` 0600, web localStorage `bw.deviceKey`; `forget` removes it, join/set-aside keep it; `device_key.dart` `deviceKeyOf(store)` makes it on first need, `decodeDeviceKey`).
  Never synced, in no backup, never logged. `WalletController.relayTransport(relay, key, repo, deviceKey:, deviceId:)` builds every `RelayTransport` (also `runRelaySync`, whose real seam in `WalletControllerDeps.platform` passes the key;
  a store that fails falls back to wallet-key signing, logged `deviceKey.unavailable`); `onMinApi` keeps the no-downgrade api floor device-local per normalised address (`relayMinApi:<scheme>://<host>:<port><path>`, `WalletController.minApiKey(uri)` / `minApiFor(repo, uri)`; every transport gets it as `minApi`), cleared only by `setRelay` (the owner saving an address in Settings › Sync), never by a check or an error; a run failing with the engine's "older version" message while the floor is 5 shows `relayOlderThanBeforeText` ("…enter its address again").
  `deps.deviceRelayOpener` (nullable) gives a short-lived `DeviceRelay` (`device_relay.dart`: `transport` for `state()`, `devices` = `DeviceKeyTransport`, `fingerprint()`); tests wrap `MemoryTransport.device(key)` in it.
  `controller_devices.dart` (`extension DeviceKeys`, state in `SyncState`: `deviceStop`, `deviceCode`, `deviceList`, `deviceOlderRelay`): `refreshDevices()`, `approveDevice(fp)`, `removeDevice(fp)` (never self, removed, or the last),
  `removeOtherDevices()`, `setRequireApproval(on)` (an "off" the relay ignores after a removal returns `approvalStaysOnText`); each returns a plain message or null. After a successful sync run the list is read again when the block was opened.
  `device_list.dart` = the pure model and texts (`deviceListOf(RelayState)`, `DeviceRow`, `PendingRow`, `deviceActionError`, `deviceStopOf(SyncException)`: the engine ends a run on a removed/waiting key with a fixed message, matched by its first words).
  A run ending `pending` sets `deviceStop = pending` + the device's code; `revoked` sets `revoked`, and then only `relay`/`join`/`unlock` triggers run (no retry loop; `SyncState.reset` clears it). `pendingFull` / `tooManyKeys` are plain errors, never the code screen.
  Screens: `screens/sync_devices.dart` `SyncDevicesBlock` (Settings › Sync › Devices: `device:<fp>` rows, `removeDevice:<fp>`, `removeOthers`, `pending:<fp>` / `approveDevice:<fp>`, `requireApproval`, `deviceRemovedNote` with `deviceRemovedOk`, `deviceOlderRelay`;
  confirms `removeConfirm|removeCancel`, `approveConfirm|approveCancel`, `removeOthersConfirm|Cancel`, `lockOffConfirm|Cancel`) and `DeviceStopNotice` (`devicePending` with `deviceCode` + `deviceCodeQr` + `deviceCheckAgain`, or `deviceRevoked`); Today's `deviceStopLine`.
  Logs: `devices.read|approve|remove|removeOthers|lock|unlock|stop|failed` with counts and enum words, no fingerprints. Tests: `test/dk_devices_ui_test.dart`, `test/key_store_file_test.dart` (device key group).
- Device id (H6): each install has its own id, stored next to the key and not only in the database: `KeyStore.readDeviceId/writeDeviceId` (`key_store_io.dart`: file
  `device.id` beside `wallet.key`, same 0700/0600 temp + rename write (`_writePrivate`); Android secure storage `budget_wallet_device_id`; `key_store_web.dart`: localStorage
  `bw.deviceId`; `KeyStore.forget` removes it too). `WalletController._openWithId`: no id stored (first open after an upgrade) → the database opens with its own id and
  `repo.deviceId` is moved into the store once; from then on every open passes `deviceId:` (`openWalletDb(dbKey, {deviceId})` → `WalletRepo.open/fromDatabase`);
  `createWallet` / `joinWallet` make a new id (`WalletRepo.newDeviceId()`), stored before the database opens. A store that fails is logged (`deviceId.storeFailed`) and the
  app goes on; the id is never logged. Tests replace the store through `WalletControllerDeps` (`deviceIdReader/deviceIdWriter`).
- Polish (M5): Plan › Backup (`screens/backup_panel.dart`: "Back up now" = `wc.backupDownload()` → `FileChooser.saveBackup` (the system save dialog on every platform; a cancel
  shows nothing), "Restore from backup…" only while `walletIsEmpty`: `pickBackupFile()` → confirm → `restoreBackupFile(bytes)` → toast with the row count; the core
  functions sit behind `backupBytesWriter/backupBytesReader` so tests use fakes) and Plan › Export (`screens/export_panel.dart`: range chips This period/year/Everything,
  `exportTransactions(range)`/`exportSummary()` return an `ExportFile` (UTF-8 with BOM) saved through `FileChooser.saveText`). Search (`screens/search.dart`
  `SearchPane`): the icon in Spending's header or Ctrl+F (`HomeShell._searchRequest`) swaps the page for a pinned field + ruled result sections via an
  `IndexedStack` (the page keeps its scroll); 2+ characters, 150 ms debounce, `wc.search(q)` cached per data version; goal/wish/bill rows jump to their tab.
  Log events (counts only): `backup.done|restored|failed`, `export.transactions|summary|saved`, `search.run`.
- Stage Q2 UI Y (suggestions, filters, changes): `controller_suggest.dart` (`extension SuggestDb`, `part` of controller.dart): `suggestCategoriesFor(text)` / `payeesFor(prefix)` (cached per data version; the
  Add expense note is a `RawAutocomplete` with up to 3 `suggestCat:<id>` chips under it, 250 ms debounce, a tap sets only the main tag; constants `addExpenseKinds/addExpenseExclude` are the
  picker's set), rule offers (`setCategory(always: false)` on a bank row leaves `wc.ruleOffer`; `txSheetToast` shows "Always put X in Y?" with **Make rule** then an Undo; Rules › Suggested
  `ruleSuggest:<key>` / `ruleSuggestMake:<key>` / `ruleSuggestDismiss:<key>`, dismissed keys device-local `ruleSuggestOff`), `searchFiltered(q, filter)` (filter chips in
  `screens/search_filters.dart`: `filterAmount|Date|Category|Attachment|Split|Uncategorised`, the date picker is the injectable `RangePicker`; `Highlighted` in common.dart bolds `matchSpans`;
  `todaySearch` on Today's Recent panel via `TodayScreen.openSearch`) and `recentChangesList` (`screens/recent_changes.dart`, in Settings › Sync under Devices: `change:<entity>:<id>`, `changesMore`).
  Tests: `q_suggest_ui_test`, `q_search_ui_test`, `q9_changes_ui_test`; screenshots `integration_test/suggest_search_test.dart`. Logs: counts and enum words only.
- Future spending (F3): `controller_future.dart` (a `part` of controller.dart: `extension FutureSpending` + `CalendarState` `wc.cal`): planned costs
  (`plannedOpen/plannedEverything`, `upcomingItems(from,to)` cached per data version + `cal.version`, `upcomingRange(next:)` = the pay period or the next one,
  `comingUp()`, `countedIn`, `addPlannedCost/updatePlanned/confirmSuggestion/dismissSuggestion/markPlannedPaid/skipPlanned/deletePlanned`,
  `paidCandidatesFor`), heads-ups (`headsUpLines()`, synced `headsUpCents/headsUpDays` via `saveHeadsUp`, device-local `headsUpNotify`, `rescheduleHeadsUps()`
  after every reload, nudge reschedule and resume; `NudgePlatform.scheduleHeadsUps/cancelHeadsUps`: channel `headsup`, ids 1000..1019, 09:00 local on
  date - days, text `headsUpBody` has no title or amount; `AndroidNudges.cancelAll` also removes them, so `rescheduleNudges` always ends with `rescheduleHeadsUps`),
  calendars (`CalendarSource` interface in `calendar_source.dart`, `calendar_platform.dart` picks `AndroidCalendars` (P13: the app's own channel `budget_wallet/calendar`, `calendar_source_io.dart`; MainActivity.kt
  reads `CalendarContract.Calendars` and `Instances.CONTENT_BY_DAY_URI`, READ_CALENDAR only, no WRITE_CALENDAR, no plugin) or `NoCalendars` on the web/desktop; `.ics` files (`importIcsFile`, 2 MB cap) and
  links (`addIcsLink`, `ics_fetch.dart`, not on the web) are kept as device-local values `icsSources` / `icsText:<id>`, device calendars chosen in `calendarsOn`; `readCalendars`
  reads [today, today+90] at start, resume, choose, import and "Read now", links are fetched again first and a failure keeps the saved copy and shows a message on the entry).
  Screens: `screens/upcoming.dart` (`openUpcoming` page/dialog, `_PeriodGrid` month grids with a mark per kind, ruled list with Confirm / Change / No cost, "Set aside" total),
  `screens/planned_sheets.dart` (`PlannedFormSheet` add/edit/confirm, `PlannedEntrySheet` Change / Paid (picker) / Skip / Delete), `screens/calendars_panel.dart` (Plan › Calendars +
  heads-up fields), Today's `comingUpLine` and `headsUp:<key>` lines, Plan › Nudges `headsUpSwitch`, Plan › Export `exportPlanned`, a "Planned costs" section in search.
  F4b: Paid and Skip show a snack bar with Undo (`reopenPlanned`; `toast(actionLabel:, onAction:)`); `fetchIcs` has one overall 60 s timeout, follows up to 5
  redirects by hand and refuses https to http (`resolveRedirect`); an `http://` link is accepted with a warning (`insecureLinkWarning`); `rescheduleHeadsUps` calls
  run one after another; `headsUpSlots` moves a passed slot to the next 09:00 on or before the cost; Android events with status canceled are dropped (`calendarEventsFrom`).
  Logs (counts only): `planned.add|edit|dismiss|paid|skip|reopen|delete`, `calendar.read {calendars, events, unsupported, trigger}`, `calendar.import {ok, kind, reason}`,
  `calendar.access|choose|remove`, `headsup.enabled|scheduled`. Tests: `test/future_spending_test.dart` (`futureWallet`, `FakeCalendars`, `fakeIcs`, `FakeNudges.headsUps` in `test/support/wallet.dart`).
- Android widget and shortcut (P13; spec `docs/context/P13_SPEC.md`): `home_widget.dart` (`HomeWidget`, `NoHomeWidget`, `AndroidHomeWidget`, `WidgetState {amount, status, date}`, `WidgetStatus`
  ok|overToday|overBudget|ended, `addExpenseAction`) and `controller_home.dart` (`extension HomeIntegration`): `widgetState()` (the Today hero's amount, never negative), `updateHomeWidget()` (after
  every `reload()` / day change / resume, one microtask per burst, only when the three words differ from the last sent; cleared when no wallet is open; failures logged `widget.updateFailed`),
  `clearHomeWidget()` (before another wallet is joined), `startHomeIntegration()` / `onShortcut(action)` / `takeShortcutAdd()` / `shortcutAdds` (HomeShell opens the Add expense sheet once; ignored in
  onboarding or locked). Channels (MainActivity.kt): `budget_wallet/widget` `update|clear` -> `SafeTodayWidget.kt` (prefs file `bw_widget`: amount, status, date, until; the amount shows only when the date is today, muted line "to 10 Nov" / Over today / Over the plan / Payday passed, else "Open the app to
  update" when the date is over a day old; tap opens the app), `budget_wallet/shortcut` `getInitialAction` + native `action` call (`onNewIntent`; a dynamic shortcut published by MainActivity with the own action `hr.marcelic.budget_wallet.ADD_EXPENSE` + extra `bw.action`, SINGLE_TOP, no static shortcuts.xml: static ones kill the running app and a VIEW intent trips the share plugin).
  First-import sheet: `screens/first_plan_sheet.dart` `offerFirstPlan` ("Looks right?": Accept all / Choose… / Not now) is called by `pickAndImport` after an import that read a file, when
  `shouldOfferFirstPlan()` (device-local `planSuggestShown` not set, proposals exist); `markFirstPlanShown()` sets it. Tests: `test/p13_widget_test.dart`, `test/calendar_channel_test.dart`,
  `test/p13_first_plan_test.dart`, `test/android_hardening_test.dart` (P13 group).
- Bills database (B4; core API in `docs/context/BILLS_API.md`): `controller_bills.dart` (a `part`: `extension BillsDb`) = lists (`billsAll`, `billLists()` To review / Unpaid / Paid,
  `billsToReview`, `billForTx`, `billCandidatesFor`, `searchBills`), adding (`importBillFile(bytes, ext, trigger:)` = pdf → text + on Android page render + code scan, xml → e-invoice,
  jpg/png → Android codes then OCR / elsewhere kept unread; the original goes to `BlobStore.add` (pictures sized to JPEG 2560 px first); no code or text in the file → `externalId`
  `file:<hash of the file>` so the same file is one bill; `importScannedCode`, `importPhoto`; results are `BillImport` with a `message` such as "Already in your bills"), Share to app
  (`startSharing()` from `HomeShell`, results on `sharedBillResults` → SnackBar), the bill sheet actions (`updateBill`, `setBillDates`, `confirmBill` needs date + total, `linkBill`,
  `unlinkBill`, `deleteBill`, `addBillAsExpense`, `billFile` = this device then the relay), reminders (`_rescheduleBillRemindersNow`, run inside `rescheduleHeadsUps`' chain, same switch as the
  heads-ups; ids 1020..1039, channel `bills`, text "A return window ends in N days" / "A warranty ends in N days") reminder days from the synced settings `returnReminderDays` / `warrantyReminderDays`.
  The camera, OCR, PDF pages and Share are behind `bill_inputs.dart` (`BillCamera`, `PictureReader`, `PdfPages`, `ShareInbox`, `BillInputs`, `BillInputs.none()`); `bill_platform.dart` picks
  `bill_inputs_io.dart` (the only file that imports `mobile_scanner`, `google_mlkit_text_recognition`, `receive_sharing_intent`; Android only) or `bill_inputs_web.dart`. The app's own
  channel `budget_wallet/bills` (MainActivity.kt) renders PDF pages (`PdfRenderer`, ≤ 5 pages, PNG at dpi, background thread) and sizes pictures (`toJpeg`, EXIF turned upright).
  Screens: `screens/bills_panel.dart` (Plan › Bills, `_pickAndImportBills`), `screens/bill_sheet.dart` (`openBill`, `BillSheet`: an "Unsure" mark on every field of a pdf/photo bill in review,
  Paid by… / Paid in cash, warranty / return-by, `BillFileScreen` = zoomable picture, rendered PDF pages or Save file…, "The file is on the relay; sync to fetch it"),
  `screens/scan_bill.dart` (`scanBillFlow`, `ScanBillScreen`: camera preview for codes; Take photo = `BillCamera.takePhoto()` = the system camera app through the channel's `takePhoto` (CAMERA asked first, FileProvider `<applicationId>.billphotos` over `cache/bill_photos/`, full resolution, file read and deleted at once; cancel = back to the scanner), then `toJpeg` + OCR), Add expense › Scan bill (only with a camera), Today's
  `billsToReview` row, the receipt mark on `TxTile(hasBill:)` + "Open bill" in `TxSheet`, Upcoming warranty / return-by rows (`UpcomingKind.warranty|returnBy`, `UpcomingItem.billDb`; opens the bill), a "Bills" section in search.
  B5b: `confirmBill` needs a category for a bill due today or later (`billNeedsCategory`; the sheet prefills `suggestedBillCategory` and marks it; core's `suggestBillCategory`; `billPlannedBy` = core's `billCoveredBy`: the sheet says "Planned by <expected bill>", such a row is listed, not reserved; `importBill(asNew: true)` for "Add as new bill"); a duplicate `BillImport` carries `addAsNew` and `existingDone` (message "You already paid a bill like this. Add it as a new one?"), shown by `showBillImport` (toast action "Add as new bill"); a bill's planned row opens the bill sheet (core `PlannedCost.isBill`: Upcoming, Today heads-ups, search); sizes are checked before reading (`maxBillFileBytes`: 15 MB, pictures 40 MB before sizing, `billTooBigMessage`; `SharedFile.tooBig`; the share plugin's cache copy is deleted); `pdfParser` (`pdf_parse.dart`: `Isolate.run` on native, inline on web); Plan › Bills "Reminder days" (`saveBillReminderDays`), Plan › Sync "N bill files waiting to upload" (`syncBlobsWaiting`) and, when `SyncReport.blobsUnsupported`, "This relay can't keep bill photos yet. Update the relay on the home server.". Bill widget tests use `tw` (60 s timeout) and read PDFs inline (`inlinePdfParser`).
  B6: `updateBill`/`setBillDates` return false when core refuses (a reserving bill without a category); the sheet then shows the category message and stays open.
  `comingUp()` = core's `reservedPlannedRows`/`reservedPlanned`; `countedIn` uses core's `plannedReserves` (shown = reserved, exactly). "Needs a category" (`PlannedCost.needsCategory`):
  Upcoming row mark, Today line per row (`plannedNeedingCategory()`, key `needsCategory:<planned id>`) and heads-up suffix; each opens the bill sheet.
  The demo wallet (`integration_test/demo_data.dart`, also used by `tool/live_demo.dart`) is seeded in `test/demo_data_test.dart`, so a core rule that breaks seeding fails `flutter test`.
  Logs (counts and enum words only): `bills.import {trigger, source, isNew, read, unsure, items, kept}`, `bill.confirm|edit|dates|link|unlink|delete|cashExpense|file`, `share.received {files}`,
  `scan.cameraFailed {code}`, `bills.remindersScheduled {count}`. Android: CAMERA (declared by mobile_scanner, asked when Scan bill opens), `singleTask` + SEND/SEND_MULTIPLE filters
  for pdf and image; no storage permission. Tests: `test/bills_test.dart` with `test/support/bills.dart` (`FakeBillInputs`, `billsWallet`, `smallPdf`).
- Setup wizard (stage X; spec `docs/context/X_SPEC.md`): `screens/setup_wizard.dart` (`openSetupWizard(context, wc, {chooser, restart})` = page on phones, 560 dp dialog from `dialogMin`; keys `setupWizard`, `setupStep:<n>`, `setupTitle`, `setupNext|Back|Skip|Accept|Done`; 8 steps: import (`setupImport`, reuses `pickAndImport`), accounts (`setupAccount:<id>`, `setupCheck:<id>`, `setupCash`+`setupCashAdd`, `setupAccountAdd`),
  payday plan (`setupProposal:<key>`, `setupProposalAccept:<key>`), bills (`setupBill:<id>`, `confirm:<id>`/`dismiss:<id>`, `setupBillsCost` only with a confirmed bill), extra income (`incomeConfirm:|incomeDismiss:<id>`), payees (`setupPayee:<key>`, dropdown `setupPayeeTag:<key>`, toast Undo), budgets (`setupBudget:<cat>`, `setupBudgetAccept:<cat>`), done (`setupSafe|setupPayday|setupBillsHeld`, `setupGoto:<n>` per skipped step)).
  `controller_setup.dart` (`extension SetupWizardDb`): device-local `setupWizard` = `pending` (set by `createWallet`; a joined wallet has none) | `step:<n>` (saved whenever a step shows) | `done` | `skipped`; `setupWizardOpen/Step`, `saveSetupStep`, `finishSetupWizard`, `declineSetupWizard`, `uncategorisedPayeeList()` (core's `uncategorisedPayees`), `makePayeeRule/undoPayeeRule`, `setupBudgetProposals/acceptBudgetProposals`, `setupSummary()` (the Today hero figure). Accept writes only its step, Skip nothing. `HomeShell` opens it after the save-key sheet; Today's setup panel has a `wizardRow` ("Finish setting up": `wizardResume`, `wizardDecline`) while it is `pending`/`step:<n>`; Settings has `setupAgain` (restart at step 1).
  `shouldOfferFirstPlan()` is false once a wizard state exists (step 3 offers the plan). Logs `setup.step {n, action}`, `setup.payeeRule {category}`, `setup.finish|decline`. Tests: `test/x_setup_wizard_test.dart`, `integration_test/onboarding_test.dart` (a screenshot per step).
- Nudges: `nudges.dart` (pure: ~14 funny, encouraging lines with no digits or names, `nudgeFor(date)`, `nudgeSlots(now)` = 15:00 on
  weekdays and 11:00 on Sunday for 4 weeks, `NudgePlatform`/`NoNudges`) and `nudge_platform_io.dart` (native-only: `AndroidNudges` with
  `flutter_local_notifications`, one inexact `zonedSchedule` per slot, no exact-alarm permission; the time zone name comes from
  the `budget_wallet/timezone` channel in MainActivity; POST_NOTIFICATIONS is asked when the switch is turned on). Everything but
  Android gets `NoNudges` (the switch is off with a note). The controller schedules again on start and resume. A reminder never
  carries amounts, merchants or names. Tests use `FakeNudges` (`test/support/wallet.dart`) through `forTest(nudges:)`.
- Pay and loan left (P16a; spec `docs/context/P16_SPEC.md`): the bill sheet's **Pay** button (`billPay`: unpaid bill with an IBAN and a total) opens `screens/pay_sheet.dart` `PaySheet` (`paySheet`; rows `payRow:<field>` with `payCopy:<field>` for payee, iban, amount, reference, description, and `payCopyAll`; "Paste these into your bank app. Nothing is sent from here."). The IBAN shows grouped (`groupedIban`) and is copied plain (`plainIban`); the amount is `bankAmountText` ("12,50", whatever the Look setting). Every copy goes through `wc.copySensitive(text)` (the `copyKeyBackup` clipboard rules: cleared after 60 s if still ours; the key copy uses it too). The bill is not touched. Log `bill.payCopy {field}` only. Plan's Loan line has `ledgerLoanLeft` ("5 payments left · 1,500 € at this rate") from `wc.loanLeftNow()` = core's `loanLeft`. Tests: `test/p16a_pay_test.dart`.
- Save-key prompt (S3): `screens/key_backup.dart` (`KeyBackupSheet` via `showSheet`: why, QR + key text, Copy key, "I saved it" → type the last 4 characters, Later; `KeyBackupRow` = Today's
  notice). Controller: `keyBackupRowVisible`, `takeKeyBackupPrompt()` (true once after `createWallet`; `HomeShell.initState` opens the sheet), `confirmKeyBackup(typed)`,
  `snoozeKeyBackup()` (7 days), `copyKeyBackup()` (clipboard cleared after 60 s if it still holds the key; `clipboardWrite/Read` swappable in tests). Device-local values
  `keyBackupConfirmed`, `keyBackupSnoozedUntil`; `joinWallet` marks confirmed. Logs `key.backup {shown|copied|confirmed|snoozed}`, nothing else. Tests: `test/key_backup_test.dart`.
  Tests that need a clean Today call `wc.snoozeKeyBackup()`; integration helpers call `wc.takeKeyBackupPrompt()` after `createWallet`.
- `lib/src/file_chooser.dart` — `FileChooser`: the system file/folder/save dialogs behind one injectable class. They can throw
  (Linux without xdg-desktop-portal), so every call site catches, logs the type and shows `chooserFailedMessage`.
- `lib/src/theme.dart` — the D3 Ledger theme (`docs/design/ledger-spec.md`): `WalletColors` (paper/ink tokens incl. `lineStrong`; light and
  night ledger, following the system), `contrastRatio`, `numStyle` (IBM Plex Mono + tabular figures: every amount uses it), `buildTheme`
  (all component themes live there: buttons radius 3, chips/inputs radius 2, dialog/sheet/nav/snackbar), `accentOutlined` (the old tonal
  button), `marginLineColor`. Fonts: six unmodified IBM Plex TTFs in `assets/fonts/` + `OFL.txt` (licence registered in `main()`;
  source and version in `third_party/fonts/README.md`). No `Card`, no pills, no shadows: ruled lines instead.
- `lib/src/screens/*.dart` — one file per tab; `budgets.dart` is Plan's "Budgets per category" panel (`BudgetsPanel`: one field per fixed/flex
  category, empty = no budget, "Suggest" fills only empty fields, only edited fields are saved, nothing written when nothing changed). `lib/src/widgets/` — `charts.dart` (fl_chart charts; strokes, bars and dashes snap to whole device pixels with `snapPx(logical, dpr)` and the net chart's line/dots/running bar are opaque: no grain at 1.25/1.5 dpr, `test/chart_crisp_test.dart`; `CategoryBars`, `RuledBar`, `PaceBar`),
  `common.dart` (`Panel` = ruled section, `SectionHead`, `Eyebrow`, `Heading`, `TotalRule`/`DoubleRule`, `TxTile` + `TxHeaderRow`
  (Date | Particulars | Amount columns, stacked above text scale 1.15), `LineItem`, `Rows`, `SplitRow`, `HeadingRow`, `Tag`, `LedgerLogo`,
  `NavBarFrame` (bar top rule + accent mark), `MarginLine` (red margin rule, wide windows only), `toast`),
  `sheets.dart` (bottom sheets: add expense, transaction details, goal).
- `lib/src/format.dart` — money/date formatting and parsing (unit-tested in `test/widget_test.dart`).
- `key_store.dart` — wallet key: `key_store_io.dart` = system keystore (phones) or a private file (desktop); `key_store_web.dart` = the
  browser (see Web build). Same members everywhere: `read`, `write(key, {passphrase})`, `forget`, `isLocked`, `unlock`, `readDeviceId`, `writeDeviceId` (see Device id).
- Key screens (H10, `screens/key_backup.dart`): the key text has letter spacing and the hint `keyHint` (`keyAlphabetHint`: A–Z and 2–7, no zero or one) under it; `KeyDisplay` = the key as a QR code first, the text only after "Show as text" (`keyShowText`; `keyQr`, `keyText`);
  used by the save-key sheet and by Plan › Show wallet key (`showWalletKey`, a dialog; `plan.dart` just calls it). `secure_window.dart` `SecureWindow` wraps both: on Android it
  calls `MethodChannel('bw/secure').invokeMethod('setSecure', true)` when the view is built and `false` when it is removed (close, back, dispose; counted, so two open views
  keep the flag until the last closes); other platforms never touch the channel; a channel error is logged (`secure.failed`, no values). `MainActivity.kt` sets FLAG_SECURE.
- Restore with another key (H13, `screens/backup_panel.dart`): while the wallet is empty, "Restore a backup made with another key…" (`restoreOtherKey`) picks the file, then
  `askOldKey` asks for the old wallet key (typed, pasted, or scanned from its QR where `billInputs.camera.supported`) and calls `restoreBackupFile(bytes, otherKey:)`
  → `VaultKey.parse` + `restoreBackupBytes(repo, bytes, oldKey)`. The wallet keeps its own key; the old key is used once, never stored or logged (`backup.restored {otherKey}`).
  Errors: not a key → the key error's own text; a key that does not open the file → "That key does not open this backup.".
- `logging.dart` — `AppLog`: console (`debugPrint` → logcat) + a `LogBackend` (`log_backend_io.dart`: `RotatingFileSink` in
  `<app support>/logs/`; `log_backend_web.dart`: `MemoryLogSink`), error hooks,
  frame/memory/lifecycle monitors, `logNav` (UI actions), `loggedRoute` (sheets), `fileExt`. `main.dart`'s `bootstrap()`
  sets it up and logs the `app.start` phases. Plan › Diagnostics (`screens/diagnostics.dart`): level, save, clear.

## Web build (`flutter build web`, localhost only)
Same app and wallet logic; the files that touch the OS come in pairs chosen by `dart.library.js_interop` (`x.dart` re-exports
`x_io.dart` or `x_web.dart`; nothing on the web path imports `dart:io`):
- `wallet_db.dart` — `openWalletDb()` → `WalletDb {repo, persist(), forget()}`. io: `wallet.db` in the support folder (`persist` does
  nothing, `forget` deletes the file). web: `sqlite3.wasm` (served next to `index.html`) on an `IndexedDbFileSystem('budget-wallet')`;
  changes sit in memory until `persist()` = `fs.flush()`; `forget` closes, drops the file system and deletes the IndexedDB database.
  The controller flushes from `notifyListeners()` (once within 800 ms of the first change) and in `persistNow()` (tab hidden/inactive/paused
  via `HomeShell`'s lifecycle listener). Nothing can be flushed synchronously on `beforeunload`; a hidden tab is the last safe point.
  One tab only: web `openWalletDb()` first takes the Web Lock `bw-wallet` (`ifAvailable`, kept for the page's life); if another tab has it, it throws
  `WalletInUse` and `WalletController.load` returns `inUseElsewhere` (empty in-memory repo, nothing opened) → `InUseScreen` (Reload = `page_reload.dart`).
- `key_store_web.dart` + `key_vault.dart` (pure Dart, tested on the VM with maps for the two storages): the key is wrapped with a
  passphrase (PBKDF2-HMAC-SHA256, 600000 rounds, random 16-byte salt, then core's `seal`) into localStorage as
  `bwk2.<rounds>.<salt>.<sealed>` (`bwk1`, 310000 rounds, still opens and is stored again as `bwk2` on the next unlock, log `key.rewrap`); unlocking puts the plain key into sessionStorage (this tab only). `KeyStore.isLocked` = wrapped key
  but nothing in sessionStorage → `UnlockScreen` (`wc.locked`, `wc.unlock`, `WrongPassphrase`). Onboarding on web asks for a passphrase
  (2 fields, ≥ 8 characters) after "Start a new wallet" / "Use my wallet key". Logs: `store: 'browser'`, found/locked flags only.
- `log_backend_web.dart` — `MemoryLogSink` (1 MB, newest lines); Plan › Diagnostics "Save logs…" downloads them through `FileChooser.saveText`.
- `nudge_platform_web.dart` (`NoNudges`). Plan hides Nudges when `isWeb` and adds "This browser"
  (Show wallet key, Forget this browser → `ForgetBrowserSheet` → `wc.forgetBrowser()`: deletes database + key, opens an empty database, app
  returns to onboarding). Backup works the same everywhere (see Polish above).
  File downloads in a browser return null from `FilePicker.saveFile`, so `FileChooser` answers with the file name there.
- `platform.dart` `isWeb` (= `kIsWeb`; tests set `debugIsWebOverride = true` to run the web branches on the VM and must reset it).
- Tests: `test/web_test.dart` (screens, controller paths, flush with fakes), `test/key_vault_test.dart` (wrap/unwrap, locked state). The
  browser itself (IndexedDB, downloads, wasm) is covered by `tools/build.sh web-test`, not by the VM tests.

## Encrypted local database in the app (R6b)
The wallet database opens **only once the key is known**, always keyed with `localDbKey(key)` (`wallet_db.dart`: `claimWalletDb()`,
`walletDbExists()`, `setAsideWalletDb(stamp)`, `openWalletDb(dbKey)` → `WalletDb {repo, converted, persist, forget}`).
`WalletController.load` claims the web tab lock, reads the key, then: key found → keyed open (an older plaintext file is converted on that
start; logs `db.open {keyed, converted, ms}`); no key (onboarding, web locked) → `WalletRepo.inMemory()` placeholder (`_dbPending`),
and `createWallet` / `joinWallet` / `unlock` write the key, open the file db (`_openFileDb`) and switch to it (`_useDb`: relay URL and
data reload from it). `forgetBrowser` deletes the db + key and goes back to the placeholder (a new IndexedDB VFS name comes with the next open).
**Never lose data:** (join with no stored key and a plaintext file never converts it: it is set aside first, and create/join set aside *before* writing the key; web forget deletes only `/wallet.db`, set-aside copies stay) a `wallet.db` that exists with no key, or that the key does not open (`WalletDbKeyException`), is left untouched
(`hasUnopenedDb`; onboarding shows "An older wallet is on this device. Join with its key to open it."). Joining with the key that opens it uses
it; creating a wallet (or joining with another key) moves it to `wallet.db.unopened-<yyyy-mm-dd>` (+ `-wal`/`-shm`/`-journal`/`.plain-copy`;
web: copied inside IndexedDB) and logs `db.setAside` (no paths). Web: one `IndexedDbFileSystem` per generation (`vfsName` `indexeddb-<n>`),
registered without `makeDefault`, opened via `openKeyed(() => sqlite.open('/wallet.db', vfs: 'multipleciphers-<name>'), dbKey)`.
Tests: `test/db_open_test.dart` (load/create/join/unlock/forget flows with a fake disk), `test/wallet_db_io_test.dart` (real files in a temp
folder via `dir:` of `walletDbExists/openWalletDb/…`, i.e. `WalletControllerDeps.platform(dbDir:)`), `test/web/wallet_db_web_test.dart` (`tools/build.sh web-test`: real IndexedDB, wrong key, converted
unkeyed db, set aside, forget + reopen).

## Encrypted database plumbing (stage R1)
`sqlite3` 3.x + `hooks: user_defines: sqlite3: source: sqlite3mc` in `pubspec.yaml` (also in `packages/wallet_core/pubspec.yaml` for
`dart test`) = SQLite3 Multiple Ciphers on Android, Linux and (via `sqlite3mc.wasm`, pinned in `dev/sqlite3-wasm.sha256`, served as
`sqlite3.wasm`) the web; `sqlite3_flutter_libs` is gone. Key right after open: `db.execute('PRAGMA key = "x\'<64 hex>\'"')`; wrong or missing
key fails on the first read (`SqliteException` 26 "file is not a database"); plaintext → encrypted in place: open unkeyed, `PRAGMA rekey = "<key>"`.
**Web: the key only works on the wrapped VFS** `sqlite.open(path, vfs: 'multipleciphers-${fs.name}')` after `registerVirtualFileSystem(fs)`
(no `makeDefault`); the default VFS says "Encryption is not supported by the VFS". After `unregisterVirtualFileSystem`, open the next
`IndexedDbFileSystem` with another `vfsName`. Proofs: `packages/wallet_core/test/encrypted_db_test.dart`, `test/web/encrypted_db_test.dart`.

## Rules
- **No `dart:io` in `main.dart`, `screens/`, `widgets/`, `layout.dart` or `platform.dart`** (they must build for the web;
  `test/platform_test.dart` checks it). File and folder work goes into the native-only files
  (`controller.dart` via `wallet_db.dart`, `key_store_io.dart`, `log_backend_io.dart`, `file_chooser.dart`). OS facts for logs: `nativeInfo()`.
- New screen state comes from the controller; don't open the database from a widget.
- Text is short and plain (the owner often uses the app by voice and on a phone).
- Android release builds are signed by the fixed key (see root `CLAUDE.md`); don't touch signing here.
- Log new actions and every catch block (`logEvent`/`logError`/`logNav`, loggers `bw.<area>`). Safe fields only:
  counts, ms, sizes, built-in categories, dates, setting keys, enum words. Never amounts, descriptions, merchants,
  notes, goal/wish names, the key, paths or file names. `integration_test/screens_test.dart` checks the emulator log.

## Tests
- `integration_test/perf_test.dart` + `test_driver/perf_driver.dart` (host side) + `test_driver/perf_budget.dart` (pure budgets,
  unit-tested in `test/`): profile-mode frame performance, `tools/build.sh perf`. Actions are `binding.traceAction`
  reports keyed `perf_<action>`; add an action there and the driver picks it up. Budgets (`PerfBudget`, per-action map
  `budgets` in the driver) are set from baseline runs in `history/perf.jsonl`. It needs `flutter drive --profile`, so
  outside it the test skips itself (`desktop-test` and `emulator.sh` run every file).
- `test/adaptive_test.dart` (four window sizes × two text scales), `test/adaptive_edge_test.dart` (boundaries, shortcuts, dialogs,
  resizing), helpers in `test/support/layout.dart`; `integration_test/adaptive_test.dart` takes desktop screenshots at
  1280×800, 1920×1080 and 800×1280 (`tools/build.sh desktop-test adaptive`). Tests find tabs with `tapTab`/`navTab`: they work for the bar and the rail.
- `test/budgets_plan_test.dart` (the editor), `test/budgets_screens_test.dart` (Spending rows, Today line, controller caching); the
  `budgetWallet()` helper in `test/support/wallet.dart` has a fixed clock (20 Oct 2026) and known amounts.
- `test/habits_test.dart` (controller, Today card and bills line, ReviewScreen steps, Plan chips/bills/nudges, layout at 320 dp @ 2.0, 360 and
  1280), `test/nudges_test.dart` (texts, slots), `test/notifier_test.dart` (the Android plugin through its method channel); the
  `habitsWallet()` helper (20 Oct 2026, a bill candidate, three unconfirmed card rows, a ready wish) and `FakeNudges` are in `test/support/wallet.dart`.
- `test/theme_*_test.dart` — the Ledger theme: contrast ratios of every token, structure (no `Card`, nav by width, Panel without radius), text
  scale 2.0 at 320/360 with the real fonts, amounts in Plex Mono with tabular figures and a shared right edge, the six font files and `OFL.txt`.
- `test/sync_relay_test.dart` (texts, controller, two controllers through one `MemoryTransport`, Plan › Sync, join with an address), `test/backup_test.dart` (save/restore through a fake chooser).
- Stage H app half: `test/harden_sync_ui_test.dart` (address table, Plan › Sync texts, create token incl. the header over a loopback socket, clock-behind dialog through the real error hooks),
  `test/secure_key_test.dart` (mocked `bw/secure` channel, QR first), `test/restore_other_key_test.dart` (a backup sealed with key A restored into a wallet with key B), the device id in
  `test/db_open_test.dart`, `test/wallet_db_io_test.dart` (real file) and `test/key_store_file_test.dart`.
- `test/` — formatting and widget tests. Run: `tools/build.sh test` (format check, `flutter analyze`, `flutter test`).
