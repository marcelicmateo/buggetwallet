// Insights (stage N3): four graphs, each with its own range control, and the biggest payments.
// Phone: a full-screen page; from 600 dp a dialog. All numbers come from the controller (wallet_core), cached per range.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/chart_viewport.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/insight_charts.dart';
import '../widgets/sheets.dart';
import 'bucket_payments.dart';
import 'category_detail.dart';
import 'period_reports.dart';
import 'tag_detail.dart';

/// Opens Insights. [picker] replaces the system date range picker (tests).
Future<void> openInsights(BuildContext context, WalletController wc, {RangePicker? picker}) =>
    openPageOrDialog<void>(context, InsightsScreen(wc: wc, picker: picker), width: 760, logName: 'InsightsScreen');

class InsightsScreen extends StatelessWidget {
  final WalletController wc;
  final RangePicker? picker;
  const InsightsScreen({super.key, required this.wc, this.picker});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const DialogAppBar(title: 'Insights'),
        body: ListView(padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad), children: [
          for (final id in insightGraphs) ...[
            InsightPanel(key: ValueKey('insightPanel_$id'), wc: wc, id: id, picker: picker),
            const SizedBox(height: 16),
          ],
          PeriodsPanel(key: const ValueKey('insightPanel_periods'), wc: wc),
          const SizedBox(height: 16),
          CategoryBudgetPanel(key: const ValueKey('insightPanel_categoryBudget'), wc: wc),
          const SizedBox(height: 16),
        ]),
      );
}

/// One graph with its range control. Redraws when the range or the wallet changes.
class InsightPanel extends StatelessWidget {
  final WalletController wc;
  final String id;
  final RangePicker? picker;
  const InsightPanel({super.key, required this.wc, required this.id, this.picker});

  @override
  Widget build(BuildContext context) {
    final model = wc.insightRange(id);
    final list = id == 'share' || id == 'tags' || id == 'biggest'; // lists: − / + and a swipe on the dates (ZC)
    final control = picker == null ? RangeControl(model: model, zoom: list) : RangeControl(model: model, picker: picker!, zoom: list);
    return ListenableBuilder(
      listenable: Listenable.merge([wc, model]),
      builder: (context, _) {
        final r = model.range;
        final cur = wc.currency;
        final foreign = id == 'biggest' ? const <String, int>{} : wc.shareFor(r).foreignByCurrency;
        final body = switch (id) {
          'spending' => _spending(context, r, cur),
          'share' => _share(context, r, cur),
          'tags' => _tags(context, r, cur),
          'income' => _income(context, r, cur),
          'budget' => _budget(context, r, cur),
          _ => _biggest(context, r, cur),
        };
        // Title only: no note restating it (owner 2026-10-30, no duplicated information).
        final eyebrow = switch (id) {
          'spending' => 'Spending per month',
          'share' => 'Where it goes',
          'tags' => 'Tags',
          'income' => 'Income and spending',
          'budget' => 'Budget and actual',
          _ => 'Biggest payments',
        };
        return Panel(children: [
          Eyebrow(eyebrow),
          control,
          ...body,
          if (foreign.isNotEmpty)
            ForeignNote(foreign, key: ValueKey('foreign_$id'), onSetRate: () {
              Navigator.of(context).popUntil((r) => r.isFirst); // close Insights, then Settings opens at Currencies
              wc.openCurrencies();
            }),
        ]);
      },
    );
  }

  String _name(DateRange span, Bucket b, bool partial) => barName(span, b, partial, wc.today());

  Key _rowKey(DateRange span, Bucket b) => ValueKey('barRow_${id}_${barRowId(span, b)}');

