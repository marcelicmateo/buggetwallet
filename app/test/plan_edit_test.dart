// Plan › Payday plan: one section that lists the ledger lines and turns into the number fields with Edit (Save / Cancel).
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
  testWidgets('without Edit the section lists the ledger lines and has no fields', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    expect(_key('planHeading'), findsOneWidget);
    expect(_key('ledgerSpendingMoney'), findsOneWidget);
    expect(_key('planEdit'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(_field('Salary per month'), findsNothing);
    expect(_key('planSave'), findsNothing);
    expect(find.text('Save numbers'), findsNothing);
    expect(find.text('NUMBERS'), findsNothing, reason: 'one section, no separate Numbers panel');
    expect(find.text('PAYDAY PLAN'), findsOneWidget);
  });

  testWidgets('Edit turns the section into the fields with Save and Cancel', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    await openPlanEdit(tester);
    expect(_field('Salary per month'), findsOneWidget);
    expect(_field('Rent'), findsOneWidget);
    expect(_field('Cash withdrawal counts as rent from'), findsOneWidget);
    expect(_key('planSave'), findsOneWidget);
    expect(_key('planCancel'), findsOneWidget);
    expect(_key('planEdit'), findsNothing);
    expect(_key('ledgerSpendingMoney'), findsNothing);
    expect(find.text('PAYDAY PLAN'), findsOneWidget);
    expect(tester.widget<TextField>(_field('Rent')).controller!.text, '550', reason: 'the fields start from the saved numbers');
  });

  testWidgets('Edit, change one field, Save: only that field is written and the ledger comes back', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    final heading = _spendingMoney(tester);
    await openPlanEdit(tester);
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
    expect(_field('Loan'), findsNothing, reason: 'back to the ledger lines');
    expect(_key('planEdit'), findsOneWidget);
    expect(_key('ledgerSpendingMoney'), findsOneWidget);
    final heading2 = _spendingMoney(tester);
    expect(heading2, isNot(heading), reason: 'the lines show the new loan in the spending money');
  });

  testWidgets('Cancel leaves the settings unchanged and the next Edit shows the saved values', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    final ops = wc.repo.pendingOps().length;
    await openPlanEdit(tester);
    await tester.enterText(_field('Loan'), '999');
    await tester.enterText(_field('Wait (hours)'), 'abc');
    await _tapKey(tester, 'planSave'); // an error is showing when Cancel comes
    expect(find.text('Numbers only'), findsOneWidget);
    await _tapKey(tester, 'planCancel');
    expect(wc.settings.toMap(), before);
    expect(wc.repo.pendingOps().length, ops, reason: 'nothing written');
    expect(_field('Loan'), findsNothing);
    expect(_key('ledgerSpendingMoney'), findsOneWidget);
    expect(find.text('Numbers only'), findsNothing);
    await openPlanEdit(tester);
    expect(tester.widget<TextField>(_field('Loan')).controller!.text, '250', reason: 'Cancel restored the shown value');
    expect(tester.widget<TextField>(_field('Wait (hours)')).controller!.text, '72');
    expect(find.text('Numbers only'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Cancel also puts the currency back', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    await openPlanEdit(tester);
    await tester.ensureVisible(_key('planCurrency'));
    await tester.tap(_key('planCurrency'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(_key('currencySearch'), 'usd');
    await tester.pump();
    await tester.tap(_key('currency:USD'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.descendant(of: _key('planCurrency'), matching: find.text('USD · US Dollar')), findsOneWidget);
    await _tapKey(tester, 'planCancel');
    await openPlanEdit(tester);
    expect(find.descendant(of: _key('planCurrency'), matching: find.text('EUR · Euro')), findsOneWidget);
    expect(wc.settings.currency, 'EUR');
  });

  testWidgets('a validation error keeps edit mode open and saves nothing', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final before = wc.settings.toMap();
    await openPlanEdit(tester);
    await tester.enterText(_field('Loan'), '300');
    await tester.enterText(_field('Rent'), 'abc');
    await _tapKey(tester, 'planSave');
    expect(find.text('Numbers only'), findsOneWidget);
    expect(_key('planSave'), findsOneWidget, reason: 'still editing');
    expect(_field('Rent'), findsOneWidget);
    expect(_key('ledgerSpendingMoney'), findsNothing);
    expect(wc.settings.toMap(), before, reason: 'not even the valid loan');
    // Fix it: Save now closes the editor.
    await tester.enterText(_field('Rent'), '560');
    await _tapKey(tester, 'planSave');
    await tester.pump(const Duration(seconds: 4));
    expect((wc.settings.rent, wc.settings.loan), (56000, 30000));
    expect(_key('planEdit'), findsOneWidget);
  });

  testWidgets('Save with nothing changed closes the editor and writes nothing', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 3000));
    final ops = wc.repo.pendingOps().length;
    await openPlanEdit(tester);
    await _tapKey(tester, 'planSave');
    expect(find.text('Nothing to save'), findsOneWidget);
    expect(_key('planEdit'), findsOneWidget);
    expect(wc.repo.pendingOps().length, ops);
    await tester.pump(const Duration(seconds: 4));
  });

  for (final (name, size, scale) in const [('320 dp at text 2.0', Size(320, 9000), 2.0), ('1280 wide', Size(1280, 3000), 1.0)]) {
    testWidgets('$name: ledger and editor lay out without overflow', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      await openPlanEdit(tester);
      expect(_key('planSave'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tapKey(tester, 'planCancel');
      expect(tester.takeException(), isNull);
    });
  }
}
