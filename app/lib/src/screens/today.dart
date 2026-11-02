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
import '../widgets/dash.dart';
import 'overview.dart';
import 'review.dart' show reviewSummary, streakText;
import 'today_view.dart';

/// The size of a typical delivery order the delivery-hour panel compares with today's money (in cents).
const typicalOrderCents = 1500;

/// Today as a Paper Tiles dashboard (RX3, `docs/design/dashboard/CONCEPT.md` §5): one [DashGrid] of tiles on the desk. The hero
/// (safe to spend today, exact cents, a state chip, the day dots, the pace meter) spans two columns (2×2 on a wide window); then what
/// needs the owner (period ended, first-run steps, device stop, balance warnings, a category to give, bills to review, heads-ups, the
/// weekly review), then one number per tile (Left, Payday, Before payday, the tightest budget, Held, Review streak), then Add expense
/// and the last payments. Each tile says one thing and opens where the old line opened; the sentences are gone.
class TodayScreen extends StatelessWidget {
  final TodayView view;
  final VoidCallback openPlan;

  /// Opens the Budget tab (the tightest budget tile); without it the tile is not tappable.
  final VoidCallback? openSpending;

  /// Opens the Add expense sheet (HomeShell owns it so Ctrl+N does the same); without it the button opens it itself.
  final VoidCallback? addExpense;

  /// Opens the Bills tab (the overdue bills tile); without it the tile is not tappable.
  final VoidCallback? openBills;

  /// Opens the Bills tab at "To review"; without it the tile opens Budget.
  final VoidCallback? openBillsReview;

  /// Opens Settings › Accounts (the Held tile); without it the tile opens Budget.
  final VoidCallback? openAccounts;

  /// Opens Settings › Sync (the "waiting for approval / removed" tile); without it the tile opens Settings.
  final VoidCallback? openSync;

  /// Opens Budget › Plan › Expected income (the income due tile); without it the tile is not tappable.
  final VoidCallback? openIncome;

  /// Opens search (the magnifier in Recent); without it the Recent tile has no search button.
  final VoidCallback? openSearch;

  /// The file chooser of the review's Import step (tests pass one that fails).
  final FileChooser chooser;

