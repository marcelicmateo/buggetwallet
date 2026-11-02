/// Split transactions (P6, schema 13): one payment's amount shared out over parts, each with its own main tag
/// (category), extra tags and note. Stored as one synced field (`split` entity, table `tx_splits`, id = the tx id,
/// `parts` = JSON), so last-writer-wins always keeps a consistent set of parts. Pure: reading and checking only;
/// `WalletRepoSplits` writes, `Categorizer.expand` reads them into rows.
library;

import 'dart:convert';

import 'cols.dart';

/// The columns of the synced entity `split` (table `tx_splits`, id = the tx id), in table order ([Col]).
abstract final class SplitCols {
  static const entity = 'split';
  static const parts = JsonCol(entity, 'parts', label: 'Parts', defaultValue: '[]'); // the whole split, one field
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[parts, deleted];
}

/// One part of a split payment: [amount] in cents (the payment's sign), [category] its main tag, [tags] its extra
/// tags (tag ids), [note] its own note (null when none).
class SplitPart {
  final int amount;
  final String category;
  final List<String> tags;
  final String? note;
  const SplitPart({required this.amount, required this.category, this.tags = const [], this.note});

  /// Fewest and most parts a split has.
  static const minParts = 2, maxParts = 20;

  /// Most extra tags on one part.
  static const maxTags = 20;

  /// Longest note (characters, after trimming).
  static const maxNote = 200;

  /// The stored shape: `{a: cents, c: category id, t: [tag ids], n: note?}`.
  Map<String, Object?> toJson() => {
        'a': amount,
        'c': category,
        't': tags,
        if (note != null) 'n': note,
      };

  /// A stored part, or null when it is not one: `a` an int, `c` a non-empty string, `t` (optional) a list of
  /// strings, `n` (optional) a string or null.
  static SplitPart? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['a'], c = j['c'], t = j['t'], n = j['n'];
    if (a is! int || c is! String || c.isEmpty) return null;
    if (t != null && (t is! List || t.any((x) => x is! String))) return null;
    if (n != null && n is! String) return null;
    final note = (n as String?)?.trim();
    return SplitPart(
        amount: a,
        category: c,
        tags: t is List ? List.unmodifiable(t.cast<String>()) : const [],
        note: note == null || note.isEmpty ? null : note);
  }

  @override
  bool operator ==(Object other) =>
      other is SplitPart &&
      other.amount == amount &&
      other.category == category &&
      other.note == note &&
      other.tags.length == tags.length &&
      Iterable<int>.generate(tags.length).every((i) => other.tags[i] == tags[i]);

  @override
  int get hashCode => Object.hash(amount, category, note, Object.hashAll(tags));

  @override
  String toString() => 'SplitPart(${tags.length} tags${note == null ? '' : ', note'})'; // never the amount or category
}

/// [parts] as the stored `parts` text.
String encodeSplitParts(List<SplitPart> parts) => jsonEncode([for (final p in parts) p.toJson()]);

/// The stored `parts` text as parts, or an empty list when it cannot be read (not JSON, not a list, or one entry is
/// not a part: the whole split is unreadable, never half of it).
List<SplitPart> decodeSplitParts(Object? text) {
  if (text is! String || text.isEmpty) return const [];
  try {
    final j = jsonDecode(text);
    if (j is! List) return const [];
    final out = <SplitPart>[];
    for (final e in j) {
      final p = SplitPart.fromJson(e);
      if (p == null) return const [];
      out.add(p);
    }
    return List.unmodifiable(out);
  } on FormatException {
    return const [];
  }
}

/// Whether [parts] still split a payment of [amount] exactly: [SplitPart.minParts]..[SplitPart.maxParts] parts, each
/// non-zero and of the payment's sign, summing to [amount] to the cent. A split that does not (the payment's amount
/// was edited, a synced split arrived for a changed row, or it is unreadable) is ignored when read: the payment
/// counts whole (`CategorizedTx.splitBroken`).
bool splitFits(int amount, List<SplitPart> parts) {
  if (amount == 0 || parts.length < SplitPart.minParts || parts.length > SplitPart.maxParts) return false;
  var sum = 0;
  for (final p in parts) {
    if (p.amount == 0 || (p.amount < 0) != (amount < 0)) return false;
    sum += p.amount;
  }
  return sum == amount;
}
