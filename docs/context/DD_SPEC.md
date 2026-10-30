# DD — Today day dots (owner, 2026-10-30)

Owner: the space right of Today's big number is empty; move the spending bar up there "as something symbolic, not
standard". Picked from four options (ring, upright gauge, burn-down line, hourglass): **day dots**. No schema/sync change.

## What the owner sees
- Right of the hero number (`safeToSpend`): a grid with **one square per day of the current pay period**, Monday-first
  columns aligned to weekdays (like a calendar), rows of 7.
  - **within** (past day, its flexible spending ≤ that day's money): filled, `c.accent`.
  - **over** (past day, spending > that day's money): filled `c.bad` with thin surface-coloured hatch lines (the over-budget hatch inverted: at 11–13 dp a red fill reads better than red lines on grey).
  - **today**: outlined, thick accent border (no verdict yet).
  - **to come** (after today, before payday): thin `c.lineStrong` outline, empty.
- Under the grid one muted line: `12 within · 3 over` (counts only, no amounts; omitted while both are 0).
- The **horizontal pace bar on Today goes** (`PaceBar` stays for Period reports). The line under it
  ("552 € of 3 € used · 550 € behind pace", `_PaceSummary`) stays where it is.
- Screen reader: one label, e.g. "Pay period, 26 days: 12 within the day's money, 3 over, today, 10 to come."
- Narrow or large text: when the number and the grid do not both fit on one row (320 dp, text scale 2.0), the grid goes
  under the number (left-aligned), never shrinks below 10 dp squares.
- Payday passed (period ended, `paydayPassed`): every day has its verdict, no "today" square. Over the plan
  (`planDaily ≤ 0`): still shown (days with spending are over, days without are within).

## Rule (core, exact)
For each day `d` of the period `[start, end)` up to yesterday (or every day once the payday passed):
`allowance(d)` and `spent(d)` are **exactly** `computePeriod(... today: d).allowanceToday` and `.spentToday` with the same
inputs Today uses now (rows, settings, goals, bills, planned, table, matchRows): what Today would have said that day,
recomputed with the payments known now (a bank row imported later moves its day's verdict). `over` ⇔ `spent(d) >
allowance(d)`; equal = within; no spending or a net refund = within. Never by amount alone: only flexible spending rows
(the same rows `spentToday` counts).

## Core API (fixed for both halves)
```dart
enum DayMark { within, over, today, toCome }
class PeriodDay { final String date; final DayMark mark; final int spent; final int allowance; } // cents; 0/0 for today/toCome
List<PeriodDay> periodDays(List<CategorizedTx> txs, WalletSettings st, List<Goal> goals, String today,
    {List<RecurringBill> bills = const [], List<PlannedCost> planned = const [], required CategoryTable table,
     List<CategorizedTx>? matchRows});
```
One entry per day of the period, ascending. Must equal per-day `computePeriod` (test pins it) and run in < 100 ms on
the 20k-row test wallet (compute the per-day values without 31 full passes over all rows if needed).

## App
`wc.periodDays()` memoized beside `period()` (`MemoKey('periodDays')`), `TodayView.periodDays()`; widget `DayDots` in
`widgets/charts.dart` (key `dayDots`, squares `dayDot:<date>`, counts line `dayDotsCounts`). Log nothing new.

## Delegation
| # | Item | Agent (model/effort) | Worktree | Order |
|---|---|---|---|---|
| DD0 | Context pack | scout (haiku/low) | – | done |
| DD1 | `periodDays` + tests (equality with computePeriod per day, edges: period start, payday passed, over plan, refund day, equal = within, perf) | core-builder (session/high) | own | parallel |
| DD2 | `DayDots`, Today layout, controller/TodayView, widget tests (320 dp × 2.0, ended, over), screenshots; a stand-in `periodDays` in the app until DD1 merges | ui-builder (sonnet/high) | own | parallel |
| DD3 | Review each half, merge (drop the stand-in), stage run, push, STATUS | lead + reviewer | v2 | last |
