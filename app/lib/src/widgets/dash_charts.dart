// Small charts for the dashboard tiles (RX2; kit in `dash.dart`). Values come in already formatted or as plain numbers to draw;
// nothing here reads the controller or decides what a number means. Strokes snap to whole device pixels (`snapPx`); colours are
// opaque; a state is never colour alone (position, hatch, dash, icon or word says it too).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';
import 'charts.dart' show snapPx, solidOver;
import 'common.dart';
import 'dash.dart';

/// A progress ring with something in the middle (usually a percent). [progress] 0..1 (more is drawn as full).
class Ring extends StatelessWidget {
  final double progress;
  final Color? color;
  final double size, stroke;
  final Widget? child;
  final String? semanticLabel;
  const Ring({super.key, required this.progress, this.color, this.size = 84, this.stroke = 8, this.child, this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final px = snapPx(stroke, MediaQuery.devicePixelRatioOf(context));
    return Semantics(
      label: semanticLabel,
      container: semanticLabel != null,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0, color ?? c.s1, c.line, px),
          child: Padding(padding: EdgeInsets.all(stroke + (size < 60 ? 2 : 4)), child: Center(child: child)),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress, stroke;
  final Color color, track;
  _RingPainter(this.progress, this.color, this.track, this.stroke);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 2 * math.pi, false, p..color = track);
    if (progress > 0) {
      canvas.drawArc(
          rect,
          -math.pi / 2,
          2 * math.pi * progress,
          false,
          p
            ..color = color
            ..strokeCap = progress >= 1 ? StrokeCap.butt : StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color || old.track != track || old.stroke != stroke;
}

/// A ring tile: label, the ring with [center] inside (a percent), the exact [value] and a sub line. [compact] puts a 44 dp ring beside
/// the value instead of a big one above it, so goal and budget tiles stay short.
class RingTile extends StatelessWidget {
  final String label, center, value;
  final String? sub;
  final double progress;
  final Color? color;
  final DashChip? chip, trailing;
  final VoidCallback? onTap;
  final bool compact, attention;
  const RingTile({
    super.key,
    required this.label,
    required this.center,
    required this.value,
    required this.progress,
    this.sub,
    this.color,
    this.chip,
    this.trailing,
    this.onTap,
    this.compact = false,
    this.attention = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final valueText = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(value, maxLines: 1, style: dashNumStyle(size: BwType.amountMdSize, color: c.ink)),
    );
    final subText = sub == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(sub!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          );
    return Tile(
      onTap: onTap,
      attention: attention,
      // An empty centre (the goal rings) is skipped, not spoken as a gap.
      semanticLabel: [label, center, value, sub, trailing?.spoken, chip?.spoken].whereType<String>().where((p) => p.isNotEmpty).join(', '),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        trailing == null ? TileLabel(label) : SplitRow(start: TileLabel(label), end: trailing!),
        const SizedBox(height: 8),
        if (compact)
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Ring(
              progress: progress,
              color: color,
              size: 44,
              stroke: 4,
              child: FittedBox(
                  fit: BoxFit.scaleDown, child: Text(center, maxLines: 1, style: dashNumStyle(size: BwType.eyebrowSize, color: c.ink))),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [valueText, if (subText != null) subText])),
          ])
        else ...[
          Center(
            child: Ring(
              progress: progress,
              color: color,
              child: FittedBox(
                  fit: BoxFit.scaleDown, child: Text(center, maxLines: 1, style: dashNumStyle(size: BwType.headingSize, color: c.ink))),
            ),
          ),
          const SizedBox(height: 8),
          valueText,
          if (subText != null) subText,
        ],
        if (chip != null) Padding(padding: const EdgeInsets.only(top: 8), child: chip),
      ]),
    );
  }
}

