// F2-ui: the IOU, planned-cost and bill sheets write through `patch`. What a refusal shows, what is (not) sent, and the read-only date of
// an IOU from a payment. Fixed clock, synthetic data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/owed.dart';
import 'package:budget_wallet/src/screens/planned_sheets.dart';
import 'package:budget_wallet/src/screens/recurring_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 60));
Finder _key(String k) => find.byKey(ValueKey(k));

WalletController _wallet() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  return wc;
}

Future<void> _show(WidgetTester t, Widget sheet) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: sheet)), size: const Size(400, 1600));

Future<void> _type(WidgetTester t, String key, String text) async {
  await t.ensureVisible(_key(key));
  await t.enterText(_key(key), text);
  await t.pump();
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(_key(key));
  await t.pump();
  await t.tap(_key(key));
  await t.pump();
}

/// A widget test that lets the controller's 3 s sync debounce run out at the end (a pending timer fails the test).
void tw(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

void main() {
  group('Planned sheet', () {
    tw('an edit of the title does not send an unchanged category, even a deleted one', (t) async {
      final wc = _wallet();
      final cat = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
      final id = wc.repo.addPlanned(title: 'Vet', date: '2026-11-03', amount: 5000, category: cat);
      await wc.deleteOwnCategory(cat);
      final p = wc.plannedOpen().single;
      await _show(t, PlannedFormSheet(wc: wc, edit: p));
      await _type(t, 'plannedTitle', 'Vet visit');
      await _tap(t, 'plannedSave');
      expect(find.byKey(const ValueKey('plannedSave')), findsOneWidget);
      // A sent deleted category would be refused and the title would stay.
      expect(wc.plannedOpen().firstWhere((x) => x.id == id).title, 'Vet visit');
    });

    tw('choosing "No category" clears it', (t) async {
      final wc = _wallet();
      wc.repo.addPlanned(title: 'Dentist', date: '2026-11-03', amount: 5000, category: 'Health & care');
      await _show(t, PlannedFormSheet(wc: wc, edit: wc.plannedOpen().single));
      await _tap(t, 'plannedCategory');
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('No category').last);
      await t.pump(const Duration(milliseconds: 400));
      await _tap(t, 'plannedSave');
      expect(wc.plannedOpen().single.category, isNull);
    });
  });

  group('IOU sheet', () {
    tw('a refused edit shows the message without the column label and writes nothing', (t) async {
      final wc = _wallet();
      final id = wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 4000, date: '2026-10-12');
      await _show(t, IouSheet(wc: wc, iouId: id));
      await _type(t, 'iouPerson', 'x' * (Iou.maxPerson + 1));
      await _tap(t, 'iouSave');
      expect(_key('iouError'), findsOneWidget);
      expect(find.textContaining('Person:'), findsNothing);
      expect(wc.iouById(id)!.iou.person, 'Sam');
    });

    tw('the date of an IOU from a payment cannot be changed', (t) async {
      final wc = _wallet();
      final txId = wc.repo.addTransaction(date: '2026-10-12', amount: 4000, category: 'Shopping');
      await _show(t, IouSheet(wc: wc, tx: wc.repo.transaction(txId)!));
      await _tap(t, 'iouDate');
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(DatePickerDialog), findsNothing);
    });

    tw('a date field of an IOU you add opens the calendar', (t) async {
      final wc = _wallet();
      await _show(t, IouSheet(wc: wc));
      await _tap(t, 'iouDate');
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(DatePickerDialog), findsOneWidget);
    });
  });

  group('Bill sheet', () {
    String bill(WalletController wc, {int? lo, int? hi}) => wc.addRecurringBill(
        label: 'Gym', category: 'Rent', amount: hi ?? 5000, minAmount: lo, maxAmount: hi, intervalDays: 30, firstDue: '2026-11-03');

    tw('a refused edit shows the message without the column label and writes nothing', (t) async {
      final wc = _wallet();
      final id = bill(wc);
      await _show(t, RecurringFormSheet(wc: wc, edit: wc.recurringBills().firstWhere((b) => b.id == id)));
      await _type(t, 'recurringName', '   ');
      await _tap(t, 'recurringSave');
      expect(find.textContaining('Give the bill a name.'), findsOneWidget);
      expect(find.textContaining('Name:'), findsNothing);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).label, 'Gym');
    });

    tw('turning the range off clears both ends', (t) async {
      final wc = _wallet();
      final id = bill(wc, lo: 4000, hi: 7000);
      expect(wc.recurringBills().firstWhere((b) => b.id == id).hasRange, isTrue);
      await _show(t, RecurringFormSheet(wc: wc, edit: wc.recurringBills().firstWhere((b) => b.id == id)));
      await _tap(t, 'recurringRange');
      await _tap(t, 'recurringSave');
      final b = wc.recurringBills().firstWhere((b) => b.id == id);
      expect((b.minAmount, b.maxAmount, b.expectedAmount), (null, null, 7000));
    });

    tw('the name field has the longest allowed name as its cap', (t) async {
      final wc = _wallet();
      await _show(t, RecurringFormSheet(wc: wc));
      expect(t.widget<TextField>(_key('recurringName')).maxLength, WalletRepoRecurring.maxLabel);
    });
  });
}
