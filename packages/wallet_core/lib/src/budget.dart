import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.budget');

/// The budget for the current pay period ("month" = salary to salary).
class PeriodBudget {
  final String start, end; // end = expected next payday (exclusive)
  final int length, daysLeft;
  final int received, extras, income, goalMonthly, fixedPlan;
  final int flexBudget, spent, spentToday, remaining, allowanceToday, safeToday, planDaily;
  final double elapsed;
  final Map<String, int> fixedPaid;

  const PeriodBudget({
    required this.start,
    required this.end,
    required this.length,
    required this.daysLeft,
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
    required this.elapsed,
    required this.fixedPaid,
  });

  /// Positive = under budget so far, negative = over.
  int get aheadOfPace => (flexBudget * elapsed).round() - spent;
}

int _sum(Iterable<CategorizedTx> xs) => xs.fold(0, (s, x) => s + x.amount);

PeriodBudget computePeriod(List<CategorizedTx> txs, WalletSettings st, List<Goal> goals, String today) {
  final start = st.periodStart ?? today;
  final end = nextPayday(start, st.paydayDay);
  final length = daysBetween(start, end).clamp(1, 1000);
  final daysLeft = daysBetween(today, end).clamp(1, 1000);
  final inPeriod = txs.where((t) => t.date.compareTo(start) >= 0 && t.date.compareTo(today) <= 0 && t.tx.live).toList();
  final received = _sum(inPeriod.where((t) => t.kind == Kind.income));
  final extras = _sum(inPeriod.where((t) => t.kind == Kind.extra));
  final income = st.incomeMode == 'received' && received > 0 ? received : st.salary;
  final goalMonthly = goals.fold<int>(0, (s, g) => s + g.monthly);
  final fixedPlan = st.rent + st.loan + st.subs;
  final flexBudget = income - fixedPlan - goalMonthly;
  final flex = inPeriod.where((t) => t.kind == Kind.flex);
  final spent = -_sum(flex);
  final spentToday = -_sum(flex.where((t) => t.date == today));
  final allowanceToday = ((flexBudget - (spent - spentToday)) / daysLeft).round();
  final elapsed = ((daysBetween(start, today) + 1) / length).clamp(0.0, 1.0);
  final fixedPaid = <String, int>{};
  for (final t in inPeriod.where((t) => t.kind == Kind.fixed)) {
    fixedPaid[t.category] = (fixedPaid[t.category] ?? 0) - t.amount;
  }
  // Dates and counts only, never amounts.
  if (_log.isLoggable(Level.FINER)) {
    logEvent(_log, Level.FINER, 'budget.period', {
      'start': start,
      'end': end,
      'saved': st.periodStart != null,
      'days': length,
      'daysLeft': daysLeft,
      'tx': inPeriod.length,
      'incomeMode': st.incomeMode,
      'goals': goals.length
    });
  }
  return PeriodBudget(
    start: start,
    end: end,
    length: length,
    daysLeft: daysLeft,
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
    elapsed: elapsed,
    fixedPaid: fixedPaid,
  );
}

class MonthSummary {
  final String month;
  final int income, out;
  final Map<String, int> byCategory;
  const MonthSummary(this.month, this.income, this.out, this.byCategory);
  int get net => income - out;
}

MonthSummary monthSummary(List<CategorizedTx> txs, String month) {
  var income = 0, out = 0;
  final byCat = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || monthOf(t.date) != month) continue;
    switch (t.kind) {
      case Kind.income || Kind.extra:
        income += t.amount;
      case Kind.fixed || Kind.flex:
        out -= t.amount;
        byCat[t.category] = (byCat[t.category] ?? 0) - t.amount;
      case Kind.transfer:
        break;
    }
  }
  return MonthSummary(month, income, out, byCat);
}

/// Spending (fixed + flex, refunds subtracted, transfers and income left out: the "Where it goes" sums) per
/// category over the live rows of [months], in one pass.
Map<String, int> _outByCategory(List<CategorizedTx> txs, Set<String> months) {
  final out = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || !months.contains(monthOf(t.date))) continue;
    if (t.kind == Kind.fixed || t.kind == Kind.flex) out[t.category] = (out[t.category] ?? 0) - t.amount;
  }
  return out;
}

/// The [count] months before [month] (exclusive), oldest first.
List<String> _monthsBefore(String month, int count) => monthsEnding(month, count + 1)..removeLast();

/// Average monthly spending per category over the [months] calendar months before [month] (the month itself left
/// out), in cents, rounded to the cent. Always divided by [months]: a month without spend counts as zero. Only
/// categories with any spend in those months appear.
Map<String, int> averageByCategory(List<CategorizedTx> txs, String month, {int months = 6}) {
  final sums = _outByCategory(txs, _monthsBefore(month, months).toSet());
  return {for (final e in sums.entries) e.key: (e.value / months).round()};
}

/// Budgets to propose for [month]: each category's average over the 6 months before it, rounded UP to the nearest
/// 1000 cents (10 €). A category whose average is zero or negative (refunds) is omitted.
Map<String, int> suggestBudgets(List<CategorizedTx> txs, String month) {
  const months = 6, step = 1000;
  final sums = _outByCategory(txs, _monthsBefore(month, months).toSet());
  return {
    for (final e in sums.entries)
      if (e.value > 0) e.key: (e.value + months * step - 1) ~/ (months * step) * step,
  };
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
/// and income left out). [today] (`YYYY-MM-DD`) decides how much of the month has elapsed for the pace.
BudgetVsActual budgetVsActual(List<CategorizedTx> txs, String month, Map<String, int> budgets, {required String today}) {
  final actual = monthSummary(txs, month).byCategory;
  final average = averageByCategory(txs, month);
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

enum Verdict { now, tight, later }

class Affordability {
  final Verdict verdict;
  final int newDaily;
  const Affordability(this.verdict, this.newDaily);
}

Affordability affordability(int price, PeriodBudget p) {
  final left = p.flexBudget - p.spent - price;
  final newDaily = (left / p.daysLeft).round();
  if (newDaily >= p.planDaily * 0.75) return Affordability(Verdict.now, newDaily);
  if (left > 0) return Affordability(Verdict.tight, newDaily);
  return Affordability(Verdict.later, newDaily);
}

/// Months until a goal is reached at its monthly amount, or null if never.
int? monthsToGoal(Goal g) {
  final left = g.target - g.saved;
  if (left <= 0) return 0;
  if (g.monthly <= 0) return null;
  return (left / g.monthly).ceil();
}
