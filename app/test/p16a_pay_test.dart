// P16a: the Pay sheet on a bill (copy IBAN, amount, reference; nothing sent) and "payments left" under Plan's Loan line.
// All data is SYNTHETIC (billsWallet: Tuesday 20 Oct 2026; hub3Slip: a made-up slip, 45.60).
import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/bills.dart';
import 'support/plan_page.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Finder key(String k) => find.byKey(ValueKey(k));

/// A widget test that lets the controller's 3 s sync debounce and the 60 s clipboard clear run out before it ends.
void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 65)); // the sync debounce and the clipboard clear
    }, timeout: const Timeout(Duration(seconds: 60)));

/// A wallet with the slip imported and a fake clipboard.
Future<({WalletController wc, String id, List<String?> clip})> slipWallet() async {
  final wc = billsWallet();
  addTearDown(wc.dispose);
  final clip = <String?>[null];
  wc.seams.clipboardWrite = (t) async => clip[0] = t;
  wc.seams.clipboardRead = () async => clip[0];
  final r = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip));
  // Pay is offered for a confirmed bill only; the slip has no date, so give it one and confirm (no due date: no category needed).
  // The total moves off 45.60 so confirming does not link the wallet's 45.60 bank row (that would make the bill paid).
  wc.repo.updateBill(r.billId!, date: '2026-10-18', total: 4570);
  wc.reload();
  expect(wc.confirmBill(r.billId!), isTrue);
  return (wc: wc, id: r.billId!, clip: clip);
}

Future<void> openSheet(WidgetTester tester, WalletController wc, String id, {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(tester,
      Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => openBill(c, wc, id), child: const Text('open'))))),
      size: size, textScale: scale);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> openPay(WidgetTester tester) async {
  final pay = key('billPay');
  await tester.ensureVisible(pay);
  await tester.pump();
  await tester.tap(pay);
  await tester.pumpAndSettle();
}

