// Reports (P8): per pay period breakdowns and "saved by waiting". Pure, read-time only: nothing is written.
import 'categories.dart';
import 'logs.dart';
import 'models.dart';
import 'periods.dart';

final _log = Logger('bw.budget');

/// One pay period split into what came in and the fixed / flexible money that went out ([periodReports]).
class PeriodReport {
  final String start; // as PeriodSummary.start (inclusive payday)
  final String end; // as PeriodSummary.end (exclusive)
  final bool running; // the current period
  final int income; // cents, = PeriodSummary.income
  final int fixed; // cents out in main tags whose kind is fixed (table.kindOf); refunds lower it
  final int flex; // cents out in every other spending tag; fixed + flex == PeriodSummary.out
  const PeriodReport({
    required this.start,
    required this.end,
    required this.running,
    required this.income,
    required this.fixed,
    required this.flex,
  });
  int get out => fixed + flex;
  int get net => income - out; // = PeriodSummary.net
}

/// The pay periods of [periodSummaries] (same periods, same income and out; oldest first, the last one running), each
/// with its out split by the kind of the main tag in [table]: [PeriodReport.fixed] for fixed tags, [PeriodReport.flex]
/// for the rest. P6: [txs] is the expanded list (`Categorizer.expand`), so a split payment counts by its parts. Rows in
/// other currencies and transfers are left out, as in [periodSummaries].
List<PeriodReport> periodReports(List<CategorizedTx> txs, WalletSettings st, String today, {required CategoryTable table, int count = 12}) {
  final res = [
    for (final p in periodSummaries(txs, st, today, count: count)) _report(p, table),
  ];
  logEvent(_log, Level.FINER, 'reports.periods', {'count': res.length});
  return res;
}

PeriodReport _report(PeriodSummary p, CategoryTable table) {
  var fixed = 0;
  for (final MapEntry(:key, :value) in rollUp(p.byCategory, table).entries) {
    if (table.kindOf(key) == BudgetKind.fixed) fixed += value;
  }
  return PeriodReport(start: p.start, end: p.end, running: p.running, income: p.income, fixed: fixed, flex: p.out - fixed);
}

/// One main tag's spending in one pay period, with its monthly budget ([categoryByPeriod]).
class CategoryPeriod {
  final String start; // as PeriodSummary.start
  final String end; // as PeriodSummary.end (exclusive)
  final bool running;
  final int spent; // cents out in the tag (refunds lower it, can be negative), as PeriodSummary.byCategory after rollUp
  final int? budget; // st.categoryBudgets[category] (cents per month; a pay period counts as one month); null = none
  const CategoryPeriod({required this.start, required this.end, required this.running, required this.spent, required this.budget});

  /// Cents over the budget; 0 when within it or when there is no budget.
  int get overBy => budget != null && spent > budget! ? spent - budget! : 0;
  bool get over => overBy > 0;
}

/// [category]'s spending per pay period (the periods of [periodSummaries], oldest first), children rolled up into
/// their main tag as budgets do ([rollUp] with [table]), next to its monthly budget (`st.categoryBudgets`). P6: [txs]
/// is the expanded list.
List<CategoryPeriod> categoryByPeriod(String category, List<CategorizedTx> txs, WalletSettings st, String today,
    {required CategoryTable table, int count = 12}) {
  final budget = st.categoryBudgets[category];
  final res = [
    for (final p in periodSummaries(txs, st, today, count: count))
      CategoryPeriod(start: p.start, end: p.end, running: p.running, spent: rollUp(p.byCategory, table)[category] ?? 0, budget: budget),
  ];
  logEvent(_log, Level.FINER, 'reports.category', {'count': res.length, 'budgeted': budget != null});
  return res;
}

/// Wishes the owner decided not to buy after the cooling-off: how many and their price total ([savedByWaiting]).
class SavedByWaiting {
  final int count;
  final int cents;
  const SavedByWaiting({required this.count, required this.cents});
  static const none = SavedByWaiting(count: 0, cents: 0);
}

/// Wishes with status `skipped` whose `decided` time (epoch ms) is in [[fromMillis], [toMillis]). `bought` and `waiting`
/// wishes never count; deleted ones are not in `WalletRepo.wishlist` and so never count either.
SavedByWaiting savedByWaiting(List<WishItem> wishes, {required int fromMillis, required int toMillis}) =>
    _saved(wishes, (d) => d >= fromMillis && d < toMillis);

/// [savedByWaiting] over all time: every skipped wish with a decided time.
SavedByWaiting savedByWaitingAll(List<WishItem> wishes) => _saved(wishes, (_) => true);

SavedByWaiting _saved(List<WishItem> wishes, bool Function(int decided) inRange) {
  var count = 0, cents = 0;
  for (final w in wishes) {
    final d = w.decided;
    if (w.status != 'skipped' || d == null || !inRange(d)) continue;
    count++;
    cents += w.price;
  }
  return SavedByWaiting(count: count, cents: cents);
}
