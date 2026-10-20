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

/// Monthly budgets for the demo wallet (cents): Groceries is usually under, Eating out and Food delivery often over.
const demoBudgets = {'Groceries': 40000, 'Eating out': 6000, 'Food delivery': 4000};
