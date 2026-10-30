import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../device_list.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../hero.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import 'review.dart' show reviewSummary, streakText;
import 'today_view.dart';

/// A small overspend is shown to the cent: "Over today by 0 €" would hide it.
String shown(int cents, String cur) => cents > 0 && cents < 10000 ? moneyExact(cents, cur) : money(cents, cur, decimals: 0);

/// The size of a typical delivery order the delivery-hour panel compares with today's money (in cents).
const typicalOrderCents = 1500;

class TodayScreen extends StatelessWidget {
  final TodayView view;
  final VoidCallback openPlan;

  /// Opens the Budget tab (the budget line); without it the line is not tappable.
  final VoidCallback? openSpending;

  /// Opens the Add expense sheet (HomeShell owns it so Ctrl+N does the same); without it the button opens it itself.
  final VoidCallback? addExpense;

  /// Opens the Bills tab (the "Due by payday" line); without it the line is not tappable.
  final VoidCallback? openBills;

  /// Opens the Bills tab at "To review" ("N bills to review"); without it the line opens Budget.
  final VoidCallback? openBillsReview;

  /// Opens Settings › Accounts ("Held: …"); without it the line opens Budget.
  final VoidCallback? openAccounts;

  /// Opens Settings › Sync (the "waiting for approval / removed" line); without it the line opens Settings.
  final VoidCallback? openSync;

  /// Opens Settings › Expected income (the expected-income line); without it the line is not tappable.
  final VoidCallback? openIncome;

  /// Opens search (the magnifier in Recent); without it the Recent panel has no search button.
  final VoidCallback? openSearch;

  /// The file chooser of the review's Import step (tests pass one that fails).
  final FileChooser chooser;

  /// The time of day the screen shows (tests pass a fixed one).
  final DateTime Function() clock;
  const TodayScreen({
    super.key,
    required this.view,
    required this.openPlan,
    this.openSpending,
    this.addExpense,
    this.openBills,
    this.openBillsReview,
    this.openAccounts,
    this.openSync,
    this.openIncome,
    this.openSearch,
    this.chooser = const FileChooser(),
    this.clock = DateTime.now,
  });

  @override
  Widget build(BuildContext context) {
    final f = _TodayFigures(view, clock());
    final p = f.p;
    final review = view.reviewState();
    final comingUp = view.comingUp();
    final held = view.heldTotals();
    final suggestions = view.suggestionCount();
    final tight = view.tightestBudget();
    final toReview = view.billsToReview();
    // The Budget tab has two pages (Spending | Plan): each link picks the one it means before the tab opens.
    void toPlan() {
      view.showBudgetView('plan');
      openPlan();
    }

    final VoidCallback? toSpending = openSpending == null
        ? null
        : () {
            view.showBudgetView('spending');
            openSpending!();
          };
    final recent =
        view.wholeTxs.where((t) => t.kind != BudgetKind.transfer || t.iou).take(12).toList(); // an IOU-linked payment shows, tagged

    return MarginLine(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: gapped([
              if (f.ended && f.newPayday == null) _PeriodEndedPanel(f),
              TwoCol(left: [
                Panel(padding: const EdgeInsets.fromLTRB(0, 14, 0, 14), children: [
                  _HeroHeader(f),
                  _HeroNumber(f),
                  _HeroSentence(f),
                  _HeroStats(f),
                  // Over the plan is said once (icon + sentence); a plan with no money in it says so.
                  if (!f.ended && p.overBudget) _OverPlanNote(f),
                  if (p.planDaily > 0) _PaceSummary(f),
                  if (p.foreignByCurrency.isNotEmpty)
                    ForeignNote(p.foreignByCurrency, key: const ValueKey('foreignNote'), onSetRate: view.openCurrencies),
                  if (tight != null) _BudgetLine(tight, view.categoryTable.label(tight.category), f.cur, toSpending),
                  if (p.expectedIncome.isNotEmpty) _ExpectedIncomeLine(f, openIncome),
                  if (p.dueCycles.isNotEmpty) _BillsLine(p.dueCycles, p.end, view.today(), f.cur, openBills, view.categoryTable),
                  if (comingUp.count > 0 || suggestions > 0) _ComingUpLine(f, comingUp, suggestions),
                  for (final n in view.plannedNeedingCategory()) _NeedsCategoryLine(f, n),
                  for (final w in view.balanceWarnings()) _BalanceWarnLine(view, w),
                  if (view.deviceStop != null) _DeviceStopLine(view.deviceStop!, view.deviceCode, openSync ?? toPlan),
                  if (held.isNotEmpty) _HeldLine(held, openAccounts ?? toPlan),
                  if (toReview > 0) _BillsToReviewLine(toReview, openBillsReview ?? toPlan),
                  for (final h in view.headsUpLines()) _HeadsUpLine(f, h),
                  if (f.reviewedToday)
                    StatusLabel(key: const ValueKey('reviewed'), good: true, text: 'Reviewed · ${streakText(review.streak)}'),
                  _AddExpenseButton(view, addExpense),
                ]),
                if (f.setupSteps.isNotEmpty)
                  _SetupPanel(view: view, steps: f.setupSteps, openPlan: toPlan, newPayday: f.newPayday, chooser: chooser),
                if (review.due) _ReviewCard(view, review, toSpending, chooser),
                if (f.s.savedFor != p.start && view.goals.isNotEmpty) _PaydayChecklist(f),
                if (f.deliveryHour) _DeliveryHourPanel(f),
              ], right: [
                _RecentPanel(view, recent, f.cur, openSearch),
              ]),
            ])));
  }

  static String _freshness(TodayView view) {
    final latest = view.latestBySource;
    String last(String src) => latest[src] == null ? 'none' : shortDateOrRaw(latest[src]!);

    return 'PBZ ${last('pbz')} · Revolut ${last('revolut')}';
  }
}

