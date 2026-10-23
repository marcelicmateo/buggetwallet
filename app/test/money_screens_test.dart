// The money screens for the hardened core (Stage H): payday passed, over budget, rows in another currency, low income,
// the Wishlist verdict. SYNTHETIC wallets on the fixed clock of `budgetWallet` (Tuesday 20 Oct 2026).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

/// A wallet whose pay period (1 Sep to 1 Oct) ended 19 days ago with money left.
WalletController passedWallet() {
  final wc = budgetWallet(budgets: false);
  wc.repo.updateSettings({'paydayDay': 1, 'periodStart': '2026-09-01'});
  wc.reload();
  return wc;
}

Widget today(WalletController wc, {DateTime? at}) =>
    Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => at ?? DateTime(2026, 10, 20, 10)));

/// Every Text on screen outside the transaction rows (those show spending as negative amounts, on purpose).
List<String> _texts(WidgetTester tester) => [
      for (final e in find.byType(Text).evaluate())
        if (e.findAncestorWidgetOfExactType<TxTile>() == null) (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText(),
    ];

String _hero(WidgetTester tester) => tester.widget<MoneyText>(find.byKey(const ValueKey('safeToSpend'))).text;

final _negativeAmount = RegExp('−\\s?\\d');

NormalizedTransaction _usd(String date, int cents) => NormalizedTransaction(
    id: transactionId(date, cents, 'SYNTHETIC USD SHOP', 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: 'USD',
    bankType: 'POS plaćanje',
    description: 'SYNTHETIC USD SHOP');

void main() {
  group('Today: payday passed', () {
    testWidgets('says the period ended, offers the new period, no "used", no 0 days, no negative', (tester) async {
      final wc = passedWallet();
      final p = wc.period();
      expect(p.paydayPassed, isTrue);
      expect(p.remaining, greaterThan(0));
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      final all = _texts(tester);
      expect(find.byKey(const ValueKey('periodEnded')), findsOneWidget);
      expect(all.any((t) => t.contains('The pay period ended on')), isTrue);
      expect(all.where((t) => t.contains('0 days') || t.contains('already used') || t.contains('Safe to spend')), isEmpty);
      expect(all.where(_negativeAmount.hasMatch), isEmpty);
      expect(find.byKey(const ValueKey('startNewPeriod')), findsOneWidget);
      expect(find.text('Start new period on ${shortDate(p.end)}'), findsOneWidget);
      // The hero is what is left, not zero or negative.
      expect(_hero(tester), money(p.remaining, 'EUR', decimals: 0));
    });

    testWidgets('the new-period button starts the period on the payday', (tester) async {
      final wc = passedWallet();
      final end = wc.period().end;
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      await tester.ensureVisible(find.byKey(const ValueKey('startNewPeriod')));
      await tester.tap(find.byKey(const ValueKey('startNewPeriod')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4)); // the controller's sync debounce
      expect(wc.settings.periodStart, end);
      expect(wc.period().paydayPassed, isFalse);
      expect(wc.period().daysLeft, greaterThan(0));
    });

    testWidgets('several missed paydays: one tap starts the latest period', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'paydayDay': 1, 'periodStart': '2026-07-01'});
      wc.reload();
      expect(wc.period().paydayPassed, isTrue);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.text('Start new period on ${shortDate('2026-10-01')}'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('startNewPeriod')));
      await tester.tap(find.byKey(const ValueKey('startNewPeriod')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(wc.settings.periodStart, '2026-10-01');
      expect(wc.period().paydayPassed, isFalse);
    });

    testWidgets('the new-period action has its own panel, not the main one', (tester) async {
      final wc = passedWallet();
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      final own = find.byKey(const ValueKey('periodEndedPanel'));
      expect(own, findsOneWidget);
      expect(find.descendant(of: own, matching: find.byKey(const ValueKey('startNewPeriod'))), findsOneWidget);
      expect(find.descendant(of: own, matching: find.byKey(const ValueKey('addExpense'))), findsNothing);
      expect(find.descendant(of: own, matching: find.byKey(const ValueKey('safeToSpend'))), findsNothing);
    });

    testWidgets('the delivery-hour panel says the period ended, never "already used"', (tester) async {
      final wc = passedWallet();
      wc.repo.addTransaction(date: '2026-09-25', amount: 1800, category: 'Food delivery'); // the panel needs an order in 90 days
      wc.reload();
      await pumpApp(tester, today(wc, at: DateTime(2026, 10, 20, 15)), size: const Size(400, 3000));
      expect(find.text('After-work delivery hour'), findsOneWidget);
      expect(find.textContaining('The pay period has ended'), findsWidgets);
      expect(find.textContaining('already used'), findsNothing);
      expect(find.textContaining("Today's money"), findsNothing);
    });

    testWidgets('over budget and passed: the overspend is named, hero is not negative', (tester) async {
      final wc = passedWallet();
      wc.repo.updateSettings({'salary': 30000});
      wc.reload();
      final p = wc.period();
      expect(p.paydayPassed && p.overBy > 0, isTrue);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      final all = _texts(tester);
      expect(all.any((t) => t.contains('over the plan') && t.contains(money(p.overBy, 'EUR'))), isTrue);
      expect(all.where(_negativeAmount.hasMatch), isEmpty);
    });
  });

  group('Today: over budget', () {
    testWidgets('over the period: overBy in words, no negative number', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'salary': 30000}); // 300 to plan, 424 spent
      wc.reload();
      final p = wc.period();
      expect(p.overBy, greaterThan(0));
      expect(p.paydayPassed, isFalse);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('overBudget')), findsOneWidget);
      expect(find.textContaining('Over the plan by ${money(p.overBy, 'EUR')} until payday.'), findsOneWidget);
      expect(_hero(tester), money(0, 'EUR', decimals: 0)); // nothing left for today
      expect(find.textContaining('ON PLAN'), findsNothing);
      expect(find.textContaining('On plan'), findsNothing);
      expect(find.textContaining('Over the plan'), findsWidgets);
      expect(_texts(tester).where(_negativeAmount.hasMatch), isEmpty);
    });

    testWidgets('over today only: "Over today by" and the amount, no negative number', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.addTransaction(date: '2026-10-20', amount: 20000, category: 'Shopping');
      wc.reload();
      final p = wc.period();
      expect(p.overToday, greaterThan(0));
      expect(p.allowanceToday, greaterThanOrEqualTo(0));
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.text('OVER TODAY BY'), findsOneWidget);
      expect(_hero(tester), money(p.overToday, 'EUR', decimals: 0));
      expect(_texts(tester).where(_negativeAmount.hasMatch), isEmpty);
    });

    testWidgets('the plan leaves no spending money: said, and no negative plan per day', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'salary': 0, 'rent': 10000});
      wc.reload();
      expect(wc.period().planDaily, lessThanOrEqualTo(0));
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('overBudget')), findsOneWidget);
      expect(find.textContaining('On plan'), findsNothing, reason: 'a green label while the plan is over');
      expect(find.textContaining('Over the plan'), findsWidgets);
      expect(find.textContaining('tomorrow gets more'), findsNothing);
      // item 5: no pace bar or "used" line that contradicts the message
      expect(find.byType(PaceBar), findsNothing);
      expect(find.textContaining('behind pace'), findsNothing);
      expect(find.textContaining(' used'), findsNothing);
      expect(_texts(tester).where(_negativeAmount.hasMatch), isEmpty);
    });

    testWidgets('a running plan keeps "On plan" and the tomorrow sentence', (tester) async {
      await pumpApp(tester, today(budgetWallet(budgets: false)), size: const Size(400, 3000));
      expect(find.textContaining('On plan'), findsOneWidget);
      expect(find.textContaining('tomorrow gets more'), findsOneWidget);
      expect(find.byType(PaceBar), findsOneWidget);
    });

    testWidgets('a small overspend is shown to the cent, never "0 €"', (tester) async {
      final wc = budgetWallet(budgets: false);
      final allowance = wc.period().allowanceToday;
      wc.repo.addTransaction(date: '2026-10-20', amount: allowance + 49, category: 'Shopping');
      wc.reload();
      expect(wc.period().overToday, 49);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(_hero(tester), moneyExact(49, 'EUR'));
      // and the period figure
      final w2 = budgetWallet(budgets: false);
      w2.repo.updateSettings({'salary': 42350}); // 50 cents under the 424 spent
      w2.reload();
      expect(w2.period().overBy, 50);
      await pumpApp(tester, today(w2), size: const Size(400, 3000));
      expect(find.text(moneyExact(50, 'EUR')), findsOneWidget); // the stat strip
    });

    testWidgets('320 dp at text scale 2.0 does not overflow (ended, over, foreign)', (tester) async {
      for (final wc in [
        passedWallet(),
        budgetWallet(budgets: false)..repo.updateSettings({'salary': 30000})
      ]) {
        wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_usd('2026-10-10', -1200)]));
        wc.reload();
        await pumpApp(tester, today(wc, at: DateTime(2026, 10, 20, 15)), size: const Size(320, 4000), textScale: 2);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('rows in another currency', () {
    testWidgets('Today: one muted line, and the totals leave the row out', (tester) async {
      final wc = budgetWallet(budgets: false);
      final before = wc.period();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_usd('2026-10-10', -1200), _usd('2026-10-11', 500)]));
      wc.reload();
      final p = wc.period();
      expect(p.spent, before.spent);
      expect(p.foreignByCurrency, {'USD': -700});
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('foreignNote')), findsOneWidget);
      expect(find.text('Other currencies, not counted: ${moneyExact(700, 'USD')} spent'), findsOneWidget);
      expect(_texts(tester).where(_negativeAmount.hasMatch), isEmpty);
    });

    testWidgets('Today: no line without foreign rows', (tester) async {
      await pumpApp(tester, today(budgetWallet(budgets: false)), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('foreignNote')), findsNothing);
      expect(find.textContaining('not counted'), findsNothing);
    });

    testWidgets('Spending month view: the line per currency, sorted by code', (tester) async {
      final wc = budgetWallet(budgets: false);
      final out = wc.spending(null).summary.out;
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        _usd('2026-10-10', -1200),
        NormalizedTransaction(
            id: transactionId('2026-10-12', -3050, 'SYNTHETIC GBP SHOP', 0),
            source: 'pbz',
            date: '2026-10-12',
            amountMinor: -3050,
            currency: 'GBP',
            bankType: 'POS plaćanje',
            description: 'SYNTHETIC GBP SHOP'),
      ]));
      wc.reload();
      expect(wc.spending(null).summary.out, out);
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 4000));
      expect(find.byKey(const ValueKey('foreignNote')), findsOneWidget);
      final line = 'Other currencies, not counted: ${moneyExact(3050, 'GBP')} spent, ${moneyExact(1200, 'USD')} spent';
      expect(find.text(line), findsOneWidget);
      expect(line.contains('−'), isFalse);
    });

    testWidgets('a net received amount says received', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_usd('2026-10-11', 500)]));
      wc.reload();
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.text('Other currencies, not counted: ${moneyExact(500, 'USD')} received'), findsOneWidget);
    });

    testWidgets('Spending month view: no line without foreign rows', (tester) async {
      await pumpApp(tester, Scaffold(body: SpendingScreen(wc: budgetWallet(budgets: false))), size: const Size(400, 4000));
      expect(find.byKey(const ValueKey('foreignNote')), findsNothing);
    });
  });

  group('Plan: low income', () {
    WalletController wallet(String start, String received) {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'paydayDay': 1, 'periodStart': start});
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx(received, 100000, 'Plaća/Mirovina', 'Neto placa synthetic part'), // 1000 of a planned 1500
      ]));
      wc.reload();
      return wc;
    }

    testWidgets('after the 7-day window the warning shows (core says lowIncome)', (tester) async {
      final wc = wallet('2026-10-01', '2026-10-02');
      expect(wc.period().lowIncome, isTrue);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 4000));
      expect(find.textContaining('Salary received so far'), findsOneWidget);
    });

    testWidgets('inside the window (parts still arriving) no warning', (tester) async {
      final wc = wallet('2026-10-15', '2026-10-16');
      expect(wc.period().lowIncome, isFalse);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 4000));
      expect(find.textContaining('Salary received so far'), findsNothing);
    });
  });

  group('Plan: heading', () {
    testWidgets('a plan with nothing left says by how much it is over, not a negative per day', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'salary': 0, 'rent': 10000});
      wc.reload();
      final p = wc.period();
      expect(p.planDaily, lessThanOrEqualTo(0));
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 4000));
      final heading = tester.widget<Heading>(find.byKey(const ValueKey('planHeading'))).text;
      expect(heading, 'Nothing to spend: the plan is ${moneyExact(-p.flexBudget, 'EUR')} over');
      expect(heading.contains('−'), isFalse);
    });

    testWidgets('a normal plan keeps "to spend"', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 4000));
      expect(tester.widget<Heading>(find.byKey(const ValueKey('planHeading'))).text, contains('to spend'));
    });
  });

  group('Plan: payday 31', () {
    testWidgets('saved as 28 by core and shown as 28', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 4000));
      final f = find.widgetWithText(TextField, 'Latest payday');
      await tester.ensureVisible(f);
      await tester.enterText(f, '31');
      final btn = find.widgetWithText(FilledButton, 'Save numbers');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(wc.settings.paydayDay, 28);
      expect(tester.widget<TextField>(f).controller!.text, '28');
    });
  });

  group('Wishlist verdicts', () {
    Future<void> check(WidgetTester tester, WalletController wc, String price) async {
      await pumpApp(tester, Scaffold(body: WishlistScreen(wc: wc)), size: const Size(400, 3000));
      await tester.enterText(find.widgetWithText(TextField, 'Price'), price);
      await tester.pump();
    }

    testWidgets('over budget: its own words, never "for the next 0 days"', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'salary': 30000});
      wc.reload();
      final p = wc.period();
      expect(affordability(1000, p).verdict, Verdict.overBudget);
      await check(tester, wc, '10');
      expect(find.byKey(const ValueKey('verdictOverBudget')), findsOneWidget);
      expect(find.textContaining('over the plan until payday'), findsOneWidget);
      expect(find.textContaining('for the next'), findsNothing);
      expect(_texts(tester).where(_negativeAmount.hasMatch), isEmpty);
    });

    testWidgets('payday passed: says the period ended, no day count', (tester) async {
      final wc = passedWallet();
      expect(affordability(1000, wc.period()).verdict, Verdict.later);
      await check(tester, wc, '10');
      expect(find.byKey(const ValueKey('verdictEnded')), findsOneWidget);
      expect(find.textContaining('The pay period has ended'), findsOneWidget);
      expect(find.textContaining('for the next'), findsNothing);
      expect(find.textContaining('0 days'), findsNothing);
    });

    testWidgets('over budget after payday says "this period", not "until payday"', (tester) async {
      final wc = passedWallet();
      wc.repo.updateSettings({'salary': 30000});
      wc.reload();
      expect(wc.period().overBudget && wc.period().paydayPassed, isTrue);
      await check(tester, wc, '10');
      expect(find.textContaining('over the plan this period'), findsOneWidget);
      expect(find.textContaining('until payday'), findsNothing);
    });

    testWidgets('one day left says "1 day"', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'paydayDay': 21, 'periodStart': '2026-09-21'}); // ends 21 Oct, today is the 20th
      wc.reload();
      expect(wc.period().daysLeft, 1);
      await check(tester, wc, '10');
      expect(find.textContaining('for the next 1 day.'), findsOneWidget);
      expect(find.textContaining('1 days'), findsNothing);
    });

    testWidgets('a normal period keeps the daily-budget sentence', (tester) async {
      final wc = budgetWallet(budgets: false);
      await check(tester, wc, '10');
      expect(find.textContaining('Your daily budget would drop'), findsOneWidget);
    });
  });
}
