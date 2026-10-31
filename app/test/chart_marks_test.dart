// Chart marks (stage C2b): the legend under the pay-period chart, bar ends rounded 4 px at the data end and square at the baseline,
// the balance chart's tooltip, end label and spoken text, and the chart colours (income "went out" is not the status red).
// Structural checks, no golden files.
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:budget_wallet/src/widgets/insight_charts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'insights_test.dart' show insightsWallet, pump;

const _periods = [
  PeriodSummary(start: '2026-07-10', end: '2026-08-10', income: 140000, out: 100000, byCategory: {}, running: false),
  PeriodSummary(start: '2026-08-10', end: '2026-09-10', income: 140000, out: 160000, byCategory: {}, running: false),
  PeriodSummary(start: '2026-09-10', end: '2026-10-10', income: 140000, out: 90000, byCategory: {}, running: true),
];

const _points = [
  ForecastPoint('2026-10-20', 100000, null),
  ForecastPoint('2026-10-25', 70000, 'Synthetic phone', causeId: 'b1', delta: -30000),
  ForecastPoint('2026-10-28', -5000, 'Synthetic rent', causeId: 'b2', delta: -75000),
];

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(theme: buildTheme(brightness), home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('the pay-period chart has a legend: Saved, Lost, Average, Faded running period', (t) async {
    await t.pumpWidget(_app(const PeriodNetLegend(periods: _periods, trend: [1000, 1500, -2000])));
    for (final word in const ['Saved', 'Lost', 'Average', 'Faded: running period']) {
      expect(find.text(word), findsOneWidget, reason: word);
    }
  });

  testWidgets('the legend names only what is drawn', (t) async {
    await t.pumpWidget(_app(PeriodNetLegend(periods: [_periods.first], trend: const [null])));
    expect(find.text('Average'), findsNothing);
    expect(find.text('Faded: running period'), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Lost'), findsNothing, reason: 'no period lost money');
  });

  testWidgets('Lost only when a period lost; Average only when a line is drawn (two neighbouring points)', (t) async {
    const lost = PeriodSummary(start: '2026-08-10', end: '2026-09-10', income: 1000, out: 5000, byCategory: {}, running: false);
    await t.pumpWidget(_app(const PeriodNetLegend(periods: [lost], trend: [1000])));
    expect(find.text('Lost'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    expect(find.text('Average'), findsNothing, reason: 'one point draws no line');
    await t.pumpWidget(_app(const PeriodNetLegend(periods: _periods, trend: [1000, null, 2000])));
    expect(find.text('Average'), findsNothing, reason: 'isolated points draw no line');
    await t.pumpWidget(_app(const PeriodNetLegend(periods: _periods, trend: [1000, 1500, null])));
    expect(find.text('Average'), findsOneWidget);
  });

  testWidgets('legend and forecast end label fit 320 dp at text scale 2', (t) async {
    t.view.physicalSize = const Size(320, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: c!),
      home: const Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            PeriodNetLegend(periods: _periods, trend: [1000, 1500, -2000]),
            ForecastStepChart(points: _points, payday: '2026-10-28', currency: 'EUR'),
          ]),
        ),
      ),
    ));
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('forecastEndLabel')), findsOneWidget);
    expect(find.text('Faded: running period'), findsOneWidget);
  });

  testWidgets('pay-period bars: 4 px round at the data end, square at the zero line, in the chart colours', (t) async {
    await t.pumpWidget(_app(const PeriodNetChart(periods: _periods, trend: [1000, null, -2000], currency: 'EUR')));
    const c = WalletColors.light;
    final rods = [for (final g in t.widget<BarChart>(find.byType(BarChart)).data.barGroups) g.barRods.single];
    expect(rods[0].borderRadius, const BorderRadius.vertical(top: Radius.circular(4))); // saved: top
    expect(rods[1].borderRadius, const BorderRadius.vertical(bottom: Radius.circular(4))); // lost: bottom
    expect(rods[0].color, c.chartPos);
    expect(rods[1].color, c.chartNeg);
  });

  testWidgets('monthly bars: 4 px round at the data end, square at the baseline', (t) async {
    await t.pumpWidget(_app(const SeriesBars(
      label: 'Spending per month',
      groups: [
        BarGroup(start: '2026-08-01', axis: 'Aug\n26', rods: [BarRod(5000, Colors.blue)], partial: false, tip: 'a', spoken: 'a'),
        BarGroup(start: '2026-09-01', axis: 'Sep\n26', rods: [BarRod(-3000, Colors.blue)], partial: false, tip: 'b', spoken: 'b'),
      ],
    )));
    final groups = t.widget<BarChart>(find.byType(BarChart)).data.barGroups;
    expect(groups[0].barRods.single.borderRadius, const BorderRadius.vertical(top: Radius.circular(4)));
    expect(groups[1].barRods.single.borderRadius, const BorderRadius.vertical(bottom: Radius.circular(4)));
  });

  group('ForecastStepChart', () {
    testWidgets('has a spoken text (start, lowest, payday), an end label and a tooltip with date and balance', (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_app(const ForecastStepChart(points: _points, payday: '2026-10-28', currency: 'EUR')));
      final label = t.getSemantics(find.bySemanticsLabel(RegExp('^Balance until payday')).first).label;
      expect(label, startsWith('Balance until payday.'));
      expect(label, contains('Starts at 1,000'));
      expect(label, contains('lowest −50')); // the dip below zero
      expect(label, contains('on payday −50'));
      expect(find.byKey(const ValueKey('forecastEndLabel')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('forecastEndLabel'))).data, contains('−50'));

      // fl_chart's own touch is off (its pan would take the drag); a pointer over the chart floats the date and the balance in force.
      expect(t.widget<LineChart>(find.byType(LineChart)).data.lineTouchData.enabled, isFalse);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      final box = t.getRect(find.byType(LineChart));
      await t.sendEventToBinding(mouse.hover(Offset(box.left + box.width * 0.7, box.center.dy))); // day 6 of 8: 26 Oct
      await t.pump();
      expect(t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('chartTip')), matching: find.byType(Text))).data,
          '${shortDateOrRaw('2026-10-26')}\n${moneyExact(70000, 'EUR')}');
      handle.dispose();
    });

    testWidgets('the end dot is 4 px with a 2 px ring in the page colour', (t) async {
      await t.pumpWidget(_app(const ForecastStepChart(points: _points, payday: '2026-10-28', currency: 'EUR')));
      final bar = t.widget<LineChart>(find.byType(LineChart)).data.lineBarsData.single;
      final dot = bar.dotData.getDotPainter(bar.spots.last, 0, bar, 0) as FlDotCirclePainter;
      expect(dot.radius, 4);
      expect(dot.strokeWidth, 2);
      expect(dot.strokeColor, WalletColors.light.bg);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('income chart: "Went out" is the second chart colour, never the status red (${b.name})', (t) async {
      final c = b == Brightness.light ? WalletColors.light : WalletColors.dark;
      await pump(t, InsightsScreen(wc: insightsWallet()), size: const Size(400, 6000), brightness: b);
      final bars = t.widget<SeriesBars>(find.byKey(const ValueKey('insightBars_income')));
      for (final g in bars.groups) {
        expect(g.rods[0].color, c.chartPos);
        expect(g.rods[1].color, c.chart2);
        expect(g.rods[1].color, isNot(c.bad));
        expect(g.rods[1].color, isNot(c.neg));
      }
      final legend = find.ancestor(of: find.text('Went out'), matching: find.byType(LegendItem));
      expect(t.widget<LegendItem>(legend).color, c.chart2);
    });
  }
}
