// The Insights graphs (stage N3): grouped bars per month, category share bars, a legend and the exact-amount rows under a graph.
// Drawing only: every number is computed by wallet_core and handed in. Crisp like the N0 charts: strokes snapped to device pixels,
// opaque fills (a faded bar is a tint over the page colour, never alpha).
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import 'charts.dart' show RuledBar, snapPx, solidOver;
import 'common.dart';

/// One bar of a group. [overCents] is the last part of [cents] that is over a budget: drawn in `bad`.
class BarRod {
  final int cents;
  final Color color;
  final int overCents;
  const BarRod(this.cents, this.color, {this.overCents = 0});
}

/// A month: one to three rods side by side. A [partial] month (not complete yet, or cut by the range) is drawn faded with a
/// dashed outline. [tip] is the tooltip, [spoken] what a screen reader says for it.
class BarGroup {
  final String month; // YYYY-MM
  final List<BarRod> rods;
  final bool partial;
  final String tip, spoken;
  const BarGroup({required this.month, required this.rods, required this.partial, required this.tip, required this.spoken});
}

/// Grouped bars per month with a zero line. [label] is what a screen reader says first; each group's [BarGroup.spoken] follows,
/// so the amounts are all heard. The exact amounts also sit in a list under the graph.
class MonthlyBars extends StatelessWidget {
  final List<BarGroup> groups;
  final String label;
  const MonthlyBars({super.key, required this.groups, required this.label});

  static const _height = 200.0, _labels = 34.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double px(double logical) => snapPx(logical, dpr);
    final n = groups.length;
    final values = [
      for (final g in groups)
        for (final r in g.rods) r.cents / 100
    ];
    final maxY = values.fold<double>(10, math.max) * 1.08;
    final minY = math.min(0.0, values.fold<double>(0, math.min)) * 1.08;
    const hidden = AxisTitles(sideTitles: SideTitles(showTitles: false));
    final spoken = '$label. ${groups.map((g) => g.spoken).join('. ')}';
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: SizedBox(
          height: _height,
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            final perRod = groups.isEmpty ? 1 : groups.map((g) => g.rods.length).reduce(math.max);
            final slot = w / math.max(1, n);
            final rodW = px(((slot * 0.72 - (perRod - 1) * 2) / perRod).clamp(2.0, 18.0));
            // Month names every few bars when they would touch.
            final every = math.max(1, (n / math.max(1, (w / 40).floor())).ceil());
            return BarChart(
              BarChartData(
                maxY: maxY,
                minY: minY,
                alignment: BarChartAlignment.spaceAround,
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (v) => FlLine(color: v == 0 ? c.lineStrong : c.line, strokeWidth: px(1)),
                ),
                titlesData: FlTitlesData(
                  leftTitles: hidden,
                  rightTitles: hidden,
                  topTitles: hidden,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: _labels,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= n || i % every != 0) return const SizedBox.shrink();
                        final m = groups[i].month;
                        return Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text('${monthShort(m)}\n${m.substring(2, 4)}',
                              textAlign: TextAlign.center,
                              style: numStyle.copyWith(fontSize: BwType.metaSize, height: 1.15, color: c.muted)),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => c.ink,
                    tooltipBorderRadius: BorderRadius.circular(2),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItem: (group, gi, rod, ri) =>
                        ri == 0 ? BarTooltipItem(groups[group.x].tip, numStyle.copyWith(fontSize: BwType.metaSize, color: c.bg)) : null,
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < n; i++)
                    BarChartGroupData(x: i, barsSpace: px(2), barRods: [
                      for (final r in groups[i].rods) _rod(r, groups[i].partial, rodW, c, px),
                    ]),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }

  BarChartRodData _rod(BarRod r, bool partial, double width, WalletColors c, double Function(double) px) {
    Color tint(Color x) => partial ? solidOver(x.withValues(alpha: 0.45), c.bg) : x;
    final v = r.cents / 100;
    final over = r.overCents.clamp(0, r.cents > 0 ? r.cents : 0) / 100;
    return BarChartRodData(
      toY: v,
      width: width,
      color: tint(r.color),
      borderRadius: BorderRadius.zero,
      borderSide: partial ? BorderSide(color: r.color, width: px(1)) : BorderSide.none,
      borderDashArray: partial ? const [3, 3] : null,
      rodStackItems:
          over > 0 ? [BarChartRodStackItem(0, v - over, tint(r.color)), BarChartRodStackItem(v - over, v, tint(c.bad))] : const [],
    );
  }
}

/// A swatch and a word, for a graph's legend. [dashed] marks the faded "so far" bar.
class LegendItem extends StatelessWidget {
  final Color color;
  final String text;
  final bool dashed;
  const LegendItem(this.color, this.text, {super.key, this.dashed = false});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: dashed ? solidOver(color.withValues(alpha: 0.45), c.bg) : color,
          border: dashed ? Border.all(color: color) : null,
        ),
      ),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2))),
    ]);
  }
}

class Legend extends StatelessWidget {
  final List<Widget> items;
  const Legend(this.items, {super.key});
  @override
  Widget build(BuildContext context) => Wrap(spacing: 14, runSpacing: 4, children: items);
}

/// "12.3 %" for 123 thousandths, "12 %" for 120.
String permilleText(int permille) {
  final whole = permille ~/ 10, tenth = permille % 10;
  return tenth == 0 ? '$whole %' : '$whole.$tenth %';
}

/// Spending per category as horizontal bars, largest first: name and exact amount over a bar and its share. A tap opens the
/// category ([onOpen]). The bar is scaled to the largest slice; the percentage is the true share (permille from core).
class ShareBars extends StatelessWidget {
  final CategoryShare share;
  final String currency;
  final ValueChanged<String>? onOpen;
  const ShareBars({super.key, required this.share, required this.currency, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final slices = share.slices;
    if (slices.isEmpty) return const EmptyNote('No spending in this range.');
    final top = slices.first.spent.clamp(1, 1 << 60);
    return Column(children: [
      for (final s in slices)
        Semantics(
          button: onOpen != null,
          label: '${s.category}: ${permilleText(s.permille)}, ${moneyExact(s.spent, currency)}',
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('shareRow_${s.category}'),
            onTap: onOpen == null ? null : () => onOpen!(s.category),
            child: RuledRow(
              minHeight: rowMin,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                  start: Text(s.category, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: BwType.bodySize)),
                  end: MoneyText(moneyExact(s.spent, currency),
                      textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: RuledBar(value: s.spent / top, color: c.bar)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 64,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(permilleText(s.permille), style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.ink2)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
    ]);
  }
}
