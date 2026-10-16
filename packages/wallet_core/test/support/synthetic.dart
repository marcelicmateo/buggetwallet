// Shared SYNTHETIC test data for wallet_core tests. No real transactions, amounts or merchants
// from the owner's spending: names are generic or well-known chains, amounts are made up.
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

/// A normalized transaction with a v1-compatible id. Amounts are cents.
NormalizedTransaction n(String date, int cents, String type, String desc, {String source = 'pbz', int occ = 0}) => NormalizedTransaction(
      id: transactionId(date, cents, desc, occ),
      source: source,
      date: date,
      amountMinor: cents,
      currency: 'EUR',
      bankType: type,
      description: desc,
    );

final january = ImportBatch(source: 'pbz', transactions: [
  n('2026-01-15', 150000, 'Plaća/Mirovina', 'Neto plaća za 12/2025'),
  n('2026-01-15', -55000, 'Isplata ATM', 'PBZ ATM TEST ULICA ZAGREB'),
  n('2026-01-16', -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin'),
  n('2026-01-17', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
  n('2026-01-18', -25000, 'Trajni nalog', 'Naplata kredita 0000000000'),
  n('2026-01-18', -33, 'Naplaćene naknade', 'Naknada On-line bankarstvo - kreditni transfer'),
  n('2026-01-20', 30000, 'Ostalo', 'VAL_01.01.2026.POVRAT'),
]);

var _ctSeq = 0;

/// A categorized transaction for pure-function tests (no database). The kind follows the category
/// (`kindOf`). Amounts are cents; expenses negative.
CategorizedTx ct(String date, int cents, String category, {bool deleted = false, String? matchedTo, bool manual = false}) => CategorizedTx(
      Tx(
          id: 'syn-${_ctSeq++}',
          source: 'pbz',
          date: date,
          amount: cents,
          description: 'Synthetic $category',
          deleted: deleted,
          matchedTo: matchedTo,
          manual: manual),
      category,
      kindOf(category),
    );
