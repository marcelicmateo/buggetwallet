// Tap-through flows on Today and Spending: add expense (validation, impulse rule), change a category once or always,
// delete an added expense, payday checklist, "Salary landed" banner. Synthetic data, well-known chains only.
// Run: make emulator-test N=flows
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/harness.dart';

/// Salary 2000, rent 500, the two default goals (100 + 100 a month): 1300 to spend from the start (today) to the period end. Under payday
/// rule C that is the 28th of next month, or of this month on the 1st-4th (a start up to 7 days after a 28th belongs to it): the tests
/// read `wc.period()`, never a fixed date.
Map<String, Object?> plan(String start) =>
    {'salary': 200000, 'rent': 50000, 'loan': 0, 'subs': 0, 'paydayDay': 28, 'periodStart': start, 'salaryConfirmed': true};

/// The big "safe to spend today" number: the keyed Text.rich itself (the key sits on the Text, not above it), read as its plain text.
Finder safeAmount() => find.byKey(const ValueKey('safeToSpend'));
String safeText(WidgetTester t) {
  final w = t.widget<Text>(safeAmount());
  return w.data ?? w.textSpan!.toPlainText();
}

Finder inSheet(Type sheet, Finder f) => find.descendant(of: find.byType(sheet), matching: f);
Finder sheetButton(String label) => inSheet(AddExpenseSheet, find.text(label)).last;
Finder tile(String amountText) => find.widgetWithText(TxTile, amountText);

/// A row with this date and category. Wide windows show the date in its own column, narrow ones as "date · category";
/// the row's data decides which, and the category text must be on screen either way.
Finder tileOn(String date, String category) => find.byWidgetPredicate(
    (w) => w is TxTile && w.t.date == date && w.t.category == category && _hasText(w, category) && _hasText(w, shortDate(date)));
bool _hasText(TxTile w, String s) => find.descendant(of: find.byWidget(w), matching: find.textContaining(s)).evaluate().isNotEmpty;

Future<void> openAddExpense(WidgetTester t) async {
  await tapVisible(t, find.text('Add expense'));
  await t.pumpAndSettle();
  expect(find.byType(AddExpenseSheet), findsOneWidget);
}

/// A new expense has no category until one is used: the CTA waits for a pick.
Future<void> pickCategory(WidgetTester t, String c) async {
  await tapVisible(t, inSheet(AddExpenseSheet, find.widgetWithText(ChoiceChip, c)));
  await t.pumpAndSettle();
}

