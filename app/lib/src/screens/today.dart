import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

class TodayScreen extends StatelessWidget {
  final WalletController wc;
  final VoidCallback openPlan;
  const TodayScreen({super.key, required this.wc, required this.openPlan});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final today = wc.today();
    final over = p.safeToday < 0;
    final used = p.flexBudget > 0 ? p.spent / p.flexBudget : 1.0;
    final ahead = p.aheadOfPace;
    final newPayday = wc.newPayday(p.start);
    final now = DateTime.now();
    final deliveryHour = (now.hour >= 14 && now.hour < 19) || now.weekday == DateTime.sunday;
    final month = monthOf(today);
    final deliveries = wc.txs.where((t) => t.category == 'Food delivery' && monthOf(t.date) == month && t.amount < 0).toList();
    final deliverySum = -deliveries.fold<int>(0, (a, t) => a + t.amount);
    final recent = wc.txs.where((t) => t.kind != Kind.transfer).take(12).toList();

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: _gap([
          if (!s.salaryConfirmed)
            Panel(color: c.warnBg, children: [
              Text('Planning on ${money(s.salary, cur, decimals: 0)} a month',
                  style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk)),
              Text(
                  s.salary > 0
                      ? 'Check this matches a normal month of pay. Fix it in Plan if not.'
                      : 'Enter your monthly salary in Plan so the daily budget can be worked out.',
                  style: TextStyle(color: c.warnInk, fontSize: 13)),
              Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, runSpacing: 8, children: [
                OutlinedButton(onPressed: openPlan, child: const Text('Open Plan')),
                TextButton(onPressed: () => wc.updateSettings({'salaryConfirmed': true}), child: const Text('Looks right')),
              ]),
            ]),
          if (newPayday != null)
            Panel(color: c.accentSoft, children: [
              Text('Salary landed on ${shortDate(newPayday)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Text('Start a new month to reset your daily budget and run the payday checklist.', style: TextStyle(fontSize: 13)),
              FilledButton(onPressed: () => wc.startNewMonth(newPayday), child: Text('Start new month on ${shortDate(newPayday)}')),
            ]),
          Panel(padding: const EdgeInsets.fromLTRB(18, 20, 18, 18), children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Flexible(child: Eyebrow('Safe to spend today')),
              const SizedBox(width: 8),
              Flexible(child: StatusLabel(good: !over, text: over ? 'Over today' : 'On plan')),
            ]),
            FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(money(p.safeToday, cur, decimals: 0),
                  style: TextStyle(fontSize: 68, height: 1, fontWeight: FontWeight.w800, letterSpacing: -2, color: over ? c.bad : c.ink)),
            ),
            Muted(p.spentToday > 0
                ? 'Spent ${money(p.spentToday, cur)} today of ${money(p.allowanceToday, cur)}. Spend less today and tomorrow gets more.'
                : "Today's allowance is ${money(p.allowanceToday, cur)}. Spend less today and tomorrow gets more."),
            Row(children: [
              _Stat(money(p.remaining, cur, decimals: 0), 'left until payday'),
              _Stat('${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}', 'to ${shortDate(p.end)}'),
              _Stat(money(p.planDaily, cur, decimals: 0), 'plan per day'),
            ]),
            PaceBar(used: used, elapsed: p.elapsed, over: p.spent > p.flexBudget * p.elapsed),
            SplitRow(
              start: Muted('${money(p.spent, cur, decimals: 0)} of ${money(p.flexBudget, cur, decimals: 0)} used'),
              end: ahead >= 0
                  ? Text('${money(ahead, cur, decimals: 0)} ahead of pace', textAlign: TextAlign.end, style: const TextStyle(fontSize: 13))
                  : StatusLabel(good: false, text: '${money(-ahead, cur, decimals: 0)} behind pace', textAlign: TextAlign.end),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.add),
              label: const Text('Add expense', style: TextStyle(fontSize: 16)),
              onPressed: () async {
                final r = await showSheet<String>(context, AddExpenseSheet(wc: wc));
                if (!context.mounted) return;
                if (r == 'added') toast(context, 'Expense added');
                if (r == 'wish') toast(context, 'On the wishlist. Decide in ${s.coolHours} hours.');
              },
            ),
          ]),
          if (s.savedFor != p.start && wc.goals.isNotEmpty)
            Panel(children: [
              const HeadingRow(Heading('Payday checklist', size: 15), Tag('pay yourself first')),
              Text('Move ${money(p.goalMonthly, cur, decimals: 0)} to your savings account before you spend anything else.',
                  style: const TextStyle(fontSize: 14)),
              Rows(children: [for (final g in wc.goals) LineItem(g.name, money(g.monthly, cur, decimals: 0))]),
              OutlinedButton.icon(
                icon: const Icon(Icons.check),
                label: Text('I moved ${money(p.goalMonthly, cur, decimals: 0)}'),
                onPressed: () {
                  wc.paydayDone(p.start);
                  toast(context, 'Savings logged');
                },
              ),
            ]),
          if (deliveryHour)
            Panel(children: [
              Row(children: [
                Expanded(child: Heading(now.weekday == DateTime.sunday ? 'Sunday delivery hour' : 'After-work delivery hour', size: 15)),
                Icon(Icons.schedule, size: 18, color: c.muted)
              ]),
              Text(
                'This month: ${deliveries.length} ${deliveries.length == 1 ? 'order' : 'orders'}, ${money(deliverySum, cur)}. '
                '${p.allowanceToday > 0 ? 'A typical €15 order is ${(1500 / p.allowanceToday * 100).round()}% of today\'s money.' : 'Today\'s money is already used.'}',
                style: const TextStyle(fontSize: 14),
              ),
            ]),
          Panel(children: [
            SplitRow(start: const Heading('Recent', size: 15), end: Muted(_freshness(wc), size: 12, align: TextAlign.end)),
            if (recent.isEmpty)
              const EmptyNote('No transactions yet. Import your bank exports in Plan, or add your first expense.')
            else
              Rows(children: [
                for (final t in recent)
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

  static String _freshness(WalletController wc) {
    String last(String src) {
      final t = wc.txs.where((x) => x.tx.source == src).firstOrNull;
      return t == null ? 'none' : shortDate(t.date);
    }

    return 'PBZ ${last('pbz')} · Revolut ${last('revolut')}';
  }
}

List<Widget> _gap(List<Widget> xs) => [
      for (var i = 0; i < xs.length; i++) ...[if (i > 0) const SizedBox(height: 14), xs[i]],
    ];

class _Stat extends StatelessWidget {
  final String value, label;
  const _Stat(this.value, this.label);
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: numStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w500)),
          Text(label, style: TextStyle(fontSize: 12, color: context.c.muted)),
        ]),
      );
}
