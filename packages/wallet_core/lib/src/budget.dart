import 'bills.dart' show occurrenceKey, plannedReserves;
import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';
import 'recurring.dart' show planRecurringPayments, RecurringPayments;

final _log = Logger('bw.budget');

/// In `incomeMode == 'received'`, the first [samePaydayDays] days of a pay period count `max(received, salary)` as
/// income: the employer pays the salary in parts over several days (owner: between the 10th and the 15th), so the
/// period is not shown short before every part has landed, and [PeriodBudget.lowIncome] stays false.
const samePaydayDays = 7;

/// The budget for the current pay period ("month" = salary to salary).
class PeriodBudget {
  final String start, end; // end = expected next payday (exclusive)

  /// [length]: days in the period (at least 1). [daysLeft]: days from today to [end], the real count: 0 once
  /// [paydayPassed], never raised to 1.
  final int length, daysLeft;

  /// Today is on or after [end]: the expected payday came and the period was not moved on yet. [daysLeft] is 0 and
  /// [allowanceToday] 0; nothing divides by the days left.
  final bool paydayPassed;

  /// The income received so far is short of the planned salary: received > 0, below 90 % of `salary`, at least 4
  /// days into the period and past the first [samePaydayDays] days (salary parts still arriving).
  final bool lowIncome;

  /// Only rows in `WalletSettings.currency` count in every sum here. The period's live rows in other currencies
  /// (income, extra, fixed and flex; transfers count nowhere) are left out: their signed sums by currency code.
  /// Empty when there are none.
  final Map<String, int> foreignByCurrency;
  final int received, extras, income, goalMonthly, fixedPlan;

  /// [allowanceToday] is never negative (0 once the flexible money is used up or [paydayPassed]); [safeToday] =
  /// allowanceToday − spentToday is negative when today's spending went over ([overToday]). [planDaily] (flexBudget ÷
  /// length) is 0 or negative when the plan leaves no flexible money ([overBudget]).
  final int flexBudget, spent, spentToday, remaining, allowanceToday, safeToday, planDaily;

  /// Tomorrow's allowance if nothing more is spent today: max(0, round(([flexBudget] − [spent]) ÷ ([daysLeft] − 1))).
  /// Null when the payday is tomorrow ([daysLeft] ≤ 1) or has passed: a new period starts then. Never negative.
  final int? allowanceTomorrow;
  final double elapsed;
  final Map<String, int> fixedPaid;

  /// Σ `reserve` of [dueCycles] not covered by a plan line ([DueCycle.coveredIn]): taken off the flexible money like
  /// the planned fixed costs (owner decision 2026-10-20). A due monthly (or shorter) bill in a fixed category
  /// ([RecurringBill.coveredByPlan]) is already in `fixedPlan`, so it is listed but not added; a long bill never is.
  final int reservedBills;

  /// The distinct bills of [dueCycles], ordered by `nextDue`, then label, then id ([dueBills]).
  final List<RecurringBill> dueBills;

  /// The cycles of confirmed bills this period holds money for ([dueCycles]), by due date.
  final List<DueCycle> dueCycles;

  /// Σ `amount` of [duePlanned] (open planned costs with an amount dated from today to the day before payday) outside
  /// fixed categories, taken off the flexible money with [reservedBills] (§4.3). One in a fixed category
  /// ([PlannedCost.coveredByPlan]) is already in `fixedPlan`: listed, not added. So is a bill's row without a category
  /// ([PlannedCost.needsCategory]) and one a due recurring bill reserves ([computePeriod]). 0 without planned costs.
  final int reservedPlanned;
  final List<PlannedCost> duePlanned;

  /// The rows of [duePlanned] summed into [reservedPlanned] ([plannedReserves]), in the same order: what "Coming up"
  /// counts, so the shown count and total are exactly what is reserved.
  final List<PlannedCost> reservedPlannedRows;

