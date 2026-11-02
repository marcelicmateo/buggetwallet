// The Explore line chart (ENG E4): one y-axis, up to a few series as lines, direct labels at the line ends, a crosshair with a tooltip that
// lists every series' exact value for the bucket under the finger or pointer. Draws only what it is given (core's `QueryRow`s); a running
// bucket is faded. The table under the chart carries the same values, so the chart itself is one spoken summary.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../theme.dart';
import 'common.dart';

/// One series of the chart: its name, colour and the value of each bucket (the same order as the chart's rows).
class ChartSeries {
  final String name;
  final Color color;
  final List<int> values;
  const ChartSeries(this.name, this.color, this.values);
}

/// The y-range of a set of values: from the lowest (or 0) to a round number above the highest, with 3 steps.
({int lo, int hi, int step}) niceRange(Iterable<int> values) {
  var lo = 0, hi = 0;
  for (final v in values) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  if (hi == lo) hi = lo + 3;
  final raw = (hi - lo) / 3;
  var mag = 1;
  while (mag * 10 <= raw) {
    mag *= 10;
  }
  final step = [1, 2, 5, 10].map((m) => m * mag).firstWhere((s) => s >= raw);
  return (lo: (lo / step).floor() * step, hi: (hi / step).ceil() * step, step: step);
}

class ExploreChart extends StatefulWidget {
  final List<DateRange> buckets;
  final List<bool> partial;
  final List<ChartSeries> series;

  /// The labels: a bucket on the axis and in the tooltip, a value in the tooltip, a value on the y-axis.
  final String Function(int bucket) bucketText;
  final String Function(int v) valueText;
  final String Function(int v) axisText;

  /// A shared y-range (small multiples); null = from this chart's own values.
  final ({int lo, int hi, int step})? range;
  final double height;
  final bool directLabels;
  final String spoken;
  const ExploreChart({
    super.key,
    required this.buckets,
    required this.partial,
    required this.series,
    required this.bucketText,
    required this.valueText,
    required this.axisText,
    required this.spoken,
    this.range,
    this.height = 260,
    this.directLabels = true,
  });
  @override
  State<ExploreChart> createState() => _ExploreChartState();
}

class _ExploreChartState extends State<ExploreChart> {
  int? _hover;

  @override
  void didUpdateWidget(ExploreChart old) {
    super.didUpdateWidget(old);
    if (old.buckets != widget.buckets) _hover = null;
  }

  static const double _left = 56, _top = 10, _bottom = 24;

  double _rightFor(double w) => widget.directLabels && w >= 520 ? 96 : 12;

