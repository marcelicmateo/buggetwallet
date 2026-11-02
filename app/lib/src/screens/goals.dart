import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';
import 'goal_new.dart';
import 'goal_planner.dart';
import 'save.dart';

/// Whole percent of [target] that is [saved], rounded down so 100 means reached; 0 without a target, never below 0 or above 100.
/// Integer maths: a double gives 28 for 290 of 1000.
int goalPercent(int saved, int target) => target <= 0 ? 0 : (saved.clamp(0, target) * 100) ~/ target;

/// Save tab › Goals (RX6): the total as one tile with a bar, a compact ring tile per goal (a tap opens its sheet), "+ Goal", and the
/// money that came in above plan. Exact cents everywhere; a ring is a display ratio of two core amounts.
class GoalsScreen extends StatelessWidget {
  final WalletController wc;

  /// On the Save tab the panels sit in that tab's scroll: no list or margin of their own.
  final bool embedded;
  const GoalsScreen({super.key, required this.wc, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cur = wc.currency;
    final p = wc.period();
    final extraAbove = p.aboveSalary;
    final tot = goalTotals(wc.goals);

    String eta(Goal g) {
      if (g.target <= 0) return 'No target';
      final n = monthsToGoal(g);
      if (n == null) return 'Set a monthly amount';
      if (n == 0) return 'Reached';
      final end = parseIso(p.end);
      final d = DateTime.utc(end.year, end.month + n - 1, 15);
      return 'by ${monthYear(d.year, d.month)}';
    }

    // The share of the target, 0..1 (ring and bar fill only); the shown percent is [goalPercent] (integer maths).
    double share(int saved, int target) => target > 0 ? (saved / target).clamp(0.0, 1.0) : 0.0;

    Widget goal(Goal g) {
      final f = share(g.saved, g.target);
      final reached = g.target > 0 && g.saved >= g.target;
      return RingTile(
        key: ValueKey('goal:${g.id}'),
        label: g.name,
        center: '', // the percent sits in the sub line: 12 dp text, not 11
        value: moneyExact(g.saved, cur),
        progress: f,
        color: c.s3,
        compact: true,
        // A reached goal says so once, in the chip.
        sub: g.target > 0 ? '${goalPercent(g.saved, g.target)}% of ${moneyExact(g.target, cur)}${reached ? '' : '\n${eta(g)}'}' : eta(g),
        chip: g.saved < 0
            ? const StateChip.over(text: 'Below zero')
            : g.boughtAt != null
                ? const StateChip.onPace(text: 'Bought')
                : g.price != null && wc.goalReady(g)
                    ? const StateChip.onPace(text: 'Ready to buy')
                    : reached
                        ? const StateChip.onPace(text: 'Reached')
                        : null,
        onTap: () async {
          if (g.price != null) return openGoalPlanner(context, wc, g.id);
          final r = await showSheet<String>(context, GoalSheet(wc: wc, goal: g));
          if (context.mounted) goalSheetToast(context, wc, r);
        },
      );
    }

    final hasBar = tot.count > 0 && tot.target > 0;
    final grid = DashGrid(children: [
      DashItem(
        span: 2,
        child: StatTile(
          key: const ValueKey('goalsTotal'),
          label: 'Put aside',
          value: moneyExact(tot.saved, cur),
          trailing: p.goalMonthly > 0 ? TileNote('${moneyExact(p.goalMonthly, cur)} this pay period') : null,
          sub: hasBar ? 'of ${moneyExact(tot.target, cur)}' : (tot.count == 0 ? 'No goals yet' : null),
          visual: hasBar ? _TotalBar(share(tot.saved, tot.target), c.s3) : null,
          visualSpoken: hasBar ? '${goalPercent(tot.saved, tot.target)} percent of the target' : null,
        ),
      ),
      if (extraAbove > 0)
        StatTile(
            key: const ValueKey('goalsAbovePlan'), label: 'Above plan', value: moneyExact(extraAbove, cur), sub: 'Salary came in higher'),
      if (p.extrasForGoals > 0)
        StatTile(
            key: const ValueKey('goalsOtherIncome'),
            label: 'Other income',
            value: moneyExact(p.extrasForGoals, cur),
            sub: 'Not in your plan'),
      for (final g in wc.goals) goal(g),
      AddTile(
          key: const ValueKey('addGoal'),
          label: 'Goal',
          onTap: () async {
            final r = await showSheet<String>(context, GoalKindSheet(wc: wc));
            if (!context.mounted || r == null) return;
            if (r.startsWith(goalPlannerResult)) {
              await openGoalPlanner(context, wc, r.substring(goalPlannerResult.length));
            } else {
              goalSheetToast(context, wc, r);
            }
          }),
    ]);
    final panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const SaveSectionHead('Goals'), grid]);
    if (embedded) return panel;
    return ColoredBox(
        color: c.desk, child: ListView(padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad), children: [panel]));
  }
}

/// The total's bar: [fraction] of the track in the goals colour (shown only).
class _TotalBar extends StatelessWidget {
  final double fraction;
  final Color color;
  const _TotalBar(this.fraction, this.color);
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          height: 10,
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: context.c.surface2),
            Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: fraction, child: ColoredBox(color: color))),
          ]),
        ),
      );
}