  const PeriodBudget({
    required this.start,
    required this.end,
    required this.length,
    required this.daysLeft,
    this.paydayPassed = false,
    this.lowIncome = false,
    this.foreignByCurrency = const {},
    required this.received,
    required this.extras,
    required this.income,
    required this.goalMonthly,
    required this.fixedPlan,
    required this.flexBudget,
    required this.spent,
    required this.spentToday,
    required this.remaining,
    required this.allowanceToday,
    required this.safeToday,
    required this.planDaily,
    this.allowanceTomorrow,
    required this.elapsed,
    required this.fixedPaid,
    this.reservedBills = 0,
    this.dueBills = const [],
    this.dueCycles = const [],
    this.reservedPlanned = 0,
    this.duePlanned = const [],
    this.reservedPlannedRows = const [],
  });

  /// Positive = under budget so far, negative = over.
  int get aheadOfPace => (flexBudget * elapsed).round() - spent;

  /// How far the period's spending is over the flexible money: max(0, −[remaining]).
  int get overBy => remaining < 0 ? -remaining : 0;

  /// How far today's spending is over today's allowance: max(0, −[safeToday]).
  int get overToday => safeToday < 0 ? -safeToday : 0;

  /// The plan is over: spending passed the flexible money ([overBy] > 0) or the plan leaves none ([planDaily] ≤ 0).
  /// [affordability] then answers [Verdict.overBudget].
  bool get overBudget => overBy > 0 || planDaily <= 0;
}

int _sum(Iterable<CategorizedTx> xs) => xs.fold(0, (s, x) => s + x.amount);

/// The confirmed bills of [bills] that still need paying out of this period's money: the distinct bills of
/// [dueCycles] (a monthly bill: `nextDue` before [end], the next payday, exclusive, and not paid in this period yet,
/// i.e. no `lastPaidTx` row in [txs] dated on or after [start]; a long bill until paid; a short one per occurrence).
/// Ordered by `nextDue`, then label, then id.
List<RecurringBill> dueBills(List<RecurringBill> bills, List<CategorizedTx> txs, String start, String end) {
  final seen = <String>{};
  return [
    for (final c in dueCycles(bills, txs, start, end, payments: const RecurringPayments({}), currency: ''))
      if (seen.add(c.bill.id)) c.bill
  ];
}

/// One cycle of a confirmed recurring bill that a pay period holds money for ([dueCycles]): [due] its due date,
/// [paid] the cents already paid of it (parts, [RecurringPayments.partsPaid]), [reserve] what is still set aside,
/// `max(0, reserveAmount − paid)`.
class DueCycle {
  final RecurringBill bill;
  final String due;
  final int reserve;
  final int paid;
  const DueCycle({required this.bill, required this.due, required this.reserve, required this.paid});

  /// Covered by a monthly plan line, so listed but not added to `reservedBills`: a monthly (or shorter) bill in a fixed
  /// category of [t] ([RecurringBill.coveredByPlanIn]). A long bill is never covered (owner: the money must be there).
  bool coveredIn(CategoryTable t) => !bill.isLong && bill.coveredByPlanIn(t);
}

/// Most cycles of one short bill a period lists (a guard; a pay period holds about five weekly ones).
const _maxCycles = 100;

