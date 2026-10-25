// Reports (P8 app half): Insights › Per pay period and Main tag vs budget, and the review's Done screen. Numbers equal core's.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'habits_test.dart' show tw;
import 'insights_test.dart' show insightsWallet, pump;

String _text(WidgetTester tester, Finder f) {
  final texts = tester.widgetList<Text>(find.descendant(of: f, matching: find.byType(Text))).map((t) => t.data ?? '').toList();
  return texts.join(' | ');
}

void main() {
  group('Per pay period', () {
    testWidgets('a row per period, newest first, numbers equal core, total line', (tester) async {
      final wc = insightsWallet();
      addTearDown(wc.dispose);
      await pump(tester, InsightsScreen(wc: wc));
      expect(find.byKey(const ValueKey('insightPanel_periods')), findsOneWidget);
      final reports = wc.periodReportsFor(count: 6);
      expect(reports, isNotEmpty);
      final cur = wc.currency;
      for (final p in reports) {
        final row = find.byKey(ValueKey('periodRow_${p.start}'));
        expect(row, findsOneWidget, reason: p.start);
        final t = _text(tester, row);
        expect(t, contains(p.net >= 0 ? 'Saved ${moneyExact(p.net, cur)}' : 'Lost ${moneyExact(-p.net, cur)}'));
        expect(t, contains('In ${moneyExact(p.income, cur)}'));
        expect(t, contains('Fixed ${moneyExact(p.fixed, cur)}'));
        expect(t, contains('Flexible ${moneyExact(p.flex, cur)}'));
        expect(p.fixed + p.flex, p.out);
      }
      expect(_text(tester, find.byKey(ValueKey('periodRow_${reports.last.start}'))), contains('so far'));
      double top(String s) => tester.getTopLeft(find.byKey(ValueKey('periodRow_$s'))).dy;
      expect(top(reports.last.start), lessThan(top(reports.first.start)));
      final net = reports.fold<int>(0, (s, p) => s + p.net);
      expect(_text(tester, find.byKey(const ValueKey('periodsTotal'))),
          contains(net >= 0 ? 'Saved ${moneyExact(net, cur)}' : 'Lost ${moneyExact(-net, cur)}'));
    });

    testWidgets('the 12 periods chip shows more rows', (tester) async {
      final wc = insightsWallet();
      addTearDown(wc.dispose);
      await pump(tester, InsightsScreen(wc: wc));
      await tester.tap(find.byKey(const ValueKey('periodCount_periods_12')));
      await tester.pump();
      for (final p in wc.periodReportsFor(count: 12)) {
        expect(find.byKey(ValueKey('periodRow_${p.start}')), findsOneWidget);
      }
    });

    testWidgets('fits 320 dp at text scale 2.0', (tester) async {
      final wc = insightsWallet();
      addTearDown(wc.dispose);
      await pump(tester, InsightsScreen(wc: wc), size: const Size(320, 20000), textScale: 2.0);
      expect(find.byKey(const ValueKey('insightPanel_periods')), findsOneWidget);
      expect(find.byKey(const ValueKey('insightPanel_categoryBudget')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Main tag vs budget', () {
    Future<void> pickTag(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(const ValueKey('catBudgetPick')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(ValueKey('catBudgetItem:$id')).last);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('picking a tag changes the bars; over-budget rows say so', (tester) async {
      final wc = insightsWallet();
      addTearDown(wc.dispose);
      await pump(tester, InsightsScreen(wc: wc), size: const Size(400, 20000));
      final cur = wc.currency;
      await pickTag(tester, 'Eating out');
      final running = wc.categoryByPeriodFor('Eating out', count: 6).firstWhere((p) => p.over);
      final row = find.byKey(ValueKey('catPeriodRow_${running.start}'));
      expect(row, findsOneWidget);
      expect(_text(tester, row), contains(moneyExact(running.spent, cur)));
      expect(_text(tester, row), contains('Over by ${moneyExact(running.overBy, cur)}'));
      expect(find.byKey(const ValueKey('catBudgetNone')), findsNothing);
      await pickTag(tester, 'Groceries');
      final groc = wc.categoryByPeriodFor('Groceries', count: 6).last;
      final grow = find.byKey(ValueKey('catPeriodRow_${groc.start}'));
      expect(_text(tester, grow), contains(moneyExact(groc.spent, cur)));
      expect(_text(tester, grow), isNot(contains('Over by')));
    });

    testWidgets('a tag without a budget says so', (tester) async {
      final wc = insightsWallet();
      addTearDown(wc.dispose);
      await pump(tester, InsightsScreen(wc: wc), size: const Size(400, 20000));
      await pickTag(tester, 'Shopping');
      expect(find.byKey(const ValueKey('catBudgetNone')), findsOneWidget);
      expect(find.text('No budget set for this main tag. Add one in Plan.'), findsOneWidget);
    });
  });

  group('Review Done screen', () {
    WalletController wishWallet({int skipped = 2}) {
      final real = DateTime.now();
      final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: DateTime.now);
      addTearDown(wc.dispose);
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': isoDate(real.subtract(const Duration(days: 3)))});
      for (var i = 0; i < skipped; i++) {
        wc.repo.decideWish(wc.repo.addWish('Thing $i', 6000), 'skipped');
      }
      wc.repo.decideWish(wc.repo.addWish('Bought one', 9900), 'bought');
      wc.reload();
      return wc;
    }

    Future<void> done(WidgetTester tester, WalletController wc, {Size size = const Size(400, 3000), double scale = 1}) async {
      await pump(tester, ReviewScreen(wc: wc), size: size, textScale: scale);
      await tester.ensureVisible(find.byKey(const ValueKey('reviewDone')));
      await tester.tap(find.byKey(const ValueKey('reviewDone')));
      await tester.pump(const Duration(milliseconds: 400));
    }

    tw('shows the streak and what waiting saved, this period and all time', (tester) async {
      final wc = wishWallet();
      await done(tester, wc);
      expect(find.byKey(const ValueKey('reviewDoneScreen')), findsOneWidget);
      expect(wc.reviewState().streak, 1);
      expect(find.textContaining(streakText(1), findRichText: true), findsOneWidget);
      final cur = wc.currency;
      expect(find.text('Saved by waiting this period: ${moneyExact(12000, cur)} (2 wishes)'), findsOneWidget);
      expect(find.text('All time: ${moneyExact(12000, cur)} (2 wishes)'), findsOneWidget);
      expect(wc.savedThisPeriod().cents, 12000);
    });

    tw('nothing saved yet says so', (tester) async {
      final wc = wishWallet(skipped: 0);
      await done(tester, wc);
      expect(find.byKey(const ValueKey('reviewSaved')), findsOneWidget);
      expect(find.textContaining('Nothing saved by waiting yet'), findsOneWidget);
    });

    tw('Close leaves the Done screen; fits 320 dp at text scale 2.0', (tester) async {
      final wc = wishWallet();
      await done(tester, wc, size: const Size(320, 8000), scale: 2.0);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('reviewClose')));
      await tester.tap(find.byKey(const ValueKey('reviewClose')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });
}
