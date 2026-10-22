import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import 'common.dart';

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
            child:
                Text('${d[0]}\n${d[1]}', textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: 10, height: 1.15, color: c.muted)),
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
              // Solid hairlines; the zero line is the axis, drawn strong.
              getDrawingHorizontalLine: (v) => FlLine(color: v == 0 ? c.lineStrong : c.line, strokeWidth: 1),
            ),
            titlesData: FlTitlesData(leftTitles: hidden, rightTitles: hidden, topTitles: hidden, bottomTitles: bottom),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => c.ink,
                tooltipBorderRadius: BorderRadius.circular(2),
                fitInsideHorizontally: true,
                fitInsideVertically: true,
                getTooltipItem: (group, gi, rod, ri) {
                  final p = periods[group.x];
                  final range = p.running ? '${shortDate(p.start)} – today (so far)' : dateRange(p.start, p.end);
                  return BarTooltipItem(
                    '$range\nIn ${money(p.income, currency, decimals: 0)} · Out ${money(p.out, currency, decimals: 0)}\n'
                    '${p.net >= 0 ? 'Saved' : 'Lost'} ${money(p.net.abs(), currency, decimals: 0)} · kept ${percent(p.savingsRate)}',
                    numStyle.copyWith(fontSize: 11, color: c.bg),
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
                    borderRadius: BorderRadius.zero,
                    // The running period: faded, with a dashed outline.
                    borderSide: periods[i].running ? BorderSide(color: vals[i] >= 0 ? c.pos : c.neg) : BorderSide.none,
                    borderDashArray: periods[i].running ? const [3, 3] : null,
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

/// "48 € left" / "over by 12 €" for a budget line (the whole amount is rounded to units).
String budgetLeftText(CategoryBudgetLine l, String currency) => leftText(l.remaining ?? 0, currency);

/// A budgeted category that is not over budget yet but is spending faster than the month passes (pace above 1.0).
bool behindPace(CategoryBudgetLine l) => !l.over && (l.pace ?? 0) > 1.0;

/// "48 € left" for money still free, "over by 12 €" for a negative amount; cents are shown when there are any (never rounded).
String leftText(int remaining, String currency) =>
    remaining < 0 ? 'over by ${moneyExact(-remaining, currency)}' : '${moneyExact(remaining, currency)} left';

/// Horizontal bars by category with a tick for the comparison average. A category with a budget in [budget] gets a ruled
/// track whose solid mark is the budget (the bar is accent up to it and hatched `bad` beyond it), and "48 € left" or
/// "over by 12 €" on the right; the others keep the plain bar and the amount. [budget] is `null` when nothing is budgeted.
class CategoryBars extends StatelessWidget {
  final Map<String, int> values;
  final Map<String, int> average;
  final String currency;
  final BudgetVsActual? budget;
  const CategoryBars({super.key, required this.values, required this.average, required this.currency, this.budget});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final lines = {
      for (final l in budget?.lines ?? const <CategoryBudgetLine>[])
        if (l.budget != null) l.category: l
    };
    final cats = {...values.keys, ...average.keys}.where((k) => (values[k] ?? 0) > 50 || (average[k] ?? 0) > 50).toList()
      ..addAll(lines.keys.where((k) => !((values[k] ?? 0) > 50 || (average[k] ?? 0) > 50)))
      ..sort((a, b) => (values[b] ?? 0).compareTo(values[a] ?? 0));
    if (cats.isEmpty) {
      return Padding(padding: const EdgeInsets.all(12), child: Text('Nothing spent this month yet.', style: TextStyle(color: c.muted)));
    }
    final maxV = cats
        .map((k) => [values[k] ?? 0, average[k] ?? 0].reduce((a, b) => a > b ? a : b))
        .reduce((a, b) => a > b ? a : b)
        .clamp(1, 1 << 60);
    final total = budget;
    return Column(children: [
      for (final k in cats)
        _CategoryRow(name: k, value: values[k] ?? 0, average: average[k] ?? 0, maxV: maxV, line: lines[k], currency: currency),
      if (total != null && total.budgetedCount > 0 && total.remainingTotal != null)
        TotalRule(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(key: const ValueKey('budgetTotal'), children: [
            const SizedBox(width: 118, child: Text('Budgeted', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '${moneyExact(total.budgetTotal - total.remainingTotal!, currency)} of ${moneyExact(total.budgetTotal, currency)}',
                  textAlign: TextAlign.end,
                  style: numStyle.copyWith(fontSize: 11.5, color: c.ink2)),
            ),
            const SizedBox(width: 8),
            _LeftText(text: leftText(total.remainingTotal!, currency), over: total.remainingTotal! < 0, width: _rightCol),
          ]),
        ),
    ]);
  }
}

const _rightCol = 96.0;

/// "48 € left" in mono, `bad` with an icon when over; shrinks instead of overflowing.
class _LeftText extends StatelessWidget {
  final String text;
  final bool over;
  final double width;
  const _LeftText({required this.text, required this.over, required this.width});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = numStyle.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: over ? c.bad : c.ink);
    return SizedBox(
      width: width,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (over) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.error_outline, size: 15, color: c.bad)),
          MoneyText(text, style: style),
        ]),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String name, currency;
  final int value, average, maxV;
  final CategoryBudgetLine? line;
  const _CategoryRow(
      {required this.name, required this.value, required this.average, required this.maxV, required this.line, required this.currency});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = line;
    final budget = l?.budget;
    final tip = '$name: ${money(value, currency, decimals: 0)} · average ${money(average, currency, decimals: 0)}'
        '${l == null ? '' : ' · budget ${moneyExact(budget!, currency)}, ${budgetLeftText(l, currency)}'}';
    return RuledRow(
      minHeight: l == null ? 36 : (behindPace(l) ? 58 : rowMin),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Tooltip(
        message: tip,
        child: Semantics(
          label: l == null ? null : '$name: ${budgetLeftText(l, currency)}',
          child: Row(children: [
            SizedBox(
                width: 118,
                child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: c.ink2))),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(builder: (ctx, box) {
                final w = box.maxWidth;
                if (l != null) return _BudgetBar(width: w, value: value, average: average, budget: budget!);
                final v = value / maxV, a = average / maxV;
                return SizedBox(
                  height: 16,
                  child: Stack(children: [
                    Positioned(left: 0, top: 2, bottom: 2, width: (w * v).clamp(2, w), child: Container(color: c.bar)),
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
            if (l == null)
              SizedBox(
                width: 72,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(money(value, currency, decimals: 0), textAlign: TextAlign.right, style: numStyle.copyWith(fontSize: 13)),
                ),
              )
            else
              SizedBox(
                width: _rightCol,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _LeftText(text: budgetLeftText(l, currency), over: l.over, width: _rightCol),
                  SizedBox(
                    width: _rightCol,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text('of ${moneyExact(budget!, currency)}', style: numStyle.copyWith(fontSize: 11, color: c.ink2)),
                    ),
                  ),
                  if (behindPace(l))
                    SizedBox(
                      key: const ValueKey('behindPace'),
                      width: _rightCol,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.warning_amber_outlined, size: 13, color: c.warnInk),
                          const SizedBox(width: 3),
                          Text('behind pace', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c.warnInk)),
                        ]),
                      ),
                    ),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The bar of a budgeted category: a ruled track, accent up to the budget, a hatched `bad` stretch beyond it, the budget as
/// a solid 2 px mark and the 6-month average as a lighter tick. The scale is the largest of the three.
class _BudgetBar extends StatelessWidget {
  final double width;
  final int value, average, budget;
  const _BudgetBar({required this.width, required this.value, required this.average, required this.budget});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final scale = [value, average, budget, 1].reduce((a, b) => a > b ? a : b);
    final inner = width - 2;
    double at(int v) => inner * v / scale;
    final solid = value < budget ? value : budget;
    return SizedBox(
      height: 20,
      child: Stack(children: [
        Positioned(
            left: 0,
            right: 0,
            top: 4,
            height: 12,
            child: DecoratedBox(decoration: BoxDecoration(color: c.surface, border: Border.all(color: c.lineStrong)))),
        if (solid > 0) Positioned(left: 1, top: 5, height: 10, width: at(solid).clamp(0, inner), child: ColoredBox(color: c.accent)),
        if (value > budget)
          Positioned(
              key: const ValueKey('overHatch'),
              left: 1 + at(budget),
              top: 5,
              height: 10,
              width: at(value - budget).clamp(0, inner),
              child: CustomPaint(painter: _HatchPainter(c.bad, c.surface2))),
        Positioned(
            left: (1 + at(average) - 1).clamp(0, width - 2),
            top: 3,
            bottom: 3,
            width: 2,
            child: ColoredBox(color: c.ink.withValues(alpha: 0.55))),
        Positioned(left: (1 + at(budget) - 1).clamp(0, width - 2), top: 0, bottom: 0, width: 2, child: ColoredBox(color: c.ink)),
      ]),
    );
  }
}

/// A 10 px bar with a 1 px ink border and a flat fill.
class RuledBar extends StatelessWidget {
  final double value;
  final Color? color;
  const RuledBar({super.key, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      height: 10,
      decoration: BoxDecoration(color: c.surface, border: Border.all(color: c.lineStrong)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(widthFactor: value.clamp(0.0, 1.0), heightFactor: 1, child: ColoredBox(color: color ?? c.accent)),
    );
  }
}

/// Diagonal hatch (135 degrees) in [color] over a pale ground: the "over budget" fill, readable without colour.
class _HatchPainter extends CustomPainter {
  final Color color, ground;
  _HatchPainter(this.color, this.ground);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width + size.height; x += 4) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color || old.ground != ground;
}

/// Spending money used vs time elapsed in the pay period: accent up to the pace mark, a hatched `bad` stretch where
/// spending is ahead of it. The mark is 2 px.
class PaceBar extends StatelessWidget {
  final double used;
  final double elapsed;
  final bool over;
  const PaceBar({super.key, required this.used, required this.elapsed, required this.over});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final u = used.clamp(0.0, 1.0), e = elapsed.clamp(0.0, 1.0);
    return Semantics(
      label: '${(used * 100).round()}% of spending money used, ${(elapsed * 100).round()}% of the month gone',
      child: LayoutBuilder(builder: (ctx, box) {
        final w = box.maxWidth;
        final solid = over ? (u < e ? u : e) : u;
        return SizedBox(
          height: 20,
          child: Stack(children: [
            Positioned(
              left: 0,
              right: 0,
              top: 5,
              height: 10,
              child: DecoratedBox(decoration: BoxDecoration(color: c.surface, border: Border.all(color: c.lineStrong))),
            ),
            // Inside the 1 px border.
            Positioned(left: 1, top: 6, height: 8, width: ((w - 2) * solid).clamp(0, w), child: ColoredBox(color: c.accent)),
            if (over && u > e)
              Positioned(
                left: 1 + (w - 2) * e,
                top: 6,
                height: 8,
                width: (w - 2) * (u - e),
                child: CustomPaint(painter: _HatchPainter(c.bad, c.surface2)),
              ),
            Positioned(left: (w * e - 1).clamp(0, w - 2), top: 0, bottom: 0, width: 2, child: ColoredBox(color: c.ink)),
          ]),
        );
      }),
    );
  }
}
