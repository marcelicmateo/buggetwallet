import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'category_detail.dart';
import 'insights.dart';
import 'search.dart';

class SpendingScreen extends StatefulWidget {
  final WalletController wc;

  /// Counts the Ctrl+F presses; the search view opens on each.
  final Listenable? searchRequest;

  /// Jumps to a tab (a goal or wish found by the search, see `Tabs`); [openBills] goes to the Bills tab.
  final void Function(int tab)? openTab;
  final VoidCallback? openBills;

  /// Panels above everything else (the Budget tab puts the payday plan here).
  final List<Widget> header;
  const SpendingScreen({super.key, required this.wc, this.searchRequest, this.openTab, this.openBills, this.header = const []});
  @override
  State<SpendingScreen> createState() => _SpendingScreenState();
}

class _SpendingScreenState extends State<SpendingScreen> {
  String? selected;
  bool searching = false;

  @override
  void initState() {
    super.initState();
    widget.searchRequest?.addListener(_openSearch);
  }

  @override
  void didUpdateWidget(SpendingScreen old) {
    super.didUpdateWidget(old);
    if (old.searchRequest != widget.searchRequest) {
      old.searchRequest?.removeListener(_openSearch);
      widget.searchRequest?.addListener(_openSearch);
    }
  }

  @override
  void dispose() {
    widget.searchRequest?.removeListener(_openSearch);
    super.dispose();
  }

  Future<void> _openTx(CategorizedTx t) async {
    final r = await showSheet<String>(context, TxSheet(wc: widget.wc, t: t));
    if (mounted) txSheetToast(context, widget.wc, r);
  }

  void _openSearch() {
    if (mounted && !searching) setState(() => searching = true);
  }

  @override
  Widget build(BuildContext context) {
    // The page stays built under the search view (an IndexedStack), so closing it keeps the scroll position and the month.
    return MarginLine(
        child: IndexedStack(index: searching ? 1 : 0, sizing: StackFit.expand, children: [
      _page(context),
      if (searching)
        SearchPane(
            wc: widget.wc,
            onClose: () => setState(() => searching = false),
            onOpenTab: (i) => widget.openTab?.call(i),
            onOpenBills: () => widget.openBills?.call())
      else
        const SizedBox.shrink(),
    ]));
  }

  Widget _page(BuildContext context) {
    final wc = widget.wc;
    final cur = wc.currency;
    final v = wc.spending(selected);
    final current = v.months.last, sel = v.month;
    final budget = wc.budgetVsActual(sel);
    final budgeted = budget.budgetedCount > 0;
    final (selSum, avg, periods, trend, done, top, monthTxs) =
        (v.summary, v.average, v.periods, v.trend, v.overview, v.topPlaces, v.transactions);

    return ListView(padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad), children: [
      Row(children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('insightsOpen'),
              style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
              icon: const Icon(Icons.insights_outlined),
              label: const Text('Insights', maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () {
                logNav('spending.insights');
                openInsights(context, wc);
              },
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('searchOpen'),
          tooltip: hasKeyboard ? 'Search (Ctrl+F)' : 'Search',
          icon: const Icon(Icons.search),
          onPressed: () => setState(() => searching = true),
        ),
      ]),
      TwoCol(left: [
        ...widget.header,
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
          if (budgeted) BudgetSummary(budget, cur),
          if (selSum.foreignByCurrency.isNotEmpty)
            ForeignNote(selSum.foreignByCurrency, key: const ValueKey('foreignNote'), onSetRate: wc.openCurrencies),
          Muted('Income ${money(selSum.income, cur, decimals: 0)}. Spending and bills by main tag; '
              '${budgeted ? 'the solid mark is the budget, the dark tick' : 'the dark tick'} is your average of the 6 months before.'),
          _MonthChips(
            months: v.months.sublist(v.months.length - 7),
            current: current,
            selected: sel,
            onSelected: (m) {
              logNav('spending.month', {'month': m});
              setState(() => selected = m);
            },
          ),
          CategoryBars(
              values: v.byTopLevel,
              table: wc.categoryTable,
              average: avg,
              currency: cur,
              budget: budgeted ? budget : null,
              onOpen: (cat) {
                logNav('spending.category');
                openCategory(context, wc, cat, wc.monthRange(sel));
              }),
        ]),
        Panel(children: [
          Heading('Top places in ${monthLong(sel)}', size: BwType.headingSize),
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
          Heading('All transactions in ${monthLong(sel)}', size: BwType.headingSize),
          const Muted('Tap one to change its main tag. Transfers between your own accounts are hidden.'),
          if (monthTxs.isEmpty)
            const EmptyNote('No transactions.')
          else
            Column(children: [
              const TxHeaderRow(),
              for (final t in monthTxs) ...[
                TxTile(
                    table: wc.categoryTable,
                    tagTable: wc.tagTable,
                    t: wc.shown(t),
                    currency: cur,
                    fxRates: wc.settings.fxRates,
                    hasBill: wc.billForTx(t.tx.id) != null,
                    splitCount: wc.splitCount(t.tx.id),
                    splitBroken: wc.splitIsBroken(t.tx.id),
                    onTap: () => _openTx(t)),
                for (final p in wc.partsOf(t.tx.id))
                  PartTile(
                      part: p,
                      currency: cur,
                      fxRates: wc.settings.fxRates,
                      table: wc.categoryTable,
                      tagTable: wc.tagTable,
                      onTap: () => _openTx(t)),
              ],
            ]),
        ]),
      ]),
    ]);
  }
}

/// "3 of 7 categories over budget, 180 € left in total"; when some are behind pace: "1 over, 2 behind pace, 46 € left in total".
class BudgetSummary extends StatelessWidget {
  final BudgetVsActual b;
  final String currency;
  const BudgetSummary(this.b, this.currency, {super.key});
  @override
  Widget build(BuildContext context) {
    final behind = b.lines.where(behindPace).length;
    final left = leftText(b.remainingTotal ?? 0, currency);
    return StatusLabel(
        good: b.overCount == 0 && behind == 0,
        text: behind > 0
            ? '${b.overCount} over, $behind behind pace, $left in total'
            : '${b.overCount} of ${b.budgetedCount} ${b.budgetedCount == 1 ? 'category' : 'categories'} over budget, $left in total');
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
