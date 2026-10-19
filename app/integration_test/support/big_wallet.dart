// SYNTHETIC big wallet for performance tests: about 5 years and ~20,000 transactions ending today. Deterministic
// (fixed seed), made-up amounts, well-known chains and brands only.
import 'dart:math';

import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

const _chains = [
  'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', 'POS KONZUM 0000 ZAGREB', 'POS SPAR 0000 ZAGREB', 'POS KAUFLAND ZAGREB', //
  'POS DM DROGERIE ZAGREB', 'POS MCDONALDS ZAGREB', 'POS WOLT ZAGREB', 'POS INA 0000 ZAGREB', 'POS DECATHLON ZAGREB',
  'POS IKEA ZAGREB', 'POS ZARA ZAGREB', 'POS STEAM GAMES', 'POS PLODINE ZAGREB', 'POS BAUHAUS ZAGREB',
];

/// One PBZ batch per year (oldest first), [perDay] card payments on average plus monthly salary, rent, loan and
/// subscriptions. 5 years at the default rate give about 20,000 rows.
List<ImportBatch> bigWallet(String today, {int years = 5, int perDay = 11}) {
  final rnd = Random(20261017);
  final end = parseIso(today);
  final start = DateTime.utc(end.year - years, end.month, end.day);
  final byYear = <int, List<(String, int, String, String)>>{};
  for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    final iso = isoDate(d);
    final rows = byYear.putIfAbsent(d.year, () => []);
    if (d.day == 10) rows.add((iso, 140000 + rnd.nextInt(5000), 'Plaća/Mirovina', 'Neto plaća dio 1'));
    if (d.day == 13) rows.add((iso, 40000, 'Plaća/Mirovina', 'Neto plaća dio 2'));
    if (d.day == 11) rows.add((iso, -55000, 'Isplata ATM', 'PBZ ATM TEST ULICA ZAGREB'));
    if (d.day == 18) rows.add((iso, -25000, 'Trajni nalog', 'Naplata kredita 0000000000'));
    if (d.day == 5) rows.add((iso, -1299, 'POS plaćanje', 'POS NETFLIX.COM'));
    if (d.day == 14) rows.add((iso, -10000, 'POS plaćanje', 'POS Revolut**0000* Dublin'));
    final n = rnd.nextInt(2 * perDay - 7) + 4; // 4..2*perDay-4, perDay on average
    for (var k = 0; k < n; k++) {
      rows.add((iso, -(150 + rnd.nextInt(8000)), 'POS plaćanje', _chains[rnd.nextInt(_chains.length)]));
    }
  }
  final out = <ImportBatch>[];
  for (final y in byYear.keys.toList()..sort()) {
    final seen = <String, int>{};
    final txs = <NormalizedTransaction>[];
    for (final (date, cents, type, desc) in byYear[y]!) {
      final key = '$date|$cents|$desc';
      final occ = seen[key] = (seen[key] ?? -1) + 1;
      txs.add(NormalizedTransaction(
          id: transactionId(date, cents, desc, occ),
          source: 'pbz',
          date: date,
          amountMinor: cents,
          currency: 'EUR',
          bankType: type,
          description: desc));
    }
    out.add(ImportBatch(source: 'pbz', transactions: txs));
  }
  return out;
}

/// A Revolut-style CSV of [days] days ending today, [perDay] card payments a day (well-known chains).
String bigRevolutCsv(String today, {int days = 7, int perDay = 6, int seed = 1}) {
  final rnd = Random(seed);
  final b = StringBuffer('Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n');
  for (var i = days - 1; i >= 0; i--) {
    final d = addDays(today, -i);
    for (var k = 0; k < perDay; k++) {
      final cents = 150 + rnd.nextInt(6000);
      final name = ['LIDL ZAGREB', 'WOLT', 'BOLT', 'MCDONALDS ZAGREB', 'SPOTIFY', 'DECATHLON ZAGREB'][rnd.nextInt(6)];
      final amount = '-${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
      b.write('Card Payment,Current,$d 1$k:00:00,$d 1$k:30:00,$name,$amount,0.00,EUR,COMPLETED,100.00\n');
    }
  }
  return b.toString();
}
