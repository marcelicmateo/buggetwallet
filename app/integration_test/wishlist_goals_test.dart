// Tap-through: Wishlist (affordability check, cooling off, buy / skip, save for it) and Goals (create, edit, add
// money, delete, months-to-goal text). Run: tools/emulator.sh test wishlist_goals
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/save.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/harness.dart';

/// Salary 2000, rent 500, default goals 200: 1300 to spend from the start (today) to the period end (payday rule C: the 28th of next month,
/// or of this month on the 1st-4th; the tests read `wc.period().end`, never a fixed date).
Map<String, Object?> plan(String start) =>
    {'salary': 200000, 'rent': 50000, 'loan': 0, 'subs': 0, 'paydayDay': 28, 'periodStart': start, 'salaryConfirmed': true};

Finder inSheet(Type sheet, Finder f) => find.descendant(of: find.byType(sheet), matching: f);
Finder inWish(Finder f) => find.descendant(of: find.byType(WishlistScreen), matching: f);

Future<void> check(WidgetTester t, String what, String price) async {
  await t.enterText(inWish(field('What')), what);
  await t.enterText(inWish(field('Price')), price);
  await t.pumpAndSettle();
}

/// `by Month Year`: the goal is reached with the n-th monthly payment, the first one on the next payday.
String byMonth(String periodEnd, int n) {
  final end = parseIso(periodEnd);
  final d = DateTime.utc(end.year, end.month + n - 1, 15);
  return 'by ${monthYear(d.year, d.month)}';
}

/// The "Saved by waiting" tile showing [value].
Finder saved(String value) => find.descendant(of: find.byKey(const ValueKey('savedByWaiting')), matching: find.text(value));

/// The ring tile of the goal called [name] (its label is shown in capitals).
Finder goalTile(String name) => find.ancestor(of: find.text(name.toUpperCase()), matching: find.byType(Tile));

