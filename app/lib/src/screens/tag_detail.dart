// Drill-down for an extra tag (T1, RX8 dashboard): the total over a range, this month against last month and the average, the spending
// per month, and the payments behind it. Every figure is core's (`tagTotalFor`, `compareTagFor`, `tagBars`); the total is the sum of the
// rows listed, so they always add up. A payment can have several tags, so one payment shows under each.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../widgets/dash.dart';
import '../widgets/detail_tiles.dart';
import '../widgets/sheets.dart';

/// Opens [tag] over [range] (a page on a phone, a dialog from 600 dp).
Future<void> openTag(BuildContext context, WalletController wc, String tag, DateRange range) =>
    openPageOrDialog<void>(context, TagDetailScreen(wc: wc, tag: tag, range: range), width: 840, logName: 'TagDetail');

class TagDetailScreen extends StatelessWidget {
  final WalletController wc;
  final String tag;
  final DateRange range;
  const TagDetailScreen({super.key, required this.wc, required this.tag, required this.range});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final cur = wc.currency;
          final name = '#${wc.tagTable.label(tag)}';
          final rows = wc.rowsOfTag(tag, range);
          final total = wc.tagTotalFor(tag, range);
          final cmp = wc.compareTagFor(tag, range);
          // The bars the tile shows when it opens (the same window, so the same bar size).
          final bars = wc.spendingSeriesFor(range, bucketFor(range), tag: tag);
          final parts = compareParts(cmp, month: wc.monthIn(range), range: range, total: total.spent, cur: cur, bars: bars);
          // One month: its one figure is the hero's, so no exact rows until the window moves (the bars stay).
          final oneMonth = monthOf(range.start) == monthOf(range.end);
          return Scaffold(
            appBar: DialogAppBar(title: name),
            body: DetailPage(children: [
              DashItem(
                span: 2,
                child: HeroTile(
                  valueKey: const ValueKey('tagDetailTotal'),
                  label: 'Total',
                  value: moneyExact(total.spent, cur),
                  sub: '${rangeLabel(range)} · ${total.count} ${total.count == 1 ? 'payment' : 'payments'}',
                  chip: parts.heroChip,
                ),
              ),
              ...parts.tiles,
              DashItem(
                span: oneMonth || parts.monthIsHero ? 4 : 2,
                child: SeriesBarsTile(
                  wc: wc,
                  id: 'tag',
                  label: '$name over time',
                  range: range,
                  bars: (w, b) => wc.spendingSeriesFor(w, b, tag: tag),
                  payments: (span) => wc.rowsOfTag(tag, span),
                  barsKey: const ValueKey('tagDetailBars'),
                  rowKey: (r) => ValueKey('tagDetailRow_$r'),
                ),
              ),
              DashItem(
                span: 4,
                child: PaymentsTile(
                  wc: wc,
                  rows: rows,
                  rowsKey: const ValueKey('tagRows'),
                  emptyText: 'Nothing spent with this tag in this range.',
                  help: 'Tap a payment to change it. A payment can have other tags too, so it shows under each of them.',
                ),
              ),
            ]),
          );
        },
      );
}
