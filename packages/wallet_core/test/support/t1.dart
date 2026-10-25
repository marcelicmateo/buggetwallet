// Shared SYNTHETIC helpers of the T1 (tags) tests. Written from docs/context/T1_SPEC.md.
import 'package:wallet_core/wallet_core.dart';

/// The `tx_tags` links as `tagsOf` takes them: row id -> tag id -> `on` (true) or `off` (false).
Map<String, Map<String, bool>> linksOf(WalletRepo r) {
  final out = <String, Map<String, bool>>{};
  for (final row in r.db.select('SELECT tx, tag, state FROM tx_tags')) {
    (out[row['tx'] as String] ??= {})[row['tag'] as String] = row['state'] == 'on';
  }
  return out;
}

/// The effective tags of the stored row [txId] on [r].
List<String> effective(WalletRepo r, String txId) {
  final t = r.transactions(includeHidden: true).firstWhere((x) => x.id == txId);
  return tagsOf(t, tags: r.tagTable(), ruleTags: r.ruleTags(), links: linksOf(r));
}

/// Raw rows of [table] sorted by id, to compare two devices field by field.
List<Map<String, Object?>> dump(WalletRepo r, String table) =>
    [for (final x in r.db.select('SELECT * FROM $table ORDER BY id')) Map<String, Object?>.from(x)];

/// A bank-style row for the pure functions. Amounts are cents; an expense is negative.
Tx plain(String id, String date, int amount, String desc, {String currency = 'EUR', bool deleted = false, String? matchedTo}) =>
    Tx(id: id, source: 'pbz', date: date, amount: amount, currency: currency, description: desc, deleted: deleted, matchedTo: matchedTo);

/// A categorized row carrying [tags] (already effective tag ids).
CategorizedTx tagged(Tx t, String category, [List<String> tags = const []]) => CategorizedTx(t, category, kindOf(category), tags: tags);
