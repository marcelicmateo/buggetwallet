// Stage P1 UI: own categories and subcategories. Plan › Categories (add / subcategory / rename / hide / move / delete + Undo, refusals,
// the sync duplicate), the pickers, Spending's rolled-up "Where it goes", the drill-down's subcategories, the CSV header, and the money
// paths that must use the table. All data is SYNTHETIC (budgetWallet, fixed clock 20 Oct 2026).
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/categories_panel.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/category_picker.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 90));

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Widget panel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: CategoriesPanel(wc: wc))));

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

/// Groceries 252 and a Bakery subcategory with 40 more this month.
Future<({WalletController wc, String bakery})> withBakery() async {
  final wc = budgetWallet(budgets: false);
  final bakery = await wc.addOwnCategory(name: 'Bakery', kind: BudgetKind.flex, parent: 'Groceries');
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
      expect(wc.countedIn(items).total, 3000);
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

    test('the summary CSV header uses the labels and a subcategory counts in its parent', () async {
      final (:wc, :bakery) = await withBakery();
      await wc.renameCategory('Groceries', 'Food');
      await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      final lines = utf8.decode(wc.exportSummary().bytes.sublist(3)).trim().split('\n');
      expect(lines.first.split(','), contains('Food'));
      expect(lines.first.split(','), contains('Pets'));
      expect(lines.first, isNot(contains('Groceries')));
      expect(lines.first, isNot(contains(bakery)));
      // October: Groceries 252 + Bakery 40 + Eating out 112 + Shopping 60 = 464.
      expect(lines.last, startsWith('2026-10,'));
      expect(lines.last, endsWith(',464.00'));
      expect(lines.last.split(',')[lines.first.split(',').indexOf('Food')], '292.00');
      wc.dispose();
    });

    test('the last-used category stays a live, offered one', () async {
      final wc = budgetWallet(budgets: false);
      final id = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      wc.addExpense(amount: 500, category: id, note: 'x', date: '2026-10-19');
      expect(wc.lastExpenseCategory, id);
      await wc.setCategoryHidden(id, true);
      expect(wc.lastExpenseCategory, isNull, reason: 'hidden: not offered');
      await wc.setCategoryHidden(id, false);
      expect(wc.lastExpenseCategory, id);
      await wc.deleteOwnCategory(id);
      expect(wc.lastExpenseCategory, isNull, reason: 'deleted: not live');
      wc.dispose();
    });
  });

  group('Plan › Categories', () {
    testWidgets('grouped by kind, every built-in is listed, children sit under their parent', (t) async {
      final (:wc, :bakery) = await withBakery();
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      for (final g in ['fixed', 'flex', 'income', 'transfer']) {
        expect(find.byKey(ValueKey('categoryGroup:$g')), findsOneWidget, reason: g);
      }
      expect(find.byKey(const ValueKey('category:Rent')), findsOneWidget);
      expect(find.byKey(const ValueKey('category:Salary')), findsOneWidget);
      expect(find.byKey(const ValueKey('category:Internal transfer')), findsOneWidget);
      final parent = t.getTopLeft(find.byKey(const ValueKey('category:Groceries')));
      final child = t.getTopLeft(find.byKey(ValueKey('category:$bakery')));
      expect(child.dy, greaterThan(parent.dy));
      expect(t.getTopLeft(find.byKey(ValueKey('category:$bakery'))).dy,
          lessThan(t.getTopLeft(find.byKey(const ValueKey('category:Food delivery'))).dy));
      expect(find.text('Bakery'), findsOneWidget);
      // The child's menu has no "Add subcategory": one level only.
      await tapKey(t, 'categoryMenu:$bakery');
      expect(find.byKey(ValueKey('categoryAddChild:$bakery')), findsNothing);
      expect(find.byKey(ValueKey('categoryDeleteItem:$bakery')), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('add a category: name and kind; a taken name shows core\'s message under the field', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      await tapKey(t, 'categoryAdd');
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

    testWidgets('add a subcategory: no kind field, the kind follows the parent', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, panel(wc), size: const Size(400, 5000));
      await menu(t, 'Rent', 'categoryAddChild');
      expect(find.byKey(const ValueKey('categoryKind')), findsNothing);
      expect(find.textContaining('In Rent'), findsOneWidget);
      await typeName(t, 'Parking');
      await tapKey(t, 'categorySave');
      final kid = wc.categoryTable.childrenOf('Rent').single;
      expect(wc.categoryTable.label(kid), 'Parking');
      expect(wc.categoryTable.kindOf(kid), BudgetKind.fixed);
      expect(find.byKey(ValueKey('category:$kid')), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

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
      await wc.moveCategory(before.first, -1);
      await wc.moveCategory(before.last, 1);
      expect(wc.dataVersion, v);
      // The built-in first of its group moves too (an override with a position), and its label is untouched.
      await wc.moveCategory('Groceries', 1);
      expect(flex().indexOf('Groceries'), 1);
      expect(wc.categoryTable.label('Groceries'), 'Groceries');
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('delete shows Undo and Undo brings it back; a category with subcategories is refused with core\'s message', (t) async {
      final wc = budgetWallet(budgets: false);
      final pets = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      final kid = await wc.addOwnCategory(name: 'Vet', kind: BudgetKind.flex, parent: pets);
      await pumpApp(t, panel(wc), size: const Size(400, 2600));
      await menu(t, pets, 'categoryDeleteItem');
      expect(find.text('Move or delete its subcategories first.'), findsOneWidget);
      expect(find.byKey(ValueKey('category:$pets')), findsOneWidget);

      await menu(t, kid, 'categoryDeleteItem');
      expect(find.text('Category removed'), findsOneWidget);
      expect(find.byKey(ValueKey('category:$kid')), findsNothing);
      await t.pump(const Duration(milliseconds: 600)); // the refusal toast leaves first
      await t.tap(find.byKey(const ValueKey('toastUndo')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(ValueKey('category:$kid')), findsOneWidget);
      expect(wc.categoryTable.parentOf(kid), pets);

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
      testWidgets('the panel fits at $name (children, hidden, duplicate, long name)', (t) async {
        final (:wc, :bakery) = await withBakery();
        await wc.setCategoryHidden('Cash', true);
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
        await tapKey(t, 'categoryAdd');
        expect(t.takeException(), isNull);
        await settle(t);
        wc.dispose();
      }, timeout: _timeout);
    }
  });

  group('pickers', () {
    test('pickable offers children right after their parent, indented in the menu, and leaves hidden ones out', () async {
      final (:wc, :bakery) = await withBakery();
      await wc.setCategoryHidden('Cash', true);
      final ids = pickerIds(wc.categoryTable, kinds: const {BudgetKind.flex});
      expect(ids[ids.indexOf('Groceries') + 1], bakery);
      expect(ids, isNot(contains('Cash')));
      expect(ids, isNot(contains('Rent')), reason: 'fixed is not in the flex list');
      // A hidden parent takes its children with it, unless one of them is the current value.
      await wc.setCategoryHidden('Groceries', true);
      expect(pickerIds(wc.categoryTable, kinds: const {BudgetKind.flex}), isNot(contains(bakery)));
      expect(pickerIds(wc.categoryTable, kinds: const {BudgetKind.flex}, current: bakery), contains(bakery));
      expect(pickerLabel(wc.categoryTable, bakery), 'Bakery (hidden)');
      wc.dispose();
    });

    testWidgets('the transaction sheet\'s menu shows a child indented under its parent and no hidden category', (t) async {
      final (:wc, :bakery) = await withBakery();
      await wc.setCategoryHidden('Cash', true);
      final row = wc.txs.firstWhere((x) => x.category == 'Groceries');
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 900));
      await tapKey(t, 'txCategory');
      final pad = t.widget<Padding>(find.byKey(ValueKey('pick:$bakery')).last).padding as EdgeInsets;
      expect(pad.left, categoryIndent);
      expect(t.widget<Padding>(find.byKey(const ValueKey('pick:Groceries')).last).padding as EdgeInsets, EdgeInsets.zero);
      expect(find.byKey(const ValueKey('pick:Cash')), findsNothing);
      expect(pickerIds(wc.categoryTable), contains('Rent'), reason: 'a change can go to any kind');
      await t.tap(find.byKey(ValueKey('pick:$bakery')).last);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Bakery'), findsWidgets);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('the add-expense chips list children after the parent and hide hidden ones', (t) async {
      final (:wc, :bakery) = await withBakery();
      await wc.setCategoryHidden('Cash', true);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc, skipImpulse: true))),
          size: const Size(400, 1600));
      expect(find.byKey(const ValueKey('cat:Groceries')), findsOneWidget);
      expect(find.text('↳ Bakery'), findsOneWidget);
      expect(find.byKey(const ValueKey('cat:Cash')), findsNothing);
      expect(find.byKey(const ValueKey('cat:Bank fees')), findsNothing);
      expect(t.getTopLeft(find.byKey(ValueKey('cat:$bakery'))).dy,
          greaterThanOrEqualTo(t.getTopLeft(find.byKey(const ValueKey('cat:Groceries'))).dy));
      await t.tap(find.byKey(ValueKey('cat:$bakery')));
      await t.pump();
      expect(t.widget<ChoiceChip>(find.byKey(ValueKey('cat:$bakery'))).selected, isTrue);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('Spending and the drill-down', () {
    testWidgets('"Where it goes" shows main categories with their subcategories added in; the sum of the rows is unchanged', (t) async {
      final (:wc, :bakery) = await withBakery();
      final v = wc.spending();
      expect(v.summary.byCategory[bakery], 4000, reason: 'per row id stays');
      expect(v.byTopLevel['Groceries'], 29200);
      expect(v.byTopLevel.containsKey(bakery), isFalse);
      expect(v.byTopLevel.values.fold<int>(0, (a, b) => a + b), v.summary.byCategory.values.fold<int>(0, (a, b) => a + b));
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('categoryRow_Groceries')), findsOneWidget);
      expect(find.byKey(ValueKey('categoryRow_$bakery')), findsNothing);
      expect(find.descendant(of: find.byType(CategoryBars), matching: find.text(money(29200, 'EUR', decimals: 0))), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a renamed category is shown by its label', (t) async {
      final wc = budgetWallet(budgets: false);
      await wc.renameCategory('Eating out', 'Dining');
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 3000));
      expect(find.descendant(of: find.byType(CategoryBars), matching: find.text('Dining')), findsOneWidget);
      expect(find.descendant(of: find.byType(CategoryBars), matching: find.text('Eating out')), findsNothing);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('the detail lists the subcategories with totals above the merchants and they add up to the total', (t) async {
      final (:wc, :bakery) = await withBakery();
      final range = wc.monthRange('2026-10');
      await pumpApp(t, CategoryDetailScreen(wc: wc, category: 'Groceries', range: range), size: const Size(400, 5000));
      expect(t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('detailTotal')), matching: find.byType(Text))).data,
          moneyExact(29200, 'EUR'));
      final child = find.byKey(ValueKey('childRow_$bakery'));
      expect(find.descendant(of: child, matching: find.text('Bakery')), findsOneWidget);
      expect(find.descendant(of: child, matching: find.text(moneyExact(4000, 'EUR'))), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('childOwn')), matching: find.text(moneyExact(25200, 'EUR'))), findsOneWidget);
      expect(wc.categoryTotal('Groceries', range),
          wc.ownTotal('Groceries', range) + wc.childTotals('Groceries', range).fold<int>(0, (a, e) => a + e.$2));
      // Above the merchants.
      expect(t.getTopLeft(find.byKey(const ValueKey('subcategories'))).dy, lessThan(t.getTopLeft(find.text('WHERE IT WENT')).dy));
      // The compare lines count the subcategory too.
      expect(wc.compareFor('Groceries', range).thisMonth, 29200);
      // Tapping a subcategory opens its own detail.
      await tapKey(t, 'childRow_$bakery');
      expect(find.text('Bakery'), findsWidgets);
      expect(t.widget<Text>(find.descendant(of: find.byKey(const ValueKey('detailTotal')), matching: find.byType(Text)).last).data,
          moneyExact(4000, 'EUR'));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a category without subcategories shows no subcategory panel', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, CategoryDetailScreen(wc: wc, category: 'Eating out', range: wc.monthRange('2026-10')), size: const Size(400, 4000));
      expect(find.byKey(const ValueKey('subcategories')), findsNothing);
      expect(find.text('WHERE IT WENT'), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);
  });
}