  /// The time of day the screen shows (tests pass a fixed one). Null = the wallet's clock (`wc.now`, so a pinned test clock moves Today too).
  final DateTime Function()? clock;
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
    this.clock,
  });

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<bool>(valueListenable: view.hoursMode, builder: (context, _, __) => _content(context));

  Widget _content(BuildContext context) {
    final f = _TodayFigures(view, clock?.call() ?? view.now);
    final p = f.p;
    final review = view.reviewState();
    final held = view.heldTotals();
    final suggestions = view.suggestionCount();
    final tight = view.tightestBudget();
    final toReview = view.billsToReview();
    // Plan and Explore each have two pages: each link picks the one it means before the page opens.
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
    final width = MediaQuery.sizeOf(context).width;
    final hasFound = view.foundCards().isNotEmpty, hasPins = view.pins().isNotEmpty, hasGoal = view.nearestGoal() != null;
    // From 1280 dp, with something to put in it, two columns (safe to spend and held | found and pinned); the Needs-you pane comes with E7.
    final twoCol = width >= 1280 && (hasFound || hasPins || hasGoal);
    final wide = sizeFor(width) == LayoutSize.expanded && !twoCol;
    final recent = view.wholeTxs.where((t) => t.kind != BudgetKind.transfer || t.iou).take(wide ? 8 : 3).toList();
    final today = view.today();
    final overdue = {
      for (final x in p.dueCycles)
        if (x.due.compareTo(today) < 0) x.bill.id
    }.length;

    // UX-B B4: the number tiles by id; null = nothing to show.
    final numberTiles = <String, Widget?>{
      'left': f.ended ? null : _LeftTile(f),
      'payday': f.ended ? null : _PaydayTile(f),
      'before': p.beforePaydayCount > 0 || p.beforePayday > 0
          ? _BeforePaydayTile(f, () => _openUpcoming(context, view))
          : suggestions > 0
              ? _CalendarCheckTile(suggestions, () => _openUpcoming(context, view))
              : null,
      'budget': tight == null ? null : _BudgetTile(tight, view.categoryTable.label(tight.category), f.cur, toSpending, view.amount),
      'held': held.isEmpty ? null : _HeldTile(held, f.cur, openAccounts ?? toPlan, view.amount),
      'income': p.expectedIncome.isEmpty ? null : _IncomeDueTile(f, openIncome),
      'reviewed': f.reviewTile ? _ReviewTile(f, review) : null,
      // On four columns both take the whole row: a two-cell button beside a tall list left the cells under it empty (RX8).
      'add': DashItem(span: wide ? 4 : 2, child: _AddExpenseButton(view, addExpense)),
      'recent': DashItem(span: wide ? 4 : 2, child: _RecentTile(view, recent, f.cur, openSearch)),
    };
    final (:order, :hidden) = view.tiles;

    final needs =
        toReview + view.plannedNeedingCategory().length + view.balanceWarnings().length + (overdue > 0 ? 1 : 0) + (review.due ? 1 : 0);
    final VoidCallback explore = toSpending ?? openSearch ?? () {};
    final header = OverviewHeader(
      eyebrow: overviewEyebrow(today, p),
      needsYou: needs,
      onPeriod: () => view.showPeriodReport(context),
      onNeedsYou: () {
        if (toReview > 0) {
          (openBillsReview ?? toPlan)();
        } else if (review.due) {
          view.showReview(context, openSpending: toSpending, chooser: chooser);
        } else if (overdue > 0 && openBills != null) {
          openBills!();
        } else {
          toast(context, 'Nothing needs you now');
        }
      },
    );
    void openFound() => view.showFindings(context, openExplore: explore);
    final found = FoundSection(view: view, onOpen: openFound);
    final pinned = PinnedSection(view: view, onExplore: explore);
    final goal = GoalBar(
        view: view,
        onOpen: () {
          view.showSaving();
          openPlan();
        });
    final heroItems = <Widget>[
      // A wide window: the hero is one short row across the whole grid (a 2x2 hero left a block of empty paper, UX-A).
      DashItem(span: wide ? 4 : 2, rowSpan: 1, child: _Hero(f, wide: wide)),
      // What needs the owner first.
      if (f.ended && f.newPayday == null) DashItem(span: 2, child: _PeriodEndedTile(f)),
      if (f.setupSteps.isNotEmpty)
        DashItem(span: 2, child: _SetupTile(view: view, steps: f.setupSteps, openPlan: toPlan, newPayday: f.newPayday, chooser: chooser)),
      if (view.deviceStop != null) _DeviceStopTile(view.deviceStop!, view.deviceCode, openSync ?? toPlan),
      for (final w in view.balanceWarnings()) _BalanceWarnTile(view, w),
      for (final n in view.plannedNeedingCategory()) _NeedsCategoryTile(f, n),
      if (toReview > 0) _BillsToReviewTile(toReview, openBillsReview ?? toPlan),
      if (overdue > 0) _OverdueTile(overdue, openBills),
      for (final h in view.headsUpLines()) _HeadsUpTile(f, h),
      if (review.due) DashItem(span: 2, child: _ReviewCard(view, review, toSpending, chooser)),
      if (f.deliveryHour) DashItem(span: 2, child: _DeliveryHourPanel(f)),
      // Not hideable: without it the owner would not know some spending is left out.
      if (p.foreignByCurrency.isNotEmpty)
        DashItem(span: 2, child: ForeignNote(p.foreignByCurrency, key: const ValueKey('foreignNote'), onSetRate: view.openCurrencies)),
    ];
    // The numbers: the owner's choice and order (Settings > Look); a tile still shows only when it has something to say.
    final numbers = <Widget>[
      for (final id in order)
        if (!hidden.contains(id) && numberTiles[id] != null) numberTiles[id]!,
    ];
    const gap = SizedBox(height: 14);
    final right = <Widget>[
      if (hasFound) found,
      if (hasPins) pinned,
      if (hasGoal) goal,
    ];
    Widget stack(List<Widget> parts) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(parts, gap: 14));

    final Widget body;
    if (twoCol) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: stack([
          DashGrid(children: [...heroItems, ...numbers])
        ])),
        const SizedBox(width: 20),
        Expanded(child: stack(right)),
      ]);
    } else {
      // Spec §5.1 order: hero and attention tiles, found, pinned, goal, then the number tiles (two grids: an odd attention tile leaves a gap).
      body = stack([
        DashGrid(fillRows: wide && right.isEmpty, children: heroItems),
        ...right,
        if (numbers.isNotEmpty) DashGrid(fillRows: wide, children: numbers),
      ]);
    }

    return ColoredBox(
      color: context.c.desk,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad),
        children: [header, gap, body],
      ),
    );
  }

  static String _freshness(TodayView view) {
    final latest = view.latestBySource;
    String last(String src) => latest[src] == null ? 'none' : shortDateOrRaw(latest[src]!);

    return 'PBZ ${last('pbz')} · Revolut ${last('revolut')}';
  }
}

