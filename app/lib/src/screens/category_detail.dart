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

  /// One month: its one figure is the hero's, so the exact-months rows are left out (the bars stay).
  Widget _bars(String cur, List<MonthBar> bars, String label, String id) => DashItem(
      span: bars.length <= 1 ? 4 : 2,
      child: MonthBarsTile(
        rows: bars.length > 1,
        label: label,
        currency: cur,
        nowMonth: monthOf(wc.today()),
        bars: bars,
        barsKey: ValueKey('detailBars_$id'),
        rowKey: (m) => ValueKey('detailRow_${id}_$m'),
      ));

  List<Widget> _categoryView(BuildContext context, String cur, List<MerchantTotal> merchants) {
    final c = context.c;
    final total = wc.categoryTotal(widget.category, range);
    final parts = compareParts(wc.compareFor(widget.category, range), month: wc.monthIn(range), range: range, total: total, cur: cur);
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
      _bars(cur, wc.categoryBars(widget.category, range), '$name per month', 'category'),
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
      _bars(cur, wc.merchantBars(widget.category, m.key, range), '${m.label} per month', 'merchant'),
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
