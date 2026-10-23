// Budget vs actual on Spending and Today, and the controller's cached budget values. All data is SYNTHETIC (budgetWallet).
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
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
    for (final (name, size, scale) in _sizes) {
      testWidgets('$name: budgeted rows show what is left, the over one is marked, a summary and a total row', (tester) async {
        final wc = budgetWallet();
        await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: size, textScale: scale);
        expect(find.text(_eur('48 € left')), findsOneWidget);
        expect(find.text(_eur('over by 12 €')), findsOneWidget);
        expect(find.text(_eur('of 300 €')), findsOneWidget);
        expect(find.text(_eur('of 100 €')), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsNWidgets(2), reason: 'the over row and the summary line');
        expect(find.byKey(const ValueKey('overHatch')), findsOneWidget);
        expect(find.textContaining('1 over, 1 behind pace, ${_eur('36 € left')} in total'), findsOneWidget);
        expect(find.byKey(const ValueKey('behindPace')), findsOneWidget, reason: 'Groceries: 84 % spent, 65 % of the month gone');
        expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
        expect(find.byKey(const ValueKey('budgetTotal')), findsOneWidget);
        expect(find.text(_eur('364 € of 400 €')), findsOneWidget);
        expect(find.descendant(of: find.byType(CategoryBars), matching: find.text(_eur('60 €'))), findsOneWidget,
            reason: 'Shopping has no budget: its amount as before');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('nothing budgeted: the rows are as before and there is no summary or total', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.textContaining('left'), findsNothing);
      expect(find.textContaining('over budget'), findsNothing);
      expect(find.byKey(const ValueKey('overHatch')), findsNothing);
      expect(find.byKey(const ValueKey('budgetTotal')), findsNothing);
      for (final v in ['252 €', '112 €']) {
        expect(find.descendant(of: find.byType(CategoryBars), matching: find.text(_eur(v))), findsOneWidget);
      }
    });

    testWidgets('within budget but behind pace: "behind pace" with a warning icon in warnInk, no hatch', (tester) async {
      final wc = budgetWallet(eatingOutBudget: 20000);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.byKey(const ValueKey('overHatch')), findsNothing);
      expect(find.textContaining('0 over, 1 behind pace, ${_eur('136 € left')} in total'), findsOneWidget);
      final label = find.descendant(of: find.byKey(const ValueKey('behindPace')), matching: find.text('behind pace'));
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).style!.color, WalletColors.light.warnInk);
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    });

    testWidgets('on pace: nothing extra, the summary counts none over', (tester) async {
      // Groceries 252 of 400 is 63 % of the budget at 65 % of the month: on pace. Eating out 112 of 200 likewise.
      final wc = budgetWallet(eatingOutBudget: 20000, groceriesBudget: 40000);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.byKey(const ValueKey('behindPace')), findsNothing);
      expect(find.byKey(const ValueKey('overHatch')), findsNothing);
      expect(find.textContaining('0 of 2 categories over budget, ${_eur('236 € left')} in total'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
    });

    testWidgets('behind pace fits 320 dp at text 2.0', (tester) async {
      final wc = budgetWallet(eatingOutBudget: 20000);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(320, 4000), textScale: 2.0);
      expect(find.byKey(const ValueKey('behindPace')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('amounts are exact: 47.50 € left and over by 0.49 €, never rounded to whole euros', (tester) async {
      // Groceries 252 of 299.50 (4750 left), Eating out 112 of 111.51 (49 over).
      final wc = budgetWallet(groceriesBudget: 29950, eatingOutBudget: 11151);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.text(_eur('47.50 € left')), findsOneWidget);
      expect(find.text(_eur('over by 0.49 €')), findsOneWidget);
      expect(find.text(_eur('of 299.50 €')), findsOneWidget);
      expect(find.text(_eur('of 111.51 €')), findsOneWidget);
      expect(find.textContaining('1 over, 1 behind pace, ${_eur('47.01 € left')} in total'), findsOneWidget);
      expect(find.textContaining('over by 0 €'), findsNothing);
      expect(find.textContaining('48 € left'), findsNothing);
    });

    testWidgets('a budgeted category with no spending yet still shows its budget', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.setCategoryBudget('Sport & fitness', 4000);
      wc.reload();
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(360, 3000));
      expect(find.text(_eur('40 € left')), findsNWidgets(2), reason: 'the row and the total');
      expect(find.textContaining('0 of 1 category over budget'), findsOneWidget);
    });
  });

  group('Today › budget line', () {
    for (final (name, size, scale) in _sizes) {
      testWidgets('$name: the least-left category shows under the stats', (tester) async {
        final wc = budgetWallet(eatingOutBudget: 20000);
        await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday)), size: size, textScale: scale);
        expect(find.text(_eur('Groceries: 48 € left this month')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('amounts are exact on the line: 47.50 € left, over by 0.49 €', (tester) async {
      Future<void> pumpToday(WalletController wc) =>
          pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday)), size: const Size(360, 3000));
      await pumpToday(budgetWallet(groceriesBudget: 29950, eatingOutBudget: 20000));
      expect(find.text(_eur('Groceries: 47.50 € left this month')), findsOneWidget);
      await pumpToday(budgetWallet(groceriesBudget: 29950, eatingOutBudget: 11151));
      expect(find.text(_eur('Eating out: over by 0.49 €')), findsOneWidget);
    });

    testWidgets('over budget: the line says so, in the bad colour with an icon', (tester) async {
      final wc = budgetWallet();
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday)), size: const Size(360, 3000));
      final t = find.text(_eur('Eating out: over by 12 €'));
      expect(t, findsOneWidget);
      expect(tester.widget<Text>(t).style!.color, WalletColors.light.bad);
      expect(find.descendant(of: find.byKey(const ValueKey('budgetLine')), matching: find.byIcon(Icons.error_outline)), findsOneWidget);
    });

    testWidgets('the line sits below the pace line and above Add expense', (tester) async {
      final wc = budgetWallet();
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday)), size: const Size(360, 3000));
      final y = tester.getTopLeft(find.byKey(const ValueKey('budgetLine'))).dy;
      expect(y, greaterThan(tester.getBottomLeft(find.textContaining('used').first).dy));
      expect(y, lessThan(tester.getTopLeft(find.text('Add expense').first).dy));
    });

    testWidgets('no budgets: no line', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday)), size: const Size(360, 3000));
      expect(find.byKey(const ValueKey('budgetLine')), findsNothing);
      expect(find.textContaining('this month'), findsNothing);
    });

    testWidgets('tapping the line calls openSpending', (tester) async {
      var opened = 0;
      final wc = budgetWallet();
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, openSpending: () => opened++, clock: () => budgetToday)),
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
