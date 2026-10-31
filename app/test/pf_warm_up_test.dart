// Stage PF: the tab fade, the idle warm-up and the staged build of the hidden pages (HomeShell, WarmUp, controller_warmup.dart).
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/save.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/warm_up.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _frame = Duration(milliseconds: 16);

/// Switches the background work on for one test (it is off for app/test, see flutter_test_config.dart).
void _background() {
  WarmUp.resetPointerState();
  WarmUp.enabled = true;
  WarmUp.waitForFirstRaster = false;
  addTearDown(() {
    WarmUp.resetPointerState();
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
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      expect(_opacity(t, 'today'), 1, reason: 'the first page is simply there');
      await _settle(t); // the other pages are built by now
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
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc), reduceMotion: true);
      await _settle(t);
      await t.tap(find.text('Bills').last);
      await t.pump();
      expect(_opacity(t, 'bills'), 1);
      await _settle(t);
    });

    testWidgets('Ctrl+2 goes through the fade too', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      await _settle(t);
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
      final wc = demoWallet(clock: pinnedNoon);
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
      await _settle(t);
    });

    testWidgets('a hidden page is not rebuilt while another tab fades in', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
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
      await _settle(t);
    });
  });

  group('a tab opened before its data is ready', () {
    testWidgets('the data is worked out one task per frame, then the page appears and fades in', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      await t.tap(find.text('Budget').last);
      await t.pump();
      expect(find.byType(SpendingScreen, skipOffstage: false), findsNothing);
      expect(_opacity(t, 'budget'), 0, reason: 'nothing to show yet');
      var frames = 0;
      while (find.byType(SpendingScreen, skipOffstage: false).evaluate().isEmpty && frames < 100) {
        await t.pump(_frame);
        frames++;
      }
      expect(frames, greaterThan(3), reason: 'one task a frame, not all in one');
      expect(frames, lessThan(60));
      expect(_opacity(t, 'budget'), lessThan(0.5), reason: 'the fade starts when the page is there');
      await t.pump(const Duration(milliseconds: 250));
      expect(_opacity(t, 'budget'), 1);
      await _settle(t);
    });

    testWidgets('a hidden page for older data stays shown until its new data is ready, then is built again', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, ListenableBuilder(listenable: wc, builder: (context, child) => HomeShell(wc: wc)));
      await _settle(t);
      final old = t.widget(find.byType(SpendingScreen, skipOffstage: false));
      wc.addExpense(amount: -700, category: 'Groceries', note: 'x', date: wc.today());
      await t.pump();
      await t.tap(find.text('Budget').last);
      await t.pump();
      expect(identical(t.widget(find.byType(SpendingScreen)), old), isTrue, reason: 'the old page, at once');
      await _settle(t);
      expect(identical(t.widget(find.byType(SpendingScreen)), old), isFalse, reason: 'then the page for the new data');
      await t.pumpWidget(const SizedBox());
      wc.dispose();
      await _settle(t);
    });
  });

  group('staged pages', () {
    testWidgets('only the shown page is built at first; the others follow one per frame; a tab opened early is built at once', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      expect(find.byType(TodayScreen), findsOneWidget);
      expect(find.byType(SpendingScreen, skipOffstage: false), findsNothing);
      expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
      // Open Settings before its turn: it has no data to wait for, so it is there a frame later
      await t.tap(find.text('Settings').last);
      await t.pump();
      await t.pump(_frame);
      await t.pump(_frame);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await _settle(t);
      for (final type in [TodayScreen, SpendingScreen, BillsScreen, SaveScreen, SettingsScreen]) {
        expect(find.byType(type, skipOffstage: false), findsOneWidget, reason: '$type is built by now');
      }
    });

    testWidgets('new data builds the shown page now and the hidden ones later', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
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
      final wc = demoWallet(clock: pinnedNoon);
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
      final wc = demoWallet(clock: pinnedNoon);
      var done = false;
      wc.startWarmUp(onDone: () => done = true);
      wc.reload();
      await t.pump(_frame);
      expect(done, isFalse);
      expect(wc.warmUp.tasksRun, 0);
    });
  });

  group('requests before the page exists', () {
    ScrollPosition settingsScroll(WidgetTester t) =>
        t.state<ScrollableState>(find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first).position;

    testWidgets('openSettings during staging scrolls the new Settings page to the section', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing, reason: 'Settings is not built yet');
      wc.openSettings(SettingsSection.diagnostics, via: 'link');
      await t.pump();
      await t.pump(_frame);
      await t.pump(_frame);
      expect(find.byType(SettingsScreen), findsOneWidget);
      for (var i = 0; i < 20; i++) {
        await t.pump(_frame);
      }
      expect(settingsScroll(t).pixels, greaterThan(0), reason: 'the link took the page to its section, not the top');
      await _settle(t);
    });

    testWidgets('a Bills anchor requested before the Bills page exists is delivered when it is built', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      final request = JumpRequest<BillsAnchor>()..request(BillsAnchor.slips);
      t.view.physicalSize = const Size(400, 300);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: BillsScreen(wc: wc, request: request))));
      for (var i = 0; i < 30; i++) {
        await t.pump(_frame);
      }
      final scroll = t.state<ScrollableState>(find.descendant(of: find.byType(BillsScreen), matching: find.byType(Scrollable)).first);
      expect(scroll.position.pixels, greaterThan(0));
      expect(request.takePending(), isNull, reason: 'delivered once');
      await _settle(t);
    });

    test('JumpRequest keeps a request nobody listened to until it is taken, once', () {
      final r = JumpRequest<int>();
      expect(r.takePending(), isNull);
      r.request(3);
      expect(r.takePending(), 3);
      expect(r.takePending(), isNull);
      var heard = 0;
      r.addListener(() => heard++);
      r.request(4);
      expect(heard, 1);
      expect(r.takePending(), isNull, reason: 'a page was listening: it has it');
      expect(r.value, 4);
    });

    testWidgets('search from Today reaches the Budget page that is built by the click', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      expect(find.byType(SpendingScreen, skipOffstage: false), findsNothing);
      t.widget<TodayScreen>(find.byType(TodayScreen)).openSearch!();
      await t.pump();
      expect(find.byType(SpendingScreen, skipOffstage: false), findsNothing, reason: 'its data is being worked out first');
      for (var i = 0; i < 60; i++) {
        await t.pump(_frame);
      }
      expect(find.byKey(const ValueKey('searchField')), findsOneWidget, reason: 'the search view is open');
      await _settle(t);
    });
  });

  group('the shell under changes', () {
    testWidgets('a replaced controller leaves no page of the old one', (t) async {
      _background();
      final first = demoWallet(clock: pinnedNoon), second = demoWallet(clock: pinnedNoon);
      final current = ValueNotifier<WalletController>(first);
      addTearDown(current.dispose);
      await _pumpShell(t, ValueListenableBuilder<WalletController>(valueListenable: current, builder: (c, wc, _) => HomeShell(wc: wc)));
      await _settle(t);
      expect(t.widget<BillsScreen>(find.byType(BillsScreen, skipOffstage: false)).wc, same(first));
      current.value = second;
      await t.pump();
      expect(find.byType(BillsScreen, skipOffstage: false), findsNothing, reason: 'the old controller\'s hidden page is dropped at once');
      expect(t.widget<TodayScreen>(find.byType(TodayScreen)).view, isNotNull);
      await _settle(t);
      expect(t.widget<BillsScreen>(find.byType(BillsScreen, skipOffstage: false)).wc, same(second));
      expect(t.widget<SpendingScreen>(find.byType(SpendingScreen, skipOffstage: false)).wc, same(second));
    });

    testWidgets('a new day restarts the warm-up and refreshes the hidden pages', (t) async {
      _background();
      var now = DateTime(2026, 10, 31, 22, 30);
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => now);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-10', 150000, 'Plaća/Mirovina', 'Neto placa synthetic'),
        syntheticTx('2026-10-20', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
      ]));
      wc.repo.updateSettings({'salary': 150000, 'periodStart': '2026-10-10', 'salaryConfirmed': true});
      wc.reload();
      await _pumpShell(t, ListenableBuilder(listenable: wc, builder: (context, child) => HomeShell(wc: wc)));
      await _settle(t);
      final done = wc.warmUp.tasksRun;
      expect(done, wc.warmUpTasks().length);
      final bills = t.widget(find.byType(BillsScreen, skipOffstage: false));
      now = DateTime(2026, 11, 1, 0, 5);
      wc.checkDay();
      await t.pump();
      expect(wc.warmUp.tasksRun, 0, reason: 'a new run started');
      await _settle(t);
      expect(wc.warmUp.tasksRun, wc.warmUpTasks().length);
      expect(identical(t.widget(find.byType(BillsScreen, skipOffstage: false)), bills), isFalse, reason: 'built again for the new day');
    });

    testWidgets('unmounting the shell in the middle of a run is quiet', (t) async {
      _background();
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      await t.pump(_frame);
      await t.pump(_frame);
      await t.pumpWidget(const SizedBox());
      await _settle(t); // no pending timer and no exception afterwards
      expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
    });

    testWidgets('waiting for the first raster: nothing starts before it, the shell works', (t) async {
      _background();
      WarmUp.waitForFirstRaster = true;
      final wc = demoWallet(clock: pinnedNoon);
      await _pumpShell(t, HomeShell(wc: wc));
      await _settle(t);
      if (!WidgetsBinding.instance.firstFrameRasterized) {
        expect(wc.warmUp.tasksRun, 0, reason: 'the first frame is not rasterized: the warm-up waits');
        expect(find.byType(BillsScreen, skipOffstage: false), findsNothing);
      }
      await t.tap(find.text('Bills').last);
      await _settle(t); // its data is worked out a task a frame, then the page is built
      expect(find.byType(BillsScreen), findsOneWidget);
      await _settle(t);
    });
  });

  group('idle gate', () {
    testWidgets('nothing runs while a finger is down or within 300 ms of it', (t) async {
      _background();
      await t.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      final order = <String>[];
      WarmUp().start([('a', () => order.add('a'))], current: () => true);
      final g = await t.startGesture(const Offset(20, 20));
      for (var i = 0; i < 30; i++) {
        await t.pump(_frame);
      }
      expect(order, isEmpty, reason: 'a finger is down');
      await g.up();
      await t.pump(const Duration(milliseconds: 100));
      expect(order, isEmpty, reason: 'just lifted');
      await _settle(t);
      expect(order, ['a']);
    });

    testWidgets('nothing runs while the app is hidden, it goes on when shown', (t) async {
      _background();
      await t.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(t.binding.framesEnabled, isFalse);
      final order = <String>[];
      WarmUp().start([('a', () => order.add('a'))], current: () => true);
      await t.pump(const Duration(seconds: 2));
      expect(order, isEmpty);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(seconds: 1));
      await _settle(t);
      expect(order, ['a']);
    });
  });
}