void main() {
  group('formats', () {
    test('the bank amount: comma decimals, no grouping, no symbol, whatever the look setting', () {
      for (final style in NumberStyle.values) {
        numberStyle = style;
        addTearDown(() => numberStyle = NumberStyle.point);
        expect(bankAmountText(1250), '12,50');
        expect(bankAmountText(123456789), '1234567,89');
        expect(bankAmountText(5), '0,05');
        expect(bankAmountText(100), '1,00');
      }
    });

    test('the IBAN is grouped in 4s for reading and plain for copying', () {
      expect(groupedIban('HR1210010051863000160'), 'HR12 1001 0051 8630 0016 0');
      expect(groupedIban('hr12 1001 0051 8630 0016 0'), 'HR12 1001 0051 8630 0016 0');
      expect(plainIban('HR12 1001 0051 8630 0016 0'), 'HR1210010051863000160');
    });
  });

  group('Pay button', () {
    tw('shown for an unpaid slip with an IBAN and an amount', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id);
      expect(key('billPay'), findsOneWidget);
    });

    tw('not shown without an IBAN', (tester) async {
      final wc = billsWallet();
      addTearDown(wc.dispose);
      final (id, _) = wc.repo.importBill(syntheticBill('noiban'));
      wc.reload();
      await openSheet(tester, wc, id);
      expect(key('billPay'), findsNothing);
    });

    tw('not shown while the bill is still to review (its fields may be unsure)', (tester) async {
      final wc = billsWallet();
      addTearDown(wc.dispose);
      final (id, _) = wc.repo.importBill(syntheticBill('pdf', source: BillSource.pdf));
      wc.repo.updateBill(id, iban: 'HR1210010051863000160');
      wc.reload();
      expect(wc.bill(id)!.unsure, greaterThan(0));
      expect(wc.bill(id)!.status, BillStatus.review);
      await openSheet(tester, wc, id);
      expect(find.textContaining('Unsure'), findsWidgets);
      expect(key('billPay'), findsNothing);
    });

    tw('not shown without an amount, or with a typed total of 0', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id);
      expect(key('billPay'), findsOneWidget);
      await tester.enterText(key('billTotal'), '0');
      await tester.pump();
      expect(key('billPay'), findsNothing);
      await tester.enterText(key('billTotal'), '');
      await tester.pump();
      expect(key('billPay'), findsNothing);
    });

    tw('not shown once the bill is paid', (tester) async {
      final s = await slipWallet();
      s.wc.addBillAsExpense(s.id, category: 'Groceries');
      expect(s.wc.bill(s.id)!.paid, isTrue);
      await openSheet(tester, s.wc, s.id);
      expect(key('billPay'), findsNothing);
    });
  });

  group('Pay sheet', () {
    tw('shows the five fields, grouped IBAN and the bank-app amount, and the note', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id);
      await openPay(tester);
      expect(key('paySheet'), findsOneWidget);
      expect(find.text('Paste these into your bank app. Nothing is sent from here.'), findsOneWidget);
      Finder inSheet(String t) => find.descendant(of: key('paySheet'), matching: find.text(t));
      expect(inSheet('Synthetic Water'), findsOneWidget);
      expect(inSheet('HR12 1001 0051 8630 0016 0'), findsOneWidget);
      expect(inSheet('45,70'), findsOneWidget);
      expect(inSheet(s.wc.bill(s.id)!.reference!), findsOneWidget);
      expect(inSheet('Water bill'), findsOneWidget);
      for (final f in ['payee', 'iban', 'amount', 'reference', 'description']) {
        expect(key('payCopy:$f'), findsOneWidget, reason: f);
      }
      expect(key('payCopyAll'), findsOneWidget);
    });

    tw('each Copy puts exactly its value on the clipboard and says Copied', (tester) async {
      final s = await slipWallet();
      final b = s.wc.bill(s.id)!;
      await openSheet(tester, s.wc, s.id);
      await openPay(tester);
      final expected = {
        'payee': b.payee,
        'iban': 'HR1210010051863000160',
        'amount': '45,70',
        'reference': b.reference,
        'description': b.description,
      };
      for (final e in expected.entries) {
        await tester.tap(key('payCopy:${e.key}'));
        await tester.pump();
        expect(s.clip[0], e.value, reason: e.key);
        expect(find.text('Copied'), findsOneWidget);
      }
    });

    tw('Copy all copies the lines together', (tester) async {
      final s = await slipWallet();
      final b = s.wc.bill(s.id)!;
      await openSheet(tester, s.wc, s.id);
      await openPay(tester);
      await tester.tap(key('payCopyAll'));
      await tester.pump();
      expect(s.clip[0], [b.payee, 'HR1210010051863000160', '45,70', b.reference, b.description].join('\n'));
    });

    tw('the clipboard is emptied after 60 s, but only while it still holds our text', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id);
      await openPay(tester);
      await tester.tap(key('payCopy:iban'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 59));
      expect(s.clip[0], 'HR1210010051863000160');
      await tester.pump(const Duration(seconds: 2));
      expect(s.clip[0], '');

      await tester.tap(key('payCopy:amount'));
      await tester.pump();
      s.clip[0] = 'something else the owner copied';
      await tester.pump(const Duration(seconds: 61));
      expect(s.clip[0], 'something else the owner copied');
    });

    tw('an IBAN edited but not saved is saved first and is what Pay shows and copies', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id);
      await tester.enterText(key('billIban'), 'GB82WEST12345698765432');
      await tester.enterText(key('billTotal'), '12,50');
      await tester.pump();
      await openPay(tester);
      expect(key('paySheet'), findsOneWidget);
      expect(s.wc.bill(s.id)!.iban, 'GB82WEST12345698765432');
      expect(s.wc.bill(s.id)!.total, 1250);
      expect(find.descendant(of: key('paySheet'), matching: find.text('GB82 WEST 1234 5698 7654 32')), findsOneWidget);
      await tester.tap(key('payCopy:iban'));
      await tester.pump();
      expect(s.clip[0], 'GB82WEST12345698765432');
      await tester.tap(key('payCopy:amount'));
      await tester.pump();
      expect(s.clip[0], '12,50');
    });

    tw('a typed IBAN that does not look right stops Pay with the Save message', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id);
      await tester.enterText(key('billIban'), 'HR0000000000000000000');
      await tester.pump();
      await openPay(tester);
      expect(key('paySheet'), findsNothing);
      expect(find.textContaining('IBAN: check the number'), findsOneWidget);
      expect(s.wc.bill(s.id)!.iban, 'HR1210010051863000160');
    });

    tw('copying does not mark the bill paid or change it', (tester) async {
      final s = await slipWallet();
      final before = s.wc.bill(s.id)!;
      await openSheet(tester, s.wc, s.id);
      await openPay(tester);
      await tester.tap(key('payCopyAll'));
      await tester.pump();
      final after = s.wc.bill(s.id)!;
      expect(after.paid, isFalse);
      expect(after.linkedTx, before.linkedTx);
      expect(after.status, before.status);
      expect(after.total, before.total);
    });

    tw('fits 320 dp at text scale 2.0', (tester) async {
      final s = await slipWallet();
      await openSheet(tester, s.wc, s.id, size: const Size(320, 800), scale: 2.0);
      await openPay(tester);
      expect(key('payCopy:iban'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Loan left in the ledger', () {
    Future<WalletController> loanWallet(Map<String, Object?> settings) async {
      final wc = billsWallet();
      addTearDown(wc.dispose);
      wc.repo.updateSettings({'loan': 30000, ...settings});
      wc.reload();
      return wc;
    }

    tw('shows the payments left and the sum under the Loan line', (tester) async {
      final wc = await loanWallet({'loanEnd': '2027-03'});
      // 20 Oct, payday the 15th: this month's has passed, so Nov..Mar = 5.
      expect(wc.loanLeftNow()!.payments, 5);
      await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 1600));
      final line = key('ledgerLoanLeft');
      await tester.ensureVisible(line);
      expect(find.descendant(of: line, matching: find.textContaining('5 payments left')), findsOneWidget);
      expect(find.textContaining('${moneyExact(150000, wc.currency)} at this rate'), findsOneWidget);
    });

    tw('one payment left says "payment"', (tester) async {
      final wc = await loanWallet({'loanEnd': '2026-11'});
      await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 1600));
      await tester.ensureVisible(key('ledgerLoanLeft'));
      expect(find.textContaining('1 payment left'), findsOneWidget);
    });

    tw('no line without an end month, with a past end, or without a loan', (tester) async {
      for (final s in [
        <String, Object?>{},
        {'loanEnd': '2026-09'},
        {'loan': 0, 'loanEnd': '2027-03'},
      ]) {
        final wc = await loanWallet(s);
        expect(wc.loanLeftNow(), isNull, reason: '$s');
        await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 1600));
        expect(key('ledgerLoanLeft'), findsNothing, reason: '$s');
      }
    });
  });
}
