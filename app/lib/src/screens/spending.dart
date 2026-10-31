import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/charts.dart' show behindPace, leftText;
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';
import 'category_detail.dart';
import 'insights.dart';
import 'search.dart';

/// Budget › Spending (RX4, "Paper Tiles"): where did it go? Tiles: Out in the month (exact, 12-month sparkline, change against the
/// 6-month average), In, Kept, Where it goes (budget meters, a tap opens the category), Saving or losing (net per pay period);
/// month chips choose the month; Insights and search stay in the header row. Top places and the month's payments sit under the tiles.
class SpendingScreen extends StatefulWidget {
  final WalletController wc;

  /// Counts the Ctrl+F presses; the search view opens on each.
  final Listenable? searchRequest;

  /// Jumps to a tab (a goal or wish found by the search, see `Tabs`); [openBills] goes to the Bills tab.
  final void Function(int tab)? openTab;
  final VoidCallback? openBills;

  /// The Spending | Plan switch the Budget tab puts on top of the page (null when the page stands alone).
  final Widget? switcher;
  const SpendingScreen({super.key, required this.wc, this.searchRequest, this.openTab, this.openBills, this.switcher});
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
    final selSum = v.summary;
    final (done, top, monthTxs) = (v.overview, v.topPlaces, v.transactions);