/// A line of [values] (oldest first) with a dot on the [marked] one (default: the last). No axes: the number it belongs to is in the
/// tile. When an earlier value is marked, the last one keeps a small plain dot so the line still ends somewhere.
class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color? color;
  final double height;
  final int? marked;
  final String? semanticLabel;
  const Sparkline({super.key, required this.values, this.color, this.height = 40, this.marked, this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      label: semanticLabel,
      container: semanticLabel != null,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: _SparkPainter(values, marked, color ?? c.s1, c.surface, snapPx(2, dpr))),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final int? marked;
  final Color color, ground;
  final double stroke;
  _SparkPainter(this.values, this.marked, this.color, this.ground, this.stroke);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    const r = 3.5, pad = r + 2;
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final span = hi - lo;
    double x(int i) => values.length == 1 ? size.width - pad : pad + (size.width - 2 * pad) * i / (values.length - 1);
    double y(double v) => span == 0 ? size.height / 2 : size.height - pad - (size.height - 2 * pad) * (v - lo) / span;
    if (values.length > 1) {
      final path = Path()..moveTo(x(0), y(values[0]));
      for (var i = 1; i < values.length; i++) {
        path.lineTo(x(i), y(values[i]));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    final last = values.length - 1;
    final at = (marked ?? last).clamp(0, last);
    if (at != last) canvas.drawCircle(Offset(x(last), y(values.last)), 2, Paint()..color = color);
    final dot = Offset(x(at), y(values[at]));
    canvas.drawCircle(dot, r + 1.5, Paint()..color = ground);
    canvas.drawCircle(dot, r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.marked != marked || old.color != color || old.ground != ground || old.stroke != stroke;
}

/// One part of a [SplitBar] or [Donut]: [weight] sets its size, [value] is the exact text shown next to its [label].
class DashSegment {
  final String label, value;
  final double weight;
  final Color color;
  const DashSegment({required this.label, required this.value, required this.weight, required this.color});

  /// [weight] made safe to draw: not finite or negative counts as 0.
  double get share => weight.isFinite && weight > 0 ? weight : 0;
}

/// The colour key with the values: a swatch, the label and the exact value, wrapping on narrow tiles.
class DashLegend extends StatelessWidget {
  final List<DashSegment> segments;
  const DashLegend(this.segments, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Wrap(spacing: 14, runSpacing: 4, children: [
      for (final s in segments)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: s.label, style: TextStyle(color: c.ink2)),
                const TextSpan(text: ' '),
                TextSpan(text: s.value, style: numStyle.copyWith(color: c.ink, fontWeight: FontWeight.w500)),
              ]),
              style: const TextStyle(fontSize: BwType.metaSize),
            ),
          ),
        ]),
    ]);
  }
}

String _spoken(List<DashSegment> s) => s.map((e) => '${e.label} ${e.value}').join(', ');

/// A horizontal bar cut into [segments] by 2 dp gaps (sizes by weight), with the legend and its values under it.
class SplitBar extends StatelessWidget {
  final List<DashSegment> segments;
  final double height;
  final bool legend;
  const SplitBar({super.key, required this.segments, this.height = 12, this.legend = true});

  @override
  Widget build(BuildContext context) {
    final shown = segments.where((s) => s.share > 0).toList();
    return Semantics(
      container: true,
      label: _spoken(segments),
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: SizedBox(
            height: height,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(flex: math.max(1, (shown[i].share * 1000).round()), child: ColoredBox(color: shown[i].color)),
              ],
            ]),
          ),
        ),
        if (legend) ...[const SizedBox(height: 8), DashLegend(segments)],
      ]),
    );
  }
}

/// A ring cut into [segments] by 2 dp gaps, [center] inside, the legend with values under it.
class Donut extends StatelessWidget {
  final List<DashSegment> segments;
  final Widget? center;
  final double size, stroke;
  const Donut({super.key, required this.segments, this.center, this.size = 132, this.stroke = 16});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: _spoken(segments),
      excludeSemantics: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _DonutPainter(segments.where((s) => s.share > 0).toList(), stroke),
            child: Padding(padding: EdgeInsets.all(stroke + 6), child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: center))),
          ),
        ),
        const SizedBox(height: 10),
        DashLegend(segments),
      ]),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<DashSegment> segments;
  final double stroke;
  _DonutPainter(this.segments, this.stroke);
  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold<double>(0, (a, s) => a + s.share);
    if (total <= 0) return;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final radius = rect.width / 2;
    // 2 dp gaps measured on the middle of the ring.
    final gap = segments.length > 1 ? 2 / radius : 0.0;
    final avail = 2 * math.pi - gap * segments.length;
    var at = -math.pi / 2 + gap / 2;
    for (final s in segments) {
      final sweep = avail * s.share / total;
      canvas.drawArc(
        rect,
        at,
        sweep,
        false,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      );
      at += sweep + gap;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.segments != segments || old.stroke != stroke;
}

