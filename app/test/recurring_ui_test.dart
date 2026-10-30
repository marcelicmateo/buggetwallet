// P4 app half: recurring bills beyond monthly in Plan › Expected bills (Add bill, Edit, Mark paid with Undo, the period / range /
// parts / instalments / held labels), Today's bills line with a held yearly bill, and bill history per cycle.
// All data is SYNTHETIC (habitsWallet: Tuesday 20 Oct 2026; payee "zorblex").
import 'package:budget_wallet/src/clock_notice.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bill_history.dart';
import 'package:budget_wallet/src/screens/recurring_sheet.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/plan_page.dart';
import 'support/wallet.dart';

WalletController hw() {
  final wc = habitsWallet();
  addTearDown(wc.dispose);
  return wc;
}

/// A wallet with one payee row of 60 on the 15th and a monthly bill of 100 due on the 25th for that payee: 60 of 100 paid.
WalletController partsWallet() {
  final wc = hw();
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-15', -6000, 'POS plaćanje', 'POS ZORBLEX ZAGREB')]));
  wc.reload();
  final payee = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblex')).key;
  wc.addRecurringBill(label: 'Zorblex plan', category: 'Groceries', amount: 10000, intervalDays: 30, firstDue: '2026-10-25', payee: payee);
  return wc;
}

String _id(WalletController wc, String label) => wc.recurringBills().firstWhere((b) => b.label == label).id;

void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

Future<void> plan(WidgetTester tester, WalletController wc, {Size size = const Size(400, 1400), double scale = 1}) =>
    pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: size, textScale: scale);

