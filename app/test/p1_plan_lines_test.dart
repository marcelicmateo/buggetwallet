// Stage P1 (last UI part): plan lines for the owner's own fixed categories (Payday plan Edit + ledger), their proposals, the money they take
// off the daily amount, the CSV with labels, search by label and the drill-down over a tree. All data is SYNTHETIC (budgetWallet, 20 Oct 2026).
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/categories_panel.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/plan_suggestions.dart';
import 'package:budget_wallet/src/screens/planned_sheets.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/bills.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 90));

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _tapKey(WidgetTester t, String k) async {
  await Scrollable.ensureVisible(t.element(_key(k)), alignment: 0.5);
  await t.pump();
  await t.tap(_key(k));
  await t.pump();
}

/// Taps a key inside a sheet or dialog (scrolls it into view when it can).
Future<void> _tapSheet(WidgetTester t, String k) async {
  await t.tap(_key(k));
  await t.pumpAndSettle();
}

/// A wallet with a fixed category of its own (`Pet insurance`) and its id.
Future<({WalletController wc, String id})> withFixed() async {
  final wc = budgetWallet(budgets: false);
  final id = await wc.addOwnCategory(name: 'Pet insurance', kind: BudgetKind.fixed);
  return (wc: wc, id: id);
}

/// Payments in [id] in the two months before the clock's month, so the imports point to a plan line.
void _paid(WalletController wc, String id, int cents) {
  wc.repo.addTransaction(date: '2026-08-12', amount: cents, category: id, note: 'Cover');
  wc.repo.addTransaction(date: '2026-09-12', amount: cents, category: id, note: 'Cover');
  wc.reload();
}