/// The cycles of [bills] that the pay period [start] .. [end] (exclusive, the next payday) holds money for, by due
/// date, then label, then id (P4 §4). Confirmed bills only; a [RecurringBill.finished] one has none.
/// - **Monthly** (27..31 days): its `nextDue` cycle when before [end] (overdue included) and not paid in this period
///   (no `lastPaidTx` row in [txs] dated on or after [start]), as before P4.
/// - **Short** ([RecurringBill.isShort]): `nextDue` (overdue included) and every `nextDue + k × intervalDays` (k ≥ 1)
///   from [start] up to before [end], not past `endsBy`: a weekly bill reserves each week in the period. Only the first
///   cycle can hold parts.
/// - **Long** ([RecurringBill.isLong]): the `nextDue` cycle only, whatever its date (also after [end]), until paid or
///   skipped: held in full from confirmation (owner). The paid-in-this-period rule does not apply: once a payment moves
///   `nextDue` on, the next cycle is held at once. A cycle whose paying row is here but not yet recorded
///   ([RecurringPayments.paidBy]) reserves 0.
/// The first cycle's [DueCycle.paid] = [RecurringPayments.partsPaid], but 0 once that cycle's match window closed
/// before [start] (`nextDue + tolerance < start`): parts that never added up do not lower the reserve of later periods
/// (the owner marks the cycle paid or skips it). [payments] defaults to [planRecurringPayments] over [txs] in
/// [currency] (the wallet's, `WalletSettings.currency`; used only then).
List<DueCycle> dueCycles(List<RecurringBill> bills, List<CategorizedTx> txs, String start, String end,
    {RecurringPayments? payments, required String currency}) {
  final live = [
    for (final b in bills)
      if (b.confirmed && isIsoDate(b.nextDue) && !b.finished) b
  ];
  if (live.isEmpty) return const [];
  final pay = payments ?? planRecurringPayments(live, wholePayments(txs), currency: currency);
  final paidOn = <String, String>{for (final t in txs) t.tx.id: t.date};
  final out = <DueCycle>[];
  DueCycle first(RecurringBill b) {
    final paid = addDays(b.nextDue, b.tolerance).compareTo(start) < 0 ? 0 : pay.partsPaid(b.id);
    final r = b.reserveAmount - paid;
    return DueCycle(bill: b, due: b.nextDue, reserve: r < 0 ? 0 : r, paid: paid);
  }

  for (final b in live) {
    if (b.isLong) {
      if (pay.paidBy[b.id] case final Tx row) {
        out.add(DueCycle(bill: b, due: b.nextDue, reserve: 0, paid: -row.amount));
      } else {
        out.add(first(b));
      }
      continue;
    }
    if (b.nextDue.compareTo(end) >= 0) continue;
    if (!b.isShort) {
      if (!(b.lastPaidTx != null && (paidOn[b.lastPaidTx]?.compareTo(start) ?? -1) >= 0)) out.add(first(b));
      continue;
    }
    out.add(first(b));
    // Later occurrences from the first one on or after the period start (k ≥ 1); only the cycles added are capped.
    final i = b.intervalDays;
    final behind = daysBetween(b.nextDue, start);
    final k0 = behind <= 0 ? 1 : (behind + i - 1) ~/ i;
    var d = addDays(b.nextDue, (k0 < 1 ? 1 : k0) * i);
    final last = b.endsBy;
    for (var n = 1; n < _maxCycles && d.compareTo(end) < 0 && (last == null || d.compareTo(last) <= 0); n++) {
      out.add(DueCycle(bill: b, due: d, reserve: b.reserveAmount, paid: 0));
      d = addDays(d, i);
    }
  }
  out.sort((a, b) {
    var d = a.due.compareTo(b.due);
    if (d == 0) d = a.bill.label.compareTo(b.bill.label);
    if (d == 0) d = a.bill.id.compareTo(b.bill.id);
    return d;
  });
  return out;
}

/// The planned costs of [planned] that still reserve money in the period ending at [end] (the next payday,
/// exclusive): open, with an amount, dated from [today] to the day before [end]. A cost dated before today reserves
/// nothing (its day has passed: the real row is in spending); paid, skipped and deleted ones never do. Ordered by date, then
/// title, then id.
List<PlannedCost> duePlanned(List<PlannedCost> planned, String today, String end) => [
      for (final p in planned)
        if (p.isOpen && p.amount != null && p.amount! > 0 && p.date.compareTo(today) >= 0 && p.date.compareTo(end) < 0) p,
    ]..sort(comparePlanned);

