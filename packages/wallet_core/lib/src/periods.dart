import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.budget');

/// Money in and out over one pay period (salary to salary).
class PeriodSummary {
  final String start; // first day, YYYY-MM-DD, inclusive (a payday)
  final String end; // next period's start, exclusive; for the running period: nextPayday(start, st.paydayDay)
  final int income; // cents: BudgetKind.income + BudgetKind.extra amounts in [start, end)
  final int out; // cents: -(BudgetKind.fixed + BudgetKind.flex amounts) in [start, end); refunds lower it
  final Map<String, int> byCategory; // category -> positive cents out (fixed + flex only)
  final bool running; // true only for the current period (today is in it)
  const PeriodSummary({
    required this.start,
    required this.end,
    required this.income,
    required this.out,
    required this.byCategory,
    required this.running,
  });
  int get net => income - out;
  double? get savingsRate => income > 0 ? net / income : null; // can be negative
}

/// Salary parts this close to a payday's first payment belong to that payday.
const _samePaydayDays = 20;

/// After this many days without salary, paydays are assumed on `paydayDay`.
const _missingSalaryDays = 45;

/// Real paydays from salary payments (sorted, all <= today): the date of the first payment of each payday.
/// Salary parts within 20 days of a payday's first payment belong to that payday.
List<String> salaryPaydays(List<CategorizedTx> txs, String today) {
  final salary = txs
      .where((t) => t.tx.live && t.kind == BudgetKind.income && t.amount > 0 && t.date.compareTo(today) <= 0)
      .map((t) => t.date)
      .toList()
    ..sort();
  final real = <String>[];
  for (final d in salary) {
    if (real.isEmpty || daysBetween(real.last, d) > _samePaydayDays) real.add(d);
  }
  return real;
}

/// Payday dates (sorted, all <= today) from salary payments, a hand-set period start and assumed paydays.
List<String> detectPaydays(List<CategorizedTx> txs, WalletSettings st, String today) {
  final real = salaryPaydays(txs, today);
  final ps = st.periodStart;
  if (ps != null && ps.compareTo(today) <= 0 && (real.isEmpty || daysBetween(real.last, ps) > _samePaydayDays)) real.add(ps);

  final out = <String>[];
  for (var i = 0; i < real.length; i++) {
    out.add(real[i]);
    final until = i + 1 < real.length ? real[i + 1] : null; // next real payday (exclusive) or today (inclusive)
    if (daysBetween(real[i], until ?? today) <= _missingSalaryDays) continue;
    // Before a late real salary, skip assumed days within 20 days of it: they would only cut off a short, empty period.
    final stop = until == null ? null : addDays(until, -_samePaydayDays);
    for (var d = nextPayday(real[i], st.paydayDay);
        stop != null ? d.compareTo(stop) < 0 : d.compareTo(today) <= 0;
        d = nextPayday(d, st.paydayDay)) {
      out.add(d);
    }
  }
  if (_log.isLoggable(Level.FINER)) {
    logEvent(_log, Level.FINER, 'budget.paydays',
        {'real': real.length, 'assumed': out.length - real.length, 'first': out.firstOrNull, 'last': out.lastOrNull});
  }
  return out;
}

/// Pay periods, oldest first; the last one is the running period. At most [count] entries.
List<PeriodSummary> periodSummaries(List<CategorizedTx> txs, WalletSettings st, String today, {int count = 12}) {
  final days = detectPaydays(txs, st, today);
  if (days.isEmpty || count <= 0) return const [];
  final from = days.length > count ? days.length - count : 0;
  final starts = days.sublist(from);
  final income = List.filled(starts.length, 0), out = List.filled(starts.length, 0);
  final byCat = [for (final _ in starts) <String, int>{}];

  // Transactions on or after the last start (up to today) belong to the running period.
  int indexOf(String date) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid].compareTo(date) <= 0) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  for (final t in txs) {
    if (!t.tx.live || t.date.compareTo(starts.first) < 0 || t.date.compareTo(today) > 0) continue;
    final i = indexOf(t.date);
    switch (t.kind) {
      case BudgetKind.income || BudgetKind.extra:
        income[i] += t.amount;
      case BudgetKind.fixed || BudgetKind.flex:
        out[i] -= t.amount;
        byCat[i][t.category] = (byCat[i][t.category] ?? 0) - t.amount;
      case BudgetKind.transfer:
        break;
    }
  }

  final last = starts.length - 1;
  logEvent(_log, Level.FINER, 'budget.periods', {'count': starts.length, 'from': starts.first, 'tx': txs.length});
  return [
    for (var i = 0; i < starts.length; i++)
      PeriodSummary(
        start: starts[i],
        end: i < last ? starts[i + 1] : nextPayday(starts[i], st.paydayDay),
        income: income[i],
        out: out[i],
        byCategory: byCat[i],
        running: i == last,
      ),
  ];
}

/// Rolling average of `net` (rounded to whole cents) over the [window] periods ending at each index.
/// null where fewer than [window] completed periods are available, and always null for a running period.
List<int?> trendNet(List<PeriodSummary> periods, {int window = 3}) {
  final res = <int?>[];
  for (var i = 0; i < periods.length; i++) {
    if (window <= 0 || periods[i].running || i + 1 < window) {
      res.add(null);
      continue;
    }
    final slice = periods.sublist(i + 1 - window, i + 1);
    if (slice.any((p) => p.running)) {
      res.add(null);
      continue;
    }
    res.add((slice.fold<int>(0, (s, p) => s + p.net) / window).round());
  }
  return res;
}

/// Totals over the completed (not running) periods, for the "Saving or losing" heading.
class SavingsOverview {
  final int periods; // completed periods
  final int saved; // completed periods with net > 0
  final int net; // sum of net over completed periods
  final int income; // sum of income over completed periods
  const SavingsOverview({required this.periods, required this.saved, required this.net, required this.income});

  /// Share of what came in that was kept, over all completed periods; null if nothing came in.
  double? get savingsRate => income > 0 ? net / income : null;
}

SavingsOverview savingsOverview(List<PeriodSummary> periods) {
  final done = periods.where((p) => !p.running);
  return SavingsOverview(
    periods: done.length,
    saved: done.where((p) => p.net > 0).length,
    net: done.fold(0, (s, p) => s + p.net),
    income: done.fold(0, (s, p) => s + p.income),
  );
}
