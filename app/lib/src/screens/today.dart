import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'key_backup.dart';
import 'review.dart';
import 'upcoming.dart';

class TodayScreen extends StatelessWidget {
  final WalletController wc;
  final VoidCallback openPlan;

  /// Opens the Spending tab (the budget line); without it the line is not tappable.
  final VoidCallback? openSpending;

  /// Opens the Add expense sheet (HomeShell owns it so Ctrl+N does the same); without it the button opens it itself.
  final VoidCallback? addExpense;

  /// Opens Plan at "Expected bills" (the "Due by payday" line); without it the line is not tappable.
  final VoidCallback? openBills;

  /// Opens Plan › Bills at "To review" ("N bills to review"); without it the line opens Plan.
  final VoidCallback? openBillsReview;

  /// The file chooser of the review's Import step (tests pass one that fails).
  final FileChooser chooser;

  /// The time of day the screen shows (tests pass a fixed one).
  final DateTime Function() clock;
  const TodayScreen({
    super.key,
    required this.wc,
    required this.openPlan,
    this.openSpending,
    this.addExpense,
    this.openBills,
    this.openBillsReview,
    this.chooser = const FileChooser(),
    this.clock = DateTime.now,
  });

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
    final tight = wc.tightestBudget();
    final review = wc.reviewState();
    final reviewedToday = wc.lastReview == wc.today() && !review.due;
    final comingUp = wc.comingUp();
    final suggestions = wc.suggestionCount();
    final headsUps = wc.headsUpLines();
    final toReview = wc.billsToReview();
    void upcoming() {
      logNav('upcoming.open');
      openUpcoming(context, wc);
    }

    final recent = wc.txs.where((t) => t.kind != Kind.transfer).take(12).toList();

    return MarginLine(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24),
            children: _gap([
              if (wc.keyBackupRowVisible) KeyBackupRow(wc: wc),
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
                  if (tight != null) _BudgetLine(tight, cur, openSpending),
                  if (p.dueBills.isNotEmpty) _BillsLine(p.dueBills, p.reservedBills, wc.today(), cur, openBills),
                  if (comingUp.count > 0 || suggestions > 0)
                    _InfoLine(
                        key: const ValueKey('comingUpLine'),
                        icon: Icons.event_outlined,
                        text: comingUp.count > 0
                            ? 'Coming up: ${comingUp.count} ${comingUp.count == 1 ? 'cost' : 'costs'} before payday · ${moneyExact(comingUp.total, cur)}'
                            : 'Coming up: $suggestions calendar ${suggestions == 1 ? 'event' : 'events'} to check',
                        onTap: upcoming),
                  if (toReview > 0)
                    _InfoLine(
                        key: const ValueKey('billsToReview'),
                        icon: Icons.receipt_long_outlined,
                        text: '$toReview ${toReview == 1 ? 'bill' : 'bills'} to review',
                        onTap: () {
                          logNav('bills.reviewOpen');
                          (openBillsReview ?? openPlan)();
                        }),
                  for (final h in headsUps)
                    _InfoLine(
                        key: ValueKey('headsUp:${h.item.key}'),
                        icon: Icons.flag_outlined,
                        text: '${h.item.title} ${h.daysLeft == 0 ? 'today' : h.daysLeft == 1 ? 'tomorrow' : 'in ${h.daysLeft} days'}'
                            ' · ${moneyExact(h.item.amount!, cur)}',
                        onTap: upcoming),
                  if (reviewedToday)
                    StatusLabel(key: const ValueKey('reviewed'), good: true, text: 'Reviewed · ${streakText(review.streak)}'),
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
                if (review.due)
                  Panel(key: const ValueKey('reviewCard'), children: [
                    const SectionHead('Weekly review'),
                    Text(reviewSummary(review) ?? 'Nothing to fix. Import your latest files and tick it off.',
                        style: const TextStyle(fontSize: 14)),
                    FilledButton(
                      onPressed: () {
                        logNav('review.open');
                        openReview(context, wc, openSpending: openSpending, chooser: chooser);
                      },
                      child: const Text('Start review'),
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
                            hasBill: wc.billForTx(t.tx.id) != null,
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

/// "Groceries: 48 € left this month" for the budgeted category with the least left (`bad` with an icon when over); a tap opens
/// Spending.
class _BudgetLine extends StatelessWidget {
  final CategoryBudgetLine line;
  final String currency;
  final VoidCallback? onTap;
  const _BudgetLine(this.line, this.currency, this.onTap);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final over = line.over;
    final text = over
        ? '${line.category}: ${leftText(line.remaining ?? 0, currency)}'
        : '${line.category}: ${leftText(line.remaining ?? 0, currency)} this month';
    final col = over ? c.bad : c.ink2;
    return InkWell(
      key: const ValueKey('budgetLine'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(children: [
          Icon(over ? Icons.error_outline : Icons.pie_chart_outline, size: 18, color: col),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: col, fontWeight: over ? FontWeight.w600 : FontWeight.w400))),
          if (onTap != null) Icon(Icons.chevron_right, size: 20, color: c.muted),
        ]),
      ),
    );
  }
}

/// "Due by payday: 3 bills, 182.40 €": confirmed bills expected before the next payday; a tap opens Plan › Expected bills.
/// Bills the plan already counts (rent, loan, subscriptions) are named apart and are not in the sum; an unpaid bill past its
/// date says "overdue" (it stays reserved).
class _BillsLine extends StatelessWidget {
  final List<RecurringBill> bills;
  final int reserved;
  final String today, currency;
  final VoidCallback? onTap;
  const _BillsLine(this.bills, this.reserved, this.today, this.currency, this.onTap);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final counted = bills.where((b) => !b.coveredByPlan).length;
    final covered = bills.length - counted;
    final overdue = bills.where((b) => b.nextDue.compareTo(today) < 0).length;
    final text = 'Due by payday: ${[
      if (counted > 0) '$counted ${counted == 1 ? 'bill' : 'bills'}, ${moneyExact(reserved, currency)}',
      if (covered > 0) '$covered covered by your plan',
    ].join(' · ')}';
    return InkWell(
      key: const ValueKey('billsLine'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(children: [
          Icon(Icons.event_note_outlined, size: 18, color: c.ink2),
          const SizedBox(width: 8),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: TextStyle(fontSize: 14, color: c.ink2)),
            if (overdue > 0) StatusLabel(key: const ValueKey('billsOverdue'), good: false, text: '$overdue overdue'),
          ])),
          if (onTap != null) Icon(Icons.chevron_right, size: 20, color: c.muted),
        ]),
      ),
    );
  }
}

/// One tappable line with an icon: "Coming up: 3 costs before payday · 182.40 €" and the heads-up lines.
class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  const _InfoLine({super.key, required this.icon, required this.text, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(children: [
          Icon(icon, size: 18, color: c.ink2),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: c.ink2))),
          Icon(Icons.chevron_right, size: 20, color: c.muted),
        ]),
      ),
    );
  }
}

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