/// The budget for the pay period that holds [today]. [bills] (`WalletRepo.recurringBills()`): confirmed recurring
/// bills due before the next payday and not paid yet are listed ([PeriodBudget.dueBills]); those in flex categories are
/// reserved ([PeriodBudget.reservedBills]), taken off the flexible money on the same path as the planned fixed costs, so
/// the daily plan and safe-to-spend drop by them until the bank row that pays each one lands. Bills in fixed categories
/// are already counted in the fixed-cost settings and change nothing ([RecurringBill.coveredByPlan]). [planned]
/// (`WalletRepo.plannedCosts()`): the open ones with an amount dated from today to the day before payday
/// ([duePlanned]) are reserved the same way ([PeriodBudget.reservedPlanned]), except those in fixed categories
/// ([PlannedCost.coveredByPlan], like bills), a bill's row that a confirmed recurring bill in [bills] already plans
/// in this period ([plannedCoverage], BILLS_API.md §3: listed, not added; only when that bill's covering occurrence is the
/// one [dueBills] lists here, the cycle just paid or skipped, or the bill is `coveredByPlan` — a slip due before
/// payday whose recurring cycle falls after it is reserved here) and a bill's row without a category
/// ([PlannedCost.needsCategory]: listed, not added; the owner is asked for the category). The rule is
/// [plannedReserves]; the rows it accepts are [PeriodBudget.reservedPlannedRows]. Without planned costs every number is as before.
/// [table] decides which categories are fixed ([RecurringBill.coveredByPlanIn], [PlannedCost.coveredByPlanIn]); it is
/// required so a custom fixed category is never reserved a second time as flex. [txs] is the expanded list (P6,
/// `Categorizer.expand`: each part of a split payment counts in its own category; recurring bills are matched on the
/// whole payments, [wholePayments]).
PeriodBudget computePeriod(List<CategorizedTx> txs, WalletSettings st, List<Goal> goals, String today,
    {List<RecurringBill> bills = const [], List<PlannedCost> planned = const [], required CategoryTable table}) {
  final start = st.periodStart ?? today;
  final end = nextPayday(start, st.paydayDay);
  final length = daysBetween(start, end).clamp(1, 1000);
  final paydayPassed = today.compareTo(end) >= 0;
  final daysLeft = paydayPassed ? 0 : daysBetween(today, end);
  // Once the payday has passed, rows dated on or after it belong to the next period, not to this one.
  final lastDay = paydayPassed ? addDays(end, -1) : today;
  final inPeriod = <CategorizedTx>[];
  final foreign = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || t.date.compareTo(start) < 0 || t.date.compareTo(lastDay) > 0) continue;
    if (t.tx.currency == st.currency) {
      inPeriod.add(t);
    } else if (t.kind != BudgetKind.transfer) {
      foreign[t.tx.currency] = (foreign[t.tx.currency] ?? 0) + t.amount;
    }
  }
  final received = _sum(inPeriod.where((t) => t.kind == BudgetKind.income));
  final extras = _sum(inPeriod.where((t) => t.kind == BudgetKind.extra));
  final age = daysBetween(start, today);
  // Salary parts can still be on their way only while the period runs; an ended period has all it will get.
  final partsArriving = !paydayPassed && age < samePaydayDays;
  final income = st.incomeMode == 'received' && received > 0 ? (partsArriving && st.salary > received ? st.salary : received) : st.salary;
  final lowIncome = received > 0 && received * 10 < st.salary * 9 && age >= 4 && !partsArriving;
  final goalMonthly = goals.fold<int>(0, (s, g) => s + g.monthly);
  // Plan lines of custom fixed categories (P1) count with rent, loan and subs; only lines the table still allows.
  final fixedPlan = st.rent + st.loan + st.subs + st.planLines.entries.fold<int>(0, (s, e) => table.hasPlanLine(e.key) ? s + e.value : s);
  final cycles = dueCycles(bills, txs, start, end, currency: st.currency);
  final seenBills = <String>{};
  final due = [
    for (final c in cycles)
      if (seenBills.add(c.bill.id)) c.bill
  ];
  final reservedBills = cycles.fold<int>(0, (s, c) => s + (c.coveredIn(table) ? 0 : c.reserve));
  final duePl = duePlanned(planned, today, end);
  final counted = {for (final c in cycles) occurrenceKey(c.bill.id, c.due)};
  final reservedRows = [
    for (final p in duePl)
      if (plannedReserves(p, bills, counted, table: table)) p
  ];
  final reservedPlanned = reservedRows.fold<int>(0, (s, p) => s + p.amount!);
  final flexBudget = income - fixedPlan - goalMonthly - reservedBills - reservedPlanned;
  final flex = inPeriod.where((t) => t.kind == BudgetKind.flex);
  final spent = -_sum(flex);
  final spentToday = -_sum(flex.where((t) => t.date == today));
  final leftForToday = flexBudget - (spent - spentToday);
  final allowanceToday = paydayPassed || leftForToday <= 0 ? 0 : (leftForToday / daysLeft).round();
  final leftAfterToday = flexBudget - spent;
  final allowanceTomorrow = paydayPassed || daysLeft <= 1 ? null : (leftAfterToday <= 0 ? 0 : (leftAfterToday / (daysLeft - 1)).round());
  final elapsed = ((daysBetween(start, today) + 1) / length).clamp(0.0, 1.0);
  final fixedPaid = <String, int>{};
  for (final t in inPeriod.where((t) => t.kind == BudgetKind.fixed)) {
    final c = table.topLevel(t.category); // a child counts in its plan line
    fixedPaid[c] = (fixedPaid[c] ?? 0) - t.amount;
  }
  // Dates and counts only, never amounts.
  if (_log.isLoggable(Level.FINER)) {
    logEvent(_log, Level.FINER, 'budget.period', {
      'start': start,
      'end': end,
      'saved': st.periodStart != null,
      'days': length,
      'daysLeft': daysLeft,
      'passed': paydayPassed,
      'tx': inPeriod.length,
      'foreignCurrencies': foreign.length,
      'incomeMode': st.incomeMode,
      'goals': goals.length,
      'bills': bills.length,
      'dueBills': due.length,
      'dueCycles': cycles.length,
      'planned': planned.length,
      'duePlanned': duePl.length,
    });
  }
  return PeriodBudget(
    start: start,
    end: end,
    length: length,
    daysLeft: daysLeft,
    paydayPassed: paydayPassed,
    lowIncome: lowIncome,
    foreignByCurrency: foreign,
    received: received,
    extras: extras,
    income: income,
    goalMonthly: goalMonthly,
    fixedPlan: fixedPlan,
    flexBudget: flexBudget,
    spent: spent,
    spentToday: spentToday,
    remaining: flexBudget - spent,
    allowanceToday: allowanceToday,
    safeToday: allowanceToday - spentToday,
    planDaily: (flexBudget / length).round(),
    allowanceTomorrow: allowanceTomorrow,
    elapsed: elapsed,
    fixedPaid: fixedPaid,
    reservedBills: reservedBills,
    dueBills: due,
    dueCycles: cycles,
    reservedPlanned: reservedPlanned,
    duePlanned: duePl,
    reservedPlannedRows: reservedRows,
  );
}