/// Diagonal lines over [ground]: "over" and "lost" stay readable without colour.
class HatchPainter extends CustomPainter {
  final Color color, ground;
  const HatchPainter(this.color, this.ground);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (var x = -size.height; x < size.width + size.height; x += 5) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(HatchPainter old) => old.color != color || old.ground != ground;
}

/// One budget meter of a [BarList]. [fraction] is spent / budget (a number that is not finite or is negative counts as 0; more than 1
/// = over, [over] is derived from it); [value] and [note] are shown as given ("48 € left", "Over by 12 €").
class BarRow {
  final String label, value, note;
  final double fraction;
  final Color? color;
  final VoidCallback? onTap;
  final Key? key;
  const BarRow({required this.label, required this.value, required this.note, required this.fraction, this.color, this.onTap, this.key});

  /// [fraction] made safe to draw.
  double get ratio => fraction.isFinite && fraction > 0 ? fraction : 0;
  bool get over => ratio > 1;
}

/// Budget meters: name and exact amount, a track with a fill, a note. The bar is the budget; when over, the fill is solid up to the
/// budget mark (a 2 px tick) and hatched beyond it, and the note carries a warning icon and bold words, so colour is never the only cue.
class BarList extends StatelessWidget {
  final List<BarRow> rows;
  const BarList({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final r in rows)
        Semantics(
          container: true,
          button: r.onTap != null,
          label: '${r.label}, ${r.value}, ${r.note}',
          onTap: r.onTap,
          excludeSemantics: true,
          child: InkWell(
            key: r.key,
            onTap: r.onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: r.onTap != null ? touchMin : 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SplitRow(
                    start: Text(r.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: BwType.bodySize)),
                    end: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(r.value, maxLines: 1, style: BwType.amount.copyWith(color: c.ink, fontSize: BwType.bodySize)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      height: 8,
                      child: LayoutBuilder(builder: (context, box) {
                        final w = box.maxWidth;
                        final budgetAt = r.over ? w / r.ratio : w; // where 100 % of the budget is
                        return Stack(children: [
                          Positioned.fill(child: ColoredBox(color: c.line)),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: r.over ? budgetAt : w * r.ratio.clamp(0.0, 1.0),
                            child: ColoredBox(color: r.color ?? c.s1),
                          ),
                          if (r.over) ...[
                            Positioned(
                                left: budgetAt, top: 0, bottom: 0, right: 0, child: CustomPaint(painter: HatchPainter(c.bad, c.badSoft))),
                            Positioned(
                                left: (budgetAt - 1).clamp(0.0, w - 2), top: 0, bottom: 0, width: 2, child: ColoredBox(color: c.ink)),
                          ],
                        ]);
                      }),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (r.over)
                      Padding(
                          padding: const EdgeInsets.only(right: 3, top: 1),
                          child: Icon(Icons.warning_amber_rounded, size: 15, color: c.bad)),
                    Expanded(
                      child: Text(r.note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: BwType.metaSize,
                              fontWeight: r.over ? FontWeight.w600 : FontWeight.w400,
                              color: r.over ? c.bad : c.muted)),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// A pace meter: the bar is the whole period, the fill is the share of money [used], a 2 px tick is where the period [expected] to be
/// (both 0..1; not finite counts as 0). When [over], the fill is solid up to the tick and hatched beyond it.
class PaceMeter extends StatelessWidget {
  final double used, expected;
  final bool over;
  final String? semanticLabel;
  const PaceMeter({super.key, required this.used, required this.expected, this.over = false, this.semanticLabel});

  static double _unit(double v) => v.isFinite ? v.clamp(0.0, 1.0) : 0.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final u = _unit(used), e = _unit(expected);
    return Semantics(
      label: semanticLabel,
      container: semanticLabel != null,
      excludeSemantics: semanticLabel != null,
      child: SizedBox(
        height: 16,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final solid = over ? math.min(u, e) : u;
          return Stack(clipBehavior: Clip.none, children: [
            Positioned(
              left: 0,
              right: 0,
              top: 3,
              height: 10,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Stack(children: [
                  Positioned.fill(child: ColoredBox(color: c.line)),
                  Positioned(left: 0, top: 0, bottom: 0, width: w * solid, child: ColoredBox(color: c.s1)),
                  if (over && u > e)
                    Positioned(
                        left: w * e, top: 0, bottom: 0, width: w * (u - e), child: CustomPaint(painter: HatchPainter(c.bad, c.badSoft))),
                ]),
              ),
            ),
            Positioned(left: (w * e - 1).clamp(0.0, math.max(0.0, w - 2)), top: 0, bottom: 0, width: 2, child: ColoredBox(color: c.ink)),
          ]);
        }),
      ),
    );
  }
}