/// What Today works out once per build from the view: the numbers, the flags and the sentences its parts show.
class _TodayFigures {
  _TodayFigures(this.view, this.now)
      : s = view.settings,
        cur = view.currency,
        p = view.period() {
    final h = HeroFigure.of(p);
    ended = h.ended;
    over = h.over;
    heroLabel = h.label;
    // Over the whole period (the plan is spent) outranks over today in the sentence under the hero.
    final overPeriod = !ended && p.overBy > 0;
    // The hero number is never negative: what is left once the period ended, how far over today, else the safe amount.
    hero = h.amount;
    // The sentence under an over hero (I1). Tomorrow's allowance is null when a new pay period starts tomorrow.
    final tomorrow = p.allowanceTomorrow;
    periodSentence = overPeriod ? "You're ${shown(p.overBy, cur)} over the plan for this period." : null;
    overSentence = ended || !over || overPeriod
        ? null
        : tomorrow != null
            ? "You're ${shown(p.overToday, cur)} over for today. Nothing more today; tomorrow starts at ${money(tomorrow, cur)}."
            : "You're ${shown(p.overToday, cur)} over for today. Nothing more today; a new pay period starts tomorrow.";
    worry = over || p.overBudget;
    newPayday = view.newPayday(p.start);
    // The first-run steps (I1): one panel below the hero while any is open.
    setupSteps = [
      if (view.keyBackupRowVisible) 'key',
      if (view.setupWizardOpen) 'wizard',
      if (!s.salaryConfirmed) 'salary',
      if (newPayday != null) 'payday'
    ];
    used = p.flexBudget > 0 ? p.spent / p.flexBudget : 1.0;
    ahead = p.aheadOfPace;
    // Several missed paydays move on in one tap: the latest payday on or before today.
    newStart = currentPeriodStart(p.start, s.paydayDay, view.today());
    // Only for a wallet that ordered food in the last 90 days.
    deliveryHour = ((now.hour >= 14 && now.hour < 19) || now.weekday == DateTime.sunday) && view.deliveryOrders90 > 0;
    reviewedToday = view.lastReview == view.today() && !view.reviewState().due;
  }

  final TodayView view;
  final DateTime now;
  final WalletSettings s;
  final String cur;
  final PeriodBudget p;
  late final bool ended, over, worry, deliveryHour, reviewedToday;
  late final int hero;
  late final String heroLabel;
  late final String? periodSentence, overSentence, newPayday;
  late final List<String> setupSteps;
  late final double used;
  late final int ahead;
  late final String newStart;
}

