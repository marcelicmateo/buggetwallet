// ENG E6 UI (docs/context/ENG_UI_SPEC.md §5.5): the goal planner, "I bought it" with Undo, the Loan screen and the plan's loan lines.
// SYNTHETIC data only; the wallet is `budgetWallet()` (20 Oct 2026).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/goal_new.dart';
import 'package:budget_wallet/src/screens/goal_planner.dart';
import 'package:budget_wallet/src/screens/goals.dart';
import 'package:budget_wallet/src/screens/loan_screen.dart';
import 'package:budget_wallet/src/screens/payday_plan.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

const _big = Size(400, 3200);
Finder _key(String k) => find.byKey(ValueKey(k));
Finder _in(String k, String text) => find.descendant(of: _key(k), matching: find.text(text));

WalletController _wallet() {
  final wc = budgetWallet();
  addTearDown(wc.dispose);
  return wc;
}

/// A financed goal: price 200,000.00, deposit 20 %, costs 6 % (property), 30 years, [saved] in the fund, [monthly] a month.
String _boat(WalletController wc, {int saved = 1000000, int monthly = 100000}) {
  final id = wc.addBigGoal(name: 'Boat', price: 20000000, financed: true, property: true)!;
  final g = wc.goalOf(id)!;
  wc.saveGoalDraft(id, GoalDraft.of(g)..monthly = monthly);
  wc.repo.saveGoal(id: id, name: 'Boat', target: wc.goalOf(id)!.target, saved: saved, monthly: monthly);
  wc.reload();
  return id;
}

/// A loan of 12,000.00 at 6 % over 12 months from [first], paid to "LENDER SYNTHETIC".
String _loan(WalletController wc, String first, {List<String> paid = const []}) {
  final id = wc.addLoan(Loan(
      id: '',
      name: 'Car loan',
      principal: 1200000,
      rateBp: 600,
      months: 12,
      firstDue: first,
      payeeKey: wc.payeeKeyOf('LENDER SYNTHETIC')))!;
  if (paid.isNotEmpty) {
    wc.repo.importBatch(
        ImportBatch(source: 'pbz', transactions: [for (final d in paid) syntheticTx(d, -103000, 'Trajni nalog', 'LENDER SYNTHETIC 123')]));
    wc.reload();
  }
  return id;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// A widget test that lets the controller's 3 s sync debounce run out (every write through the controller arms it).
void _test(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    });

