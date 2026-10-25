// N0 bug (owner, laptop): the Spending chart looked grainy. Strokes of 1 and 2 dp cover fractional device pixels at 1.25 and
// 1.5 device pixels per dp, and translucent line, dots and fills mixed alpha where they overlap. The chart now snaps every
// stroke and bar to whole device pixels and draws the line opaque and straight. Structural checks, no golden files.
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

const _periods = [
  PeriodSummary(start: '2026-07-10', end: '2026-08-10', income: 140000, out: 100000, byCategory: {}, running: false),
  PeriodSummary(start: '2026-08-10', end: '2026-09-10', income: 140000, out: 160000, byCategory: {}, running: false),
  PeriodSummary(start: '2026-09-10', end: '2026-10-10', income: 140000, out: 90000, byCategory: {}, running: true),
];

bool _whole(double logical, double dpr) {
  final px = logical * dpr;
  return (px - px.roundToDouble()).abs() < 1e-6 && px.round() >= 1;
}

void main() {
  test('snapPx rounds to whole device pixels, at least one', () {
    expect(snapPx(1, 1.25), 1 / 1.25);
    expect(snapPx(2, 1.25) * 1.25, 3);
    expect(snapPx(1, 1.5) * 1.5, 2);
    expect(snapPx(0.1, 2) * 2, 1);
    expect(snapPx(2, 1), 2);
  });

  for (final dpr in const [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('chart strokes cover whole device pixels at $dpr', (t) async {
      t.view.physicalSize = const Size(600, 600) * dpr;
      t.view.devicePixelRatio = dpr;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: PeriodNetChart(periods: _periods, trend: [1000, null, -2000], currency: 'EUR')),
      ));

      final line = t.widget<LineChart>(find.byType(LineChart)).data.lineBarsData.single;
      expect(_whole(line.barWidth, dpr), isTrue, reason: 'line width ${line.barWidth} dp');
      expect(line.isCurved, isFalse, reason: 'straight segments: a curve overshoots the data');
      expect(line.color!.a, 1.0, reason: 'opaque, so it does not mix with the bars it crosses');
      final dot = line.dotData.getDotPainter(line.spots.first, 0, line, 0) as FlDotCirclePainter;
      expect(_whole(dot.radius * 2, dpr), isTrue, reason: 'dot diameter ${dot.radius * 2} dp');
      expect(dot.color.a, 1.0);

      final bars = t.widget<BarChart>(find.byType(BarChart)).data;
      for (final g in bars.barGroups) {
        for (final rod in g.barRods) {
          expect(_whole(rod.width, dpr), isTrue, reason: 'bar width ${rod.width} dp');
          expect(rod.color!.a, 1.0, reason: 'the running bar is an opaque tint, not alpha over its outline');
        }
      }
      final running = bars.barGroups.last.barRods.single;
      expect(_whole(running.borderSide.width, dpr), isTrue);
      for (final v in const [0.0, 500.0]) {
        expect(_whole(bars.gridData.getDrawingHorizontalLine(v).strokeWidth, dpr), isTrue, reason: 'grid line at $v');
      }
    });
  }
}