  /// A time graph in a [ChartViewport]: the bars follow the finger, the legend and the exact rows follow the committed window. Tapping
  /// a bar or its row opens that bar's payments.
  Widget _graph<T>(
    BuildContext context,
    InsightRange model, {
    required String keyName,
    required String label,
    required int rods,
    required List<T> Function(DateRange w, Bucket b) bars,
    required DateRange Function(T) span,
    required bool Function(T) partial,
    required BarGroup Function(T bar, String name, Bucket b, bool first) group,
    required Widget Function(T bar, String name, Key key, VoidCallback open) row,
    required List<Widget> Function(bool anyPartial, bool anyShare, Bucket b) legend,
    bool Function(T)? prorated,
    bool income = false,
  }) {
    void open(T bar, Bucket b) {
      final sp = span(bar);
      logNav('insights.bar', {'graph': id, 'bucket': b.name});
      openBucketPayments(context, wc, title: _name(sp, b, false), rows: () => wc.paymentsIn(sp, income: income));
    }

    return ChartViewport(
      id: id,
      window: model.range,
      onCommit: model.setWindow,
      onReset: model.reset,
      canReset: model.isFree,
      edges: model.edges,
      rodsPerBar: rods,
      chart: (context, w, b) {
        final list = bars(w, b);
        return SeriesBars(
          key: ValueKey(keyName),
          label: label,
          groups: [
            for (var i = 0; i < list.length; i++) group(list[i], _name(span(list[i]), b, partial(list[i])), b, i == 0),
          ],
          onOpen: (i) => open(list[i], b),
        );
      },
      legend: (context, w, b) {
        final list = bars(w, b);
        return Legend(legend(list.any(partial), prorated != null && list.any(prorated), b));
      },
      rows: (context, w, b) {
        final list = bars(w, b);
        return Rows(children: [
          for (final x in list) row(x, _name(span(x), b, partial(x)), _rowKey(span(x), b), () => open(x, b)),
        ]);
      },
    );
  }

  List<Widget> _spending(BuildContext context, DateRange r, String cur) {
    final c = context.c;
    return [
      _graph<SeriesBar>(
        context,
        wc.insightRange(id),
        keyName: 'insightBars_spending',
        label: 'Spending per month',
        rods: 1,
        bars: wc.spendingSeriesFor,
        span: (x) => x.span,
        partial: (x) => x.partial,
        group: (x, name, b, first) => BarGroup(
          start: x.span.start,
          axis: barAxisText(x.span, b, firstOfAll: first),
          partial: x.partial,
          rods: [BarRod(x.spent, c.chartPos)],
          tip: '$name\nOut ${moneyExact(x.spent, cur)}',
          spoken: '$name: ${moneyExact(x.spent, cur)} spent',
        ),
        row: (x, name, key, open) => LineItem(name, moneyExact(x.spent, cur), key: key, onTap: open),
        legend: (anyPartial, _, b) =>
            [LegendItem(c.chartPos, 'Spent'), if (anyPartial) LegendItem(c.chartPos, barFadedText(b), dashed: true)],
      ),
    ];
  }

  List<Widget> _share(BuildContext context, DateRange r, String cur) {
    final share = wc.shareFor(r);
    return [
      ShareBars(
        share: share,
        table: wc.categoryTable,
        currency: cur,
        onOpen: (cat) {
          logNav('insights.category', {'graph': id});
          openCategory(context, wc, cat, r);
        },
      ),
    ];
  }

  List<Widget> _tags(BuildContext context, DateRange r, String cur) {
    final share = wc.tagShareFor(r);
    return [
      const Muted('A payment can have several tags, so these overlap.', key: ValueKey('tagsOverlapNote')),
      TagBars(
        share: share,
        tags: wc.tagTable,
        currency: cur,
        onOpen: (tag) {
          logNav('insights.tag', {'graph': id});
          openTag(context, wc, tag, r);
        },
      ),
      if (share.slices.isNotEmpty || share.untaggedSpent > 0)
        Rows(children: [LineItem('No extra tag', moneyExact(share.untaggedSpent, cur), key: const ValueKey('tagsUntagged'))]),
    ];
  }