/// One bar of [NetBars]: [cents] only sets how tall it is (kept above the line, lost below and hatched); [value] is the exact text
/// shown under its label ("180.16 €", "−80 €"), formatted by the caller; [running] = the period still going (faded, dashed).
class NetBar {
  final String label, value;
  final int cents;
  final bool running;
  const NetBar({required this.label, required this.value, required this.cents, this.running = false});
}

/// Kept or lost per period as bars around a zero line; label and exact value under each. Heights scale to the largest bar. Each bar
/// gets at least [minCell] dp for its label and value (the value scales down inside the cell, with [cellGap] dp on each side so
/// neighbours never touch): when [bars] do not all fit, the newest ones are shown.
class NetBars extends StatelessWidget {
  final List<NetBar> bars;
  final double height;
  final double minCell;
  static const cellGap = 3.0;
  const NetBars({super.key, required this.bars, this.height = 96, this.minCell = 56});

  /// How many of [count] bars fit in [width].
  static int fit(double width, int count, double minCell) =>
      width.isFinite ? math.max(1, math.min(count, (width / minCell).floor())) : count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, box) {
      final n = fit(box.maxWidth, bars.length, minCell);
      final shown = bars.length > n ? bars.sublist(bars.length - n) : bars;
      return Semantics(
        container: true,
        label: [for (final b in shown) '${b.label} ${b.cents >= 0 ? 'kept' : 'lost'} ${b.value}${b.running ? ' so far' : ''}'].join(', '),
        excludeSemantics: true,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(painter: _NetPainter(shown, c.s3, c.bad, c.surface, c.lineStrong, snapPx(1, dpr))),
          ),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final b in shown)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: cellGap),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(b.label, maxLines: 1, style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.muted)),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(b.value,
                          maxLines: 1, style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w500, color: c.ink)),
                    ),
                  ]),
                ),
              ),
          ]),
        ]),
      );
    });
  }
}

class _NetPainter extends CustomPainter {
  final List<NetBar> bars;
  final Color kept, lost, ground, axis;
  final double hair;
  _NetPainter(this.bars, this.kept, this.lost, this.ground, this.axis, this.hair);
  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final maxUp = bars.fold<int>(0, (a, b) => b.cents > a ? b.cents : a);
    final maxDown = bars.fold<int>(0, (a, b) => -b.cents > a ? -b.cents : a);
    final total = math.max(1, maxUp + maxDown);
    final zeroY = (size.height * maxUp / total).clamp(0.0, size.height);
    final unit = size.height / total;
    final slot = size.width / bars.length;
    final bw = math.min(slot * 0.6, 28.0);
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final h = math.max(b.cents == 0 ? 0.0 : 2.0, b.cents.abs() * unit);
      final left = slot * i + (slot - bw) / 2;
      final rect = b.cents >= 0 ? Rect.fromLTWH(left, zeroY - h, bw, h) : Rect.fromLTWH(left, zeroY, bw, h);
      final rr = RRect.fromRectAndCorners(
        rect,
        topLeft: b.cents >= 0 ? const Radius.circular(3) : Radius.zero,
        topRight: b.cents >= 0 ? const Radius.circular(3) : Radius.zero,
        bottomLeft: b.cents < 0 ? const Radius.circular(3) : Radius.zero,
        bottomRight: b.cents < 0 ? const Radius.circular(3) : Radius.zero,
      );
      final base = b.cents >= 0 ? kept : lost;
      canvas.save();
      canvas.clipRRect(rr);
      if (b.cents < 0) {
        canvas.translate(rect.left, rect.top);
        HatchPainter(lost, solidOver(lost.withValues(alpha: 0.18), ground)).paint(canvas, rect.size);
      } else {
        canvas.drawRect(rect, Paint()..color = b.running ? solidOver(base.withValues(alpha: 0.35), ground) : base);
      }
      canvas.restore();
      if (b.running || b.cents < 0) {
        canvas.drawRRect(
          rr.deflate(hair / 2),
          Paint()
            ..color = base
            ..style = PaintingStyle.stroke
            ..strokeWidth = hair,
        );
      }
    }
    canvas.drawLine(
        Offset(0, zeroY),
        Offset(size.width, zeroY),
        Paint()
          ..color = axis
          ..strokeWidth = hair);
  }

  @override
  bool shouldRepaint(_NetPainter old) => old.bars != bars || old.kept != kept || old.lost != lost || old.hair != hair;
}