/// "Pay period ended on …" with the button that starts the new period (hidden when a salary row already offers a new month).
class _PeriodEndedPanel extends StatelessWidget {
  const _PeriodEndedPanel(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) => Panel(key: const ValueKey('periodEndedPanel'), color: context.c.accentSoft, children: [
        Text('Pay period ended on ${shortDate(f.p.end)}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const Text('Start the new period to get a daily budget again.', style: TextStyle(fontSize: BwType.metaSize)),
        FilledButton(
            key: const ValueKey('startNewPeriod'),
            onPressed: () => f.view.startNewMonth(f.newStart),
            child: Text('Start new period on ${shortDate(f.newStart)}')),
      ]);
}

/// The hero's label and its status mark.
class _HeroHeader extends StatelessWidget {
  const _HeroHeader(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Flexible(child: Eyebrow(f.heroLabel)),
        const SizedBox(width: 8),
        Flexible(
            child: f.ended
                ? const StatusLabel(key: ValueKey('periodEnded'), good: false, text: 'Pay period ended')
                : StatusLabel(good: !f.worry, text: f.over ? 'Over today' : (f.p.overBudget ? 'Over the plan' : 'On plan'))),
      ]);
}

/// The big number, with the day dots on its right (under it when both do not fit on one row).
class _HeroNumber extends StatelessWidget {
  const _HeroNumber(this.f);
  final _TodayFigures f;

  static const double _gap = 12;

  /// The smallest share of its normal size the number is scaled to, to keep the dots beside it.
  static const double _minScale = 0.65;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final text = f.over && !f.ended ? shown(f.hero, f.cur) : money(f.hero, f.cur, decimals: 0);
    final style = numStyle.copyWith(
        fontSize: BwType.heroSize, height: 0.95, fontWeight: FontWeight.w500, letterSpacing: -3, color: f.over && !f.ended ? c.bad : c.ink);
    final number = FittedBox(
        alignment: Alignment.centerLeft, fit: BoxFit.scaleDown, child: MoneyText(text, key: const ValueKey('safeToSpend'), style: style));
    final days = f.view.periodDays();
    return TotalRule(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
      child: days.isEmpty
          ? number
          : LayoutBuilder(builder: (context, box) {
              // Beside the number whenever it can be: the number may shrink to _minScale, the squares to 11 dp. Under it only
              // when even that does not fit (320 dp at a large text scale, a huge amount).
              final natural = _naturalWidth(context, text, style);
              for (final compact in const [false, true]) {
                final grid = compact ? DayDots.compactWidth : DayDots.width;
                if (box.maxWidth - _gap - grid >= natural * _minScale) {
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Align(alignment: Alignment.centerLeft, child: number)),
                    const SizedBox(width: _gap),
                    DayDots(days: days, compact: compact),
                  ]);
                }
              }
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [number, const SizedBox(height: 10), DayDots(days: days)]);
            }),
    );
  }

  /// The number's width at full size and the current text scale (what `MoneyText` lays out).
  static double _naturalWidth(BuildContext context, String text, TextStyle style) {
    final i = text.indexOf('\u00A0');
    final size = style.fontSize ?? 14;
    final painter = TextPainter(
      text: TextSpan(
          style: style,
          children: i < 0
              ? [TextSpan(text: text)]
              : [
                  TextSpan(text: text.substring(0, i)),
                  TextSpan(text: '\u00A0', style: TextStyle(fontSize: size * 0.4)),
                  TextSpan(text: text.substring(i + 1)),
                ]),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }
}

/// The sentence under the hero number.
class _HeroSentence extends StatelessWidget {
  const _HeroSentence(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p, cur = f.cur;
    return Muted(
        f.ended
            ? (p.overBy > 0
                ? 'The pay period ended on ${shortDate(p.end)}. Spending was ${money(p.overBy, cur)} over the plan.'
                : 'The pay period ended on ${shortDate(p.end)}. Start the new period to get a daily budget again.')
            : f.overSentence ??
                (p.spentToday > 0
                    ? 'Spent ${money(p.spentToday, cur)} today of ${money(p.allowanceToday, cur)}.${p.overBudget ? '' : ' Spend less today and tomorrow gets more.'}'
                    : "Today's allowance is ${money(p.allowanceToday, cur)}.${p.overBudget ? '' : ' Spend less today and tomorrow gets more.'}"),
        key: f.overSentence == null ? null : const ValueKey('overSentence'));
  }
}

