// Graph data and the Spending drill-down (stage N3, docs/context/N3_SPEC.md §2–3). Pure functions over a
// [DateRange]. Spending is counted exactly as "Where it goes" (`monthSummary(...).byCategory`): live rows in the home
// currency, fixed + flex, refunds subtracted, transfers and income left out. Nothing is reclassified.
import 'budget.dart' show averageByCategory, budgetVsActual, countsAsSpending, monthSummary;
import 'categories.dart' show BudgetKind, CategoryTable, merchantKey, merchantName;
import 'dates.dart';
import 'models.dart';
import 'ranges.dart';

/// One calendar month of a spending series. [spent] counts only the days inside the range; [partial] = the month is
/// not wholly inside the range, or it is the current month.
class MonthBar {
  final String month; // YYYY-MM
  final int spent;
  final bool partial;
  const MonthBar({required this.month, required this.spent, required this.partial});

  @override
  String toString() => 'MonthBar($month, $spent${partial ? ', partial' : ''})';
}

/// One category's part of [CategoryShare.total], in thousandths ([permille]; all slices add up to exactly 1000).
class CategorySlice {
  final String category;
  final int spent;
  final int permille;
  const CategorySlice({required this.category, required this.spent, required this.permille});

  @override
  String toString() => 'CategorySlice($category, $spent, $permille‰)';
}

/// Spending per category over a range: categories with net spending > 0 only (sorted by spent desc, then name).
class CategoryShare {
  final List<CategorySlice> slices;
  final int total;

  /// The range's live rows in other currencies (income, extra, fixed, flex), signed sums by code, as in `MonthSummary`.
  final Map<String, int> foreignByCurrency;
  const CategoryShare({required this.slices, required this.total, required this.foreignByCurrency});
}

/// Money in and out of one calendar month (only the days inside the range).
class IncomeVsSpending {
  final String month; // YYYY-MM
  final int income; // BudgetKind.income
  final int extra; // BudgetKind.extra
  final int spent;
  final int net; // income + extra - spent
  final bool partial;
  const IncomeVsSpending(
      {required this.month, required this.income, required this.extra, required this.spent, required this.net, required this.partial});
}

/// Budgets against spending of the budgeted categories in one calendar month.
class BudgetMonth {
  final String month; // YYYY-MM
  final int budgeted; // Σ budgets of the categories that have one
  final int actual; // their spending in the month (refunds subtracted)
  final int over; // Σ max(0, actual_c − budget_c)
  const BudgetMonth({required this.month, required this.budgeted, required this.actual, required this.over});
}

/// One payee of a category in the drill-down. [key] is `merchantKey` ('' = rows without one, [label] `Other`);
/// [label] is the newest row's cleaned description (`merchantName`).
class MerchantTotal {
  final String key;
  final String label;
  final int spent;
  final int count;
  final String lastDate;
  const MerchantTotal({required this.key, required this.label, required this.spent, required this.count, required this.lastDate});

  @override
  String toString() => 'MerchantTotal($key, $spent, $count, $lastDate)';
}

/// A category's spending in a month, the month before, and the mean of the 6 months before (÷ 6, as
/// `averageByCategory`).
class CategoryCompare {
  final int thisMonth;
  final int lastMonth;
  final int average6;
  const CategoryCompare({required this.thisMonth, required this.lastMonth, required this.average6});
}

/// The key the drill-down groups by: `merchantKey`, or '' for a row without one (a hand-added row without a note,
/// or a description with nothing left after cleaning).
String _merchantOf(Tx t) {
  if (t.source == 'manual' && (t.note == null || t.note!.isEmpty)) return '';
  final k = merchantKey(t);
  return k == 'x' ? '' : k;
}

const _otherLabel = 'Other';

/// The calendar months (`YYYY-MM`) [r] overlaps, oldest first.
List<String> _monthsOf(DateRange r) {
  final last = monthOf(r.end);
  final out = <String>[monthOf(r.start)];
  while (out.last != last) {
    out.add(monthOf(addDays('${out.last}-${daysInMonth(out.last).toString().padLeft(2, '0')}', 1)));
  }
  return out;
}

/// Every row dated inside [r], by calendar month; every month of [r] present (empty when it has no rows).
Map<String, List<CategorizedTx>> _byMonth(List<CategorizedTx> txs, DateRange r) {
  final out = {for (final m in _monthsOf(r)) m: <CategorizedTx>[]};
  for (final t in txs) {
    if (r.contains(t.date)) out[monthOf(t.date)]!.add(t);
  }
  return out;
}

bool _partial(String month, DateRange r, String today) =>
    month == monthOf(today) || r.start.compareTo('$month-01') > 0 || r.end.compareTo('$month-${daysInMonth(month)}') < 0;

