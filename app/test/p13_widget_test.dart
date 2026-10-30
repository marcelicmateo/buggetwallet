// P13 §1 and §2: the Android home-screen widget (three words through `budget_wallet/widget`) and the launcher shortcut "Add expense"
// (`budget_wallet/shortcut`). The Kotlin side is checked by android_hardening_test.dart and the apk build; the widget itself by the owner.
// All data is SYNTHETIC.
import 'dart:async';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/home_widget.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

/// A widget stand-in: records what the app gave it.
class FakeHomeWidget implements HomeWidget {
  final bool on;
  final updates = <HomeWidgetState>[];
  int clears = 0;
  Object? failWith;
  String? first;
  final _actions = StreamController<String>.broadcast();
  FakeHomeWidget({this.on = true});
  @override
  bool get supported => on;
  @override
  Future<void> update(HomeWidgetState state) async {
    if (failWith != null) Error.throwWithStackTrace(failWith!, StackTrace.current);
    updates.add(state);
  }

  @override
  Future<void> clear() async => clears++;
  @override
  Future<String?> initialAction() async => first;
  @override
  Stream<String> get actions => _actions.stream;
  void send(String a) => _actions.add(a);
}

const _widgetChannel = MethodChannel('budget_wallet/widget');
const _shortcutChannel = MethodChannel('budget_wallet/shortcut');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late List<String> lines;

  WalletController wallet(FakeHomeWidget w) {
    final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => now, homeWidget: w);
    wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
    wc.repo.addTransaction(date: '2026-10-03', amount: 15200, category: 'Groceries', note: 'SecretShopNote');
    wc.reload();
    return wc;
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    now = DateTime(2026, 10, 20, 12);
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  group('widget updates', () {
    test('a reload gives the widget amount, status, date and payday; nothing else', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await flush();
      expect(w.updates, hasLength(1));
      final s = w.updates.single;
      expect(s.status, WidgetStatus.ok);
      expect(s.date, '2026-10-20');
      expect(s.amount, matches(RegExp(r'\d')));
      expect(s.toMap().keys.toSet(), {'amount', 'status', 'date', 'until'});
      expect(s.until, wc.period().end, reason: 'the payday the line "to 10 Nov" shows');
      expect(s.toMap().values.join(' '), isNot(contains('SecretShopNote')));
      expect(lines.join('\n'), isNot(contains(s.amount)), reason: 'the amount is never logged');
      expect(lines.where((l) => l.contains('widget.update')), isNotEmpty);
      wc.dispose();
    });

    testWidgets('the widget\'s ok amount is the text Today shows as "Safe to spend today"', (t) async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await t.runAsync(flush);
      await pumpApp(t, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {})), size: const Size(400, 3000));
      final heroText = t.widget<Text>(find.byKey(const ValueKey('safeToSpend')));
      final shown = heroText.textSpan?.toPlainText() ?? heroText.data!;
      expect(w.updates.last.status, WidgetStatus.ok);
      expect(w.updates.last.amount, shown);
      await t.pump(const Duration(seconds: 4));
    });

    test('a non-ok state sends no payday', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      wc.repo.addTransaction(date: '2026-10-20', amount: 900000, category: 'Shopping');
      wc.reload();
      await flush();
      expect(w.updates.last.status, isNot(WidgetStatus.ok));
      expect(w.updates.last.toMap().containsKey('until'), isFalse);
      wc.dispose();
    });

    test('a reload that changes nothing sends nothing; a change that moves the number sends again', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await flush();
      wc.reload();
      wc.reload();
      await flush();
      expect(w.updates, hasLength(1), reason: 'same words');
      wc.repo.addTransaction(date: '2026-10-20', amount: 1200, category: 'Groceries');
      wc.reload();
      await flush();
      expect(w.updates, hasLength(2));
      expect(w.updates.last.amount, isNot(w.updates.first.amount));
      wc.dispose();
    });

    test('a new day sends the new date even with the same numbers', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await flush();
      now = DateTime(2026, 10, 21, 9);
      wc.checkDay();
      await flush();
      expect(w.updates.map((s) => s.date), ['2026-10-20', '2026-10-21']);
      wc.dispose();
    });

    test('resume asks again but only sends what changed', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await flush();
      await wc.updateHomeWidget();
      expect(w.updates, hasLength(1));
      wc.dispose();
    });

    test('over today and payday passed have their own words and a non-negative amount', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      wc.repo.addTransaction(date: '2026-10-20', amount: 900000, category: 'Shopping');
      wc.reload();
      await flush();
      expect(w.updates.last.status, anyOf(WidgetStatus.overToday, WidgetStatus.overBudget));
      expect(w.updates.last.amount, isNot(contains('-')));
      now = DateTime(2026, 12, 20, 9);
      wc.checkDay();
      await flush();
      expect(w.updates.last.status, WidgetStatus.ended);
      expect(w.updates.last.amount, isNot(contains('-')));
      wc.dispose();
    });

    test('a failing widget is logged and never thrown; the next change tries again', () async {
      final w = FakeHomeWidget()..failWith = PlatformException(code: 'failed', message: 'x');
      final wc = wallet(w);
      await flush();
      expect(lines.where((l) => l.contains('widget.updateFailed')), isNotEmpty);
      w.failWith = null;
      await wc.updateHomeWidget();
      expect(w.updates, hasLength(1));
      wc.dispose();
    });

    test('forgetting the wallet clears the widget; no wallet open sends no numbers', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await flush();
      wc.seams.keyForgetter = () async {};
      await wc.forgetBrowser();
      await flush();
      expect(w.clears, greaterThanOrEqualTo(1));
      expect(w.updates, hasLength(1), reason: 'only the number from before');
      wc.dispose();
    });

    test('joining another wallet clears the widget again after the old one was set aside', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      await flush();
      wc.repo.setLocalValue('keyBackupConfirmed', wc.today());
      final before = w.clears;
      await wc.joinAnotherWallet(await VaultKey.generate().toText()).then((_) {}, onError: (_) {});
      await flush();
      expect(w.clears, greaterThan(before), reason: 'cleared at least once whatever the join did here');
      wc.dispose();
    });

    test('where there is no widget (desktop, web) nothing is called', () async {
      final w = FakeHomeWidget(on: false);
      final wc = wallet(w);
      wc.reload();
      await flush();
      await wc.updateHomeWidget();
      expect(w.updates, isEmpty);
      expect(w.clears, 0);
      wc.dispose();
    });

    test('defaultHomeWidget: the Android one on Android only', () {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        expect(defaultHomeWidget(), isA<NoHomeWidget>());
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(defaultHomeWidget(), isA<AndroidHomeWidget>());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('channels', () {
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      m.setMockMethodCallHandler(_widgetChannel, (c) async {
        calls.add(c);
        return null;
      });
      m.setMockMethodCallHandler(_shortcutChannel, (c) async {
        calls.add(c);
        return c.method == 'getInitialAction' ? 'addExpense' : null;
      });
      addTearDown(() {
        m.setMockMethodCallHandler(_widgetChannel, null);
        m.setMockMethodCallHandler(_shortcutChannel, null);
      });
    });

    test('update and clear: exactly the four words, then nothing', () async {
      final w = AndroidHomeWidget();
      await w.update(const HomeWidgetState(amount: '12 €', status: 'ok', date: '2026-10-20', until: '2026-11-10'));
      await w.clear();
      expect(calls.map((c) => c.method), ['update', 'clear']);
      expect(calls.first.arguments, {'amount': '12 €', 'status': 'ok', 'date': '2026-10-20', 'until': '2026-11-10'});
      expect(calls.last.arguments, isNull);
    });

    test('the shortcut that started the app, and one that arrives later', () async {
      final w = AndroidHomeWidget();
      expect(await w.initialAction(), 'addExpense');
      final got = <String>[];
      final sub = w.actions.listen(got.add);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          _shortcutChannel.name, const StandardMethodCodec().encodeMethodCall(const MethodCall('action', 'addExpense')), (_) {});
      await flush();
      expect(got, ['addExpense']);
      await sub.cancel();
    });
  });

  group('shortcut', () {
    test('Add expense: asked once, ignored for other words, ignored with no wallet open', () async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      wc.onShortcut('somethingElse');
      expect(wc.takeShortcutAdd(), isFalse);
      wc.onShortcut(addExpenseAction);
      expect(wc.takeShortcutAdd(), isTrue);
      expect(wc.takeShortcutAdd(), isFalse, reason: 'one request, one answer');
      expect(lines.where((l) => l.contains('shortcut.used')), isNotEmpty);
      wc.seams.keyForgetter = () async {};
      await wc.forgetBrowser();
      wc.onShortcut(addExpenseAction);
      expect(wc.takeShortcutAdd(), isFalse, reason: 'onboarding');
      wc.dispose();
    });

    testWidgets('the shortcut that started the app opens the Add expense sheet once the shell is up', (t) async {
      final w = FakeHomeWidget()..first = addExpenseAction;
      final wc = wallet(w);
      wc.snoozeKeyBackup();
      wc.startHomeIntegration();
      await t.runAsync(flush);
      await pumpApp(t, HomeShell(wc: wc), size: const Size(400, 900));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('addExpenseSave')), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a shortcut that reaches the running app opens the sheet', (t) async {
      final w = FakeHomeWidget();
      final wc = wallet(w);
      wc.snoozeKeyBackup();
      wc.startHomeIntegration();
      await pumpApp(t, HomeShell(wc: wc), size: const Size(400, 900));
      expect(find.byKey(const ValueKey('addExpenseSave')), findsNothing);
      w.send(addExpenseAction);
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('addExpenseSave')), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });
  });
}