/// Left until payday, days left and plan per day.
class _HeroStats extends StatelessWidget {
  const _HeroStats(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p, cur = f.cur;
    return _Stats([
      p.overBy > 0 && !f.ended
          ? (shown(p.overBy, cur), 'over the plan')
          : (money(p.remaining > 0 ? p.remaining : 0, cur, decimals: 0), f.ended ? 'left, period over' : 'left until payday'),
      f.ended ? (shortDate(p.end), 'payday was') : ('${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}', 'to ${shortDate(p.end)}'),
      (money(p.planDaily > 0 ? p.planDaily : 0, cur, decimals: 0), 'plan per day'),
    ]);
  }
}

/// "Over the plan" said once (icon + sentence); a plan with no money in it says so.
class _OverPlanNote extends StatelessWidget {
  const _OverPlanNote(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
      key: f.periodSentence == null ? null : const ValueKey('overSentence'),
      child: StatusLabel(key: const ValueKey('overBudget'), good: false, text: f.periodSentence ?? 'The plan leaves no spending money.'));
}

/// "x of y used" and how far ahead of or behind the pace.
class _PaceSummary extends StatelessWidget {
  const _PaceSummary(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p, cur = f.cur, ahead = f.ahead;
    return SplitRow(
      start: Muted('${money(p.spent, cur, decimals: 0)} of ${money(p.flexBudget > 0 ? p.flexBudget : 0, cur, decimals: 0)} used'),
      end: ahead >= 0
          ? Text('${money(ahead, cur, decimals: 0)} ahead of pace',
              textAlign: TextAlign.end, style: const TextStyle(fontSize: BwType.metaSize))
          : StatusLabel(good: false, text: '${money(-ahead, cur, decimals: 0)} behind pace', textAlign: TextAlign.end),
    );
  }
}

/// "Expected income: … by …"; a tap opens Settings › Expected income.
class _ExpectedIncomeLine extends StatelessWidget {
  const _ExpectedIncomeLine(this.f, this.onTap);
  final _TodayFigures f;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final p = f.p;
    return _InfoLine(
        key: const ValueKey('expectedIncomeLine'),
        icon: Icons.south_west,
        text: 'Expected income: ${moneyExact(p.expectedIncome.fold<int>(0, (a, x) => a + x.amount), f.cur)} '
            'by ${shortDateOrRaw(p.expectedIncome.last.due)} (counts when it lands)',
        onTap: onTap);
  }
}

/// "Coming up: N costs before payday", or the calendar events to check; a tap opens Upcoming.
class _ComingUpLine extends StatelessWidget {
  const _ComingUpLine(this.f, this.comingUp, this.suggestions);
  final _TodayFigures f;
  final ({int count, int total}) comingUp;
  final int suggestions;
  @override
  Widget build(BuildContext context) => _InfoLine(
      key: const ValueKey('comingUpLine'),
      icon: Icons.event_outlined,
      text: comingUp.count > 0
          ? 'Coming up: ${comingUp.count} ${comingUp.count == 1 ? 'cost' : 'costs'} before payday · ${moneyExact(comingUp.total, f.cur)}'
          : 'Coming up: $suggestions calendar ${suggestions == 1 ? 'event' : 'events'} to check',
      onTap: () => _openUpcoming(context, f.view));
}

void _openUpcoming(BuildContext context, TodayView view) {
  logNav('upcoming.open');
  view.showUpcoming(context);
}

/// A planned bill that has no category yet; a tap opens the bill.
class _NeedsCategoryLine extends StatelessWidget {
  const _NeedsCategoryLine(this.f, this.n);
  final _TodayFigures f;
  final PlannedCost n;
  @override
  Widget build(BuildContext context) => _InfoLine(
      key: ValueKey('needsCategory:${n.id}'),
      icon: Icons.label_outline,
      text: '${n.title.isEmpty ? 'Bill' : n.title} · ${moneyExact(n.amount!, f.cur)} · needs a category',
      onTap: () {
        logNav('bill.needsCategory');
        f.view.showBill(context, n.sourceRef!);
      });
}

