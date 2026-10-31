// The tiles the tag, category and merchant detail pages share (RX8, "Paper Tiles"): the page on the desk, the per-month bars, the
// compare tiles and the payments tile. Every figure arrives from the controller (core); nothing is added up here.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../logging.dart';
import '../screens/bucket_payments.dart';
import '../theme.dart';
import 'chart_viewport.dart';
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
/// month is then said once, by the hero. When the bars the page shows ([bars]) are month bars that include both [month] and the month
/// before, the two tiles would repeat them: only the Average stays (and the page lays out as when the hero is the month). Day and week
/// bars do not hold the months, so the tiles stay.
ComparePart compareParts(CategoryCompare cmp,
    {required String month, required DateRange range, required int total, required String cur, List<SeriesBar> bars = const []}) {
  final prev = monthsEnding(month, 2).first;
  final single = range.start == '$month-01' && monthOf(range.end) == month && cmp.thisMonth == total;
  bool has(String m) => bars.any((b) => b.bucket == Bucket.month && monthOf(b.span.start) == m);
  final listed = !single && has(month) && has(prev);
  final delta = spendDelta(cmp.thisMonth, cmp.lastMonth, monthShort(prev), key: const ValueKey('compareDelta'));
  return ComparePart(
      single ? delta : null,
      [
        if (!single && !listed)
          StatTile(
              key: const ValueKey('compareThis'),
              label: 'This month',
              value: moneyExact(cmp.thisMonth, cur),
              sub: monthLong(month),
              chip: delta),
        if (!listed)
          StatTile(key: const ValueKey('compareLast'), label: 'Last month', value: moneyExact(cmp.lastMonth, cur), sub: monthLong(prev)),
        // Two cells wide when it follows "this month" and "last month" or stands alone beside the hero: the row under the hero is
        // then full (hero 2 + 1 + 1, or hero 2 + 2), this one holds Average + the bars.
        DashItem(
          span: single ? 1 : 2,
          child: StatTile(
              key: const ValueKey('compareAverage'), label: 'Average', value: moneyExact(cmp.average6, cur), sub: 'of the 6 months before'),
        ),
      ],
      monthIsHero: single || listed);
}

/// The spending of a category, merchant or tag over time as bars you can drag and zoom (ZC), with the exact amount of each bar under
/// them. The window starts as the page's [range] (Reset goes back to it); drag, pinch and the buttons change it. [bars] reads the day
/// index, [payments] gives the payments behind one bar (a tap on it or its row). A single bar is the hero's one figure: no row for it.
class SeriesBarsTile extends StatelessWidget {
  final WalletController wc;
  final String id, label;
  final DateRange range;
  final List<SeriesBar> Function(DateRange window, Bucket bucket) bars;
  final List<CategorizedTx> Function(DateRange span) payments;
  final Key barsKey;
  final Key Function(String rowId) rowKey;
  const SeriesBarsTile({
    super.key,
    required this.wc,
    required this.id,
    required this.label,
    required this.range,
    required this.bars,
    required this.payments,
    required this.barsKey,
    required this.rowKey,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cur = wc.currency, today = wc.today();
    String name(SeriesBar x) => barName(x.span, x.bucket, x.partial, today);
    void open(SeriesBar x) {
      logNav('detail.bar', {'graph': id, 'bucket': x.bucket.name});
      openBucketPayments(context, wc, title: barName(x.span, x.bucket, false, today), rows: () => payments(x.span));
    }

    return Tile(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const TileLabel('Over time'),
        const SizedBox(height: 8),
        ChartViewport(
          id: id,
          initial: range,
          edges: wc.chartEdges,
          // The page's range is the hero's sub line; the dates show once the window has moved off it.
          datesText: (w) => w == range ? null : rangeLabel(w),
          chart: (context, w, b) {
            final list = bars(w, b);
            return SeriesBars(
              key: barsKey,
              label: label,
              groups: [
                for (var i = 0; i < list.length; i++)
                  BarGroup(
                    start: list[i].span.start,
                    axis: barAxisText(list[i].span, b, firstOfAll: i == 0),
                    partial: list[i].partial,
                    rods: [BarRod(list[i].spent, c.chartPos)],
                    tip: '${name(list[i])}\n${moneyExact(list[i].spent, cur)}',
                    spoken: '${name(list[i])}: ${moneyExact(list[i].spent, cur)}',
                  ),
              ],
              onOpen: (i) => open(list[i]),
            );
          },
          legend: (context, w, b) =>
              bars(w, b).any((x) => x.partial) ? Legend([LegendItem(c.chartPos, barFadedText(b), dashed: true)]) : const SizedBox.shrink(),
          rows: (context, w, b) {
            final list = bars(w, b);
            // One bar is its one figure, the hero's: no row for it.
            if (list.length <= 1) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DashRows(rows: [
                for (final x in list)
                  DashRowData(key: rowKey(barRowId(x.span, b)), title: name(x), amount: moneyExact(x.spent, cur), onTap: () => open(x)),
              ]),
            );
          },
        ),
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
