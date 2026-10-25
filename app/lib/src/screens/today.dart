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
import 'bill_sheet.dart';
import 'key_backup.dart';
import 'review.dart';
import 'upcoming.dart';

/// A small overspend is shown to the cent: "Over today by 0 €" would hide it.
String shown(int cents, String cur) => cents > 0 && cents < 10000 ? moneyExact(cents, cur) : money(cents, cur, decimals: 0);

/// The size of a typical delivery order the delivery-hour panel compares with today's money (in cents).
const typicalOrderCents = 1500;

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

  /// Opens Plan › Accounts ("Held: …"); without it the line opens Plan.
  final VoidCallback? openAccounts;

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
    this.openAccounts,
    this.chooser = const FileChooser(),
    this.clock = DateTime.now,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final ended = p.paydayPassed;
    final over = p.overToday > 0;
    // Over the whole period (the plan is spent) outranks over today in the sentence under the hero.
    final overPeriod = !ended && p.overBy > 0;
    // The hero number is never negative: what is left once the period ended, how far over today, else the safe amount.
    final hero = ended ? (p.remaining > 0 ? p.remaining : 0) : (over ? p.overToday : p.safeToday);
    // The sentence under an over hero (I1). Tomorrow's allowance is null when a new pay period starts tomorrow.
    final tomorrow = p.allowanceTomorrow;
    final periodSentence = overPeriod ? "You're ${shown(p.overBy, cur)} over the plan for this period." : null;
    final overSentence = ended || !over || overPeriod
        ? null
        : tomorrow != null
            ? "You're ${shown(p.overToday, cur)} over for today. Nothing more today; tomorrow starts at ${money(tomorrow, cur)}."
            : "You're ${shown(p.overToday, cur)} over for today. Nothing more today; a new pay period starts tomorrow.";
    final worry = over || p.overBudget;
    final newPayday = wc.newPayday(p.start);
    // The first-run steps (I1): one panel below the hero while any is open.
    final setupSteps = [if (wc.keyBackupRowVisible) 'key', if (!s.salaryConfirmed) 'salary', if (newPayday != null) 'payday'];
    final used = p.flexBudget > 0 ? p.spent / p.flexBudget : 1.0;
    final ahead = p.aheadOfPace;
    // Several missed paydays move on in one tap: the latest payday on or before today.
    final newStart = currentPeriodStart(p.start, s.paydayDay, wc.today());
    final now = clock();
    // Only for a wallet that ordered food in the last 90 days.
    final deliveryHour = ((now.hour >= 14 && now.hour < 19) || now.weekday == DateTime.sunday) && wc.deliveryOrders90 > 0;
    final (deliveryCount, deliverySum) = wc.deliveries;
    final tight = wc.tightestBudget();
    final review = wc.reviewState();
    final reviewedToday = wc.lastReview == wc.today() && !review.due;
    final comingUp = wc.comingUp();
    final held = wc.heldTotals();
    final suggestions = wc.suggestionCount();
    final headsUps = wc.headsUpLines();
    final needCategory = wc.plannedNeedingCategory();
    final toReview = wc.billsToReview();
    void upcoming() {
      logNav('upcoming.open');
      openUpcoming(context, wc);
    }

    final recent = wc.wholeTxs.where((t) => t.kind != BudgetKind.transfer).take(12).toList();

    return MarginLine(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: gapped([
              if (ended && newPayday == null)
                Panel(key: const ValueKey('periodEndedPanel'), color: c.accentSoft, children: [
                  Text('Pay period ended on ${shortDate(p.end)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Text('Start the new period to get a daily budget again.', style: TextStyle(fontSize: BwType.metaSize)),
                  FilledButton(
                      key: const ValueKey('startNewPeriod'),
                      onPressed: () => wc.startNewMonth(newStart),
                      child: Text('Start new period on ${shortDate(newStart)}')),
                ]),
              TwoCol(left: [
                Panel(padding: const EdgeInsets.fromLTRB(0, 14, 0, 14), children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Flexible(child: Eyebrow(ended ? 'Left this pay period' : (over ? 'Over today by' : 'Safe to spend today'))),
                    const SizedBox(width: 8),
                    Flexible(
                        child: ended
                            ? const StatusLabel(key: ValueKey('periodEnded'), good: false, text: 'Pay period ended')
                            : StatusLabel(good: !worry, text: over ? 'Over today' : (p.overBudget ? 'Over the plan' : 'On plan'))),
                  ]),
                  TotalRule(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
                    child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: MoneyText((over && !ended ? shown(hero, cur) : money(hero, cur, decimals: 0)),
                          key: const ValueKey('safeToSpend'),
                          style: numStyle.copyWith(
                              fontSize: BwType.heroSize,
                              height: 0.95,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -3,
                              color: over && !ended ? c.bad : c.ink)),
                    ),
                  ),
                  Muted(
                      ended
                          ? (p.overBy > 0
                              ? 'The pay period ended on ${shortDate(p.end)}. Spending was ${money(p.overBy, cur)} over the plan.'
                              : 'The pay period ended on ${shortDate(p.end)}. Start the new period to get a daily budget again.')
                          : overSentence ??
                              (p.spentToday > 0
                                  ? 'Spent ${money(p.spentToday, cur)} today of ${money(p.allowanceToday, cur)}.${p.overBudget ? '' : ' Spend less today and tomorrow gets more.'}'
                                  : "Today's allowance is ${money(p.allowanceToday, cur)}.${p.overBudget ? '' : ' Spend less today and tomorrow gets more.'}"),
                      key: overSentence == null ? null : const ValueKey('overSentence')),
                  _Stats([
                    p.overBy > 0 && !ended
                        ? (shown(p.overBy, cur), 'over the plan')
                        : (money(p.remaining > 0 ? p.remaining : 0, cur, decimals: 0), ended ? 'left, period over' : 'left until payday'),
                    ended
                        ? (shortDate(p.end), 'payday was')
                        : ('${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}', 'to ${shortDate(p.end)}'),
                    (money(p.planDaily > 0 ? p.planDaily : 0, cur, decimals: 0), 'plan per day'),
                  ]),
                  // Over the plan is said once (icon + sentence); a plan with no money in it says so.
                  if (!ended && p.overBudget)
                    KeyedSubtree(
                        key: periodSentence == null ? null : const ValueKey('overSentence'),
                        child: StatusLabel(
                            key: const ValueKey('overBudget'), good: false, text: periodSentence ?? 'The plan leaves no spending money.')),
                  if (p.planDaily > 0) PaceBar(used: used, elapsed: p.elapsed, over: p.spent > p.flexBudget * p.elapsed),
                  if (p.planDaily > 0)
                    SplitRow(
                      start: Muted(
                          '${money(p.spent, cur, decimals: 0)} of ${money(p.flexBudget > 0 ? p.flexBudget : 0, cur, decimals: 0)} used'),
                      end: ahead >= 0
                          ? Text('${money(ahead, cur, decimals: 0)} ahead of pace',
                              textAlign: TextAlign.end, style: const TextStyle(fontSize: BwType.metaSize))
                          : StatusLabel(good: false, text: '${money(-ahead, cur, decimals: 0)} behind pace', textAlign: TextAlign.end),
                    ),
                  if (p.foreignByCurrency.isNotEmpty) ForeignNote(p.foreignByCurrency, key: const ValueKey('foreignNote')),
                  if (tight != null) _BudgetLine(tight, wc.categoryTable.label(tight.category), cur, openSpending),
                  if (p.expectedIncome.isNotEmpty)
                    _InfoLine(
                        key: const ValueKey('expectedIncomeLine'),
                        icon: Icons.south_west,
                        text: 'Expected income: ${moneyExact(p.expectedIncome.fold<int>(0, (a, x) => a + x.amount), cur)} '
                            'by ${shortDateOrRaw(p.expectedIncome.last.due)} (counts when it lands)',
                        onTap: openBills ?? () {}),
                  if (p.dueCycles.isNotEmpty) _BillsLine(p.dueCycles, p.end, wc.today(), cur, openBills, wc.categoryTable),
                  if (comingUp.count > 0 || suggestions > 0)
                    _InfoLine(
                        key: const ValueKey('comingUpLine'),
                        icon: Icons.event_outlined,
                        text: comingUp.count > 0
                            ? 'Coming up: ${comingUp.count} ${comingUp.count == 1 ? 'cost' : 'costs'} before payday · ${moneyExact(comingUp.total, cur)}'
                            : 'Coming up: $suggestions calendar ${suggestions == 1 ? 'event' : 'events'} to check',
                        onTap: upcoming),
                  for (final n in needCategory)
                    _InfoLine(
                        key: ValueKey('needsCategory:${n.id}'),
                        icon: Icons.label_outline,
                        text: '${n.title.isEmpty ? 'Bill' : n.title} · ${moneyExact(n.amount!, cur)} · needs a category',
                        onTap: () {
                          logNav('bill.needsCategory');
                          openBill(context, wc, n.sourceRef!);
                        }),
                  if (held.isNotEmpty)
                    _InfoLine(
                        key: const ValueKey('heldLine'),
                        icon: Icons.account_balance_wallet_outlined,
                        text: 'Held: ${held.entries.map((e) => moneyExact(e.value, e.key)).join(' · ')}',
                        onTap: () {
                          logNav('accounts.heldOpen');
                          (openAccounts ?? openPlan)();
                        }),
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
                            ' · ${moneyExact(h.item.amount!, cur)}'
                            '${(h.item.planned?.needsCategory ?? false) ? ' · needs a category' : ''}',
                        onTap: () {
                          final p = h.item.planned;
                          if (p != null && p.isBill) {
                            openBill(context, wc, p.sourceRef!);
                          } else {
                            upcoming();
                          }
                        }),
                  if (reviewedToday)
                    StatusLabel(key: const ValueKey('reviewed'), good: true, text: 'Reviewed · ${streakText(review.streak)}'),
                  Tooltip(
                    message: hasKeyboard ? 'Add expense (Ctrl+N)' : '',
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
                      key: const ValueKey('addExpense'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add expense', style: TextStyle(fontSize: BwType.headingSize)),
                      onPressed: addExpense ?? () => addExpenseFlow(context, wc),
                    ),
                  ),
                ]),
                if (setupSteps.isNotEmpty) _SetupPanel(wc: wc, steps: setupSteps, openPlan: openPlan, newPayday: newPayday),
                if (review.due)
                  Panel(key: const ValueKey('reviewCard'), children: [
                    const SectionHead('Weekly review'),
                    Text(reviewSummary(review) ?? 'Nothing to fix. Import your latest files and tick it off.',
                        style: const TextStyle(fontSize: BwType.bodySize)),
                    FilledButton(
                      key: const ValueKey('startReview'),
                      onPressed: () {
                        logNav('review.open');
                        openReview(context, wc, openSpending: openSpending, chooser: chooser);
                      },
                      child: const Text('Start review'),
                    ),
                  ]),
                if (s.savedFor != p.start && wc.goals.isNotEmpty)
                  Panel(children: [
                    const HeadingRow(Heading('Payday checklist', size: BwType.headingSize), Tag('pay yourself first')),
                    Text('Move ${money(p.goalMonthly, cur, decimals: 0)} to your savings account before you spend anything else.',
                        style: const TextStyle(fontSize: BwType.bodySize)),
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
                          child: Heading(now.weekday == DateTime.sunday ? 'Sunday delivery hour' : 'After-work delivery hour',
                              size: BwType.headingSize)),
                      Icon(Icons.schedule, size: 18, color: c.muted)
                    ]),
                    Text(
                      'This month: $deliveryCount ${deliveryCount == 1 ? 'order' : 'orders'}, ${money(deliverySum, cur)}. '
                      '${ended ? 'The pay period has ended; start the new one to get a daily budget.' : p.allowanceToday > 0 ? 'A typical ${money(typicalOrderCents, cur, decimals: 0)} order is ${(typicalOrderCents / p.allowanceToday * 100).round()}% of today\'s money.' : 'Today\'s money is used up.'}',
                      style: const TextStyle(fontSize: BwType.bodySize),
                    ),
                  ]),
              ], right: [
                Panel(children: [
                  SplitRow(
                      start: const Heading('Recent', size: BwType.headingSize),
                      end: Muted(_freshness(wc), size: BwType.metaSize, align: TextAlign.end)),
                  if (recent.isEmpty)
                    const EmptyNote('No transactions yet. Import your bank exports in Plan, or add your first expense.')
                  else
                    Column(children: [
                      const TxHeaderRow(),
                      for (final t in recent)
                        TxTile(
                            table: wc.categoryTable,
                            tagTable: wc.tagTable,
                            t: t,
                            currency: cur,
                            hasBill: wc.billForTx(t.tx.id) != null,
                            splitCount: wc.splitCount(t.tx.id),
                            splitBroken: wc.splitIsBroken(t.tx.id),
                            onTap: () async {
                              final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                              if (context.mounted) txSheetToast(context, wc, r);
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

/// "Groceries: 48 € left this month" for the budgeted category with the least left (`bad` with an icon when over); a tap opens
/// Spending.
class _BudgetLine extends StatelessWidget {
  final CategoryBudgetLine line;
  final String name, currency;
  final VoidCallback? onTap;
  const _BudgetLine(this.line, this.name, this.currency, this.onTap);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final over = line.over;
    final text =
        over ? '$name: ${leftText(line.remaining ?? 0, currency)}' : '$name: ${leftText(line.remaining ?? 0, currency)} this month';
    final col = over ? c.bad : c.ink2;
    return InkWell(
      key: const ValueKey('budgetLine'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: rowMin),
        child: Row(children: [
          Icon(over ? Icons.error_outline : Icons.pie_chart_outline, size: 18, color: col),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: BwType.bodySize, color: col, fontWeight: over ? FontWeight.w600 : FontWeight.w400))),
          if (onTap != null) Icon(Icons.chevron_right, size: 20, color: c.muted),
        ]),
      ),
    );
  }
}

/// "Due by payday: 3 bills, 182.40 €": confirmed bills expected before the next payday; a tap opens Plan › Expected bills.
/// Bills the plan already counts (rent, loan, subscriptions) are named apart and are not in the sum; an unpaid bill past its
/// date says "overdue" (it stays reserved). A weekly bill counts each payment of the period ("1 bill (4 payments)"). A bill that
/// comes less often than monthly and is due after payday is held in full: "Car insurance 600 € held until paid".
class _BillsLine extends StatelessWidget {
  final List<DueCycle> cycles;
  final String end, today, currency;
  final VoidCallback? onTap;
  final CategoryTable table;
  const _BillsLine(this.cycles, this.end, this.today, this.currency, this.onTap, this.table);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    bool held(DueCycle x) => x.bill.isLong && x.due.compareTo(end) >= 0;
    final soon = [
      for (final x in cycles)
        if (!held(x)) x
    ];
    final heldCycles = [
      for (final x in cycles)
        if (held(x) && x.reserve > 0) x
    ];
    final counted = [
      for (final x in soon)
        if (!x.coveredIn(table)) x
    ];
    final countedBills = {for (final x in counted) x.bill.id}.length;
    final coveredBills = {
      for (final x in soon)
        if (x.coveredIn(table)) x.bill.id
    }.length;
    final reserved = counted.fold<int>(0, (s, x) => s + x.reserve);
    final overdue = {
      for (final x in cycles)
        if (x.due.compareTo(today) < 0) x.bill.id
    }.length;
    final payments = counted.length > countedBills ? ' (${counted.length} payments)' : '';
    final text = [
      if (countedBills > 0) '$countedBills ${countedBills == 1 ? 'bill' : 'bills'}$payments, ${moneyExact(reserved, currency)}',
      if (coveredBills > 0) '$coveredBills covered by your plan',
    ].join(' · ');
    if (text.isEmpty && heldCycles.isEmpty && overdue == 0) return const SizedBox.shrink();
    final style = TextStyle(fontSize: BwType.bodySize, color: c.ink2);
    return InkWell(
      key: const ValueKey('billsLine'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: rowMin),
        child: Row(children: [
          Icon(Icons.event_note_outlined, size: 18, color: c.ink2),
          const SizedBox(width: 8),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (text.isNotEmpty) Text('Due by payday: $text', style: style),
            for (final x in heldCycles)
              Text('${x.bill.label.isNotEmpty ? x.bill.label : x.bill.payee} ${moneyExact(x.reserve, currency)} held until paid',
                  key: ValueKey('billHeld:${x.bill.id}'), style: style),
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
        constraints: const BoxConstraints(minHeight: rowMin),
        child: Row(children: [
          Icon(icon, size: 18, color: c.ink2),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: BwType.bodySize, color: c.ink2))),
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
                  Text(label, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: MoneyText(value,
                        textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.amountMdSize, fontWeight: FontWeight.w500)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The first-run steps in one panel under the hero (I1): save the key, confirm the salary, start a new month. After the owner
/// hides it once it is a single line (`setupLine`) that opens it again.
class _SetupPanel extends StatelessWidget {
  final WalletController wc;
  final List<String> steps;
  final VoidCallback openPlan;
  final String? newPayday;
  const _SetupPanel({required this.wc, required this.steps, required this.openPlan, required this.newPayday});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = wc.settings;
    final cur = wc.currency;
    if (wc.setupCollapsedFor(steps)) {
      final n = steps.length;
      return Panel(color: c.warnBg, children: [
        InkWell(
          key: const ValueKey('setupLine'),
          onTap: () => wc.setSetupCollapsed(false, steps),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(children: [
              Icon(Icons.checklist, size: 18, color: c.warnInk),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('$n ${n == 1 ? 'step' : 'steps'} left to set up',
                      style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk))),
              Icon(Icons.expand_more, color: c.warnInk),
            ]),
          ),
        ),
      ]);
    }
    return Panel(key: const ValueKey('setupPanel'), color: c.warnBg, children: [
      Row(children: [
        Icon(Icons.checklist, size: 18, color: c.warnInk),
        const SizedBox(width: 8),
        Expanded(child: Text('Set up your wallet', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk))),
        TextButton(key: const ValueKey('setupHide'), onPressed: () => wc.setSetupCollapsed(true, steps), child: const Text('Hide')),
      ]),
      if (steps.contains('key')) ...[
        Row(key: const ValueKey('keyBackupRow'), children: [
          Icon(Icons.key, size: 16, color: c.warnInk),
          const SizedBox(width: 8),
          Expanded(child: Text('Save your wallet key', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk))),
        ]),
        Text('Without it, this wallet cannot be opened again.', style: TextStyle(color: c.warnInk, fontSize: BwType.metaSize)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(key: const ValueKey('keySaveNow'), onPressed: () => openKeyBackup(context, wc), child: const Text('Save now')),
          TextButton(key: const ValueKey('keyRowLater'), onPressed: wc.snoozeKeyBackup, child: const Text('Later')),
        ]),
      ],
      if (steps.contains('salary')) ...[
        Text('Planning on ${money(s.salary, cur, decimals: 0)} a month', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk)),
        Text(
            s.salary > 0
                ? 'Check this matches a normal month of pay. Fix it in Plan if not.'
                : 'Enter your monthly salary in Plan so the daily budget can be worked out.',
            style: TextStyle(color: c.warnInk, fontSize: BwType.metaSize)),
        Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: openPlan, child: const Text('Open Plan')),
          FilledButton(onPressed: () => wc.updateSettings({'salaryConfirmed': true}), child: const Text('Looks right')),
        ]),
      ],
      if (steps.contains('payday') && newPayday != null) ...[
        Text('Salary landed on ${shortDate(newPayday!)}', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk)),
        Text('Start a new month to reset your daily budget and run the payday checklist.',
            style: TextStyle(fontSize: BwType.metaSize, color: c.warnInk)),
        FilledButton(onPressed: () => wc.startNewMonth(newPayday!), child: Text('Start new month on ${shortDate(newPayday!)}')),
      ],
    ]);
  }
}