/// What Today works out once per build from the view: the numbers and the flags its tiles show.
class _TodayFigures {
  _TodayFigures(this.view, this.now)
      : s = view.settings,
        cur = view.currency,
        p = view.period() {
    final h = HeroFigure.of(p);
    ended = h.ended;
    over = h.over;
    heroLabel = h.label;
    // The hero number is never negative: what is left once the period ended, how far over today, else the safe amount.
    hero = h.amount;
    overPeriod = !ended && p.overBy > 0;
    newPayday = view.newPayday(p.start);
    // The first-run steps (I1): one tile below the hero while any is open.
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
    final r = view.reviewState();
    reviewedToday = view.lastReview == view.today() && !r.due;
    reviewTile = !r.due && (reviewedToday || r.streak > 0);
  }

  final TodayView view;
  final DateTime now;
  final WalletSettings s;
  final String cur;
  final PeriodBudget p;
  late final bool ended, over, overPeriod, deliveryHour, reviewedToday, reviewTile;
  late final int hero;
  late final String heroLabel;
  late final String? newPayday;
  late final List<String> setupSteps;
  late final double used;
  late final int ahead;
  late final String newStart;
}

/// A chip that carries a key (the tests and the screen find a state by it) and says what the chip inside it says.
class _KeyedChip extends DashChip {
  const _KeyedChip({required Key key, required this.chip}) : super(key: key);
  final DashChip chip;
  @override
  String get spoken => chip.spoken;
  @override
  Widget build(BuildContext context) => chip;
}

void _openUpcoming(BuildContext context, TodayView view) {
  logNav('upcoming.open');
  view.showUpcoming(context);
}

/// The hero: the safe amount to the cent, one state chip (said once), the day dots and the pace meter.
class _Hero extends StatelessWidget {
  const _Hero(this.f, {this.wide = false});
  final _TodayFigures f;
  final bool wide;

