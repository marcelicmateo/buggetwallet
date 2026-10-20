import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

class GoalsScreen extends StatelessWidget {
  final WalletController wc;
  const GoalsScreen({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cur = wc.currency;
    final p = wc.period();
    final extraAbove = p.received - wc.settings.salary;
    final total = wc.goals.fold<int>(0, (a, g) => a + g.saved);

    String eta(Goal g) {
      final n = monthsToGoal(g);
      if (n == null) return 'Set a monthly amount';
      if (n == 0) return 'Reached';
      final end = parseIso(p.end);
      final d = DateTime.utc(end.year, end.month + n - 1, 15);
      return 'by ${monthYear(d.year, d.month)}';
    }

    Widget card(Goal g) => InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: c.surface2,
          focusColor: c.accentSoft,
          mouseCursor: SystemMouseCursors.click,
          onTap: () => showSheet<void>(context, GoalSheet(wc: wc, goal: g)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SplitRow(
                  start: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  end: Text('${money(g.saved, cur, decimals: 0)} / ${money(g.target, cur, decimals: 0)}',
                      textAlign: TextAlign.end, style: numStyle)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  value: g.target > 0 ? (g.saved / g.target).clamp(0.0, 1.0) : 0.0,
                  minHeight: 8,
                  backgroundColor: c.surface2,
                  color: c.accent,
                ),
              ),
              const SizedBox(height: 6),
              Text('${money(g.monthly, cur, decimals: 0)} a month · ${eta(g)}', style: TextStyle(fontSize: 12.5, color: c.muted)),
            ]),
          ),
        );

    return ListView(
        padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24),
        children: gapped([
          if (p.extras > 0 || extraAbove > 0)
            Panel(color: c.accentSoft, children: [
              const Heading('Extra money this month', size: 15),
              Text(
                '${extraAbove > 0 ? 'Salary came in ${money(extraAbove, cur, decimals: 0)} above plan. ' : ''}'
                '${p.extras > 0 ? 'Other income: ${money(p.extras, cur, decimals: 0)}. ' : ''}'
                "Put it straight into a goal so it doesn't leak into daily spending.",
                style: const TextStyle(fontSize: 14),
              ),
            ]),
          Panel(children: [
            const Eyebrow('Goals'),
            Heading('${money(total, cur, decimals: 0)} put aside'),
            const Muted(
                'Each goal takes its monthly amount off the top on payday. Emergency fund first: 3 months of rent, loan and bills.'),
            if (wc.goals.isEmpty) const EmptyNote('No goals yet.'),
            if (wc.goals.isNotEmpty)
              LayoutBuilder(builder: (context, box) {
                // Cards side by side from the medium size up.
                final cols = layoutOf(context) == LayoutSize.compact ? 1 : 2;
                final w = (box.maxWidth - (cols - 1) * 16) / cols;
                return Wrap(spacing: 16, runSpacing: 6, children: [
                  for (final g in wc.goals) SizedBox(width: w, child: card(g)),
                ]);
              }),
            OutlinedButton.icon(
                icon: const Icon(Icons.add), label: const Text('New goal'), onPressed: () => showSheet<void>(context, GoalSheet(wc: wc))),
          ]),
        ]));
  }
}
