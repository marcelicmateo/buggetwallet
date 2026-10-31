// Drill-down (stage N3, RX8 dashboard): a category over a range (total, compare, trend, merchants), then one merchant's rows. Every total
// shown is core's; the rows listed are core's `rowsFor`, so they add up to it.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/detail_tiles.dart';
import '../widgets/sheets.dart';

/// Opens [category] over [range] (a page on a phone, a dialog from 600 dp).
Future<void> openCategory(BuildContext context, WalletController wc, String category, DateRange range) =>
    openPageOrDialog<void>(context, CategoryDetailScreen(wc: wc, category: category, range: range), width: 840, logName: 'CategoryDetail');

class CategoryDetailScreen extends StatefulWidget {
  final WalletController wc;
  final String category;
  final DateRange range;
  const CategoryDetailScreen({super.key, required this.wc, required this.category, required this.range});
  @override
  State<CategoryDetailScreen> createState() => _CategoryDetailState();
}

class _CategoryDetailState extends State<CategoryDetailScreen> {
  /// The merchant key being looked at (null: the category view). '' is the "Other" group.
  String? merchant;

  WalletController get wc => widget.wc;
  String get name => wc.categoryTable.label(widget.category);
  DateRange get range => widget.range;

  void _open(String? key) {
    logNav(key == null ? 'insights.categoryView' : 'insights.merchant');
    setState(() => merchant = key);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: DialogAppBar(title: wc.categoryTable.label(widget.category)),
      body: ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final cur = wc.currency;
          final merchants = wc.merchantsFor(widget.category, range);
          final shown = merchant == null ? null : merchants.where((m) => m.key == merchant).firstOrNull;
          // An edit removed the merchant being shown: show the category again, so Back leaves the screen.
          if (merchant != null && shown == null) merchant = null;
          return PopScope(
            canPop: merchant == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _open(null);
            },
            child: DetailPage(children: shown == null ? _categoryView(context, cur, merchants) : _merchantView(cur, shown)),
          );
        },
      ),
    );
  }

  /// The bars over time, starting at the page's range; one month is a row of days.
  Widget _bars(String id, String label, {String? merchantKey}) {
    final oneMonth = monthOf(range.start) == monthOf(range.end);
    return DashItem(
        span: oneMonth ? 4 : 2,
        child: SeriesBarsTile(
          wc: wc,
          id: id,
          label: label,
          range: range,
          bars: (w, b) => wc.spendingSeriesFor(w, b, category: widget.category, merchantKey: merchantKey),
          payments: (span) => wc.rowsOf(widget.category, merchantKey, span),
          barsKey: ValueKey('detailBars_$id'),
          rowKey: (r) => ValueKey('detailRow_${id}_$r'),
        ));
  }

  List<Widget> _categoryView(BuildContext context, String cur, List<MerchantTotal> merchants) {
    final c = context.c;
    final total = wc.categoryTotal(widget.category, range);
    // The bars the tile shows when it opens (the same window, so the same bar size).
    final bars = wc.spendingSeriesFor(range, bucketFor(range), category: widget.category);
    final parts =
        compareParts(wc.compareFor(widget.category, range), month: wc.monthIn(range), range: range, total: total, cur: cur, bars: bars);
    final biggest = merchants.fold<int>(1, (m, x) => x.spent > m ? x.spent : m);
    return [
      DashItem(
        span: 2,
        child: HeroTile(
          valueKey: const ValueKey('detailTotal'),
          label: 'Total',
          value: moneyExact(total, cur),
          sub: rangeLabel(range),
          chip: parts.heroChip,
        ),
      ),
      ...parts.tiles,
      _bars('category', '$name over time'),
      DashItem(
        span: 2,
        child: Tile(
          key: const ValueKey('merchantsTile'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            const TileLabel('Where it went'),
            const SizedBox(height: 4),
            if (merchants.isEmpty)
              const EmptyNote('Nothing spent in this range.')
            else
              BarList(rows: [
                for (final m in merchants)
                  BarRow(
                    key: ValueKey('merchantRow_${m.key}'),
                    label: m.label,
                    value: moneyExact(m.spent, cur),
                    note: '${m.count} ${m.count == 1 ? 'payment' : 'payments'} · last ${shortDateOrRaw(m.lastDate)}',
                    fraction: m.spent > 0 ? m.spent / biggest : 0,
                    color: c.s1,
                    onTap: () => _open(m.key),
                  ),
              ]),
          ]),
        ),
      ),
    ];
  }

  List<Widget> _merchantView(String cur, MerchantTotal m) {
    final rows = wc.rowsOf(widget.category, m.key, range);
    return [
      DashItem(
        span: 4,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              key: const ValueKey('detailBack'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () => _open(null),
              icon: const Icon(Icons.chevron_left),
              label: Text('Back to $name')),
        ),
      ),
      DashItem(
        span: 2,
        child: HeroTile(
          valueKey: const ValueKey('detailTotal'),
          label: m.label,
          value: moneyExact(m.spent, cur),
          sub: '${rangeLabel(range)} · ${m.count} ${m.count == 1 ? 'payment' : 'payments'} in $name',
        ),
      ),
      _bars('merchant', '${m.label} over time', merchantKey: m.key),
      DashItem(
        span: 4,
        child: PaymentsTile(
          wc: wc,
          rows: rows,
          rowsKey: const ValueKey('merchantRows'),
          emptyText: 'Nothing spent in this range.',
          help: 'Tap a payment to change it.',
        ),
      ),
    ];
  }
}
