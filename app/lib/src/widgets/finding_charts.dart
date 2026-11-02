// Evidence charts of a finding (ENG E3, docs/context/ENG_UI_SPEC.md §5.2): 7 weekday bars, a scatter with a dashed trend, a step line.
// Dumb widgets: the numbers they draw come as ints from core (through the controller) and are only scaled here; the exact values arrive
// preformatted as text and are in the semantics label. No colour carries meaning alone: every chart has its values in text.
import 'package:flutter/material.dart';

import '../theme.dart';

/// Seven bars (Monday first) with the day names under them; tap a bar to see its exact value. [texts] are the exact values.
class WeekBars extends StatefulWidget {
  final List<int> values;
  final List<String> texts;
  const WeekBars({super.key, required this.values, required this.texts});

  static const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  State<WeekBars> createState() => _WeekBarsState();
}

class _WeekBarsState extends State<WeekBars> {
  late int _sel = _top();

  int _top() {
    var t = 0;
    for (var i = 1; i < widget.values.length; i++) {
      if (widget.values[i] > widget.values[t]) t = i;
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hi = widget.values.fold<int>(1, (a, b) => b > a ? b : a);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 130,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.lineStrong))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < widget.values.length; i++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == _sel,
                  label: '${WeekBars.days[i]}, ${widget.texts[i]}',
                  excludeSemantics: true,
                  onTap: () => setState(() => _sel = i),
                  child: GestureDetector(
                    key: ValueKey('weekBar:$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _sel = i),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      if (i == _sel)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(6)),
                            child: Text(widget.texts[i],
                                key: const ValueKey('weekBarValue'), style: numStyle.copyWith(fontSize: 11, color: c.bg)),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Container(
                        width: 26,
                        height: 12 + 84 * widget.values[i] / hi,
                        decoration: BoxDecoration(
                          color: c.s1,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          border: i == _sel ? Border.all(color: c.ink, width: 2) : null,
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        for (final d in WeekBars.days)
          Expanded(child: Text(d, textAlign: TextAlign.center, maxLines: 1, style: TextStyle(fontSize: 12, color: c.muted))),
      ]),
    ]);
  }
}

/// Two series of the same months as dots, with a dashed least-squares line (drawn only) and the axis names under and over it.
class ScatterChart extends StatelessWidget {
  final List<int> xs, ys;
  final String xName, yName, semanticLabel;
  const ScatterChart(
      {super.key, required this.xs, required this.ys, required this.xName, required this.yName, required this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final label = TextStyle(fontSize: 12, color: c.muted);
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('$yName ↑', maxLines: 1, overflow: TextOverflow.ellipsis, style: label),
        const SizedBox(height: 4),
        SizedBox(height: 150, child: CustomPaint(painter: _ScatterPainter(xs, ys, c.s5, c.surface, c.muted, c.lineStrong))),
        const SizedBox(height: 4),
        Text('$xName →', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: label),
      ]),
    );
  }
}

class _ScatterPainter extends CustomPainter {
  final List<int> xs, ys;
  final Color dot, ring, trend, axis;
  _ScatterPainter(this.xs, this.ys, this.dot, this.ring, this.trend, this.axis);

  @override
  void paint(Canvas canvas, Size size) {
    final n = xs.length < ys.length ? xs.length : ys.length;
    if (n == 0) return;
    const pad = 8.0;
    double lo(List<int> v) => v.take(n).reduce((a, b) => a < b ? a : b).toDouble();
    double hi(List<int> v) => v.take(n).reduce((a, b) => a > b ? a : b).toDouble();
    final x0 = lo(xs), x1 = hi(xs), y0 = lo(ys), y1 = hi(ys);
    double px(int v) => pad + (size.width - 2 * pad) * (x1 == x0 ? 0.5 : (v - x0) / (x1 - x0));
    double py(int v) => size.height - pad - (size.height - 2 * pad) * (y1 == y0 ? 0.5 : (v - y0) / (y1 - y0));
    final axisPaint = Paint()
      ..color = axis
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1), axisPaint);
    canvas.drawLine(Offset.zero, Offset(0, size.height), axisPaint);
    // Least squares on the screen positions: only for the dashed line, no figure comes from it.
    var mx = 0.0, my = 0.0;
    for (var i = 0; i < n; i++) {
      mx += px(xs[i]);
      my += py(ys[i]);
    }
    mx /= n;
    my /= n;
    var sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < n; i++) {
      sxx += (px(xs[i]) - mx) * (px(xs[i]) - mx);
      sxy += (px(xs[i]) - mx) * (py(ys[i]) - my);
    }
    if (sxx > 0) {
      final k = sxy / sxx;
      final xa = pad, xb = size.width - pad;
      _dashed(
          canvas,
          Offset(xa, my + k * (xa - mx)),
          Offset(xb, my + k * (xb - mx)),
          Paint()
            ..color = trend
            ..strokeWidth = 1.5);
    }
    for (var i = 0; i < n; i++) {
      final p = Offset(px(xs[i]), py(ys[i]));
      canvas.drawCircle(p, 6, Paint()..color = ring);
      canvas.drawCircle(p, 4.5, Paint()..color = dot);
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final d = b - a, len = d.distance;
    if (len == 0) return;
    final u = d / len;
    for (var t = 0.0; t < len; t += 8) {
      canvas.drawLine(a + u * t, a + u * (t + 4 > len ? len : t + 4), paint);
    }
  }

  @override
  bool shouldRepaint(_ScatterPainter old) => old.xs != xs || old.ys != ys || old.dot != dot || old.ring != ring || old.trend != trend;
}

/// A step line of [values] (one per month the payments existed), the first and last value written under its two ends.
class StepLine extends StatelessWidget {
  final List<int> values;
  final String firstText, lastText, semanticLabel;
  const StepLine({super.key, required this.values, required this.firstText, required this.lastText, required this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 80, child: CustomPaint(painter: _StepPainter(values, c.s1))),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(firstText, key: const ValueKey('stepFirst'), style: numStyle.copyWith(fontSize: 12, color: c.muted))),
          const SizedBox(width: 8),
          Flexible(
              child: Text(lastText,
                  key: const ValueKey('stepLast'), textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: 12, color: c.ink))),
        ]),
      ]),
    );
  }
}

class _StepPainter extends CustomPainter {
  final List<int> values;
  final Color color;
  _StepPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final lo = values.reduce((a, b) => a < b ? a : b), hi = values.reduce((a, b) => a > b ? a : b);
    const pad = 6.0;
    double y(int v) => hi == lo ? size.height / 2 : size.height - pad - (size.height - 2 * pad) * (v - lo) / (hi - lo);
    double x(int i) => values.length == 1 ? size.width : size.width * i / (values.length - 1);
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i - 1]));
      path.lineTo(x(i), y(values[i]));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_StepPainter old) => old.values != values || old.color != color;
}
