// Budget vs actual on Spending and Today, and the controller's cached budget values. All data is SYNTHETIC (budgetWallet).
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart' show WalletRepoSettings;

import 'support/wallet.dart';

const _sizes = [('320 dp at text 2.0', Size(320, 4000), 2.0), ('360 dp', Size(360, 3000), 1.0), ('1280 wide', Size(1280, 2000), 1.0)];

String _eur(String body) => body.replaceAll(' €', ' €');

void main() {
  group('controller', () {
    test('budgetVsActual, suggestedBudgets and tightestBudget are cached until the data changes', () {
      final wc = budgetWallet();
      final b = wc.budgetVsActual('2026-10');
      expect(identical(wc.budgetVsActual('2026-10'), b), isTrue);
      expect(identical(wc.budgetVsActual('2026-09'), b), isFalse);
      final s = wc.suggestedBudgets('2026-10');
      expect(identical(wc.suggestedBudgets('2026-10'), s), isTrue);
      final t = wc.tightestBudget();
      expect(identical(wc.tightestBudget(), t), isTrue);

      wc.addExpense(amount: 500, category: 'Groceries', note: 'x', date: '2026-10-15');
      expect(identical(wc.budgetVsActual('2026-10'), b), isFalse);
      expect(wc.budgetVsActual('2026-10').lines.firstWhere((l) => l.category == 'Groceries').actual, 25700);
      expect(identical(wc.tightestBudget(), t), isFalse);
    });

    test('the numbers: Groceries 48 left, Eating out over by 12, one of two over', () {
      final b = budgetWallet().budgetVsActual('2026-10');
      expect(b.budgetedCount, 2);
      expect(b.overCount, 1);
      expect(b.remainingTotal, 3600);
      final g = b.lines.firstWhere((l) => l.category == 'Groceries');
      expect((g.budget, g.actual, g.remaining, g.over), (30000, 25200, 4800, false));
      final e = b.lines.firstWhere((l) => l.category == 'Eating out');
      expect((e.remaining, e.over), (-1200, true));
    });

    test('tightestBudget is the least left, null without budgets', () {
      final wc = budgetWallet();
      expect(wc.tightestBudget()!.category, 'Eating out');
      expect(budgetWallet(eatingOutBudget: 20000).tightestBudget()!.category, 'Groceries');
      expect(budgetWallet(budgets: false).tightestBudget(), isNull);
    });

    test('saveCategoryBudgets stores the map and an empty map clears it', () {
      final wc = budgetWallet(budgets: false);
      final v = wc.dataVersion;
      wc.saveCategoryBudgets({'Shopping': 5000});
      expect(wc.dataVersion, v + 1);
      expect(wc.categoryBudgets, {'Shopping': 5000});
      wc.saveCategoryBudgets({});
      expect(wc.categoryBudgets, isEmpty);
      wc.dispose(); // cancels the sync debounce
    });
  });

  group('Spending › Where it goes', () {
    // RX4: a BarList tile. The value is "spent / budget" (exact), the note says what is left, "over by" with a warning icon or
    // "behind pace"; the tile's chip counts the over and behind-pace categories; the total is one muted line.
    Finder row(String id) => find.byKey(ValueKey('categoryRow_$id'));
    for (final (name, size, scale) in _sizes) {
      testWidgets('$name: budgeted rows show what is left, the over one is marked, a chip and a total line', (tester) async {
        final wc = budgetWallet();
        await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: size, textScale: scale);
        expect(find.text(_eur('252 € / 300 €')), findsOneWidget);
        expect(find.text(_eur('112 € / 100 €')), findsOneWidget);
        expect(find.text(_eur('48 € left · behind pace')), findsOneWidget, reason: 'Groceries: 84 % spent, 65 % of the month gone');
        expect(find.text(_eur('over by 12 €')), findsOneWidget);
        expect(find.descendant(of: row('Eating out'), matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget,
            reason: 'the over row: icon and bold words, not colour alone');
        expect(
            find.descendant(of: find.byKey(const ValueKey('budgetState')), matching: find.text('1 over · 1 behind pace')), findsOneWidget);
        expect(find.text(_eur('364 € of 400 € budgeted')), findsOneWidget);
        expect(find.descendant(of: row('Shopping'), matching: find.text(_eur('60 €'))), findsOneWidget,
            reason: 'Shopping has no budget: its amount and the average');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('only the over row is hatched beyond its budget mark; a behind-pace row is solid', (tester) async {
      final wc = budgetWallet();
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      bool hatched(String id) => find
          .descendant(
              of: find.byKey(ValueKey('categoryRow_$id')),
              matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HatchPainter))
          .evaluate()
          .isNotEmpty;
      expect(hatched('Eating out'), isTrue, reason: '112 of 100: over');
      expect(hatched('Groceries'), isFalse, reason: '252 of 300 is behind pace, not over: no hatch, the words say it');
      expect(hatched('Shopping'), isFalse, reason: 'no budget');
    });

    testWidgets('nothing budgeted: the rows show amounts and averages, no chip or total', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.textContaining('left'), findsNothing);
      expect(find.byKey(const ValueKey('budgetState')), findsNothing);
      expect(find.byKey(const ValueKey('budgetTotal')), findsNothing);
      for (final v in ['252 €', '112 €']) {
        expect(find.descendant(of: find.byKey(const ValueKey('whereTile')), matching: find.text(_eur(v))), findsOneWidget);
      }
      expect(find.text(_eur('Average 290 €')), findsOneWidget);
    });

    testWidgets('within budget but behind pace: the word with the numbers, the chip says so', (tester) async {
      final wc = budgetWallet(eatingOutBudget: 20000);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.byIcon(Icons.warning_amber_rounded), findsNWidgets(1), reason: 'the chip only: no row is over');
      expect(find.descendant(of: find.byKey(const ValueKey('budgetState')), matching: find.text('1 behind pace')), findsOneWidget);
      expect(find.text(_eur('48 € left · behind pace')), findsOneWidget);
      expect(find.textContaining('over by'), findsNothing);
    });

    testWidgets('on pace: nothing extra, the chip says On pace with a tick', (tester) async {
      // Groceries 252 of 400 is 63 % of the budget at 65 % of the month: on pace. Eating out 112 of 200 likewise.
      final wc = budgetWallet(eatingOutBudget: 20000, groceriesBudget: 40000);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.textContaining('behind pace'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('budgetState')), matching: find.text('On pace')), findsOneWidget);
      expect(find.byIcon(Icons.check), findsWidgets);
      expect(find.text(_eur('364 € of 600 € budgeted')), findsOneWidget);
    });

    testWidgets('behind pace fits 320 dp at text 2.0', (tester) async {
      final wc = budgetWallet(eatingOutBudget: 20000);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(320, 4000), textScale: 2.0);
      expect(find.textContaining('behind pace'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('amounts are exact: 47.50 € left and over by 0.49 €, never rounded to whole euros', (tester) async {
      // Groceries 252 of 299.50 (4750 left), Eating out 112 of 111.51 (49 over).
      final wc = budgetWallet(groceriesBudget: 29950, eatingOutBudget: 11151);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.text(_eur('47.50 € left · behind pace')), findsOneWidget);
      expect(find.text(_eur('over by 0.49 €')), findsOneWidget);
      expect(find.text(_eur('252 € / 299.50 €')), findsOneWidget);
      expect(find.text(_eur('112 € / 111.51 €')), findsOneWidget);
      expect(find.text(_eur('364 € of 411.01 € budgeted')), findsOneWidget);
      expect(find.textContaining('over by 0 €'), findsNothing);
      expect(find.textContaining('48 € left'), findsNothing);
    });

    testWidgets('a budgeted category with no spending yet still shows its budget', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.setCategoryBudget('Sport & fitness', 4000);
      wc.reload();
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.text(_eur('40 € left')), findsOneWidget);
      expect(find.text(_eur('0 € / 40 €')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('budgetState')), matching: find.text('On pace')), findsOneWidget);
    });
  });

  group('Today › budget line', () {
    for (final (name, size, scale) in _sizes) {
      testWidgets('$name: the least-left category is a ring tile with the amount left', (tester) async {
        final wc = budgetWallet(eatingOutBudget: 20000);
        await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
            size: size, textScale: scale);
        final tile = find.byKey(const ValueKey('budgetLine'));
        expect(find.descendant(of: tile, matching: find.text('GROCERIES')), findsOneWidget);
        expect(find.descendant(of: tile, matching: find.text(_eur('48 €'))), findsOneWidget);
        expect(find.descendant(of: tile, matching: find.text('left')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('amounts are exact on the line: 47.50 € left, 0.49 € over', (tester) async {
      Future<void> pumpToday(WalletController wc) =>
          pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
              size: const Size(360, 3000));
      await pumpToday(budgetWallet(groceriesBudget: 29950, eatingOutBudget: 20000));
      expect(find.descendant(of: find.byKey(const ValueKey('budgetLine')), matching: find.text(_eur('47.50 €'))), findsOneWidget);
      await pumpToday(budgetWallet(groceriesBudget: 29950, eatingOutBudget: 11151));
      expect(find.descendant(of: find.byKey(const ValueKey('budgetLine')), matching: find.text(_eur('0.49 €'))), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('budgetLine')), matching: find.text('EATING OUT')), findsOneWidget);
    });

    testWidgets('over budget: the tile says so in a chip with an icon, the amount over in the value', (tester) async {
      final wc = budgetWallet();
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
          size: const Size(360, 3000));
      final tile = find.byKey(const ValueKey('budgetLine'));
      expect(find.descendant(of: tile, matching: find.text(_eur('12 €'))), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('Over budget')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
    });

    testWidgets('the tile sits among the number tiles, above Add expense', (tester) async {
      final wc = budgetWallet();
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
          size: const Size(360, 3000));
      final y = tester.getTopLeft(find.byKey(const ValueKey('budgetLine'))).dy;
      expect(y, greaterThan(tester.getBottomLeft(find.byKey(const ValueKey('heroTile'))).dy));
      expect(y, lessThan(tester.getTopLeft(find.text('Add expense').first).dy));
    });

    testWidgets('no budgets: no line', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
          size: const Size(360, 3000));
      expect(find.byKey(const ValueKey('budgetLine')), findsNothing);
      expect(find.textContaining('this month'), findsNothing);
    });

    testWidgets('tapping the line calls openSpending', (tester) async {
      var opened = 0;
      final wc = budgetWallet();
      await pumpApp(
          tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, openSpending: () => opened++, clock: () => budgetToday)),
          size: const Size(360, 3000));
      await tester.tap(find.byKey(const ValueKey('budgetLine')));
      expect(opened, 1);
    });

    testWidgets('in the app, the tap moves to the Spending tab', (tester) async {
      final wc = budgetWallet()..snoozeKeyBackup(); // the key row would push the budget line off the 800 dp screen
      await pumpApp(tester, HomeShell(wc: wc), size: const Size(360, 800));
      expect(find.byType(SpendingScreen), findsNothing);
      await tester.tap(find.byKey(const ValueKey('budgetLine')));
      await tester.pump();
      expect(find.byType(SpendingScreen), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);
      wc.dispose();
    });
  });
}
