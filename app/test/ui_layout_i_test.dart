// Stage I (IUa): add button on every tab, search icon, device-local theme choice, explainers shown once, type tokens.
// SYNTHETIC data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

void main() {
  const tabs = ['Today', 'Spending', 'Wishlist', 'Goals', 'Plan'];

  group('add button', () {
    for (final tab in tabs) {
      testWidgets('phone: the add FAB is on $tab and opens Add expense once, even tapped twice', (tester) async {
        await pumpFull(tester, demoWallet(), 1.0);
        await tapTab(tester, tab);
        final fab = find.byKey(const ValueKey('addFab'));
        expect(fab, findsOneWidget);
        expect(tester.getSize(fab).shortestSide, greaterThanOrEqualTo(48));
        await tester.tap(fab);
        await tester.tap(fab, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.byType(AddExpenseSheet), findsOneWidget);
      });
    }

    testWidgets('rail layouts: the add action sits in the rail, no bottom-right FAB', (tester) async {
      await pumpFull(tester, demoWallet(), 1.0, size: const Size(1280, 800));
      expect(find.byKey(const ValueKey('addFab')), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.descendant(of: find.byType(NavigationRail), matching: find.byKey(const ValueKey('addFab'))), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('addFab')));
      await tester.pumpAndSettle();
      expect(find.byType(AddExpenseSheet), findsOneWidget);
    });
  });

  group('search icon', () {
    for (final size in const [Size(360, 800), Size(1280, 800)]) {
      testWidgets('the app bar search icon opens Spending search at ${size.width.toInt()} dp', (tester) async {
        await pumpFull(tester, demoWallet(), 1.0, size: size);
        await tester.tap(find.byKey(const ValueKey('appBarSearch')));
        await tester.pumpAndSettle();
        expect(find.byType(SearchPane), findsOneWidget);
      });
    }
  });

  group('theme mode', () {
    testWidgets('Plan › Look switches to dark and back, kept as a device-local value', (tester) async {
      final wc = demoWallet();
      await pumpFull(tester, wc, 1.0);
      expect(wc.themeModeName, 'system');
      await tapTab(tester, 'Plan');
      final seg = find.byKey(const ValueKey('themeMode'));
      await tester.scrollUntilVisible(seg, 400, scrollable: find.byType(Scrollable).hitTestable().first);
      await tester.tap(find.descendant(of: seg, matching: find.text('Dark')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(wc.themeModeName, 'dark');
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
      await tester.tap(find.descendant(of: seg, matching: find.text('Light')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(wc.themeModeName, 'light');
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.light);
    });

    test('an unknown mode is ignored', () {
      final wc = emptyWallet();
      wc.setThemeMode('purple');
      expect(wc.themeModeName, 'system');
    });
  });

  group('explainers', () {
    testWidgets('shown in full the first time, folded behind the info icon later; the icon opens them again', (tester) async {
      final wc = emptyWallet();
      Widget page() => Scaffold(body: Explainer(wc, 'demo', 'Some explanation.'));
      await pumpApp(tester, page());
      expect(find.text('Some explanation.'), findsOneWidget);
      expect(find.byKey(const ValueKey('explainerInfo')), findsNothing);
      expect(wc.explainerSeen('demo'), isTrue);
      // The same wallet again (a later visit): folded.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpApp(tester, page());
      expect(find.text('Some explanation.'), findsNothing);
      expect(tester.getSize(find.byKey(const ValueKey('explainerInfo'))).shortestSide, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const ValueKey('explainerInfo')));
      await tester.pump();
      expect(find.text('Some explanation.'), findsOneWidget);
    });

    testWidgets('a hidden tab (TickerMode off) does not use the explainer up', (tester) async {
      final wc = emptyWallet();
      Widget page(bool shown) => Scaffold(body: TickerMode(enabled: shown, child: Explainer(wc, 'hidden', 'Some explanation.')));
      await pumpApp(tester, page(false));
      expect(wc.explainerSeen('hidden'), isFalse);
      await tester.pumpWidget(MaterialApp(home: page(true)));
      expect(wc.explainerSeen('hidden'), isTrue);
    });
  });

  group('delivery-hour panel', () {
    Future<void> pump(WidgetTester tester, bool orders) async {
      final wc = budgetWallet();
      if (orders) wc.repo.addTransaction(date: '2026-09-10', amount: 1800, category: 'Food delivery');
      wc.reload();
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => DateTime(2026, 10, 20, 15))),
          size: const Size(400, 4000));
    }

    testWidgets('shown at 15:00 when the last 90 days hold a delivery order', (tester) async {
      await pump(tester, true);
      expect(find.text('After-work delivery hour'), findsOneWidget);
    });

    testWidgets('hidden at 15:00 for a wallet that never orders in', (tester) async {
      await pump(tester, false);
      expect(find.text('After-work delivery hour'), findsNothing);
    });
  });

  group('delivery gate: 90 days exactly, spending in the wallet currency only', () {
    // budgetWallet's clock is 20 Oct 2026: the window runs from 23 Jul to 20 Oct (90 days).
    Future<void> pump(WidgetTester tester, void Function(WalletController wc) setUp) async {
      final wc = budgetWallet();
      setUp(wc);
      wc.reload();
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => DateTime(2026, 10, 20, 15))),
          size: const Size(400, 4000));
    }

    testWidgets('an order on the first day of the window turns the panel on', (tester) async {
      await pump(tester, (wc) => wc.repo.addTransaction(date: '2026-07-23', amount: 1800, category: 'Food delivery'));
      expect(find.text('After-work delivery hour'), findsOneWidget);
    });

    testWidgets('an order one day before the window does not', (tester) async {
      await pump(tester, (wc) => wc.repo.addTransaction(date: '2026-07-22', amount: 1800, category: 'Food delivery'));
      expect(find.text('After-work delivery hour'), findsNothing);
    });

    testWidgets('a refund (money in) does not', (tester) async {
      await pump(tester, (wc) => wc.repo.addTransaction(date: '2026-10-10', amount: -1800, category: 'Food delivery'));
      expect(find.text('After-work delivery hour'), findsNothing);
    });

    testWidgets('an order in another currency does not', (tester) async {
      await pump(tester, (wc) => wc.repo.addTransaction(date: '2026-10-10', amount: 1800, category: 'Food delivery', currency: 'USD'));
      expect(find.text('After-work delivery hour'), findsNothing);
    });
  });

  group('theme stays put', () {
    testWidgets('a notify does not build a new theme (no theme animation after a sync or write)', (tester) async {
      final wc = demoWallet();
      await pumpFull(tester, wc, 1.0);
      ThemeData? theme() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme;
      final before = theme();
      wc.reload();
      wc.setThemeMode('dark');
      await tester.pump(const Duration(milliseconds: 20));
      expect(identical(theme(), before), isTrue);
    });

    test('the theme choice survives a controller reload', () {
      final wc = emptyWallet();
      wc.setThemeMode('dark');
      wc.reload();
      expect(wc.themeModeName, 'dark');
    });
  });

  test('type tokens: nothing under 12 dp except the eyebrow', () {
    expect(BwType.eyebrow.fontSize, greaterThanOrEqualTo(11));
    for (final s in [BwType.meta, BwType.body, BwType.bodyStrong, BwType.heading, BwType.title, BwType.amount, BwType.hero]) {
      expect(s.fontSize, greaterThanOrEqualTo(12));
    }
  });
}
