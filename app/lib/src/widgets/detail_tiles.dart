// The tiles the tag, category and merchant detail pages share (RX8, "Paper Tiles"): the page on the desk, the per-month bars, the
// compare tiles and the payments tile. Every figure arrives from the controller (core); nothing is added up here.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../theme.dart';
import 'common.dart';
import 'dash.dart';
import 'insight_charts.dart';
import 'sheets.dart';

/// A detail page: [DashGrid] of [children] on the desk, scrolling (the app bar stays).
class DetailPage extends StatelessWidget {
  final List<Widget> children;
  const DetailPage({super.key, required this.children});

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: context.c.desk,
        child: SingleChildScrollView(
          key: const ValueKey('detailPage'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          child: DashGrid(children: children),
        ),
      );
}

/// "12 % vs Sep" for spending of [now] against [before] (spending less is the good direction); "same as Sep" under half a percent;
/// null when [before] is not positive (no ratio to show).
DeltaChip? spendDelta(int now, int before, String against, {Key? key}) {
  if (before <= 0) return null;
  final change = changePermille(now, before);
  if (change == null) return null;
  if (change.abs() < 5) return DeltaChip(key: key, trend: Trend.flat, text: 'same as $against');
  return DeltaChip(
      key: key, trend: change > 0 ? Trend.up : Trend.down, text: '${(change.abs() + 5) ~/ 10} % vs $against', good: change < 0);
}

/// The compare figures of a detail page: [heroChip] for the hero when the hero already is the month, else a "this month" tile.
class ComparePart {
  final DashChip? heroChip;
  final List<Widget> tiles;

  /// The hero already is this month (so there is no "this month" tile). The page uses it to fill its rows without a hole: with one
  /// tile fewer, the Average tile is one cell wide and the months list gets a tile of its own.
  final bool monthIsHero;
  const ComparePart(this.heroChip, this.tiles, {required this.monthIsHero});
}

/// This month (only when the hero is not that month), last month and the 6-month average of [cmp], all core's. The hero total
/// [total] over [range] is "the month" when the range starts on the 1st, ends in [month] and equals this month's figure, so the
/// month is then said once, by the hero.
ComparePart compareParts(CategoryCompare cmp, {required String month, required DateRange range, required int total, required String cur}) {
  final prev = monthsEnding(month, 2).first;
  final single = range.start == '$month-01' && monthOf(range.end) == month && cmp.thisMonth == total;
  final delta = spendDelta(cmp.thisMonth, cmp.lastMonth, monthShort(prev), key: const ValueKey('compareDelta'));
  return ComparePart(
      single ? delta : null,
      [
        if (!single)
          StatTile(
              key: const ValueKey('compareThis'),
              label: 'This month',
              value: moneyExact(cmp.thisMonth, cur),
              sub: monthLong(month),
              chip: delta),
        StatTile(key: const ValueKey('compareLast'), label: 'Last month', value: moneyExact(cmp.lastMonth, cur), sub: monthLong(prev)),
        // Two cells wide when it follows "this month" and "last month": the row under the hero is then full (hero 2 + 1 + 1), this one
        // holds Average + the bars.
        DashItem(
          span: single ? 1 : 2,
          child: StatTile(
              key: const ValueKey('compareAverage'), label: 'Average', value: moneyExact(cmp.average6, cur), sub: 'of the 6 months before'),
        ),
      ],
      monthIsHero: single);
}

String _monthNote(MonthBar b, String nowMonth) => !b.partial ? '' : (b.month == nowMonth ? ' · so far' : ' · part of the month');

/// The exact amount of each month ([rowKey] names a row), the figures the bars cannot give to the cent. A tile of its own for a page
/// with room beside the chart; [MonthBarsTile] with `rows: true` holds the same rows under the bars.
class MonthRowsTile extends StatelessWidget {
  final String currency, nowMonth;
  final List<MonthBar> bars;
  final Key Function(String month) rowKey;
  const MonthRowsTile({super.key, required this.currency, required this.nowMonth, required this.bars, required this.rowKey});

  @override
  Widget build(BuildContext context) => Tile(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const TileLabel('Months'),
          const SizedBox(height: 4),
          _MonthRows(currency: currency, nowMonth: nowMonth, bars: bars, rowKey: rowKey),
        ]),
      );
}

class _MonthRows extends StatelessWidget {
  final String currency, nowMonth;
  final List<MonthBar> bars;
  final Key Function(String month) rowKey;
  const _MonthRows({required this.currency, required this.nowMonth, required this.bars, required this.rowKey});

  @override
  Widget build(BuildContext context) => DashRows(rows: [
        for (final b in bars)
          DashRowData(
              key: rowKey(b.month), title: '${monthLong(b.month)}${_monthNote(b, nowMonth)}', amount: moneyExact(b.spent, currency)),
      ]);
}

/// The spending per month as bars; with [rows] the exact amount of each month under them (otherwise a [MonthRowsTile] shows them).
class MonthBarsTile extends StatelessWidget {
  final String label, currency, nowMonth;
  final List<MonthBar> bars;
  final Key barsKey;
  final Key Function(String month) rowKey;
  final bool rows;
  const MonthBarsTile({
    super.key,
    required this.label,
    required this.currency,
    required this.nowMonth,
    required this.bars,
    required this.barsKey,
    required this.rowKey,
    this.rows = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    String note(MonthBar b) => _monthNote(b, nowMonth);
    return Tile(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const TileLabel('Per month'),
        const SizedBox(height: 8),
        MonthlyBars(
          key: barsKey,
          label: label,
          groups: [
            for (final b in bars)
              BarGroup(
                month: b.month,
                partial: b.partial,
                rods: [BarRod(b.spent, c.chartPos)],
                tip: '${monthLong(b.month)}${note(b)}\n${moneyExact(b.spent, currency)}',
                spoken: '${monthLong(b.month)}${note(b)}: ${moneyExact(b.spent, currency)}',
              ),
          ],
        ),
        if (rows) ...[
          const SizedBox(height: 8),
          _MonthRows(currency: currency, nowMonth: nowMonth, bars: bars, rowKey: rowKey),
        ],
      ]),
    );
  }
}

/// The payments behind a total, newest first, each opening the transaction sheet. The (i) says [help].
class PaymentsTile extends StatelessWidget {
  final WalletController wc;
  final List<CategorizedTx> rows;
  final Key rowsKey;
  final String emptyText, help;
  const PaymentsTile({super.key, required this.wc, required this.rows, required this.rowsKey, required this.emptyText, required this.help});

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    return Tile(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        SplitRow(
            start: const TileLabel('Payments'),
            end: TileInfo(key: const ValueKey('paymentsInfo'), onTap: () => showInfoSheet(context, 'Payments', help))),
        if (rows.isEmpty)
          EmptyNote(emptyText)
        else
          Column(key: rowsKey, children: [
            const TxHeaderRow(),
            for (final t in rows)
              TxTile(
                  table: wc.categoryTable,
                  tagTable: wc.tagTable,
                  t: t,
                  currency: cur,
                  fxRates: wc.settings.fxRates,
                  hasBill: wc.billForTx(t.tx.id) != null,
                  matched: wc.isMatchedBank(t.tx.id),
                  iouTag: wc.iouTagOf(t.tx.id),
                  onTap: () async {
                    final res = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                    if (context.mounted) txSheetToast(context, wc, res);
                  }),
          ]),
      ]),
    );
  }
}
