// Plan › Payday plan: every value is edited in place. A tap turns its row into the field with Save / Cancel (one at a time).
// All data is SYNTHETIC.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/plan_page.dart';
import 'support/wallet.dart';

Finder _field(String label) => find.widgetWithText(TextField, label);
Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _tapKey(WidgetTester tester, String k) async {
  await Scrollable.ensureVisible(tester.element(_key(k)), alignment: 0.5);
  await tester.pump();
  await tester.tap(_key(k));
  await tester.pump();
}

/// The Spending money row's texts (the amount changes with the plan).
String _spendingMoney(WidgetTester t) =>
    t.widgetList<Text>(find.descendant(of: _key('ledgerSpendingMoney'), matching: find.byType(Text))).map((w) => w.data).join('|');

void main() {
  testWidgets('nothing is being edited: the ledger lines are tappable values, no Edit button, no fields', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    expect(_key('planHeading'), findsOneWidget);
    expect(_key('ledgerSpendingMoney'), findsOneWidget);
    expect(_key('planEdit'), findsNothing);
    expect(find.text('Edit'), findsNothing);
    for (final k in ['salary', 'rent', 'loan', 'subs', 'paydayDay', 'impulse', 'coolHours', 'rentCashThreshold']) {
      expect(planRow(k), findsOneWidget, reason: k);
    }
    expect(_field('Salary per month'), findsNothing);
    expect(_key('planSave'), findsNothing);
    expect(find.text('PAYDAY PLAN'), findsOneWidget);
  });

  testWidgets('a tap on a value shows its field with the saved number, Save and Cancel', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    await openPlanEdit(tester, 'rent');
    expect(_field('Rent'), findsOneWidget);
    expect(_field('Loan'), findsNothing, reason: 'one value at a time');
    expect(_key('planSave'), findsOneWidget);
    expect(_key('planCancel'), findsOneWidget);
    expect(_key('ledgerSpendingMoney'), findsOneWidget, reason: 'the other lines stay');
    expect(tester.widget<TextField>(_field('Rent')).controller!.text, '550', reason: 'the field starts from the saved number');
    await openPlanEdit(tester, 'rentCashThreshold');
    expect(_field('Rent'), findsNothing, reason: 'opening another value drops the first one');
    expect(_field('Cash withdrawal counts as rent from'), findsOneWidget);
  });

  testWidgets('edit one value in place and Save: only that setting is written and the lines show it', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    final heading = _spendingMoney(tester);
    await openPlanEdit(tester, 'loan');
    await tester.enterText(_field('Loan'), '300');
    await _tapKey(tester, 'planSave');
    await tester.pump(const Duration(seconds: 4)); // toast and the sync debounce
    final after = wc.settings.toMap();
    final changed = {
      for (final k in after.keys)
        if (after[k] != before[k]) k
    };
    // merchantPatterns is the controller's own follow-up write (the loan rule), not a field of this form.
    expect(changed.difference({'merchantPatterns'}), {'loan'});
    expect(wc.settings.loan, 30000);
    expect(_field('Loan'), findsNothing, reason: 'back to the line');
    expect(_key('planSave'), findsNothing);
    expect(_key('ledgerSpendingMoney'), findsOneWidget);
    expect(_spendingMoney(tester), isNot(heading), reason: 'the lines show the new loan in the spending money');
  });

  testWidgets('a refused value shows its message under the field, stays open and saves nothing', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    final ops = wc.repo.pendingOps().length;
    await openPlanEdit(tester, 'rent');
    await tester.enterText(_field('Rent'), 'abc');
    await _tapKey(tester, 'planSave');
    expect(find.text('Numbers only'), findsOneWidget);
    expect(_key('planSave'), findsOneWidget, reason: 'still editing');
    expect(wc.settings.toMap(), before);
    expect(wc.repo.pendingOps().length, ops);
    // Fix it: Save now closes the field.
    await tester.enterText(_field('Rent'), '560');
    await tester.pump();
    expect(find.text('Numbers only'), findsNothing, reason: 'typing clears the message');
    await _tapKey(tester, 'planSave');
    await tester.pump(const Duration(seconds: 4));
    expect(wc.settings.rent, 56000);
    expect(_key('planSave'), findsNothing);
  });

  testWidgets('Cancel leaves the settings unchanged and the next tap shows the saved value', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    final ops = wc.repo.pendingOps().length;
    await openPlanEdit(tester, 'loan');
    await tester.enterText(_field('Loan'), '999');
    await _tapKey(tester, 'planCancel');
    expect(wc.settings.toMap(), before);
    expect(wc.repo.pendingOps().length, ops, reason: 'nothing written');
    expect(_field('Loan'), findsNothing);
    await openPlanEdit(tester, 'loan');
    expect(tester.widget<TextField>(_field('Loan')).controller!.text, '250', reason: 'Cancel restored the shown value');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('what was typed in one value is dropped when another is opened', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    await openPlanEdit(tester, 'loan');
    await tester.enterText(_field('Loan'), '999');
    await openPlanEdit(tester, 'rent');
    await openPlanEdit(tester, 'loan');
    expect(tester.widget<TextField>(_field('Loan')).controller!.text, '250');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the wallet currency here opens the same switch sheet; money fields then read that currency', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    Future<void> pick(String code) async {
      await tester.ensureVisible(_key('planCurrency'));
      await tester.tap(_key('planCurrency'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(_key('currencySearch'), code.toLowerCase());
      await tester.pump();
      await tester.tap(_key('currency:$code'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Cancel in the sheet: nothing changed.
    await pick('USD');
    expect(find.textContaining('keep their currency'), findsOneWidget);
    await _tapKey(tester, 'currencyOfferNo');
    expect(wc.settings.currency, 'EUR');
    expect(find.descendant(of: _key('planCurrency'), matching: find.text('EUR · Euro')), findsOneWidget);
    // Switch: it is written at once (setWalletCurrency), and the fields read yen.
    await pick('JPY');
    await _tapKey(tester, 'currencyOfferYes');
    expect(wc.settings.currency, 'JPY');
    expect(find.descendant(of: _key('planCurrency'), matching: find.text('JPY · Yen')), findsOneWidget);
    final before = wc.settings.toMap();
    await openPlanEdit(tester, 'loan');
    await tester.enterText(_field('Loan'), '10.5');
    await _tapKey(tester, 'planSave');
    expect(_key('planSave'), findsOneWidget, reason: 'a decimal of a yen is refused: still editing');
    expect(wc.settings.toMap(), before);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('two values refused one after the other: the message follows the open value', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    await openPlanEdit(tester, 'loan');
    await tester.enterText(_field('Loan'), 'abc');
    await _tapKey(tester, 'planSave');
    expect(find.text('Numbers only'), findsOneWidget);
    await openPlanEdit(tester, 'rent');
    expect(find.text('Numbers only'), findsNothing, reason: 'the loan message went with the loan field');
    expect(wc.settings.toMap(), before);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Save with nothing changed closes the field and writes nothing', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final ops = wc.repo.pendingOps().length;
    await openPlanEdit(tester);
    await _tapKey(tester, 'planSave');
    expect(find.text('Nothing to save'), findsOneWidget);
    expect(_key('planSave'), findsNothing);
    expect(wc.repo.pendingOps().length, ops);
    await tester.pump(const Duration(seconds: 4));
  });

  for (final (name, size, scale) in const [('320 dp at text 2.0', Size(320, 9000), 2.0), ('1280 wide', Size(1280, 3000), 1.0)]) {
    testWidgets('$name: lines and the open field lay out without overflow', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      await openPlanEdit(tester, 'rentCashThreshold');
      expect(_key('planSave'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tapKey(tester, 'planCancel');
      expect(tester.takeException(), isNull);
    });
  }
}
