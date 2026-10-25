// SYNTHETIC demo wallet for screenshot tests. Made-up amounts; merchants are well-known chains only.
import 'dart:math';

import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

/// About 8 months of PBZ-style transactions ending today: salary in two parts (10th and 13th), rent as an
/// ATM withdrawal, loan, groceries, eating out, subscriptions, Revolut top-ups, one big purchase month.
ImportBatch demoBatch(String today) {
  final rnd = Random(7);
  final rows = <(String, int, String, String)>[]; // date, cents, bank type, description
  final end = parseIso(today);
  for (var back = 8; back >= 0; back--) {
    final m = DateTime(end.year, end.month - back, 1);
    String day(int d) => isoDate(DateTime(m.year, m.month, d));
    rows
      ..add((day(10), 100000, 'Plaća/Mirovina', 'Neto plaća dio 1'))
      ..add((day(13), 40000, 'Plaća/Mirovina', 'Neto plaća dio 2'))
      ..add((day(12), 15000, 'Ostalo', 'UPLATA DEMO SIDE JOB')) // P9: a monthly side income
      ..add((day(11), -55000, 'Isplata ATM', 'PBZ ATM TEST ULICA ZAGREB'))
      ..add((day(18), -25000, 'Trajni nalog', 'Naplata kredita 0000000000'))
      ..add((day(5), -1299, 'POS plaćanje', 'POS NETFLIX.COM'))
      ..add((day(14), -10000, 'POS plaćanje', 'POS Revolut**0000* Dublin'));
    for (var d = 1; d <= 28; d += 2 + rnd.nextInt(3)) {
      rows.add((
        day(d),
        -(1200 + rnd.nextInt(5200)),
        'POS plaćanje',
        rnd.nextBool() ? 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB' : 'POS KONZUM 0000 ZAGREB'
      ));
      if (rnd.nextInt(3) == 0) rows.add((day(d), -(900 + rnd.nextInt(2500)), 'POS plaćanje', 'POS MCDONALDS ZAGREB'));
      if (rnd.nextInt(4) == 0) rows.add((day(d), -(1500 + rnd.nextInt(2000)), 'POS plaćanje', 'POS WOLT ZAGREB'));
    }
    if (back == 0) rows.add((isoDate(end.subtract(const Duration(days: 1))), -6000, 'POS plaćanje', 'POS SPAR ZAGREB')); // seedDemoSplit
    if (back == 3) rows.add((day(20), -48000, 'POS plaćanje', 'POS IKEA ZAGREB'));
    if (back == 5) rows.add((day(22), 25000, 'Ostalo', 'POVRAT POREZA'));
  }
  final seen = <String, int>{};
  final txs = <NormalizedTransaction>[];
  for (final (date, cents, type, desc) in rows) {
    if (date.compareTo(today) > 0) continue;
    final k = '$date|$cents|$desc';
    final occ = seen[k] = (seen[k] ?? -1) + 1;
    txs.add(NormalizedTransaction(
        id: transactionId(date, cents, desc, occ),
        source: 'pbz',
        date: date,
        amountMinor: cents,
        currency: 'EUR',
        bankType: type,
        description: desc));
  }
  return ImportBatch(source: 'pbz', transactions: txs);
}

/// SYNTHETIC accounts for the demo: the PBZ account, cash and a Revolut account in USD, each opened 30 days ago.
Future<void> seedDemoAccounts(WalletRepo repo, String today) async {
  final opened = addDays(today, -30);
  await repo.addAccount(name: 'PBZ current', source: 'pbz', currency: 'EUR', opening: 184250, openingDate: opened);
  await repo.addAccount(name: 'Cash', currency: 'EUR', opening: 6000, openingDate: opened);
  await repo.addAccount(name: 'Revolut travel', source: 'revolut', currency: 'USD', opening: 8000, openingDate: opened);
}

/// Monthly budgets for the demo wallet (cents): Groceries is usually under, Eating out and Food delivery often over.
const demoBudgets = {'Groceries': 40000, 'Eating out': 6000, 'Food delivery': 4000};

/// SYNTHETIC planned costs for the demo: a 340 insurance 2 days ahead (a heads-up on Today), an 80 dentist visit and a 25 gift,
/// all before payday ([periodEnd] is the first day of the next pay period).
void seedDemoPlanned(WalletRepo repo, String today, String periodEnd) {
  String before(int days) {
    final d = addDays(today, days);
    final last = addDays(periodEnd, -1);
    return d.compareTo(last) > 0 ? last : d;
  }

  repo.addPlanned(title: 'Car insurance', date: before(2), amount: 34000, category: 'Car & transport');
  repo.addPlanned(title: 'Dentist', date: before(4), amount: 8000, category: 'Health & care');
  repo.addPlanned(title: 'Gift for a friend', date: before(6), amount: 2500, category: 'Shopping');
}

