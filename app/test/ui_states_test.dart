// Stage I (IUb): honest states and flows. Over-today and over-plan sentences on Today, one setup panel, wish naming,
// toasts (2.5 s, Undo, Open), form defaults, backup and relay texts. All data SYNTHETIC; fixed clocks (20 Oct 2026).
import 'package:budget_wallet/src/clock_notice.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;

import 'support/wallet.dart';

Finder key(String k) => find.byKey(ValueKey(k));

/// A wallet on 20 Oct 2026 with the key confirmed (no setup panel), salary confirmed, plan from 1 Oct.
WalletController wallet({DateTime? now, int salary = 150000}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => now ?? budgetToday);
  wc.repo.updateSettings({'salary': salary, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
  wc.repo.setLocalValue('keyBackupConfirmed', '1');
  wc.reload();
  addTearDown(wc.dispose);
  return wc;
}

Widget today(WalletController wc) =>
    Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {}, clock: () => budgetToday));

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
      expect(s, contains('over for today'));
      expect(s, contains('Nothing more today; tomorrow starts at'));
      expect(find.textContaining('-'), findsNothing, reason: 'no minus sign on Today');
      expect(find.textContaining('OVER TODAY BY'), findsOneWidget);
    });

    testWidgets('over the period: says over the plan, once', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-20', amount: 400000, category: 'Shopping');
      wc.reload();
      expect(wc.period().overBy > 0, isTrue);
      await pumpApp(t, today(wc), size: const Size(400, 1600));
      expect(find.descendant(of: key('overSentence'), matching: find.textContaining('over the plan for this period.', findRichText: true)),
          findsOneWidget);
      expect(find.textContaining('over the plan', findRichText: true), findsWidgets);
      expect(find.textContaining('for this period', findRichText: true), findsOneWidget, reason: 'said once');
    });

    testWidgets('last day: no tomorrow figure (everything left is today\'s)', (t) async {
      final wc = wallet(now: DateTime(2026, 10, 31, 12));
      expect(wc.period().allowanceTomorrow, isNull);
      await pumpApp(
          t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {}, clock: () => DateTime(2026, 10, 31, 12))),
          size: const Size(400, 1600));
      expect(key('overSentence'), findsNothing);
    });

    testWidgets('Plan ledger: a negative total reads "Over by", not a minus', (t) async {
      final wc = wallet(salary: 100000);
      wc.repo.updateSettings({'rent': 90000, 'loan': 30000});
      wc.reload();
      expect(wc.period().flexBudget < 0, isTrue);
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 4000));
      final row = find.descendant(of: key('ledgerSpendingMoney'), matching: find.byType(Text));
      final texts = t.widgetList<Text>(row).map((w) => w.data ?? '').join(' ');
      expect(texts, contains('Over by'));
      expect(texts.contains('-'), isFalse);
    });
  });

  group('I1 setup panel', () {
    testWidgets('the open steps are one panel; hide leaves one line that opens it again', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      expect(wc.keyBackupRowVisible, isTrue);
      await pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {})), size: const Size(400, 1600));
      expect(key('setupPanel'), findsOneWidget);
      expect(key('keyBackupRow'), findsOneWidget, reason: 'the key step is inside it');
      expect(find.textContaining('Planning on'), findsOneWidget, reason: 'the salary step too');
      await t.tap(key('setupHide'));
      await t.pump();
      await pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {})), size: const Size(400, 1600));
      expect(key('setupPanel'), findsNothing);
      expect(key('setupLine'), findsOneWidget);
      await t.tap(key('setupLine'));
      await t.pump();
      await pumpApp(t, Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {})), size: const Size(400, 1600));
      expect(key('setupPanel'), findsOneWidget);
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
      expect(opened, 2);
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
    testWidgets('the backup says bill files are not in it', (t) async {
      final wc = wallet();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc))), size: const Size(400, 1200));
      expect(find.textContaining('not in the backup; they stay on your relay'), findsOneWidget);
      expect(key('backupNoFiles'), findsOneWidget);
    });

    testWidgets('Sync shows relay usage when known, nothing when not', (t) async {
      final wc = wallet();
      wc.syncRunner =
          (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true, relayBytes: 3 * 1048576, relayMaxBytes: 50 * 1048576);
      await t.runAsync(() => wc.setRelay(Uri.parse('http://homeserver.local:8787')));
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: const Size(400, 1400));
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(textOf(t, 'relayUsage'), '3 MB of 50 MB used on the relay');
      wc.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(key('relayUsage'), findsNothing, reason: 'an older relay: hidden');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a failed database write shows a toast', (t) async {
      final wc = wallet();
      await pumpApp(
          t, Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => toast(c, writeFailedText), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pump();
      expect(find.text("Couldn't save. Nothing was changed."), findsOneWidget);
      expect(wc.txs, isEmpty);
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

    testWidgets('a plain expense has no mark', (t) async {
      final wc = wallet();
      wc.repo.addTransaction(date: '2026-10-18', amount: 2340, category: 'Eating out', note: 'lunch');
      wc.reload();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: wc.txs.single))), size: const Size(400, 1200));
      expect(key('matchedMark'), findsNothing);
    });
  });
}