/// Whether a row in [rowCategory] belongs to [category]: the same id, or with [table] also a child of it (a
/// category's whole tree, one level), so a parent's drill-down sums exactly what its rolled-up total shows.
bool _inTree(String rowCategory, String category, CategoryTable? table) =>
    rowCategory == category || (table != null && table.parentOf(rowCategory) == category);

/// Spending rows of [category] (its tree with [table], [_inTree]) inside [r], newest first (date, then id descending).
List<CategorizedTx> _categoryRows(String category, List<CategorizedTx> txs, DateRange r, String currency, [CategoryTable? table]) => [
      for (final t in txs)
        if (_inTree(t.category, category, table) && r.contains(t.date) && countsAsSpending(t, currency)) t
    ]..sort(_newestFirst);

int _newestFirst(CategorizedTx a, CategorizedTx b) {
  final d = b.date.compareTo(a.date);
  return d != 0 ? d : b.tx.id.compareTo(a.tx.id);
}

/// One bar per calendar month overlapping [r], months without spending included.
List<MonthBar> spendingByMonth(List<CategorizedTx> txs, DateRange r, {required String currency, required String today}) => [
      for (final MapEntry(key: m, value: rows) in _byMonth(txs, r).entries)
        MonthBar(month: m, spent: monthSummary(rows, m, currency: currency).out, partial: _partial(m, r, today)),
    ];

/// Spending per category over [r] ("Where it goes" summed over its days), with the largest-remainder permille. Per row
/// category (a child is its own slice); with [rollUp], children are summed into their top-level category of [table]
/// (built-ins when null), like the `rollUp` helper.
CategoryShare categoryShare(List<CategorizedTx> txs, DateRange r, {required String currency, bool rollUp = false, CategoryTable? table}) {
  final cats = table ?? CategoryTable.builtIn;
  final byCat = <String, int>{};
  final foreign = <String, int>{};
  for (final MapEntry(key: m, value: rows) in _byMonth(txs, r).entries) {
    final s = monthSummary(rows, m, currency: currency);
    for (final e in s.byCategory.entries) {
      final k = rollUp ? cats.topLevel(e.key) : e.key;
      byCat[k] = (byCat[k] ?? 0) + e.value;
    }
    for (final e in s.foreignByCurrency.entries) {
      foreign[e.key] = (foreign[e.key] ?? 0) + e.value;
    }
  }
  final kept = [
    for (final e in byCat.entries)
      if (e.value > 0) e
  ]..sort((a, b) {
      final d = b.value.compareTo(a.value);
      return d != 0 ? d : a.key.compareTo(b.key);
    });
  final total = kept.fold<int>(0, (s, e) => s + e.value);
  final permille = [for (final e in kept) e.value * 1000 ~/ total];
  // Largest remainder: the thousandths lost to rounding down go to the largest remainders (ties in slice order).
  final order = List.generate(kept.length, (i) => i)
    ..sort((a, b) {
      final d = (kept[b].value * 1000 % total).compareTo(kept[a].value * 1000 % total);
      return d != 0 ? d : a.compareTo(b);
    });
  var left = kept.isEmpty ? 0 : 1000 - permille.fold<int>(0, (s, p) => s + p);
  for (var k = 0; left > 0; k++, left--) {
    permille[order[k]]++;
  }
  return CategoryShare(
    slices: [for (var i = 0; i < kept.length; i++) CategorySlice(category: kept[i].key, spent: kept[i].value, permille: permille[i])],
    total: total,
    foreignByCurrency: foreign,
  );
}

/// Income, extra income and spending per calendar month overlapping [r].
List<IncomeVsSpending> incomeVsSpending(List<CategorizedTx> txs, DateRange r, {required String currency, required String today}) => [
      for (final MapEntry(key: m, value: rows) in _byMonth(txs, r).entries) _incomeVsSpending(m, rows, currency, _partial(m, r, today)),
    ];

IncomeVsSpending _incomeVsSpending(String month, List<CategorizedTx> rows, String currency, bool partial) {
  final all = monthSummary(rows, month, currency: currency);
  // monthSummary's income is income + extra: the extra rows alone give the split.
  final extra = monthSummary([
    for (final t in rows)
      if (t.kind == BudgetKind.extra) t
  ], month, currency: currency)
      .income;
  final income = all.income - extra;
  return IncomeVsSpending(month: month, income: income, extra: extra, spent: all.out, net: income + extra - all.out, partial: partial);
}

