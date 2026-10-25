// Shared SYNTHETIC helpers of the N2 (accounts, balances, suggestions) tests.
import 'package:wallet_core/wallet_core.dart';

/// 2026-10-10 00:00 UTC in ms: the fixed "today" of the N2 repo tests.
const n2Now = 1791590400000;
const n2Today = '2026-10-10';

var _seq = 0;

/// A bare row for the pure balance functions. Amounts are cents.
Tx n2Tx(
  String date,
  int amount, {
  String source = 'pbz',
  String currency = 'EUR',
  bool manual = false,
  String? matchedTo,
  bool matchPending = false,
  bool deleted = false,
  TxKind? kindHint,
}) =>
    Tx(
      id: 'n2-${_seq++}',
      source: source,
      date: date,
      amount: amount,
      currency: currency,
      description: 'Synthetic row',
      manual: manual,
      matchedTo: matchedTo,
      matchPending: matchPending,
      deleted: deleted,
      kindHint: kindHint,
    );

/// A categorised row in any currency (the shared `ct` is EUR only).
CategorizedTx n2Cz(String date, int cents, String category, {String currency = 'EUR', String id = ''}) {
  final t = Tx(
    id: id.isEmpty ? 'n2c-${_seq++}' : id,
    source: 'pbz',
    date: date,
    amount: cents,
    currency: currency,
    description: 'Synthetic $category',
  );
  return CategorizedTx(t, category, kindOf(category));
}