Future<void> see(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> openAdd(WidgetTester tester) async {
  await see(tester, find.byKey(const ValueKey('addRecurring')));
  await tester.tap(find.byKey(const ValueKey('addRecurring')));
  await settle(tester);
  expect(find.byKey(const ValueKey('recurringSheet')), findsOneWidget);
}

Future<void> typeIn(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> pickMain(WidgetTester tester, String id) async {
  await tapKey(tester, 'recurringCategory');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(ValueKey('pick:$id')).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> save(WidgetTester tester) async {
  await tapKey(tester, 'recurringSave');
  await settle(tester);
}

void main() {
  group('Add bill', () {
    tw('every period: the chosen chip sets the days', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      for (final p in RecurringPeriod.values) {
        await openAdd(tester);
        await typeIn(tester, 'recurringName', 'Zorblex ${p.name}');
        await typeIn(tester, 'recurringAmount', '25');
        await pickMain(tester, 'Groceries');
        await tapKey(tester, 'recurringPeriod:${p.name}');
        await save(tester);
        expect(find.byKey(const ValueKey('recurringSheet')), findsNothing, reason: '${p.name} saved');
        final b = wc.recurringBills().firstWhere((b) => b.label == 'Zorblex ${p.name}');
        expect(b.intervalDays, p.days);
        expect(b.manual, isTrue);
        expect(b.confirmed, isTrue);
        expect(b.expectedAmount, 2500);
        expect(b.payee, isEmpty);
      }
      expect(wc.recurringBills().where((b) => b.manual).length, RecurringPeriod.values.length);
    });

    tw('a yearly bill is shown as yearly and held in full', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      await openAdd(tester);
      await typeIn(tester, 'recurringName', 'Car cover');
      await typeIn(tester, 'recurringAmount', '600');
      await pickMain(tester, 'Car & transport');
      await tapKey(tester, 'recurringPeriod:yearly');
      expect(find.textContaining('set aside in full from today'), findsOneWidget);
      await save(tester);
      expect(find.text('Bill added'), findsOneWidget);
      final id = _id(wc, 'Car cover');
      await see(tester, find.byKey(ValueKey('bill:$id')));
      expect(find.descendant(of: find.byKey(ValueKey('bill:$id')), matching: find.textContaining('yearly')), findsOneWidget);
      expect(find.byKey(ValueKey('billHeld:$id')), findsOneWidget);
      expect(find.text('Held in full until paid'), findsOneWidget);
      expect(wc.period().dueCycles.any((c) => c.bill.id == id && c.reserve == 60000), isTrue);
    });

    tw('an amount that changes: from and to, the highest is set aside', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      await openAdd(tester);
      await typeIn(tester, 'recurringName', 'Zorblex power');
      await pickMain(tester, 'Groceries');
      await tapKey(tester, 'recurringRange');
      expect(find.byKey(const ValueKey('recurringAmount')), findsNothing);
      await typeIn(tester, 'recurringMin', '40');
      await typeIn(tester, 'recurringMax', '70');
      await save(tester);
      final b = wc.recurringBills().firstWhere((b) => b.label == 'Zorblex power');
      expect((b.minAmount, b.maxAmount, b.reserveAmount), (4000, 7000, 7000));
      await see(tester, find.byKey(ValueKey('billRange:${b.id}')));
      expect(find.text('40–70 €, sets aside 70 €'.replaceAll(' €', ' €')), findsOneWidget);
    });

    tw('instalments: N payments, "N payments left" on the row', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      await openAdd(tester);
      await typeIn(tester, 'recurringName', 'Zorblex phone');
      await typeIn(tester, 'recurringAmount', '30');
      await pickMain(tester, 'Groceries');
      await tapKey(tester, 'recurringEnds');
      await typeIn(tester, 'recurringCount', '6');
      await save(tester);
      final b = wc.recurringBills().firstWhere((b) => b.label == 'Zorblex phone');
      expect(b.endsOn, isNotNull);
      expect(b.instalmentsLeft, 6);
      await see(tester, find.byKey(ValueKey('billInstalments:${b.id}')));
      expect(find.text('6 payments left'), findsOneWidget);
    });

    tw('a payee from history is saved with the bill', (tester) async {
      final wc = partsWallet();
      final key = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblex')).key;
      wc.deleteRecurring(_id(wc, 'Zorblex plan'));
      await plan(tester, wc);
      await openAdd(tester);
      await typeIn(tester, 'recurringName', 'Zorblex again');
      await typeIn(tester, 'recurringAmount', '100');
      await pickMain(tester, 'Groceries');
      await tapKey(tester, 'recurringPayee');
      await tester.tap(find.byKey(ValueKey('payeeItem:$key')).last);
      await tester.pump(const Duration(milliseconds: 300));
      await save(tester);
      expect(wc.recurringBills().firstWhere((b) => b.label == 'Zorblex again').payee, key);
    });

    tw('mistakes show core\'s message and keep the sheet open', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      await openAdd(tester);
      await save(tester);
      expect(find.textContaining('Enter an amount, like 12.50.'), findsOneWidget);
      await typeIn(tester, 'recurringAmount', '20');
      await save(tester);
      expect(find.textContaining('Pick a main tag for the bill.'), findsOneWidget);
      await pickMain(tester, 'Groceries');
      await save(tester);
      expect(find.textContaining('Give the bill a name.'), findsOneWidget);
      await typeIn(tester, 'recurringName', 'Zorblex');
      await tapKey(tester, 'recurringRange');
      await typeIn(tester, 'recurringMin', '70');
      await typeIn(tester, 'recurringMax', '40');
      await save(tester);
      expect(find.textContaining('The amount range is not valid.'), findsOneWidget);
      await typeIn(tester, 'recurringMin', '');
      await save(tester);
      expect(find.textContaining('Enter both ends of the range, like 40 and 70.'), findsOneWidget);
      await tapKey(tester, 'recurringRange'); // back to one amount
      await tapKey(tester, 'recurringEnds');
      await typeIn(tester, 'recurringCount', 'x');
      await save(tester);
      expect(find.textContaining('Enter how many payments, like 12.'), findsOneWidget);
      await typeIn(tester, 'recurringCount', '0');
      await save(tester);
      expect(find.textContaining('Instalments must be between 1 and 600.'), findsOneWidget);
      expect(find.byKey(const ValueKey('recurringSheet')), findsOneWidget);
      expect(wc.recurringBills().where((b) => b.manual), isEmpty, reason: 'nothing was saved');
    });

    tw('a payee that another bill uses is refused with core\'s message', (tester) async {
      final wc = partsWallet();
      final key = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblex')).key;
      await plan(tester, wc);
      await openAdd(tester);
      await typeIn(tester, 'recurringName', 'Zorblex twin');
      await typeIn(tester, 'recurringAmount', '10');
      await pickMain(tester, 'Groceries');
      await tapKey(tester, 'recurringPayee');
      await tester.tap(find.byKey(ValueKey('payeeItem:$key')).last);
      await tester.pump(const Duration(milliseconds: 300));
      await save(tester);
      expect(find.textContaining('Another bill already uses this payee.'), findsOneWidget);
    });
  });

  group('Edit', () {
    tw('change name, amount and how often; the row follows', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(label: 'Zorblex gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-28');
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      expect(find.text('Change bill'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('recurringPeriod:monthly'))).selected, isTrue);
      await typeIn(tester, 'recurringName', 'Zorblex gym 2');
      await typeIn(tester, 'recurringAmount', '45.50');
      await tapKey(tester, 'recurringPeriod:weekly');
      await save(tester);
      expect(find.text('Bill saved'), findsOneWidget);
      final b = wc.recurringBills().firstWhere((b) => b.id == id);
      expect((b.label, b.expectedAmount, b.intervalDays), ('Zorblex gym 2', 4550, 7));
      await see(tester, find.byKey(ValueKey('bill:$id')));
      expect(find.descendant(of: find.byKey(ValueKey('bill:$id')), matching: find.textContaining('every week')), findsOneWidget);
    });

    tw('turn the range off and the instalments off', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(
          label: 'Zorblex ranged',
          category: 'Groceries',
          amount: 7000,
          minAmount: 4000,
          maxAmount: 7000,
          intervalDays: 30,
          firstDue: '2026-10-28',
          instalments: 4);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('recurringRange'))).value, isTrue);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('recurringEnds'))).value, isTrue);
      await tapKey(tester, 'recurringRange');
      await typeIn(tester, 'recurringAmount', '55');
      await tapKey(tester, 'recurringEnds');
      await save(tester);
      final b = wc.recurringBills().firstWhere((b) => b.id == id);
      expect((b.hasRange, b.expectedAmount, b.endsOn), (false, 5500, null));
    });

    tw('a bill that ends: Payments left is changed from the due date', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(
          label: 'Zorblex loan', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-28', instalments: 4);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      expect(find.widgetWithText(TextField, '4'), findsOneWidget);
      await typeIn(tester, 'recurringCount', '2');
      await save(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).instalmentsLeft, 2);
    });

    tw('an error on save keeps the sheet and the bill as it was', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(label: 'Zorblex gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-28');
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      await typeIn(tester, 'recurringName', '');
      await save(tester);
      expect(find.textContaining('Give the bill a name.'), findsOneWidget);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).label, 'Zorblex gym');
    });
  });

  group('Mark paid', () {
    tw('a bill without payee: Mark paid moves the due date, Undo puts it back', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(label: 'Zorblex rent', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-28');
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringMarkPaid:$id')));
      expect(find.byKey(ValueKey('skip:$id')), findsNothing, reason: 'Mark paid replaces Skip');
      await tester.tap(find.byKey(ValueKey('recurringMarkPaid:$id')));
      await settle(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).nextDue, '2026-11-27');
      expect(find.text('Marked paid'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toastUndo')));
      await settle(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).nextDue, '2026-10-28');
    });

    tw('a bill paid in parts: shows what is paid, reserves the rest, Mark paid ends the cycle', (tester) async {
      final wc = partsWallet();
      final id = _id(wc, 'Zorblex plan');
      expect(wc.billPartsPaid(wc.recurringBills().firstWhere((b) => b.id == id)), 6000);
      expect(wc.period().dueCycles.single.reserve, 4000);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('billParts:$id')));
      expect(find.text('60 of 100 € paid'.replaceAll(' €', ' €')), findsOneWidget);
      expect(find.byKey(ValueKey('skip:$id')), findsNothing);
      await tester.tap(find.byKey(ValueKey('recurringMarkPaid:$id')));
      await settle(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).nextDue, '2026-11-24');
      expect(wc.period().reservedBills, 0);
    });

    tw('a bill with a payee and no parts keeps Skip this cycle', (tester) async {
      final wc = hw(); // the detected gym bill
      wc.confirmRecurring(wc.recurringBills().first.id);
      final id = wc.recurringBills().first.id;
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('skip:$id')));
      expect(find.byKey(ValueKey('recurringMarkPaid:$id')), findsNothing);
      expect(find.byKey(ValueKey('recurringEdit:$id')), findsOneWidget);
    });
  });

  group('Today', () {
    Widget today(WalletController wc) => Scaffold(
        body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday, chooser: const FileChooser(), openBills: () {}));

    tw('a held yearly bill is in the Before payday tile: 600 €', (tester) async {
      final wc = hw();
      wc.addRecurringBill(label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: '2027-03-01');
      expect(wc.period().reservedBills, 60000);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(
          find.descendant(of: find.byKey(const ValueKey('comingUpLine')), matching: find.text(moneyExact(60000, 'EUR'))), findsOneWidget);
      expect(find.textContaining('held until paid'), findsNothing, reason: 'the held text lives on the Bills page');
      expect(find.textContaining('Due by payday'), findsNothing, reason: 'nothing else is due before payday');
    });

    tw('a weekly bill adds each payment of the period to Before payday', (tester) async {
      final wc = hw();
      wc.addRecurringBill(label: 'Zorblex weekly', category: 'Groceries', amount: 2000, intervalDays: 7, firstDue: '2026-10-21');
      final n = wc.period().dueCycles.length;
      expect(n, greaterThan(2));
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      final tile = find.byKey(const ValueKey('comingUpLine'));
      expect(find.descendant(of: tile, matching: find.text(moneyExact(2000 * n, 'EUR'))), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('${wc.period().beforePaydayCount} costs')), findsOneWidget);
    });
  });

  group('Expected bills labels', () {
    tw('a detected non-monthly candidate says how often it comes', (tester) async {
      final wc = hw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-09-28', '2026-10-05', '2026-10-12', '2026-10-19'])
          syntheticTx(d, -1200, 'POS plaćanje', 'POS ZORBLEXWEEK ZAGREB'),
      ]));
      wc.reload();
      wc.refreshRecurring();
      final weekly = wc.recurringBills().where((b) => b.status == 'candidate' && b.intervalDays == 7);
      expect(weekly, hasLength(1));
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('candidate:${weekly.single.id}')));
      expect(find.text('Looks like a repeating bill'), findsOneWidget);
      expect(find.textContaining('Every week · next about'), findsOneWidget);
    });
  });

  group('Bill history per cycle', () {
    tw('a quarterly bill has a line per due date', (tester) async {
      final wc = hw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-04-16', '2026-07-15']) syntheticTx(d, -9000, 'POS plaćanje', 'POS ZORBLEXQ ZAGREB'),
      ]));
      wc.reload();
      final payee = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblexq')).key;
      final id = wc.addRecurringBill(
          label: 'Zorblex quarter', category: 'Groceries', amount: 9000, intervalDays: 91, firstDue: '2026-10-14', payee: payee);
      final months = wc.billHistoryFor(id)!.months;
      expect(months.every((m) => m.due != null), isTrue);
      expect(months.map((m) => m.due).toSet().length, months.length, reason: 'one line per cycle');
      await pumpApp(tester, BillHistoryScreen(wc: wc, billId: id), size: const Size(400, 3000));
      for (final m in months) {
        expect(find.byKey(ValueKey('historyMonth_${m.due}')), findsOneWidget);
        expect(find.text('Due ${longDateOrRaw(m.due!)}'), findsOneWidget);
      }
      expect(find.textContaining('one payment due date at a time'), findsOneWidget);
      expect(months.where((m) => m.state == BillMonthState.paid), isNotEmpty);
    });

    tw('a cycle paid in parts lists its parts', (tester) async {
      final wc = hw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-09-20', '2026-09-27']) syntheticTx(d, -5000, 'POS plaćanje', 'POS ZORBLEXP ZAGREB'),
      ]));
      wc.reload();
      final payee = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblexp')).key;
      final id = wc.addRecurringBill(
          label: 'Zorblex parts', category: 'Groceries', amount: 10000, intervalDays: 91, firstDue: '2026-09-28', payee: payee);
      final months = wc.billHistoryFor(id)!.months;
      final cycle = months.firstWhere((m) => m.payments.length == 2);
      await pumpApp(tester, BillHistoryScreen(wc: wc, billId: id), size: const Size(400, 3000));
      await tester.tap(find.byKey(ValueKey('historyToggle_${cycle.due}')));
      await tester.pump();
      expect(find.text('Part'), findsNWidgets(2));
      expect(find.text('Payment'), findsNothing);
    });

    tw('a monthly bill keeps its month lines', (tester) async {
      final wc = hw(); // the detected gym bill
      wc.confirmRecurring(wc.recurringBills().first.id);
      final id = wc.recurringBills().first.id;
      final months = wc.billHistoryFor(id)!.months;
      expect(months.every((m) => m.due == null), isTrue);
      await pumpApp(tester, BillHistoryScreen(wc: wc, billId: id), size: const Size(400, 3000));
      expect(find.byKey(ValueKey('historyMonth_${months.first.month}')), findsOneWidget);
      expect(find.textContaining('a month at a time'), findsOneWidget);
    });
  });

  group('review fixes', () {
    tw('renaming a 36-payment monthly plan from 31 Jan keeps its last due date', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(
          label: 'Zorblex loan', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2027-01-31', instalments: 36);
      final end = wc.recurringBills().firstWhere((b) => b.id == id).endsOn;
      expect(end, '2029-12-31');
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      await typeIn(tester, 'recurringName', 'Zorblex loan 2');
      await save(tester);
      final b = wc.recurringBills().firstWhere((b) => b.id == id);
      expect((b.label, b.endsOn), ('Zorblex loan 2', end));
    });

    tw('changing the count of a monthly plan uses calendar months', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(
          label: 'Zorblex loan', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2027-01-31', instalments: 6);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      await typeIn(tester, 'recurringCount', '3');
      await save(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).endsOn, '2027-03-31');
    });

    tw('a finished plan opens with a blank count and a save keeps its end', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(
          label: 'Zorblex done', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-08-01', instalments: 1);
      wc.repo.updateRecurring(id, nextDue: '2026-12-01');
      wc.reload();
      final end = wc.recurringBills().firstWhere((b) => b.id == id).endsOn;
      expect(wc.recurringBills().firstWhere((b) => b.id == id).finished, isTrue);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('recurringEnds'))).value, isTrue);
      await typeIn(tester, 'recurringName', 'Zorblex done 2');
      await save(tester);
      expect(find.byKey(const ValueKey('recurringSheet')), findsNothing);
      final b = wc.recurringBills().firstWhere((b) => b.id == id);
      expect((b.label, b.endsOn, b.finished), ('Zorblex done 2', end, true));
    });

    tw('Paid shows for a monthly bill only, not a weekly or yearly one', (tester) async {
      final wc = hw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-14', -2000, 'POS plaćanje', 'POS ZORBLEXW ZAGREB'),
        syntheticTx('2026-10-14', -3000, 'POS plaćanje', 'POS ZORBLEXM ZAGREB'),
      ]));
      wc.reload();
      String key(String s) => wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains(s)).key;
      final weekly = wc.addRecurringBill(
          label: 'Zorblex weekly', category: 'Groceries', amount: 2000, intervalDays: 7, firstDue: '2026-10-14', payee: key('zorblexw'));
      final monthly = wc.addRecurringBill(
          label: 'Zorblex monthly', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-14', payee: key('zorblexm'));
      expect(wc.recurringBills().firstWhere((b) => b.id == weekly).lastPaidTx, isNotNull);
      expect(wc.recurringBills().firstWhere((b) => b.id == monthly).lastPaidTx, isNotNull);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('bill:$monthly')));
      expect(find.descendant(of: find.byKey(ValueKey('bill:$monthly')), matching: find.textContaining('Paid')), findsOneWidget);
      await see(tester, find.byKey(ValueKey('bill:$weekly')));
      expect(find.descendant(of: find.byKey(ValueKey('bill:$weekly')), matching: find.textContaining('Paid')), findsNothing);
    });

    tw('a detected candidate can be edited and stays a candidate', (tester) async {
      final wc = hw();
      final id = wc.recurringBills().single.id;
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringEdit:$id')));
      await tester.tap(find.byKey(ValueKey('recurringEdit:$id')));
      await settle(tester);
      expect(find.text('Change bill'), findsOneWidget);
      await typeIn(tester, 'recurringAmount', '31');
      await save(tester);
      expect(find.text('Bill saved'), findsOneWidget);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).status, 'candidate');
    });

    tw('Mark paid refused by a clock that is behind: no "Marked paid" toast, the due date stays', (tester) async {
      var wall = DateTime(2026, 10, 20, 12).millisecondsSinceEpoch;
      final wc = WalletController.forTest(WalletRepo.inMemory(now: () => wall), key: VaultKey.generate(), clock: () => budgetToday);
      addTearDown(wc.dispose);
      final id = wc.addRecurringBill(label: 'Zorblex rent', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-28');
      final before = clockBehindNotice.value;
      await plan(tester, wc);
      wall -= 3 * 3600 * 1000;
      await see(tester, find.byKey(ValueKey('recurringMarkPaid:$id')));
      await tester.tap(find.byKey(ValueKey('recurringMarkPaid:$id')));
      await settle(tester);
      expect(clockBehindNotice.value, before + 1);
      expect(find.text('Marked paid'), findsNothing);
      expect(wc.recurringBills().single.nextDue, '2026-10-28');
    });

    tw('a long bill paid by a row not yet recorded holds nothing: no held line', (tester) async {
      final wc = hw();
      wc.repo.updateSettings({'paydayDay': 21});
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-19', -60000, 'POS plaćanje', 'POS ZORBLEXY ZAGREB')]));
      wc.reload();
      final payee = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblexy')).key;
      wc.repo.addRecurring(
          label: 'Zorblex cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: '2026-10-25', payee: payee);
      wc.reload();
      final c = wc.period().dueCycles.firstWhere((c) => c.bill.label == 'Zorblex cover');
      expect(c.reserve, 0);
      await pumpApp(
          tester,
          Scaffold(
              body: TodayScreen(
                  view: TodayView(wc), openPlan: () {}, clock: () => budgetToday, chooser: const FileChooser(), openBills: () {})),
          size: const Size(400, 3000));
      expect(find.textContaining('held until paid'), findsNothing);
    });

    tw('Mark paid then Undo restores the exact old due date of a monthly plan with an end', (tester) async {
      final wc = hw();
      final id = wc.addRecurringBill(
          label: 'Zorblex loan', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-31', instalments: 6);
      await plan(tester, wc);
      await see(tester, find.byKey(ValueKey('recurringMarkPaid:$id')));
      await tester.tap(find.byKey(ValueKey('recurringMarkPaid:$id')));
      await settle(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).nextDue, isNot('2026-10-31'));
      await tester.tap(find.byKey(const ValueKey('toastUndo')));
      await settle(tester);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).nextDue, '2026-10-31');
    });

    test('billPaidText writes both numbers in the money format', () {
      expect(billPaidText(6000, 10000, 'EUR'), '60 of 100 € paid');
      expect(billPaidText(123456, 200000, 'EUR'), '1,234.56 of 2,000 € paid');
    });
  });

  group('layout', () {
    final sizes = [
      ('320 dp at text 2.0', const Size(320, 640), 2.0),
      ('360 dp', const Size(360, 800), 1.0),
      ('1280 wide', const Size(1280, 900), 1.0),
    ];
    for (final (name, size, scale) in sizes) {
      tw('$name: Plan with every kind of bill row', (tester) async {
        final errors = Errors();
        final wc = partsWallet();
        wc.addRecurringBill(label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: '2027-03-01');
        wc.addRecurringBill(
            label: 'Zorblex power',
            category: 'Groceries',
            amount: 7000,
            minAmount: 4000,
            maxAmount: 7000,
            intervalDays: 7,
            firstDue: '2026-10-21',
            instalments: 12);
        await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: size, textScale: scale);
        await scrollThrough(tester);
        errors.check();
      });

      tw('$name: the add sheet with the range and instalments open', (tester) async {
        final errors = Errors();
        final wc = hw();
        await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: size, textScale: scale);
        await openAdd(tester);
        await tapKey(tester, 'recurringRange');
        await tapKey(tester, 'recurringEnds');
        await tapKey(tester, 'recurringPeriod:biweekly');
        await tester.ensureVisible(find.byKey(const ValueKey('recurringSave')));
        await tester.pump();
        errors.check();
      });
    }
  });
}
