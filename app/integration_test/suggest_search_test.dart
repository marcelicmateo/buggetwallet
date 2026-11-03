// Stage Q on screen: the main tag chips and payee list in Add expense, search with filter chips and a bold match, Plan › Rules › Suggested and
// Settings › Sync › Recent changes. Synthetic demo data only. Screenshots at a desktop size and at a phone size.
import 'dart:async';

import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'demo_data.dart';
import 'support/harness.dart';

void main() {
  Harness.init();
  itest('Q: Add expense chips, search filters, rule suggestions and recent changes, at a desktop and a phone size', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, batch: demoBatch(today), settings: {'salary': 100000, 'salaryConfirmed': true, 'paydayDay': 15});
    // Hand-added lunches, so the note has something to complete and to suggest from.
    wc.addExpense(amount: 1400, category: 'Eating out', note: 'Lunch with Ana', date: today);
    wc.addExpense(amount: 900, category: 'Eating out', note: 'Lunch at work', date: today);
    wc.addExpense(amount: 2500, category: 'Shopping', note: 'Lunch box', date: today);
    // One payee the owner put in the same main tag by hand three times: a rule is suggested.
    final bank = wc.repo.transactions().where((r) => r.live && !r.manual && r.description.contains('MCDONALDS')).toList();
    for (final r in bank.take(3)) {
      wc.repo.setCategory(r.id, 'Eating out');
    }
    wc.reload();
    final konzumId = wc.repo.transactions().firstWhere((r) => r.description.contains('KONZUM')).id;
    wc.repo.setCategory(konzumId, 'Groceries');
    wc.reload();
    await t.pumpAndSettle();

    for (final (name, size) in const [('wide', Size(1280, 800)), ('phone', Size(400, 860))]) {
      t.view.physicalSize = size * t.view.devicePixelRatio;
      await t.pumpAndSettle();

      // Add expense: chips under the note, then the payee list.
      final ctx = t.element(find.byType(Scaffold).first);
      unawaited(showSheet<String>(ctx, AddExpenseSheet(wc: wc)));
      await t.pumpAndSettle();
      await t.enterText(find.descendant(of: find.byType(AddExpenseSheet), matching: find.byKey(const ValueKey('expenseNote'))), 'Lunch');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('suggestCat:Eating out')), findsOneWidget);
      await Harness.shot(t, 'add-expense-chips-$name');
      await hideKeyboard(t);
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      if (find.byType(AddExpenseSheet).evaluate().isNotEmpty) {
        await tapVisible(t, find.byKey(const ValueKey('sheetClose')).last);
        await t.pumpAndSettle();
      }

      // Search: Uncategorised + an amount range, with a typed text.
      await goTab(t, 'Budget');
      await tapVisible(t, find.byKey(const ValueKey('searchOpen')));
      await t.pumpAndSettle();
      await tapVisible(t, find.byKey(const ValueKey('filterUncategorised')));
      await tapVisible(t, find.byKey(const ValueKey('filterAmount')));
      await t.enterText(find.byKey(const ValueKey('filterMin')), '10');
      await tapVisible(t, find.byKey(const ValueKey('filterAmountApply')));
      await t.enterText(find.byKey(const ValueKey('searchField')), 'lidl');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('filterNote')), findsOneWidget);
      await Harness.shot(t, 'search-filters-$name');
      await tapVisible(t, find.byKey(const ValueKey('searchClose')));
      await t.pumpAndSettle();

      // Today: the search button on Recent.
      await goTab(t, 'Today');
      await scrollTo(t, find.byKey(const ValueKey('todaySearch')), TodayScreen);
      await Harness.shot(t, 'today-recent-search-$name');

      // Settings › Tags and rules › Recommendations.
      await goTags(t);
      await Harness.shot(t, 'tags-window-$name');
      await scrollTo(t, find.byKey(const ValueKey('ruleSuggest:mcdonalds_zagreb')), SettingsScreen);
      await Harness.shot(t, 'rules-suggested-$name');

      // Settings › Sync › Recent changes.
      await goSettings(t, SettingsSection.sync);
      await scrollTo(t, find.byKey(const ValueKey('recentChanges')), SettingsScreen);
      await Harness.shot(t, 'sync-recent-changes-$name');
    }
    await Harness.checkLog();
  });
}