  DashChip _chip() {
    final p = f.p, cur = f.cur;
    if (f.ended) return const StateChip.over(key: ValueKey('periodEnded'), text: 'Pay period ended');
    if (f.overPeriod) {
      return _KeyedChip(
          key: const ValueKey('overBudget'),
          chip: _KeyedChip(key: const ValueKey('overSentence'), chip: StateChip.over(text: '${f.view.amount(p.overBy, cur)} over plan')));
    }
    if (f.over) return const _KeyedChip(key: ValueKey('overSentence'), chip: StateChip.over(text: 'Nothing more today'));
    if (p.overBudget) return const _KeyedChip(key: ValueKey('overBudget'), chip: StateChip.over(text: 'No money in plan'));
    return f.ahead >= 0 ? const StateChip.onPace() : const StateChip.over(text: 'Behind pace');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = f.p, cur = f.cur;
    final days = f.view.periodDays();
    final pace = !f.ended && p.planDaily > 0;
    final tomorrow = p.allowanceTomorrow;
    final String? sub = f.ended
        ? (p.overBy > 0 ? '${f.view.amount(p.overBy, cur)} over plan' : null)
        : f.over
            // Over the whole plan there is nothing to promise for tomorrow.
            ? (f.overPeriod ? null : (tomorrow != null ? 'Tomorrow ${f.view.amount(tomorrow, cur)}' : 'New period tomorrow'))
            : pace
                // Spent of the flexible budget, then "Tomorrow X · pace ▲ N ahead" (spec §5.1) while on plan; over plan the chip's
                // "X over plan" is the only word (never both).
                ? '${f.view.amount(p.spent, cur)} of ${f.view.amount(p.flexBudget > 0 ? p.flexBudget : 0, cur)}${f.overPeriod || p.overBudget ? '' : '\n${[
                    if (tomorrow != null) 'Tomorrow ${f.view.amount(tomorrow, cur)}',
                    'pace ${f.ahead >= 0 ? '▲ ${f.view.amount(f.ahead, cur)} ahead' : '▼ ${f.view.amount(-f.ahead, cur)} behind'}',
                  ].join(' · ')}'}'
                : null;
    final ahead = f.ahead;
    return HeroTile(
      key: const ValueKey('heroTile'),
      wide: wide,
      valueKey: const ValueKey('safeToSpend'),
      label: f.heroLabel,
      value: f.view.amount(f.hero, cur),
      valueColor: f.over && !f.ended ? c.bad : null,
      trailing: f.view.hoursAvailable
          ? HoursSwitch(
              hours: f.view.showHours,
              symbol: currencySymbol(cur),
              currencyName: currencyInfo(cur)?.name ?? cur,
              onChanged: f.view.setShowHours)
          : null,
      sub: sub,
      chip: _chip(),
      dots: days.isEmpty ? null : DayDots(days: days),
      dotsCompact: days.isEmpty ? null : DayDots(days: days, compact: true),
      dotsWidth: DayDots.width,
      dotsCompactWidth: DayDots.compactWidth,
      dotsSpoken: days.isEmpty ? null : DayDots.label(days),
      paceUsed: pace ? f.used : null,
      paceExpected: pace ? p.elapsed : null,
      paceOver: pace && (ahead < 0 || p.overBy > 0),
      paceSpoken: pace ? (ahead >= 0 ? '${f.view.amount(ahead, cur)} ahead of pace' : '${f.view.amount(-ahead, cur)} behind pace') : null,
    );
  }
}

/// The button that starts the new pay period (hidden when a salary row already offers a new month).
class _PeriodEndedTile extends StatelessWidget {
  const _PeriodEndedTile(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) => Tile(
      key: const ValueKey('periodEndedPanel'),
      attention: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const TileLabel('New pay period'),
        const SizedBox(height: 8),
        FilledButton(
            key: const ValueKey('startNewPeriod'),
            onPressed: () => f.view.startNewMonth(f.newStart),
            child: Text('Start new period on ${shortDate(f.newStart)}')),
      ]));
}

/// Left until payday and the plan per day.
class _LeftTile extends StatelessWidget {
  const _LeftTile(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p;
    return StatTile(
        key: const ValueKey('leftTile'),
        label: 'Left',
        value: f.view.amount(p.remaining > 0 ? p.remaining : 0, f.cur),
        sub: p.planDaily > 0 && !f.ended ? '${f.view.amount(p.planDaily, f.cur)} a day' : null);
  }
}

/// Days to payday with the share of the period gone as a ring.
class _PaydayTile extends StatelessWidget {
  const _PaydayTile(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p;
    return RingTile(
        key: const ValueKey('paydayTile'),
        label: 'Payday',
        trailing: TileNote(shortDate(p.end)),
        compact: true,
        progress: p.elapsed,
        center: '',
        value: '${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}');
  }
}

