// P9 app half: recurring income in Plan › Expected income (candidate, Confirm, Add income sheet and its validation), kept out of the
// Expected bills panel, the Payday plan ledger lines before and after an income lands, Today's expected-income line, Goals reading
// extrasForGoals, and the layout at 360 dp / text scale 2.0. SYNTHETIC data (habitsWallet: Tuesday 20 Oct 2026, pay period from 1 Oct).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/goals.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

NormalizedTransaction payout(String date, int cents) => syntheticTx(date, cents, 'Ostalo', 'Quorvant Payout 2026');

/// habitsWallet plus three monthly payouts of 300 on the 20th (July to September): one income candidate due today, not landed.
WalletController incomeWallet({bool landed = false, bool confirm = false}) {
  final wc = habitsWallet();
  addTearDown(wc.dispose);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    payout('2026-07-20', 30000),
    payout('2026-08-20', 30000),
    payout('2026-09-20', 30000),
    if (landed) payout('2026-10-20', 30000),
  ]));
  wc.reload();
  wc.refreshRecurring();
  if (confirm) wc.confirmRecurring(wc.expectedIncomes().single.id);
  return wc;
}

/// The payout arrives on the 20th (the refresh moves the income on).
void landPayout(WalletController wc) {
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [payout('2026-10-20', 30000)]));
  wc.reload();
  wc.refreshRecurring();
}

void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    }, timeout: const Timeout(Duration(seconds: 60)));

Future<void> plan(WidgetTester tester, WalletController wc, {Size size = const Size(400, 1400), double scale = 1}) =>
    pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: size, textScale: scale);

Future<void> todayPage(WidgetTester tester, WalletController wc) => pumpApp(
    tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday, chooser: const FileChooser(), openBills: () {})),
    size: const Size(400, 1600));