enum CalKind { none, bill, planned, payday }

/// A day of a [CalendarStrip]: [label] is the day number as shown, [amount] an optional short preformatted text under it (the cost
/// of that day), shown at its own size or left out when it would not fit (the day number never shrinks for it). [overdue] marks a
/// cell that holds costs already past due (a warning icon on the cell and "Overdue" in the legend: not colour alone).
class CalDay {
  final String label;
  final CalKind kind;
  final bool today;
  final String? amount;
  final bool overdue;
  const CalDay(this.label, {this.kind = CalKind.none, this.today = false, this.amount, this.overdue = false});
}

/// The days until payday as small squares: a bill = filled, a planned cost = dashed, payday = dashed teal with a flag, today = a bar
/// under the number. With [startWeekday] (1 = Monday .. 7 = Sunday, the weekday of the first day) the days sit in Monday-first
/// weekday columns under a one-letter header, like a calendar; without it they flow like a strip. [semanticLabel] says it in words
/// (the caller knows the names and amounts).
class CalendarStrip extends StatelessWidget {
  final List<CalDay> days;
  final int? startWeekday;
  final List<String> weekdayLabels;
  final String? semanticLabel;
  final bool legend;
  const CalendarStrip({
    super.key,
    required this.days,
    this.startWeekday,
    this.weekdayLabels = const ['M', 'T', 'W', 'T', 'F', 'S', 'S'],
    this.semanticLabel,
    this.legend = true,
  });

  static const _gap = 4.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final scaler = MediaQuery.textScalerOf(context);
    final base = scaler.scale(30).clamp(30.0, 44.0);
    final hasAmount = days.any((d) => d.amount != null);
    // A cell is as tall as its content needs at this text scale (the number never shrinks to fit): the day number, a flag or warning
    // icon above it where a day has one, an amount under it where one day has one.
    final dts = DefaultTextStyle.of(context).style;
    double lineH(TextStyle st) =>
        (TextPainter(text: TextSpan(text: '0', style: dts.merge(st)), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)
              ..layout())
            .height;
    final hasMark = days.any((d) => d.kind == CalKind.payday || d.overdue);
    final need = 4 +
        lineH(numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w700)) +
        (hasMark ? 10 : 0) +
        (hasAmount ? lineH(numStyle.copyWith(fontSize: BwType.eyebrowSize)) : 0);
    final oldHeight = hasAmount ? base + scaler.scale(BwType.eyebrowSize) * 1.2 + 2 : base;
    final height = need > oldHeight ? need : oldHeight;
    final kinds = days.map((d) => d.kind).toSet();
    final Widget cells;
    if (startWeekday == null) {
      cells = Wrap(spacing: _gap, runSpacing: _gap, children: [for (final d in days) _CalCell(d, width: base, height: height)]);
    } else {
      final lead = (startWeekday! - 1).clamp(0, 6);
      final rows = (lead + days.length + 6) ~/ 7;
      Widget line(Widget Function(int col) cell) => Row(children: [
            for (var col = 0; col < 7; col++) ...[
              if (col > 0) const SizedBox(width: _gap),
              Expanded(child: cell(col)),
            ],
          ]);
      cells = Column(mainAxisSize: MainAxisSize.min, children: [
        ExcludeSemantics(
          child: line((col) => Center(
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(weekdayLabels[col], style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.muted))),
              )),
        ),
        for (var r = 0; r < rows; r++)
          Padding(
            padding: const EdgeInsets.only(top: _gap),
            child: line((col) {
              final i = r * 7 + col - lead;
              return i >= 0 && i < days.length ? _CalCell(days[i], height: height) : SizedBox(height: height);
            }),
          ),
      ]);
    }
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        cells,
        if (legend && kinds.any((k) => k != CalKind.none)) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: [
            if (kinds.contains(CalKind.bill)) _CalKey(const CalDay('', kind: CalKind.bill), 'Bill', c),
            if (kinds.contains(CalKind.planned)) _CalKey(const CalDay('', kind: CalKind.planned), 'Planned', c),
            if (kinds.contains(CalKind.payday)) _CalKey(const CalDay('', kind: CalKind.payday), 'Payday', c),
            if (days.any((d) => d.overdue))
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: c.bad),
                const SizedBox(width: 6),
                Text('Overdue', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
              ]),
          ]),
        ],
      ]),
    );
  }
}

