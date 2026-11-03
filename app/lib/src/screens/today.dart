import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

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
import 'needs_you.dart';
import 'overview.dart';
import 'review.dart' show streakText;
import 'today_view.dart';

/// "N things need you": the one attention tile; it opens the Needs-you page.
class _NeedsYouTile extends StatelessWidget {
  const _NeedsYouTile(this.count, this.onTap);
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => StatTile(
      key: const ValueKey('needsYouTile'),
      attention: true,
      label: 'Needs you',
      value: '$count',
      sub: count == 1 ? 'thing needs you' : 'things need you',
      onTap: onTap);
}

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

  /// Opens Settings › Accounts (the Held tile); without it the tile opens Budget.
  final VoidCallback? openAccounts;

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
    this.openAccounts,
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
    // From needsYouPaneMin the shell stands the queue beside the page (main.dart), so the tile would repeat it.
    final pane = width >= needsYouPaneMin;
    final twoCol = width >= 1280 && (hasFound || hasPins || hasGoal);
    final wide = sizeFor(width) == LayoutSize.expanded && !twoCol;
    final recent = view.wholeTxs.where((t) => t.kind != BudgetKind.transfer || t.iou).take(wide ? 8 : 3).toList();
    final today = view.today();
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

    final needs = view.needsYouCount();
    final VoidCallback explore = toSpending ?? openSearch ?? () {};
    final header = OverviewHeader(
      eyebrow: overviewEyebrow(today, p),
      needsYou: needs,
      onPeriod: () => view.showPeriodReport(context),
      onNeedsYou: () => openNeedsYou(context, view.controller, chooser: chooser),
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
      // The queue: everything that needs the owner is one tile here (the cards are on the Needs-you page and, from 1280 dp, its pane).
      if (needs > 0 && !pane)
        DashItem(span: 2, child: _NeedsYouTile(needs, () => openNeedsYou(context, view.controller, chooser: chooser))),
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
    used = p.flexBudget > 0 ? p.spent / p.flexBudget : 1.0;
    ahead = p.aheadOfPace;
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
  late final double used;
  late final int ahead;
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