class MonthSummary {
  final String month;
  final int income, out;
  final Map<String, int> byCategory;

  /// The month's live rows in other currencies than the one summed (income, extra, fixed and flex): signed sums by
  /// currency code, left out of every other field. Empty when there are none.
  final Map<String, int> foreignByCurrency;
  const MonthSummary(this.month, this.income, this.out, this.byCategory, {this.foreignByCurrency = const {}});
  int get net => income - out;
}

/// The one "Where it goes" rule for a row: live, in [currency], in a fixed or flex category (refunds count, negative).
/// Shared by [monthSummary], [averageByCategory]/[suggestBudgets] and the N3 graphs (`insights.dart`).
bool countsAsSpending(CategorizedTx t, String currency) =>
    t.tx.live && t.tx.currency == currency && (t.kind == BudgetKind.fixed || t.kind == BudgetKind.flex);

/// Money in and out of calendar [month] (`YYYY-MM`), counting only rows in [currency] (`WalletSettings.currency`);
/// the others are in [MonthSummary.foreignByCurrency]. Like every money sum here (budgets, averages, the review),
/// [txs] is the expanded list (P6, `Categorizer.expand`).
MonthSummary monthSummary(List<CategorizedTx> txs, String month, {required String currency}) {
  var income = 0, out = 0;
  final byCat = <String, int>{};
  final foreign = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || monthOf(t.date) != month) continue;
    if (t.tx.currency != currency) {
      if (t.kind != BudgetKind.transfer) foreign[t.tx.currency] = (foreign[t.tx.currency] ?? 0) + t.amount;
      continue;
    }
    if (countsAsSpending(t, currency)) {
      out -= t.amount;
      byCat[t.category] = (byCat[t.category] ?? 0) - t.amount;
    } else if (t.kind == BudgetKind.income || t.kind == BudgetKind.extra) {
      income += t.amount;
    }
  }
  return MonthSummary(month, income, out, byCat, foreignByCurrency: foreign);
}

