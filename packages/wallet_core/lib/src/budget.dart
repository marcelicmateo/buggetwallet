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