    return ListView(
        padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
        children: gapped([
          if (widget.switcher != null) widget.switcher!,
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
          _MonthChips(
            months: v.months.sublist(v.months.length - 7),
            current: current,
            selected: sel,
            onSelected: (m) {
              logNav('spending.month', {'month': m});
              setState(() => selected = m);
            },
          ),
          DashGrid(children: [
            DashItem(span: 2, child: _outTile(v, cur, current)),
            _inTile(selSum.income, cur),
            _keptTile(done),
            DashItem(span: 2, child: _whereTile(v, budget, budgeted, cur)),
            DashItem(span: 2, child: _netTile(v, cur)),
          ]),
          if (selSum.foreignByCurrency.isNotEmpty)
            ForeignNote(selSum.foreignByCurrency, key: const ValueKey('foreignNote'), onSetRate: wc.openCurrencies),
          TwoCol(left: [
            Panel(children: [
              Heading('Top places in ${monthLong(sel)}', size: BwType.headingSize),
              if (top.isEmpty)
                const EmptyNote('No card spending this month yet.')
              else
                Rows(children: [
                  for (final (name, n, total) in top) LineItem(name, moneyExact(total, cur), sub: '$n ${n == 1 ? 'payment' : 'payments'}')
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
                        matched: wc.isMatchedBank(t.tx.id),
                        iouTag: wc.iouTagOf(t.tx.id),
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
        ]));
  }

  /// "October", or "October 2025" for a month of another year.
  String _monthName(String ym, String current) {
    final long = monthLong(ym);
    return ym.substring(0, 4) == current.substring(0, 4) ? long.split(' ').first : long;
  }

  Widget _outTile(SpendingView v, String cur, String current) {
    final series = v.outByMonth.sublist(v.outByMonth.length - 12);
    final markedAt = v.months.indexOf(v.month) - (v.months.length - series.length); // the chosen month's place among the 12
    final change = v.outChange;
    // Spending less than the average is the good direction; a missing average (nothing in the 6 months before) shows no chip.
    // Under half a percent (5 permille) it is the same as the average: a flat chip, never "0 % worse".
    final chip = change == null
        ? null
        : change.abs() < 5
            ? const DeltaChip(key: ValueKey('outDelta'), trend: Trend.flat, text: 'same as avg')
            : DeltaChip(
                key: const ValueKey('outDelta'),
                trend: change > 0 ? Trend.up : Trend.down,
                text: '${(change.abs() + 5) ~/ 10} % vs avg',
                good: change < 0);
    return StatTile(
      key: const ValueKey('outTile'),
      label: 'Out in ${_monthName(v.month, current)}',
      value: moneyExact(v.summary.out, cur),
      visual: Sparkline(
          values: [for (final c in series) c / 100],
          marked: markedAt < 0 ? null : markedAt,
          color: context.c.s1,
          semanticLabel: 'Out per month, the last ${series.length} months, ${monthLong(v.month)} marked'),
      chip: chip,
    );
  }

  Widget _inTile(int income, String cur) => StatTile(key: const ValueKey('inTile'), label: 'In', value: moneyExact(income, cur));

  Widget _keptTile(SavingsOverview o) {
    final rate = o.savingsRate;
    if (o.periods == 0) {
      return const StatTile(key: ValueKey('keptTile'), label: 'Kept', value: '—', sub: 'No pay periods yet');
    }
    return StatTile(
      key: const ValueKey('keptTile'),
      label: 'Kept',
      trailing: TileNote('${o.periods} ${o.periods == 1 ? 'period' : 'periods'}'),
      value: percent(rate),
      sub: '${o.saved} saved · ${o.periods - o.saved} lost',
      chip: rate != null && rate < 0 ? const StateChip.over(text: 'Spent more than came in') : null,
    );
  }

  Widget _whereTile(SpendingView v, BudgetVsActual budget, bool budgeted, String cur) {
    final wc = widget.wc, c = context.c;
    final table = wc.categoryTable, sel = v.month;
    final lines = {
      for (final l in budget.lines)
        if (l.budget != null) l.category: l
    };
    final values = v.byTopLevel, avg = v.average;
    bool shown(String k) => (values[k] ?? 0) > 50 || (avg[k] ?? 0) > 50;
    final cats = {...values.keys, ...avg.keys}.where(shown).toList()
      ..addAll(lines.keys.where((k) => !shown(k)))
      ..sort((a, b) => (values[b] ?? 0).compareTo(values[a] ?? 0));
    final maxV = cats.fold<int>(1, (m, k) => (values[k] ?? 0) > m ? values[k]! : m);
    final behind = lines.values.where(behindPace).length;
    BarRow row(String k) {
      final l = lines[k], actual = values[k] ?? 0;
      final color = table.kindOf(k) == BudgetKind.fixed ? c.s2 : c.s1;
      void open() {
        logNav('spending.category');
        openCategory(context, wc, k, wc.monthRange(sel));
      }

      if (l == null) {
        return BarRow(
            key: ValueKey('categoryRow_$k'),
            label: table.label(k),
            value: moneyExact(actual, cur),
            note: 'Average ${moneyExact(avg[k] ?? 0, cur)}',
            fraction: actual / maxV,
            color: color,
            onTap: open);
      }
      final b = l.budget!;
      return BarRow(
          key: ValueKey('categoryRow_$k'),
          label: table.label(k),
          value: '${moneyExact(l.actual, cur)} / ${moneyExact(b, cur)}',
          note: behindPace(l) ? '${leftText(l.remaining!, cur)} · behind pace' : leftText(l.remaining!, cur),
          fraction: b == 0 ? (l.actual > 0 ? 2 : 0) : l.actual / b,
          color: color,
          onTap: open);
    }

    final DashChip? chip = !budgeted
        ? null
        : budget.overCount > 0 || behind > 0
            ? StateChip.over(
                key: const ValueKey('budgetState'),
                text: [if (budget.overCount > 0) '${budget.overCount} over', if (behind > 0) '$behind behind pace'].join(' · '))
            : const StateChip.onPace(key: ValueKey('budgetState'));
    return Tile(
      key: const ValueKey('whereTile'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const TileLabel('Where it goes'),
        if (chip != null) Padding(padding: const EdgeInsets.only(top: 6), child: chip),
        const SizedBox(height: 4),
        if (cats.isEmpty) const EmptyNote('Nothing spent this month yet.') else BarList(rows: [for (final k in cats) row(k)]),
        if (budgeted && budget.remainingTotal != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${moneyExact(budget.budgetedActual, cur)} of ${moneyExact(budget.budgetTotal, cur)} budgeted',
                key: const ValueKey('budgetTotal'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          ),
      ]),
    );
  }

  Widget _netTile(SpendingView v, String cur) {
    final periods = v.periods;
    if (periods.isEmpty) {
      return const StatTile(label: 'Saving or losing', value: '—', sub: 'No pay periods yet');
    }
    final n = sizeFor(MediaQuery.sizeOf(context).width) == LayoutSize.compact ? 6 : 8;
    final last = periods.length > n ? periods.sublist(periods.length - n) : periods;
    return Tile(
      key: const ValueKey('netTile'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const SplitRow(start: TileLabel('Saving or losing'), end: TileNote('per pay period')),
        const SizedBox(height: 8),
        NetBars(bars: [
          for (final p in last)
            NetBar(label: monthShort(p.start.substring(0, 7)), value: moneyExact(p.net, cur), cents: p.net, running: p.running)
        ]),
      ]),
    );
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
