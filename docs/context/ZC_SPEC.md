# ZC — scrollable, zoomable graphs (plan, 2026-10-30)

Owner: "All graphs should be scrollable and zoomable to give more or less detail. Plan the UI change, and how a dynamic
range change shows the right entries." Status: **plan, owner answers in §6; queued after the Today day dots (DD)**. No schema or sync change.

## 1. What changes for the owner
- **Drag sideways** on a time graph = move through time (with a fling). **Pinch** = zoom: in = shorter stretch, finer
  bars; out = longer stretch, coarser bars. **Double tap** = one step in. Vertical drags still scroll the page.
- **Zoom buttons** − / + and a **Reset** under every graph, next to the dates (one hand, TalkBack, no pinch needed).
- **More detail = finer bars, not wider ones.** The bar size follows how much time is on screen:

  | On screen | One bar per | Example label |
  |---|---|---|
  | up to ~5 weeks | day | `14` (month under the first bar) |
  | up to ~5 months | week (Mon–Sun) | `6–12 Oct` |
  | up to ~4 years | month | `Oct 26` (as now) |
  | longer (max 5 years) | quarter | `Q4 26` |

  At most ~40 bars on a phone; on a narrow screen the next coarser size is used before bars get thinner than 6 px.
- The **dates line** (`May–Oct 2026`) always says what is on screen. The **chips stay** (This pay period, Month, 3/6/12
  months, Custom) as quick jumps; after a drag or pinch no chip is ticked until one is tapped or Reset.
- **The exact-amount rows under each graph follow the graph**: one row per visible bar, same order, exact cents, partial
  buckets marked like today's faded month ("not a whole week"). **Tap a bar or its row** → that bucket's payments (the
  existing drill-down list, now for a day/week/month/quarter).