/// SYNTHETIC bills for the demo: one read from a photo that waits in To review (guessed fields), two confirmed payment slips (unpaid):
/// water due in five days in Bills & subscriptions ("covered by your plan") and a gym fee due in three days in Bills & one-offs
/// (reserved), and one paid receipt with a warranty date and a return-by date, linked to the demo wallet's first card payment.
void seedDemoBills(WalletRepo repo, String today) {
  repo.importBill(NormalizedBill(
      source: BillSource.photo,
      externalId: 'demo:review',
      date: addDays(today, -2),
      total: 7123,
      payee: 'Demo Review Shop',
      description: 'Photo of a shop receipt',
      unsure: 3));
  final (slip, _) = repo.importBill(NormalizedBill(
      source: BillSource.hub3,
      externalId: 'demo:slip',
      date: addDays(today, -1),
      dueDate: addDays(today, 5),
      total: 5432,
      payee: 'Demo Water Utility',
      iban: 'HR1210010051863000160',
      reference: 'HR01 1234-5678',
      description: 'Water bill'));
  // A slip that is still to be paid needs a category before it is confirmed (core rule: never reserved twice).
  repo.updateBill(slip, category: 'Bills & subscriptions');
  repo.confirmBill(slip);
  final (gym, _) = repo.importBill(NormalizedBill(
      source: BillSource.hub3,
      externalId: 'demo:gym',
      date: addDays(today, -1),
      dueDate: addDays(today, 3),
      total: 2900,
      payee: 'Demo Gym Club',
      iban: 'HR1210010051863000160',
      reference: 'HR01 8765-4321',
      description: 'Gym fee'));
  repo.updateBill(gym, category: 'Bills & one-offs');
  repo.confirmBill(gym);
  // P4: a yearly bill (held in full until paid) and a weekly one with a range, both added by hand without a payee.
  repo.addRecurring(
      label: 'Demo Domain Renewal',
      category: 'Bills & one-offs',
      amount: 3600,
      intervalDays: RecurringPeriod.yearly.days,
      firstDue: addDays(today, 120));
  repo.addRecurring(
      label: 'Demo Market Box',
      category: 'Groceries',
      amount: 1200,
      minAmount: 900,
      maxAmount: 1200,
      intervalDays: RecurringPeriod.weekly.days,
      firstDue: addDays(today, 2));
  // P9: the side income, confirmed (the detection finds the monthly rows as a candidate; a row after the 12th has landed this period).
  repo.refreshRecurring(today);
  final side = repo.recurringBills().where((b) => b.isIncome && b.status == 'candidate').firstOrNull;
  if (side != null) repo.confirmRecurring(side.id);
  final spent = repo.transactions().where((t) => t.live && t.amount < 0 && !t.description.toUpperCase().contains('ATM')).firstOrNull;
  if (spent == null) return;
  final (receipt, _) = repo.importBill(NormalizedBill(
      source: BillSource.receiptQr,
      externalId: 'demo:receipt',
      date: spent.date,
      total: -spent.amount,
      payee: 'Demo Electronics',
      description: 'Kettle',
      items: [BillItem(name: 'Kettle', quantity: '1', amount: -spent.amount)]));
  repo.confirmBill(receipt);
  repo.linkBill(receipt, spent.id);
  repo.updateBill(receipt, warrantyUntil: addDays(today, 200), returnBy: addDays(today, 4));
}

/// A SYNTHETIC calendar file: one event with an amount in its title, one without (both become suggestions in Upcoming).
String demoIcs(String today) {
  String d(int n) => addDays(today, n).replaceAll('-', '');
  return 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Budget Wallet demo//EN\r\n'
      'BEGIN:VEVENT\r\nUID:demo-1\r\nDTSTART;VALUE=DATE:${d(3)}\r\nSUMMARY:Birthday dinner 60 €\r\nEND:VEVENT\r\n'
      'BEGIN:VEVENT\r\nUID:demo-2\r\nDTSTART;VALUE=DATE:${d(5)}\r\nSUMMARY:Concert tickets\r\nEND:VEVENT\r\n'
      'END:VCALENDAR\r\n';
}

/// One split supermarket payment (P6): yesterday's 60.00 at the supermarket, 42.00 Groceries and 18.00 Shopping. Call after the import.
void seedDemoSplit(WalletRepo repo) {
  final tx = repo.transactions().firstWhere((t) => t.description == 'POS SPAR ZAGREB');
  repo.setSplit(tx.id, const [
    SplitPart(amount: -4200, category: 'Groceries', tags: [], note: null),
    SplitPart(amount: -1800, category: 'Shopping', tags: [], note: 'Household'),
  ]);
}
