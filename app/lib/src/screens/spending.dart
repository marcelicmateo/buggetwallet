import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

class SpendingScreen extends StatefulWidget {
  final WalletController wc;
  const SpendingScreen({super.key, required this.wc});
  @override
  State<SpendingScreen> createState() => _SpendingScreenState();
}

class _SpendingScreenState extends State<SpendingScreen> {
  String? selected;

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final cur = wc.currency;
    final current = monthOf(wc.today());
    final months = monthsEnding(current, 13);
    final sums = [for (final m in months) monthSummary(wc.txs, m)];
    final sel = selected != null && months.contains(selected) ? selected! : current;
    final selSum = sums.firstWhere((s) => s.month == sel);
    final prev = sums.where((s) => s.month.compareTo(sel) < 0).toList();
    final prev6 = prev.length > 6 ? prev.sublist(prev.length - 6) : prev;
    final avg = <String, int>{};
    for (final p in prev6) {
      p.byCategory.forEach((k, v) => avg[k] = (avg[k] ?? 0) + (v / (prev6.isEmpty ? 1 : prev6.length)).round());
    }
    final periods = wc.payPeriods(count: 12);
    final trend = trendNet(periods);
    final done = savingsOverview(periods);

    final merch = <String, (int, int)>{};
    for (final t in wc.txs.where((t) => monthOf(t.date) == sel && t.kind == Kind.flex && t.amount < 0)) {
      final k = merchantName(t.tx);
      final (n, v) = merch[k] ?? (0, 0);
      merch[k] = (n + 1, v - t.amount);
    }
    final top = merch.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    final monthTxs = wc.txs.where((t) => monthOf(t.date) == sel && t.kind != Kind.transfer).toList();

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: gapped([
          Panel(children: [
            const Eyebrow('Saving or losing'),
            if (periods.isEmpty) ...[
              const Heading('No pay periods yet'),
              const Muted('Import a bank file with your salary. Each pay period runs from one salary to the next.'),
            ] else ...[
              Heading(_savedHeading(done, cur)),
              Muted(_savedNote(done)),
              PeriodNetChart(periods: periods, trend: trend, currency: cur),
            ],
          ]),
          Panel(children: [
            const Eyebrow('Where it goes'),
            Heading('${monthLong(sel)}: ${money(selSum.out, cur, decimals: 0)} out'),
            Muted(
                'Income ${money(selSum.income, cur, decimals: 0)}. Spending and bills by category; the dark tick is your average of the 6 months before.'),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final m in months.sublist(months.length - 7))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                        label: Text(m == current ? '${monthShort(m)} (now)' : monthShort(m)),
                        selected: m == sel,
                        onSelected: (_) => setState(() => selected = m)),
                  ),
              ]),
            ),
            CategoryBars(values: selSum.byCategory, average: avg, currency: cur),
          ]),
          Panel(children: [
            Heading('Top places in ${monthLong(sel)}', size: 15),
            if (top.isEmpty)
              const EmptyNote('No card spending this month yet.')
            else
              Rows(children: [
                for (final e in top.take(8))
                  LineItem(e.key, money(e.value.$2, cur, decimals: 0), sub: '${e.value.$1} ${e.value.$1 == 1 ? 'payment' : 'payments'}')
              ]),
          ]),
          Panel(children: [
            Heading('All transactions in ${monthLong(sel)}', size: 15),
            const Muted('Tap one to change its category. Transfers between your own accounts are hidden.'),
            if (monthTxs.isEmpty)
              const EmptyNote('No transactions.')
            else
              Rows(children: [
                for (final t in monthTxs)
                  TxTile(
                      t: t,
                      currency: cur,
                      onTap: () async {
                        final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                        if (r != null && context.mounted) toast(context, r == 'deleted' ? 'Deleted' : 'Category saved');
                      }),
              ]),
          ]),
        ]));
  }
}

String _periods(int n) => n == 1 ? 'pay period' : '$n pay periods';

String _savedHeading(SavingsOverview o, String cur) {
  if (o.periods == 0) return 'First pay period still running';
  final over = o.periods == 1 ? 'in the last pay period' : 'over the last ${_periods(o.periods)}';
  return o.net >= 0 ? 'Saved ${money(o.net, cur, decimals: 0)} $over' : 'Lost ${money(-o.net, cur, decimals: 0)} $over';
}

String _savedNote(SavingsOverview o) {
  final parts = <String>[];
  final r = o.savingsRate;
  if (r != null) parts.add(r >= 0 ? 'You kept ${percent(r)} of what came in.' : 'You spent ${percent(-r)} more than came in.');
  if (o.periods > 0) parts.add('${o.saved} of ${o.periods} ${o.periods == 1 ? 'period' : 'periods'} saved.');
  parts.add('Each bar runs from one salary to the next; the line is the 3-period average. The faded bar is still running.');
  return parts.join(' ');
}