void main() {
  group('the line takes money off the daily amount', () {
    test('a custom fixed category with a line lowers the spending money by the line; without a line it does not', () async {
      final (:wc, :id) = await withFixed();
      final before = wc.period();
      wc.repo.addTransaction(date: '2026-10-08', amount: 5000, category: id, note: 'Cover');
      wc.reload();
      expect(wc.period().flexBudget, before.flexBudget, reason: 'no line yet: nothing is taken off, and the payment is not spending money');
      expect(wc.period().fixedPaid[id], 5000);
      wc.savePlanLines({id: 20000});
      final after = wc.period();
      expect(after.flexBudget, before.flexBudget - 20000);
      expect(after.safeToday, lessThan(before.safeToday), reason: 'today\'s safe amount follows the line');
      expect(after.planDaily, lessThan(before.planDaily));
      wc.savePlanLines({id: null});
      expect(wc.period().flexBudget, before.flexBudget);
      wc.dispose();
    });

    test('savePlanLines refuses a category that has no line', () async {
      final wc = budgetWallet(budgets: false);
      expect(() => wc.savePlanLines({'Groceries': 100}), throwsArgumentError);
      wc.dispose();
    });
  });

  group('Payday plan', () {
    testWidgets('Edit shows a field per line, labelled by the category; Save writes only the edited line', (t) async {
      final (:wc, :id) = await withFixed();
      wc.savePlanLines({id: 12000});
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 3000));
      await openPlanEdit(t);
      final field = _key('planLine_$id');
      expect(field, findsOneWidget);
      expect(find.widgetWithText(TextField, 'Pet insurance'), findsOneWidget);
      expect(t.widget<TextField>(field).controller!.text, '120');
      final before = wc.settings.toMap();
      await t.enterText(field, '135.50');
      await _tapKey(t, 'planSave');
      await settle(t);
      expect(wc.settings.planLines[id], 13550);
      final after = wc.settings.toMap();
      final changed = {
        for (final k in after.keys)
          if (after[k] != before[k]) k
      };
      // merchantPatterns is the controller's own follow-up write, as in plan_edit_test.
      expect(changed.difference({'merchantPatterns', 'plan:$id'}), isEmpty, reason: 'the other numbers are untouched');
      expect(_key('planEdit'), findsOneWidget, reason: 'back to the ledger');
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('an empty field is shown for a missing line; typing and clearing removes it', (t) async {
      final (:wc, :id) = await withFixed();
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 3000));
      await openPlanEdit(t);
      expect(t.widget<TextField>(_key('planLine_$id')).controller!.text, '');
      await t.enterText(_key('planLine_$id'), '80');
      await _tapKey(t, 'planSave');
      await settle(t);
      expect(wc.settings.planLines[id], 8000);
      await openPlanEdit(t);
      await t.enterText(_key('planLine_$id'), '');
      await _tapKey(t, 'planSave');
      await settle(t);
      expect(wc.settings.planLines.containsKey(id), isFalse, reason: 'cleared = no line');
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a bad amount shows the error under the field and writes nothing; 0 on a missing line is no change', (t) async {
      final (:wc, :id) = await withFixed();
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 3000));
      await openPlanEdit(t);
      final ops = wc.repo.pendingOps().length;
      await t.enterText(_key('planLine_$id'), 'abc');
      await _tapKey(t, 'planSave');
      await t.pump();
      expect(find.text('Numbers only'), findsOneWidget);
      expect(_key('planSave'), findsOneWidget, reason: 'the editor stays open');
      await t.enterText(_key('planLine_$id'), '-5');
      await _tapKey(t, 'planSave');
      await t.pump();
      expect(find.text('Numbers only'), findsOneWidget);
      expect(wc.repo.pendingOps().length, ops);
      expect(wc.settings.planLines, isEmpty);
      await t.enterText(_key('planLine_$id'), '0');
      await _tapKey(t, 'planSave');
      await settle(t);
      expect(wc.settings.planLines, isEmpty);
      expect(wc.repo.pendingOps().length, ops);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('the ledger lists the line with what was paid; no line yet says it is not taken off', (t) async {
      final (:wc, :id) = await withFixed();
      wc.repo.addTransaction(date: '2026-10-08', amount: 5000, category: id, note: 'Cover');
      wc.reload();
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 3000));
      final row = _key('ledgerPlanLine_$id');
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Pet insurance')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('Paid since payday: ${moneyExact(wc.period().fixedPaid[id]!, 'EUR')}')),
          findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('Not taken off your daily money until you fill this in.')),
          findsOneWidget);
      wc.savePlanLines({id: 12000});
      await t.pump();
      expect(find.descendant(of: _key('ledgerPlanLine_$id'), matching: find.text(moneyExact(-12000, 'EUR'))), findsOneWidget);
      expect(find.descendant(of: _key('ledgerPlanLine_$id'), matching: find.textContaining('Not taken off')), findsNothing);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a subcategory or a flex category has no line', (t) async {
      final (:wc, :id) = await withFixed();
      await wc.addOwnCategory(name: 'Cat food', kind: BudgetKind.flex);
      await wc.addOwnCategory(name: 'Collar', kind: BudgetKind.fixed, parent: id);
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 3000));
      await openPlanEdit(t);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('planLine_')),
          findsOneWidget);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('proposals', () {
    test('a plan: proposal is accepted through setPlanLine', () async {
      final (:wc, :id) = await withFixed();
      _paid(wc, id, 7000);
      final p = wc.planProposalList().where((x) => x.key == 'plan:$id');
      expect(p, hasLength(1));
      expect(p.single.suggested, 7000);
      expect(wc.acceptPlanProposals(only: {'plan:$id'}), 1);
      expect(wc.settings.planLines[id], 7000);
      expect(wc.planProposalList().where((x) => x.key == 'plan:$id'), isEmpty);
      wc.dispose();
    });

    test('Accept all with a plan line and a setting writes both', () async {
      final (:wc, :id) = await withFixed();
      _paid(wc, id, 7000);
      for (final m in ['2026-08-03', '2026-09-03']) {
        wc.repo.addTransaction(date: m, amount: 45000, category: 'Rent', note: 'Rent');
      }
      wc.reload();
      final keys = [for (final x in wc.planProposalList()) x.key];
      expect(keys, containsAll(['plan:$id', 'rent']));
      expect(wc.acceptPlanProposals(), keys.length);
      expect(wc.settings.planLines[id], 7000);
      expect(wc.settings.rent, 45000);
      wc.dispose();
    });

    testWidgets('the panel names the row by the category label', (t) async {
      final (:wc, :id) = await withFixed();
      _paid(wc, id, 7000);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: PlanSuggestionsPanel(wc: wc))), size: const Size(400, 1500));
      final row = _key('proposal:plan:$id');
      expect(find.descendant(of: row, matching: find.text('Pet insurance')), findsOneWidget);
      expect(t.widget<Text>(_key('proposalValue:plan:$id')).data, endsWith('→ ${moneyExact(7000, 'EUR')}'));
      await _tapKey(t, 'proposalAccept:plan:$id');
      await settle(t);
      expect(wc.settings.planLines[id], 7000);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('labels in the rest of the app', () {
    test('the transactions CSV writes labels, not ids', () async {
      final (:wc, :id) = await withFixed();
      wc.repo.addTransaction(date: '2026-10-08', amount: 5000, category: id, note: 'Cover');
      wc.reload();
      final csv = utf8.decode(wc.exportTransactions(ExportRange.all).bytes.sublist(3));
      expect(csv, contains('Pet insurance'));
      expect(csv, isNot(contains(id)));
      wc.dispose();
    });

    test('searching a category label finds its rows', () async {
      final (:wc, :id) = await withFixed();
      wc.repo.addTransaction(date: '2026-10-08', amount: 5000, category: id, note: 'Cover');
      wc.reload();
      final r = wc.search('pet insur');
      expect(r.txs.map((x) => x.category), [id]);
      expect(wc.search('Pet insurance').txs, hasLength(1));
      await wc.renameCategory(id, 'Animal cover');
      expect(wc.search('pet insur').txs, isEmpty);
      expect(wc.search('animal').txs, hasLength(1));
      wc.dispose();
    });

    test('the drill-down total of a parent equals its rows and its merchants, children included', () async {
      final wc = budgetWallet(budgets: false);
      final bakery = await wc.addOwnCategory(name: 'Bakery', kind: BudgetKind.flex, parent: 'Groceries');
      wc.repo.addTransaction(date: '2026-10-05', amount: 4000, category: bakery, note: 'Morning bread');
      wc.reload();
      final r = wc.monthRange('2026-10');
      final rows = wc.rowsOf('Groceries', null, r);
      final merchants = wc.merchantsFor('Groceries', r);
      expect(wc.categoryTotal('Groceries', r), 29200);
      expect(-rows.fold<int>(0, (s, x) => s + x.amount), 29200);
      expect(merchants.fold<int>(0, (s, m) => s + m.spent), 29200, reason: 'the merchants cover the whole tree');
      expect(rows.any((x) => x.category == bakery), isTrue);
      expect(wc.ownTotal('Groceries', r) + wc.childTotals('Groceries', r).fold<int>(0, (s, e) => s + e.$2), 29200);
      for (final m in merchants) {
        final mine = wc.rowsOf('Groceries', m.key, r);
        expect(-mine.fold<int>(0, (s, x) => s + x.amount), m.spent, reason: 'each merchant total equals its rows');
        expect(wc.merchantBars('Groceries', m.key, r).fold<int>(0, (s, b) => s + b.spent), m.spent);
      }
      expect(wc.categoryBars('Groceries', r).fold<int>(0, (s, b) => s + b.spent), 29200);
      expect(wc.compareFor('Groceries', r).thisMonth, 29200);
      wc.dispose();
    });
  });

  group('fields cover every plan line', () {
    testWidgets('a hidden category and a sync duplicate still get a field (core subtracts their lines)', (t) async {
      final (:wc, :id) = await withFixed();
      await wc.setCategoryHidden(id, true);
      final now = DateTime.now().millisecondsSinceEpoch;
      const dup = 'kffffffffffff'; // the same label as `id`; the smaller id is the original
      wc.repo.applyRemote([
        Op('category', dup, {'name': 'Pet insurance', 'kind': 'fixed', 'position': 0, 'hidden': 0, 'deleted': 0},
            Hlc(now + 60000, 0, 'peer').toString())
      ]);
      wc.reload();
      expect(wc.categoryTable.planLineIds, containsAll([id, dup]));
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 3000));
      await openPlanEdit(t);
      expect(_key('planLine_$id'), findsOneWidget);
      expect(_key('planLine_$dup'), findsOneWidget);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('edits that do not touch the category write no category', () {
    int categoryOps(WalletController wc, String entity, String id) =>
        wc.repo.pendingOps().where((o) => o.$2.entity == entity && o.$2.id == id && o.$2.fields.containsKey('category')).length;

    testWidgets('editing only the amount of a planned cost whose category was deleted', (t) async {
      final (:wc, :id) = await withFixed();
      wc.addPlannedCost(title: 'Cover plan', date: '2026-10-25', amount: 5000, category: id);
      wc.reload();
      await wc.deleteOwnCategory(id);
      final p = wc.plannedEverything().firstWhere((x) => x.title == 'Cover plan');
      final before = categoryOps(wc, 'planned', p.id);
      expect(before, greaterThan(0), reason: 'the add wrote the category once');
      await pumpApp(
          t,
          Scaffold(
              body: Builder(
                  builder: (c) =>
                      TextButton(onPressed: () => showSheet<String>(c, PlannedFormSheet(wc: wc, edit: p)), child: const Text('open')))),
          size: const Size(400, 2600));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(_key('plannedAmount'), '75');
      await _tapSheet(t, 'plannedSave');
      await t.pump(const Duration(milliseconds: 500));
      wc.reload();
      expect(wc.plannedEverything().firstWhere((x) => x.title == 'Cover plan').amount, 7500);
      expect(categoryOps(wc, 'planned', p.id), before, reason: 'no new category op');
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('confirming a past bill with only a suggestion shown does not write the suggestion', (t) async {
      final wc = billsWallet();
      wc.billCategorySuggester = (b) => 'Groceries';
      final (id, _) = wc.repo.importBill(syntheticBill('dead-cat', due: '2000-01-01'));
      wc.reload();
      expect(wc.bill(id)!.category, isNull);
      await pumpApp(t, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openBill(c, wc, id), child: const Text('open')))),
          size: const Size(400, 3200));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Suggested from your earlier bills. Check it.'), findsOneWidget);
      await _tapSheet(t, 'confirmBill');
      await t.pump(const Duration(milliseconds: 500));
      wc.reload();
      expect(wc.bill(id)!.status, BillStatus.confirmed);
      expect(categoryOps(wc, 'bill', id), 0, reason: 'nothing needed a category, and the owner did not pick one');
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('confirming a bill that is still to be paid accepts the shown suggestion', (t) async {
      final wc = billsWallet();
      wc.billCategorySuggester = (b) => 'Groceries';
      final (id, _) = wc.repo.importBill(syntheticBill('live-cat', due: '2026-10-28'));
      wc.reload();
      await pumpApp(t, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openBill(c, wc, id), child: const Text('open')))),
          size: const Size(400, 3200));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await _tapSheet(t, 'confirmBill');
      await t.pump(const Duration(milliseconds: 500));
      wc.reload();
      expect(wc.bill(id)!.category, 'Groceries');
      expect(wc.bill(id)!.status, BillStatus.confirmed);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('deleting a category with a plan line', () {
    Widget panel(WalletController wc) =>
        ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: CategoriesPanel(wc: wc))));

    Future<void> menuDelete(WidgetTester t, String id) async {
      await _tapKey(t, 'categoryMenu:$id');
      await t.pump(const Duration(milliseconds: 400));
      await _tapKey(t, 'categoryDeleteItem:$id');
      await t.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the dialog names the line and what happens to the bills; Cancel keeps the category, Delete removes it', (t) async {
      final (:wc, :id) = await withFixed();
      wc.savePlanLines({id: 12000});
      await pumpApp(t, panel(wc), size: const Size(400, 2600));
      await menuDelete(t, id);
      expect(_key('categoryDeleteConfirm'), findsOneWidget);
      expect(find.text('Its plan line (${moneyExact(12000, 'EUR')}) goes too. Its bills then count under the automatic category.'),
          findsOneWidget);
      expect(wc.categoryTable.isLive(id), isTrue, reason: 'nothing is deleted before the answer');
      await _tapSheet(t, 'categoryDeleteCancel');
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.categoryTable.isLive(id), isTrue);
      expect(wc.settings.planLines[id], 12000);
      await menuDelete(t, id);
      await _tapSheet(t, 'categoryDeleteGo');
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.categoryTable.isLive(id), isFalse);
      expect(find.text('Category removed'), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('without a plan line there is no dialog', (t) async {
      final (:wc, :id) = await withFixed();
      await pumpApp(t, panel(wc), size: const Size(400, 2600));
      await menuDelete(t, id);
      expect(_key('categoryDeleteConfirm'), findsNothing);
      expect(wc.categoryTable.isLive(id), isFalse);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);
  });
}