/// Spending (fixed + flex, refunds subtracted, transfers and income left out: the "Where it goes" sums) per
/// category over the live rows of [months] in [currency], in one pass.
Map<String, int> _outByCategory(List<CategorizedTx> txs, Set<String> months, String currency) {
  final out = <String, int>{};
  for (final t in txs) {
    if (countsAsSpending(t, currency) && months.contains(monthOf(t.date))) out[t.category] = (out[t.category] ?? 0) - t.amount;
  }
  return out;
}

/// The [count] months before [month] (exclusive), oldest first.
List<String> _monthsBefore(String month, int count) => monthsEnding(month, count + 1)..removeLast();

/// Average monthly spending per category over the [months] calendar months before [month] (the month itself left
/// out), in cents, rounded to the cent. Always divided by [months]: a month without spend counts as zero. Only
/// categories with any spend in those months appear. Only rows in [currency] count. With [table], children's sums are
/// rolled up into their top-level category ([rollUp]) before dividing.
Map<String, int> averageByCategory(List<CategorizedTx> txs, String month,
    {int months = 6, required String currency, CategoryTable? table}) {
  final sums = rollUp(_outByCategory(txs, _monthsBefore(month, months).toSet(), currency), table ?? CategoryTable.builtIn);
  return {for (final e in sums.entries) e.key: (e.value / months).round()};
}

/// Budgets to propose for [month]: each category's average over the 6 months before it, rounded UP to the nearest
/// 1000 cents (10 €). A category whose average is zero or negative (refunds) is omitted. Only rows in [currency] count.
/// With [table], per top-level category (children rolled up, [rollUp]): budgets are set on top-level categories only.
Map<String, int> suggestBudgets(List<CategorizedTx> txs, String month, {required String currency, CategoryTable? table}) {
  const months = 6, step = 1000;
  final sums = rollUp(_outByCategory(txs, _monthsBefore(month, months).toSet(), currency), table ?? CategoryTable.builtIn);
  return {
    for (final e in sums.entries)
      if (e.value > 0) e.key: (e.value + months * step - 1) ~/ (months * step) * step,
  };
}

/// One row of the budget Suggest diff ([budgetProposals]): [current] is null when the category has no budget (or 0).
class BudgetProposal {
  final String category;
  final int? current;
  final int suggested;
  const BudgetProposal({required this.category, this.current, required this.suggested});
  bool get fillsEmpty => current == null;
}

/// What Suggest would change: each [suggested] category whose [current] budget is missing or 0 (fills an empty field)
/// or differs; equal values are left out. Empty fields first, then by category name. Nothing is written.
List<BudgetProposal> budgetProposals(Map<String, int> current, Map<String, int> suggested) {
  final out = <BudgetProposal>[];
  for (final MapEntry(key: c, value: v) in suggested.entries) {
    final have = current[c];
    if (have == null || have == 0) {
      out.add(BudgetProposal(category: c, suggested: v));
    } else if (have != v) {
      out.add(BudgetProposal(category: c, current: have, suggested: v));
    }
  }
  out.sort((a, b) {
    if (a.fillsEmpty != b.fillsEmpty) return a.fillsEmpty ? -1 : 1;
    return a.category.compareTo(b.category);
  });
  return out;
}

/// One category of [BudgetVsActual]. Cents; [budget] is null when none is set.
class CategoryBudgetLine {
  final String category;
  final int? budget;
  final int actual; // spending this month, refunds subtracted (can be negative)
  final int average6; // average of the 6 months before
  final int elapsedDays, daysInMonth; // see [BudgetVsActual]

  const CategoryBudgetLine({
    required this.category,
    required this.budget,
    required this.actual,
    required this.average6,
    required this.elapsedDays,
    required this.daysInMonth,
  });

  /// budget − actual; null without a budget.
  int? get remaining => budget == null ? null : budget! - actual;

  /// actual ÷ (budget × elapsedDays ÷ daysInMonth): ≤ 1.0 on pace, > 1.0 behind. Null without a budget, with a zero
  /// budget, or before the month starts (elapsedDays 0).
  double? get pace {
    final b = budget;
    if (b == null || b == 0 || elapsedDays == 0) return null;
    return actual * daysInMonth / (b * elapsedDays);
  }