/// What bills and planned costs hold back until payday (core's `beforePayday`); a tap opens the list with dates.
class _BeforePaydayTile extends StatelessWidget {
  const _BeforePaydayTile(this.f, this.onTap);
  final _TodayFigures f;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final n = f.p.beforePaydayCount;
    return StatTile(
        key: const ValueKey('comingUpLine'),
        label: 'Before payday',
        value: f.view.amount(f.p.beforePayday, f.cur),
        sub: n > 0 ? '$n ${n == 1 ? 'cost' : 'costs'}' : null,
        onTap: onTap);
  }
}

/// Calendar events with no amount, when there is nothing else before payday.
class _CalendarCheckTile extends StatelessWidget {
  const _CalendarCheckTile(this.count, this.onTap);
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => StatTile(
      key: const ValueKey('comingUpLine'),
      label: 'To check',
      value: '$count',
      sub: 'calendar ${count == 1 ? 'event' : 'events'}',
      onTap: onTap);
}

/// The budgeted category with the least left this month, as a ring (used share); `bad` with a word when over; a tap opens Spending.
class _BudgetTile extends StatelessWidget {
  final CategoryBudgetLine line;
  final String name, currency;
  final VoidCallback? onTap;
  final String Function(int, String) amt;
  const _BudgetTile(this.line, this.name, this.currency, this.onTap, this.amt);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final over = line.over;
    final left = line.remaining ?? 0;
    final b = line.budget ?? 0;
    final used = b > 0 ? (line.actual / b).clamp(0.0, 1.0) : 1.0;
    return RingTile(
        key: const ValueKey('budgetLine'),
        label: name,
        compact: true,
        progress: used,
        color: over ? c.bad : null,
        center: '',
        value: amt(over ? -left : left, currency),
        sub: over ? null : 'left',
        chip: over ? const StateChip.over(text: 'Over budget') : null,
        onTap: onTap);
  }
}

/// Money in accounts (per currency; the wallet's own first); a tap opens Settings › Accounts.
class _HeldTile extends StatelessWidget {
  final String Function(int, String) amt;
  const _HeldTile(this.held, this.cur, this.open, this.amt);
  final Map<String, int> held;
  final String cur;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) {
    final codes = held.keys.toList()..sort((a, b) => a == cur ? -1 : (b == cur ? 1 : a.compareTo(b)));
    final first = codes.first;
    return StatTile(
        key: const ValueKey('heldLine'),
        label: 'Held',
        value: amt(held[first]!, first),
        sub: codes.length > 1 ? codes.skip(1).map((k) => amt(held[k]!, k)).join(' · ') : null,
        onTap: () {
          logNav('accounts.heldOpen');
          open();
        });
  }
}

/// Income that is expected before payday; it counts when it lands. A tap opens Budget › Plan › Expected income.
class _IncomeDueTile extends StatelessWidget {
  const _IncomeDueTile(this.f, this.onTap);
  final _TodayFigures f;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final p = f.p;
    return StatTile(
        key: const ValueKey('expectedIncomeLine'),
        label: 'Income due',
        value: f.view.amount(p.expectedIncome.fold<int>(0, (a, x) => a + x.amount), f.cur),
        chip: StateChip.date(shortDateOrRaw(p.expectedIncome.last.due)),
        onTap: onTap);
  }
}

/// The review streak, or the next review day.
class _ReviewTile extends StatelessWidget {
  const _ReviewTile(this.f, this.review);
  final _TodayFigures f;
  final ReviewState review;
  @override
  Widget build(BuildContext context) => StatTile(
      key: const ValueKey('reviewed'),
      label: 'Review',
      value: '${review.streak}',
      sub: streakText(review.streak).replaceFirst('${review.streak} ', ''),
      chip: f.reviewedToday ? const StateChip.onPace(text: 'Reviewed') : StateChip.date(shortDateOrRaw(review.nextReviewDate)));
}

