/// Search over everything in the wallet (M5). Pure: the caller passes the lists it shows.
library;

import 'models.dart';

/// Newest transactions a result holds at most.
const searchTxLimit = 200;

/// Most digits an amount query may have before the decimal point (more is never an amount).
const _maxAmountDigits = 15;

/// `12`, `12.5`, `12,50`, `-12.50`, `12.50 €` (spaces around allowed) → cents; anything else → null: no partial
/// numbers (`12.`), never more than two fractional digits (`12.345` is not an amount and is never rounded), no
/// thousands separators, no words.
int? parseAmountQuery(String q) {
  final m = RegExp('^(-?)(\\d{1,$_maxAmountDigits})(?:[.,](\\d{1,2}))?\\s*€?\$').firstMatch(q.trim());
  if (m == null) return null;
  final whole = int.parse(m.group(2)!);
  final frac = m.group(3);
  final cents = whole * 100 + (frac == null ? 0 : int.parse(frac.padRight(2, '0')));
  return m.group(1)!.isEmpty ? cents : -cents;
}

/// Letters folded for matching: Croatian č ć š ž đ (and the `dj` spelling of đ) plus common Latin accents.
const _fold = {
  'č': 'c', 'ć': 'c', 'š': 's', 'ž': 'z', 'đ': 'd', //
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'æ': 'ae',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss',
};

/// [s] lower-cased with accents folded ([_fold]) and `dj` → `d`, so `Đuru` is found by `duru` and by `djuru`.
String foldText(String s) {
  final sb = StringBuffer();
  for (final ch in s.toLowerCase().runes) {
    final c = String.fromCharCode(ch);
    sb.write(_fold[c] ?? c);
  }
  return sb.toString().replaceAll('dj', 'd');
}

/// What matched a query, each list in its own display order ([searchAll]).
class SearchResult {
  /// Newest first, at most [searchTxLimit].
  final List<CategorizedTx> txs;
  final List<Goal> goals;
  final List<WishItem> wishlist;
  final List<RecurringBill> bills;
  const SearchResult({this.txs = const [], this.goals = const [], this.wishlist = const [], this.bills = const []});

  static const empty = SearchResult();

  bool get isEmpty => txs.isEmpty && goals.isEmpty && wishlist.isEmpty && bills.isEmpty;
}

/// Everything matching [query]: a case- and accent-insensitive substring ([foldText]) of a transaction's description,
/// note or category, a goal's name, a wish's name, a bill's label or category; or, when the query is an amount
/// ([parseAmountQuery]), a transaction whose `amount.abs()` is that many cents, a goal with that target or saved total,
/// a wish with that price, a bill with that expected amount. A query that is both matches either way. Deleted and
/// replaced transactions are never found. Blank query → [SearchResult.empty]. Transactions come newest first (date,
/// then id, descending), capped at [searchTxLimit]; the other lists keep their input order.
SearchResult searchAll(
  String query, {
  required List<CategorizedTx> txs,
  required List<Goal> goals,
  required List<WishItem> wishlist,
  required List<RecurringBill> bills,
}) {
  final q = foldText(query.trim());
  if (q.isEmpty) return SearchResult.empty;
  final cents = parseAmountQuery(query)?.abs();
  bool text(String? s) => s != null && foldText(s).contains(q);
  bool amount(int v) => cents != null && v.abs() == cents;

  final hits = [
    for (final t in txs)
      if (t.tx.live && (amount(t.amount) || text(t.tx.description) || text(t.tx.note) || text(t.category))) t
  ]..sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.tx.id.compareTo(a.tx.id);
    });
  return SearchResult(
    txs: hits.length > searchTxLimit ? hits.sublist(0, searchTxLimit) : hits,
    goals: [
      for (final g in goals)
        if (text(g.name) || amount(g.target) || amount(g.saved)) g
    ],
    wishlist: [
      for (final w in wishlist)
        if (text(w.name) || amount(w.price)) w
    ],
    bills: [
      for (final b in bills)
        if (text(b.label) || text(b.category) || amount(b.expectedAmount)) b
    ],
  );
}