/// A red line for a bank account (Q5): below zero now, goes below zero before payday (and at which bill), or "Check your balance"
/// (the balance is not confirmed lately: the question opens). Warn style; never from a balance the app does not trust.
class _BalanceWarnLine extends StatelessWidget {
  const _BalanceWarnLine(this.view, this.w);
  final TodayView view;
  final BalanceWarning w;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final name = w.account.name;
    final cur = w.account.currency;
    final text = switch (w.kind) {
      BalanceWarningKind.belowNow => '$name is below zero now (${moneyExact(w.cents ?? 0, cur)})',
      BalanceWarningKind.goesBelow =>
        '$name goes below zero around ${shortDateOrRaw(w.date ?? '')}${(w.cause ?? '').isEmpty ? '' : ' (${w.cause})'}',
      BalanceWarningKind.checkBalance => 'Check your $name balance',
    };
    final check = w.kind == BalanceWarningKind.checkBalance;
    return Container(
      key: ValueKey('balanceWarn:${w.account.id}'),
      decoration:
          BoxDecoration(color: check ? null : c.warnBg, border: check ? null : Border(left: BorderSide(color: c.warnInk, width: 3))),
      padding: check ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        onTap: check
            ? () {
                logNav('balance.checkOpen');
                view.showBalanceCheck(context, w.account);
              }
            : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: rowMin),
          child: Row(children: [
            Icon(check ? Icons.help_outline : Icons.warning_amber_outlined, size: 18, color: check ? c.ink2 : c.warnInk),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: BwType.bodySize, color: check ? c.ink2 : c.warnInk, fontWeight: check ? null : FontWeight.w600))),
            if (check) Icon(Icons.chevron_right, size: 20, color: c.muted),
          ]),
        ),
      ),
    );
  }
}

/// "Held: …" per currency; a tap opens Settings › Accounts.
class _HeldLine extends StatelessWidget {
  const _HeldLine(this.held, this.open);
  final Map<String, int> held;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) => _InfoLine(
      key: const ValueKey('heldLine'),
      icon: Icons.account_balance_wallet_outlined,
      text: 'Held: ${held.entries.map((e) => moneyExact(e.value, e.key)).join(' · ')}',
      onTap: () {
        logNav('accounts.heldOpen');
        open();
      });
}

/// This device waits for approval or was removed from the wallet (stage DK); a tap opens Settings › Sync, where the code is.
class _DeviceStopLine extends StatelessWidget {
  const _DeviceStopLine(this.stop, this.code, this.open);
  final DeviceStop stop;
  final String? code;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) => _InfoLine(
      key: const ValueKey('deviceStopLine'),
      icon: stop == DeviceStop.pending ? Icons.hourglass_empty : Icons.block,
      text: stop == DeviceStop.pending
          ? 'Waiting for approval${code == null ? '' : ': $code'}. Tap for the QR code.'
          : 'This device was removed from the wallet.',
      onTap: () {
        logNav('devices.stopOpen', {'stop': stop.name});
        open();
      });
}

/// "N bills to review"; a tap opens the Bills tab at To review.
class _BillsToReviewLine extends StatelessWidget {
  const _BillsToReviewLine(this.count, this.open);
  final int count;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) => _InfoLine(
      key: const ValueKey('billsToReview'),
      icon: Icons.receipt_long_outlined,
      text: '$count ${count == 1 ? 'bill' : 'bills'} to review',
      onTap: () {
        logNav('bills.reviewOpen');
        open();
      });
}

/// One heads-up: a cost coming within the days you chose; a tap opens its bill or Upcoming.
class _HeadsUpLine extends StatelessWidget {
  const _HeadsUpLine(this.f, this.h);
  final _TodayFigures f;
  final HeadsUp h;
  @override
  Widget build(BuildContext context) => _InfoLine(
      key: ValueKey('headsUp:${h.item.key}'),
      icon: Icons.flag_outlined,
      text: '${h.item.title} ${h.daysLeft == 0 ? 'today' : h.daysLeft == 1 ? 'tomorrow' : 'in ${h.daysLeft} days'}'
          ' · ${moneyExact(h.item.amount!, f.cur)}'
          '${(h.item.planned?.needsCategory ?? false) ? ' · needs a category' : ''}',
      onTap: () {
        final p = h.item.planned;
        if (p != null && p.isBill) {
          f.view.showBill(context, p.sourceRef!);
        } else {
          _openUpcoming(context, f.view);
        }
      });
}