/// A planned bill that has no category yet; a tap opens the bill.
class _NeedsCategoryTile extends StatelessWidget {
  const _NeedsCategoryTile(this.f, this.n);
  final _TodayFigures f;
  final PlannedCost n;
  @override
  Widget build(BuildContext context) => StatTile(
      key: ValueKey('needsCategory:${n.id}'),
      attention: true,
      label: n.title.isEmpty ? 'Bill' : n.title,
      value: f.view.amount(n.amount!, f.cur),
      chip: const StateChip.over(text: 'Needs a category'),
      onTap: () {
        logNav('bill.needsCategory');
        f.view.showBill(context, n.sourceRef!);
      });
}

/// A bank account (Q5): below zero now, goes below zero before payday (and at which bill), or "check your balance" (the balance is
/// not confirmed lately: the question opens). Never from a balance the app does not trust.
class _BalanceWarnTile extends StatelessWidget {
  const _BalanceWarnTile(this.view, this.w);
  final TodayView view;
  final BalanceWarning w;
  @override
  Widget build(BuildContext context) {
    final name = w.account.name;
    final cur = w.account.currency;
    final key = ValueKey('balanceWarn:${w.account.id}');
    return switch (w.kind) {
      BalanceWarningKind.belowNow => StatTile(
          key: key,
          attention: true,
          label: name,
          value: view.amount(w.cents ?? 0, cur),
          valueColor: context.c.bad,
          chip: const StateChip.over(text: 'Below zero')),
      BalanceWarningKind.goesBelow => StatTile(
          key: key,
          attention: true,
          label: name,
          value: shortDateOrRaw(w.date ?? ''),
          sub: (w.cause ?? '').isEmpty ? null : w.cause,
          chip: const StateChip.over(text: 'Goes below zero')),
      BalanceWarningKind.checkBalance => StatTile(
          key: key,
          label: name,
          value: 'Check',
          sub: 'Balance not confirmed lately',
          onTap: () {
            logNav('balance.checkOpen');
            view.showBalanceCheck(context, w.account);
          }),
    };
  }
}

/// This device waits for approval or was removed from the wallet (stage DK); a tap opens Settings › Sync, where the code is.
class _DeviceStopTile extends StatelessWidget {
  const _DeviceStopTile(this.stop, this.code, this.open);
  final DeviceStop stop;
  final String? code;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) {
    final pending = stop == DeviceStop.pending;
    return StatTile(
        key: const ValueKey('deviceStopLine'),
        attention: true,
        label: 'This device',
        value: pending ? 'Waiting' : 'Removed',
        sub: pending && code != null ? 'Code $code' : null,
        chip: pending ? const StateChip.date('Needs approval') : const StateChip.over(text: 'No access'),
        onTap: () {
          logNav('devices.stopOpen', {'stop': stop.name});
          open();
        });
  }
}

/// "N bills to review"; a tap opens the Bills tab at To review.
class _BillsToReviewTile extends StatelessWidget {
  const _BillsToReviewTile(this.count, this.open);
  final int count;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) => StatTile(
      key: const ValueKey('billsToReview'),
      attention: true,
      label: 'To review',
      value: '$count',
      sub: count == 1 ? 'bill' : 'bills',
      onTap: () {
        logNav('bills.reviewOpen');
        open();
      });
}

/// Bills past their date and not paid; a tap opens the Bills tab.
class _OverdueTile extends StatelessWidget {
  const _OverdueTile(this.count, this.open);
  final int count;
  final VoidCallback? open;
  @override
  Widget build(BuildContext context) => StatTile(
      key: const ValueKey('billsLine'),
      attention: true,
      label: 'Bills',
      value: '$count',
      chip: const StateChip.over(key: ValueKey('billsOverdue'), text: 'Overdue'),
      onTap: open);
}

