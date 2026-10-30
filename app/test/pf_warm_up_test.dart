// Stage PF: the tab fade, the idle warm-up and the staged build of the hidden pages (HomeShell, WarmUp, controller_warmup.dart).
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/save.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/warm_up.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

const _frame = Duration(milliseconds: 16);

/// Switches the background work on for one test (it is off for app/test, see flutter_test_config.dart).
void _background() {
  WarmUp.enabled = true;
  WarmUp.waitForFirstRaster = false;
  addTearDown(() {
    WarmUp.enabled = false;
    WarmUp.waitForFirstRaster = true;
  });
}

Finder _fade(String tab) => find.descendant(of: find.byKey(ValueKey('tabFade:$tab')), matching: find.byType(FadeTransition)).first;

double _opacity(WidgetTester t, String tab) => t.widget<FadeTransition>(_fade(tab)).opacity.value;

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(_frame);
  }
}

Future<void> _pumpShell(WidgetTester t, Widget shell, {bool reduceMotion = false}) async {
  t.view.physicalSize = const Size(400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion), child: c!),
    home: shell,
  ));
  await t.pump();
}

void main() {
  group('tab fade', () {
    testWidgets('the opened page fades in over about 180 ms and the first page does not fade', (t) async {
      _background();
      final wc = demoWallet();
      await _pumpShell(t, HomeShell(wc: wc));
      expect(_opacity(t, 'today'), 1, reason: 'the first page is simply there');
      await t.tap(find.text('Budget').last);
      await t.pump();
      expect(_opacity(t, 'budget'), lessThan(0.2));
      await t.pump(const Duration(milliseconds: 90));
      expect(_opacity(t, 'budget'), allOf(greaterThan(0.2), lessThan(0.9)));
      await t.pump(const Duration(milliseconds: 120));
      expect(_opacity(t, 'budget'), 1);
      await _settle(t);
    });

    testWidgets('reduced motion: the page is shown at once', (t) async {
      _background();
      final wc = demoWallet();
      await _pumpShell(t, HomeShell(wc: wc), reduceMotion: true);
      await t.tap(find.text('Bills').last);
      await t.pump();
      expect(_opacity(t, 'bills'), 1);
      await _settle(t);
    });

    testWidgets('Ctrl+2 goes through the fade too', (t) async {
      _background();
      final wc = demoWallet();
      await _pumpShell(t, HomeShell(wc: wc));
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.digit2);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(find.byType(SpendingScreen), findsOneWidget);
      expect(_opacity(t, 'budget'), lessThan(0.2));
      await t.pump(const Duration(milliseconds: 250));
      expect(_opacity(t, 'budget'), 1);
      await _settle(t);
    });

    testWidgets('pages keep their State across switches, and a switch builds no new page', (t) async {
      _background();
      final wc = demoWallet();
      await _pumpShell(t, HomeShell(wc: wc));
      await _settle(t);
      final spendingState = t.state(find.byType(SpendingScreen, skipOffstage: false));
      final spendingWidget = t.widget(find.byType(SpendingScreen, skipOffstage: false));
      final billsWidget = t.widget(find.byType(BillsScreen, skipOffstage: false));
      for (final tab in ['Budget', 'Bills', 'Save', 'Settings', 'Today', 'Budget']) {
        await t.tap(find.text(tab).last);
        await t.pump(const Duration(milliseconds: 250));
      }
      expect(identical(t.state(find.byType(SpendingScreen)), spendingState), isTrue);
      expect(identical(t.widget(find.byType(SpendingScreen)), spendingWidget), isTrue, reason: 'no new page for a switch');
      expect(identical(t.widget(find.byType(BillsScreen, skipOffstage: false)), billsWidget), isTrue);
    });

    testWidgets('a hidden page is not rebuilt while another tab fades in', (t) async {
      _background();
      final wc = demoWallet();
      await _pumpShell(t, HomeShell(wc: wc));
      await _settle(t);
      final bills = find.byType(BillsScreen, skipOffstage: false);
      final element = t.element(bills);
      await t.tap(find.text('Save').last);
      for (var i = 0; i < 15; i++) {
        await t.pump(_frame);
        expect(element.dirty, isFalse);
      }
      expect(identical(t.element(bills), element), isTrue);
    });
  });

  group('staged pages', () {
    testWidgets('only the shown page is built at first; the others follow one per frame; a tab opened early is built at once', (t) async {
      _background();
      final wc = demoWallet();
      await _pumpShell(t, HomeShell(wc: wc));
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(find.byType(SpendingScreen, skipOffstage: false), findsNothing);
      expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
      // Open Settings before its turn
      await t.tap(find.text('Settings').last);
      await t.pump();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await _settle(t);
      for (final type in [TodayScreen, SpendingScreen, BillsScreen, SaveScreen, SettingsScreen]) {
        expect(find.byType(type, skipOffstage: false), findsOneWidget, reason: '$type is built by now');
      }
    });

    testWidgets('new data builds the shown page now and the hidden ones later', (t) async {
      _background();
      final wc = demoWallet();
      // the app rebuilds the shell when the wallet changes
      await _pumpShell(t, ListenableBuilder(listenable: wc, builder: (context, child) => HomeShell(wc: wc)));
      await _settle(t);
      final bills = t.widget(find.byType(BillsScreen, skipOffstage: false));
      final today = t.widget(find.byType(TodayScreen));
      wc.addExpense(amount: -700, category: 'Groceries', note: 'x', date: wc.today());
      await t.pump();
      expect(identical(t.widget(find.byType(TodayScreen)), today), isFalse, reason: 'the shown page follows the data at once');
      expect(identical(t.widget(find.byType(BillsScreen, skipOffstage: false)), bills), isTrue, reason: 'a hidden page waits for its turn');
      await _settle(t);
      expect(identical(t.widget(find.byType(BillsScreen, skipOffstage: false)), bills), isFalse);
      // a change schedules a sync 3 s later: the controller goes with the tree
      await t.pumpWidget(const SizedBox());
      wc.dispose();
    });
  });

  group('warm-up', () {
    testWidgets('runs every task once, then calls onDone', (t) async {
      _background();
      final order = <String>[];
      var done = 0;
      final w = WarmUp();
      w.start([('a', () => order.add('a')), ('b', () => order.add('b')), ('c', () => order.add('c'))],
          current: () => true, onDone: () => done++);
      expect(order, isEmpty, reason: 'nothing runs inside the call');
      await t.pump(_frame);
      expect(order, ['a', 'b', 'c']);
      expect(done, 1);
      expect(w.tasksRun, 3);
    });

    testWidgets('a task that throws is skipped, the rest still run', (t) async {
      _background();
      final order = <String>[];
      final w = WarmUp();
      w.start([('a', () => throw StateError('x')), ('b', () => order.add('b'))], current: () => true);
      await t.pump(_frame);
      expect(order, ['b']);
    });

    testWidgets('ends quietly when the data version changed, and a new run replaces the old one', (t) async {
      _background();
      final order = <String>[];
      var live = true;
      final w = WarmUp();
      var done = 0;
      w.start([
        (
          'a',
          () {
            order.add('a');
            live = false;
          }
        ),
        ('b', () => order.add('b')),
      ], current: () => live, onDone: () => done++);
      await t.pump(_frame);
      expect(order, ['a'], reason: 'b sees the old data version and does nothing');
      expect(done, 0);

      w.start([('x', () => order.add('x')), ('y', () => order.add('y'))], current: () => true);
      w.start([('z', () => order.add('z'))], current: () => true);
      await t.pump(_frame);
      expect(order, ['a', 'z']);
    });

    testWidgets('does nothing when switched off', (t) async {
      WarmUp.enabled = false;
      final order = <String>[];
      WarmUp().start([('a', () => order.add('a'))], current: () => true);
      await t.pump(_frame);
      expect(order, isEmpty);
    });

    testWidgets('the controller list works out on a wallet with data and every task finishes', (t) async {
      _background();
      final wc = demoWallet();
      var done = false;
      wc.startWarmUp(onDone: () => done = true);
      await t.pump(_frame);
      expect(done, isTrue);
      expect(wc.warmUp.tasksRun, wc.warmUpTasks().length);
      final period = wc.period();
      wc.startWarmUp();
      await t.pump(_frame);
      expect(identical(wc.period(), period), isTrue, reason: 'the memo is still there: warming up again recomputes nothing');
    });

    testWidgets('a reload during the run stops it', (t) async {
      _background();
      final wc = demoWallet();
      var done = false;
      wc.startWarmUp(onDone: () => done = true);
      wc.reload();
      await t.pump(_frame);
      expect(done, isFalse);
      expect(wc.warmUp.tasksRun, 0);
    });
  });
}
