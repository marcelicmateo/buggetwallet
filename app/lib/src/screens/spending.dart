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
    final full = sums.sublist(0, sums.length - 1);
    final net12 = full.fold<int>(0, (a, s) => a + s.net);
    final savedMonths = full.where((s) => s.net > 0).length;

    final merch = <String, (int, int)>{};
    for (final t in wc.txs.where((t) => monthOf(t.date) == sel && t.kind == Kind.flex && t.amount < 0)) {
      final k = merchantName(t.tx);
      final (n, v) = merch[k] ?? (0, 0);
      merch[k] = (n + 1, v - t.amount);
    }
    final top = merch.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    final monthTxs = wc.txs.where((t) => monthOf(t.date) == sel && t.kind != Kind.transfer).toList();

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: gapped([
      Panel(children: [
        const Eyebrow('Saving or losing'),
        Heading(net12 >= 0 ? 'Saved ${money(net12, cur, decimals: 0)} in the last 12 months' : 'Lost ${money(-net12, cur, decimals: 0)} in the last 12 months'),
        Muted('$savedMonths of 12 months ended with more money than they started. Bars above the line are months you saved; below the line, months you spent more than came in. This month is still running.'),
        NetBarsChart(months: sums, currentMonth: current, currency: cur),
      ]),
      Panel(children: [
        const Eyebrow('Where it goes'),
        Heading('${monthLong(sel)}: ${money(selSum.out, cur, decimals: 0)} out'),
        Muted('Income ${money(selSum.income, cur, decimals: 0)}. Spending and bills by category; the dark tick is your average of the 6 months before.'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final m in months.sublist(months.length - 7))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(m == current ? '${monthShort(m)} (now)' : monthShort(m)), selected: m == sel, onSelected: (_) => setState(() => selected = m)),
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
          Rows(children: [for (final e in top.take(8)) LineItem(e.key, money(e.value.$2, cur, decimals: 0), sub: '${e.value.$1} ${e.value.$1 == 1 ? 'payment' : 'payments'}')]),
      ]),
      Panel(children: [
        Heading('All transactions in ${monthLong(sel)}', size: 15),
        const Muted('Tap one to change its category. Transfers between your own accounts are hidden.'),
        if (monthTxs.isEmpty)
          const EmptyNote('No transactions.')
        else
          Rows(children: [
            for (final t in monthTxs)
              TxTile(t: t, currency: cur, onTap: () async {
                final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                if (r != null && context.mounted) toast(context, r == 'deleted' ? 'Deleted' : 'Category saved');
              }),
          ]),
      ]),
    ]));
  }
}