Future<void> see(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> tapKey(WidgetTester tester, String key) async {
  if (find.byKey(ValueKey(key)).evaluate().isEmpty) await see(tester, find.byKey(ValueKey(key)));
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> typeIn(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

Future<void> pickExtraTag(WidgetTester tester) async {
  await tapKey(tester, 'recurringCategory');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(const ValueKey('pick:Extra income')).last);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('Expected income panel', () {
    tw('a candidate shows Confirm and Not regular; Confirm makes a confirmed row', (tester) async {
      final wc = incomeWallet();
      final id = wc.expectedIncomes().single.id;
      expect(id, startsWith('recin:'));
      await plan(tester, wc);
      await see(tester, find.byKey(const ValueKey('expectedIncomePanel')));
      expect(find.text('EXPECTED INCOME'), findsOneWidget);
      expect(find.text('Looks like regular income'), findsOneWidget);
      expect(find.byKey(ValueKey('incomeCandidate:$id')), findsOneWidget);
      expect(find.text('Not regular'), findsOneWidget);
      await tapKey(tester, 'incomeConfirm:$id');
      await settle(tester);
      expect(wc.expectedIncomes().single.confirmed, isTrue);
      expect(find.byKey(ValueKey('income:$id')), findsOneWidget);
      expect(find.byKey(ValueKey('incomeCandidate:$id')), findsNothing);
      expect(find.byKey(ValueKey('incomeDelete:$id')), findsOneWidget);
    });

    tw('Not regular hides the candidate', (tester) async {
      final wc = incomeWallet();
      final id = wc.expectedIncomes().single.id;
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('incomeDismiss:$id')));
      await tapKey(tester, 'incomeDismiss:$id');
      await settle(tester);
      expect(wc.expectedIncomes(), isEmpty);
      expect(find.byKey(ValueKey('incomeCandidate:$id')), findsNothing);
    });

    tw('the Expected bills panel never lists an income, and the income panel never lists a bill', (tester) async {
      final wc = incomeWallet(confirm: true);
      final income = wc.expectedIncomes().single;
      expect(wc.expectedBills().where((b) => b.isIncome), isEmpty);
      expect(wc.expectedBills(), isNotEmpty); // the synthetic gym candidate
      await plan(tester, wc);
      await see(tester, find.byKey(const ValueKey('addRecurring')));
      for (final k in ['candidate:${income.id}', 'bill:${income.id}', 'confirm:${income.id}']) {
        expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
      }
      for (final b in wc.expectedBills()) {
        expect(find.byKey(ValueKey('income:${b.id}')), findsNothing);
        expect(find.byKey(ValueKey('incomeCandidate:${b.id}')), findsNothing);
      }
      // A bill history of an income id is not offered either.
      expect(wc.billHistoryFor(income.id), isNull);
    });

    tw('Remove income shows Undo, which brings it back', (tester) async {
      final wc = incomeWallet(confirm: true);
      final id = wc.expectedIncomes().single.id;
      await plan(tester, wc);
      await tapKey(tester, 'incomeDelete:$id');
      await settle(tester);
      expect(wc.expectedIncomes(), isEmpty);
      expect(find.text('Income removed'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      final back = wc.expectedIncomes().single;
      expect(back.confirmed, isTrue);
      expect(back.expectedAmount, 30000);
      expect(back.isIncome, isTrue);
    });
  });

  group('Add income', () {
    tw('the sheet is in income mode: income tags only, no instalments, no held text; no payee is refused with core\'s text',
        (tester) async {
      final wc = incomeWallet();
      await plan(tester, wc);
      await tapKey(tester, 'addIncome');
      await settle(tester);
      expect(find.byKey(const ValueKey('incomeSheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('recurringSheet')), findsNothing);
      expect(find.text('Add income'), findsWidgets);
      expect(find.byKey(const ValueKey('recurringEnds')), findsNothing);
      expect(find.textContaining('set aside'), findsNothing);
      expect(find.textContaining('Held'), findsNothing);
      // Main tags: only kind extra.
      await tapKey(tester, 'recurringCategory');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('pick:Extra income')), findsWidgets);
      expect(find.byKey(const ValueKey('pick:Salary')), findsNothing);
      expect(find.byKey(const ValueKey('pick:Groceries')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pick:Extra income')).last);
      await tester.pump(const Duration(milliseconds: 300));
      await typeIn(tester, 'recurringName', 'Side job');
      await typeIn(tester, 'recurringAmount', '300');
      await tapKey(tester, 'recurringSave');
      await settle(tester);
      expect(find.byKey(const ValueKey('recurringError')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('recurringError')), matching: find.textContaining('Pick the payee the income comes from')),
          findsOneWidget);
      expect(wc.expectedIncomes().where((b) => b.manual), isEmpty);
    });

    tw('a complete income is saved confirmed and listed', (tester) async {
      final wc = incomeWallet();
      wc.dismissRecurring(wc.expectedIncomes().single.id); // the detected candidate would own the payee
      await plan(tester, wc);
      await tapKey(tester, 'addIncome');
      await settle(tester);
      await pickExtraTag(tester);
      await typeIn(tester, 'recurringName', 'Side job');
      await typeIn(tester, 'recurringAmount', '300');
      await tapKey(tester, 'recurringPayee');
      await tester.pump(const Duration(milliseconds: 300));
      final payee = wc.incomePayees().firstWhere((p) => p.key.contains('quorvant')).key;
      await tester.tap(find.byKey(ValueKey('payeeItem:$payee')).last);
      await tester.pump(const Duration(milliseconds: 300));
      await tapKey(tester, 'recurringSave');
      await settle(tester);
      expect(find.byKey(const ValueKey('incomeSheet')), findsNothing);
      final mine = wc.expectedIncomes().where((b) => b.manual).single;
      expect(mine.isIncome, isTrue);
      expect(mine.confirmed, isTrue);
      expect(mine.label, 'Side job');
      expect(mine.expectedAmount, 30000);
      expect(find.byKey(ValueKey('income:${mine.id}')), findsOneWidget);
    });

    test('core refusals reach the controller: a salary tag and instalments', () {
      final wc = incomeWallet();
      String? fail(void Function() f) {
        try {
          f();
        } on ArgumentError catch (e) {
          return '${e.message}';
        }
        return null;
      }

      final payee = wc.incomePayees().first.key;
      void add(String category, {int? instalments}) => wc.addRecurringBill(
          label: 'Pay',
          category: category,
          amount: 1000,
          intervalDays: 30,
          firstDue: '2026-11-01',
          payee: payee,
          instalments: instalments,
          direction: RecurringBill.directionIn);
      expect(fail(() => add('Salary')), 'This tag already counts as salary.');
      expect(fail(() => add('Extra income', instalments: 3)), 'An income has no instalments.');
    });
  });

  group('Payday plan ledger', () {
    tw('before it lands: the "Expected, not counted yet" line; after: "Extra income received" and no expected line', (tester) async {
      final wc = incomeWallet(confirm: true);
      expect(wc.period().expectedIncome, hasLength(1));
      await plan(tester, wc);
      await see(tester, find.byKey(const ValueKey('ledgerSpendingMoney')));
      expect(find.byKey(const ValueKey('ledgerLandedIncome')), findsNothing);
      expect(find.byKey(const ValueKey('ledgerExpectedIncome')), findsOneWidget);
      expect(find.textContaining('Expected, not counted yet:'), findsOneWidget);
      final before = wc.period().flexBudget;

      landPayout(wc);
      expect(wc.period().landedIncome, 30000);
      expect(wc.period().flexBudget, before + 30000);
      await plan(tester, wc);
      await see(tester, find.byKey(const ValueKey('ledgerSpendingMoney')));
      expect(find.byKey(const ValueKey('ledgerLandedIncome')), findsOneWidget);
      expect(find.text('Extra income received'), findsOneWidget);
      expect(find.textContaining('+300'), findsOneWidget);
      expect(find.byKey(const ValueKey('ledgerExpectedIncome')), findsNothing);
    });
  });

  group('Today', () {
    tw('the expected-income line shows while it is expected and the hero does not change; it goes when the income lands', (tester) async {
      final wc = incomeWallet(confirm: true);
      final flexBefore = wc.period().flexBudget;
      await todayPage(tester, wc);
      expect(find.byKey(const ValueKey('expectedIncomeLine')), findsOneWidget);
      expect(find.textContaining('Expected income:'), findsOneWidget);
      expect(find.textContaining('(counts when it lands)'), findsOneWidget);
      expect(wc.period().flexBudget, flexBefore);

      landPayout(wc);
      await todayPage(tester, wc);
      expect(find.byKey(const ValueKey('expectedIncomeLine')), findsNothing);
    });

    tw('no income, no line', (tester) async {
      final wc = habitsWallet();
      addTearDown(wc.dispose);
      await todayPage(tester, wc);
      expect(find.byKey(const ValueKey('expectedIncomeLine')), findsNothing);
    });
  });

  group('Goals', () {
    tw('income that landed is spending money, not "Extra money" for goals', (tester) async {
      final wc = incomeWallet(landed: true, confirm: true);
      final p = wc.period();
      expect(p.landedIncome, 30000);
      expect(p.extrasForGoals, p.extras - 30000);
      await pumpApp(tester, Scaffold(body: GoalsScreen(wc: wc)), size: const Size(400, 1600));
      expect(find.textContaining('Other income: 300'), findsNothing);
      if (p.extrasForGoals <= 0) expect(find.text('Extra money this month'), findsNothing);
    });
  });

  group('Layout', () {
    for (final (w, scale) in [(320.0, 2.0), (360.0, 2.0), (360.0, 1.0)]) {
      tw('Expected income panel and the Add income sheet fit at ${w.round()} dp, text scale $scale', (tester) async {
        final wc = incomeWallet();
        wc.confirmRecurring(wc.expectedIncomes().single.id);
        wc.addRecurringBill(
            label: 'Long named side income',
            category: 'Extra income',
            amount: 12345,
            minAmount: 10000,
            maxAmount: 12345,
            intervalDays: 7,
            firstDue: '2026-10-27',
            payee: 'other_payee',
            direction: RecurringBill.directionIn);
        await plan(tester, wc, size: Size(w, 1600), scale: scale);
        await see(tester, find.byKey(const ValueKey('addIncome')));
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'addIncome');
        await settle(tester);
        expect(find.byKey(const ValueKey('incomeSheet')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