void main() {
  Harness.init();
  Harness.private(
      texts: ['Robot vacuum', 'Espresso', 'Desk chair', 'Bookshelf', 'Bike', 'Camera'], cents: [12000, 8000, 9000, 60000, 15000, 30000]);

  itest('Wishlist: price check, cooling off, then buy or skip', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    await goTab(t, 'Save');
    expect(find.text('Over 50\u00A0€ waits 72 h'), findsOneWidget);
    expect(find.byKey(const ValueKey('emptySection:Cooling off')), findsOneWidget);

    await check(t, 'Robot vacuum synthetic', '30');
    expect(status('Fits this month'), findsOneWidget);
    expect(find.textContaining('no wait needed'), findsNothing, reason: 'the tile note already says what waits');
    expect(find.textContaining('Put on wishlist'), findsNothing);

    await check(t, 'Robot vacuum synthetic', '2500');
    expect(status('Not this month'), findsOneWidget);
    expect(find.text("It's more than the 1,300\u00A0€ you have left until payday."), findsOneWidget);

    await check(t, 'Espresso synthetic', '120');
    expect(status('Fits this month'), findsOneWidget);
    await Harness.shot(t, 'wishlist-check');
    await scrollTo(t, find.text('Put on wishlist (72h)'), SaveScreen);
    await tapVisible(t, find.text('Put on wishlist (72h)'));
    await t.pumpAndSettle();
    expect(find.text('On the wishlist. Decide in 72 hours.'), findsOneWidget);
    final w = wc.wish.single;
    expect((w.name, w.price, w.status), ('Espresso synthetic', 12000, 'waiting'));
    expect(t.widget<TextField>(inWish(field('Price'))).controller!.text, isEmpty, reason: 'the form is cleared');
    expect(find.text('Espresso synthetic'), findsOneWidget);
    // Just added: a little under 72 hours left, rounded up to whole hours (never "2d 24h").
    expect(find.text('3d left'), findsOneWidget);

    await tapVisible(t, find.text("Don't need it"));
    await t.pumpAndSettle();
    expect(wc.wish.single.status, 'skipped');
    expect(saved('120\u00A0€'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);

    // No waiting time: items are ready to decide right away.
    wc.updateSettings({'coolHours': 0});
    await t.pumpAndSettle();
    await check(t, 'Desk chair synthetic', '80');
    await scrollTo(t, find.text('Put on wishlist (0h)'), SaveScreen);
    await tapVisible(t, find.text('Put on wishlist (0h)'));
    await t.pumpAndSettle();
    expect(find.text('Waited 0h'), findsOneWidget);
    await scrollTo(t, find.text('Buy it'), SaveScreen);
    await tapVisible(t, find.text('Buy it'));
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsOneWidget, reason: 'buying opens Add expense, filled in');
    expect(t.widget<TextField>(inSheet(AddExpenseSheet, find.byType(TextField)).first).controller!.text, '80');
    expect(t.widget<TextField>(inSheet(AddExpenseSheet, field('Note'))).controller!.text, 'Desk chair synthetic');
    // A new expense has no category until one is used: the button waits for a pick.
    await tapVisible(t, inSheet(AddExpenseSheet, find.widgetWithText(ChoiceChip, 'Groceries')));
    await t.pumpAndSettle();
    await tapVisible(t, inSheet(AddExpenseSheet, find.text('Add expense')).last); // no impulse warning for a waited item
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsNothing);
    expect(wc.txs.single.amount, -8000);
    expect(wc.txs.single.tx.note, 'Desk chair synthetic');
    expect(wc.wish.firstWhere((x) => x.name == 'Desk chair synthetic').status, 'bought');
    expect(find.text('Bought'), findsOneWidget);

    await scrollTo(t, find.text('Can I afford it?'.toUpperCase()), SaveScreen, delta: -250);
    await check(t, 'Bookshelf synthetic', '90');
    await scrollTo(t, find.text('Put on wishlist (0h)'), SaveScreen);
    await tapVisible(t, find.text('Put on wishlist (0h)'));
    await t.pumpAndSettle();
    await scrollTo(t, find.text('Skip'), SaveScreen);
    await tapVisible(t, find.text('Skip'));
    await t.pumpAndSettle();
    expect(saved('210\u00A0€'), findsOneWidget);
    expect(wc.wish.map((x) => x.status), ['skipped', 'bought', 'skipped']);
    await Harness.checkLog();
  });

  itest('Wishlist: Save for it makes a goal with the price as target', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    await goTab(t, 'Save');
    await check(t, 'Camera synthetic', '600');
    await scrollTo(t, find.text('Save for it'), SaveScreen);
    await tapVisible(t, find.text('Save for it'));
    await t.pumpAndSettle();
    expect(inSheet(GoalSheet, find.text('New goal')), findsOneWidget);
    expect(t.widget<TextField>(inSheet(GoalSheet, field('Name'))).controller!.text, 'Camera synthetic');
    expect(t.widget<TextField>(inSheet(GoalSheet, field('Target'))).controller!.text, '600');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    final g = wc.goals.firstWhere((x) => x.name == 'Camera synthetic');
    expect((g.target, g.saved, g.monthly), (60000, 5000, 5000), reason: 'paid for this pay period at once');
    await Harness.checkLog();
  });

  itest('Goals: create, edit, add money, reached, delete; months-to-goal text', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    final flex0 = wc.period().flexBudget;
    await goTab(t, 'Save');
    expect(find.descendant(of: find.byKey(const ValueKey('goalsTotal')), matching: find.text('200\u00A0€')), findsOneWidget,
        reason: 'two goals paid by themselves');
    expect(find.text('EMERGENCY FUND'), findsOneWidget);

    await scrollTo(t, find.byKey(const ValueKey('addGoal')), SaveScreen);
    await tapVisible(t, find.byKey(const ValueKey('addGoal')));
    await t.pumpAndSettle();
    await t.enterText(inSheet(GoalSheet, field('Name')), 'Bike synthetic goal');
    await t.enterText(inSheet(GoalSheet, field('Target')), '600');
    await t.enterText(inSheet(GoalSheet, field('Each month')), '150');
    await t.pumpAndSettle();
    expect(find.text('At 150\u00A0€ a month you reach it in 4 months. This comes out of your daily spending money.'), findsOneWidget);
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    var g = wc.goals.firstWhere((x) => x.name == 'Bike synthetic goal');
    expect((g.target, g.saved, g.monthly), (60000, 15000, 15000));
    expect(wc.period().flexBudget, flex0 - 15000, reason: 'a goal takes its monthly amount off the spending money');
    final end = wc.period().end;
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.textContaining('25% of 600\u00A0€')), findsOneWidget);
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.textContaining(byMonth(end, 3))), findsOneWidget);

    Future<void> edit(void Function() fill) async {
      await scrollTo(t, find.text('BIKE SYNTHETIC GOAL'), SaveScreen);
      await tapVisible(t, find.text('BIKE SYNTHETIC GOAL'));
      await t.pumpAndSettle();
      expect(inSheet(GoalSheet, find.text('Edit goal')), findsOneWidget);
      fill();
      await t.pumpAndSettle();
    }

    await edit(() {});
    expect(t.widget<TextField>(inSheet(GoalSheet, field('This pay period'))).controller!.text, '150');
    await Harness.shot(t, 'goal-sheet');
    await tapVisible(t, find.byKey(const ValueKey('goalTakeOut')));
    await t.pumpAndSettle();
    await Harness.shot(t, 'goal-sheet-takeout');
    await t.enterText(inSheet(GoalSheet, field('Add money now')), '300');
    await t.pumpAndSettle();
    expect(find.text('At 150\u00A0€ a month you reach it in 1 months. This comes out of your daily spending money.'), findsOneWidget);
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    g = wc.goals.firstWhere((x) => x.id == g.id);
    expect(g.saved, 45000);
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.text('450\u00A0€')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('goalsTotal')), matching: find.text('650\u00A0€')), findsOneWidget);
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.textContaining(byMonth(end, 1))), findsOneWidget);

    await edit(() {});
    await t.enterText(inSheet(GoalSheet, field('Each month')), '0');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.textContaining('Set a monthly amount')), findsOneWidget);

    await edit(() {});
    await t.enterText(inSheet(GoalSheet, field('Put aside so far')), '600');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.text('Reached')), findsOneWidget);
    expect(find.descendant(of: goalTile('Bike synthetic goal'), matching: find.text('600\u00A0€')), findsOneWidget);

    await goTab(t, 'Budget');
    await t.tap(find.byKey(const ValueKey('budgetPlan')));
    await t.pumpAndSettle();
    expect(find.text('Bike synthetic goal'), findsOneWidget, reason: 'a goal line in the payday plan');
    await goTab(t, 'Save');

    await edit(() {});
    await tapVisible(t, inSheet(GoalSheet, find.text('Delete')));
    await t.pumpAndSettle();
    expect(wc.goals.map((x) => x.name), ['Emergency fund', 'Yearly costs']);
    expect(find.text('BIKE SYNTHETIC GOAL'), findsNothing);

    // A goal without a name is called "Goal".
    await scrollTo(t, find.byKey(const ValueKey('addGoal')), SaveScreen);
    await tapVisible(t, find.byKey(const ValueKey('addGoal')));
    await t.pumpAndSettle();
    await t.enterText(inSheet(GoalSheet, field('Target')), '100');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    expect(wc.goals.where((x) => x.name == 'Goal'), hasLength(1));
    await Harness.checkLog();
  });
}