void main() {
  group('planner', () {
    _test('the ledger foots and the ready month is core\'s', (t) async {
      final wc = _wallet();
      final id = _boat(wc);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      final g = wc.goalOf(id)!;
      final plan = wc.planFor(g, GoalDraft.of(g));
      // deposit 40,000.00 + costs 12,000.00 - in the fund 10,000.00 = still to save 42,000.00
      expect([plan.deposit, plan.costs, plan.need - plan.left, plan.left], [4000000, 1200000, 1000000, 4200000]);
      expect(plan.deposit + plan.costs - (plan.need - plan.left), plan.left);
      expect(_in('ledgerDeposit', moneyExact(plan.deposit, 'EUR')), findsOneWidget);
      expect(_in('ledgerCosts', moneyExact(plan.costs, 'EUR')), findsOneWidget);
      expect(_in('ledgerSaved', '−${moneyExact(1000000, 'EUR')}'), findsOneWidget);
      expect(_in('ledgerLeft', moneyExact(plan.left, 'EUR')), findsOneWidget);
      expect(_in('ledgerLoan', moneyExact(16000000, 'EUR')), findsOneWidget);
      // No rate typed: the payment is the loan over the 360 months, rounded up to the cent.
      expect(_in('ledgerPayment', moneyExact(44445, 'EUR')), findsOneWidget);
      expect(_key('plannerNoRate'), findsOneWidget);
      // 42,000.00 at 1,000.00 a month = 42 months from Oct 2026.
      expect(plan.months, 42);
      expect(_in('plannerHero', 'April 2030'), findsOneWidget);
      expect(find.textContaining('in 3 y 6 m'), findsOneWidget);
      expect(_key('plannerChart'), findsOneWidget);
      expect(find.text("Estimate only. The lender's offer gives the exact numbers."), findsOneWidget);
    });

    _test('no monthly amount: asks for one, with no division', (t) async {
      final wc = _wallet();
      final id = _boat(wc, monthly: 0);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      expect(_in('plannerHero', 'Set a monthly amount'), findsOneWidget);
      expect(_key('plannerChart'), findsNothing);
    });

    _test('typing the price writes the goal and its target', (t) async {
      final wc = _wallet();
      final id = _boat(wc);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      await t.tap(_key('plannerPrice:value'));
      await _settle(t);
      await t.enterText(_key('askField'), '300000');
      await t.tap(_key('askOk'));
      await _settle(t);
      final g = wc.goalOf(id)!;
      expect(g.price, 30000000);
      // target follows what is needed (20 % + 6 % of 300,000.00), so the Save tab's ring agrees
      expect(g.target, 7800000);
      expect(_in('ledgerLeft', moneyExact(6800000, 'EUR')), findsOneWidget);
    });

    _test('a rate typed by the owner changes the payment (annuity)', (t) async {
      final wc = _wallet();
      final id = _boat(wc);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      await t.tap(_key('plannerRate:value'));
      await _settle(t);
      await t.enterText(_key('askField'), '3.6');
      await t.tap(_key('askOk'));
      await _settle(t);
      expect(wc.goalOf(id)!.loanRateBp, 360);
      final g = wc.goalOf(id)!;
      expect(_in('ledgerPayment', moneyExact(wc.planFor(g, GoalDraft.of(g)).payment!, 'EUR')), findsOneWidget);
      expect(_key('plannerNoRate'), findsNothing);
    });

    _test('ready: the card says so, Not yet hides it', (t) async {
      final wc = _wallet();
      final id = _boat(wc, saved: 5200000);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      expect(_in('plannerReady', 'Boat is ready'), findsOneWidget);
      expect(_in('plannerHero', 'Now'), findsOneWidget);
      expect(wc.goalReady(wc.goalOf(id)!), isTrue);
      await t.tap(_key('plannerNotYet'));
      await _settle(t);
      expect(_key('plannerReady'), findsNothing);
      expect(_key('plannerIBoughtLate'), findsOneWidget);
    });

    _test('I bought it: picked rows, Confirm, then Undo restores the goal and removes the loan', (t) async {
      final wc = _wallet();
      final id = _boat(wc, saved: 5200000);
      wc.repo.addTransaction(date: '2026-10-14', amount: 4000000, category: 'Shopping');
      wc.reload();
      final row = wc.purchaseCandidates().firstWhere((x) => x.amount == -4000000);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      await t.tap(_key('plannerIBought'));
      await _settle(t);
      expect(_key('boughtSheet'), findsOneWidget);
      // the loan as the plan guessed it, marked Unsure until touched
      expect(find.text('Unsure: from the plan. Check it.'), findsWidgets);
      await t.tap(_key('pick:${row.id}'));
      await t.pump();
      expect(find.text('1 picked'), findsOneWidget);
      await t.enterText(_key('lf:rate'), '3.6');
      await t.pump();
      await t.tap(_key('boughtConfirm'));
      await _settle(t);
      var g = wc.goalOf(id)!;
      expect(g.boughtAt, wc.today());
      expect(g.loanId, 'l:goal:$id');
      final loan = wc.repo.loans().single;
      expect([loan.principal, loan.rateBp, loan.months], [16000000, 360, 360]);
      expect(_key('plannerBought'), findsOneWidget);
      expect(wc.settings.loanLines.keys, contains(loan.id));
      await t.tap(_key('toastUndo'));
      await _settle(t);
      g = wc.goalOf(id)!;
      expect([g.boughtAt, g.loanId], [null, null]);
      expect(wc.repo.loans(), isEmpty);
      expect(wc.settings.loanLines, isEmpty);
      expect(g.saved, 5200000);
    });

    _test('Confirm with the rate missing writes nothing', (t) async {
      final wc = _wallet();
      final id = _boat(wc, saved: 5200000);
      await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: _big);
      await t.tap(_key('plannerIBought'));
      await _settle(t);
      await t.tap(_key('boughtConfirm'));
      await _settle(t);
      expect(_key('boughtError'), findsOneWidget);
      expect(wc.goalOf(id)!.boughtAt, isNull);
      expect(wc.repo.loans(), isEmpty);
    });

    _test('+ Goal with a loan: property starts at 6 % costs and 30 years, a car at 0 % and 5 years', (t) async {
      final wc = _wallet();
      String? result;
      await pumpApp(
          t,
          Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      key: const ValueKey('open'),
                      onPressed: () async => result = await showDialog<String>(
                          context: context, builder: (_) => Dialog(child: SingleChildScrollView(child: GoalKindSheet(wc: wc)))),
                      child: const Text('open')))),
          size: _big);
      for (final property in [true, false]) {
        await t.tap(_key('open'));
        await _settle(t);
        await t.tap(find.text('With a loan'));
        await t.pump();
        await t.enterText(_key('goalLoanName'), property ? 'Flat' : 'Car');
        await t.enterText(_key('goalLoanPrice'), '15000');
        if (property) await t.tap(_key('goalProperty'));
        await t.pump();
        await t.tap(_key('goalLoanPlan'));
        await _settle(t);
        final g = wc.goals.firstWhere((x) => x.name == (property ? 'Flat' : 'Car'));
        expect(result, 'planner:${g.id}');
        expect([g.price, g.depositPermille, g.costsPermille, g.loanMonths], [1500000, 200, property ? 60 : 0, property ? 360 : 60]);
        expect(g.target, wc.planFor(g, GoalDraft.of(g)).need);
      }
    });

    _test('a priced goal opens the planner from the Goals tile', (t) async {
      final wc = _wallet();
      final id = _boat(wc);
      await pumpApp(t, GoalsScreen(wc: wc), size: _big);
      await t.tap(_key('goal:$id'));
      await _settle(t);
      expect(find.byType(GoalPlannerScreen), findsOneWidget);
    });
  });

  group('loan screen', () {
    _test('the numbers are loanSchedule and loanState', (t) async {
      final wc = _wallet();
      final id = _loan(wc, '2026-08-15', paid: ['2026-08-15', '2026-09-15']);
      await pumpApp(t, LoanScreen(wc: wc, loanId: id), size: _big);
      final l = wc.loanOf(id)!;
      final sched = loanSchedule(l, const [], const []);
      final st = loanState(sched, ['2026-08-15', '2026-09-15'], '2026-10-20');
      expect(st.paidMonths, 2);
      expect(t.widget<Text>(_key('loanOwed')).data, moneyExact(st.owedNow, 'EUR'));
      expect(_in('loanMonthsLeft', '${st.monthsLeft}'), findsOneWidget);
      expect(_in('loanPayoff', monthLong(st.payoffMonth!)), findsOneWidget);
      expect(st.payoffMonth, '2027-07');
      expect(_in('loanInterestPaid', moneyExact(st.interestPaid, 'EUR')), findsOneWidget);
      expect(_in('loanInterestToPay', moneyExact(st.interestToPay, 'EUR')), findsOneWidget);
      // interest paid + still to pay = the whole schedule's interest; the schedule ends at exactly 0
      expect(st.interestPaid + st.interestToPay, sched.fold<int>(0, (a, m) => a + m.interest));
      expect(sched.last.balance, 0);
      expect(_key('loanChart'), findsOneWidget);
      expect(_key('loanPay:${wc.loanView(id)!.payments.first.txId}'), findsOneWidget);
    });

    _test('"Not seen yet" shows once a month is more than 3 days past due', (t) async {
      final wc = _wallet();
      // today is 20 Oct. Due 16 Oct + 3 days = 19 Oct, past: shown. Due 17 Oct + 3 = 20 Oct, not past: not shown.
      final late = _loan(wc, '2026-10-16');
      await pumpApp(t, LoanScreen(wc: wc, loanId: late), size: _big);
      expect(_key('notSeen:2026-10-16'), findsOneWidget);
      expect(find.text('Not seen yet'), findsOneWidget);
      final fresh = _loan(wc, '2026-10-17');
      await pumpApp(t, LoanScreen(wc: wc, loanId: fresh), size: _big);
      expect(_key('notSeen:2026-10-17'), findsNothing);
      expect(find.text('Not seen yet'), findsNothing);
    });

    _test('a payment of another amount is still found and flagged', (t) async {
      final wc = _wallet();
      final id = _loan(wc, '2026-09-15');
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-09-15', -50000, 'Trajni nalog', 'LENDER SYNTHETIC 123')]));
      wc.reload();
      await pumpApp(t, LoanScreen(wc: wc, loanId: id), size: _big);
      expect(find.text('Amount changed'), findsOneWidget);
    });

    _test('the lender\'s balance: matches, or off by X and then continues from it', (t) async {
      final wc = _wallet();
      final id = _loan(wc, '2026-08-15');
      final sched = loanSchedule(wc.loanOf(id)!, const [], const []);
      final expected = sched[2].balance; // the last due date up to 20 Oct is 15 Oct
      await pumpApp(t, LoanScreen(wc: wc, loanId: id), size: _big);
      await t.enterText(_key('loanCheckField'), centsToFieldText(expected));
      await t.tap(_key('loanCheckGo'));
      await t.pump();
      expect(_key('loanCheckMatches'), findsOneWidget);
      expect(wc.repo.loanChecks(id), isEmpty);
      await t.enterText(_key('loanCheckField'), centsToFieldText(expected + 12345));
      await t.tap(_key('loanCheckGo'));
      await t.pump();
      expect(find.textContaining('Off by ${moneyExact(12345, 'EUR')}'), findsOneWidget);
      expect(wc.repo.loanChecks(id), isEmpty, reason: 'never corrected on its own');
      await t.tap(_key('loanCheckApply'));
      await _settle(t);
      expect(wc.repo.loanChecks(id).single.balance, expected + 12345);
    });

    _test('what if: months and interest saved are loanWhatIf\'s', (t) async {
      final wc = _wallet();
      final id = _loan(wc, '2026-08-15');
      await pumpApp(t, LoanScreen(wc: wc, loanId: id), size: _big);
      await t.enterText(_key('whatIfMonthly'), '500');
      await t.pump();
      final w = loanWhatIf(wc.loanOf(id)!, extraMonthly: 50000);
      expect(w.monthsSaved, greaterThan(0));
      expect(find.text('${w.monthsSaved} months sooner'), findsOneWidget);
      expect(find.text('${moneyExact(w.interestSaved, 'EUR')} less interest'), findsOneWidget);
      expect(wc.repo.loanRates(id), isEmpty, reason: 'nothing saved without Use this');
    });

    _test('Close loan asks, closes, and Undo reopens', (t) async {
      final wc = _wallet();
      final id = _loan(wc, '2026-08-15');
      await pumpApp(t, LoanScreen(wc: wc, loanId: id), size: _big);
      await t.tap(_key('loanClose'));
      await _settle(t);
      expect(wc.loanOf(id)!.open, isTrue);
      await t.tap(_key('loanCloseConfirm'));
      await _settle(t);
      expect(wc.loanOf(id)!.closedAt, wc.today());
      expect(wc.settings.loanLines, isEmpty, reason: 'a closed loan leaves the plan');
      await t.tap(_key('toastUndo'));
      await _settle(t);
      expect(wc.loanOf(id)!.open, isTrue);
    });
  });

  group('money row', () {
    _test('a payment found by a loan says so and opens the Loan screen; another payment does not', (t) async {
      final wc = _wallet();
      final id = _loan(wc, '2026-09-15', paid: ['2026-09-15']);
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-09-16', -2000, 'POS plaćanje', 'OTHER SHOP SYNTHETIC')]));
      wc.reload();
      final paid = wc.wholeTxs.firstWhere((c) => c.tx.description.contains('LENDER'));
      final other = wc.wholeTxs.firstWhere((c) => c.tx.description.contains('OTHER SHOP'));
      expect(wc.loanOfPayment(paid.tx.id)!.id, id);
      expect(wc.loanOfPayment(other.tx.id), isNull);
      await pumpApp(t,
          Builder(builder: (c) => TextButton(onPressed: () => showSheet<String>(c, TxSheet(wc: wc, t: paid)), child: const Text('open'))),
          size: _big);
      await t.tap(find.text('open'));
      await _settle(t);
      expect(_key('txLoan'), findsOneWidget);
      await t.tap(_key('txLoan'));
      await _settle(t);
      expect(find.byType(LoanScreen), findsOneWidget);
    });
  });

  group('payday plan', () {
    _test('Turn into a loan: nothing is written until Confirm', (t) async {
      final wc = _wallet();
      wc.repo.updateSettings({'loan': 25000});
      wc.reload();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: PaydayPlan(wc: wc))), size: _big);
      await openPlanEdit(t, 'loan');
      await t.tap(_key('planConvertLoan'));
      await _settle(t);
      expect(_key('loanConvertNote'), findsOneWidget);
      await t.enterText(_key('lf:years'), '25');
      await t.enterText(_key('lf:rate'), '3.6');
      await t.enterText(_key('lf:principal'), '100000');
      await t.pump();
      // typed, not confirmed
      expect(wc.settings.loan, 25000);
      expect(wc.repo.loans(), isEmpty);
      await t.tap(_key('loanFormCancel'));
      await _settle(t);
      expect(wc.settings.loan, 25000);
      expect(wc.repo.loans(), isEmpty);
      // the loan field is still open; again, and confirm
      await t.tap(_key('planConvertLoan'));
      await _settle(t);
      await t.enterText(_key('lf:years'), '25');
      await t.enterText(_key('lf:rate'), '3.6');
      await t.enterText(_key('lf:principal'), '100000');
      await t.tap(_key('loanFormSave'));
      await _settle(t);
      expect(wc.settings.loan, 0);
      final l = wc.repo.loans().single;
      expect([l.id, l.payment, l.months, l.rateBp, l.principal], [Loan.legacyId, 25000, 300, 360, 10000000]);
      // its own fixed line now; the old Loan line is gone; a tap opens the Loan screen
      expect(_key('planLoan:${l.id}'), findsOneWidget);
      expect(_key('planRow_loan'), findsNothing);
      await t.tap(_key('planLoan:${l.id}'));
      await _settle(t);
      expect(find.byType(LoanScreen), findsOneWidget);
    });

    _test('+ Loan adds a loan with its own line', (t) async {
      final wc = _wallet();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: PaydayPlan(wc: wc))), size: _big);
      await t.ensureVisible(_key('planAddLoan'));
      await t.tap(_key('planAddLoan'));
      await _settle(t);
      await t.enterText(_key('lf:principal'), '12000');
      await t.enterText(_key('lf:rate'), '6');
      await t.enterText(_key('lf:years'), '1');
      await t.enterText(_key('lf:payment'), '1030');
      await t.tap(_key('loanFormSave'));
      await _settle(t);
      expect(_key('loanFormError'), findsOneWidget, reason: 'the first payment date is needed');
      expect(wc.repo.loans(), isEmpty);
    });
  });

  group('layout', () {
    for (final (name, size) in [('320 at 2.0', const Size(320, 640)), ('1280', const Size(1280, 800))]) {
      _test('planner, bought sheet and loan screen at $name', (t) async {
        final wc = _wallet();
        final id = _boat(wc, saved: 5200000);
        final loan = _loan(wc, '2026-08-15', paid: ['2026-08-15']);
        final scale = size.width < 400 ? 2.0 : 1.0;
        await pumpApp(t, GoalPlannerScreen(wc: wc, goalId: id), size: size, textScale: scale);
        expect(t.takeException(), isNull);
        await t.tap(_key('plannerIBought'));
        await _settle(t);
        expect(t.takeException(), isNull);
        await pumpApp(t, Scaffold(body: SingleChildScrollView(child: LoanFormSheet(wc: wc, mode: LoanFormMode.convert))),
            size: size, textScale: scale);
        expect(t.takeException(), isNull);
        await pumpApp(t, LoanScreen(wc: wc, loanId: loan), size: size, textScale: scale);
        expect(t.takeException(), isNull);
        await t.drag(_key('loanPage'), const Offset(0, -3000), warnIfMissed: false);
        await t.pump();
        expect(t.takeException(), isNull);
      });
    }
  });
}
