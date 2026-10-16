import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../theme.dart';

/// Saved (above the line) or lost (below) per month. The current month is faded.
class NetBarsChart extends StatelessWidget {
  final List<MonthSummary> months;
  final String currentMonth;
  final String currency;
  const NetBarsChart({super.key, required this.months, required this.currentMonth, required this.currency});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final vals = months.map((m) => m.net / 100).toList();
    final maxPos = vals.fold<double>(50, (a, b) => b > a ? b : a);
    final maxNeg = vals.fold<double>(50, (a, b) => -b > a ? -b : a);
    return SizedBox(
      height: 200,
      child: BarChart(
        BarChartData(
          maxY: maxPos * 1.08,
          minY: -maxNeg * 1.08,
          alignment: BarChartAlignment.spaceAround,
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            checkToShowHorizontalLine: (v) => v == 0,
            getDrawingHorizontalLine: (v) => FlLine(color: c.line, strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= months.length) return const SizedBox.shrink();
                  final ym = months[i].month;
                  final label = monthShort(ym) + (i == 0 || ym.endsWith('-01') ? " '${ym.substring(2, 4)}" : '');
                  return Padding(padding: const EdgeInsets.only(top: 4), child: Text(label, style: TextStyle(fontSize: 10, color: c.muted)));
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, gi, rod, ri) {
                final m = months[group.x];
                final cur = m.month == currentMonth ? ' (so far)' : '';
                return BarTooltipItem(
                  '${monthLong(m.month)}$cur\nIn ${money(m.income, currency, decimals: 0)} · Out ${money(m.out, currency, decimals: 0)}\n${m.net >= 0 ? 'Saved' : 'Lost'} ${money(m.net.abs(), currency, decimals: 0)}',
                  const TextStyle(fontSize: 12, color: Colors.white),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < months.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: vals[i],
                  width: 14,
                  color: (vals[i] >= 0 ? c.pos : c.neg).withValues(alpha: months[i].month == currentMonth ? 0.45 : 1),
                  borderRadius: vals[i] >= 0
                      ? const BorderRadius.vertical(top: Radius.circular(4))
                      : const BorderRadius.vertical(bottom: Radius.circular(4)),
                ),
              ]),
          ],
        ),
      ),
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
    if (cats.isEmpty) return Padding(padding: const EdgeInsets.all(12), child: Text('Nothing spent this month yet.', style: TextStyle(color: c.muted)));
    final maxV = cats.map((k) => [values[k] ?? 0, average[k] ?? 0].reduce((a, b) => a > b ? a : b)).reduce((a, b) => a > b ? a : b).clamp(1, 1 << 60);
    return Column(children: [
      for (final k in cats)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Tooltip(
            message: '$k: ${money(values[k] ?? 0, currency, decimals: 0)} · average ${money(average[k] ?? 0, currency, decimals: 0)}',
            child: Row(children: [
              SizedBox(width: 118, child: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: c.ink2))),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(builder: (ctx, box) {
                  final w = box.maxWidth;
                  final v = (values[k] ?? 0) / maxV, a = (average[k] ?? 0) / maxV;
                  return SizedBox(
                    height: 16,
                    child: Stack(children: [
                      Positioned(left: 0, top: 2, bottom: 2, width: (w * v).clamp(2, w), child: Container(decoration: BoxDecoration(color: c.bar, borderRadius: const BorderRadius.horizontal(right: Radius.circular(4))))),
                      Positioned(left: (w * a - 1).clamp(0, w - 2), top: 0, bottom: 0, width: 2, child: Container(color: c.ink.withValues(alpha: 0.55))),
                    ]),
                  );
                }),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 64, child: Text(money(values[k] ?? 0, currency, decimals: 0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]))),
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
            Positioned(left: 0, right: 0, top: 2, bottom: 2, child: Container(decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.line)))),
            Positioned(left: 0, top: 2, bottom: 2, width: w * used.clamp(0, 1), child: Container(decoration: BoxDecoration(color: over ? c.bad : c.accent, borderRadius: BorderRadius.circular(6)))),
            Positioned(left: (w * elapsed - 1).clamp(0, w - 2), top: 0, bottom: 0, width: 2, child: Container(color: c.ink)),
          ]),
        );
      }),
    );
  }
}