  void _at(double dx, double w) {
    final n = widget.buckets.length;
    if (n == 0) return;
    final plotW = w - _left - _rightFor(w);
    final i = n == 1 ? 0 : (((dx - _left) / plotW) * (n - 1)).round().clamp(0, n - 1);
    if (i != _hover) setState(() => _hover = i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final range = widget.range ?? niceRange([for (final s in widget.series) ...s.values]);
    return Semantics(
      label: widget.spoken,
      image: true,
      child: ExcludeSemantics(
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth, h = widget.height;
          final right = _rightFor(w);
          final n = widget.buckets.length;
          final plot = Rect.fromLTRB(_left, _top, w - right, h - _bottom);
          double x(int i) => n == 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
          final hv = _hover;
          return SizedBox(
            height: h,
            child: MouseRegion(
              onHover: (e) => _at(e.localPosition.dx, w),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                key: const ValueKey('exploreChartArea'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _at(d.localPosition.dx, w),
                onHorizontalDragStart: (d) => _at(d.localPosition.dx, w),
                onHorizontalDragUpdate: (d) => _at(d.localPosition.dx, w),
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ChartPainter(
                        plot: plot,
                        range: range,
                        series: widget.series,
                        partial: widget.partial,
                        bucketText: widget.bucketText,
                        axisText: widget.axisText,
                        hover: hv,
                        labels: widget.directLabels && right > 12,
                        grid: c.chartGrid,
                        axis: c.lineStrong,
                        ink: c.ink,
                        muted: c.muted,
                        bg: c.surface,
                      ),
                    ),
                  ),
                  if (hv != null) _tooltip(context, x(hv), w),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _tooltip(BuildContext context, double hx, double w) {
    final c = context.c;
    final width = math.min(230.0, w - 8);
    final left = (hx + 12 + width > w ? hx - 12 - width : hx + 12).clamp(0.0, math.max(0.0, w - width)).toDouble();
    final i = _hover!;
    return Positioned(
      left: left,
      top: 4,
      width: width,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('exploreTip'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: c.bg, border: Border.all(color: c.lineStrong), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('${widget.bucketText(i)}${widget.partial[i] ? ' · so far' : ''}',
                key: const ValueKey('exploreTipTitle'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: BwType.metaSize)),
            for (var s = 0; s < widget.series.length; s++)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SplitRow(
                  start: Row(children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: widget.series[s].color, borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(widget.series[s].name,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: BwType.metaSize))),
                  ]),
                  end: Text(widget.valueText(widget.series[s].values[i]),
                      key: ValueKey('exploreTipValue:$s'), style: numStyle.copyWith(fontSize: BwType.metaSize), textAlign: TextAlign.end),
                  maxEnd: 0.6,
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final Rect plot;
  final ({int lo, int hi, int step}) range;
  final List<ChartSeries> series;
  final List<bool> partial;
  final String Function(int) bucketText, axisText;
  final int? hover;
  final bool labels;
  final Color grid, axis, ink, muted, bg;
  _ChartPainter({
    required this.plot,
    required this.range,
    required this.series,
    required this.partial,
    required this.bucketText,
    required this.axisText,
    required this.hover,
    required this.labels,
    required this.grid,
    required this.axis,
    required this.ink,
    required this.muted,
    required this.bg,
  });

  TextPainter _text(String s, Color color, double size, {double maxWidth = 200, String family = monoFamily}) => TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontFamily: family)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…')
    ..layout(maxWidth: maxWidth);

  @override
  void paint(Canvas canvas, Size size) {
    final n = series.isEmpty ? 0 : series.first.values.length;
    final span = (range.hi - range.lo).toDouble();
    double y(int v) => plot.bottom - (v - range.lo) / span * plot.height;
    double x(int i) => n <= 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var v = range.lo; v <= range.hi; v += range.step) {
      canvas.drawLine(
          Offset(plot.left, y(v)),
          Offset(plot.right, y(v)),
          v == 0
              ? (Paint()
                ..color = axis
                ..strokeWidth = 1)
              : gridPaint);
      final t = _text(axisText(v), muted, 11, maxWidth: plot.left - 6);
      t.paint(canvas, Offset(plot.left - 6 - t.width, y(v) - t.height / 2));
    }
    // x labels: as many as fit with room between them
    final every = math.max(1, (n / math.max(1, (plot.width / 74).floor())).ceil());
    for (var i = 0; i < n; i += every) {
      final t = _text(bucketText(i), muted, 11, maxWidth: 70, family: sansFamily);
      t.paint(canvas, Offset((x(i) - t.width / 2).clamp(0.0, size.width - t.width), plot.bottom + 6));
    }
    final ends = <(double, ChartSeries)>[];
    for (final s in series) {
      final line = Paint()
        ..color = s.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final solid = partial.isNotEmpty && partial.last && n > 1 ? n - 1 : n;
      final path = Path();
      for (var i = 0; i < solid; i++) {
        i == 0 ? path.moveTo(x(i), y(s.values[i])) : path.lineTo(x(i), y(s.values[i]));
      }
      if (n == 1) canvas.drawCircle(Offset(x(0), y(s.values[0])), 3, Paint()..color = s.color);
      canvas.drawPath(path, line);
      if (solid < n) {
        // the running bucket: its segment is faded and its marker hollow
        canvas.drawLine(
            Offset(x(n - 2), y(s.values[n - 2])), Offset(x(n - 1), y(s.values[n - 1])), line..color = s.color.withValues(alpha: 0.4));
        canvas.drawCircle(Offset(x(n - 1), y(s.values[n - 1])), 3.5, Paint()..color = bg);
        canvas.drawCircle(
            Offset(x(n - 1), y(s.values[n - 1])),
            3.5,
            Paint()
              ..color = s.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      if (n > 0) ends.add((y(s.values[n - 1]), s));
    }
    if (labels) {
      // direct labels at the line ends, pushed apart when closer than 14 px
      ends.sort((a, b) => a.$1.compareTo(b.$1));
      var prev = -1e9;
      for (final (ey, s) in ends) {
        final ly = math.max(ey, prev + 14);
        prev = ly;
        final t = _text(s.name, ink, 12, maxWidth: size.width - plot.right - 10, family: sansFamily);
        t.paint(canvas, Offset(plot.right + 8, ly - t.height / 2));
      }
    }
    final hv = hover;
    if (hv != null && hv < n) {
      canvas.drawLine(
          Offset(x(hv), plot.top),
          Offset(x(hv), plot.bottom),
          Paint()
            ..color = muted
            ..strokeWidth = 1);
      for (final s in series) {
        canvas.drawCircle(Offset(x(hv), y(s.values[hv])), 4, Paint()..color = s.color);
        canvas.drawCircle(
            Offset(x(hv), y(s.values[hv])),
            4,
            Paint()
              ..color = bg
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter o) =>
      o.hover != hover || o.series != series || o.plot != plot || o.range != range || o.grid != grid || o.ink != ink;
}