/// One heads-up: a cost coming within the days you chose; a tap opens its bill or Upcoming.
class _HeadsUpTile extends StatelessWidget {
  const _HeadsUpTile(this.f, this.h);
  final _TodayFigures f;
  final HeadsUp h;
  @override
  Widget build(BuildContext context) => StatTile(
      key: ValueKey('headsUp:${h.item.key}'),
      label: h.item.title,
      value: f.view.amount(h.item.amount!, f.cur),
      sub: (h.item.planned?.needsCategory ?? false) ? 'Needs a category' : null,
      chip: StateChip.date(h.daysLeft == 0
          ? 'Today'
          : h.daysLeft == 1
              ? 'Tomorrow'
              : 'In ${h.daysLeft} days'),
      onTap: () {
        final p = h.item.planned;
        if (p != null && p.isBill) {
          f.view.showBill(context, p.sourceRef!);
        } else {
          _openUpcoming(context, f.view);
        }
      });
}

/// The Add expense button (thumb reach, after the numbers).
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

/// The weekly review while one is due.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard(this.view, this.review, this.openSpending, this.chooser);
  final TodayView view;
  final ReviewState review;
  final VoidCallback? openSpending;
  final FileChooser chooser;
  @override
  Widget build(BuildContext context) => Tile(
      key: const ValueKey('reviewCard'),
      attention: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Text('Weekly review', style: TextStyle(fontWeight: FontWeight.w600, fontSize: BwType.headingSize)),
        const SizedBox(height: 6),
        Text(reviewSummary(review) ?? 'Nothing to fix. Import your latest files and tick it off.',
            style: const TextStyle(fontSize: BwType.bodySize)),
        const SizedBox(height: 10),
        FilledButton(
          key: const ValueKey('startReview'),
          onPressed: () {
            logNav('review.open');
            view.showReview(context, openSpending: openSpending, chooser: chooser);
          },
          child: const Text('Start review'),
        ),
      ]));
}

/// How a typical delivery order compares with today's money, in the hours people order.
class _DeliveryHourPanel extends StatelessWidget {
  const _DeliveryHourPanel(this.f);
  final _TodayFigures f;
  @override
  Widget build(BuildContext context) {
    final p = f.p, cur = f.cur;
    final (deliveryCount, deliverySum) = f.view.deliveries;
    return Tile(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
            child:
                Heading(f.now.weekday == DateTime.sunday ? 'Sunday delivery hour' : 'After-work delivery hour', size: BwType.headingSize)),
        Icon(Icons.schedule, size: 18, color: context.c.muted)
      ]),
      const SizedBox(height: 6),
      Text(
        'This month: $deliveryCount ${deliveryCount == 1 ? 'order' : 'orders'}, ${f.view.amount(deliverySum, cur)}. '
        '${f.ended ? 'The pay period has ended; start the new one to get a daily budget.' : p.allowanceToday > 0 ? 'A typical ${f.view.amount(typicalOrderCents, cur)} order is ${(typicalOrderCents / p.allowanceToday * 100).round()}% of today\'s money.' : 'Today\'s money is used up.'}',
        style: const TextStyle(fontSize: BwType.bodySize),
      ),
    ]));
  }
}

/// The latest payments (3 on a phone, 8 on a wide window), with when each bank file last brought something.
class _RecentTile extends StatelessWidget {
  const _RecentTile(this.view, this.recent, this.cur, this.openSearch);
  final VoidCallback? openSearch;
  final TodayView view;
  final List<CategorizedTx> recent;
  final String cur;
  @override
  Widget build(BuildContext context) => Tile(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        SplitRow(
            start: Row(children: [
              const Flexible(child: TileLabel('Recent')),
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
                  amountOf: view.showHours ? view.amount : null,
                  fxRates: view.settings.fxRates,
                  hasBill: view.billForTx(t.tx.id) != null,
                  matched: view.isMatchedBank(t.tx.id),
                  iouTag: view.iouTagOf(t.tx.id),
                  splitCount: view.splitCount(t.tx.id),
                  splitBroken: view.splitIsBroken(t.tx.id),
                  onTap: () async {
                    await view.openTx(context, t);
                  }),
          ]),
      ]));
}

