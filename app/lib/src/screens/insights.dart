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
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/insight_charts.dart';
import '../widgets/sheets.dart';
import 'category_detail.dart';
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
    final control = picker == null ? RangeControl(model: model) : RangeControl(model: model, picker: picker!);
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
        final (eyebrow, note) = switch (id) {
          'spending' => ('Spending per month', 'What went out each month.'),
          'share' => ('Where it goes', 'Each main tag as a share of the spending. Tap one to see where it went.'),
          'tags' => ('Tags', 'Spent per extra tag. Tap one to see its payments.'),
          'income' => ('Income and spending', 'What came in against what went out, per month.'),
          'budget' => ('Budget and actual', 'Each bar is a whole calendar month.'),
          _ => ('Biggest payments', 'The ten largest. Tap one to change its main tag.'),
        };
        return Panel(children: [
          Eyebrow(eyebrow),
          Muted(note),
          control,
          ...body,
          if (foreign.isNotEmpty) ForeignNote(foreign, key: ValueKey('foreign_$id')),
        ]);
      },
    );
  }

  /// "so far" for the running month, "part of the month" for one cut by the range, null for a whole month.
  String? _partNote(String month, bool partial) {
    if (!partial) return null;
    return month == monthOf(wc.today()) ? 'so far' : 'part of the month';
  }

  String _name(String month, bool partial) {
    final note = _partNote(month, partial);
    return note == null ? monthLong(month) : '${monthLong(month)} · $note';
  }

  List<Widget> _spending(BuildContext context, DateRange r, String cur) {
    final c = context.c;
    final bars = wc.spendingBars(r);
    return [
      MonthlyBars(
        key: const ValueKey('insightBars_spending'),
        label: 'Spending per month',
        groups: [
          for (final b in bars)
            BarGroup(
              month: b.month,
              partial: b.partial,
              rods: [BarRod(b.spent, c.bar)],
              tip: '${_name(b.month, b.partial)}\nOut ${moneyExact(b.spent, cur)}',
              spoken: '${_name(b.month, b.partial)}: ${moneyExact(b.spent, cur)} spent',
            ),
        ],
      ),
      Legend([LegendItem(c.bar, 'Spent'), if (bars.any((b) => b.partial)) LegendItem(c.bar, 'Faded: not a whole month', dashed: true)]),
      Rows(children: [
        for (final b in bars) LineItem(_name(b.month, b.partial), moneyExact(b.spent, cur), key: ValueKey('barRow_${id}_${b.month}')),
      ]),
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
    final bars = wc.incomeBars(r);
    return [
      MonthlyBars(
        key: const ValueKey('insightBars_income'),
        label: 'Income and spending per month',
        groups: [
          for (final b in bars)
            BarGroup(
              month: b.month,
              partial: b.partial,
              rods: [BarRod(b.income + b.extra, c.pos), BarRod(b.spent, c.neg)],
              tip: '${_name(b.month, b.partial)}\nIn ${moneyExact(b.income + b.extra, cur)}\nOut ${moneyExact(b.spent, cur)}\n'
                  'Net ${moneyExactSigned(b.net, cur)}',
              spoken: '${_name(b.month, b.partial)}: in ${moneyExact(b.income + b.extra, cur)}, out ${moneyExact(b.spent, cur)}, '
                  'net ${moneyExactSigned(b.net, cur)}',
            ),
        ],
      ),
      Legend([
        LegendItem(c.pos, 'Came in'),
        LegendItem(c.neg, 'Went out'),
        if (bars.any((b) => b.partial)) LegendItem(c.ink2, 'Faded: not a whole month', dashed: true),
      ]),
      Rows(children: [
        for (final b in bars)
          LineItem(_name(b.month, b.partial), 'Net ${moneyExactSigned(b.net, cur)}',
              key: ValueKey('barRow_${id}_${b.month}'),
              valueColor: b.net < 0 ? c.bad : null,
              sub: 'In ${moneyExact(b.income + b.extra, cur)}${b.extra > 0 ? ' (${moneyExact(b.extra, cur)} extra)' : ''}'
                  ' · Out ${moneyExact(b.spent, cur)}'),
      ]),
    ];
  }

  List<Widget> _budget(BuildContext context, DateRange r, String cur) {
    final c = context.c;
    final bars = wc.budgetBars(r);
    if (bars.every((b) => b.budgeted == 0)) {
      return const [EmptyNote('No budgets set. Add them in Plan.')];
    }
    final now = monthOf(wc.today());
    String name(String m) => m == now ? '${monthLong(m)} · so far' : monthLong(m);
    return [
      MonthlyBars(
        key: const ValueKey('insightBars_budget'),
        label: 'Budget and actual per month',
        groups: [
          for (final b in bars)
            BarGroup(
              month: b.month,
              partial: b.month == now,
              rods: [BarRod(b.budgeted, c.lineStrong), BarRod(b.actual, c.accent, overCents: b.over)],
              tip: '${name(b.month)}\nBudget ${moneyExact(b.budgeted, cur)}\nSpent ${moneyExact(b.actual, cur)}'
                  '${b.over > 0 ? '\nOver by ${moneyExact(b.over, cur)}' : ''}',
              spoken: '${name(b.month)}: budget ${moneyExact(b.budgeted, cur)}, spent ${moneyExact(b.actual, cur)}'
                  '${b.over > 0 ? ', over by ${moneyExact(b.over, cur)}' : ''}',
            ),
        ],
      ),
      Legend([
        LegendItem(c.lineStrong, 'Budget'),
        LegendItem(c.accent, 'Spent'),
        LegendItem(c.bad, 'Over a budget'),
      ]),
      Rows(children: [
        for (final b in bars)
          LineItem(name(b.month), moneyExact(b.actual, cur),
              key: ValueKey('barRow_${id}_${b.month}'),
              leading: b.over > 0 ? Icon(Icons.error_outline, size: 18, color: c.bad, semanticLabel: 'Over a budget') : null,
              sub: 'Budget ${moneyExact(b.budgeted, cur)}${b.over > 0 ? ' · over by ${moneyExact(b.over, cur)}' : ''}'),
      ]),
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
              hasBill: wc.billForTx(t.tx.id) != null,
              onTap: () async {
                final res = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                if (context.mounted) txSheetToast(context, wc, res);
              }),
      ]),
    ];
  }
}
