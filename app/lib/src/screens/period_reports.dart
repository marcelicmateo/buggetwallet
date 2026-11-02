// Insights (stage P8): two reports per pay period (salary to salary), not by date range, so no range control, only a
// 6 / 12 periods chip. "Per pay period" is a ledger (income, fixed, flexible, net); "Main tag vs budget" shows one main tag's
// spending per period against its budget. Every number comes from wallet_core through [WalletInsights]; nothing is worked out here
// except adding up the shown rows for the total line.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';

/// "Oct 1 – Oct 31", with "so far" for the running period.
String _periodName(String start, String end, bool running) => running ? '${dateRange(start, end)} · so far' : dateRange(start, end);

/// The 6 / 12 periods chips; keys `periodCount_<id>_<n>`.
class _CountChips extends StatelessWidget {
  final String id;
  final int count;
  final ValueChanged<int> onPick;
  const _CountChips({required this.id, required this.count, required this.onPick});
  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, children: [
        for (final n in const [6, 12])
          ChoiceChip(
              key: ValueKey('periodCount_${id}_$n'), label: Text('$n pay periods'), selected: count == n, onSelected: (_) => onPick(n)),
      ]);
}

/// Income, fixed, flexible and net for the last pay periods, newest first, with a total line.
class PeriodsPanel extends StatefulWidget {
  final WalletController wc;
  const PeriodsPanel({super.key, required this.wc});
  @override
  State<PeriodsPanel> createState() => _PeriodsPanelState();
}

class _PeriodsPanelState extends State<PeriodsPanel> {
  int _count = 6;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final wc = widget.wc, cur = wc.currency, c = context.c;
        final reports = wc.periodReportsFor(count: _count).reversed.toList();
        var income = 0, fixed = 0, flex = 0;
        for (final p in reports) {
          income += p.income;
          fixed += p.fixed;
          flex += p.flex;
        }
        final net = income - fixed - flex;
        String netText(int n) => n >= 0 ? 'Saved ${moneyExact(n, cur)}' : 'Lost ${moneyExact(-n, cur)}';
        String sub(int i, int f, int x) => 'In ${moneyExact(i, cur)} · Fixed ${moneyExact(f, cur)} · Flexible ${moneyExact(x, cur)}';
        return Panel(children: [
          const Eyebrow('Per pay period'),
          _CountChips(id: 'periods', count: _count, onPick: (n) => setState(() => _count = n)),
          if (reports.isEmpty)
            const EmptyNote('No pay periods yet. Import your bank files first.')
          else
            Rows(children: [
              for (final p in reports)
                Semantics(
                  container: true,
                  excludeSemantics: true,
                  label: '${_periodName(p.start, p.end, p.running)}: ${netText(p.net)}. ${sub(p.income, p.fixed, p.flex)}',
                  child: LineItem(_periodName(p.start, p.end, p.running), netText(p.net),
                      key: ValueKey('periodRow_${p.start}'),
                      valueColor: p.net < 0 ? c.bad : null,
                      leading: p.net < 0 ? Icon(Icons.trending_down, size: 18, color: c.bad) : null,
                      sub: sub(p.income, p.fixed, p.flex)),
                ),
              Semantics(
                container: true,
                excludeSemantics: true,
                label: 'Total of ${reports.length} pay periods: ${netText(net)}. ${sub(income, fixed, flex)}',
                child: LineItem('Total · ${reports.length} ${reports.length == 1 ? 'period' : 'periods'}', netText(net),
                    key: const ValueKey('periodsTotal'), bold: true, valueColor: net < 0 ? c.bad : null, sub: sub(income, fixed, flex)),
              ),
            ]),
        ]);
      });
}

/// One main tag's spending per pay period against its budget: a bar per period with the budget mark.
class CategoryBudgetPanel extends StatefulWidget {
  final WalletController wc;
  const CategoryBudgetPanel({super.key, required this.wc});
  @override
  State<CategoryBudgetPanel> createState() => _CategoryBudgetPanelState();
}

class _CategoryBudgetPanelState extends State<CategoryBudgetPanel> {
  int _count = 6;
  String? _pick;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final wc = widget.wc, cur = wc.currency, c = context.c, table = wc.categoryTable;
        final ids = wc.recommendedMainFor(null, kinds: {BudgetKind.fixed, BudgetKind.flex});
        final sel = _pick != null && ids.contains(_pick) ? _pick : ids.firstOrNull;
        return Panel(children: [
          const Eyebrow('Main tag vs budget'),
          const Muted('The line is its monthly budget.'),
          _CountChips(id: 'categoryBudget', count: _count, onPick: (n) => setState(() => _count = n)),
          if (sel == null)
            const EmptyNote('No spending main tags yet.')
          else ...[
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Main tag'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('catBudgetPick'),
                  isExpanded: true,
                  isDense: true,
                  value: sel,
                  items: [
                    for (final id in ids)
                      DropdownMenuItem<String>(
                          value: id, child: Text(table.label(id), key: ValueKey('catBudgetItem:$id'), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _pick = v),
                ),
              ),
            ),
            ..._bars(wc, sel, cur, c),
          ],
        ]);
      });

  List<Widget> _bars(WalletController wc, String cat, String cur, WalletColors c) {
    final periods = wc.categoryByPeriodFor(cat, count: _count).reversed.toList();
    if (periods.isEmpty) return const [EmptyNote('No pay periods yet.')];
    final budget = periods.first.budget;
    var scale = budget ?? 0;
    for (final p in periods) {
      if (p.spent > scale) scale = p.spent;
    }
    return [
      if (budget == null)
        const Muted('No budget set for this main tag. Add one in Budget › Plan.', key: ValueKey('catBudgetNone'))
      else
        Muted('Budget ${moneyExact(budget, cur)} a month.', key: const ValueKey('catBudgetValue')),
      Rows(children: [
        for (final p in periods)
          Semantics(
            container: true,
            excludeSemantics: true,
            label: '${_periodName(p.start, p.end, p.running)}: spent ${moneyExact(p.spent, cur)}'
                '${p.budget == null ? '' : ', budget ${moneyExact(p.budget!, cur)}'}${p.over ? ', over by ${moneyExact(p.overBy, cur)}' : ''}',
            child: Column(key: ValueKey('catPeriodRow_${p.start}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LineItem(_periodName(p.start, p.end, p.running), moneyExact(p.spent, cur),
                  valueColor: p.over ? c.bad : null,
                  leading: p.over ? Icon(Icons.error_outline, size: 18, color: c.bad) : null,
                  sub: p.over ? 'Over by ${moneyExact(p.overBy, cur)}' : (p.budget == null ? null : 'Within budget')),
              if (scale > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: p.budget == null
                      ? RuledBar(value: p.spent <= 0 ? 0 : p.spent / scale)
                      : PaceBar(
                          used: p.spent <= 0 ? 0 : p.spent / scale,
                          elapsed: p.budget! / scale,
                          over: p.over,
                          label: 'Spent ${moneyExact(p.spent, cur)} of a ${moneyExact(p.budget!, cur)} budget'),
                ),
            ]),
          ),
      ]),
    ];
  }
}
