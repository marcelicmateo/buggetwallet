// Layout stress: every screen and sheet in dark mode, at text scale 1.3 and 2.0, and on a small phone (320x640),
// scrolled top to bottom. Fails on any FlutterError (overflow, layout, paint), except the known bugs in Harness.knownLayoutBugs.
// Screenshots: dist/screens/layout/<variant>-<screen>-<n>.png. Run: tools/emulator.sh test layout
import 'dart:math';

import 'package:budget_wallet/src/platform.dart';
import 'package:budget_wallet/src/screens/goals.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_data.dart';
import 'support/harness.dart';

const variants = <(String, Brightness, double, Size?)>[
  ('dark', Brightness.dark, 1.0, null),
  ('text130', Brightness.light, 1.3, null),
  ('text200', Brightness.light, 2.0, null),
  ('small', Brightness.light, 1.0, Size(320, 640)),
  ('small-dark-text200', Brightness.dark, 2.0, Size(320, 640)),
  ('wide-dark', Brightness.dark, 1.0, Size(1280, 800)), // rail, two columns, dialogs
];

const longGoal = 'Emergency fund for the long winter and the car repairs synthetic';
const longWish = 'A very long wishlist item name for a synthetic layout test';
const longNote = 'A long synthetic note about a lunch with colleagues downtown';

Future<void> scrollThrough(WidgetTester t, Type screen, String prefix, {int shots = 3}) async {
  final list = pageList(screen);
  var i = 0;
  await Harness.shot(t, '$prefix-$i');
  while (i < 80) {
    final pos = t.state<ScrollableState>(list).position;
    if (pos.pixels >= pos.maxScrollExtent - 1) break;
    pos.jumpTo(min(pos.pixels + pos.viewportDimension * 0.8, pos.maxScrollExtent));
    await t.pumpAndSettle();
    i++;
    if (i < shots) await Harness.shot(t, '$prefix-$i');
  }
  t.state<ScrollableState>(list).position.jumpTo(0);
  await t.pumpAndSettle();
}

Future<void> closeSheet(WidgetTester t, Type sheet) async {
  Navigator.of(t.element(find.byType(sheet))).pop();
  await t.pumpAndSettle();
}