  bool get over => budget != null && actual > budget!;
}

/// Budget vs actual per category for one calendar [month].
class BudgetVsActual {
  final String month; // YYYY-MM
  final List<CategoryBudgetLine> lines; // every category with a budget or any spend; actual desc, then name
  final int budgetTotal; // over budgeted categories
  final int actualTotal; // over all lines
  final int? remainingTotal; // Σ remaining over budgeted categories; null when nothing is budgeted
  final int overCount, budgetedCount;
  final int elapsedDays; // day of month for the current month, the whole month for a past one, 0 for a future one
  final int daysInMonth;

  const BudgetVsActual({
    required this.month,
    required this.lines,
    required this.budgetTotal,
    required this.actualTotal,
    required this.remainingTotal,
    required this.overCount,
    required this.budgetedCount,
    required this.elapsedDays,
    required this.daysInMonth,
  });
}

/// Compares [budgets] (`category -> cents per month`, see `WalletSettings.categoryBudgets`) with what went out in
/// [month] per category, exactly as [monthSummary] counts it (live rows, fixed + flex, refunds subtracted, transfers
/// and income left out; only rows in [currency]). [today] (`YYYY-MM-DD`) decides how much of the month has elapsed
/// for the pace. With [table], children are rolled up into their top-level category ([rollUp]): budgets are set on
/// top-level categories only.
BudgetVsActual budgetVsActual(List<CategorizedTx> txs, String month, Map<String, int> budgets,
    {required String today, required String currency, CategoryTable? table}) {
  final t = table ?? CategoryTable.builtIn;
  final actual = rollUp(monthSummary(txs, month, currency: currency).byCategory, t);
  final average = averageByCategory(txs, month, currency: currency, table: t);
  final current = monthOf(today);
  final days = daysInMonth(month);
  final elapsed = month == current ? dayOf(today) : (month.compareTo(current) < 0 ? days : 0);
  final lines = [
    for (final c in {...budgets.keys, ...actual.keys})
      CategoryBudgetLine(
        category: c,
        budget: budgets[c],
        actual: actual[c] ?? 0,
        average6: average[c] ?? 0,
        elapsedDays: elapsed,
        daysInMonth: days,
      ),
  ]..sort((a, b) {
      final d = b.actual.compareTo(a.actual);
      return d != 0 ? d : a.category.compareTo(b.category);
    });
  var budgetTotal = 0, actualTotal = 0, remainingTotal = 0, overCount = 0, budgetedCount = 0;
  for (final l in lines) {
    actualTotal += l.actual;
    if (l.over) overCount++;
    if (l.budget case final b?) {
      budgetedCount++;
      budgetTotal += b;
      remainingTotal += b - l.actual;
    }
  }
  // Month and counts only, never amounts.
  if (_log.isLoggable(Level.FINER)) {
    logEvent(_log, Level.FINER, 'budget.vsActual',
        {'month': month, 'lines': lines.length, 'budgeted': budgetedCount, 'over': overCount, 'elapsed': elapsed});
  }
  return BudgetVsActual(
    month: month,
    lines: lines,
    budgetTotal: budgetTotal,
    actualTotal: actualTotal,
    remainingTotal: budgetedCount == 0 ? null : remainingTotal,
    overCount: overCount,
    budgetedCount: budgetedCount,
    elapsedDays: elapsed,
    daysInMonth: days,
  );
}

/// The first date on or after [from] that falls on weekday [day] (1 = Monday .. 7 = Sunday).
String _nextWeekday(String from, int day) {
  final d = parseIso(from);
  return addDays(from, (day - d.weekday + 7) % 7);
}

