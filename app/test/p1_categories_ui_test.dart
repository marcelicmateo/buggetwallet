// Stage P1 UI (T1: subcategories were replaced by tags): own main tags. Plan › Main tags (add / rename / hide / move / delete + Undo,
// refusals, the sync duplicate), the pickers, Spending's "Where it goes", the drill-down, the CSV header, and the money paths that must
// use the table. All data is SYNTHETIC (budgetWallet, fixed clock 20 Oct 2026).
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/categories_panel.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/category_picker.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/detail.dart';
import 'support/tags_window.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 90));

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Widget panel(WalletController wc) => panelWithAdd(wc, () => CategoriesPanel(wc: wc));

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> menu(WidgetTester t, String id, String item) async {
  await tapKey(t, 'categoryMenu:$id');
  await tapKey(t, '$item:$id');
}

Future<void> typeName(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const ValueKey('categoryName')), text);
  await t.pump();
}

/// A category row written the way a sync from another device would (newer HLC), then reloaded.
void remoteCategory(WalletController wc, String id, String name, {String kind = 'flex'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  wc.repo.applyRemote([
    Op('category', id, {'name': name, 'kind': kind, 'position': 0, 'hidden': 0, 'deleted': 0}, Hlc(now + 60000, 0, 'peer').toString())
  ]);
  wc.reload();
}

/// Groceries 252 and a Bakery main tag of its own with 40 more this month.
Future<({WalletController wc, String bakery})> withBakery() async {
  final wc = budgetWallet(budgets: false);
  final bakery = await wc.addOwnCategory(name: 'Bakery', kind: BudgetKind.flex);
  wc.repo.addTransaction(date: '2026-10-05', amount: 4000, category: bakery, note: 'Morning bread');
  wc.reload();
  return (wc: wc, bakery: bakery);
}

void main() {
  group('money paths use the table', () {
    test('a custom fixed category in a planned cost is not reserved, a custom flex one is', () async {
      final wc = budgetWallet(budgets: false);
      final fixed = await wc.addOwnCategory(name: 'Pet insurance', kind: BudgetKind.fixed);
      final flex = await wc.addOwnCategory(name: 'Pet food', kind: BudgetKind.flex);
      wc.addPlannedCost(title: 'Vet plan', date: '2026-10-22', amount: 5000, category: fixed);
      wc.addPlannedCost(title: 'Treats', date: '2026-10-23', amount: 3000, category: flex);
      wc.reload();
      final p = wc.period();
      expect(p.duePlanned.length, 2);
      expect(p.reservedPlanned, 3000, reason: 'only the flex one comes off the flexible money');
      expect(p.duePlanned.firstWhere((x) => x.title == 'Vet plan').coveredByPlanIn(wc.categoryTable), isTrue);
      // Upcoming's "Set aside" total follows the same rule.
      final items = wc.upcomingItems('2026-10-21', '2026-10-31');
      expect(wc.setAside(items).total, 3000);
      wc.dispose();
    });

    test('a budget on a custom category survives effectiveSettings (no period start saved)', () async {
      final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
      final id = await wc.addOwnCategory(name: 'Pet food', kind: BudgetKind.flex);
      wc.repo.setCategoryBudget(id, 20000);
      wc.reload();
      expect(wc.settings.periodStart, isNull);
      expect(wc.effectiveSettings.categoryBudgets, {id: 20000});
      expect(wc.categoryBudgets, {id: 20000});
      wc.dispose();
    });

    test('the table is rebuilt with the data: a new category is there at once, a deleted one is not live', () async {
      final wc = budgetWallet(budgets: false);
      final t0 = wc.categoryTable;
      final id = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      expect(identical(wc.categoryTable, t0), isFalse);
      expect(wc.categoryTable.label(id), 'Pets');
      await wc.deleteOwnCategory(id);
      expect(wc.categoryTable.isLive(id), isFalse);
      wc.dispose();
    });

    test('a row pinned to a category that is deleted is back in the review', () async {
      final wc = budgetWallet(budgets: false);
      final id = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      wc.repo.addTransaction(date: '2026-10-18', amount: 1500, category: id, note: 'Toy');
      wc.reload();
      expect(wc.reviewRows().where((t) => t.tx.note == 'Toy'), isEmpty, reason: 'the owner set it');
      await wc.deleteOwnCategory(id);
      expect(wc.reviewRows().where((t) => t.tx.note == 'Toy'), hasLength(1), reason: 'the override is ignored; nothing was rewritten');
      await wc.undeleteOwnCategory(id);
      expect(wc.reviewRows().where((t) => t.tx.note == 'Toy'), isEmpty);
      wc.dispose();
    });

    test('the summary CSV header uses the labels and each main tag counts on its own', () async {
      final (:wc, :bakery) = await withBakery();
      wc.renameCategory('Groceries', 'Food');
      await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      final lines = utf8.decode(wc.exportSummary().bytes.sublist(3)).trim().split('\n');
      expect(lines.first.split(','), contains('Food'));
      expect(lines.first.split(','), contains('Pets'));
      expect(lines.first, isNot(contains('Groceries')));
      expect(lines.first.split(','), contains('Bakery'));
      expect(lines.first, isNot(contains(bakery)));
      // October: Groceries 252 + Bakery 40 + Eating out 112 + Shopping 60 = 464.
      expect(lines.last, startsWith('2026-10,'));
      expect(lines.last, endsWith(',464.00'));
      expect(lines.last.split(',')[lines.first.split(',').indexOf('Food')], '252.00');
      expect(lines.last.split(',')[lines.first.split(',').indexOf('Bakery')], '40.00');
      wc.dispose();
    });

    test('the last-used category stays a live, offered one', () async {
      final wc = budgetWallet(budgets: false);
      final id = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      wc.addExpense(amount: 500, category: id, note: 'x', date: '2026-10-19');
      expect(wc.lastExpenseCategory, id);
      wc.setCategoryHidden(id, true);
      expect(wc.lastExpenseCategory, isNull, reason: 'hidden: not offered');
      wc.setCategoryHidden(id, false);
      expect(wc.lastExpenseCategory, id);
      await wc.deleteOwnCategory(id);
      expect(wc.lastExpenseCategory, isNull, reason: 'deleted: not live');
      wc.dispose();
    });
  });

  group('Plan › Main tags', () {
    testWidgets('grouped by kind, every built-in is listed, an own one sits in its kind, no subcategory action', (t) async {
      final (:wc, :bakery) = await withBakery();
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      for (final g in ['fixed', 'flex', 'income', 'transfer']) {
        expect(find.byKey(ValueKey('categoryGroup:$g')), findsOneWidget, reason: g);
      }
      expect(find.byKey(const ValueKey('category:Rent')), findsOneWidget);
      expect(find.byKey(const ValueKey('category:Salary')), findsOneWidget);
      expect(find.byKey(const ValueKey('category:Internal transfer')), findsOneWidget);
      final groceries = t.getTopLeft(find.byKey(const ValueKey('category:Groceries')));
      final own = t.getTopLeft(find.byKey(ValueKey('category:$bakery')));
      expect(own.dx, groceries.dx, reason: 'a flat list: nothing is indented under another');
      expect(own.dy, greaterThan(t.getTopLeft(find.byKey(const ValueKey('category:Food delivery'))).dy), reason: 'own ones come last');
      expect(find.text('Bakery'), findsOneWidget);
      expect(find.text('Main tags'.toUpperCase()), findsOneWidget);
      // There is no "Add subcategory": tags replaced subcategories.
      await tapKey(t, 'categoryMenu:$bakery');
      expect(find.byKey(ValueKey('categoryAddChild:$bakery')), findsNothing);
      expect(find.textContaining('subcategory'), findsNothing);
      expect(find.byKey(ValueKey('categoryDeleteItem:$bakery')), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('add a category: name and kind; a taken name shows core\'s message under the field', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      await tapAdd(t, 'main');
      await typeName(t, ' groceries ');
      await tapKey(t, 'categorySave');
      expect(find.text('There is already a category with this name.'), findsOneWidget);
      expect(find.byKey(const ValueKey('categoryName')), findsOneWidget, reason: 'the sheet stays open');
      await typeName(t, '   ');
      await tapKey(t, 'categorySave');
      expect(find.text('Give the category a name.'), findsOneWidget);

      await typeName(t, 'Pet insurance');
      await tapKey(t, 'categoryKind');
      await t.tap(find.text('Fixed cost (rent, bills)').last);
      await t.pump(const Duration(milliseconds: 400));
      await tapKey(t, 'categorySave');
      final id = wc.categoryTable.topLevelIds.firstWhere((c) => wc.categoryTable.label(c) == 'Pet insurance');
      expect(wc.categoryTable.kindOf(id), BudgetKind.fixed);
      expect(find.byKey(const ValueKey('categoryName')), findsNothing);
      expect(find.byKey(ValueKey('category:$id')), findsOneWidget);
      // It sits in the fixed group (before the flexible heading).
      expect(t.getTopLeft(find.byKey(ValueKey('category:$id'))).dy,
          lessThan(t.getTopLeft(find.byKey(const ValueKey('categoryGroup:flex'))).dy));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a category stored with a parent (older data) shows as a main tag of its own and counts once', (t) async {
      final wc = budgetWallet(budgets: false);
      final now = DateTime.now().millisecondsSinceEpoch;
      wc.repo.applyRemote([
        Op(
            'category',
            'kcccccccccccc',
            {'name': 'Old child', 'kind': 'flex', 'parent': 'Groceries', 'position': 0, 'hidden': 0, 'deleted': 0},
            Hlc(now + 60000, 0, 'peer').toString())
      ]);
      wc.reload();
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      expect(find.byKey(const ValueKey('category:kcccccccccccc')), findsOneWidget);
      expect(t.getTopLeft(find.byKey(const ValueKey('category:kcccccccccccc'))).dx,
          t.getTopLeft(find.byKey(const ValueKey('category:Groceries'))).dx);
      expect(wc.categoryTable.childrenOf('Groceries'), isEmpty);
      await tapKey(t, 'categoryMenu:kcccccccccccc');
      expect(find.byKey(const ValueKey('categoryAddChild:kcccccccccccc')), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    test('a new main tag refuses a parent with core\'s message (tags replaced subcategories)', () async {
      final wc = budgetWallet(budgets: false);
      await expectLater(wc.repo.addCategory(name: 'Bakery', kind: BudgetKind.flex, parent: 'Groceries'), throwsA(isA<ArgumentError>()));
      wc.dispose();
    });

    testWidgets('rename a built-in: the label changes, the id stays, rows keep their category', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      await menu(t, 'Groceries', 'categoryRename');
      expect(find.widgetWithText(TextField, 'Groceries'), findsOneWidget, reason: 'prefilled');
      await typeName(t, 'Food shop');
      await tapKey(t, 'categorySave');
      expect(wc.categoryTable.label('Groceries'), 'Food shop');
      expect(find.text('Food shop'), findsOneWidget);
      expect(wc.txs.where((x) => x.category == 'Groceries'), isNotEmpty);
      // Same name as another category: refused with the message.
      await menu(t, 'Shopping', 'categoryRename');
      await typeName(t, 'food SHOP');
      await tapKey(t, 'categorySave');
      expect(find.text('There is already a category with this name.'), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 400));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('hide and show: marked with an icon and text, gone from the pickers, existing rows still show it', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      await menu(t, 'Cash', 'categoryHide');
      expect(find.byKey(const ValueKey('categoryHidden:Cash')), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
      expect(wc.categoryTable.pickable(), isNot(contains('Cash')));
      expect(wc.categoryTable.isLive('Cash'), isTrue);
      await tapKey(t, 'categoryMenu:Cash');
      expect(find.text('Show'), findsOneWidget);
      await tapKey(t, 'categoryHide:Cash');
      expect(find.byKey(const ValueKey('categoryHidden:Cash')), findsNothing);
      expect(wc.categoryTable.pickable(), contains('Cash'));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('move up and down reorders the group and keeps the other groups', (t) async {
      final wc = budgetWallet(budgets: false);
      final pets = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      List<String> flex() => wc.categorySiblings('Groceries');
      final before = flex();
      expect(before.last, pets);
      final fixedBefore = wc.categorySiblings('Rent');
      await menu(t, pets, 'categoryUp');
      final now = flex();
      expect(now[now.length - 2], pets);
      expect(now.last, before[before.length - 2]);
      expect(now.sublist(0, now.length - 2), before.sublist(0, before.length - 2));
      await menu(t, pets, 'categoryDown');
      expect(flex(), before);
      expect(wc.categorySiblings('Rent'), fixedBefore);
      // The first row cannot go up; the last cannot go down: nothing is written.
      final v = wc.dataVersion;
      wc.moveCategory(before.first, -1);
      wc.moveCategory(before.last, 1);
      expect(wc.dataVersion, v);
      // The built-in first of its group moves too (an override with a position), and its label is untouched.
      wc.moveCategory('Groceries', 1);
      expect(flex().indexOf('Groceries'), 1);
      expect(wc.categoryTable.label('Groceries'), 'Groceries');
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('delete shows Undo and Undo brings it back', (t) async {
      final wc = budgetWallet(budgets: false);
      final pets = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      await pumpApp(t, panel(wc), size: const Size(400, 2600));
      await menu(t, pets, 'categoryDeleteItem');
      expect(find.text('Main tag removed'), findsOneWidget);
      expect(find.byKey(ValueKey('category:$pets')), findsNothing);
      await t.tap(find.byKey(const ValueKey('toastUndo')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(ValueKey('category:$pets')), findsOneWidget);
      expect(wc.categoryTable.isLive(pets), isTrue);

      // Built-ins have no Delete item.
      await tapKey(t, 'categoryMenu:Groceries');
      expect(find.byKey(const ValueKey('categoryDeleteItem:Groceries')), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 400));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a sync duplicate says so and can be deleted; it is not offered', (t) async {
      final wc = budgetWallet(budgets: false);
      remoteCategory(wc, 'kaaaaaaaaaaaa', 'Pets');
      remoteCategory(wc, 'kbbbbbbbbbbbb', 'pets');
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      expect(find.byKey(const ValueKey('categoryDuplicate:kbbbbbbbbbbbb')), findsOneWidget);
      expect(find.textContaining('same name as Pets, not offered'), findsOneWidget);
      expect(find.byKey(const ValueKey('category:kaaaaaaaaaaaa')), findsOneWidget);
      expect(wc.categoryTable.pickable(), isNot(contains('kbbbbbbbbbbbb')));
      await tapKey(t, 'categoryDelete:kbbbbbbbbbbbb');
      expect(find.byKey(const ValueKey('categoryDuplicate:kbbbbbbbbbbbb')), findsNothing);
      expect(find.byKey(const ValueKey('category:kaaaaaaaaaaaa')), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    for (final (name, size, scale, brightness) in [
      ('320 dp at text 2.0', const Size(320, 9000), 2.0, Brightness.light),
      ('400 dp dark', const Size(400, 6000), 1.0, Brightness.dark),
      ('1280 wide', const Size(1280, 4000), 1.0, Brightness.light),
    ]) {
      testWidgets('the panel fits at $name (hidden, duplicate, long name)', (t) async {
        final (:wc, :bakery) = await withBakery();
        wc.setCategoryHidden('Cash', true);
        await wc.addOwnCategory(name: 'A very long category name for a screen', kind: BudgetKind.fixed);
        remoteCategory(wc, 'kaaaaaaaaaaaa', 'Pets');
        remoteCategory(wc, 'kbbbbbbbbbbbb', 'Pets');
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(brightness),
          builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
          home: panel(wc),
        ));
        await t.pump();
        expect(t.takeException(), isNull);
        expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, brightness);
        // Menus and the form fit too.
        await tapKey(t, 'categoryMenu:$bakery');
        expect(t.takeException(), isNull);
        await t.tapAt(const Offset(2, 2));
        await t.pump(const Duration(milliseconds: 400));
        await tapAdd(t, 'main');
        expect(t.takeException(), isNull);
        await settle(t);
        wc.dispose();
      }, timeout: _timeout);
    }
  });

  group('pickers', () {
    test('pickable is flat and leaves hidden ones out unless one is the current value', () async {
      final (:wc, :bakery) = await withBakery();
      wc.setCategoryHidden('Cash', true);
      final ids = pickerIds(wc.categoryTable, kinds: const {BudgetKind.flex});
      expect(ids, contains(bakery));
      expect(ids, isNot(contains('Cash')));
      expect(ids, isNot(contains('Rent')), reason: 'fixed is not in the flex list');
      wc.setCategoryHidden(bakery, true);
      expect(pickerIds(wc.categoryTable, kinds: const {BudgetKind.flex}), isNot(contains(bakery)));
      expect(pickerIds(wc.categoryTable, kinds: const {BudgetKind.flex}, current: bakery), contains(bakery));
      expect(pickerLabel(wc.categoryTable, bakery), 'Bakery (hidden)');
      wc.dispose();
    });

    testWidgets('the transaction sheet\'s menu lists an own main tag, no hidden one, and a change can go to any kind', (t) async {
      final (:wc, :bakery) = await withBakery();
      wc.setCategoryHidden('Cash', true);
      final row = wc.txs.firstWhere((x) => x.category == 'Groceries');
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 900));
      await tapKey(t, 'txCategory');
      expect(find.byKey(ValueKey('pick:$bakery')), findsWidgets);
      expect(find.byKey(const ValueKey('pick:Groceries')), findsWidgets);
      expect(find.byKey(const ValueKey('pick:Cash')), findsNothing);
      expect(pickerIds(wc.categoryTable), contains('Rent'), reason: 'a change can go to any kind');
      await t.tap(find.byKey(ValueKey('pick:$bakery')).last);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Bakery'), findsWidgets);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('the add-expense chips list an own main tag and hide hidden ones', (t) async {
      final (:wc, :bakery) = await withBakery();
      wc.setCategoryHidden('Cash', true);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc, skipImpulse: true))),
          size: const Size(400, 1600));
      expect(find.byKey(const ValueKey('cat:Groceries')), findsOneWidget);
      expect(find.text('Bakery'), findsOneWidget);
      expect(find.byKey(const ValueKey('cat:Cash')), findsNothing);
      expect(find.byKey(const ValueKey('cat:Bank fees')), findsNothing);
      await t.tap(find.byKey(ValueKey('cat:$bakery')));
      await t.pump();
      expect(t.widget<ChoiceChip>(find.byKey(ValueKey('cat:$bakery'))).selected, isTrue);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('Spending and the drill-down', () {
    testWidgets('"Where it goes" lists each main tag on its own; the sum of the rows is unchanged', (t) async {
      final (:wc, :bakery) = await withBakery();
      final v = wc.spending();
      expect(v.summary.byCategory[bakery], 4000);
      expect(v.byTopLevel['Groceries'], 25200);
      expect(v.byTopLevel[bakery], 4000);
      expect(v.byTopLevel.values.fold<int>(0, (a, b) => a + b), v.summary.byCategory.values.fold<int>(0, (a, b) => a + b));
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('categoryRow_Groceries')), findsOneWidget);
      expect(find.byKey(ValueKey('categoryRow_$bakery')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('whereTile')), matching: find.text(moneyExact(25200, 'EUR'))), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a renamed category is shown by its label', (t) async {
      final wc = budgetWallet(budgets: false);
      wc.renameCategory('Eating out', 'Dining');
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 3000));
      expect(find.descendant(of: find.byKey(const ValueKey('whereTile')), matching: find.text('Dining')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('whereTile')), matching: find.text('Eating out')), findsNothing);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('the detail total is the rows of the main tag alone, and there is no subcategory panel', (t) async {
      final (:wc, :bakery) = await withBakery();
      final range = wc.monthRange('2026-10');
      await pumpApp(t, CategoryDetailScreen(wc: wc, category: 'Groceries', range: range), size: const Size(400, 5000));
      expect(heroText(t, 'detailTotal'), moneyExact(25200, 'EUR'));
      expect(wc.categoryTotal('Groceries', range), 25200);
      expect(-wc.rowsOf('Groceries', null, range).fold<int>(0, (a, e) => a + e.amount), 25200);
      expect(find.byKey(const ValueKey('subcategories')), findsNothing);
      expect(find.byKey(ValueKey('childRow_$bakery')), findsNothing);
      expect(wc.compareFor('Groceries', range).thisMonth, 25200);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a main tag shows no subcategory panel', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, CategoryDetailScreen(wc: wc, category: 'Eating out', range: wc.monthRange('2026-10')), size: const Size(400, 4000));
      expect(find.byKey(const ValueKey('subcategories')), findsNothing);
      expect(find.text('WHERE IT WENT'), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);
  });
}
