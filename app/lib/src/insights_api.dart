// Insights (stage N3): the date range each graph shows (one [InsightRange] per graph) and the graph data for a range.
// No money logic here: every number comes from wallet_core's insights.dart / ranges.dart; this file picks the range, keeps the
// result per data version + day (so redrawing or stepping back to a range does not recompute) and logs counts only.
import 'package:flutter/foundation.dart';
import 'package:wallet_core/wallet_core.dart';

import 'controller.dart';

final _log = Logger('bw.insights');

/// The graphs that have a range control, by id (also the key of the device-local setting).
const insightGraphs = ['spending', 'share', 'tags', 'income', 'budget', 'biggest'];

/// The kind each graph starts with.
RangeKind defaultKindFor(String id) => switch (id) {
      'share' || 'tags' || 'biggest' => RangeKind.month,
      _ => RangeKind.months6,
    };

String rangeKindLabel(RangeKind k) => switch (k) {
      RangeKind.payPeriod => 'This pay period',
      RangeKind.month => 'Month',
      RangeKind.months3 => '3 months',
      RangeKind.months6 => '6 months',
      RangeKind.months12 => '12 months',
      RangeKind.custom => 'Custom',
    };

/// The range one graph shows: a [kind], how many whole ranges back from the current one ([offset], 0 = current), or for
/// [RangeKind.custom] the chosen dates. Changing it notifies; a refused range keeps the old one and sets [error].
/// The kind is remembered on this device (`insightRange:<id>`); custom dates too, but never the offset.
class InsightRange extends ChangeNotifier {
  final WalletController wc;
  final String id;
  RangeKind kind;
  int offset = 0;
  String? _from, _to;

  /// Why the last change was refused (core's message), null when the last change worked.
  String? error;
  DateRange? _range;
  String? _stamp;

  InsightRange(this.wc, this.id) : kind = defaultKindFor(id) {
    final saved = wc.repo.localValue('insightRange:$id');
    if (saved == null) return;
    final parts = saved.split(':');
    final k = RangeKind.values.where((k) => k.name == parts.first).firstOrNull;
    if (k == null) return;
    if (k == RangeKind.custom) {
      if (parts.length != 3) return;
      try {
        wc.resolveRange(RangeKind.custom, from: parts[1], to: parts[2]);
      } on ArgumentError {
        return; // dates that are no longer allowed (a new month cannot make an old range invalid, but a bad value can)
      }
      _from = parts[1];
      _to = parts[2];
    }
    kind = k;
  }

  /// The range to draw now. Worked out again when the data or the day changed.
  DateRange get range {
    final stamp = '${wc.dataVersion}|${wc.today()}';
    final cached = _range;
    if (cached != null && _stamp == stamp) return cached;
    _stamp = stamp;
    return _range = _resolve();
  }

  DateRange _resolve() {
    try {
      if (kind == RangeKind.custom) return wc.resolveRange(kind, from: _from, to: _to);
      return wc.resolveRange(kind, offset: offset);
    } on ArgumentError {
      kind = defaultKindFor(id);
      offset = 0;
      return wc.resolveRange(kind);
    }
  }

