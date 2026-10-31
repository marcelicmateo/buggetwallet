// KL-UI1 (known limits, UI half): the auto-Paid toast with Undo, "Belongs to bill…" and payee aliases in every core call, calendar uid and
// start time, Upcoming's "Set aside" = Today's "Before payday" (overdue cycles included), and the RX8 stand-in swapped for core's compareTag.
// Synthetic data only.
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/upcoming.dart';
import 'package:budget_wallet/src/screens/upcoming_view.dart';
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

/// 20 Oct 2026, payday on the 1st: period 1 Oct .. 1 Nov.
WalletController wallet() {
  final wc = seamedController(WalletRepo.inMemory(now: () => budgetToday.millisecondsSinceEpoch),
      key: VaultKey.generate(), clock: () => budgetToday, billInputs: FakeBillInputs().inputs);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
  wc.snoozeKeyBackup();
  addTearDown(wc.dispose);
  return wc;
}

ImportBatch lidl(String date, int cents) =>
    ImportBatch(source: 'pbz', transactions: [syntheticTx(date, cents, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB')]);

void main() {
  group('auto-Paid toast', () {
    test('takeAutoPaid gives the closed costs once; Undo reopens them and they stay open', () {
      final wc = wallet();
      final id = wc.repo.addPlanned(title: 'Synthetic groceries', date: '2026-10-18', amount: 4500, category: 'Groceries');
      wc.reload();
      expect(wc.takeAutoPaid(), isEmpty);
      wc.repo.importBatch(lidl('2026-10-19', -4500));
      wc.reload();
      final done = wc.takeAutoPaid();
      expect(done.map((a) => a.plannedId), [id]);
      expect(wc.autoPaidText(done), 'Marked paid: Synthetic groceries');
      expect(wc.plannedOpen(), isEmpty);
      expect(wc.takeAutoPaid(), isEmpty, reason: 'shown once');
      expect(wc.repo.autoPaidPlanned(), isEmpty, reason: 'acknowledged');
      wc.undoAutoPaid(done);
      expect(wc.plannedOpen().map((p) => p.id), [id]);
      expect(wc.takeAutoPaid(), isEmpty, reason: 'the undo itself is not announced');
      wc.reload();
      expect(wc.plannedOpen(), hasLength(1), reason: 'the same bank row never closes it again');
    });

    test('several costs: the text counts them', () {
      final wc = wallet();
      expect(
          wc.autoPaidText([const AutoPaid(plannedId: 'a', txId: 't', title: 'x'), const AutoPaid(plannedId: 'b', txId: 'u', title: 'y')]),
          '2 planned costs marked paid');
    });

    tw('an import that closes a cost shows one toast with Undo', (tester) async {
      final wc = wallet();
      final id = wc.repo.addPlanned(title: 'Synthetic groceries', date: '2026-10-18', amount: 4500, category: 'Groceries');
      wc.reload();
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BudgetWalletApp(wc: wc));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      wc.repo.importBatch(lidl('2026-10-19', -4500));
      wc.reload();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.descendant(of: find.byType(SnackBar), matching: find.text('Marked paid: Synthetic groceries')), findsOneWidget);
      await tester.tap(key('toastUndo'));
      await tester.pump();
      expect(wc.plannedOpen().map((p) => p.id), [id]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing, reason: 'the undo itself is not announced');
    });

    tw('two bank rows that fit the cost: it stays open and no toast shows', (tester) async {
      final wc = wallet();
      final id = wc.repo.addPlanned(title: 'Synthetic groceries', date: '2026-10-18', amount: 4500, category: 'Groceries');
      wc.reload();
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(BudgetWalletApp(wc: wc));
      await tester.pump();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-19', -4500, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
        syntheticTx('2026-10-20', -4500, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
      ]));
      wc.reload();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(SnackBar), findsNothing);
      expect(wc.plannedOpen().map((p) => p.id), [id]);
      expect(wc.takeAutoPaid(), isEmpty);
    });
  });

  group('Belongs to bill…', () {
    WalletController withGym() {
      final wc = wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) syntheticTx(d, -2999, 'POS plaćanje', 'POS SYNTHGYM ZAGREB'),
      ]));
      wc.reload();
      wc.confirmRecurring(wc.recurringBills().singleWhere((r) => r.label.toLowerCase().contains('synthgym')).id);
      return wc;
    }

    String slip(WalletController wc, String payee) {
      final (id, _) = wc.repo.importBill(syntheticBill('s-$payee', payee: payee, due: '2026-10-25', total: 2999));
      wc.repo.updateBill(id, category: 'Bills & subscriptions');
      wc.reload();
      wc.confirmBill(id);
      return id;
    }

    test('link, coverage follows the alias, Undo forgets it', () {
      final wc = withGym();
      final gym = wc.expectedBills().single;
      final id = slip(wc, 'Synth Gym Ltd');
      final b = wc.bill(id)!;
      expect(wc.billPlannedBy(b), isNull);
      expect(wc.billsForSlip(b).map((r) => r.id), [gym.id]);
      expect(wc.payeeAliases(), isEmpty);
      expect(wc.linkSlipToBill(b, gym), isNull);
      expect(wc.payeeAliases().values, [gym.payee]);
      expect(wc.billPlannedBy(wc.bill(id)!)?.id, gym.id);
      expect(wc.billsForSlip(wc.bill(id)!), isEmpty);
      wc.unlinkSlip(b);
      expect(wc.payeeAliases(), isEmpty);
      expect(wc.billPlannedBy(wc.bill(id)!), isNull);
    });

    test('core\'s refusal comes back as text; an attachment or a bill of the same payee offers nothing', () {
      final wc = withGym();
      final gym = wc.expectedBills().single;
      final id = slip(wc, 'SYNTHGYM ZAGREB');
      expect(wc.billsForSlip(wc.bill(id)!), isEmpty, reason: 'same payee: already covered');
      final other = wc.bill(slip(wc, 'Unknown Plumber'))!;
      expect(wc.linkSlipToBill(other, gym), isNull);
      final third = wc.bill(slip(wc, 'Another Plumber'))!;
      expect(wc.linkSlipToBill(third, gym), isNull, reason: 'two spellings may share one bill');
    });

    tw('the slip sheet offers the picker, links, and the toast Undo removes the alias', (tester) async {
      final wc = withGym();
      final gym = wc.expectedBills().single;
      final id = slip(wc, 'Synth Gym Ltd');
      await _openSheet(tester, wc, id);
      expect(key('slipBelongsTo'), findsOneWidget);
      await tester.tap(key('slipBelongsTo'));
      await tester.pumpAndSettle();
      expect(key('belongs:${gym.id}'), findsOneWidget);
      await tester.tap(key('belongs:${gym.id}'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 300)); // the picker closes, then the sheet, then the toast slides in
      }
      expect(wc.payeeAliases().values, [gym.payee]);
      expect(key('toastUndo'), findsOneWidget);
      await tester.tap(key('toastUndo'));
      await tester.pump();
      expect(wc.payeeAliases(), isEmpty);
    });

    tw('closing the picker without a choice links nothing', (tester) async {
      final wc = withGym();
      final id = slip(wc, 'Synth Gym Ltd');
      await _openSheet(tester, wc, id);
      await tester.tap(key('slipBelongsTo'));
      await tester.pumpAndSettle();
      expect(find.text('Belongs to bill…'), findsWidgets);
      await tester.tapAt(const Offset(200, 20)); // the barrier
      await tester.pumpAndSettle();
      expect(wc.payeeAliases(), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(wc.billPlannedBy(wc.bill(id)!), isNull);
    });

    tw('a slip an expected bill already covers has no button', (tester) async {
      final wc = withGym();
      final id = slip(wc, 'SYNTHGYM ZAGREB');
      await _openSheet(tester, wc, id);
      expect(key('plannedBy'), findsOneWidget);
      expect(key('slipBelongsTo'), findsNothing);
    });
  });

  group('calendar events', () {
    test('a confirm stores the uid + start time ref; a dismiss finds a row stored under the old ref', () {
      final wc = wallet();
      const e = CalendarEvent(
          calendarId: 'c1', uid: 'u-1@example.com', title: 'Synthetic event', date: '2026-10-24', allDay: false, startMinutes: 600);
      expect(e.ref, isNot(e.legacyRef));
      wc.repo.addPlanned(
          title: 'Synthetic event',
          date: e.date,
          amount: 5000,
          category: 'Shopping',
          source: PlannedSource.calendar,
          sourceRef: e.legacyRef);
      wc.reload();
      wc.dismissSuggestion(UpcomingItem(kind: UpcomingKind.suggestion, key: 'e:${e.ref}', date: e.date, title: e.title, event: e));
      final rows = wc.plannedEverything();
      expect(rows, hasLength(1), reason: 'the old row is the one skipped');
      expect(rows.single.status, PlannedStatus.skipped);
      expect(rows.single.sourceRef, e.legacyRef);
      wc.confirmSuggestion(UpcomingItem(kind: UpcomingKind.suggestion, key: 'e:${e.ref}', date: e.date, title: e.title, event: e),
          amount: 5000);
      expect(wc.plannedEverything().map((p) => p.sourceRef), contains(e.ref));
    });
  });

  group('calendar events without an id', () {
    const noId = CalendarEvent(calendarId: 'c1', uid: '', title: 'Synthetic event', date: '2026-10-24', allDay: false, startMinutes: 600);
    test('the title, date and start time identify it; a rename with a uid keeps the ref', () {
      final later = CalendarEvent(calendarId: 'c9', uid: '', title: 'synthetic EVENT', date: noId.date, allDay: false, startMinutes: 600);
      expect(later.ref, noId.ref, reason: 'the same on another device and calendar');
      expect(CalendarEvent(calendarId: 'c1', uid: '', title: noId.title, date: noId.date, allDay: false, startMinutes: 900).ref,
          isNot(noId.ref));
      const a = CalendarEvent(calendarId: 'c1', uid: 'u@x', title: 'Old name', date: '2026-10-24', allDay: false, startMinutes: 600);
      const b = CalendarEvent(calendarId: 'c1', uid: 'u@x', title: 'New name', date: '2026-10-24', allDay: false, startMinutes: 600);
      expect(b.ref, a.ref);
    });
  });

  group('Upcoming = Today', () {
    /// An overdue bill inside the period, one overdue from before it, a bill later, a planned cost.
    WalletController overdueWallet() {
      final wc = wallet();
      wc.repo.addRecurring(
          label: 'Synth overdue', category: 'Shopping', amount: 3100, intervalDays: 30, firstDue: '2026-10-05', payee: 'synth_a');
      wc.repo
          .addRecurring(label: 'Synth old', category: 'Shopping', amount: 1700, intervalDays: 30, firstDue: '2026-09-10', payee: 'synth_b');
      wc.repo.addRecurring(
          label: 'Synth later', category: 'Shopping', amount: 2200, intervalDays: 30, firstDue: '2026-10-28', payee: 'synth_c');
      wc.repo.addPlanned(title: 'Synthetic gift', date: '2026-10-24', amount: 4000, category: 'Shopping');
      wc.reload();
      return wc;
    }

    test('Set aside is exactly Before payday, overdue cycles included', () {
      final wc = overdueWallet();
      final p = wc.period();
      expect(p.beforePayday, 3100 + 1700 + 2200 + 4000);
      final r = wc.upcomingRange();
      final items = wc.upcomingItems(r.start, r.end);
      expect(wc.setAside(items), (count: 4, total: p.beforePayday));
      expect(wc.comingUp().total + p.reservedBills, p.beforePayday);
      expect(wc.overdueEarlier().map((c) => c.bill.label), ['Synth old']);
      expect(items.where(wc.isOverdueCycle).map((i) => i.title), ['Synth overdue', 'Synth old']);
    });

    tw('the page shows the same cents as Today, marks the overdue cycle and lists the older one apart', (tester) async {
      final wc = overdueWallet();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 2400));
      final total = moneyExact(wc.period().beforePayday, wc.currency);
      expect(find.text(total), findsWidgets);
      expect(find.text('Set aside'), findsOneWidget);
      expect(find.text('4 costs'), findsOneWidget);
      final marked = wc.upcomingItems(wc.upcomingRange().start, wc.upcomingRange().end).where(wc.isOverdueCycle);
      for (final i in marked) {
        expect(key('overdue:${i.key}'), findsOneWidget);
      }
      expect(key('upcomingOverdue'), findsOneWidget);
      expect(find.text('OVERDUE'), findsOneWidget, reason: 'the panel heading');
    });
  });
}

Future<void> _openSheet(WidgetTester tester, WalletController wc, String id) async {
  await pumpApp(tester,
      Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => openBill(c, wc, id), child: const Text('open'))))),
      size: const Size(400, 1600));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
