// Plan › Budgets per category. All data is SYNTHETIC (budgetWallet: fixed clock, made-up amounts).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

Finder _field(String category) => find.byKey(ValueKey('budget:$category'));
String _text(WidgetTester tester, String category) => tester.widget<TextField>(_field(category)).controller!.text;

Future<void> _tapButton(WidgetTester tester, String label) async {
  final btn = find.text(label);
  await tester.pump(const Duration(milliseconds: 400)); // a focused field scrolls itself into view first
  await tester.ensureVisible(btn);
  await tester.pump();
  await tester.tap(btn);
  await tester.pump();
  await tester.pump(const Duration(seconds: 4)); // toast and the controller's sync debounce
}

late WalletController _wc; // the wallet of the running test

Future<void> _pump(WidgetTester tester, {bool budgets = true, Size size = const Size(400, 6000), double scale = 1}) async {
  _wc = budgetWallet(budgets: budgets);
  await pumpApp(tester, Scaffold(body: PlanScreen(wc: _wc)), size: size, textScale: scale);
}

void main() {
  testWidgets('the fields show the saved budgets and are empty for the others', (tester) async {
    await _pump(tester);
    expect(_text(tester, 'Groceries'), '300');
    expect(_text(tester, 'Eating out'), '100');
    expect(_text(tester, 'Shopping'), '');
    expect(find.text('BUDGETS PER CATEGORY'), findsOneWidget);
    expect(find.byKey(const ValueKey('budget:Salary')), findsNothing, reason: 'income has no budget');
    expect(find.byKey(const ValueKey('budget:Internal transfer')), findsNothing);
    expect(find.byKey(const ValueKey('budget:Rent')), findsOneWidget);
  });

  testWidgets('Suggest fills only the empty fields and writes nothing by itself', (tester) async {
    await _pump(tester, budgets: false);
    final before = _wc.dataVersion;
    await tester.ensureVisible(_field('Groceries'));
    await tester.enterText(_field('Groceries'), '150');
    await _tapButton(tester, 'Suggest from the last 6 months');
    expect(_text(tester, 'Groceries'), '150', reason: 'a typed value is kept');
    expect(_text(tester, 'Eating out'), '90', reason: '85 rounded up to the nearest 10');
    expect(_text(tester, 'Shopping'), '', reason: 'no history, no suggestion');
    expect(_wc.dataVersion, before, reason: 'nothing saved yet');
    expect(_wc.categoryBudgets, isEmpty);
  });

  testWidgets('Suggest does not touch a field that already has a value', (tester) async {
    await _pump(tester);
    await _tapButton(tester, 'Suggest from the last 6 months');
    expect(_text(tester, 'Groceries'), '300');
    expect(_text(tester, 'Eating out'), '100', reason: 'saved 100, suggestion would be 90');
    expect(find.text('Nothing new to suggest.'), findsOneWidget, reason: 'the only categories with history already have a budget');
  });

  testWidgets('Save writes once, with the edited fields on top of the saved budgets', (tester) async {
    await _pump(tester);
    final before = _wc.dataVersion;
    await tester.ensureVisible(_field('Shopping'));
    await tester.enterText(_field('Shopping'), '80,50');
    await _tapButton(tester, 'Save budgets');
    expect(_wc.dataVersion, before + 1);
    expect(_wc.categoryBudgets, {'Groceries': 30000, 'Eating out': 10000, 'Shopping': 8050});
    expect(_text(tester, 'Shopping'), '80.50');
  });

  testWidgets('Save with nothing changed does not write', (tester) async {
    await _pump(tester);
    final before = _wc.dataVersion;
    await _tapButton(tester, 'Save budgets');
    expect(_wc.dataVersion, before);
    expect(find.text('Nothing to save'), findsOneWidget);
    // Typing the saved value again, or 0 into an empty field, is no change either.
    await tester.enterText(_field('Groceries'), '300.00');
    await tester.enterText(_field('Shopping'), '0');
    await _tapButton(tester, 'Save budgets');
    expect(_wc.dataVersion, before);
    expect(_text(tester, 'Groceries'), '300');
    expect(_text(tester, 'Shopping'), '');
  });

  testWidgets('an emptied field removes the budget', (tester) async {
    await _pump(tester);
    await tester.enterText(_field('Eating out'), '');
    await _tapButton(tester, 'Save budgets');
    expect(_wc.categoryBudgets, {'Groceries': 30000});
  });

  testWidgets('invalid input is refused with a message and nothing is saved', (tester) async {
    await _pump(tester);
    final before = _wc.dataVersion;
    await tester.enterText(_field('Shopping'), 'abc');
    await tester.enterText(_field('Groceries'), '-5');
    await tester.enterText(_field('Rent'), '1e3');
    final btn = find.text('Save budgets');
    await tester.ensureVisible(btn);
    await tester.pump();
    await tester.tap(btn);
    await tester.pump();
    expect(find.text('Numbers only'), findsNWidgets(3));
    expect(_wc.dataVersion, before);
    expect(_wc.categoryBudgets, {'Groceries': 30000, 'Eating out': 10000});
    // Editing a field clears its message.
    await tester.enterText(_field('Shopping'), '40');
    await tester.pump();
    expect(find.text('Numbers only'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 4));
  });

  for (final (name, size, scale) in const [
    ('320 dp at text 2.0', Size(320, 6000), 2.0),
    ('1280 wide', Size(1280, 3000), 1.0),
    ('360 dp', Size(360, 4000), 1.0)
  ]) {
    testWidgets('$name: the editor lays out without overflow, errors included', (tester) async {
      await _pump(tester, size: size, scale: scale);
      await tester.enterText(_field('Shopping'), 'abc');
      await _tapButton(tester, 'Save budgets');
      await tester.ensureVisible(_field('Bank fees'));
      await tester.pump();
      expect(find.text('Numbers only'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final k in const ['Groceries', 'Bank fees']) {
        final r = tester.getRect(_field(k));
        expect(r.right, lessThanOrEqualTo(size.width + 0.5));
        expect(r.left, greaterThanOrEqualTo(0));
      }
    });
  }
}
