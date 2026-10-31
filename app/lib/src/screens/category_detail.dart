// Drill-down (stage N3): a category over a range (compare, trend, merchants), then one merchant's rows. Every total shown is
// core's; the rows listed are core's `rowsFor`, so they add up to it.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/insight_charts.dart';
import '../widgets/sheets.dart';

/// Opens [category] over [range] (a page on a phone, a dialog from 600 dp).
Future<void> openCategory(BuildContext context, WalletController wc, String category, DateRange range) =>
    openPageOrDialog<void>(context, CategoryDetailScreen(wc: wc, category: category, range: range), width: 640, logName: 'CategoryDetail');

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
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 88), children: [
              if (shown == null) ..._categoryView(context, cur, merchants) else ..._merchantView(context, cur, shown),
            ]),
          );
        },
      ),
    );
  }

  Widget _bars(BuildContext context, List<MonthBar> bars, String cur, String label, String id) {
    final c = context.c;
    final now = monthOf(wc.today());
    String note(MonthBar b) => !b.partial ? '' : (b.month == now ? ' · so far' : ' · part of the month');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MonthlyBars(
        key: ValueKey('detailBars_$id'),
        label: label,
        groups: [
          for (final b in bars)
            BarGroup(
              month: b.month,
              partial: b.partial,
              rods: [BarRod(b.spent, c.chartPos)],
              tip: '${monthLong(b.month)}${note(b)}\n${moneyExact(b.spent, cur)}',
              spoken: '${monthLong(b.month)}${note(b)}: ${moneyExact(b.spent, cur)}',
            ),
        ],
      ),
      const SizedBox(height: 8),
      Rows(children: [
        for (final b in bars)
          LineItem('${monthLong(b.month)}${note(b)}', moneyExact(b.spent, cur), key: ValueKey('detailRow_${id}_${b.month}')),
      ]),
    ]);
  }

  List<Widget> _categoryView(BuildContext context, String cur, List<MerchantTotal> merchants) {
    final total = wc.categoryTotal(widget.category, range);
    final cmp = wc.compareFor(widget.category, range);
    final month = wc.monthIn(range);
    return gapped([
      Panel(children: [
        Eyebrow(rangeLabel(range)),
        Heading(moneyExact(total, cur), key: const ValueKey('detailTotal')),
      ]),
      Panel(children: [
        const Eyebrow('Compared'),
        Rows(children: [
          LineItem(monthLong(month), moneyExact(cmp.thisMonth, cur), key: const ValueKey('compareThis')),
          LineItem(monthLong(monthsEnding(month, 2).first), moneyExact(cmp.lastMonth, cur), key: const ValueKey('compareLast')),
          LineItem('Average of the 6 months before', moneyExact(cmp.average6, cur), key: const ValueKey('compareAverage')),
        ]),
      ]),
      Panel(children: [
        const Eyebrow('Per month'),
        _bars(context, wc.categoryBars(widget.category, range), cur, '$name per month', 'category'),
      ]),
      Panel(children: [
        const Eyebrow('Where it went'),
        if (merchants.isEmpty)
          const EmptyNote('Nothing spent in this range.')
        else
          Rows(children: [
            for (final m in merchants)
              InkWell(
                key: ValueKey('merchantRow_${m.key}'),
                onTap: () => _open(m.key),
                child: LineItem(m.label, moneyExact(m.spent, cur),
                    sub: '${m.count} ${m.count == 1 ? 'payment' : 'payments'} · last ${shortDateOrRaw(m.lastDate)}'),
              ),
          ]),
      ]),
    ], gap: 16);
  }

  List<Widget> _merchantView(BuildContext context, String cur, MerchantTotal m) {
    final rows = wc.rowsOf(widget.category, m.key, range);
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
            key: const ValueKey('detailBack'),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => _open(null),
            icon: const Icon(Icons.chevron_left),
            label: Text('Back to $name')),
      ),
      ...gapped([
        Panel(children: [
          Eyebrow(rangeLabel(range)),
          Heading(m.label),
          Heading(moneyExact(m.spent, cur), key: const ValueKey('detailTotal'), size: BwType.amountMdSize),
          Muted('${m.count} ${m.count == 1 ? 'payment' : 'payments'} in $name.'),
        ]),
        Panel(children: [
          const Eyebrow('Per month'),
          _bars(context, wc.merchantBars(widget.category, m.key, range), cur, '${m.label} per month', 'merchant'),
        ]),
        Panel(children: [
          const Eyebrow('Payments'),
          const Muted('Tap one to change it.'),
          Column(key: const ValueKey('merchantRows'), children: [
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
      ], gap: 16),
    ];
  }
}
