import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

class SpendingScreen extends StatefulWidget {
  final WalletController wc;
  const SpendingScreen({super.key, required this.wc});
  @override
  State<SpendingScreen> createState() => _SpendingScreenState();
}

class _SpendingScreenState extends State<SpendingScreen> {
  String? selected;

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final cur = wc.currency;
    final v = wc.spending(selected);
    final current = v.months.last, sel = v.month;
    final (selSum, avg, periods, trend, done, top, monthTxs) =
        (v.summary, v.average, v.periods, v.trend, v.overview, v.topPlaces, v.transactions);

    return MarginLine(
        child: ListView(padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24), children: [
      TwoCol(left: [
        Panel(children: [
          const Eyebrow('Saving or losing'),
          if (periods.isEmpty) ...[
            const Heading('No pay periods yet'),
            const Muted('Import a bank file with your salary. Each pay period runs from one salary to the next.'),
          ] else ...[
            Heading(_savedHeading(done, cur)),
            Muted(_savedNote(done)),
            PeriodNetChart(periods: periods, trend: trend, currency: cur),
          ],
        ]),
        Panel(children: [
          const Eyebrow('Where it goes'),
          Heading('${monthLong(sel)}: ${money(selSum.out, cur, decimals: 0)} out'),
          Muted(
              'Income ${money(selSum.income, cur, decimals: 0)}. Spending and bills by category; the dark tick is your average of the 6 months before.'),
          _MonthChips(
            months: v.months.sublist(v.months.length - 7),
            current: current,
            selected: sel,
            onSelected: (m) {
              logNav('spending.month', {'month': m});
              setState(() => selected = m);
            },
          ),
          CategoryBars(values: selSum.byCategory, average: avg, currency: cur),
        ]),
        Panel(children: [
          Heading('Top places in ${monthLong(sel)}', size: 15),
          if (top.isEmpty)
            const EmptyNote('No card spending this month yet.')
          else
            Rows(children: [
              for (final (name, n, total) in top)
                LineItem(name, money(total, cur, decimals: 0), sub: '$n ${n == 1 ? 'payment' : 'payments'}')
            ]),
        ]),
      ], right: [
        Panel(children: [
          Heading('All transactions in ${monthLong(sel)}', size: 15),
          const Muted('Tap one to change its category. Transfers between your own accounts are hidden.'),
          if (monthTxs.isEmpty)
            const EmptyNote('No transactions.')
          else
            Column(children: [
              const TxHeaderRow(),
              for (final t in monthTxs)
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
    ]));
  }
}

/// The month chips in a row that scrolls sideways; the selected chip is scrolled fully into view when the row is first
/// built, when the selection changes and when the row's width changes (a resized window).
class _MonthChips extends StatefulWidget {
  final List<String> months;
  final String current, selected;
  final ValueChanged<String> onSelected;
  const _MonthChips({required this.months, required this.current, required this.selected, required this.onSelected});
  @override
  State<_MonthChips> createState() => _MonthChipsState();
}

class _MonthChipsState extends State<_MonthChips> {
  final _selectedKey = GlobalKey();
  double? _width;

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _selectedKey.currentContext;
        // Only the chip row scrolls: Scrollable.ensureVisible would also move every enclosing scrollable (the page).
        final ro = c?.findRenderObject();
        if (mounted && c != null && ro != null) Scrollable.of(c).position.ensureVisible(ro, alignment: 1);
      });

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(_MonthChips old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _reveal();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (_width != box.maxWidth) {
          _width = box.maxWidth;
          _reveal();
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final m in widget.months)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                    key: m == widget.selected ? _selectedKey : null,
                    label: Text(m == widget.current ? '${monthShort(m)} (now)' : monthShort(m)),
                    selected: m == widget.selected,
                    onSelected: (_) => widget.onSelected(m)),
              ),
          ]),
        );
      });
}

String _periods(int n) => n == 1 ? 'pay period' : '$n pay periods';

String _savedHeading(SavingsOverview o, String cur) {
  if (o.periods == 0) return 'First pay period still running';
  final over = o.periods == 1 ? 'in the last pay period' : 'over the last ${_periods(o.periods)}';
  return o.net >= 0 ? 'Saved ${money(o.net, cur, decimals: 0)} $over' : 'Lost ${money(-o.net, cur, decimals: 0)} $over';
}

String _savedNote(SavingsOverview o) {
  final parts = <String>[];
  final r = o.savingsRate;
  if (r != null) parts.add(r >= 0 ? 'You kept ${percent(r)} of what came in.' : 'You spent ${percent(-r)} more than came in.');
  if (o.periods > 0) parts.add('${o.saved} of ${o.periods} ${o.periods == 1 ? 'period' : 'periods'} saved.');
  parts.add('Each bar runs from one salary to the next; the line is the 3-period average. The faded bar is still running.');
  return parts.join(' ');
}
