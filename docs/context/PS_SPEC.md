# PS — payday auto-save (owner 2026-11-02)

Owner: "payday checklist should be automatic; the owner must opt out, or take money out of savings, before it can be spent or to rebalance."
Decisions: silent (no Today tile); skip/lower for one pay period → the difference goes back to this period's spending money;
"Take out" from a goal's saved total asks: this period's spending money, or another goal. Wishes hold no money ("Save for it" makes a goal).

## Core (wallet_core) — fixed API
All rows are `goal_contrib` rows written through `WalletRepo._write`; no new table, no schema bump. `period` = the pay period start
(`PeriodBudget.start`, `YYYY-MM-DD`), the same string on every device.
- `payGoals({required String period})` — writes `pay:<goalId>:<period>` = `g.monthly` (clamped) **only for goals that have no such row
  yet** and `monthly > 0` (idempotent; two devices write the same id). The no-period variant is dropped (fix its callers/tests).
- `setGoalPeriodAmount(String goalId, String period, int cents)` — this period's amount for one goal, `0` = skip. Writes the pay row
  first if missing, then `adj:<goalId>:<period>` = `cents − payRowAmount` (overwritten on a second call; `cents == payRowAmount`
  writes 0). `ArgumentError` (owner-readable) for cents < 0, over `Goal.maxContribution`, unknown/deleted goal, or when the goal's
  saved total would go below 0.
- `Map<String, int> goalPeriodAmounts(String period)` — per live goal: pay + adj when a pay row exists, else `monthly + adj`.
- `String takeOutOfGoal(String goalId, int cents, {required String date, String? toGoalId})` — `cents > 0`, at most the goal's saved
  total (`ArgumentError` otherwise). `toGoalId == null`: row `out:<uuid>` = −cents dated `date` (counts as spending money in the
  period containing `date`). Else one `_write` with `mv:<uuid>` = −cents on the goal and `mv:<uuid>:in` = +cents on `toGoalId`
  (no effect on spending money; same goal refused).
- `int goalTakenOutBetween(String start, String endExclusive)` — sum (positive) of `out:` rows dated in the range.
- `computePeriod` (budget.dart ~:469/:500) and the second copy (~:1257/:1277): take `goalAmounts` (Map, default = monthly) and
  `goalTakenOut` (int, default 0). `PeriodBudget.goalMonthly` = Σ goalAmounts (this period's savings); new field `goalTakenOut`;
  `flexBudget = income − fixedPlan − goalMonthly − reservedBills − reservedPlanned + landedIncome + goalTakenOut`. `planSplit.saved`
  = goalMonthly. Future-period paths (forecast, projected reserves, `monthlyFlex`, `monthsToGoal`) keep `g.monthly`.
- Logs: counts and enum words only (`goal.periodAmount {skip: bool}`, `goal.takeOut {to: spending|goal}`), never amounts or names.
- `savedFor` setting stays readable (old builds write it); nothing new reads it.

## App
- Controller: after every `reload()` / day change, when a period exists and goals have `monthly > 0`, call
  `repo.payGoals(period: p.start)` (only writes when rows are missing; no notify loop). Pass `goalPeriodAmounts(p.start)` and
  `goalTakenOutBetween(p.start, p.end)` into every `computePeriod` call. Upgrade: the running period is paid on first start; earlier
  unticked periods are not back-filled.
- Remove Today's `_PaydayChecklist`, `TodayView.paydayDone`, `wc.paydayDone`, the `savedFor` write.
- Goal sheet: "This pay period" amount (default this period's amount) + **Skip this period**; **Take out** = amount + destination
  (This period's spending money / another goal). Plan ledger and Goals tiles show this period's amounts (`goalPeriodAmounts`).

## Tests (money)
Two devices auto-pay the same period → counted once; skip/lower → total and spending money move by exactly the difference; lower
twice → last wins; take out to spending → spending money of that period +X, total −X; move → totals shift, spending unchanged; take
out more than saved → refused; goal with monthly 0 → no row; new goal mid-period → paid once; period without salary → no auto-pay.
