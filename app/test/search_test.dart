// Search in the Spending tab: icon, field, ruled result sections, jumps, Esc, Ctrl+F, narrow layout. SYNTHETIC data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

/// habitsWallet (three SYNTHGYM card payments, a confirmed SYNTHGYM bill, a "Synthetic lamp" wish) plus a goal; "synth" is in all four.
WalletController searchWallet() {
  final wc = habitsWallet(confirmBill: true);
  addTearDown(wc.dispose);
  wc.saveGoal(name: 'Synthetic holiday', target: 200000, saved: 5000, monthly: 5000);
  return wc;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

Future<void> _type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const ValueKey('searchField')), text);
  await _settle(t);
}

Future<void> _open(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('searchOpen')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

Widget _page(WalletController wc, {void Function(int)? openTab, VoidCallback? openBills, Listenable? request}) =>
    Scaffold(body: SpendingScreen(wc: wc, openTab: openTab, openBills: openBills, searchRequest: request));

void main() {
  group('controller', () {
    test('search covers transactions, goals, wishlist and bills, and is cached per data version', () {
      final wc = searchWallet();
      final r = wc.search('synth');
      expect(r.txs.map((t) => t.tx.source).toSet(), {'pbz'});
      expect(r.txs.length, 3);
      expect(r.goals.single.name, 'Synthetic holiday');
      expect(r.wishlist.single.name, 'Synthetic lamp');
      expect(r.bills, hasLength(1));
      expect(identical(wc.search('synth'), r), isTrue);
      expect(wc.search('nothing-like-this').isEmpty, isTrue);
    });

    test('the log carries counts only, never the query', () {
      Logger.root.level = Level.ALL;
      final lines = <String>[];
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(sub.cancel);
      final wc = searchWallet();
      wc.search('synthgym');
      final run = lines.where((l) => l.contains('search.run')).toList();
      expect(run, hasLength(1));
      expect(run.single, contains('"tx":3'));
      expect(run.single, contains('"chars":8'));
      expect(lines.join('\n').toLowerCase(), isNot(contains('synthgym ')));
      expect(run.single.toLowerCase(), isNot(contains('synthgym')));
    });
  });

  group('screen', () {
    testWidgets('the search icon opens a focused field; results are ruled sections', (t) async {
      final wc = searchWallet();
      await pumpApp(t, _page(wc));
      expect(find.byKey(const ValueKey('searchField')), findsNothing);
      await _open(t);
      final field = find.byKey(const ValueKey('searchField'));
      expect(field, findsOneWidget);
      expect(t.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await _type(t, 'synth');
      for (final s in ['TRANSACTIONS', 'GOALS', 'WISHLIST', 'EXPECTED BILLS']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('Synthetic holiday'), findsOneWidget);
      expect(find.text('Synthetic lamp'), findsOneWidget);
      expect(find.textContaining('SYNTHGYM'), findsWidgets);
      expect(find.byType(TxTile), findsNWidgets(3));
      expect(t.takeException(), isNull);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('only the sections with hits show', (t) async {
      final wc = searchWallet();
      await pumpApp(t, _page(wc));
      await _open(t);
      await _type(t, 'lamp');
      expect(find.text('WISHLIST'), findsOneWidget);
      expect(find.text('TRANSACTIONS'), findsNothing);
      expect(find.text('GOALS'), findsNothing);
      expect(find.text('EXPECTED BILLS'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Nothing found after 2+ characters; one character only asks for more', (t) async {
      final wc = searchWallet();
      await pumpApp(t, _page(wc));
      await _open(t);
      await _type(t, 'z');
      expect(find.text('Nothing found'), findsNothing);
      expect(find.textContaining('at least 2'), findsOneWidget);
      await _type(t, 'zq');
      expect(find.text('Nothing found'), findsOneWidget);
      await _type(t, 'synth');
      expect(find.text('Nothing found'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Esc closes the search and the Spending page is back', (t) async {
      final wc = searchWallet();
      await pumpApp(t, _page(wc));
      await _open(t);
      await _type(t, 'synth');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(find.byKey(const ValueKey('searchField')), findsNothing);
      expect(find.byKey(const ValueKey('searchOpen')), findsOneWidget);
      await _open(t);
      expect(find.text('TRANSACTIONS'), findsNothing, reason: 'a new search starts empty');
      await t.tap(find.byKey(const ValueKey('searchClose')));
      await t.pump();
      expect(find.byKey(const ValueKey('searchField')), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a transaction opens the edit sheet; goal, wish and bill jump to their tab', (t) async {
      final wc = searchWallet();
      final tabs = <int>[], hooked = <int>[];
      wc.tabHook = (tab, via) => hooked.add(tab);
      var bills = 0;
      await pumpApp(t, _page(wc, openTab: tabs.add, openBills: () => bills++));
      await _open(t);
      await _type(t, 'synth');
      await t.tap(find.text('Synthetic holiday'));
      await t.tap(find.text('Synthetic lamp'));
      final bill = find.textContaining('Confirmed');
      await t.ensureVisible(bill);
      await t.tap(bill);
      expect(tabs, [Tabs.plan], reason: 'a goal jumps to Save');
      expect(hooked, [Tabs.plan], reason: 'a wish goes through openWish: Save, and the wish is the one to show');
      expect(wc.highlightWish.value, wc.wish.firstWhere((w) => w.name == 'Synthetic lamp').id);
      expect(bills, 1);
      final tx = find.byType(TxTile).first;
      await t.ensureVisible(tx);
      await t.tap(tx);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(TxSheet), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Ctrl+F in the app opens Spending with the search field', (t) async {
      final wc = searchWallet();
      await pumpFull(t, wc, 1, size: const Size(400, 800));
      await t.tapAt(const Offset(397, 400));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('searchField')), findsOneWidget);
      expect(t.widget<IndexedStack>(find.byWidgetPredicate((w) => w is IndexedStack && w.children.length == 5)).index, Tabs.explore);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('the field stays put while the results scroll, at 320 dp and text scale 2.0', (t) async {
      final wc = searchWallet();
      for (var i = 0; i < 30; i++) {
        wc.repo.addTransaction(
            date: '2026-09-${(i % 27 + 1).toString().padLeft(2, '0')}', amount: 1000 + i, category: 'Shopping', note: 'Synthetic item $i');
      }
      wc.reload();
      await withErrors((errors) async {
        await pumpFull(t, wc, 2.0);
        await t.tap(find.descendant(of: find.byKey(const ValueKey('navBar')), matching: find.text('Explore')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        await t.tap(find.byKey(const ValueKey('searchOpen')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        await _type(t, 'synth');
        final before = t.getTopLeft(find.byKey(const ValueKey('searchField')));
        await scrollThrough(t);
        expect(t.getTopLeft(find.byKey(const ValueKey('searchField'))), before);
        errors.check();
      });
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('closing the search keeps the page where it was', (t) async {
      final wc = searchWallet();
      final request = ValueNotifier<int>(0);
      addTearDown(request.dispose);
      await pumpApp(t, _page(wc, request: request), size: const Size(400, 500));
      final list = find.byType(Scrollable).first;
      t.state<ScrollableState>(list).position.jumpTo(300);
      await t.pump();
      request.value++;
      await t.pump();
      expect(find.byKey(const ValueKey('searchField')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, 300);
      await t.pump(const Duration(seconds: 4));
    });
  });
}
