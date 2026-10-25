// Stage N4, app half: Plan › Expected bills › History of a confirmed bill (one line per month, newest first). All data is SYNTHETIC
// (20 Oct 2026; a gym paid on the 25th, with a gap, an extra payment, slips and a month paid early).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/bill_history.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/bills.dart';
import 'support/layout.dart';
import 'support/wallet.dart';

const _gym = 'POS SYNTHGYM ZAGREB';

/// The app puts a no-break space before the currency sign.
String eur(String s) => s.replaceAll(' €', '\u00A0€');

/// A wallet with a confirmed gym bill. Feb: a slip only. Mar, Apr: nothing. May: two payments (29.99 and 30.00) and a slip of
/// 60.50. Jun: nothing, but May's extra payment is dated 30 May. Jul to Sep: 29.99. Oct: coming up.
WalletController historyWallet({bool confirm = true}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  // The gym is detected from three regular months first; the rest of the history is added afterwards.
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) syntheticTx(d, -2999, 'POS plaćanje', _gym),
  ]));
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  wc.snoozeKeyBackup();
  wc.reload();
  wc.refreshRecurring();
  if (confirm) wc.confirmRecurring(wc.recurringBills().single.id);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-05-25', -2999, 'POS plaćanje', _gym),
    syntheticTx('2026-05-30', -3000, 'POS plaćanje', _gym),
  ]));
  wc.repo.importBill(syntheticBill('feb', date: '2026-02-03', total: 2500, payee: _gym));
  wc.repo.importBill(syntheticBill('may', date: '2026-05-02', total: 6050, payee: _gym));
  wc.reload();
  return wc;
}

void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    }, timeout: const Timeout(Duration(minutes: 2)));

Future<void> openHistory(WidgetTester tester, WalletController wc, {Size size = const Size(400, 6000), double scale = 1}) async {
  await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: size, textScale: scale);
  final id = wc.recurringBills().firstWhere((b) => b.status == 'confirmed').id;
  final button = find.byKey(ValueKey('billHistory_$id'));
  await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Finder inMonth(String ym, Finder f) => find.descendant(of: find.byKey(ValueKey('historyMonth_$ym')), matching: f);

