// Stage Q10 + Q11 app half: the bills cost header ("X a month · Y a year", "about" for a range) and the payday forecast (line and step
// chart under the payday plan, hidden without a trusted bank balance). Fixed clock (20 Oct 2026), synthetic data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/habits_panels.dart';
import 'package:budget_wallet/src/screens/payday_plan.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 60));

Finder _key(String k) => find.byKey(ValueKey(k));

WalletController _wallet({String? openingDate, int opening = 100000}) {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  if (openingDate != null) {
    wc.repo.addAccount(name: 'PBZ current', source: 'pbz', currency: 'EUR', opening: opening, openingDate: openingDate);
  }
  wc.reload();
  return wc;
}

/// A widget test that lets the controller's 3 s sync debounce run out at the end (a pending timer fails the test).
void tw(String name, Future<void> Function(WidgetTester t) body, {Timeout? timeout}) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: timeout);

void main() {
  group('Q10 bills cost header', () {
    Future<void> panel(WidgetTester t, WalletController wc, {double scale = 1, Size size = const Size(400, 1400)}) =>
        pumpApp(t, Scaffold(body: SingleChildScrollView(child: ExpectedBillsPanel(wc: wc))), textScale: scale, size: size);

    tw('a monthly and a yearly bill: X a month · Y a year', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 30000, intervalDays: 30, firstDue: '2026-10-25');
      wc.addRecurringBill(label: 'Synthetic cover', category: 'Groceries', amount: 60000, intervalDays: 365, firstDue: '2027-03-01');
      await panel(t, wc);
      final cost = wc.billsCost()!;
      expect((cost.monthly, cost.yearly, cost.approximate), (35000, 420000, false));
      expect(
          find.text('Bills and subscriptions: ${moneyExact(35000, 'EUR')} a month · ${moneyExact(420000, 'EUR')} a year'), findsOneWidget);
      expect(find.textContaining('about'), findsNothing);
    }, timeout: _t);

    tw('a bill whose amount changes makes the figures "about"', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(
          label: 'Synthetic power',
          category: 'Groceries',
          amount: 12000,
          minAmount: 8000,
          maxAmount: 12000,
          intervalDays: 30,
          firstDue: '2026-10-25');
      await panel(t, wc);
      expect(wc.billsCost()!.approximate, isTrue);
      expect(
          find.textContaining(
              'Bills and subscriptions: about ${moneyExact(10000, 'EUR')} a month · about ${moneyExact(120000, 'EUR')} a year'),
          findsOneWidget);
    }, timeout: _t);

    tw('no confirmed bill: no header', (t) async {
      final wc = _wallet();
      await panel(t, wc);
      expect(_key('recurringCost'), findsNothing);
    }, timeout: _t);

    tw('the header fits 320 dp at text 2.0', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 30000, intervalDays: 30, firstDue: '2026-10-25');
      await panel(t, wc, scale: 2, size: const Size(320, 900));
      expect(_key('recurringCost'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, timeout: _t);
  });

  group('Q11 payday forecast', () {
    Future<void> plan(WidgetTester t, WalletController wc, {double scale = 1, Size size = const Size(400, 2200)}) =>
        pumpApp(t, Scaffold(body: SingleChildScrollView(child: PaydayPlan(wc: wc))), textScale: scale, size: size);

    tw('a trusted balance: "On payday: about X" after the bill, and the chart', (t) async {
      final wc = _wallet(openingDate: '2026-10-10');
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 30000, intervalDays: 30, firstDue: '2026-10-25');
      final f = wc.paydayForecast()!;
      expect(f.onPayday, 70000);
      expect(f.points.first.cents, 100000);
      await plan(t, wc);
      expect(find.text('On payday: about ${moneyExact(70000, 'EUR')} (after bills, before day-to-day spending)'), findsOneWidget);
      expect(_key('forecastChart'), findsOneWidget);
    }, timeout: _t);

    tw('no bank balance at all: the line and the chart are hidden', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 30000, intervalDays: 30, firstDue: '2026-10-25');
      expect(wc.paydayForecast(), isNull);
      await plan(t, wc);
      expect(_key('forecastLine'), findsNothing);
      expect(_key('forecastChart'), findsNothing);
    }, timeout: _t);

    tw('an old, unchecked balance is not trusted: hidden; a matching check brings it back', (t) async {
      final wc = _wallet(openingDate: '2026-07-01');
      final id = wc.accountsAll().single.id;
      expect(wc.paydayForecast(), isNull);
      await plan(t, wc);
      expect(_key('forecastLine'), findsNothing);
      wc.recordBalanceCheck(id, date: '2026-10-18', bankCents: 100000);
      await plan(t, wc);
      expect(_key('forecastLine'), findsOneWidget);
    }, timeout: _t);

    tw('cash alone does not show it', (t) async {
      final wc = _wallet();
      await wc.repo.addAccount(name: 'Cash', currency: 'EUR', opening: 100000, openingDate: '2026-10-10');
      wc.reload();
      expect(wc.paydayForecast(), isNull);
    }, timeout: _t);

    tw('a balance that ends below zero is shown in the bad colour', (t) async {
      final wc = _wallet(openingDate: '2026-10-10', opening: 10000);
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 30000, intervalDays: 30, firstDue: '2026-10-25');
      await plan(t, wc);
      final text = t.widget<Text>(_key('forecastLine'));
      expect(text.data, contains('−'));
      expect(text.style!.color, isNotNull);
    }, timeout: _t);

    for (final dark in [false, true]) {
      tw('320 dp at text 2.0 ${dark ? 'dark' : 'light'}: the forecast fits', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        final wc = _wallet(openingDate: '2026-10-10');
        wc.addRecurringBill(
            label: 'Synthetic phone with a long name', category: 'Groceries', amount: 30000, intervalDays: 30, firstDue: '2026-10-25');
        await plan(t, wc, scale: 2, size: const Size(320, 2600));
        expect(_key('forecastLine'), findsOneWidget);
        expect(t.takeException(), isNull);
      }, timeout: _t);
    }
  });

  group('ForecastStepChart crisp pixels', () {
    bool whole(double logical, double dpr) {
      final px = logical * dpr;
      return (px - px.roundToDouble()).abs() < 1e-6 && px.round() >= 1;
    }

    const points = [
      ForecastPoint('2026-10-20', 100000, null),
      ForecastPoint('2026-10-25', 70000, 'Synthetic phone', causeId: 'b1', delta: -30000),
      ForecastPoint('2026-10-28', -5000, 'Synthetic rent', causeId: 'b2', delta: -75000),
    ];

    for (final dpr in const [1.0, 1.25, 1.5, 2.0]) {
      tw('strokes cover whole device pixels at $dpr', (t) async {
        t.view.physicalSize = const Size(600, 600) * dpr;
        t.view.devicePixelRatio = dpr;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: ForecastStepChart(points: points, payday: '2026-11-01', currency: 'EUR')),
        ));
        final line = t.widget<LineChart>(find.byType(LineChart)).data.lineBarsData.single;
        expect(line.isStepLineChart, isTrue);
        expect(line.isCurved, isFalse);
        expect(whole(line.barWidth, dpr), isTrue, reason: 'line width ${line.barWidth} dp');
        expect(line.color!.a, 1.0, reason: 'opaque');
        final dot = line.dotData.getDotPainter(line.spots.first, 0, line, 0) as FlDotCirclePainter;
        expect(whole(dot.radius * 2, dpr), isTrue);
        expect(dot.color.a, 1.0);
        final grid = t.widget<LineChart>(find.byType(LineChart)).data.gridData;
        for (final v in const [0.0, 500.0]) {
          expect(whole(grid.getDrawingHorizontalLine(v).strokeWidth, dpr), isTrue, reason: 'grid at $v');
        }
      });
    }
  });
}
