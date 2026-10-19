// Tap-through: Wishlist (affordability check, cooling off, buy / skip, save for it) and Goals (create, edit, add
// money, delete, months-to-goal text). Run: tools/emulator.sh test wishlist_goals
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/goals.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/harness.dart';

/// Salary 2000, rent 500, default goals 200: 1300 to spend.
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

void main() {
  Harness.init();
  Harness.private(
      texts: ['Robot vacuum', 'Espresso', 'Desk chair', 'Bookshelf', 'Bike', 'Camera'], cents: [12000, 8000, 9000, 60000, 15000, 30000]);

  itest('Wishlist: price check, cooling off, then buy or skip', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    await goTab(t, 'Wishlist');
    expect(find.text('Anything over 50\u00A0€ waits 72 hours on the wishlist first.'), findsOneWidget);
    expect(find.text('Your wishlist is empty. Check something above to add it.'), findsOneWidget);

    await check(t, 'Robot vacuum synthetic', '30');
    expect(status('Fits this month'), findsOneWidget);
    expect(find.text('Under 50\u00A0€, no wait needed.'), findsOneWidget);
    expect(find.textContaining('Put on wishlist'), findsNothing);

    await check(t, 'Robot vacuum synthetic', '2500');
    expect(status('Not this month'), findsOneWidget);
    expect(find.text("It's more than the 1,300\u00A0€ you have left until payday."), findsOneWidget);

    await check(t, 'Espresso synthetic', '120');
    expect(status('Fits this month'), findsOneWidget);
    await Harness.shot(t, 'wishlist-check');
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
    expect(find.text('Saved by waiting: 120\u00A0€'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);

    // No waiting time: items are ready to decide right away.
    wc.updateSettings({'coolHours': 0});
    await t.pumpAndSettle();
    await check(t, 'Desk chair synthetic', '80');
    await tapVisible(t, find.text('Put on wishlist (0h)'));
    await t.pumpAndSettle();
    expect(find.text('Waited 0h'), findsOneWidget);
    await scrollTo(t, find.text('Buy it'), WishlistScreen);
    await tapVisible(t, find.text('Buy it'));
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsOneWidget, reason: 'buying opens Add expense, filled in');
    expect(t.widget<TextField>(inSheet(AddExpenseSheet, find.byType(TextField)).first).controller!.text, '80.00');
    expect(t.widget<TextField>(inSheet(AddExpenseSheet, field('Note'))).controller!.text, 'Desk chair synthetic');
    await tapVisible(t, inSheet(AddExpenseSheet, find.text('Add expense')).last); // no impulse warning for a waited item
    await t.pumpAndSettle();
    expect(find.byType(AddExpenseSheet), findsNothing);
    expect(wc.txs.single.amount, -8000);
    expect(wc.txs.single.tx.note, 'Desk chair synthetic');
    expect(wc.wish.firstWhere((x) => x.name == 'Desk chair synthetic').status, 'bought');
    expect(find.text('Bought'), findsOneWidget);

    await scrollTo(t, find.text('Can I afford it?'.toUpperCase()), WishlistScreen, delta: -250);
    await check(t, 'Bookshelf synthetic', '90');
    await tapVisible(t, find.text('Put on wishlist (0h)'));
    await t.pumpAndSettle();
    await scrollTo(t, find.text('Skip'), WishlistScreen);
    await tapVisible(t, find.text('Skip'));
    await t.pumpAndSettle();
    expect(find.text('Saved by waiting: 210\u00A0€'), findsOneWidget);
    expect(wc.wish.map((x) => x.status), ['skipped', 'bought', 'skipped']);
    await Harness.checkLog();
  });

  itest('Wishlist: Save for it makes a goal with the price as target', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    await goTab(t, 'Wishlist');
    await check(t, 'Camera synthetic', '600');
    await tapVisible(t, find.text('Save for it'));
    await t.pumpAndSettle();
    expect(inSheet(GoalSheet, find.text('New goal')), findsOneWidget);
    expect(t.widget<TextField>(inSheet(GoalSheet, field('Name'))).controller!.text, 'Camera synthetic');
    expect(t.widget<TextField>(inSheet(GoalSheet, field('Target'))).controller!.text, '600');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    final g = wc.goals.firstWhere((x) => x.name == 'Camera synthetic');
    expect((g.target, g.saved, g.monthly), (60000, 0, 5000));
    await Harness.checkLog();
  });

  itest('Goals: create, edit, add money, reached, delete; months-to-goal text', (t) async {
    final wc = await Harness.start(t, settings: plan(todayIso()));
    final flex0 = wc.period().flexBudget;
    await goTab(t, 'Goals');
    expect(find.text('0\u00A0€ put aside'), findsOneWidget);
    expect(find.text('Emergency fund'), findsOneWidget);

    await scrollTo(t, find.text('New goal'), GoalsScreen);
    await tapVisible(t, find.text('New goal'));
    await t.pumpAndSettle();
    await t.enterText(inSheet(GoalSheet, field('Name')), 'Bike synthetic goal');
    await t.enterText(inSheet(GoalSheet, field('Target')), '600');
    await t.enterText(inSheet(GoalSheet, field('Each month')), '150');
    await t.pumpAndSettle();
    expect(find.text('At 150\u00A0€ a month you reach it in 4 months. This comes out of your daily spending money.'), findsOneWidget);
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    var g = wc.goals.firstWhere((x) => x.name == 'Bike synthetic goal');
    expect((g.target, g.saved, g.monthly), (60000, 0, 15000));
    expect(wc.period().flexBudget, flex0 - 15000, reason: 'a goal takes its monthly amount off the spending money');
    final end = wc.period().end;
    expect(find.text('0\u00A0€ / 600\u00A0€'), findsOneWidget);
    expect(find.text('150\u00A0€ a month · ${byMonth(end, 4)}'), findsOneWidget);

    Future<void> edit(void Function() fill) async {
      await scrollTo(t, find.text('Bike synthetic goal'), GoalsScreen);
      await tapVisible(t, find.text('Bike synthetic goal'));
      await t.pumpAndSettle();
      expect(inSheet(GoalSheet, find.text('Edit goal')), findsOneWidget);
      fill();
      await t.pumpAndSettle();
    }

    await edit(() {});
    await t.enterText(inSheet(GoalSheet, field('Add money now')), '300');
    await t.pumpAndSettle();
    expect(find.text('At 150\u00A0€ a month you reach it in 2 months. This comes out of your daily spending money.'), findsOneWidget);
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    g = wc.goals.firstWhere((x) => x.id == g.id);
    expect(g.saved, 30000);
    expect(find.text('300\u00A0€ / 600\u00A0€'), findsOneWidget);
    expect(find.text('300\u00A0€ put aside'), findsOneWidget);
    expect(find.text('150\u00A0€ a month · ${byMonth(end, 2)}'), findsOneWidget);

    await edit(() {});
    await t.enterText(inSheet(GoalSheet, field('Each month')), '0');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    expect(find.text('0\u00A0€ a month · Set a monthly amount'), findsOneWidget);

    await edit(() {});
    await t.enterText(inSheet(GoalSheet, field('Put aside so far')), '600');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    expect(find.text('0\u00A0€ a month · Reached'), findsOneWidget);
    expect(find.text('600\u00A0€ / 600\u00A0€'), findsOneWidget);

    await goTab(t, 'Plan');
    expect(find.descendant(of: find.byType(PlanScreen), matching: find.text('Bike synthetic goal')), findsOneWidget);
    await goTab(t, 'Goals');

    await edit(() {});
    await tapVisible(t, inSheet(GoalSheet, find.text('Delete')));
    await t.pumpAndSettle();
    expect(wc.goals.map((x) => x.name), ['Emergency fund', 'Yearly costs']);
    expect(find.text('Bike synthetic goal'), findsNothing);

    // A goal without a name is called "Goal".
    await scrollTo(t, find.text('New goal'), GoalsScreen);
    await tapVisible(t, find.text('New goal'));
    await t.pumpAndSettle();
    await t.enterText(inSheet(GoalSheet, field('Target')), '100');
    await tapVisible(t, find.text('Save goal'));
    await t.pumpAndSettle();
    expect(wc.goals.where((x) => x.name == 'Goal'), hasLength(1));
    await Harness.checkLog();
  });
}