- Edges: you cannot drag before the first payment (or 5 years back) or past today (past payday on the forecast). Zoom
  stops at 7 days and at 5 years (core's custom-range limit).

ASCII of one graph on a phone:
```
SPENDING PER MONTH
[This pay period] [Month] [3 months] [6 months ✓] [12 months] [Custom]
 ‹        6 Oct – 2 Nov 2026  📅        ›
 ▇ ▅ ▇ ▃ ▆ ▂ ▇ ▅   (weeks, drag ↔, pinch)
 Spent  ░ Faded: not a whole week
 [ − ]  [ + ]  [ Reset ]
 6–12 Oct ............ 312.40 €
 13–19 Oct ........... 188.05 €  …
```

## 2. Which graphs
| Graph | Where | Drag | Zoom | Finest bar |
|---|---|---|---|---|
| Spending per month | Insights | yes | yes | day |
| Income vs spending | Insights | yes | yes | day |
| Budget vs actual | Insights | yes | yes | day (pro-rated budget share, §6 Q2) |
| Category / merchant / tag per-month bars | drill-downs | yes | yes | day |
| Per pay period (net, saved/lost) | Budget tab | yes | number of periods shown (3–24) | one pay period |
| Payday forecast (step chart) | Budget tab | yes | yes (days shown) | day |
| Category share, Tags, Biggest payments, "Where it goes" | Insights / Budget | swipe on the dates line moves the range | − / + make the range shorter / longer | – (they are lists) |

## 3. How a range change gets the right entries (data)
- **One day index per data version** (core, pure): from the same expanded, home-currency list and the same
  `_isSpending` rule the graphs use today, a sorted array of days holding exact cent sums (spent, income, extra; per
  category, tag and merchant key on demand). Built once when the data changes (20k rows / 5 years ≈ 1,800 days: a few
  ms), memoized like today's graph data (`wc.memo`, data version + day).
- **Any window, any bar size = sums over that index**, never a new pass over the payments: prefix sums give each bucket
  in O(1). A drag frame only reads the index, so it stays inside the frame budget.
- **Buckets are aligned** (days, Monday weeks, calendar months, calendar quarters); the first/last one cut by the window
  or by today is `partial` (faded + dashed, as today).
- **While the finger moves**: the graph redraws from the index, with one window of buckets ready on each side so new bars
  appear at once. **When it stops**: the window is committed: dates line, rows list, drill-down target, log
  `insights.view {graph, bucket}` (no dates, no amounts). The chip kind stays remembered per device; the window is not
  (as today's offset).
- **Same numbers as today, checked by tests**: a month bucket equals today's `MonthBar` exactly; the buckets of any window
  add up to that window's total; days add up to their week, weeks to their month (partial weeks counted once); weeks across
  New Year and DST; a refund in a bucket lowers it (a net refund shows below zero, as now); other currencies never mixed in.
- Budget vs actual keeps calendar months (owner decision 2026-10-20); a pay-period window shows the months it touches.

## 4. Core API (fixed for both halves)
```dart
enum Bucket { day, week, month, quarter }
Bucket bucketFor(DateRange window, {int maxBars = 40, Bucket finest = Bucket.day});
List<DateRange> bucketsOf(DateRange window, Bucket b);            // aligned, clipped at the window edges
class DayIndex {                                                     // pure, web-safe
  DayIndex(List<CategorizedTx> expanded, {required String currency, CategoryTable? table});
  String? get first; String? get last;                               // data extents
  int spent(DateRange r, {String? category, String? tag, String? merchantKey});
  int income(DateRange r); int extra(DateRange r);
}
class SeriesBar { DateRange span; Bucket bucket; int spent; bool partial; }
List<SeriesBar> spendingSeries(DayIndex ix, DateRange window, Bucket b, {required String today, String? category, String? tag, String? merchantKey});
List<IncomeSpendingBar> incomeSeries(DayIndex ix, DateRange window, Bucket b, {required String today});
List<BudgetMonth> budgetSeries(...);                                 // month or quarter buckets only
String bucketLabel(DateRange span, Bucket b);                        // "14", "6–12 Oct", "Oct 26", "Q4 26"
```
`spendingByMonth`/`incomeVsSpending`/`tagTrend`/`merchantTrend` stay (old callers, and the month-equality tests).

## 5. App
- `widgets/chart_viewport.dart` `ChartViewport`: owns the window (start/end), turns drag/pinch/double tap/buttons into a
  new window (clamped), asks for bars, keys `chartZoomIn_<id>`, `chartZoomOut_<id>`, `chartReset_<id>`. Desktop: Shift +
  wheel or trackpad = drag, Ctrl + wheel = zoom, ← → / + − when the graph has focus.
- Our own gesture layer, not fl_chart's `transformationConfig` (that only stretches the picture; we need finer bars).
  No new packages.
- `InsightRange` gains the window; `MonthlyBars` becomes `SeriesBars` (any bucket); the rows list and drill-down take
  the bucket's `DateRange`. `PeriodNetChart` and `ForecastStepChart` get the same viewport with their own finest step.
- Perf: new `perf_test` action `insights_pan` (pan + pinch on 20k rows), budget = today's chart budgets.

## 6. Owner decisions (2026-10-30)
- Q1 Finest step: **day**.
- Q2 Budget vs actual below a month: **weeks (and days) of actual against a pro-rated budget**. The month budget is split
  over its days in integer cents (largest-remainder, so the parts of a month add up to its budget exactly); a bucket's
  budget = the sum of its days. Labelled as a share ("budget share 112 €"), never as a separate budget; the month view
  stays exact as today. `budgetSeries` takes any bucket; the finest-bar column in §2 reads "day" for it too.
- Q3 Lists (share, tags, biggest): **swipe on the dates line moves the range, − / + make it shorter / longer.**
- Also (owner, same day): graph panels show the title only, no note under it (done in 2c99d30's follow-up).

## 7. Delegation (cap 4)
| # | Item | Agent (model/effort) | Worktree | Order |
|---|---|---|---|---|
| Z0 | Context pack: every chart, its data call, tests, perf actions | scout (haiku/low) | – | first |
| Z1 | Core: `Bucket`, `bucketsOf`, `DayIndex`, series functions, labels + unit tests | core-builder (session model/high) | zc-core | after Z0 |
| Z2 | Spec tests from §3/§4 (sums, edges, weeks over New Year/DST, refunds, currencies, 5-year cap) | test-writer (sonnet/medium) | zc-tests | with Z1 |
| Z3 | UI: `ChartViewport`, all graphs in §2, rows + drill-down by bucket, widget tests, live-mode screenshots | ui-builder (sonnet/high) | zc-ui | with Z1 (API in §4) |
| Z4 | Review each half as it lands, merge, stage run (haiku watcher, incl. perf), push, STATUS | lead + reviewer (high) | v2 | last |
