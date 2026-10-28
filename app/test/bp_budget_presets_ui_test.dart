// Stage BP: Budget › Budgets "Start from…" menu. All data is SYNTHETIC (budgetWallet: Groceries 290 and Eating out 85 a month
// for April to September, salary 1500, clock 2026-10-20). The numbers themselves are pinned in core; here: the menu, the flow, the header.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/budgets.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart' show Muted;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart' show BudgetPresetKind;

import 'support/wallet.dart';

Finder _field(String category) => find.byKey(ValueKey('budget:$category'));
String _text(WidgetTester tester, String category) => tester.widget<TextField>(_field(category)).controller!.text;

late WalletController _wc;

Future<void> _pump(WidgetTester tester,
    {WalletController? wc, Size size = const Size(400, 6000), double scale = 1, bool dark = false}) async {
  _wc = wc ?? budgetWallet(budgets: false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(dark ? Brightness.dark : Brightness.light),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: BudgetsPanel(wc: _wc))),
  ));
  await tester.pump();
}

Future<void> _open(WidgetTester tester) async {
  final btn = find.byKey(const ValueKey('budgetsPreset'));
  await tester.ensureVisible(btn);
  await tester.pump();
  await tester.tap(btn);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _choose(WidgetTester tester, BudgetPresetKind kind) async {
  await _open(tester);
  await tester.tap(find.byKey(ValueKey('preset:${kind.name}')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('the menu lists the six ways to start', (tester) async {
    await _pump(tester);
    await _open(tester);
    for (final k in BudgetPresetKind.values) {
      expect(find.byKey(ValueKey('preset:${k.name}')), findsOneWidget, reason: k.name);
    }
    for (final label in const [
      'Average of the last 3 months',
      'Average of the last 6 months',
      'Average of the last 12 months',
      'Spend 10% less',
      'Fit my plan',
      '50/30/20',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a preset fills the empty fields at once and writes nothing until Save', (tester) async {
    await _pump(tester);
    final before = _wc.dataVersion;
    await _choose(tester, BudgetPresetKind.spendLess);
    expect(_text(tester, 'Groceries'), '260', reason: '90 % of 290, rounded down to 10');
    expect(_text(tester, 'Eating out'), '70', reason: '90 % of 85, rounded down to 10');
    expect(_text(tester, 'Shopping'), '', reason: 'no history, no budget');
    expect(find.byKey(const ValueKey('suggestAccept')), findsNothing, reason: 'nothing to ask');
    expect(_wc.dataVersion, before);
    expect(_wc.categoryBudgets, isEmpty);
    await tester.pump(const Duration(seconds: 4));
    await tester.ensureVisible(find.byKey(const ValueKey('budgetsSave')));
    await tester.tap(find.byKey(const ValueKey('budgetsSave')));
    await tester.pump();
    expect(_wc.categoryBudgets, {'Groceries': 26000, 'Eating out': 7000});
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('fields with a number are asked about, under the preset header; Cancel changes nothing', (tester) async {
    await _pump(tester);
    await tester.ensureVisible(_field('Groceries'));
    await tester.enterText(_field('Groceries'), '150');
    final before = _wc.dataVersion;
    await _choose(tester, BudgetPresetKind.fitPlan);
    expect(_text(tester, 'Eating out'), '340', reason: '1,500 split by 290 : 85, whole euros');
    expect(find.text('Fit my plan'), findsOneWidget);
    expect(
        find.text('${money(150000, 'EUR', decimals: 0)} a month of flexible money, split by what you spent in the last 6 months. '
            '${moneyExact(150000, 'EUR')} a month in all.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('suggestPick:Groceries')), findsOneWidget);
    expect(find.text('${moneyExact(15000, 'EUR')} → ${moneyExact(116000, 'EUR')}'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('suggestCancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_text(tester, 'Groceries'), '150');
    expect(_wc.dataVersion, before);
    expect(_wc.categoryBudgets, isEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Accept all takes the preset for a field that has a number', (tester) async {
    await _pump(tester);
    await tester.ensureVisible(_field('Groceries'));
    await tester.enterText(_field('Groceries'), '150');
    await _choose(tester, BudgetPresetKind.fiftyThirtyTwenty);
    expect(find.text('50/30/20'), findsWidgets);
    expect(find.textContaining('30 % of your salary for wants: ${money(45000, 'EUR', decimals: 0)}.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('suggestAcceptAll')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_text(tester, 'Groceries'), '348', reason: '30 % of 1,500 = 450, split 290 : 85');
    expect(_text(tester, 'Eating out'), '102');
    expect(find.byKey(const ValueKey('budgetsPresetNote')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a preset that fills everything at once still shows its header and total, until Save', (tester) async {
    await _pump(tester);
    await _choose(tester, BudgetPresetKind.fiftyThirtyTwenty);
    final note = find.byKey(const ValueKey('budgetsPresetNote'));
    expect(note, findsOneWidget);
    final text = tester.widget<Muted>(note).text;
    expect(text, startsWith('50/30/20: 30 % of your salary for wants: ${money(45000, 'EUR', decimals: 0)}.'));
    expect(text, contains('Needs are your payday plan; 20 % is for savings.'));
    expect(text, endsWith('${moneyExact(45000, 'EUR')} a month in all.'));
    await tester.pump(const Duration(seconds: 4));
    await tester.ensureVisible(find.byKey(const ValueKey('budgetsSave')));
    await tester.tap(find.byKey(const ValueKey('budgetsSave')));
    await tester.pump();
    expect(find.byKey(const ValueKey('budgetsPresetNote')), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('every preset names its total in the header', (tester) async {
    await _pump(tester);
    for (final k in BudgetPresetKind.values) {
      final p = _wc.budgetPresetFor(k, '2026-10');
      expect(_wc.budgetPresetNote(k, p.total).$2, endsWith('${moneyExact(p.total, 'EUR')} a month in all.'), reason: k.name);
    }
  });

  testWidgets('Start from… is 48 dp high and has a label for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, size: const Size(320, 9000), scale: 2.0);
    final btn = find.byKey(const ValueKey('budgetsPreset'));
    await tester.ensureVisible(btn);
    expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Start from…'), findsWidgets);
    handle.dispose();
  });

  testWidgets('a preset with nothing to offer says why in a toast and fills nothing', (tester) async {
    await _pump(tester, wc: emptyWallet());
    await _choose(tester, BudgetPresetKind.avg3);
    expect(find.text('No spending in the last 3 months.'), findsOneWidget);
    await _choose(tester, BudgetPresetKind.fitPlan);
    expect(find.text('Set your salary in the payday plan first.'), findsOneWidget);
    expect(_text(tester, 'Groceries'), '');
    await tester.pump(const Duration(seconds: 4));
  });

  test('the controller caches a preset per kind and month until the data changes', () {
    final wc = budgetWallet(budgets: false);
    final a = wc.budgetPresetFor(BudgetPresetKind.avg3, '2026-10');
    expect(identical(wc.budgetPresetFor(BudgetPresetKind.avg3, '2026-10'), a), isTrue);
    expect(identical(wc.budgetPresetFor(BudgetPresetKind.avg6, '2026-10'), a), isFalse);
    wc.addExpense(amount: 500, category: 'Groceries', note: 'x', date: '2026-09-15');
    expect(identical(wc.budgetPresetFor(BudgetPresetKind.avg3, '2026-10'), a), isFalse);
  });

  test('Fit my plan follows the goals: a monthly goal lowers it, deleting the goal gives it back', () {
    final wc = budgetWallet(budgets: false);
    expect(wc.budgetPresetFor(BudgetPresetKind.fitPlan, '2026-10').total, 150000);
    wc.saveGoal(name: 'Synthetic goal', target: 500000, saved: 0, monthly: 20000);
    expect(wc.budgetPresetFor(BudgetPresetKind.fitPlan, '2026-10').total, 130000, reason: '1,500 - 200 a month for the goal');
    wc.deleteGoal(wc.goals.single.id);
    expect(wc.budgetPresetFor(BudgetPresetKind.fitPlan, '2026-10').total, 150000);
  });

  test('a salary change replaces the cached presets', () {
    final wc = budgetWallet(budgets: false);
    expect(wc.budgetPresetFor(BudgetPresetKind.fiftyThirtyTwenty, '2026-10').total, 45000);
    wc.updateSettings({'salary': 200000});
    expect(wc.budgetPresetFor(BudgetPresetKind.fiftyThirtyTwenty, '2026-10').total, 60000);
    expect(wc.budgetPresetFor(BudgetPresetKind.fitPlan, '2026-10').total, 200000);
  });

  for (final (name, size, scale, dark) in const [
    ('320 dp at text 2.0', Size(320, 9000), 2.0, false),
    ('dark, 400 dp', Size(400, 6000), 1.0, true),
    ('wide desktop', Size(1280, 3000), 1.0, false),
  ]) {
    testWidgets('layout: $name', (tester) async {
      await _pump(tester, size: size, scale: scale, dark: dark);
      await _open(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('preset:fitPlan')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preset:fitPlan')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(_text(tester, 'Groceries'), isNotEmpty);
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('layout: the header dialog fits 320 dp at text 2.0', (tester) async {
    await _pump(tester, size: const Size(320, 9000), scale: 2.0);
    await tester.ensureVisible(_field('Groceries'));
    await tester.enterText(_field('Groceries'), '150');
    await _choose(tester, BudgetPresetKind.fiftyThirtyTwenty);
    expect(find.byKey(const ValueKey('suggestPick:Groceries')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('suggestCancel')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
  });
}