class _CalKey extends StatelessWidget {
  final CalDay day;
  final String text;
  final WalletColors c;
  const _CalKey(this.day, this.text, this.c);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        _CalCell(day, width: 16, height: 16),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
      ]);
}

class _CalCell extends StatelessWidget {
  final CalDay day;
  final double? width;
  final double height;
  const _CalCell(this.day, {this.width, required this.height});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final painter = switch (day.kind) {
      CalKind.none => DashedBorderPainter(color: c.line, radius: 4, width: 1, dash: null),
      CalKind.bill =>
        DashedBorderPainter(color: c.s2, radius: 4, width: 2, dash: null, fill: solidOver(c.s2.withValues(alpha: 0.22), c.surface)),
      CalKind.planned => DashedBorderPainter(color: c.s2, radius: 4, width: 1.5, dash: 3),
      CalKind.payday =>
        DashedBorderPainter(color: c.s3, radius: 4, width: 2, dash: 3, fill: solidOver(c.s3.withValues(alpha: 0.18), c.surface)),
    };
    final ink = day.kind == CalKind.none ? c.muted : c.ink;
    final scaler = MediaQuery.textScalerOf(context);
    final numStyleDay = numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: day.today ? FontWeight.w700 : FontWeight.w400, color: ink);
    final amountStyle = numStyle.copyWith(fontSize: BwType.eyebrowSize, color: c.ink2);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: painter,
        child: height < 20
            ? null
            : LayoutBuilder(builder: (context, box) {
                // The day number is scaled on its own (only when it cannot fit at all). The amount is shown only when it fits at
                // about its own size (not under 80 %) and under the number; otherwise it is left out (Upcoming and the spoken label
                // have it).
                const pad = 2.0;
                // The same style the Text widgets resolve (the theme's default height included), so what is measured is what is drawn.
                final base = DefaultTextStyle.of(context).style;
                final availW = box.maxWidth - 2 * pad, availH = box.maxHeight - 2 * pad;
                final mark = day.kind == CalKind.payday || day.overdue ? 10.0 : 0.0;
                double textH(String t, TextStyle st) {
                  final tp = TextPainter(
                      text: TextSpan(text: t, style: base.merge(st)), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)
                    ..layout();
                  return tp.height;
                }

                double textW(String t, TextStyle st) {
                  final tp = TextPainter(
                      text: TextSpan(text: t, style: base.merge(st)), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)
                    ..layout();
                  return tp.width;
                }

                final numH = textH(day.label, numStyleDay);
                final amount = day.amount;
                final showAmount =
                    amount != null && availW / textW(amount, amountStyle) >= 0.8 && mark + numH + textH(amount, amountStyle) <= availH;
                return Stack(alignment: Alignment.center, children: [
                  Padding(
                    padding: const EdgeInsets.all(pad),
                    child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                      if (day.kind == CalKind.payday) Icon(Icons.flag, size: 10, color: c.s3),
                      if (day.overdue) Icon(Icons.warning_amber_rounded, size: 10, color: c.bad),
                      FittedBox(fit: BoxFit.scaleDown, child: Text(day.label, maxLines: 1, style: numStyleDay)),
                      if (showAmount) FittedBox(fit: BoxFit.scaleDown, child: Text(amount, maxLines: 1, style: amountStyle)),
                    ]),
                  ),
                  if (day.today) Positioned(left: 6, right: 6, bottom: 3, height: 3, child: ColoredBox(color: c.ink)),
                ]);
              }),
      ),
    );
  }
}