void main() {
  group('controller', () {
    test('billHistoryFor: confirmed bills only, one result per data version', () {
      final wc = historyWallet();
      final id = wc.recurringBills().single.id;
      final h = wc.billHistoryFor(id)!;
      expect(h.months.first.month, '2026-10');
      expect(identical(h, wc.billHistoryFor(id)), isTrue, reason: 'memoized');
      expect(wc.billHistoryFor('nope'), isNull);
      final c = historyWallet(confirm: false);
      expect(c.billHistoryFor(c.recurringBills().single.id), isNull);
    });
  });

  group('History sheet', () {
    tw('only a confirmed bill has the action', (tester) async {
      final wc = historyWallet(confirm: false);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
      expect(find.byKey(ValueKey('confirm:${wc.recurringBills().single.id}')), findsOneWidget);
      expect(find.text('History'), findsNothing);
      wc.confirmRecurring(wc.recurringBills().single.id);
      await tester.pump();
      expect(find.text('History'), findsOneWidget);
    });

    tw('every state word, newest month first', (tester) async {
      final wc = historyWallet();
      await openHistory(tester, wc);
      expect(find.byType(BillHistoryScreen), findsOneWidget);
      expect(inMonth('2026-10', find.text('Coming up')), findsOneWidget);
      expect(inMonth('2026-09', find.text('Paid')), findsOneWidget);
      expect(inMonth('2026-07', find.text('Paid')), findsOneWidget);
      expect(inMonth('2026-06', find.text('Paid in May 2026')), findsOneWidget);
      expect(inMonth('2026-05', find.text('Paid')), findsOneWidget);
      expect(inMonth('2026-04', find.text('Missing (no payment or bill found)')), findsOneWidget);
      expect(inMonth('2026-03', find.text('Missing (no payment or bill found)')), findsOneWidget);
      expect(inMonth('2026-02', find.text('Bill only, not paid yet')), findsOneWidget);
      // Newest first.
      final months = [
        for (final m in ['2026-10', '2026-09', '2026-02']) tester.getTopLeft(find.byKey(ValueKey('historyMonth_$m'))).dy
      ];
      expect(months, orderedEquals([...months]..sort()));
      // Nothing before the oldest month with data (Feb).
      expect(find.byKey(const ValueKey('historyMonth_2026-01')), findsNothing);
    });

    tw('exact paid and billed amounts; no amount for a month without one', (tester) async {
      final wc = historyWallet();
      await openHistory(tester, wc);
      expect(inMonth('2026-05', find.text(eur('59.99 €'))), findsOneWidget, reason: 'paid = 29.99 + 30.00');
      expect(inMonth('2026-05', find.text(eur('Bill 60.50 €'))), findsOneWidget);
      expect(inMonth('2026-09', find.text(eur('29.99 €'))), findsOneWidget);
      expect(inMonth('2026-09', find.textContaining('Bill ')), findsNothing, reason: 'no slip in September');
      expect(inMonth('2026-02', find.text(eur('Bill 25 €'))), findsOneWidget);
      for (final m in ['2026-10', '2026-06', '2026-04', '2026-03', '2026-02']) {
        expect(inMonth(m, find.textContaining(RegExp(r'^-?[0-9]+[.,][0-9]{2}\s?€$'))), findsNothing, reason: '$m: no payment amount');
      }
    });

    tw('a month opens to its payments and slips; a payment opens the transaction sheet, a slip the bill sheet', (tester) async {
      final wc = historyWallet();
      await openHistory(tester, wc);
      expect(find.byKey(const ValueKey('historyPayment_x')), findsNothing);
      expect(find.text('Payment'), findsNothing, reason: 'closed months show no rows');
      await tester.tap(find.byKey(const ValueKey('historyToggle_2026-05')));
      await tester.pump();
      expect(find.text('Payment'), findsNWidgets(2));
      expect(find.text('Bill'), findsOneWidget);
      // A month with nothing is not a button.
      expect(find.byKey(const ValueKey('historyToggle_2026-04')), findsNothing);

      final pay =
          find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('historyPayment_')).first;
      await tester.tap(pay);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TxSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sheetClose')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TxSheet), findsNothing);

      final slip =
          find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('historySlip_')).first;
      await tester.tap(slip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(BillSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sheetClose')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // Collapse again.
      await tester.tap(find.byKey(const ValueKey('historyToggle_2026-05')));
      await tester.pump();
      expect(find.text('Payment'), findsNothing);
    });

    tw('a bill with no data shows the current month as Coming up, and only that', (tester) async {
      final wc = historyWallet();
      for (final c in wc.txs.toList()) {
        wc.repo.deleteTransaction(c.tx.id);
      }
      for (final b in wc.billsAll()) {
        wc.repo.deleteBill(b.id);
      }
      wc.reload();
      expect(wc.recurringBills().where((b) => b.status == 'confirmed'), isNotEmpty);
      await openHistory(tester, wc);
      expect(find.byType(BillHistoryScreen), findsOneWidget);
      expect(find.text('Coming up'), findsOneWidget);
      expect(inMonth('2026-10', find.text('Coming up')), findsOneWidget);
      expect(find.byKey(const ValueKey('historyMonth_2026-09')), findsNothing);
    });

    tw('the screen says so when the bill is gone', (tester) async {
      final wc = historyWallet();
      await openHistory(tester, wc);
      wc.deleteRecurring(wc.recurringBills().single.id);
      await tester.pump();
      expect(find.text('This bill is not in your list any more.'), findsOneWidget);
    });

    tw('screen-reader label of a month says month, state and amounts', (tester) async {
      final wc = historyWallet();
      await openHistory(tester, wc);
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(r'^May 2026, Paid, paid 59\.99.€, bill 60\.50.€$')), findsOneWidget);
      expect(find.bySemanticsLabel('October 2026, Coming up'), findsOneWidget);
      handle.dispose();
    });
  });

  group('layout', () {
    final sizes = [('320 dp at text 2.0', const Size(320, 640), 2.0), ('1280 wide', const Size(1280, 900), 1.0)];
    for (final (name, size, scale) in sizes) {
      tw('$name: the history with a month open', (tester) async {
        final errors = Errors();
        final wc = historyWallet();
        await openHistory(tester, wc, size: size, scale: scale);
        expect(find.byType(BillHistoryScreen), findsOneWidget);
        expect(find.byType(Dialog), size.width >= 600 ? findsOneWidget : findsNothing, reason: 'dialog from 600 dp, a page below');
        await tester.ensureVisible(find.byKey(const ValueKey('historyToggle_2026-05')));
        await tester.tap(find.byKey(const ValueKey('historyToggle_2026-05')));
        await tester.pump();
        await scrollThrough(tester);
        // 48 dp targets.
        for (final k in ['historyToggle_2026-05', 'historyToggle_2026-09']) {
          final f = find.byKey(ValueKey(k));
          if (f.evaluate().isNotEmpty) expect(tester.getSize(f).height, greaterThanOrEqualTo(48), reason: k);
        }
        errors.check();
      });
    }
  });
}
