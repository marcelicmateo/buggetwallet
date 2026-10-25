# Stage P8 spec: reports (2026-10-25)

Plan item: PATH_FORWARD P8 ("Reports: net per period, one category vs budget over time, income/fixed/flex per period; 'saved by waiting' + streak on the review's Done screen"). No schema change; everything is worked out at read time from existing data.

Rules: exact cents; the same numbers as the rest of the app (pay periods from `periodSummaries`, parts from P6 splits, foreign rows not counted, transfers out); nothing written.

## 1. Core (pure, `reports.dart`, exported)
- **Per pay period breakdown:** `List<PeriodReport> periodReports(List<CategorizedTx> txs, WalletSettings st, String today, {required CategoryTable table, int count = 12})`, built on `periodSummaries` (same periods, same `income`/`out`):
  - `PeriodReport {start, end, running, income, fixed, flex, net}` — `fixed` / `flex` = the period's spending in fixed / flex main tags (`table.kindOf`); `fixed + flex == out`; `net == income − out` (identical to `PeriodSummary.net`).
- **One main tag vs its budget over pay periods:** `List<CategoryPeriod> categoryByPeriod(String category, List<CategorizedTx> txs, WalletSettings st, String today, {required CategoryTable table, int count = 12})` → `CategoryPeriod {start, end, running, spent, budget}`; `spent` = the period's spending in that main tag (P1 roll-up as in budgets); `budget` = the tag's monthly budget (`st.categoryBudgets[category]`, null when none) — a pay period counts as one budget month.
- **Saved by waiting:** `SavedByWaiting savedByWaiting(List<WishItem> wishes, {required int fromMillis, required int toMillis})` → `{int count, int cents}`: wishes with status `skipped` whose `decided` falls in `[from, to)` — money the owner decided not to spend after the cooling-off. `bought`, `waiting` and deleted wishes never count. Also `savedByWaitingAll(wishes)` (all time).

## 2. App
- **Insights › Per pay period** (`insightPanel_periods`): a ledger table, newest first, one row per period: dates, Income, Fixed, Flexible, Net (Saved / Lost) — the running period marked "so far". Total line for the shown periods.
- **Insights › Main tag vs budget** (`insightPanel_categoryBudget`): pick a main tag (spending tags only); bars per pay period with the budget mark; "No budget set" when none; "over by" per period.
- **Review Done screen** (`reviewDoneScreen`): pressing Done shows a small screen/sheet instead of only the toast: "Review done", the streak ("4 weeks in a row", `streakText`), "Saved by waiting this period: 120 € (2 wishes)" (period = the current pay period's start to now) and "All time: 1,340 €"; button "Close". The toast stays for the Today quick path.
- Keys: `insightPanel_periods`, `periodRow_<start>`, `insightPanel_categoryBudget`, `catBudgetPick`, `reviewDoneScreen`, `reviewSaved`, `reviewStreak`.

## 3. Tests
- `periodReports`: fixed + flex == out, net equals `PeriodSummary.net` for every period, running period, split payment counted by parts, foreign and transfers excluded, custom fixed tag.
- `categoryByPeriod`: spent equals the period's spending in the tag (and child roll-up), budget null when none, partial period.
- `savedByWaiting`: skipped in range counted, bought/waiting/deleted not, boundary `from` inclusive / `to` exclusive.
- App: both panels render with a demo wallet, numbers match core; Done screen shows streak and saved; 360 dp.
