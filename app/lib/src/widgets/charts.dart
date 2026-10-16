import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../theme.dart';

/// Saved (above the line) or lost (below) per pay period, with the rolling average as a line.
/// The running period is faded.
class PeriodNetChart extends StatelessWidget {
  final List<PeriodSummary> periods;
  final List<int?> trend; // same length as [periods]; null = no point
  final String currency;
  const PeriodNetChart({super.key, required this.periods, required this.trend, required this.currency});

  static const _height = 200.0, _labels = 30.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final vals = periods.map((p) => p.net / 100).toList();
    final all = [
      ...vals,
      for (final t in trend)
        if (t != null) t / 100
    ];
    final maxY = all.fold<double>(50, (a, b) => b > a ? b : a) * 1.08;
    final minY = -all.fold<double>(50, (a, b) => -b > a ? -b : a) * 1.08;
    const hidden = AxisTitles(sideTitles: SideTitles(showTitles: false));
    // Both charts reserve the same label strip so their plot areas line up.
    final bottom = AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: _labels,
        getTitlesWidget: (value, meta) {
          final i = value.toInt();
          if (i < 0 || i >= periods.length) return const SizedBox.shrink();
          final d = shortDate(periods[i].start).split(' ');
          return Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text('${d[0]}\n${d[1]}', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, height: 1.15, color: c.muted)),
          );
        },
      ),
    );
    final spots = [for (var i = 0; i < trend.length; i++) trend[i] == null ? FlSpot.nullSpot : FlSpot(i.toDouble(), trend[i]! / 100)];
    return SizedBox(
      height: _height,
      child: Stack(children: [
        BarChart(
          BarChartData(
            maxY: maxY,
            minY: minY,
            alignment: BarChartAlignment.spaceAround,
            borderData: FlBorderData(show: false),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              checkToShowHorizontalLine: (v) => v == 0,
              getDrawingHorizontalLine: (v) => FlLine(color: c.line, strokeWidth: 1),
            ),
            titlesData: FlTitlesData(leftTitles: hidden, rightTitles: hidden, topTitles: hidden, bottomTitles: bottom),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                fitInsideHorizontally: true,
                fitInsideVertically: true,
                getTooltipItem: (group, gi, rod, ri) {
                  final p = periods[group.x];
                  final range = p.running ? '${shortDate(p.start)} – today (so far)' : dateRange(p.start, p.end);
                  return BarTooltipItem(
                    '$range\nIn ${money(p.income, currency, decimals: 0)} · Out ${money(p.out, currency, decimals: 0)}\n'
                    '${p.net >= 0 ? 'Saved' : 'Lost'} ${money(p.net.abs(), currency, decimals: 0)} · kept ${percent(p.savingsRate)}',
                    const TextStyle(fontSize: 12, color: Colors.white),
                  );
                },
              ),
            ),
            barGroups: [
              for (var i = 0; i < periods.length; i++)
                BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                    toY: vals[i],
                    width: 14,
                    color: (vals[i] >= 0 ? c.pos : c.neg).withValues(alpha: periods[i].running ? 0.45 : 1),
                    borderRadius: vals[i] >= 0
                        ? const BorderRadius.vertical(top: Radius.circular(4))
                        : const BorderRadius.vertical(bottom: Radius.circular(4)),
                  ),
                ]),
            ],
          ),
        ),
        if (trend.any((t) => t != null))
          IgnorePointer(
            child: LineChart(
              LineChartData(
                // spaceAround centres bar i in slot i of n, which is x = i on [-0.5, n - 0.5].
                minX: -0.5,
                maxX: periods.length - 0.5,
                maxY: maxY,
                minY: minY,
                borderData: FlBorderData(show: false),
                gridData: const FlGridData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
                titlesData: FlTitlesData(
                  leftTitles: hidden,
                  rightTitles: hidden,
                  topTitles: hidden,
                  bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: _labels, getTitlesWidget: (v, m) => const SizedBox.shrink())),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: c.ink.withValues(alpha: 0.7),
                    barWidth: 2,
                    dotData: FlDotData(
                      getDotPainter: (s, p, b, i) => FlDotCirclePainter(radius: 2.5, color: c.ink.withValues(alpha: 0.8), strokeWidth: 0),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}

/// Horizontal bars by category with a tick for the comparison average.
class CategoryBars extends StatelessWidget {
  final Map<String, int> values;
  final Map<String, int> average;
  final String currency;
  const CategoryBars({super.key, required this.values, required this.average, required this.currency});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cats = {...values.keys, ...average.keys}.where((k) => (values[k] ?? 0) > 50 || (average[k] ?? 0) > 50).toList()
      ..sort((a, b) => (values[b] ?? 0).compareTo(values[a] ?? 0));
    if (cats.isEmpty)
      return Padding(padding: const EdgeInsets.all(12), child: Text('Nothing spent this month yet.', style: TextStyle(color: c.muted)));
    final maxV = cats
        .map((k) => [values[k] ?? 0, average[k] ?? 0].reduce((a, b) => a > b ? a : b))
        .reduce((a, b) => a > b ? a : b)
        .clamp(1, 1 << 60);
    return Column(children: [
      for (final k in cats)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Tooltip(
            message: '$k: ${money(values[k] ?? 0, currency, decimals: 0)} · average ${money(average[k] ?? 0, currency, decimals: 0)}',
            child: Row(children: [
              SizedBox(
                  width: 118,
                  child: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: c.ink2))),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(builder: (ctx, box) {
                  final w = box.maxWidth;
                  final v = (values[k] ?? 0) / maxV, a = (average[k] ?? 0) / maxV;
                  return SizedBox(
                    height: 16,
                    child: Stack(children: [
                      Positioned(
                          left: 0,
                          top: 2,
                          bottom: 2,
                          width: (w * v).clamp(2, w),
                          child: Container(
                              decoration:
                                  BoxDecoration(color: c.bar, borderRadius: const BorderRadius.horizontal(right: Radius.circular(4))))),
                      Positioned(
                          left: (w * a - 1).clamp(0, w - 2),
                          top: 0,
                          bottom: 0,
                          width: 2,
                          child: Container(color: c.ink.withValues(alpha: 0.55))),
                    ]),
                  );
                }),
              ),
              const SizedBox(width: 8),
              SizedBox(
                  width: 64,
                  child: Text(money(values[k] ?? 0, currency, decimals: 0),
                      textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]))),
            ]),
          ),
        ),
    ]);
  }
}

/// Spending money used vs time elapsed in the pay period.
class PaceBar extends StatelessWidget {
  final double used;
  final double elapsed;
  final bool over;
  const PaceBar({super.key, required this.used, required this.elapsed, required this.over});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: '${(used * 100).round()}% of spending money used, ${(elapsed * 100).round()}% of the month gone',
      child: LayoutBuilder(builder: (ctx, box) {
        final w = box.maxWidth;
        return SizedBox(
          height: 14,
          child: Stack(children: [
            Positioned(
                left: 0,
                right: 0,
                top: 2,
                bottom: 2,
                child: Container(
                    decoration:
                        BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.line)))),
            Positioned(
                left: 0,
                top: 2,
                bottom: 2,
                width: w * used.clamp(0, 1),
                child: Container(decoration: BoxDecoration(color: over ? c.bad : c.accent, borderRadius: BorderRadius.circular(6)))),
            Positioned(left: (w * elapsed - 1).clamp(0, w - 2), top: 0, bottom: 0, width: 2, child: Container(color: c.ink)),
          ]),
        );
      }),
    );
  }
}
