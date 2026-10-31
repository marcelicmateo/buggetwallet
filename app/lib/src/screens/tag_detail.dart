// Drill-down for an extra tag (T1): its total over a range, the spending per month, and the payments behind it. The total is the sum of
// the rows listed (core's `rowsForTag`), so they always add up. A payment can have several tags, so one payment shows under each.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/insight_charts.dart';
import '../widgets/sheets.dart';

/// Opens [tag] over [range] (a page on a phone, a dialog from 600 dp).
Future<void> openTag(BuildContext context, WalletController wc, String tag, DateRange range) =>
    openPageOrDialog<void>(context, TagDetailScreen(wc: wc, tag: tag, range: range), width: 640, logName: 'TagDetail');

class TagDetailScreen extends StatelessWidget {
  final WalletController wc;
  final String tag;
  final DateRange range;
  const TagDetailScreen({super.key, required this.wc, required this.tag, required this.range});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final c = context.c;
          final cur = wc.currency;
          final name = '#${wc.tagTable.label(tag)}';
          final rows = wc.rowsOfTag(tag, range);
          final total = -rows.fold<int>(0, (s, t) => s + t.amount);
          final bars = wc.tagBars(tag, range);
          final now = monthOf(wc.today());
          String note(MonthBar b) => !b.partial ? '' : (b.month == now ? ' · so far' : ' · part of the month');
          return Scaffold(
            appBar: DialogAppBar(title: name),
            body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 88), children: [
              ...gapped([
                Panel(children: [
                  Eyebrow(rangeLabel(range)),
                  Heading(moneyExact(total, cur), key: const ValueKey('tagDetailTotal')),
                  Muted('${rows.length} ${rows.length == 1 ? 'payment' : 'payments'}. A payment can have other tags too.'),
                ]),
                Panel(children: [
                  const Eyebrow('Per month'),
                  MonthlyBars(
                    key: const ValueKey('tagDetailBars'),
                    label: '$name per month',
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
                      LineItem('${monthLong(b.month)}${note(b)}', moneyExact(b.spent, cur), key: ValueKey('tagDetailRow_${b.month}')),
                  ]),
                ]),
                Panel(children: [
                  const Eyebrow('Payments'),
                  const Muted('Tap one to change it.'),
                  if (rows.isEmpty)
                    const EmptyNote('Nothing spent with this tag in this range.')
                  else
                    Column(key: const ValueKey('tagRows'), children: [
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
            ]),
          );
        },
      );
}