/// Budgets against actual spending per calendar month overlapping [r], from `budgetVsActual`. Budgets are monthly
/// (owner decision 2026-10-20), so each bar counts its WHOLE calendar month, also the days outside [r]; the current
/// month counts its spending so far. [table]: as in `budgetVsActual` (children count in their parent's budget).
List<BudgetMonth> budgetVsActualSeries(List<CategorizedTx> txs, DateRange r, Map<String, int> budgets,
    {required String today, required String currency, CategoryTable? table}) {
  final whole = DateRange(start: '${monthOf(r.start)}-01', end: '${monthOf(r.end)}-${daysInMonth(monthOf(r.end))}');
  final out = <BudgetMonth>[];
  for (final MapEntry(key: m, value: rows) in _byMonth(txs, whole).entries) {
    var budgeted = 0, actual = 0, over = 0;
    for (final l in budgetVsActual(rows, m, budgets, today: today, currency: currency, table: table).lines) {
      if (l.budget case final b?) {
        budgeted += b;
        actual += l.actual;
        if (l.actual > b) over += l.actual - b;
      }
    }
    out.add(BudgetMonth(month: m, budgeted: budgeted, actual: actual, over: over));
  }
  return out;
}

/// The payees behind [category]'s spending in [r], spent desc, then label (then key). With [table], the rows of its
/// children count too.
List<MerchantTotal> merchantsIn(String category, List<CategorizedTx> txs, DateRange r, {required String currency, CategoryTable? table}) {
  final groups = <String, List<CategorizedTx>>{};
  for (final t in _categoryRows(category, txs, r, currency, table)) {
    (groups[_merchantOf(t.tx)] ??= []).add(t);
  }
  final out = [
    for (final MapEntry(key: k, value: rows) in groups.entries)
      MerchantTotal(
        key: k,
        label: k.isEmpty ? _otherLabel : merchantName(rows.first.tx), // rows are newest first
        spent: -rows.fold<int>(0, (s, t) => s + t.amount),
        count: rows.length,
        lastDate: rows.first.date,
      ),
  ]..sort((a, b) {
      var d = b.spent.compareTo(a.spent);
      if (d == 0) d = a.label.compareTo(b.label);
      return d != 0 ? d : a.key.compareTo(b.key);
    });
  return out;
}

/// The live rows behind a [merchantsIn] total ([merchantKey] null: the whole category), newest first; their amounts
/// sum to exactly −spent. With [table], the rows of its children count too.
List<CategorizedTx> rowsFor(String category, String? merchantKey, List<CategorizedTx> txs, DateRange r,
    {required String currency, CategoryTable? table}) {
  final rows = _categoryRows(category, txs, r, currency, table);
  return merchantKey == null
      ? rows
      : [
          for (final t in rows)
            if (_merchantOf(t.tx) == merchantKey) t
        ];
}

/// One payee's spending per calendar month overlapping [r], shaped like [spendingByMonth]. [table]: as in [rowsFor].
List<MonthBar> merchantTrend(String category, String merchantKey, List<CategorizedTx> txs, DateRange r,
    {required String currency, required String today, CategoryTable? table}) {
  final spent = {for (final m in _monthsOf(r)) m: 0};
  for (final t in rowsFor(category, merchantKey, txs, r, currency: currency, table: table)) {
    spent[monthOf(t.date)] = spent[monthOf(t.date)]! - t.amount;
  }
  return [for (final e in spent.entries) MonthBar(month: e.key, spent: e.value, partial: _partial(e.key, r, today))];
}

/// [category] in calendar [month] (`YYYY-MM`) against the month before and the 6-month average. With [table], its
/// whole tree counts: the tree's rows are summed as one category before averaging, so the numbers are exact.
CategoryCompare compareCategory(String category, List<CategorizedTx> txs, String month, {required String currency, CategoryTable? table}) {
  final rows = table == null
      ? txs
      : [
          for (final t in txs)
            if (_inTree(t.category, category, table)) CategorizedTx(t.tx, category, t.kind)
        ];
  final before = monthsEnding(month, 2).first;
  return CategoryCompare(
    thisMonth: monthSummary(rows, month, currency: currency).byCategory[category] ?? 0,
    lastMonth: monthSummary(rows, before, currency: currency).byCategory[category] ?? 0,
    average6: averageByCategory(rows, month, currency: currency)[category] ?? 0,
  );
}

/// The [limit] largest spending rows (outflows of spending categories) in [r] by absolute amount; ties: newest
/// date first, then id ascending.
List<CategorizedTx> biggestRows(List<CategorizedTx> txs, DateRange r, {int limit = 10, required String currency}) {
  if (limit <= 0) return const [];
  final rows = [
    for (final t in txs)
      if (t.amount < 0 && r.contains(t.date) && countsAsSpending(t, currency)) t
  ]..sort((a, b) {
      var d = a.amount.compareTo(b.amount); // most negative first
      if (d == 0) d = b.date.compareTo(a.date);
      return d != 0 ? d : a.tx.id.compareTo(b.tx.id);
    });
  return rows.length > limit ? rows.sublist(0, limit) : rows;
}
