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
import 'charts.dart' show RuledBar, dataEndRadius, snapPx, solidOver;
import 'common.dart';

/// One bar of a group. [overCents] is the last part of [cents] that is over a budget: drawn in `bad`.
class BarRod {
  final int cents;
  final Color color;
  final int overCents;
  const BarRod(this.cents, this.color, {this.overCents = 0});
}

/// Touch layer of a time graph: the text [tipAt] gives for the place under a mouse pointer or a long press (a fraction of the width,
/// 0..1) floats at the top, and a tap calls [onTapAt]. fl_chart's own touch handling is off for these graphs: its pan recognizer wins
/// the drag from the viewport.
class ChartTip extends StatefulWidget {
  final Widget child;
  final String? Function(double fraction) tipAt;
  final ValueChanged<double>? onTapAt;
  const ChartTip({super.key, required this.child, required this.tipAt, this.onTapAt});
  @override
  State<ChartTip> createState() => _ChartTipState();
}

class _ChartTipState extends State<ChartTip> {
  double? _at;

  void _set(Offset p, double w) {
    final f = (p.dx / math.max(1, w)).clamp(0.0, 1.0);
    if (_at != f) setState(() => _at = f);
  }

  void _clear() {
    if (_at != null) setState(() => _at = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final f = _at;
      final tip = f == null ? null : widget.tipAt(f);
      return Stack(children: [
        MouseRegion(
          onHover: (e) => _set(e.localPosition, w),
          onExit: (_) => _clear(),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPressStart: (d) => _set(d.localPosition, w),
            onLongPressMoveUpdate: (d) => _set(d.localPosition, w),
            onLongPressEnd: (_) => _clear(),
            onTapUp: widget.onTapAt == null ? null : (d) => widget.onTapAt!((d.localPosition.dx / math.max(1, w)).clamp(0.0, 1.0)),
            child: widget.child,
          ),
        ),
        if (tip != null && f != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment(f * 2 - 1, -1),
                child: Container(
                  key: const ValueKey('chartTip'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(2)),
                  child: Text(tip, style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.bg)),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

/// One bar of a time graph (a day, week, month or quarter): one to three rods side by side. A [partial] bar (not complete yet, or
/// cut by the window) is drawn faded with a dashed outline. [axis] is the text under it (one or two lines), [start] the first day
/// it covers, [tip] the tooltip, [spoken] what a screen reader says for it.
class BarGroup {
  final String start; // YYYY-MM-DD
  final String axis;
  final List<BarRod> rods;
  final bool partial;
  final String tip, spoken;
  const BarGroup(
      {required this.start, required this.axis, required this.rods, required this.partial, required this.tip, required this.spoken});
}

/// The axis text under a bar of [span]: the month and year of a month, `Q4` and the year of a quarter, the day (and the month
/// under the first one of a month) of a day, the first day and month of a week.
String barAxisText(DateRange span, Bucket b, {bool firstOfAll = false}) {
  final m = monthOf(span.start), d = dayOf(span.start);
  return switch (b) {
    Bucket.month => '${monthShort(m)}\n${m.substring(2, 4)}',
    Bucket.quarter => bucketLabel(span, b).replaceFirst(' ', '\n'),
    Bucket.week => '$d\n${monthShort(m)}',
    Bucket.day => d == 1 || firstOfAll ? '$d\n${monthShort(m)}' : '$d',
  };
}

/// A bar's name in the rows and the tooltip: "October 2026", "Q4 2026", "6–12 Oct", "20 Oct", with "· so far" when it holds [today] and
/// what makes it partial otherwise (not a whole week, part of the month).
String barName(DateRange span, Bucket b, bool partial, String today) {
  final base = switch (b) {
    Bucket.month => monthLong(monthOf(span.start)),
    Bucket.quarter => 'Q${(int.parse(span.start.substring(5, 7)) - 1) ~/ 3 + 1} ${span.start.substring(0, 4)}',
    Bucket.week => bucketLabel(span, b),
    Bucket.day => shortDateOrRaw(span.start),
  };
  if (!partial) return base;
  if (span.contains(today)) return '$base · so far';
  final note = switch (b) {
    Bucket.day => null,
    Bucket.week => 'not a whole week',
    Bucket.month => 'part of the month',
    Bucket.quarter => 'part of the quarter',
  };
  return note == null ? base : '$base · $note';
}

/// The legend words for a faded bar.
String barFadedText(Bucket b) => switch (b) {
      Bucket.day => 'Faded: today, not over yet',
      Bucket.week => 'Faded: not a whole week',
      Bucket.month => 'Faded: not a whole month',
      Bucket.quarter => 'Faded: not a whole quarter',
    };

/// The key part of a bar's row: the month (`2026-10`) for a month bar, else the first day.
String barRowId(DateRange span, Bucket b) => b == Bucket.month ? monthOf(span.start) : span.start;

/// Grouped bars over time with a zero line, any bar size ([Bucket]). [label] is what a screen reader says first; each group's
/// [BarGroup.spoken] follows, so the amounts are all heard. The exact amounts also sit in a list under the graph. [onOpen] is a tap on
/// a bar (its index).
class SeriesBars extends StatelessWidget {
  final List<BarGroup> groups;
  final String label;
  final ValueChanged<int>? onOpen;
  const SeriesBars({super.key, required this.groups, required this.label, this.onOpen});

  static const _height = 200.0, _labels = 34.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double px(double logical) => snapPx(logical, dpr);
    final n = groups.length;
    final values = [
      for (final g in groups)
        for (final r in g.rods) chartUnits(r.cents)
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
            // The text under a bar every few bars when they would touch.
            final longest = groups.fold<int>(1, (m, g) => math.max(m, g.axis.split('\n').map((l) => l.length).reduce(math.max)));
            final every = math.max(1, (n / math.max(1, (w / (longest * 7.0 + 10)).floor())).ceil());
            final chart = BarChart(
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
                        return Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(groups[i].axis,
                              textAlign: TextAlign.center,
                              style: labelStyle.copyWith(fontSize: BwType.metaSize, height: 1.15, color: c.muted)),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData:
                    const BarTouchData(enabled: false), // our own touch layer: fl_chart's pan would take the drag from the viewport
                barGroups: [
                  for (var i = 0; i < n; i++)
                    BarChartGroupData(x: i, barsSpace: px(2), barRods: [
                      for (final r in groups[i].rods) _rod(r, groups[i].partial, rodW, c, px),
                    ]),
                ],
              ),
            );
            if (n == 0) return chart;
            return ChartTip(
              tipAt: (f) => groups[(f * n).floor().clamp(0, n - 1)].tip,
              onTapAt: onOpen == null ? null : (f) => onOpen!((f * n).floor().clamp(0, n - 1)),
              child: chart,
            );
          }),
        ),
      ),
    );
  }

  BarChartRodData _rod(BarRod r, bool partial, double width, WalletColors c, double Function(double) px) {
    Color tint(Color x) => partial ? solidOver(x.withValues(alpha: 0.45), c.bg) : x;
    final v = chartUnits(r.cents);
    final over = r.overCents.clamp(0, r.cents > 0 ? r.cents : 0) / storageScale();
    return BarChartRodData(
      toY: v,
      width: width,
      color: tint(r.color),
      borderRadius: dataEndRadius(r.cents >= 0, px(4)),
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

  /// A thin line key instead of a square swatch, for a line series.
  final bool line;
  const LegendItem(this.color, this.text, {super.key, this.dashed = false, this.line = false});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (line)
        Container(width: 12, height: 2, color: color)
      else
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

  /// Where the names come from (null: the built-in names).
  final CategoryTable? table;
  const ShareBars({super.key, required this.share, required this.currency, this.onOpen, this.table});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final slices = share.slices;
    final cats = table ?? CategoryTable.builtIn;
    if (slices.isEmpty) return const EmptyNote('No spending in this range.');
    final top = slices.first.spent.clamp(1, 1 << 60);
    return Column(children: [
      for (final s in slices)
        Semantics(
          button: onOpen != null,
          label: '${cats.label(s.category)}: ${permilleText(s.permille)}, ${moneyExact(s.spent, currency)}',
          excludeSemantics: true,
          onTap: onOpen == null ? null : () => onOpen!(s.category),
          child: InkWell(
            key: ValueKey('shareRow_${s.category}'),
            onTap: onOpen == null ? null : () => onOpen!(s.category),
            child: RuledRow(
              minHeight: rowMin,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                  start: Text(cats.label(s.category),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: BwType.bodySize)),
                  end: MoneyText(moneyExact(s.spent, currency),
                      textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: RuledBar(value: s.spent / top, color: c.chartPos)),
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

/// Spent per extra tag as ruled bars (T1): the biggest tag is the full bar, and the number of payments sits on the right. Tags
/// overlap (a payment can have several), so there is no percent and the bars do not add up. Tap a row to open the tag.
class TagBars extends StatelessWidget {
  final TagShare share;
  final TagTable tags;
  final String currency;
  final ValueChanged<String>? onOpen;
  const TagBars({super.key, required this.share, required this.tags, required this.currency, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final slices = share.slices;
    if (slices.isEmpty) return const EmptyNote('No tagged spending in this range.');
    final top = slices.first.spent.clamp(1, 1 << 60);
    return Column(children: [
      for (final s in slices)
        Semantics(
          button: onOpen != null,
          label: '#${tags.label(s.tag)}: ${moneyExact(s.spent, currency)}, ${s.count} ${s.count == 1 ? 'payment' : 'payments'}',
          excludeSemantics: true,
          onTap: onOpen == null ? null : () => onOpen!(s.tag),
          child: InkWell(
            key: ValueKey('tagRow_${s.tag}'),
            onTap: onOpen == null ? null : () => onOpen!(s.tag),
            child: RuledRow(
              minHeight: rowMin,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                  start: Text('#${tags.label(s.tag)}',
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: BwType.bodySize)),
                  end: MoneyText(moneyExact(s.spent, currency),
                      textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: RuledBar(value: s.spent / top, color: c.chartPos)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text('${s.count} ${s.count == 1 ? 'payment' : 'payments'}',
                          style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
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