  /// Whether a step forward is possible (never past the current range).
  bool get canForward {
    if (kind != RangeKind.custom) return offset < 0;
    try {
      wc.shiftedRange(range, kind, 1);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  void _save() {
    final v = kind == RangeKind.custom ? 'custom:$_from:$_to' : kind.name;
    wc.repo.setLocalValue('insightRange:$id', v);
  }

  /// Picks a kind (the current period of that kind). A custom range without dates yet keeps the shown range's dates.
  void select(RangeKind k) {
    final shown = range;
    if (k == RangeKind.custom) {
      _from = shown.start;
      // A pay period can run into next month; a custom range may not go past the end of this month.
      final lastDay = wc.monthRange(monthOf(wc.today())).end;
      _to = shown.end.compareTo(lastDay) > 0 ? lastDay : shown.end;
      try {
        wc.resolveRange(k, from: _from, to: _to);
      } on ArgumentError catch (e) {
        error = '${e.message}';
        notifyListeners();
        return;
      }
    }
    kind = k;
    offset = 0;
    _afterChange('select');
  }

  /// One range back (-1) or forward (+1) of the same kind.
  void step(int by) {
    if (by == 0) return;
    try {
      if (kind == RangeKind.custom) {
        final next = wc.shiftedRange(range, kind, by);
        _from = next.start;
        _to = next.end;
      } else {
        if (by > 0 && offset >= 0) return;
        wc.shiftedRange(wc.resolveRange(kind), kind, offset + by); // checks it before taking it
        offset += by;
      }
    } on ArgumentError catch (e) {
      error = '${e.message}';
      notifyListeners();
      return;
    }
    _afterChange('step');
  }

  /// A range typed or picked by the owner. Refused ranges set [error] and change nothing.
  void setCustom(String from, String to) {
    try {
      wc.resolveRange(RangeKind.custom, from: from, to: to);
    } on ArgumentError catch (e) {
      error = '${e.message}';
      notifyListeners();
      return;
    }
    kind = RangeKind.custom;
    offset = 0;
    _from = from;
    _to = to;
    _afterChange('custom');
  }

  void _afterChange(String how) {
    error = null;
    _range = null;
    _save();
    logEvent(_log, Level.INFO, 'insights.range', {'graph': id, 'kind': kind.name, 'how': how, 'offset': offset});
    notifyListeners();
  }
}

/// Graph data per range, from wallet_core. Every method is cached per range until the data (or the day) changes.
extension WalletInsights on WalletController {
  /// The range of [kind] [offset] ranges back (0 = the current one). [RangeKind.custom] needs [from] and [to]. Throws
  /// [ArgumentError] for a range core refuses.
  DateRange resolveRange(RangeKind kind, {int offset = 0, String? from, String? to}) {
    if (kind == RangeKind.custom) {
      return memo('ins.range.custom.$from.$to', () => rangeFor(kind, today(), effectiveSettings, txs: txs, from: from, to: to));
    }
    final base = memo('ins.range.$kind', () => rangeFor(kind, today(), effectiveSettings, txs: txs));
    return offset == 0 ? base : shiftedRange(base, kind, offset);
  }

  /// [r] moved by [steps] ranges of [kind]; [ArgumentError] when core refuses the result.
  DateRange shiftedRange(DateRange r, RangeKind kind, int steps) => shiftRange(r, kind, steps, effectiveSettings, txs: txs, today: today());

  String _k(String what, DateRange r) => 'ins.$what.${r.start}.${r.end}';

  /// The calendar month that "now" means inside [r]: the month of its last day, but never after today (a pay period that ends
  /// next month still compares this month).
  String monthIn(DateRange r) => monthOf(r.end.compareTo(today()) > 0 ? today() : r.end);

  List<MonthBar> spendingBars(DateRange r) => memo(_k('bars', r),
      () => timed('insights.bars', () => spendingByMonth(txs, r, currency: currency, today: today()), fields: _f(r), warnMs: 50));

  CategoryShare shareFor(DateRange r) => memo(_k('share', r),
      () => timed('insights.share', () => categoryShare(txs, r, currency: currency, table: categoryTable), fields: _f(r), warnMs: 50));

  /// Spending of [category] over [r]: the rows' sum, so a refund-only category shows its negative total (the share drops it). It
  /// equals the "Where it goes" total.
  int categoryTotal(String category, DateRange r) => -rowsOf(category, null, r).fold<int>(0, (s, t) => s + t.amount);

  List<IncomeVsSpending> incomeBars(DateRange r) => memo(_k('income', r),
      () => timed('insights.income', () => incomeVsSpending(txs, r, currency: currency, today: today()), fields: _f(r), warnMs: 50));

  List<BudgetMonth> budgetBars(DateRange r) => memo(
      _k('budget', r),
      () => timed(
          'insights.budget', () => budgetVsActualSeries(txs, r, categoryBudgets, today: today(), currency: currency, table: categoryTable),
          fields: _f(r), warnMs: 50));

  List<MerchantTotal> merchantsFor(String category, DateRange r) => memo(
      '${_k('merchants', r)}.$category',
      () => timed('insights.merchants', () => merchantsIn(category, txs, r, currency: currency, table: categoryTable),
          fields: _f(r), warnMs: 50));

  /// The rows behind a total ([merchantKey] null: the whole category), newest first; they add up to the total.
  List<CategorizedTx> rowsOf(String category, String? merchantKey, DateRange r) => memo(
      '${_k('rows', r)}.$category.$merchantKey',
      () => timed('insights.rows', () => rowsFor(category, merchantKey, txs, r, currency: currency, table: categoryTable),
          fields: _f(r), warnMs: 50));

  List<MonthBar> merchantBars(String category, String merchantKey, DateRange r) => memo(
      '${_k('mtrend', r)}.$category.$merchantKey',
      () => timed('insights.merchantTrend',
          () => merchantTrend(category, merchantKey, txs, r, currency: currency, today: today(), table: categoryTable),
          fields: _f(r), warnMs: 50));

  /// The category's spending per month over [r]: its rows added up per calendar month (the same rows as [categoryTotal]).
  List<MonthBar> categoryBars(String category, DateRange r) => memo('${_k('ctrend', r)}.$category', () {
        final spent = <String, int>{};
        for (final t in rowsOf(category, null, r)) {
          spent[monthOf(t.date)] = (spent[monthOf(t.date)] ?? 0) - t.amount;
        }
        return [for (final b in spendingBars(r)) MonthBar(month: b.month, spent: spent[b.month] ?? 0, partial: b.partial)];
      });

  /// This month, last month and the 6-month average of [category] (the figures equal the "Where it goes" rows).
  CategoryCompare compareFor(String category, DateRange r) =>
      memo('${_k('compare', r)}.$category', () => compareCategory(category, txs, monthIn(r), currency: currency, table: categoryTable));

  List<CategorizedTx> biggestIn(DateRange r) =>
      memo(_k('biggest', r), () => timed('insights.biggest', () => biggestRows(txs, r, currency: currency), fields: _f(r), warnMs: 50));

  /// Income, fixed and flexible spending and the net of the last [count] pay periods, oldest first (the last one is running).
  List<PeriodReport> periodReportsFor({int count = 12}) => memo(
      'rep.periods.$count',
      () => timed('reports.periods', () => periodReports(txs, settings, today(), table: categoryTable, count: count),
          fields: {'count': count, 'tx': txs.length}, warnMs: 50));

  /// What [category] spent in each of the last [count] pay periods against its budget, oldest first.
  List<CategoryPeriod> categoryByPeriodFor(String category, {int count = 12}) => memo(
      'rep.catPeriods.$category.$count',
      () => timed('reports.categoryPeriods', () => categoryByPeriod(category, txs, settings, today(), table: categoryTable, count: count),
          fields: {'count': count, 'tx': txs.length}, warnMs: 50));

  /// Wishes skipped since the current pay period started (its first day to now).
  SavedByWaiting savedThisPeriod() => memo('rep.saved.${period().start}', () {
        final from = DateTime.parse(period().start).millisecondsSinceEpoch;
        return savedByWaiting(wish, fromMillis: from, toMillis: now.millisecondsSinceEpoch + 1);
      });

  /// Every skipped wish, all time.
  SavedByWaiting savedAllTime() => memo('rep.savedAll', () => savedByWaitingAll(wish));

  /// The month `YYYY-MM` as a range (first to last day).
  DateRange monthRange(String month) => DateRange(start: '$month-01', end: '$month-${daysInMonth(month).toString().padLeft(2, '0')}');

  Map<String, Object?> _f(DateRange r) => {'days': r.days, 'tx': txs.length};
}
