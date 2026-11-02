// Stage I (IUb): honest states and flows. Over-today and over-plan sentences on Today, one setup panel, wish naming,
// toasts (2.5 s, Undo, Open), form defaults, backup and relay texts. All data SYNTHETIC; fixed clocks (20 Oct 2026).
import 'package:budget_wallet/src/clock_notice.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;
import 'package:wallet_sync/wallet_sync.dart';

import 'support/layout.dart' show pumpFull, tapTab;
import 'support/plan_page.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Finder key(String k) => find.byKey(ValueKey(k));

/// A wallet on 20 Oct 2026 with the key confirmed (no setup panel), salary confirmed, plan from 1 Oct.
WalletController wallet({DateTime? now, int salary = 150000}) {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => now ?? budgetToday);
  wc.repo.updateSettings({'salary': salary, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
  wc.repo.setLocalValue('keyBackupConfirmed', '1');
  wc.reload();
  addTearDown(wc.dispose);
  return wc;
}

Widget today(WalletController wc) =>
    Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {}, clock: () => budgetToday));

String textOf(WidgetTester t, String k) =>
    t.widgetList<Text>(find.descendant(of: key(k), matching: find.byType(Text))).map((w) => w.data ?? '').join(' ');

void main() {
  group('I1 Today over states', () {
    testWidgets('over today: one sentence with tomorrow, no negative numbers', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-20', amount: 80000, category: 'Shopping');
      wc.reload();
      final p = wc.period();
      expect(p.overToday > 0 && p.overBy == 0, isTrue, reason: 'precondition: over today only (${p.overToday}, ${p.overBy})');
      await pumpApp(t, today(wc), size: const Size(400, 1600));
      final s = textOf(t, 'overSentence');
      expect(s, 'Nothing more today');
      expect(find.textContaining('Tomorrow'), findsOneWidget);
      expect(find.textContaining('-'), findsNothing, reason: 'no minus sign on Today');
      expect(find.textContaining('OVER TODAY BY'), findsOneWidget);
    });

    testWidgets('over the period: says over the plan, once', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-20', amount: 400000, category: 'Shopping');
      wc.reload();
      expect(wc.period().overBy > 0, isTrue);
      await pumpApp(t, today(wc), size: const Size(400, 1600));
      expect(find.descendant(of: key('overSentence'), matching: find.textContaining('over plan', findRichText: true)), findsOneWidget);
      expect(find.textContaining('over plan', findRichText: true), findsOneWidget, reason: 'said once');
    });

    testWidgets('last day, over the plan: the period sentence, no tomorrow figure', (t) async {
      final wc = wallet(now: DateTime(2026, 10, 31, 12));
      wc.repo.addTransaction(date: '2026-10-31', amount: 400000, category: 'Shopping');
      wc.reload();
      final p = wc.period();
      expect(p.allowanceTomorrow, isNull);
      expect(p.overToday > 0 && p.overBy > 0, isTrue, reason: 'precondition: over on the last day (${p.overToday}, ${p.overBy})');
      await pumpApp(
          t,
          Scaffold(
              body: TodayScreen(
                  key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {}, clock: () => DateTime(2026, 10, 31, 12))),
          size: const Size(400, 1600));
      expect(find.descendant(of: key('overSentence'), matching: find.textContaining('over plan', findRichText: true)), findsOneWidget);
      expect(find.textContaining('Tomorrow'), findsNothing);
      expect(find.textContaining('-'), findsNothing, reason: 'no minus sign on Today');
    });

    testWidgets('last day, under the plan: no over sentence', (t) async {
      final wc = wallet(now: DateTime(2026, 10, 31, 12));
      expect(wc.period().allowanceTomorrow, isNull);
      await pumpApp(
          t,
          Scaffold(
              body: TodayScreen(
                  key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {}, clock: () => DateTime(2026, 10, 31, 12))),
          size: const Size(400, 1600));
      expect(key('overSentence'), findsNothing);
    });

    testWidgets('Plan ledger: a negative total reads "Over by", not a minus', (t) async {
      final wc = wallet(salary: 100000);
      wc.repo.updateSettings({'rent': 90000, 'loan': 30000});
      wc.reload();
      expect(wc.period().flexBudget < 0, isTrue);
      await pumpApp(t, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 4000));
      final row = find.descendant(of: key('ledgerSpendingMoney'), matching: find.byType(Text));
      final texts = t.widgetList<Text>(row).map((w) => w.data ?? '').join(' ');
      expect(texts, contains('Over by'));
      expect(texts.contains('-'), isFalse);
    });
  });

  group('IUbb Plan ledger', () {
    double valueOf(String text) => double.parse(text.replaceAll('\u2212', '-').replaceAll(RegExp(r'[^0-9.\-]'), ''));

    testWidgets('the rows add up to the total to the cent, the set-aside row included', (t) async {
      final wc = wallet(salary: 100000);
      wc.repo.updateSettings({'rent': 1050, 'loan': 2050});
      wc.addPlannedCost(title: 'Dentist', date: '2026-10-25', amount: 3333);
      wc.reload();
      await pumpApp(t, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 4000));
      expect(key('ledgerSetAside'), findsOneWidget, reason: 'precondition: a coming cost is set aside');
      String value(Finder row) =>
          t.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).map((w) => w.data ?? '').toList().last;
      final items = find.descendant(of: key('planLines'), matching: find.byType(RuledRow));
      final n = items.evaluate().length;
      var sum = 0.0;
      for (var i = 0; i < n - 1; i++) {
        // the last row is the total itself
        final texts = t.widgetList<Text>(find.descendant(of: items.at(i), matching: find.byType(Text))).map((w) => w.data ?? '').toList();
        // title, optional sub-line and chip, amount last
        sum += valueOf(texts.last);
      }
      final total = valueOf(value(key('ledgerSpendingMoney')));
      expect(sum.toStringAsFixed(2), total.toStringAsFixed(2), reason: 'the ledger rows sum to the spending money');
      expect(total, wc.period().flexBudget / 100);
      expect(find.textContaining('10.50'), findsWidgets, reason: 'cents shown, not rounded');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a few cents of spending money: the heading never shows a negative', (t) async {
      final wc = wallet(salary: 100000);
      wc.repo.updateSettings({'rent': 99990});
      wc.reload();
      final p = wc.period();
      expect(p.flexBudget > 0 && p.planDaily == 0, isTrue, reason: 'precondition: ${p.flexBudget} cents, ${p.planDaily}/day');
      await pumpApp(t, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 4000));
      final row = find.descendant(of: key('ledgerSpendingMoney'), matching: find.byType(Text));
      final h = t.widgetList<Text>(row).map((w) => w.data ?? '').join(' ');
      expect(h, contains('0.10'));
      expect(h, isNot(contains('Over')));
      expect(h.contains('-') || h.contains('\u2212'), isFalse);
      expect(t.widget<StateChip>(key('planHeading')).text, 'On plan');
      expect(find.descendant(of: key('planPerDay'), matching: find.text(moneyExact(0, 'EUR'))), findsOneWidget);
    });
  });

  group('IUbb Review delete', () {
    testWidgets('deleting from Review says so, with Undo', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-19', amount: 1234, category: 'Old category'); // not one of the wallet's categories
      wc.reload();
      expect(wc.reviewRows(), hasLength(1));
      await pumpApp(t, ReviewScreen(wc: wc), size: const Size(400, 1600));
      await t.tap(find.widgetWithText(TextButton, 'Change'));
      await t.pumpAndSettle();
      await t.tap(key('txDelete'));
      await t.pumpAndSettle();
      expect(find.text('Deleted'), findsOneWidget);
      expect(key('toastUndo'), findsOneWidget);
      await t.tap(key('toastUndo'));
      await t.pump();
      expect(wc.txs, hasLength(1), reason: 'Undo brought it back');
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('IUbb confirmed bill row', () {
    testWidgets('at 320 dp and text scale 2 the Skip button keeps a readable width (the amount no longer squeezes it)', (t) async {
      final wc = habitsWallet(confirmBill: true);
      await pumpFull(t, wc, 2.0);
      await tapTab(t, 'Bills');
      final skip = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('skip:'));
      await t.dragUntilVisible(skip, find.byType(Scrollable).first, const Offset(0, -300));
      expect(t.getSize(skip).width, greaterThan(120), reason: 'the label "Skip this cycle" must not wrap letter by letter');
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(minutes: 6));
    });
  });

  group('I1 setup panel', () {
    testWidgets('the open steps are one panel; hide leaves one line that opens it again', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      expect(wc.keyBackupRowVisible, isTrue);
      await pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {})),
          size: const Size(400, 1600));
      expect(key('setupPanel'), findsOneWidget);
      expect(key('keyBackupRow'), findsOneWidget, reason: 'the key step is inside it');
      expect(find.textContaining('Planning on'), findsOneWidget, reason: 'the salary step too');
      await t.tap(key('setupHide'));
      await t.pump();
      await pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {})),
          size: const Size(400, 1600));
      expect(key('setupPanel'), findsNothing);
      expect(key('setupLine'), findsOneWidget);
      await t.tap(key('setupLine'));
      await t.pump();
      await pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {})),
          size: const Size(400, 1600));
      expect(key('setupPanel'), findsOneWidget);
    });

    testWidgets('a different set of open steps shows the panel open again', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      Future<void> rebuild(WidgetTester t) =>
          pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), view: TodayView(wc), openPlan: () {})),
              size: const Size(400, 1600));
      await rebuild(t);
      await t.tap(key('setupHide'));
      await t.pump();
      await rebuild(t);
      expect(key('setupLine'), findsOneWidget);
      wc.updateSettings({'salaryConfirmed': true}); // one step done: the set changed
      await rebuild(t);
      expect(key('setupPanel'), findsOneWidget, reason: 'open again for the changed set');
      expect(key('setupLine'), findsNothing);
      expect(wc.setupCollapsedFor(['key']), isFalse);
      wc.setSetupCollapsed(true, ['key']);
      expect(wc.setupCollapsedFor(['key']), isTrue);
      expect(wc.setupCollapsedFor(['key', 'payday']), isFalse, reason: 'a new step opens it again');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('no open step: no panel and no line', (t) async {
      final wc = wallet();
      await pumpApp(t, today(wc), size: const Size(400, 1600));
      expect(key('setupPanel'), findsNothing);
      expect(key('setupLine'), findsNothing);
    });
  });

  group('I2 / I5 add expense', () {
    Future<void> openFlow(WidgetTester t, WalletController wc) async {
      await pumpApp(
          t, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => addExpenseFlow(c, wc), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
    }

    Future<void> pick(WidgetTester t, String name) async {
      final f = find.widgetWithText(ChoiceChip, name);
      await t.ensureVisible(f);
      await t.pumpAndSettle();
      await t.tap(f);
      await t.pump();
    }

    testWidgets('no category used yet: the button waits for one; then it is remembered', (t) async {
      final wc = wallet();
      await openFlow(t, wc);
      await t.enterText(find.byType(TextField).first, '5');
      await t.pump();
      expect(t.widget<FilledButton>(key('addExpenseSave')).onPressed, isNull);
      await pick(t, 'Eating out');
      expect(t.widget<FilledButton>(key('addExpenseSave')).onPressed, isNotNull);
      await t.ensureVisible(key('addExpenseSave'));
      await t.pumpAndSettle();
      await t.tap(key('addExpenseSave'));
      await t.pump(const Duration(milliseconds: 500));
      expect(wc.lastExpenseCategory, 'Eating out');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('the sheet has a close button and the toast clears when it opens', (t) async {
      final wc = wallet();
      await openFlow(t, wc);
      expect(key('sheetClose'), findsOneWidget);
      await t.tap(key('sheetClose'));
      await t.pumpAndSettle();
      expect(key('addExpenseSave'), findsNothing);
    });

    testWidgets('a wish takes its note as name; without a note it asks, and Open goes to the Wishlist', (t) async {
      final wc = wallet();
      int? opened;
      wc.tabHook = (i, via) => opened = i;
      await openFlow(t, wc);
      await t.enterText(find.byType(TextField).first, '900');
      await pick(t, 'Shopping');
      await t.ensureVisible(key('addExpenseSave'));
      await t.pumpAndSettle();
      await t.ensureVisible(key('addExpenseSave'));
      await t.pumpAndSettle();
      await t.tap(key('addExpenseSave'));
      await t.pumpAndSettle();
      expect(key('wishName'), findsOneWidget);
      expect(t.widget<OutlinedButton>(key('putOnWishlist')).onPressed, isNull, reason: 'no name yet');
      await t.enterText(key('wishName'), 'Synthetic shoes');
      await t.pump();
      await t.ensureVisible(key('putOnWishlist'));
      await t.pumpAndSettle();
      await t.tap(key('putOnWishlist'));
      await t.pump(const Duration(milliseconds: 500));
      expect(wc.wish.single.name, 'Synthetic shoes');
      expect(key('toastAction'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(key('toastAction'));
      await t.pump();
      expect(opened, Tabs.plan);
      expect(wc.highlightWish.value, wc.wish.single.id);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('the Wishlist tints and shows the wish the toast pointed at', (t) async {
      final wc = wallet();
      final id = wc.addWish('Synthetic lamp', 8000);
      wc.highlightWish.value = id;
      await pumpApp(t, Scaffold(body: WishlistScreen(wc: wc)), size: const Size(400, 1600));
      await t.pump();
      expect(key('wishHighlight'), findsOneWidget);
      expect(wc.highlightWish.value, isNull);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('I4 toasts', () {
    Future<void> host(WidgetTester t, void Function(BuildContext) run) async {
      await pumpApp(t, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => run(c), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pump();
    }

    testWidgets('a toast lasts 2.5 seconds, also with an action', (t) async {
      await host(t, (c) => toast(c, 'Hello there', actionLabel: 'Undo', onAction: () {}));
      expect(find.text('Hello there'), findsOneWidget);
      Future<void> run(int ms) async {
        for (var i = 0; i < ms ~/ 100; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await run(2000);
      expect(find.text('Hello there'), findsOneWidget);
      await run(1500);
      expect(find.text('Hello there'), findsNothing);
    });

    testWidgets('Undo brings a deleted expense back', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-19', amount: 1234, category: 'Groceries');
      wc.reload();
      final tx = wc.txs.single.tx;
      wc.deleteTransaction(tx);
      expect(wc.txs, isEmpty);
      await host(t, (c) => txSheetToast(c, wc, 'deleted'));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(key('toastUndo'));
      await t.pump();
      expect(wc.txs.map((x) => x.tx.id), [tx.id]);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Undo brings a deleted goal back', (t) async {
      final wc = wallet();
      final id = wc.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 0, monthly: 1000);
      wc.reload();
      wc.deleteGoal(id);
      expect(wc.goals, isEmpty);
      await host(t, (c) => goalSheetToast(c, wc, 'deleted'));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(key('toastUndo'));
      await t.pump();
      expect(wc.goals.map((g) => g.id), [id]);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a toast is cleared when a sheet opens', (t) async {
      final wc = wallet();
      await host(t, (c) {
        toast(c, 'Old message');
        addExpenseFlow(c, wc);
      });
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Old message'), findsNothing);
    });
  });

  group('I8 honest states', () {
    testWidgets('the backup says which bill files go into it', (t) async {
      final wc = wallet();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc))), size: const Size(400, 1200));
      expect(find.textContaining('Files only on your relay do not'), findsOneWidget);
      expect(find.textContaining('up to ${backupBlobBytesDefault >> 20} MB'), findsOneWidget);
      expect(find.textContaining('up to 16 MB'), findsOneWidget, reason: 'the cap comes from core');
      expect(key('backupNoFiles'), findsOneWidget);
    });

    testWidgets('Sync shows relay usage when known, nothing when not', (t) async {
      final wc = wallet();
      wc.seams.syncRunner =
          (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true, relayBytes: 3 * 1048576, relayMaxBytes: 50 * 1048576);
      await t.runAsync(() => wc.setRelay(Uri.parse('http://homeserver.local:8787')));
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: const Size(400, 1400));
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(textOf(t, 'relayUsage'), '3 MB of 50 MB used on the relay');
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(key('relayUsage'), findsNothing, reason: 'an older relay: hidden');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a toast with an action stays for a screen reader, one without times out', (t) async {
      Future<void> run(int ms) async {
        for (var i = 0; i < ms ~/ 100; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> hostA11y(void Function(BuildContext) go, {required bool reader}) async {
        t.view.physicalSize = const Size(400, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(400, 900), accessibleNavigation: reader),
            child: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => go(c), child: const Text('go')))),
          ),
        ));
        await t.tap(find.text('go'));
        await t.pump();
      }

      await hostA11y((c) => toast(c, 'Kept', actionLabel: 'Undo', onAction: () {}), reader: true);
      await run(6000);
      expect(find.text('Kept'), findsOneWidget, reason: 'screen reader on: the action toast stays');
      await hostA11y((c) => toast(c, 'Plain'), reader: true);
      await run(4000);
      expect(find.text('Plain'), findsNothing, reason: 'no action: it times out even with a screen reader');
      await hostA11y((c) => toast(c, 'Gone', actionLabel: 'Undo', onAction: () {}), reader: false);
      await run(4000);
      expect(find.text('Gone'), findsNothing, reason: 'no screen reader: it times out');
    });

    group('write failures', () {
      late void Function(FlutterErrorDetails)? prevOnError;
      setUp(() => prevOnError = FlutterError.onError);
      tearDown(() => FlutterError.onError = prevOnError);

      test('only a database error out of a write is a "Couldn\'t save"', () {
        final before = writeFailedNotice.value;
        final e = SqliteException(extendedResultCode: 1, message: 'x');
        expect(noticeWriteFailed(StateError('x'), StackTrace.current), isFalse);
        expect(noticeWriteFailed(e, null), isFalse);
        expect(noticeWriteFailed(e, StackTrace.current), isFalse, reason: 'a read or a build-time error: not from a write');
        expect(writeFailedNotice.value, before);
      });

      testWidgets('a write the database refuses shows a dialog over the open Add expense sheet; a failed read does not', (t) async {
        await t.runAsync(AppLog.init);
        final wc = wallet();
        // The outbox insert of every write fails: a real SqliteException out of a real repo write.
        wc.repo.db.execute("CREATE TEMP TRIGGER bw_fail BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'disk full'); END");
        await pumpFull(t, wc, 1, size: const Size(400, 900));
        await t.ensureVisible(key('addExpense'));
        await t.pumpAndSettle();
        await t.tap(key('addExpense'));
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField).first, '5');
        await t.pump();
        final chip = find.widgetWithText(ChoiceChip, 'Groceries');
        await t.ensureVisible(chip);
        await t.pumpAndSettle();
        await t.tap(chip);
        await t.pump();
        await t.ensureVisible(key('addExpenseSave'));
        await t.pumpAndSettle();
        await t.tap(key('addExpenseSave'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(t.takeException(), isA<SqliteException>());
        expect(key('writeFailedDialog'), findsOneWidget, reason: 'on the top route, not under the sheet');
        expect(find.text(writeFailedText), findsOneWidget);
        expect(wc.txs, isEmpty, reason: 'nothing was written');
        await t.tap(key('writeFailedOk'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(key('writeFailedDialog'), findsNothing);

        // A database error that did not come out of a write is logged as a crash, not shown as "Couldn't save".
        FlutterError.onError!(
            FlutterErrorDetails(exception: SqliteException(extendedResultCode: 1, message: 'read failed'), stack: StackTrace.current));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(t.takeException(), isA<SqliteException>());
        expect(key('writeFailedDialog'), findsNothing);
      });

      test('a saved expense is never followed by a failure of the remembered category', () {
        final wc = wallet();
        wc.addExpense(amount: 500, category: 'Groceries', note: '', date: '2026-10-20');
        expect(wc.txs, hasLength(1));
        expect(wc.lastExpenseCategory, 'Groceries');
      });
    });

    testWidgets('a bank row that replaced a hand-added expense shows the mark', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-18', amount: 2340, category: 'Eating out', note: 'lunch');
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-18', -2340, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE')]));
      wc.reload();
      final bank = wc.txs.firstWhere((x) => !x.tx.manual);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: bank))), size: const Size(400, 1200));
      expect(key('matchedMark'), findsOneWidget);
      expect(find.textContaining('Matched with your bank'), findsOneWidget);
    });

    testWidgets('the list row of that bank row shows "Matched"; an unmatched bank row and a plain entry do not', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-18', amount: 2340, category: 'Eating out', note: 'lunch');
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-18', -2340, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE'),
        syntheticTx('2026-10-19', -990, 'POS plaćanje', 'PBZ POS SYNTHETIC KIOSK'),
      ]));
      wc.reload();
      final matched = wc.txs.firstWhere((x) => !x.tx.manual && x.tx.amount == -2340);
      final other = wc.txs.firstWhere((x) => !x.tx.manual && x.tx.amount == -990);
      expect(wc.isMatchedBank(matched.tx.id), isTrue);
      expect(wc.isMatchedBank(other.tx.id), isFalse);
      Future<void> tile(CategorizedTx row, bool on) =>
          pumpApp(t, Scaffold(body: TxTile(t: row, currency: 'EUR', matched: on)), size: const Size(400, 300));
      await tile(matched, wc.isMatchedBank(matched.tx.id));
      expect(key('rowMatched'), findsOneWidget);
      expect(find.text('Matched'), findsOneWidget);
      await tile(other, wc.isMatchedBank(other.tx.id));
      expect(key('rowMatched'), findsNothing);
    });

    test('deleting the bank row reopens the entry: nothing is matched any more', () {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-18', amount: 2340, category: 'Eating out', note: 'lunch');
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-18', -2340, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE')]));
      wc.reload();
      final bank = wc.txs.firstWhere((x) => !x.tx.manual);
      expect(wc.isMatchedBank(bank.tx.id), isTrue);
      wc.deleteTransaction(bank.tx);
      expect(wc.isMatchedBank(bank.tx.id), isFalse);
    });

    testWidgets('a plain expense has no mark', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-18', amount: 2340, category: 'Eating out', note: 'lunch');
      wc.reload();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: wc.txs.single))), size: const Size(400, 1200));
      expect(key('matchedMark'), findsNothing);
    });
  });
}
