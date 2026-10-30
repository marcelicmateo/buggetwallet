// Profile-mode frame performance with a big SYNTHETIC wallet (~5 years, ~20,000 transactions) on the Linux desktop app:
// scrolling the Spending tab top to bottom and back, switching through all five tabs twice, Insights, and `first_switch`
// (the first visit of every tab after the data changed: what the idle warm-up should make cheap). Each action runs inside
// `binding.traceAction`; the timelines go to the host driver (test_driver/perf_driver.dart), which writes the summary
// and the full trace per action and checks the budgets (test_driver/perf_budget.dart).
// Run: tools/build.sh perf   (that is `flutter drive --profile`; a plain `flutter test` run has no timeline to trace)
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/big_wallet.dart';
import 'support/harness.dart';

/// The report key prefix the driver looks for: `perf_<action>`.
const perfPrefix = 'perf_';

void main() {
  // desktop-test and emulator.sh run every file in this folder: outside `flutter drive --profile` this one has nothing to measure
  if (!kProfileMode) {
    test('perf: only in profile mode (tools/build.sh perf)', () {}, skip: 'profile mode only: run tools/build.sh perf');
    return;
  }
  final binding = Harness.init();
  // Real frames at the real rate, as a person scrolling would get them (the default policy only draws when pumped).
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  Harness.private(texts: ['BOLT', 'SPOTIFY', 'PLODINE', 'BAUHAUS', 'DM DROGERIE'], cents: [55000, 25000, 1299, 40000]);

  itest('perf: spending scroll and tab switches with ~20k rows', (t) async {
    final today = todayIso();
    await Harness.start(t, pump: false, settings: {'salary': 180000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
    final wc = Harness.wc;
    for (final b in bigWallet(today)) {
      wc.repo.importBatch(b);
    }
    wc.reload();
    expect(wc.txs.length, greaterThan(18000));
    final opened = await Harness.restart(t); // shows the app, opened from disk as after a phone restart
    AppLog.startMonitors();
    expect(opened.txs.length, greaterThan(18000));

    await goTab(t, 'Budget');
    final list = pageList(SpendingScreen);
    t.state<ScrollableState>(list).position.jumpTo(0);
    await t.pumpAndSettle();

    // Spending: down in ten flings, then back up
    await binding.traceAction(() async {
      for (var i = 0; i < 10; i++) {
        await t.fling(list, const Offset(0, -700), 3000);
        await t.pumpAndSettle();
      }
      for (var i = 0; i < 10; i++) {
        await t.fling(list, const Offset(0, 700), 3000);
        await t.pumpAndSettle();
      }
    }, reportKey: '${perfPrefix}spending_scroll');

    // Every tab, twice
    await binding.traceAction(() async {
      for (var r = 0; r < 2; r++) {
        for (final tab in ['Budget', 'Bills', 'Save', 'Settings', 'Today']) {
          await goTab(t, tab);
        }
      }
    }, reportKey: '${perfPrefix}tab_switch');

    // Insights: open it from Spending, switch the range of the first graph through every kind and step back and forward (each
    // switch draws a new range from ~20k rows), scroll through the graphs, open a category, close both
    await goTab(t, 'Budget');
    await binding.traceAction(() async {
      await t.tap(find.byKey(const ValueKey('insightsOpen')));
      await t.pumpAndSettle();
      for (final k in ['months12', 'months3', 'payPeriod', 'month', 'months6']) {
        await t.tap(find.byKey(ValueKey('rangeChip_spending_$k')));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const ValueKey('rangeBack_spending')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rangeForward_spending')));
      await t.pumpAndSettle();
      final insights = pageList(InsightsScreen);
      await t.fling(insights, const Offset(0, -700), 3000);
      await t.pumpAndSettle();
      await t.fling(insights, const Offset(0, 700), 3000);
      await t.pumpAndSettle();
      // open the largest category (its trend and merchants come from ~20k rows), then close it and Insights
      await scrollTo(t, find.byKey(const ValueKey('insightPanel_share')), InsightsScreen);
      final shareRow =
          find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shareRow_'));
      await tapVisible(t, shareRow.first);
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sheetClose')));
      await t.pumpAndSettle();
    }, reportKey: '${perfPrefix}insights');

    // First visit of every tab after the data changed: an expense is added (the shown page rebuilds at once), the app is left idle for a
    // moment (the idle warm-up works out the derived values, then the other pages are built one per frame), then each tab is opened once.
    // Without the warm-up each of these switches builds its page and works its data out in the switch's own frame.
    await goTab(t, 'Today');
    opened.addExpense(amount: -1234, category: 'Groceries', note: 'perf first switch', date: opened.today());
    await t.pump(const Duration(seconds: 4));
    await binding.traceAction(() async {
      for (final tab in ['Budget', 'Bills', 'Save', 'Settings', 'Today']) {
        await goTab(t, tab);
      }
    }, reportKey: '${perfPrefix}first_switch');

    // Early switch: the data changes and the tabs are opened at once, before the warm-up and the staged page builds had their time
    // (a tab whose page is not built yet is built by the switch itself).
    opened.addExpense(amount: -2345, category: 'Groceries', note: 'perf early switch', date: opened.today());
    await binding.traceAction(() async {
      for (final tab in ['Budget', 'Bills', 'Save', 'Settings', 'Today']) {
        await goTab(t, tab);
      }
    }, reportKey: '${perfPrefix}early_switch');

    await Harness.checkLog();
  });
}