/// The big Add expense button.
class _AddExpenseButton extends StatelessWidget {
  const _AddExpenseButton(this.view, this.addExpense);
  final TodayView view;
  final VoidCallback? addExpense;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: hasKeyboard ? 'Add expense (Ctrl+N)' : '',
        child: FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
          key: const ValueKey('addExpense'),
          icon: const Icon(Icons.add),
          label: const Text('Add expense', style: TextStyle(fontSize: BwType.headingSize)),
          onPressed: addExpense ?? () => view.showAddExpense(context),
        ),
      );
}

/// The weekly review card while a review is due.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard(this.view, this.review, this.openSpending, this.chooser);
  final TodayView view;
  final ReviewState review;
  final VoidCallback? openSpending;
  final FileChooser chooser;
  @override
  Widget build(BuildContext context) => Panel(key: const ValueKey('reviewCard'), children: [
        const SectionHead('Weekly review'),
        Text(reviewSummary(review) ?? 'Nothing to fix. Import your latest files and tick it off.',
            style: const TextStyle(fontSize: BwType.bodySize)),
        FilledButton(
          key: const ValueKey('startReview'),
          onPressed: () {
            logNav('review.open');
            view.showReview(context, openSpending: openSpending, chooser: chooser);
          },
          child: const Text('Start review'),
        ),
      ]);
}

/// "Pay yourself first": move the month's savings, tick it off.
class _PaydayChecklist extends StatelessWidget {
  const _PaydayChecklist(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p, cur = f.cur, view = f.view;
    return Panel(children: [
      const HeadingRow(Heading('Payday checklist', size: BwType.headingSize), Tag('pay yourself first')),
      Text('Move ${money(p.goalMonthly, cur, decimals: 0)} to your savings account before you spend anything else.',
          style: const TextStyle(fontSize: BwType.bodySize)),
      Rows(children: [for (final g in view.goals) LineItem(g.name, money(g.monthly, cur, decimals: 0), leading: const CheckSquare())]),
      OutlinedButton.icon(
        icon: const Icon(Icons.check),
        label: Text('I moved ${money(p.goalMonthly, cur, decimals: 0)}'),
        onPressed: () {
          view.paydayDone(p.start);
          toast(context, 'Savings logged');
        },
      ),
    ]);
  }
}

/// How a typical delivery order compares with today's money, in the hours people order.
class _DeliveryHourPanel extends StatelessWidget {
  const _DeliveryHourPanel(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p, cur = f.cur;
    final (deliveryCount, deliverySum) = f.view.deliveries;
    return Panel(children: [
      Row(children: [
        Expanded(
            child:
                Heading(f.now.weekday == DateTime.sunday ? 'Sunday delivery hour' : 'After-work delivery hour', size: BwType.headingSize)),
        Icon(Icons.schedule, size: 18, color: context.c.muted)
      ]),
      Text(
        'This month: $deliveryCount ${deliveryCount == 1 ? 'order' : 'orders'}, ${money(deliverySum, cur)}. '
        '${f.ended ? 'The pay period has ended; start the new one to get a daily budget.' : p.allowanceToday > 0 ? 'A typical ${money(typicalOrderCents, cur, decimals: 0)} order is ${(typicalOrderCents / p.allowanceToday * 100).round()}% of today\'s money.' : 'Today\'s money is used up.'}',
        style: const TextStyle(fontSize: BwType.bodySize),
      ),
    ]);
  }
}