/// The first-run steps in one tile under the hero (I1): save the key, finish the wizard, confirm the salary, start a new month.
/// After the owner hides it once it is a single line (`setupLine`) that opens it again.
class _SetupTile extends StatelessWidget {
  final TodayView view;
  final List<String> steps;
  final VoidCallback openPlan;
  final String? newPayday;
  final FileChooser chooser;
  const _SetupTile(
      {required this.view, required this.steps, required this.openPlan, required this.newPayday, this.chooser = const FileChooser()});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = view.settings;
    final cur = view.currency;
    if (view.setupCollapsedFor(steps)) {
      final n = steps.length;
      return Tile(
        key: const ValueKey('setupLine'),
        attention: true,
        onTap: () => view.setSetupCollapsed(false, steps),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(children: [
            Icon(Icons.checklist, size: 18, color: c.accent),
            const SizedBox(width: 8),
            Expanded(child: Text('$n ${n == 1 ? 'step' : 'steps'} left to set up', style: const TextStyle(fontWeight: FontWeight.w600))),
            const Icon(Icons.expand_more),
          ]),
        ),
      );
    }
    const bold = TextStyle(fontWeight: FontWeight.w600);
    final meta = TextStyle(color: c.ink2, fontSize: BwType.metaSize);
    return Tile(
        key: const ValueKey('setupPanel'),
        attention: true,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: gapped([
              Row(children: [
                Icon(Icons.checklist, size: 18, color: c.accent),
                const SizedBox(width: 8),
                const Expanded(child: Text('Set up your wallet', style: bold)),
                TextButton(
                    key: const ValueKey('setupHide'), onPressed: () => view.setSetupCollapsed(true, steps), child: const Text('Hide')),
              ]),
              if (steps.contains('key'))
                Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: gapped([
                      Row(key: const ValueKey('keyBackupRow'), children: [
                        Icon(Icons.key, size: 16, color: c.accent),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('Save your wallet key', style: bold)),
                      ]),
                      Text('Without it, this wallet cannot be opened again.', style: meta),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton(
                            key: const ValueKey('keySaveNow'), onPressed: () => view.showKeyBackup(context), child: const Text('Save now')),
                        TextButton(key: const ValueKey('keyRowLater'), onPressed: view.snoozeKeyBackup, child: const Text('Later')),
                      ]),
                    ], gap: 6)),
              if (steps.contains('wizard'))
                Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: gapped([
                      Row(key: const ValueKey('wizardRow'), children: [
                        Icon(Icons.auto_fix_high, size: 16, color: c.accent),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('Finish setting up', style: bold)),
                      ]),
                      Text('Step ${view.setupWizardStep} of ${view.setupWizardStepCount}. Every step can be skipped.', style: meta),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton(
                            key: const ValueKey('wizardResume'),
                            onPressed: () => view.showSetupWizard(context, chooser),
                            child: const Text('Continue')),
                        TextButton(
                            key: const ValueKey('wizardDecline'), onPressed: view.declineSetupWizard, child: const Text('No thanks')),
                      ]),
                    ], gap: 6)),
              if (steps.contains('salary'))
                Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: gapped([
                      Text('Planning on ${view.amount(s.salary, cur)} a month', style: bold),
                      Text(
                          s.salary > 0
                              ? 'Check this matches a normal month of pay. Fix it in Plan if not.'
                              : 'Enter your monthly salary in Plan so the daily budget can be worked out.',
                          style: meta),
                      Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, runSpacing: 8, children: [
                        OutlinedButton(onPressed: openPlan, child: const Text('Open Plan')),
                        FilledButton(onPressed: () => view.updateSettings({'salaryConfirmed': true}), child: const Text('Looks right')),
                      ]),
                    ], gap: 6)),
              if (steps.contains('payday') && newPayday != null)
                Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: gapped([
                      Text('Salary landed on ${shortDate(newPayday!)}', style: bold),
                      Text('Start a new month to reset your daily budget and run the payday checklist.', style: meta),
                      FilledButton(
                          onPressed: () => view.startNewMonth(newPayday!), child: Text('Start new month on ${shortDate(newPayday!)}')),
                    ], gap: 6)),
            ], gap: 12)));
  }
}
