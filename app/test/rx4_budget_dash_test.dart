// RX4: the Budget tab as two dashboards (Spending | Plan): the switch and its remembered choice, Today's links, exact cents on the tiles,
// the change chip against the 6-month average (and its absence), and the layout at 320 dp × 2.0, 360, 411 and 1280, light and dark.
// All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/budget.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

/// A widget test that lets the controller's 3 s sync debounce run out before it ends (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester tester) body, {Timeout? timeout}) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    }, timeout: timeout);

Future<void> _show(WidgetTester t, WalletController wc, {Size size = const Size(400, 3000), double scale = 1}) =>
    pumpApp(t, Scaffold(body: BudgetScreen(wc: wc)), size: size, textScale: scale);

void main() {
  group('RX4 the switch', () {
    tw('opens on Spending, Plan is one tap away and the choice is remembered on the device', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      expect(wc.budgetView, 'spending');
      await _show(t, wc);
      expect(_key('budgetSwitch'), findsOneWidget);
      expect(_key('outTile'), findsOneWidget);
      expect(_key('planTile'), findsNothing, reason: 'the Plan page is built but not shown');
      expect(t.widget<SegmentedButton<String>>(_key('budgetSwitch')).selected, {'spending'});

      await t.tap(_key('budgetPlan'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'plan');
      expect(wc.repo.localValue('budgetView'), 'plan', reason: 'device-local, not a synced setting');
      expect(_key('planTile'), findsOneWidget);
      expect(_key('outTile'), findsNothing);

      // A new screen (an app restart) opens where the owner left it.
      await t.pumpWidget(const SizedBox());
      await _show(t, wc);
      expect(_key('planTile'), findsOneWidget);
      expect(t.widget<SegmentedButton<String>>(_key('budgetSwitch')).selected, {'plan'});

      await t.tap(_key('budgetSpending'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'spending');
      expect(wc.repo.localValue('budgetView'), isNull, reason: 'Spending is the default: nothing stored');
      expect(_key('outTile'), findsOneWidget);
    });

    tw('the plan editor keeps what was typed while Spending is shown', (t) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      wc.setBudgetView('plan');
      await _show(t, wc);
      await openPlanEdit(t);
      await t.enterText(find.widgetWithText(TextField, 'Rent'), '777');
      await t.tap(_key('budgetSpending'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(_key('budgetPlan'));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.widget<TextField>(find.widgetWithText(TextField, 'Rent')).controller!.text, '777');
    });

    tw('a search request (Ctrl+F, the app bar) lands on Spending', (t) async {
      final wc = budgetWallet()..setBudgetView('plan');
      addTearDown(wc.dispose);
      final request = ValueNotifier<int>(0);
      addTearDown(request.dispose);
      await pumpApp(t, Scaffold(body: BudgetScreen(wc: wc, searchRequest: request)), size: const Size(400, 3000));
      expect(_key('planTile'), findsOneWidget);
      request.value++;
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'spending');
      expect(_key('outTile'), findsNothing, reason: 'the search view covers the page');
      expect(find.byKey(const ValueKey('searchField')).evaluate().isNotEmpty || find.byType(TextField).evaluate().isNotEmpty, isTrue);
    });

    tw("Today's links pick the page they mean: a held line and the setup link open Plan, the budget line opens Spending", (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      await wc.repo.addAccount(name: 'Cash', currency: 'EUR', opening: 5000, openingDate: '2026-10-10');
      wc.reload();
      wc.snoozeKeyBackup();
      var opened = '';
      Future<void> today() => pumpApp(
          t,
          Scaffold(
              body: TodayScreen(
                  view: TodayView(wc), openPlan: () => opened = 'plan', openSpending: () => opened = 'spending', clock: () => budgetToday)),
          size: const Size(400, 3000));

      // Spending first (the budget line), then Plan (the held line has no own opener here, so it uses the plan link).
      wc.setBudgetView('plan');
      await today();
      await t.ensureVisible(_key('budgetLine'));
      await t.tap(_key('budgetLine'));
      await t.pump();
      expect(opened, 'spending');
      expect(wc.budgetView, 'spending');

      await t.ensureVisible(_key('heldLine'));
      await t.tap(_key('heldLine'));
      await t.pump();
      expect(opened, 'plan');
      expect(wc.budgetView, 'plan');
    });
  });

  group('RX4 Spending tiles', () {
    tw('Out in the month is exact to the cent, with a change chip against the 6-month average', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      wc.repo.addTransaction(date: '2026-10-14', amount: 1234, category: 'Shopping');
      wc.reload();
      final v = wc.spending();
      expect(v.summary.out, 43634);
      expect(v.averageOut, 37500, reason: '6 months × (290 + 85) €');
      expect(v.outChange, changePermille(43634, 37500));
      await _show(t, wc);
      expect(find.descendant(of: _key('outTile'), matching: find.text(moneyExact(43634, 'EUR'))), findsOneWidget);
      expect(find.text('OUT IN OCTOBER'), findsOneWidget);
      expect(find.textContaining('436.34'), findsWidgets, reason: 'cents, never rounded');
      final chip = t.widget<DeltaChip>(_key('outDelta'));
      expect(chip.trend, Trend.up);
      expect(chip.good, isFalse, reason: 'more than usual is not the good direction');
      expect(chip.text, '16 % vs avg');
      expect(find.descendant(of: _key('outTile'), matching: find.byType(Sparkline)), findsOneWidget);
      // In and Kept are tiles too, and the income is exact.
      expect(find.descendant(of: _key('inTile'), matching: find.text(moneyExact(v.summary.income, 'EUR'))), findsOneWidget);
      expect(_key('keptTile'), findsOneWidget);
    });

    tw('spending below the average gives a down chip in the good direction', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      // Go back to September: 375 € average of the 6 months before, out 375 €: flat; July had the same. Use a month with less.
      wc.repo.addTransaction(date: '2026-03-05', amount: 100000, category: 'Shopping'); // raises the 6 months before Sep (Mar..Aug)
      wc.reload();
      await _show(t, wc);
      await t.tap(find.text('Sep'));
      await t.pump(const Duration(milliseconds: 300));
      final v = wc.spending('2026-09');
      expect(v.outChange, isNotNull);
      expect(v.outChange!, lessThan(0));
      final chip = t.widget<DeltaChip>(_key('outDelta'));
      expect(chip.trend, Trend.down);
      expect(chip.good, isTrue);
    });

    tw('no average (nothing in the 6 months before): no chip, the number stays', (t) async {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
      addTearDown(wc.dispose);
      wc.repo.addTransaction(date: '2026-10-03', amount: 15200, category: 'Groceries');
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
      wc.reload();
      expect(wc.spending().averageOut, 0);
      expect(wc.spending().outChange, isNull);
      await _show(t, wc);
      expect(_key('outDelta'), findsNothing);
      expect(find.descendant(of: _key('outTile'), matching: find.text(moneyExact(15200, 'EUR'))), findsOneWidget);
    });

    tw('Where it goes: budget meters with exact amounts; a row opens its category; the state is a word', (t) async {
      final wc = budgetWallet(groceriesBudget: 29950, eatingOutBudget: 11151);
      addTearDown(wc.dispose);
      await _show(t, wc);
      expect(find.text('${moneyExact(25200, 'EUR')} / ${moneyExact(29950, 'EUR')}'), findsOneWidget);
      expect(find.textContaining(leftTextFor(4750)), findsOneWidget);
      expect(find.textContaining('over by 0.49'), findsOneWidget);
      expect(find.descendant(of: _key('budgetState'), matching: find.textContaining('1 over')), findsOneWidget);
      expect(_key('categoryRow_Groceries'), findsOneWidget);
      expect(_key('budgetTotal'), findsOneWidget);
    });

    tw('a month chip changes the month of every tile', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      await _show(t, wc);
      await t.tap(find.text('Sep'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('OUT IN SEPTEMBER'), findsOneWidget);
      expect(
          find.descendant(of: _key('outTile'), matching: find.text(moneyExact(wc.spending('2026-09').summary.out, 'EUR'))), findsOneWidget);
    });
  });

  group('RX4 Plan tiles', () {
    tw('the salary split, per day, the lines with a paid tick and Edit', (t) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      wc.setBudgetView('plan');
      await _show(t, wc);
      final p = wc.period();
      expect(_key('planTile'), findsOneWidget);
      expect(find.byType(Donut), findsOneWidget);
      expect(find.descendant(of: _key('planPerDay'), matching: find.text(moneyExact(p.planDaily > 0 ? p.planDaily : 0, 'EUR'))),
          findsOneWidget);
      expect(_key('planEdit'), findsOneWidget);
      expect(_key('ledgerSpendingMoney'), findsOneWidget);
      expect(find.descendant(of: _key('ledgerSpendingMoney'), matching: find.text(moneyExact(p.flexBudget, 'EUR'))), findsOneWidget);
    });
  });

  group('RX4 layout', () {
    for (final dark in [false, true]) {
      for (final (w, scale) in const [(320.0, 2.0), (360.0, 1.0), (411.0, 1.0), (1280.0, 1.0)]) {
        for (final view in const ['spending', 'plan']) {
          tw('$view page at $w dp, text $scale, ${dark ? 'dark' : 'light'}: nothing overflows', (t) async {
            t.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
            addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
            final wc = demoWallet();
            addTearDown(wc.dispose);
            wc.setBudgetView(view);
            await _show(t, wc, size: Size(w, 900), scale: scale);
            expect(find.byType(DashGrid), findsWidgets);
            await scrollThrough(t);
            expect(t.takeException(), isNull);
            final rows = overflowing.toList();
            overflowing.clear();
            expect(rows, isEmpty, reason: 'overflowing: ${rows.join(' / ')}');
          }, timeout: const Timeout(Duration(minutes: 2)));
        }
      }
    }
  });
}

/// "47.50 € left" in the wallet's number style.
String leftTextFor(int cents) => '${moneyExact(cents, 'EUR')} left';
