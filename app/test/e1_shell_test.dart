// ENG E1 shell: per-tab warm-up keys, Ctrl+K, semantics of [+], the gear and the destinations. SYNTHETIC data only.
import 'dart:ui' as ui;

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _ctrl(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(k);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

void main() {
  test('each destination warms the values its first build reads', () {
    final wc = demoWallet(clock: pinnedNoon);
    addTearDown(wc.dispose);
    Set<String> keys(int tab) => {for (final task in wc.warmUpTasksFor(tab)) task.$1};
    expect(keys(Tabs.explore), containsAll(['period', 'payPeriods', 'monthSummary', 'averageSpending', 'spending', 'budgetVsActual']));
    expect(keys(Tabs.plan), containsAll(['budgetVsActual', 'paceRows', 'paydayForecast', 'owedTotals', 'goalTargetTotal']));
    expect(keys(Tabs.money), containsAll(['billLists', 'expectedBills', 'expectedIncomes', 'recurringPayments', 'billsCost']));
    expect(keys(Tabs.overview), containsAll(['period', 'periodDays', 'heldTotals', 'tightestBudget', 'comingUp', 'reviewState']));
    expect(keys(Tabs.settings), isEmpty);
  });

  testWidgets('Ctrl+K jumps from any destination to Explore and opens its search', (t) async {
    await pumpFull(t, demoWallet(clock: pinnedNoon), 1.0, size: const Size(400, 900));
    await tapTab(t, 'Money');
    await t.tapAt(const Offset(397, 450));
    await t.pump();
    await _ctrl(t, LogicalKeyboardKey.keyK);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(SpendingScreen), findsOneWidget);
    expect(_key('searchField'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('semantics: [+] is the button "Add", the destinations are buttons with the selected one marked, the gear has its tooltip',
      (t) async {
    final handle = t.ensureSemantics();
    await pumpFull(t, demoWallet(clock: pinnedNoon), 1.0, size: const Size(400, 900));
    final add = t.getSemantics(_key('addButton'));
    expect(add.label, 'Add');
    expect(add.getSemanticsData().flagsCollection.isButton, isTrue);
    for (final (key, selected) in [('tab:overview', true), ('tab:money', false), ('tab:explore', false), ('tab:plan', false)]) {
      final d = t.getSemantics(_key(key)).getSemanticsData();
      expect(d.flagsCollection.isButton, isTrue, reason: key);
      expect(d.flagsCollection.isSelected == ui.Tristate.isTrue, selected, reason: key);
    }
    await tapTab(t, 'Money');
    expect(t.getSemantics(_key('tab:money')).getSemanticsData().flagsCollection.isSelected, ui.Tristate.isTrue);
    await tapTab(t, 'Overview');
    expect(t.widget<IconButton>(_key('openSettings')).tooltip, startsWith('Settings'));
    handle.dispose();
    await t.pump(const Duration(seconds: 4));
  });
}