void main() {
  Harness.init();
  Harness.private(texts: ['Lunch', 'Headphones', 'Taxi', 'Ana'], cents: [2347, 12000, 7510, 3456, 1999, 2999, 3999, 4999, 1599, 98000]);

  itest('Add expense: validation, shows in Today and Spending, safe to spend drops by the amount', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, settings: plan(today));
    final before = wc.period();
    expect(before.flexBudget, 130000);
    expect(safeText(t), moneyExact(before.safeToday, 'EUR'));

    await openAddExpense(t);
    final save = find.byKey(const ValueKey('addExpenseSave'));
    expect(t.widget<FilledButton>(save).onPressed, isNull, reason: 'no category yet: the button waits');
    await pickCategory(t, 'Eating out');
    expect(t.widget<FilledButton>(save).onPressed, isNotNull);
    await tapVisible(t, sheetButton('Add expense'));
    await t.pumpAndSettle();
    expect(status('Enter an amount, like 12.50.'), findsOneWidget);
    expect(wc.txs, isEmpty);

    await t.enterText(inSheet(AddExpenseSheet, find.byType(TextField)).first, '23,47');
    await t.enterText(inSheet(AddExpenseSheet, field('Note')), 'Lunch synthetic note');
    await t.pumpAndSettle();
    await tapVisible(t, sheetButton('Add expense'));
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsNothing);
    expect(find.text('Expense added'), findsOneWidget);

    final added = wc.txs.single;
    expect(added.amount, -2347);
    expect(added.category, 'Eating out');
    expect(added.date, today);
    expect(added.tx.source, 'manual');
    expect(added.tx.note, 'Lunch synthetic note');

    final after = wc.period();
    expect(after.spentToday, 2347);
    expect(after.allowanceToday, before.allowanceToday, reason: "today's spending doesn't change today's allowance");
    expect(after.safeToday, before.safeToday - 2347);
    expect(safeText(t), moneyExact(after.safeToday, 'EUR'));
    // The hero's sub line (the "Spent … today" sentence is gone since RX3): what the period has used of its flexible budget; the
    // "Tomorrow … · pace …" line follows in the same text.
    expect(find.textContaining('${moneyExact(after.spent, 'EUR')} of ${moneyExact(after.flexBudget, 'EUR')}'), findsOneWidget);

    await scrollTo(t, find.text('Lunch synthetic note'), TodayScreen);
    expect(tileOn(today, 'Eating out'), findsOneWidget);
    expect(find.widgetWithText(TxTile, 'added'), findsOneWidget);
    await Harness.shot(t, 'today-after-expense');

    await goTab(t, 'Budget');
    expect(find.descendant(of: find.byKey(const ValueKey('outTile')), matching: find.text(moneyExact(2347, 'EUR'))), findsOneWidget);
    await scrollTo(t, tile('−23.47\u00A0€'), SpendingScreen);
    expect(find.widgetWithText(TxTile, 'Lunch synthetic note'), findsOneWidget);
    await Harness.checkLog();
  });

  itest('Add expense over the wishlist limit: asks first; put on wishlist, or add anyway', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    await openAddExpense(t);
    await t.enterText(inSheet(AddExpenseSheet, find.byType(TextField)).first, '120');
    await pickCategory(t, 'Groceries');
    await t.enterText(inSheet(AddExpenseSheet, field('Note')), 'Headphones synthetic');
    await tapVisible(t, sheetButton('Add expense'));
    await t.pumpAndSettle();
    expect(find.text('Over 50\u00A0€: wait 72 hours first?'), findsOneWidget);
    expect(wc.txs, isEmpty);
    await tapVisible(t, find.text('Put on wishlist'));
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsNothing);
    expect(find.text('On the wishlist. Decide in 72 hours.'), findsOneWidget);
    expect(wc.wish.single.name, 'Headphones synthetic');
    expect(wc.wish.single.price, 12000);
    expect(wc.wish.single.status, 'waiting');
    expect(wc.txs, isEmpty);

    await openAddExpense(t);
    await t.enterText(inSheet(AddExpenseSheet, find.byType(TextField)).first, '75.10');
    await pickCategory(t, 'Groceries');
    await tapVisible(t, sheetButton('Add expense'));
    await t.pumpAndSettle();
    expect(find.text('Over 50\u00A0€: wait 72 hours first?'), findsOneWidget);
    await tapVisible(t, sheetButton('Add expense')); // the second tap adds it (so does Add anyway)
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsNothing);
    expect(wc.txs.single.amount, -7510);
    expect(wc.txs.single.category, 'Groceries', reason: 'the category picked');
    expect(wc.wish, hasLength(1));
    await Harness.checkLog();
  });

  itest('Category: once changes one row, always makes a merchant rule for all rows and new imports', (t) async {
    final today = todayIso();
    final rows = [
      (today, -1999, 'POS plaćanje', 'POS ZARA ZAGREB'),
      (today, -2999, 'POS plaćanje', 'POS ZARA ZAGREB'),
      (today, -3999, 'POS plaćanje', 'POS ZARA ZAGREB'),
      (today, -1599, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    ];
    final batch = pbzBatch(rows);
    final ids = [for (final n in batch.transactions) n.id];
    final wc = await Harness.start(t, settings: plan(today), batch: batch);
    String cat(String id) => wc.txs.firstWhere((x) => x.tx.id == id).category;
    expect([for (final id in ids) cat(id)], ['Shopping', 'Shopping', 'Shopping', 'Groceries']);

    await goTab(t, 'Budget');
    await scrollTo(t, tile('−19.99\u00A0€'), SpendingScreen);
    await tapVisible(t, tile('−19.99\u00A0€'));
    expect(find.byType(TxSheet), findsOneWidget);
    expect(inSheet(TxSheet, find.text('ZARA ZAGREB')), findsOneWidget);
    expect(inSheet(TxSheet, find.text('Delete')), findsNothing, reason: 'bank rows cannot be deleted');
    await pickDropdown(t, inSheet(TxSheet, find.byKey(const ValueKey('txCategory'))), 'Home & tools');
    final sw = inSheet(TxSheet, find.byType(Switch));
    expect(t.widget<Switch>(sw).value, isTrue, reason: '"Always" is on by default');
    await tapVisible(t, sw);
    await t.pumpAndSettle();
    await tapVisible(t, inSheet(TxSheet, find.text('Save')));
    await t.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect([for (final id in ids) cat(id)], ['Home & tools', 'Shopping', 'Shopping', 'Groceries']);
    expect(wc.repo.transaction(ids[0])!.category, 'Home & tools');
    expect(wc.repo.merchantRules(), isEmpty);
    expect(tileOn(today, 'Home & tools'), findsOneWidget);

    await tapVisible(t, tile('−29.99\u00A0€'));
    await pickDropdown(t, inSheet(TxSheet, find.byKey(const ValueKey('txCategory'))), 'Sport & fitness');
    await tapVisible(t, inSheet(TxSheet, find.text('Save')));
    await t.pumpAndSettle();
    expect(wc.repo.merchantRules(), {'zara_zagreb': 'Sport & fitness'});
    // The row changed "once" keeps its own category (a row's own choice beats the merchant rule).
    expect([for (final id in ids) cat(id)], ['Home & tools', 'Sport & fitness', 'Sport & fitness', 'Groceries']);
    expect(tileOn(today, 'Sport & fitness'), findsNWidgets(2));

    // New imports of the merchant follow the rule.
    final more = pbzBatch([(today, -4999, 'POS plaćanje', 'POS ZARA ZAGREB')]);
    wc.repo.importBatch(more);
    wc.reload();
    await t.pumpAndSettle();
    expect(cat(more.transactions.single.id), 'Sport & fitness');

    // "Always" on the row with its own category: the rule changes and the row's own choice is cleared.
    await scrollTo(t, tile('−19.99\u00A0€'), SpendingScreen);
    await tapVisible(t, tile('−19.99\u00A0€'));
    await pickDropdown(t, inSheet(TxSheet, find.byKey(const ValueKey('txCategory'))), 'Shopping');
    await tapVisible(t, inSheet(TxSheet, find.text('Save')));
    await t.pumpAndSettle();
    expect(wc.repo.merchantRules(), {'zara_zagreb': 'Shopping'});
    expect(wc.repo.transaction(ids[0])!.category, isNull);
    expect([
      for (final id in [...ids, more.transactions.single.id]) cat(id)
    ], [
      'Shopping',
      'Shopping',
      'Shopping',
      'Groceries',
      'Shopping'
    ]);
    await Harness.checkLog();
  });

  itest('Delete an added expense; its budget comes back', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, settings: plan(today));
    final before = wc.period();
    wc.addExpense(amount: 3456, category: 'Car & transport', note: 'Taxi synthetic note', date: today);
    await t.pumpAndSettle();
    expect(wc.period().safeToday, before.safeToday - 3456);
    final id = wc.txs.single.tx.id;

    await scrollTo(t, find.text('Taxi synthetic note'), TodayScreen);
    await tapVisible(t, find.text('Taxi synthetic note'));
    expect(inSheet(TxSheet, find.byType(Switch)), findsNothing, reason: 'no merchant rule for hand-added rows');
    await tapVisible(t, inSheet(TxSheet, find.text('Delete')));
    await t.pumpAndSettle();
    expect(find.text('Deleted'), findsOneWidget);
    expect(wc.txs, isEmpty);
    expect(wc.repo.transaction(id)!.deleted, isTrue);
    expect(wc.repo.transactions(), isEmpty);
    expect(find.text('Taxi synthetic note'), findsNothing);
    expect(wc.period().safeToday, before.safeToday);
    expect(safeText(t), moneyExact(before.safeToday, 'EUR'));
    await Harness.checkLog();
  });

  itest('Goals are paid by themselves and the "Salary landed" banner', (t) async {
    final today = todayIso();
    final payday = addDays(today, -1);
    final wc = await Harness.start(t,
        settings: {...plan(addDays(today, -40)), 'salaryConfirmed': true},
        batch: pbzBatch([(payday, 98000, 'Plaća/Mirovina', 'Neto plaća synthetic')]));
    expect(wc.newPayday(wc.period().start), payday);
    expect(find.text('Salary landed on ${shortDate(payday)}'), findsOneWidget);
    await tapVisible(t, find.text('Start new month on ${shortDate(payday)}'));
    await t.pumpAndSettle();
    expect(wc.settings.periodStart, payday);
    expect(wc.settings.incomeMode, 'planned');
    expect(find.textContaining('Salary landed on'), findsNothing);
    expect(find.textContaining('${shortDate(payday)} – '), findsOneWidget, reason: 'the period chip in the app bar');

    expect(wc.goals.map((g) => g.saved), [20000, 20000], reason: 'once for the first period, once for the new month');
    expect(find.text('Payday checklist'), findsNothing);
    await Harness.checkLog();
  });
}