/// The weekly review: whether it is due on [today] and what each step holds.
///
/// Due from the first `reviewDay` after the last review (`lastReview` + 1 on) until it is done ([nextReviewDate] is
/// that day; when the review is not due yet, the next one). Never reviewed: due at once ([nextReviewDate] = the last
/// `reviewDay` on or before today), so a new wallet shows the review the first time it is opened. Steps: `import` is
/// 0 (the UI fills it after importing); `categories` = live spending rows (fixed and flex) of the last 7 days whose
/// category is not user-set (the rows a merchant rule can be learnt from); `pace` = categories of the current calendar
/// month behind pace or over budget ([budgetVsActual]); `wishlist` = waiting items whose cooling-off (`coolHours`)
/// has run out by [nowMillis] (default: the end of [today], UTC). [streak] is the stored `reviewStreak`.
ReviewState reviewState(List<CategorizedTx> txs, WalletSettings st, List<WishItem> wishes, Map<String, int> budgets,
    {required String today, int? nowMillis, CategoryTable? table}) {
  final cats = table ?? CategoryTable.builtIn;
  final last = st.lastReview;
  final String next;
  final bool due;
  if (last == null) {
    final coming = _nextWeekday(today, st.reviewDay);
    next = coming == today ? coming : addDays(coming, -7);
    due = true;
  } else {
    next = _nextWeekday(addDays(last, 1), st.reviewDay);
    due = today.compareTo(next) >= 0;
  }
  final since = addDays(today, -7);
  var automatic = 0;
  for (final t in txs) {
    if (!t.tx.live || t.date.compareTo(since) <= 0 || t.date.compareTo(today) > 0) continue;
    if (t.kind != BudgetKind.fixed && t.kind != BudgetKind.flex) continue;
    if (t.isPart) continue; // the owner gave each part its main tag
    final own = t.tx.category;
    if (own == null || !cats.isLive(own)) automatic++; // no override, or one that is deleted or unknown here
  }
  final pace = budgetVsActual(txs, monthOf(today), budgets, today: today, currency: st.currency, table: cats)
      .lines
      .where((l) => l.over || (l.pace ?? 0) > 1)
      .length;
  final now = nowMillis ?? parseIso(addDays(today, 1)).millisecondsSinceEpoch;
  final waiting = wishes.where((w) => w.status == 'waiting' && w.hoursLeft(st.coolHours, now) <= 0).length;
  final steps = [
    const ReviewStep('import', 0),
    ReviewStep('categories', automatic),
    ReviewStep('pace', pace),
    ReviewStep('wishlist', waiting),
  ];
  // Dates and counts only.
  logEvent(_log, Level.FINER, 'review.state',
      {'due': due, 'next': next, 'streak': st.reviewStreak, 'categories': automatic, 'pace': pace, 'wishlist': waiting});
  return ReviewState(due: due, nextReviewDate: next, streak: st.reviewStreak, steps: steps);
}

/// [overBudget]: the plan is already over ([PeriodBudget.overBudget]), whatever the price.
enum Verdict { now, tight, later, overBudget }

class Affordability {
  final Verdict verdict;

  /// The daily allowance left after buying it, never negative (0 when it does not fit or the payday passed).
  final int newDaily;
  const Affordability(this.verdict, this.newDaily);
}

/// Whether [price] (cents, in the settings' currency) fits the period [p]. [Verdict.overBudget] whenever the plan is
/// over ([PeriodBudget.overBudget]), never [Verdict.now]; [Verdict.later] once the payday passed (no days left to
/// spread it over) or when it does not fit; [Verdict.now] when the new daily allowance keeps 75 % of the plan's,
/// [Verdict.tight] when it fits with less.
Affordability affordability(int price, PeriodBudget p) {
  if (p.overBudget) return const Affordability(Verdict.overBudget, 0);
  if (p.paydayPassed || p.daysLeft <= 0) return const Affordability(Verdict.later, 0);
  final left = p.flexBudget - p.spent - price;
  if (left <= 0) return const Affordability(Verdict.later, 0);
  final newDaily = (left / p.daysLeft).round();
  if (newDaily >= p.planDaily * 0.75) return Affordability(Verdict.now, newDaily);
  return Affordability(Verdict.tight, newDaily);
}

/// Months until a goal is reached at its monthly amount, or null if never.
int? monthsToGoal(Goal g) {
  final left = g.target - g.saved;
  if (left <= 0) return 0;
  if (g.monthly <= 0) return null;
  return (left / g.monthly).ceil();
}