/// The latest rows, with when each bank file last brought something.
class _RecentPanel extends StatelessWidget {
  const _RecentPanel(this.view, this.recent, this.cur, this.openSearch);
  final VoidCallback? openSearch;
  final TodayView view;
  final List<CategorizedTx> recent;
  final String cur;
  @override
  Widget build(BuildContext context) => Panel(children: [
        SplitRow(
            start: Row(children: [
              const Flexible(child: Heading('Recent', size: BwType.headingSize)),
              if (openSearch != null)
                IconButton(
                    key: const ValueKey('todaySearch'),
                    tooltip: 'Search payments',
                    icon: const Icon(Icons.search),
                    onPressed: () {
                      logNav('today.search');
                      openSearch!();
                    }),
            ]),
            end: Muted(TodayScreen._freshness(view), size: BwType.metaSize, align: TextAlign.end)),
        if (recent.isEmpty)
          const EmptyNote('No transactions yet. Import your bank exports in Settings, or add your first expense.')
        else
          Column(children: [
            const TxHeaderRow(),
            for (final t in recent)
              TxTile(
                  table: view.categoryTable,
                  tagTable: view.tagTable,
                  t: view.shown(t),
                  currency: cur,
                  fxRates: view.settings.fxRates,
                  hasBill: view.billForTx(t.tx.id) != null,
                  iouTag: view.iouTagOf(t.tx.id),
                  splitCount: view.splitCount(t.tx.id),
                  splitBroken: view.splitIsBroken(t.tx.id),
                  onTap: () async {
                    await view.openTx(context, t);
                  }),
          ]),
      ]);
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
  final VoidCallback? onTap;
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
          if (onTap != null) Icon(Icons.chevron_right, size: 20, color: c.muted),
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
  final TodayView view;
  final List<String> steps;
  final VoidCallback openPlan;
  final String? newPayday;
  final FileChooser chooser;
  const _SetupPanel(
      {required this.view, required this.steps, required this.openPlan, required this.newPayday, this.chooser = const FileChooser()});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = view.settings;
    final cur = view.currency;
    if (view.setupCollapsedFor(steps)) {
      final n = steps.length;
      return Panel(color: c.warnBg, children: [
        InkWell(
          key: const ValueKey('setupLine'),
          onTap: () => view.setSetupCollapsed(false, steps),
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
        TextButton(key: const ValueKey('setupHide'), onPressed: () => view.setSetupCollapsed(true, steps), child: const Text('Hide')),
      ]),
      if (steps.contains('key')) ...[
        Row(key: const ValueKey('keyBackupRow'), children: [
          Icon(Icons.key, size: 16, color: c.warnInk),
          const SizedBox(width: 8),
          Expanded(child: Text('Save your wallet key', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk))),
        ]),
        Text('Without it, this wallet cannot be opened again.', style: TextStyle(color: c.warnInk, fontSize: BwType.metaSize)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(key: const ValueKey('keySaveNow'), onPressed: () => view.showKeyBackup(context), child: const Text('Save now')),
          TextButton(key: const ValueKey('keyRowLater'), onPressed: view.snoozeKeyBackup, child: const Text('Later')),
        ]),
      ],
      if (steps.contains('wizard')) ...[
        Row(key: const ValueKey('wizardRow'), children: [
          Icon(Icons.auto_fix_high, size: 16, color: c.warnInk),
          const SizedBox(width: 8),
          Expanded(child: Text('Finish setting up', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk))),
        ]),
        Text('Step ${view.setupWizardStep} of ${view.setupWizardStepCount}. Every step can be skipped.',
            style: TextStyle(color: c.warnInk, fontSize: BwType.metaSize)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(
              key: const ValueKey('wizardResume'), onPressed: () => view.showSetupWizard(context, chooser), child: const Text('Continue')),
          TextButton(key: const ValueKey('wizardDecline'), onPressed: view.declineSetupWizard, child: const Text('No thanks')),
        ]),
      ],
      if (steps.contains('salary')) ...[
        Text('Planning on ${money(s.salary, cur, decimals: 0)} a month', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk)),
        Text(
            s.salary > 0
                ? 'Check this matches a normal month of pay. Fix it in Budget if not.'
                : 'Enter your monthly salary in Budget so the daily budget can be worked out.',
            style: TextStyle(color: c.warnInk, fontSize: BwType.metaSize)),
        Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, runSpacing: 8, children: [
          OutlinedButton(onPressed: openPlan, child: const Text('Open Budget')),
          FilledButton(onPressed: () => view.updateSettings({'salaryConfirmed': true}), child: const Text('Looks right')),
        ]),
      ],
      if (steps.contains('payday') && newPayday != null) ...[
        Text('Salary landed on ${shortDate(newPayday!)}', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk)),
        Text('Start a new month to reset your daily budget and run the payday checklist.',
            style: TextStyle(fontSize: BwType.metaSize, color: c.warnInk)),
        FilledButton(onPressed: () => view.startNewMonth(newPayday!), child: Text('Start new month on ${shortDate(newPayday!)}')),
      ],
    ]);
  }
}
