import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

class TodayScreen extends StatelessWidget {
  final WalletController wc;
  final VoidCallback openPlan;

  /// Opens the Add expense sheet (HomeShell owns it so Ctrl+N does the same); without it the button opens it itself.
  final VoidCallback? addExpense;

  /// The time of day the screen shows (tests pass a fixed one).
  final DateTime Function() clock;
  const TodayScreen({super.key, required this.wc, required this.openPlan, this.addExpense, this.clock = DateTime.now});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final over = p.safeToday < 0;
    final used = p.flexBudget > 0 ? p.spent / p.flexBudget : 1.0;
    final ahead = p.aheadOfPace;
    final newPayday = wc.newPayday(p.start);
    final now = clock();
    final deliveryHour = (now.hour >= 14 && now.hour < 19) || now.weekday == DateTime.sunday;
    final (deliveryCount, deliverySum) = wc.deliveries;
    final recent = wc.txs.where((t) => t.kind != Kind.transfer).take(12).toList();

    return MarginLine(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24),
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
              TwoCol(left: [
                Panel(padding: const EdgeInsets.fromLTRB(0, 14, 0, 14), children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    const Flexible(child: Eyebrow('Safe to spend today')),
                    const SizedBox(width: 8),
                    Flexible(child: StatusLabel(good: !over, text: over ? 'Over today' : 'On plan')),
                  ]),
                  TotalRule(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
                    child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: MoneyText(money(p.safeToday, cur, decimals: 0),
                          key: const ValueKey('safeToSpend'),
                          style: numStyle.copyWith(
                              fontSize: 78, height: 0.95, fontWeight: FontWeight.w500, letterSpacing: -3, color: over ? c.bad : c.ink)),
                    ),
                  ),
                  Muted(p.spentToday > 0
                      ? 'Spent ${money(p.spentToday, cur)} today of ${money(p.allowanceToday, cur)}. Spend less today and tomorrow gets more.'
                      : "Today's allowance is ${money(p.allowanceToday, cur)}. Spend less today and tomorrow gets more."),
                  _Stats([
                    (money(p.remaining, cur, decimals: 0), 'left until payday'),
                    ('${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}', 'to ${shortDate(p.end)}'),
                    (money(p.planDaily, cur, decimals: 0), 'plan per day'),
                  ]),
                  PaceBar(used: used, elapsed: p.elapsed, over: p.spent > p.flexBudget * p.elapsed),
                  SplitRow(
                    start: Muted('${money(p.spent, cur, decimals: 0)} of ${money(p.flexBudget, cur, decimals: 0)} used'),
                    end: ahead >= 0
                        ? Text('${money(ahead, cur, decimals: 0)} ahead of pace',
                            textAlign: TextAlign.end, style: const TextStyle(fontSize: 13))
                        : StatusLabel(good: false, text: '${money(-ahead, cur, decimals: 0)} behind pace', textAlign: TextAlign.end),
                  ),
                  Tooltip(
                    message: hasKeyboard ? 'Add expense (Ctrl+N)' : '',
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      icon: const Icon(Icons.add),
                      label: const Text('Add expense', style: TextStyle(fontSize: 16)),
                      onPressed: addExpense ?? () => addExpenseFlow(context, wc),
                    ),
                  ),
                ]),
                if (s.savedFor != p.start && wc.goals.isNotEmpty)
                  Panel(children: [
                    const HeadingRow(Heading('Payday checklist', size: 15), Tag('pay yourself first')),
                    Text('Move ${money(p.goalMonthly, cur, decimals: 0)} to your savings account before you spend anything else.',
                        style: const TextStyle(fontSize: 14)),
                    Rows(children: [
                      for (final g in wc.goals) LineItem(g.name, money(g.monthly, cur, decimals: 0), leading: const CheckSquare())
                    ]),
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
                      Expanded(
                          child: Heading(now.weekday == DateTime.sunday ? 'Sunday delivery hour' : 'After-work delivery hour', size: 15)),
                      Icon(Icons.schedule, size: 18, color: c.muted)
                    ]),
                    Text(
                      'This month: $deliveryCount ${deliveryCount == 1 ? 'order' : 'orders'}, ${money(deliverySum, cur)}. '
                      '${p.allowanceToday > 0 ? 'A typical ${money(1500, cur, decimals: 0)} order is ${(1500 / p.allowanceToday * 100).round()}% of today\'s money.' : 'Today\'s money is already used.'}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ]),
              ], right: [
                Panel(children: [
                  SplitRow(start: const Heading('Recent', size: 15), end: Muted(_freshness(wc), size: 12, align: TextAlign.end)),
                  if (recent.isEmpty)
                    const EmptyNote('No transactions yet. Import your bank exports in Plan, or add your first expense.')
                  else
                    Column(children: [
                      const TxHeaderRow(),
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
              ]),
            ])));
  }

  static String _freshness(WalletController wc) {
    final latest = wc.latestBySource;
    String last(String src) => latest[src] == null ? 'none' : shortDateOrRaw(latest[src]!);

    return 'PBZ ${last('pbz')} · Revolut ${last('revolut')}';
  }
}

List<Widget> _gap(List<Widget> xs) => [
      for (var i = 0; i < xs.length; i++) ...[if (i > 0) const SizedBox(height: 14), xs[i]],
    ];

/// Three figures in a ruled strip: a strong rule above, a hairline below, hairline dividers between. Figures are mono,
/// right-aligned, and shrink rather than overflow at large text.
class _Stats extends StatelessWidget {
  final List<(String, String)> items;
  const _Stats(this.items);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.lineStrong), bottom: BorderSide(color: c.line))),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, (value, label)) in items.indexed)
            Expanded(
              child: Container(
                decoration: BoxDecoration(border: i == 0 ? null : Border(left: BorderSide(color: c.line))),
                padding: EdgeInsets.fromLTRB(i == 0 ? 0 : 10, 9, i == items.length - 1 ? 0 : 10, 9),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(label, style: TextStyle(fontSize: 12, color: c.ink2)),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: MoneyText(value, textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: 20, fontWeight: FontWeight.w500)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
