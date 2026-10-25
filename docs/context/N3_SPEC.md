# Stage N3 core spec: date ranges, graph data, Spending drill-down (2026-10-25)

Owner decisions:
- D11: all four graphs (spending per month, category share, income vs spending, budget vs actual).
- D12: drill-down first, no new categories.
- A range control on every graph.

Rules that apply to everything here:
- Pure functions in `packages/wallet_core/lib/src/ranges.dart` and `insights.dart`.
- Exact cents.
- Only home-currency rows count (`st.currency`). Other currencies are reported in `foreignByCurrency`, as in `monthSummary`.
- Rows count exactly as in "Where it goes" (`monthSummary(...).byCategory`): live rows, fixed + flex spending, refunds subtracted, transfers and income left out of spending.
- Never reclassify anything.

## 1. Ranges (`ranges.dart`)
`enum RangeKind { payPeriod, month, months3, months6, months12, custom }`.
`class DateRange { final String start; final String end; }`:
- `start` and `end` are `YYYY-MM-DD`, both inclusive.
- `start <= end` is required, else `ArgumentError`.
- It has `days` and `contains(date)`.

`DateRange rangeFor(RangeKind kind, String today, WalletSettings st, {List<CategorizedTx> txs = const [], String? from, String? to})`:
- `payPeriod`: the current pay period, as `detectPaydays`/`computePeriod` define it. `start` is the period start; `end` is the day before the next payday.
- `month`: the calendar month of `today`.
- `months3` / `months6` / `months12`: the N calendar months ending with the month of `today` (the current month included, so the last one is partial).
- `custom`: `from`..`to`, both required.
  - Invalid dates, `from > to` or a span over 5 years → `ArgumentError`.
  - Dates after today are allowed only up to the end of the month of `today`.

`DateRange shiftRange(DateRange r, RangeKind kind, int steps, WalletSettings st, {List<CategorizedTx> txs = const []})`: step back (negative) or forward.
- Pay periods use the real payday list.
- Months use whole calendar months of the same count, e.g. `months3` Aug–Oct → May–Jul.
- `custom` moves by its own length in days.
- A step must not move `start` past the month of `today` → `ArgumentError`.

`String rangeLabel(DateRange r)` is a short neutral label: `1–31 Oct 2026`, `Aug–Oct 2026`, `14 Oct – 13 Nov 2026`. The app may format its own; this one is for tests and logs (dates only).

## 2. Graph data (`insights.dart`)
Each function takes `(List<CategorizedTx> txs, DateRange r, {required String currency})` unless stated.

- `List<MonthBar> spendingByMonth(...)`. One bar per calendar month that overlaps `r`, including months with no spending.
  - `MonthBar { String month /*YYYY-MM*/; int spent; bool partial; }`. `spent` counts only the days inside `r`. `partial` = the month is not fully inside `r`, or it is the current month.
- `CategoryShare categoryShare(...)`.
  - `CategoryShare { List<CategorySlice> slices; int total; Map<String,int> foreignByCurrency; }`.
  - `CategorySlice { String category; int spent; int permille; }`, sorted by `spent` descending, then by name.
  - `permille` = `spent * 1000 ~/ total`, using the largest-remainder method so the slices add up to exactly 1000.
  - Categories with net spending ≤ 0 are left out of `slices` and `total`.
- `List<IncomeVsSpending> incomeVsSpending(...)`, one per calendar month overlapping `r`.
  - `IncomeVsSpending { String month; int income; int extra; int spent; int net; bool partial; }`.
  - `income` = BudgetKind.income, `extra` = BudgetKind.extra, `spent` as above, `net = income + extra - spent`.
- `List<BudgetMonth> budgetVsActualSeries(txs, r, Map<String,int> budgets, {required String today, required String currency})`, one per calendar month overlapping `r`.
  - `BudgetMonth { String month; int budgeted; int actual; int over; }`.
  - `budgeted` = the sum of budgets for categories that have one; `actual` = their spending in that month.
  - `over` = the sum over categories of `max(0, actual_c - budget_c)`.
  - The current month is included and has `actual` so far. Reuse `budgetVsActual` per month where possible.

## 3. Drill-down (`insights.dart`)
- `List<MerchantTotal> merchantsIn(String category, txs, r, {required String currency})`.
  - `MerchantTotal { String key /*merchantKey*/; String label /*latest row's cleaned description*/; int spent; int count; String lastDate; }`.
  - Only rows of that resolved category. Sorted by spent descending, then by label.
  - Rows without a merchant key are grouped under key `''` and label `Other`.
- `List<CategorizedTx> rowsFor(String category, String? merchantKey, txs, r, {required String currency})`: the live rows behind a total, newest first. Their signed amounts must sum to exactly `-spent` of that total.
- `List<MonthBar> merchantTrend(String category, String merchantKey, txs, r, {required String currency})`: the per-month spending of one merchant, in the same shape as `spendingByMonth`.
- `CategoryCompare compareCategory(String category, txs, String month, {required String currency})`.
  - `CategoryCompare { int thisMonth; int lastMonth; int average6 /*mean of the 6 months before, ÷ 6 like averageByCategory*/; }`.
- `List<CategorizedTx> biggestRows(txs, r, {int limit = 10, required String currency})`: the largest spending rows by absolute amount, ties broken by newest date, then id.

Reuse `merchantKey`, `monthSummary`, `averageByCategory` and `budgetVsActual` where they fit. Don't duplicate their rules.

## 4. Performance
The big synthetic wallet (`tools/build.sh perf` fixture, ~10k rows) must run every function above for `months12` in under 50 ms on the VM. Add one test that measures it loosely: it fails only above 500 ms, to avoid flakes.

## 5. Tests the spec requires
Use synthetic data.

Ranges:
- every kind;
- month ends (31st, February in a leap year);
- pay periods across a missed payday;
- shifting back and forward;
- refusals: past today, custom over 5 years, from > to.

Graph data:
- days outside `r` are excluded from partial months;
- foreign rows are left out and reported;
- refunds;
- transfers count nowhere;
- permille sums to 1000;
- empty months appear;
- `rowsFor` sums match their totals exactly;
- tie ordering.

Drill-down:
- merchant grouping;
- `Other`;
- the compare averages;
- `biggestRows` ordering.
