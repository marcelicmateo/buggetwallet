// AF (app review findings): the auto-Paid toast is acknowledged only once seen, Reopen for a paid planned cost, the Upcoming rows vs
// "Set aside" (long bill in a fixed category, "Not set aside yet", the next period), the Unlink toast when core rematches, and the alias
// Undo / picker. SYNTHETIC data only.
import 'dart:async';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/planned_sheets.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/screens/upcoming.dart';
import 'package:budget_wallet/src/screens/upcoming_view.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;

import 'support/bills.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Finder key(String k) => find.byKey(ValueKey(k));

void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce
    }, timeout: const Timeout(Duration(seconds: 60)));

/// Pumps [ms] milliseconds in 100 ms frames (an animation and a timer need frames, one long pump runs neither).
Future<void> run(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// 20 Oct 2026, payday on the 1st: period 1 Oct .. 1 Nov.
WalletController wallet({DateTime? at, String periodStart = '2026-10-01'}) {
  final wc = seamedController(WalletRepo.inMemory(now: () => (at ?? budgetToday).millisecondsSinceEpoch),
      key: VaultKey.generate(), clock: () => at ?? budgetToday, billInputs: FakeBillInputs().inputs);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': periodStart, 'paydayDay': 1});
  wc.snoozeKeyBackup();
  addTearDown(wc.dispose);
  return wc;
}

ImportBatch lidl(String date, int cents) =>
    ImportBatch(source: 'pbz', transactions: [syntheticTx(date, cents, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB')]);

void main() {
  group('auto-Paid toast is acknowledged only when seen', () {
    Future<(WalletController, String)> app(WidgetTester tester) async {
      final wc = wallet();
      final id = wc.repo.addPlanned(title: 'Synthetic groceries', date: '2026-10-18', amount: 4500, category: 'Groceries');
      wc.reload();
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BudgetWalletApp(wc: wc));
      await tester.pump();
      return (wc, id);
    }

    void closeCost(WalletController wc) {
      wc.repo.importBatch(lidl('2026-10-19', -4500));
      wc.reload();
    }

    final shown = find.descendant(of: find.byType(SnackBar), matching: find.text('Marked paid: Synthetic groceries'));

    tw('a sheet on top: no toast, the cost stays pending; it shows when the page is on top, then it is acknowledged', (tester) async {
      final (wc, _) = await app(tester);
      final ctx = tester.element(find.byType(Scaffold).first);
      unawaited(showDialog<void>(context: ctx, builder: (_) => const AlertDialog(content: Text('modal'))));
      await run(tester, 400);
      closeCost(wc);
      await run(tester, 4000);
      expect(find.byType(SnackBar), findsNothing);
      expect(wc.repo.autoPaidPlanned(), hasLength(1), reason: 'nobody saw it yet');
      Navigator.of(tester.element(find.text('modal'))).pop();
      await run(tester, 600);
      expect(shown, findsOneWidget);
      expect(wc.repo.autoPaidPlanned(), hasLength(1), reason: 'still on screen: not acknowledged yet');
      await run(tester, 4000);
      expect(find.byType(SnackBar), findsNothing);
      expect(wc.repo.autoPaidPlanned(), isEmpty, reason: 'timed out: seen');
    });

    tw('a toast with an action is not replaced: the auto-Paid toast waits for it', (tester) async {
      final (wc, _) = await app(tester);
      final ctx = tester.element(find.byType(Scaffold).first);
      toast(ctx, 'Imported 3 payments', actionLabel: 'Undo', onAction: () {});
      await run(tester, 400);
      closeCost(wc);
      await run(tester, 800);
      expect(find.text('Imported 3 payments'), findsOneWidget, reason: 'the Undo toast stays');
      expect(shown, findsNothing);
      expect(wc.repo.autoPaidPlanned(), hasLength(1));
      await run(tester, 3000);
      expect(shown, findsOneWidget, reason: 'after the Undo toast closed');
      await run(tester, 4000);
      expect(wc.repo.autoPaidPlanned(), isEmpty);
    });

    tw('replaced by another toast before it timed out: not acknowledged, it comes back', (tester) async {
      final (wc, _) = await app(tester);
      closeCost(wc);
      await run(tester, 800);
      expect(shown, findsOneWidget);
      toast(tester.element(find.byType(Scaffold).first), 'Saved');
      await run(tester, 400);
      expect(find.text('Saved'), findsOneWidget);
      expect(wc.repo.autoPaidPlanned(), hasLength(1), reason: 'hidden is not seen');
      await run(tester, 4500);
      expect(shown, findsOneWidget, reason: 'back after the other toast went');
      await run(tester, 4000);
      expect(wc.repo.autoPaidPlanned(), isEmpty);
    });

    tw('its Undo reopens the cost and acknowledges', (tester) async {
      final (wc, id) = await app(tester);
      closeCost(wc);
      await run(tester, 800);
      await tester.tap(key('toastUndo'));
      await run(tester, 400);
      expect(wc.plannedOpen().map((p) => p.id), [id]);
      expect(wc.repo.autoPaidPlanned(), isEmpty);
    });
  });

  group('Reopen a paid planned cost', () {
    PlannedCost paid(WalletController wc, {bool skip = false}) {
      final id = wc.repo.addPlanned(title: 'Synthetic dentist', date: '2026-10-18', amount: 8000, category: 'Health');
      wc.reload();
      final p = wc.plannedOpen().singleWhere((x) => x.id == id);
      if (skip) {
        wc.skipPlanned(p);
      } else {
        wc.repo.markPlannedPaid(id, 'tx-none');
        wc.reload();
      }
      return wc.plannedEverything().singleWhere((x) => x.id == id);
    }

    Future<void> openEntry(WidgetTester tester, WalletController wc, PlannedCost p) async {
      await pumpApp(
          tester,
          Scaffold(
              body: Builder(
                  builder: (c) =>
                      TextButton(onPressed: () => showSheet<String>(c, PlannedEntrySheet(wc: wc, planned: p)), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await run(tester, 600);
    }

    tw('an open cost has Paid and Skip, no Reopen; a paid one has Reopen, no Paid or Skip, and Reopen opens it again', (tester) async {
      final wc = wallet();
      final id = wc.repo.addPlanned(title: 'Synthetic gift', date: '2026-10-24', amount: 4000, category: 'Shopping');
      wc.reload();
      await openEntry(tester, wc, wc.plannedOpen().single);
      expect(key('entryPaid'), findsOneWidget);
      expect(key('entrySkip'), findsOneWidget);
      expect(key('entryReopen'), findsNothing);
      Navigator.of(tester.element(key('entryPaid'))).pop();
      await run(tester, 400);

      final p = paid(wc);
      expect(p.status, PlannedStatus.paid);
      await openEntry(tester, wc, p);
      expect(key('entryReopen'), findsOneWidget);
      expect(key('entryPaid'), findsNothing);
      expect(key('entrySkip'), findsNothing);
      await tester.tap(key('entryReopen'));
      await run(tester, 600);
      expect(wc.plannedOpen().map((x) => x.id), contains(p.id));
      expect(wc.plannedOpen().map((x) => x.id), contains(id));
    });

    tw('search finds a paid planned cost and its row opens the sheet with Reopen', (tester) async {
      final wc = wallet();
      final p = paid(wc);
      await pumpApp(tester, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})));
      await tester.enterText(key('searchField'), 'dentist');
      await run(tester, 600);
      await tester.tap(find.text('Synthetic dentist').first);
      await run(tester, 600);
      expect(key('entryReopen'), findsOneWidget);
      await tester.tap(key('entryReopen'));
      await run(tester, 800);
      expect(wc.plannedOpen().map((x) => x.id), [p.id]);
      expect(find.text('Open again'), findsOneWidget);
    });

    tw('a skipped cost can be reopened too', (tester) async {
      final wc = wallet();
      final p = paid(wc, skip: true);
      await openEntry(tester, wc, p);
      await tester.tap(key('entryReopen'));
      await run(tester, 600);
      expect(wc.plannedOpen().map((x) => x.id), [p.id]);
    });
  });

  group('Upcoming rows and Set aside', () {
    String rowIdOf(WalletController wc, String label) =>
        wc.upcomingItems(wc.upcomingRange().start, wc.upcomingRange().end).firstWhere((i) => i.title == label).key;

    tw('a long bill in a fixed category is not "covered by your plan" and is counted', (tester) async {
      final wc = wallet();
      wc.repo.addRecurring(
          label: 'Synth insurance',
          category: 'Bills & subscriptions',
          amount: 90000,
          intervalDays: 365,
          firstDue: '2026-10-25',
          payee: 'synth_ins');
      wc.repo.addRecurring(
          label: 'Synth phone',
          category: 'Bills & subscriptions',
          amount: 2000,
          intervalDays: 30,
          firstDue: '2026-10-26',
          payee: 'synth_ph');
      wc.reload();
      final r = wc.upcomingRange();
      final items = wc.upcomingItems(r.start, r.end);
      expect(wc.setAside(items), (count: 1, total: 90000), reason: 'the long bill is set aside, the monthly one is in the plan');
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 2400));
      final long = find.descendant(of: key('up:${rowIdOf(wc, 'Synth insurance')}'), matching: find.text('covered by your plan'));
      final monthly = find.descendant(of: key('up:${rowIdOf(wc, 'Synth phone')}'), matching: find.text('covered by your plan'));
      expect(long, findsNothing);
      expect(monthly, findsOneWidget);
    });

    tw('the second occurrence of a monthly bill, and a cycle behind an overdue one, say "Not set aside yet"', (tester) async {
      final wc = wallet();
      // 27 days: due 2 Oct and 29 Oct are both in the period; core reserves the 2 Oct cycle (overdue) only.
      wc.repo.addRecurring(
          label: 'Synth twice', category: 'Shopping', amount: 3000, intervalDays: 27, firstDue: '2026-10-02', payee: 'synth_t');
      // Overdue since September: the cycle in the Overdue panel is the one reserved; the 10 Oct occurrence is not.
      wc.repo
          .addRecurring(label: 'Synth old', category: 'Shopping', amount: 1700, intervalDays: 30, firstDue: '2026-09-10', payee: 'synth_o');
      wc.repo.addRecurring(
          label: 'Synth once', category: 'Shopping', amount: 2200, intervalDays: 30, firstDue: '2026-10-28', payee: 'synth_s');
      wc.reload();
      final r = wc.upcomingRange();
      final items = wc.upcomingItems(r.start, r.end);
      String k(String title, String date) => items.firstWhere((i) => i.title == title && i.date == date).key;
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 2400));
      expect(key('notSetAside:${k('Synth twice', '2026-10-29')}'), findsOneWidget);
      expect(key('notSetAside:${k('Synth twice', '2026-10-02')}'), findsNothing);
      expect(key('notSetAside:${k('Synth old', '2026-10-10')}'), findsOneWidget);
      expect(key('overdue:${k('Synth old', '2026-10-10')}'), findsNothing, reason: 'overdue only where core really holds the cycle');
      expect(key('notSetAside:${k('Synth once', '2026-10-28')}'), findsNothing);
      expect(key('overdue:${k('Synth twice', '2026-10-02')}'), findsOneWidget);
      // The total is core's: only three cycles (the two reserved ones and the later one).
      expect(wc.setAside(items), (count: 3, total: 3000 + 1700 + 2200));
      expect(wc.setAside(items).total, wc.period().beforePayday);
    });

    test('the next period set aside is what Before payday holds when that period starts', () {
      void bills(WalletController wc, {required String monthlyDue}) {
        wc.repo.addRecurring(
            label: 'Synth monthly', category: 'Shopping', amount: 3000, intervalDays: 30, firstDue: monthlyDue, payee: 'synth_a');
        wc.repo.addRecurring(
            label: 'Synth early', category: 'Shopping', amount: 2500, intervalDays: 30, firstDue: '2026-11-02', payee: 'synth_b');
        wc.repo.addRecurring(
            label: 'Synth long', category: 'Shopping', amount: 120000, intervalDays: 365, firstDue: '2027-03-01', payee: 'synth_l');
        wc.repo.addRecurring(
            label: 'Synth fixed',
            category: 'Bills & subscriptions',
            amount: 900,
            intervalDays: 30,
            firstDue: '2026-11-05',
            payee: 'synth_f');
        wc.repo.addPlanned(title: 'Synthetic gift', date: '2026-11-10', amount: 4000, category: 'Shopping');
        wc.reload();
      }

      final now = wallet();
      bills(now, monthlyDue: '2026-10-28');
      final next = now.upcomingRange(next: true);
      expect(next.start, '2026-11-01');
      expect(next.end, '2026-11-30');
      final nextItems = now.upcomingItems(next.start, next.end);
      final counted = now.setAside(nextItems, next: true);
      // Every bill of this period paid in time: the same wallet on 1 Nov with the monthly bill's next cycle on 27 Nov.
      final later = wallet(at: DateTime(2026, 11, 1, 12), periodStart: '2026-11-01');
      bills(later, monthlyDue: '2026-11-27');
      final p = later.period();
      expect(counted, (count: p.beforePaydayCount, total: p.beforePayday));
      expect(counted.total, 3000 + 2500 + 120000 + 4000, reason: 'one cycle each, the long bill held, the fixed one in the plan');
      // The rows: the long bill sits in the held list, the monthly bill's occurrence is a reserved cycle, no row is flagged.
      expect(UpcomingView(now).heldCycles(next: true).map((c) => c.bill.label), ['Synth long']);
      for (final i in nextItems.where((i) => i.kind == UpcomingKind.bill && i.title != 'Synth fixed')) {
        expect(now.billNotSetAside(i, next: true), isFalse, reason: i.title);
      }
    });

    tw('the next period page shows the held long bill and the same total', (tester) async {
      final wc = wallet();
      wc.repo.addRecurring(
          label: 'Synth long', category: 'Shopping', amount: 120000, intervalDays: 365, firstDue: '2027-03-01', payee: 'synth_l');
      wc.repo.addRecurring(
          label: 'Synth early', category: 'Shopping', amount: 2500, intervalDays: 30, firstDue: '2026-11-02', payee: 'synth_b');
      wc.reload();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 2400));
      await tester.tap(key('periodNext'));
      await run(tester, 400);
      expect(find.text('2 costs'), findsOneWidget);
      expect(find.text(moneyExact(122500, 'EUR')), findsWidgets);
      expect(key('upcomingHeld'), findsOneWidget);
    });
  });

  group('Unlink toast', () {
    WalletController twoBankRows() {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
      wc.repo.setLocalValue('keyBackupConfirmed', '1');
      wc.repo.addTransaction(date: '2026-10-20', amount: 2340, category: 'Eating out', note: 'lunch');
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-20', -2340, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE'),
        syntheticTx('2026-10-20', -2340, 'POS plaćanje', 'PBZ POS SYNTHETIC DINER'),
      ]));
      wc.reload();
      addTearDown(wc.dispose);
      return wc;
    }

    test('core rematches at once: the controller says so; with no other bank row it does not', () {
      final wc = twoBankRows();
      final matched = wc.repo.matchedBankIds().single;
      final entry = wc.repo.transactions(includeHidden: true).firstWhere((x) => x.manual && !x.deleted);
      expect(wc.unlinkCashMatch(entry.id, matched), isNull);
      expect(wc.lastUnlinkedRematched, isTrue);
      expect(wc.repo.matchedBankIds().single, isNot(matched));
      expect(wc.unlinkCashMatch(entry.id, wc.repo.matchedBankIds().single), isNull);
    });

    tw('the toast says the entry now matches another bank payment, still with Undo', (tester) async {
      final wc = twoBankRows();
      final matched = wc.repo.matchedBankIds().single;
      final row = wc.txs.firstWhere((x) => x.tx.id == matched);
      await pumpApp(
          tester,
          Scaffold(
              body: Builder(
                  builder: (c) => TextButton(
                      onPressed: () async {
                        final r = await showSheet<String>(c, TxSheet(wc: wc, t: row));
                        if (c.mounted) txSheetToast(c, wc, r);
                      },
                      child: const Text('go')))));
      await tester.tap(find.text('go'));
      await run(tester, 600);
      await tester.tap(key('unlinkMatch'));
      await run(tester, 800);
      expect(find.text(unlinkedRematchedText), findsOneWidget);
      expect(find.text('Unlinked: the cash entry counts again'), findsNothing);
      expect(key('toastUndo'), findsOneWidget);
    });
  });

  group('payee alias Undo and picker', () {
    WalletController withGym() {
      final wc = wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) syntheticTx(d, -2999, 'POS plaćanje', 'POS SYNTHGYM ZAGREB'),
        for (final d in const ['2026-07-12', '2026-08-12', '2026-09-12']) syntheticTx(d, -1500, 'POS plaćanje', 'POS SYNTHPOOL ZAGREB'),
      ]));
      wc.reload();
      for (final r in wc.recurringBills().where((r) => r.label.toLowerCase().contains('synth'))) {
        wc.confirmRecurring(r.id);
      }
      return wc;
    }

    Bill slip(WalletController wc, String payee) {
      final (id, _) = wc.repo.importBill(syntheticBill('s-$payee', payee: payee, due: '2026-10-25', total: 2999));
      wc.repo.updateBill(id, category: 'Bills & subscriptions');
      wc.reload();
      wc.confirmBill(id);
      return wc.bill(id)!;
    }

    RecurringBill byLabel(WalletController wc, String part) => wc.expectedBills().singleWhere((r) => r.label.toLowerCase().contains(part));

    test('Undo puts back the alias the spelling had, not nothing', () {
      final wc = withGym();
      final gym = byLabel(wc, 'synthgym'), pool = byLabel(wc, 'synthpool');
      final b = slip(wc, 'Synth Club Ltd');
      expect(wc.linkSlipToBill(b, pool), isNull);
      final key = wc.payeeAliases().keys.single;
      expect(wc.payeeAliases()[key], pool.payee);
      expect(wc.linkSlipToBill(wc.bill(b.id)!, gym), isNull, reason: 'moved to another bill');
      expect(wc.payeeAliases()[key], gym.payee);
      wc.unlinkSlip(b);
      expect(wc.payeeAliases()[key], pool.payee, reason: 'back to what it was');
      wc.unlinkSlip(b);
      expect(wc.payeeAliases()[key], isNull, reason: 'a plain Undo with no earlier alias still forgets it');
    });

    test('the picker leaves out what core refuses: a bill that is itself an alias, and a slip key another alias points to', () {
      final wc = withGym();
      final gym = byLabel(wc, 'synthgym'), pool = byLabel(wc, 'synthpool');
      final a = slip(wc, 'Synth Club Ltd');
      expect(wc.billsForSlip(a).map((r) => r.id), unorderedEquals([gym.id, pool.id]));
      // The pool bill's payee becomes an alias of the gym's: it can no longer be the target of another alias.
      wc.repo.setPayeeAlias(pool.payee, gym.payee);
      wc.reload();
      expect(wc.billsForSlip(a).map((r) => r.id), [gym.id]);
      for (final r in wc.billsForSlip(a)) {
        expect(wc.linkSlipToBill(a, r), isNull, reason: 'everything offered works');
      }
      // A slip whose spelling is what another alias points to is offered nothing.
      final c = slip(wc, 'Some Other Shop');
      wc.repo.setPayeeAlias('synth_third', billPayeeKey(c)!);
      wc.reload();
      expect(wc.billsForSlip(wc.bill(c.id)!), isEmpty);
    });
  });
}
