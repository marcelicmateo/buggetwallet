// RX4: the Budget tab as two dashboards (Spending | Plan): the switch and its remembered choice, Today's links, exact cents on the tiles,
// the change chip against the 6-month average (and its absence), and the layout at 320 dp × 2.0, 360, 411 and 1280, light and dark.
// All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/budget.dart';
import 'package:budget_wallet/src/screens/plan_screen.dart';
import 'package:budget_wallet/src/screens/save.dart';
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

Future<void> _show(WidgetTester t, WalletController wc, {Size size = const Size(400, 3000), double scale = 1, bool spending = true}) {
  if (spending) wc.setBudgetView('spending'); // the tiles under test are the Spending page; Explore is the tab's first page
  return pumpApp(t, Scaffold(body: BudgetScreen(wc: wc)), size: size, textScale: scale);
}

/// Plan › Payday plan (it moved off the Budget tab in ENG E1).
Future<void> _showPlan(WidgetTester t, WalletController wc, {Size size = const Size(400, 3000), double scale = 1}) =>
    pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: size, textScale: scale);

void main() {
  group('RX4 the switch', () {
    test('budgetView keeps explore, spending and tags; anything else falls back to explore', () {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      wc.setBudgetView('tags');
      expect(wc.budgetView, 'tags');
      expect(wc.repo.localValue('budgetView'), 'tags');
      wc.setBudgetView('bogus');
      expect(wc.budgetView, 'tags', reason: 'an unknown view is ignored');
      wc.repo.setLocalValue('budgetView', 'old');
      expect(wc.budgetView, 'explore', reason: 'an unknown stored value reads as the default');
    });

    tw('Explore opens on Explore, Spending and Tags are one tap away and the choice is remembered on the device', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      expect(wc.budgetView, 'explore');
      await _show(t, wc, spending: false);
      await t.tap(_key('budgetSpending'));
      await t.pump(const Duration(milliseconds: 300));
      expect(_key('budgetSwitch'), findsOneWidget);
      expect(_key('outTile'), findsOneWidget);
      expect(_key('budgetPlan'), findsNothing, reason: 'the plan moved to Plan');
      expect(t.widget<SegmentedButton<String>>(_key('budgetSwitch')).selected, {'spending'});

      await t.ensureVisible(_key('budgetTags')); // the switch scrolls sideways when the labels do not fit
      await t.tap(_key('budgetTags'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'tags');
      expect(wc.repo.localValue('budgetView'), 'tags', reason: 'device-local, not a synced setting');
      expect(_key('outTile'), findsNothing);

      // A new screen (an app restart) opens where the owner left it.
      await t.pumpWidget(const SizedBox());
      await _show(t, wc, spending: false);
      expect(t.widget<SegmentedButton<String>>(_key('budgetSwitch')).selected, {'tags'});

      await t.tap(_key('budgetSpending'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'spending');
      expect(wc.repo.localValue('budgetView'), 'spending');
      expect(_key('outTile'), findsOneWidget);
      await t.tap(_key('budgetExplore'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.repo.localValue('budgetView'), isNull, reason: 'Explore is the default: nothing stored');
    });

    tw('Plan opens on the payday plan, Saving is one tap away and the choice is remembered on the device', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      expect(wc.planView, 'payday');
      await _showPlan(t, wc);
      expect(_key('planSwitch'), findsOneWidget);
      expect(_key('planTile'), findsOneWidget);
      await t.tap(_key('planSaving'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.planView, 'saving');
      expect(wc.repo.localValue('planView'), 'saving');
      expect(find.byType(SaveScreen), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await _showPlan(t, wc);
      expect(t.widget<SegmentedButton<String>>(_key('planSwitch')).selected, {'saving'});
      await t.tap(_key('planPayday'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.repo.localValue('planView'), isNull, reason: 'the payday plan is the default: nothing stored');
      wc.setPlanView('bogus');
      expect(wc.planView, 'payday');
    });

    tw('the plan editor keeps what was typed while Saving is shown', (t) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      await _showPlan(t, wc);
      await openPlanEdit(t, 'rent');
      await t.enterText(find.widgetWithText(TextField, 'Rent'), '777');
      await t.tap(_key('planSaving'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(_key('planPayday'));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.widget<TextField>(find.widgetWithText(TextField, 'Rent')).controller!.text, '777');
    });

    tw('a search request (Ctrl+F, the app bar) lands on Explore', (t) async {
      final wc = budgetWallet()..setBudgetView('tags');
      addTearDown(wc.dispose);
      final request = ValueNotifier<int>(0);
      addTearDown(request.dispose);
      await pumpApp(t, Scaffold(body: BudgetScreen(wc: wc, searchRequest: request)), size: const Size(400, 3000));
      expect(_key('budgetSwitch'), findsOneWidget);
      request.value++;
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'explore');
      expect(_key('outTile'), findsNothing, reason: 'the search view covers the page');
      expect(find.byKey(const ValueKey('searchField')).evaluate().isNotEmpty || find.byType(TextField).evaluate().isNotEmpty, isTrue);
    });

    tw("Today's links pick the page they mean: a held line and the setup link open Plan › Payday plan, the budget line opens Explore › Spending",
        (t) async {
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
      wc.setBudgetView('tags');
      wc.setPlanView('saving');
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
      expect(wc.planView, 'payday');
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
    tw('the salary split, per day, the lines with a paid tick, each value editable in place', (t) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      await _showPlan(t, wc);
      final p = wc.period();
      expect(_key('planTile'), findsOneWidget);
      expect(find.byType(Donut), findsOneWidget);
      expect(find.descendant(of: _key('planPerDay'), matching: find.text(moneyExact(p.planDaily > 0 ? p.planDaily : 0, 'EUR'))),
          findsOneWidget);
      expect(_key('planRow_rent'), findsOneWidget, reason: 'each value is tappable: no Edit button');
      expect(_key('planEdit'), findsNothing);
      expect(_key('ledgerSpendingMoney'), findsOneWidget);
      expect(find.descendant(of: _key('ledgerSpendingMoney'), matching: find.text(moneyExact(p.flexBudget, 'EUR'))), findsOneWidget);
    });
  });

  group('RX4b exact cents, chip, sparkline, once-only numbers, net bars', () {
    /// October out [oct] against six months of 100 € (the average is 10000).
    WalletController flat(int oct) {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
      for (final m in const ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09']) {
        wc.repo.addTransaction(date: '$m-10', amount: 10000, category: 'Groceries');
      }
      wc.repo.addTransaction(date: '2026-10-10', amount: oct, category: 'Groceries');
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
      wc.reload();
      return wc;
    }

    tw('Top places shows exact cents', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      wc.repo.addTransaction(date: '2026-10-14', amount: 1234, category: 'Shopping', note: 'Synthetic corner shop');
      wc.reload();
      final top = wc.spending().topPlaces;
      expect(top, isNotEmpty);
      await _show(t, wc);
      for (final (_, _, total) in top) {
        expect(find.text(moneyExact(total, 'EUR')), findsWidgets, reason: 'a place total of $total cents');
      }
      expect(top.any((p) => p.$3 % 100 != 0), isTrue, reason: 'precondition: a total with cents');
    });

    tw('within half a percent of the average the chip says "same as avg", flat, neither better nor worse', (t) async {
      for (final oct in [10000, 10040, 9960]) {
        final wc = flat(oct);
        addTearDown(wc.dispose);
        expect(wc.spending().outChange!.abs(), lessThan(5), reason: '$oct');
        await _show(t, wc);
        final chip = t.widget<DeltaChip>(_key('outDelta'));
        expect((chip.trend, chip.text, chip.good), (Trend.flat, 'same as avg', null), reason: '$oct');
        expect(find.textContaining('0 %'), findsNothing);
      }
    });

    tw('from half a percent on it is a percent chip again', (t) async {
      final wc = flat(10060);
      addTearDown(wc.dispose);
      await _show(t, wc);
      final chip = t.widget<DeltaChip>(_key('outDelta'));
      expect((chip.trend, chip.text, chip.good), (Trend.up, '1 % vs avg', false));
    });

    tw('the sparkline marks the chosen month', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      await _show(t, wc);
      Sparkline spark() => t.widget<Sparkline>(find.descendant(of: _key('outTile'), matching: find.byType(Sparkline)));
      expect(spark().values.length, 12);
      expect(spark().marked, 11, reason: 'this month: the last point');
      await t.tap(find.text('Sep'));
      await t.pump(const Duration(milliseconds: 300));
      expect(spark().marked, 10);
      await t.tap(find.text('Jun'));
      await t.pump(const Duration(milliseconds: 300));
      expect(spark().marked, 7);
    });

    tw('Plan says each number once: no salary in the ring, no spending amount in its legend; the rows have them', (t) async {
      final wc = budgetWallet(budgets: false);
      addTearDown(wc.dispose);
      wc.repo.updateSettings({'rent': 40050});
      wc.reload();
      await _showPlan(t, wc);
      final p = wc.period();
      expect(p.flexBudget, isNot(p.income));
      final tile = _key('planTile');
      expect(find.descendant(of: tile, matching: find.textContaining(moneyExact(p.income, 'EUR'))), findsNothing);
      expect(find.descendant(of: tile, matching: find.textContaining(moneyExact(p.flexBudget, 'EUR'))), findsNothing);
      final lines = _key('planLines');
      expect(find.descendant(of: lines, matching: find.text(moneyExact(p.income, 'EUR'))), findsOneWidget, reason: 'the Salary row');
      expect(find.descendant(of: lines, matching: find.text(moneyExact(p.flexBudget, 'EUR'))), findsOneWidget, reason: 'the total row');
    });

    tw('the ring: Fixed and Saved with their exact values, weights in proportion', (t) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      await _showPlan(t, wc);
      final p = wc.period();
      final segs = t.widget<Donut>(find.byType(Donut)).segments;
      expect([for (final s in segs) s.label], ['Fixed', 'Saved', 'Spending']);
      expect(segs[0].value, moneyExact(p.fixedPlan + p.beforePayday, 'EUR'));
      expect(segs[1].value, moneyExact(p.goalMonthly, 'EUR'));
      expect(segs[0].weight, (p.fixedPlan + p.beforePayday).toDouble());
      expect(segs[1].weight, p.goalMonthly.toDouble());
      expect(segs[2].weight, p.flexBudget > 0 ? p.flexBudget.toDouble() : 0);
      // The legend is one rich text per entry: its label and exact value.
      expect(find.descendant(of: _key('planTile'), matching: find.textContaining(moneyExact(p.fixedPlan + p.beforePayday, 'EUR'))),
          findsOneWidget);
      expect(find.descendant(of: _key('planTile'), matching: find.textContaining(moneyExact(p.goalMonthly, 'EUR'))), findsOneWidget);
    });

    for (final (w, most) in const [(360.0, 5), (1280.0, 8)]) {
      tw('Saving or losing at $w dp: the newest bars that fit, exact amounts, cells apart', (t) async {
        final wc = demoWallet();
        addTearDown(wc.dispose);
        final periods = wc.spending().periods;
        await _show(t, wc, size: Size(w, 1400));
        final take = periods.length < most ? periods.length : most;
        final values = [for (final p in periods.sublist(periods.length - take)) moneyExact(p.net, 'EUR')];
        final netTexts = find.descendant(of: _key('netTile'), matching: find.byType(Text));
        final shown = [
          for (final e in netTexts.evaluate())
            if (values.contains((e.widget as Text).data)) (e.widget as Text).data!
        ];
        expect(shown, values, reason: 'the newest ${values.length} periods, each amount exact, in order');
        expect(t.takeException(), isNull);
      });

      tw('NetBars at $w dp (a tile of ${w - 56}): 8 bars with long amounts keep $most, none touching', (t) async {
        final bars = [
          for (var i = 0; i < 8; i++) NetBar(label: 'Mo$i', value: '−1,234.56 €', cents: i.isEven ? 123456 : -123456),
        ];
        await pumpApp(t, Scaffold(body: Padding(padding: const EdgeInsets.all(28), child: NetBars(bars: bars))), size: Size(w, 400));
        final cells = find.byType(FittedBox);
        final boxes = [for (var i = 1; i < cells.evaluate().length; i += 2) t.getRect(cells.at(i))]; // each cell: label box, value box
        expect(boxes.length, most, reason: 'bars shown at $w dp');
        expect(find.text('Mo7'), findsOneWidget, reason: 'the newest is kept');
        expect(find.text('Mo0'), most == 8 ? findsOneWidget : findsNothing, reason: 'the oldest goes first');
        for (var i = 1; i < boxes.length; i++) {
          expect(boxes[i].left - boxes[i - 1].right, greaterThanOrEqualTo(2 * NetBars.cellGap), reason: 'cells $i and ${i - 1} touch');
        }
        expect(NetBars.fit(w - 56, 8, 56), most);
        expect(t.takeException(), isNull);
      });
    }
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
            if (view == 'plan') {
              await _showPlan(t, wc, size: Size(w, 900), scale: scale);
            } else {
              await _show(t, wc, size: Size(w, 900), scale: scale);
            }
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