void main() {
  Harness.init();
  Harness.private(texts: [longGoal, longWish, longNote, 'long winter', 'layout test', 'colleagues'], cents: [140000, 55000, 98765]);

  for (final (name, brightness, scale, size) in variants) {
    itest('layout: $name', (t) async {
      final errors = <String>[];
      var where = 'start';
      final prev = FlutterError.onError;
      FlutterError.onError = (d) {
        final known = Harness.knownLayoutBug(d), e = Harness.describeLayoutError(d);
        if (known == null) {
          errors.add('$where: $e');
        } else {
          Harness.knownBug(known, false, '$e ($name, $where)');
        }
      };
      t.platformDispatcher.platformBrightnessTestValue = brightness;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      if (size != null) {
        t.view.physicalSize = size * t.view.devicePixelRatio; // what MediaQuery and layout read
        Harness.shots = !isAndroid; // a resized view hangs takeScreenshot on the emulator; desktop is fine
      }
      try {
        final wc = await Harness.start(t, wallet: false);
        final ctx = t.element(find.byType(MaterialApp));
        debugPrint('layout $name: media ${MediaQuery.sizeOf(ctx)}, render view ${t.binding.renderViews.first.size}');
        if (size != null) expect(MediaQuery.sizeOf(ctx), size);
        expect(MediaQuery.textScalerOf(ctx).scale(10), closeTo(10 * scale, 0.01));
        expect(MediaQuery.platformBrightnessOf(ctx), brightness);

        where = 'onboarding';
        debugPrint('layout $name: $where');
        await Harness.shot(t, '$name-onboarding');
        await scrollTo(t, find.text('Join my wallet from another device'), OnboardingScreen);
        await tapVisible(t, find.text('Join my wallet from another device'));
        await Harness.shot(t, '$name-onboarding-join');
        await scrollTo(t, find.text('Back'), OnboardingScreen);
        await tapVisible(t, find.text('Back'));

        where = 'today';
        await wc.createWallet();
        wc.takeKeyBackupPrompt(); // shot below through Today's row
        Harness.rememberKey(await wc.keyText());
        wc.repo.importBatch(demoBatch(wc.today()));
        wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
        wc.saveCategoryBudgets(demoBudgets); // budgeted and over-budget rows on Spending, the line on Today, the editor on Plan
        wc.saveGoal(name: longGoal, target: 98765 * 10, saved: 98765, monthly: 9876);
        wc.addWish(longWish, 98765);
        wc.addExpense(amount: 9876, category: 'Bills & one-offs', note: longNote, date: wc.today());
        await t.pumpAndSettle();
        expect(Theme.of(t.element(find.byType(TodayScreen))).brightness, brightness);

        where = 'today';
        debugPrint('layout $name: $where');
        await scrollThrough(t, TodayScreen, '$name-today');
        where = 'add-expense-sheet';
        debugPrint('layout $name: $where');
        final addExpense = find.descendant(of: find.byType(TodayScreen), matching: find.text('Add expense'));
        await scrollTo(t, addExpense, TodayScreen);
        await tapVisible(t, addExpense);
        await t.enterText(find.descendant(of: find.byType(AddExpenseSheet), matching: find.byType(TextField)).first, '120');
        await tapVisible(t, find.descendant(of: find.byType(AddExpenseSheet), matching: find.text('Add expense')).last);
        expect(find.text('Over 50\u00A0€: wishlist first?'), findsOneWidget);
        await Harness.shot(t, '$name-sheet-add-expense');
        await closeSheet(t, AddExpenseSheet);

        for (final (tab, screen) in [
          ('Spending', SpendingScreen),
          ('Wishlist', WishlistScreen),
          ('Goals', GoalsScreen),
          ('Plan', PlanScreen)
        ]) {
          where = tab.toLowerCase();
          debugPrint('layout $name: $where');
          await goTab(t, tab);
          if (tab == 'Wishlist') {
            await t.enterText(field('Price'), '120');
            await t.pumpAndSettle();
          }
          await scrollThrough(t, screen, '$name-${tab.toLowerCase()}', shots: tab == 'Plan' ? 6 : 3);
        }

        where = 'tx-sheet';
        debugPrint('layout $name: $where');
        await goTab(t, 'Spending');
        await scrollTo(t, find.textContaining('All transactions in'), SpendingScreen);
        await scrollTo(t, find.descendant(of: find.byType(SpendingScreen), matching: find.byType(TxTile)).first, SpendingScreen);
        await tapVisible(t, find.descendant(of: find.byType(SpendingScreen), matching: find.byType(TxTile)).first);
        await Harness.shot(t, '$name-sheet-tx');
        await closeSheet(t, TxSheet);

        where = 'goal-sheet';
        debugPrint('layout $name: $where');
        await goTab(t, 'Goals');
        await scrollTo(t, find.text(longGoal), GoalsScreen);
        await tapVisible(t, find.text(longGoal));
        await Harness.shot(t, '$name-sheet-goal');
        await closeSheet(t, GoalSheet);

        where = 'key-sheet';
        debugPrint('layout $name: $where');
        await goTab(t, 'Today');
        await scrollTo(t, find.text('Save now'), TodayScreen, delta: -250);
        await tapVisible(t, find.text('Save now'));
        await Harness.shot(t, '$name-sheet-key');
        await closeSheet(t, KeyBackupSheet);
        expect(t.takeException(), isNull);
      } finally {
        FlutterError.onError = prev;
        t.platformDispatcher.clearAllTestValues();
        if (size != null) t.view.resetPhysicalSize();
        Harness.shots = true;
        for (final e in errors.toSet()) {
          debugPrint('LAYOUT ERROR $name $e');
        }
      }

      expect(errors.toSet().toList(), isEmpty, reason: 'layout errors in $name (known bugs: Harness.knownLayoutBugs)');
      await Harness.checkLog();
    });
  }
}