  List<Widget> _income(BuildContext context, DateRange r, String cur) {
    final c = context.c;
    return [
      _graph<IncomeSpendingBar>(
        context,
        wc.insightRange(id),
        keyName: 'insightBars_income',
        label: 'Income and spending per month',
        rods: 2,
        income: true,
        bars: wc.incomeSeriesFor,
        span: (x) => x.span,
        partial: (x) => x.partial,
        group: (x, name, b, first) => BarGroup(
          start: x.span.start,
          axis: barAxisText(x.span, b, firstOfAll: first),
          partial: x.partial,
          rods: [BarRod(x.income + x.extra, c.chartPos), BarRod(x.spent, c.chart2)],
          tip: '$name\nIn ${moneyExact(x.income + x.extra, cur)}\nOut ${moneyExact(x.spent, cur)}\nNet ${moneyExactSigned(x.net, cur)}',
          spoken: '$name: in ${moneyExact(x.income + x.extra, cur)}, out ${moneyExact(x.spent, cur)}, net ${moneyExactSigned(x.net, cur)}',
        ),
        row: (x, name, key, open) => LineItem(name, 'Net ${moneyExactSigned(x.net, cur)}',
            key: key,
            onTap: open,
            valueColor: x.net < 0 ? c.bad : null,
            sub: 'In ${moneyExact(x.income + x.extra, cur)}${x.extra > 0 ? ' (${moneyExact(x.extra, cur)} extra)' : ''}'
                ' · Out ${moneyExact(x.spent, cur)}'),
        legend: (anyPartial, _, b) => [
          LegendItem(c.chartPos, 'Came in'),
          LegendItem(c.chart2, 'Went out'),
          if (anyPartial) LegendItem(c.ink2, barFadedText(b), dashed: true),
        ],
      ),
    ];
  }

  List<Widget> _budget(BuildContext context, DateRange r, String cur) {
    final c = context.c;
    if (wc.categoryBudgets.values.every((v) => v <= 0)) {
      return const [EmptyNote('No budgets set. Add them in Settings.')];
    }
    return [
      _graph<BudgetBar>(
        context,
        wc.insightRange(id),
        keyName: 'insightBars_budget',
        label: 'Budget and actual per month',
        rods: 2,
        bars: wc.budgetSeriesFor,
        span: (x) => x.span,
        partial: (x) => x.partial,
        prorated: (x) => x.prorated,
        group: (x, name, b, first) {
          final what = x.prorated ? 'Budget share' : 'Budget';
          return BarGroup(
            start: x.span.start,
            axis: barAxisText(x.span, b, firstOfAll: first),
            partial: x.partial,
            rods: [BarRod(x.budgeted, c.lineStrong), BarRod(x.actual, c.chartPos, overCents: x.over)],
            tip: '$name\n$what ${moneyExact(x.budgeted, cur)}\nSpent ${moneyExact(x.actual, cur)}'
                '${x.over > 0 ? '\nOver by ${moneyExact(x.over, cur)}' : ''}',
            spoken: '$name: ${what.toLowerCase()} ${moneyExact(x.budgeted, cur)}, spent ${moneyExact(x.actual, cur)}'
                '${x.over > 0 ? ', over by ${moneyExact(x.over, cur)}' : ''}',
          );
        },
        row: (x, name, key, open) => LineItem(name, moneyExact(x.actual, cur),
            key: key,
            onTap: open,
            leading: x.over > 0 ? Icon(Icons.error_outline, size: 18, color: c.bad, semanticLabel: 'Over a budget') : null,
            sub: '${x.prorated ? 'Budget share' : 'Budget'} ${moneyExact(x.budgeted, cur)}'
                '${x.over > 0 ? ' · over by ${moneyExact(x.over, cur)}' : ''}'),
        legend: (anyPartial, anyShare, b) => [
          LegendItem(c.lineStrong, anyShare ? 'Budget share' : 'Budget'),
          LegendItem(c.chartPos, 'Spent'),
          LegendItem(c.bad, 'Over a budget'),
          if (anyPartial) LegendItem(c.ink2, barFadedText(b), dashed: true),
        ],
      ),
    ];
  }

  List<Widget> _biggest(BuildContext context, DateRange r, String cur) {
    final rows = wc.biggestIn(r);
    if (rows.isEmpty) return const [EmptyNote('No spending in this range.')];
    return [
      Column(key: const ValueKey('biggestList'), children: [
        const TxHeaderRow(),
        for (final t in rows)
          TxTile(
              table: wc.categoryTable,
              tagTable: wc.tagTable,
              t: t,
              currency: cur,
              fxRates: wc.settings.fxRates,
              hasBill: wc.billForTx(t.tx.id) != null,
              matched: wc.isMatchedBank(t.tx.id),
              onTap: () async {
                final res = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                if (context.mounted) txSheetToast(context, wc, res);
              }),
      ]),
    ];
  }
}
