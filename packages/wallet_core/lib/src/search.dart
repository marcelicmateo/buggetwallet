/// Search over everything in the wallet. Pure: the caller passes the lists it shows.
library;

import 'bills.dart';
import 'categories.dart' show CategoryTable;
import 'models.dart';
import 'schema.dart';
import 'tags.dart' show TagTable;

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

  /// Planned costs (§4.3), in input order.
  final List<PlannedCost> planned;

  /// Stored bills (receipts, slips), in input order.
  final List<Bill> billsDb;

  /// Matches among the raw rows passed as [searchAll]'s `rows` (entity → matching rows, input order; see [searchRows]).
  final Map<String, List<Map<String, Object?>>> rows;

  /// P6: tx id → the 0-based part of a split payment in [txs] that matched, when only a part did (its note, main tag,
  /// tags or amount); absent when the payment itself matched.
  final Map<String, int> matchedPart;
  const SearchResult(
      {this.txs = const [],
      this.matchedPart = const {},
      this.goals = const [],
      this.wishlist = const [],
      this.bills = const [],
      this.planned = const [],
      this.billsDb = const [],
      this.rows = const {}});

  static const empty = SearchResult();

  bool get isEmpty =>
      txs.isEmpty &&
      goals.isEmpty &&
      wishlist.isEmpty &&
      bills.isEmpty &&
      planned.isEmpty &&
      billsDb.isEmpty &&
      rows.values.every((l) => l.isEmpty);
}

/// The names of the columns of [entity] that search looks at (flagged `searchable` in [entitySchema]): text columns
/// by folded substring, integer columns by exact amount. Unknown entity → none.
List<String> searchableColumns(String entity) => [
      for (final c in entitySchema[entity]?.columns ?? const <ColumnDef>[])
        if (c.searchable) c.name
    ];

/// The rows of [entity] (maps as `SELECT *` returns them) matching [query] on its searchable columns ([searchableColumns]):
/// a text column that holds the folded query ([foldText]) or, when the query is an amount ([parseAmountQuery]), an
/// integer column whose `abs()` is that many cents. A row whose `deleted` is 1 is never found. Input order. Any entity
/// flagged searchable in the schema is searched this way without a parameter of its own on [searchAll].
List<Map<String, Object?>> searchRows(String entity, String query, Iterable<Map<String, Object?>> rows) {
  final q = foldText(query.trim());
  if (q.isEmpty) return const [];
  final cols = [
    for (final c in entitySchema[entity]?.columns ?? const <ColumnDef>[])
      if (c.searchable) c
  ];
  if (cols.isEmpty) return const [];
  final cents = parseAmountQuery(query)?.abs();
  bool hit(Map<String, Object?> r) {
    if (r['deleted'] == 1) return false;
    if (entity == 'bill' && r['source'] == 'attachment') return false; // P16b: listed on its payment only
    for (final c in cols) {
      final v = r[c.name];
      if (c.type == ColumnType.text) {
        if (v is String && foldText(v).contains(q)) return true;
      } else if (cents != null && v is int && v.abs() == cents) {
        return true;
      }
    }
    return false;
  }

  return [
    for (final r in rows)
      if (hit(r)) r
  ];
}

/// Everything matching [query]: a case- and accent-insensitive substring ([foldText]) of a transaction's description,
/// note or category, a goal's name, a wish's name, a bill's label or category; or, when the query is an amount
/// ([parseAmountQuery]), a transaction whose `amount.abs()` is that many cents, a goal with that target or saved total,
/// a wish with that price, a bill with that expected amount; a planned cost by title or category, or its exact amount
/// (deleted ones never); a stored bill ([billsDb], deleted ones never) by payee, description or an item name, or its
/// exact total. A query that is both matches either way. Deleted and
/// replaced transactions are never found. Blank query → [SearchResult.empty]. Transactions come newest first (date,
/// then id, descending), capped at [searchTxLimit]; the other lists keep their input order. [rows] (entity → raw rows)
/// are searched on the entity's searchable columns ([searchRows]) into [SearchResult.rows]. With [table], a
/// category also matches by its label ([CategoryTable.label], folded), so a custom category is found by its name. With
/// [tags], a transaction also matches when the label of one of its extra tags ([CategorizedTx.tags],
/// [TagTable.label]) holds the query.
///
/// P6: [txs] is the expanded list (`Categorizer.expand`). A part also matches by its own note, main tag, tags and
/// amount; a payment is found once, as its whole row ([CategorizedTx.whole]: whole amount and main tag). When only a
/// part matched (not the payment's own text, note, amount, main tag or tags), [SearchResult.matchedPart] names it.
SearchResult searchAll(
  String query, {
  required List<CategorizedTx> txs,
  required List<Goal> goals,
  required List<WishItem> wishlist,
  required List<RecurringBill> bills,
  List<PlannedCost> planned = const [],
  List<Bill> billsDb = const [],
  Map<String, Iterable<Map<String, Object?>>> rows = const {},
  CategoryTable? table,
  TagTable? tags,
}) {
  final q = foldText(query.trim());
  if (q.isEmpty) return SearchResult.empty;
  final cents = parseAmountQuery(query)?.abs();
  bool text(String? s) => s != null && foldText(s).contains(q);
  bool amount(int v) => cents != null && v.abs() == cents;
  bool category(String? c) => text(c) || (c != null && table != null && text(table.label(c)));
  bool tagged(CategorizedTx t) => tags != null && t.tags.any((g) => text(tags.label(g)));

  // P15: a converted row (`inHomeCurrency`) is also found by the bank's own figure ([CategorizedTx.originalAmount]).
  bool amounts(CategorizedTx t) => amount(t.amount) || (t.originalAmount != null && amount(t.originalAmount!));
  bool payment(CategorizedTx w) => amounts(w) || text(w.tx.description) || text(w.tx.note) || category(w.category) || tagged(w);
  bool part(CategorizedTx t) => amounts(t) || text(t.partNote) || category(t.category) || tagged(t);
  final found = <String, CategorizedTx>{};
  final matchedPart = <String, int>{};
  final paymentHit = <String, bool>{};
  for (final t in txs) {
    final id = t.tx.id;
    if (!t.tx.live) continue;
    if (!t.isPart) {
      if (payment(t)) found[id] = t;
      continue;
    }
    final w = t.whole ?? CategorizedTx(t.tx, t.category, t.kind, tags: t.tags);
    if (paymentHit[id] ??= payment(w)) {
      found[id] ??= w;
    } else if (!matchedPart.containsKey(id) && part(t)) {
      found[id] = w;
      matchedPart[id] = t.part!;
    }
  }
  final hits = [...found.values]..sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.tx.id.compareTo(a.tx.id);
    });
  return SearchResult(
    txs: hits.length > searchTxLimit ? hits.sublist(0, searchTxLimit) : hits,
    matchedPart: matchedPart.isEmpty
        ? const {}
        : {
            for (final h in hits.take(searchTxLimit))
              if (matchedPart[h.tx.id] case final p?) h.tx.id: p
          },
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
        if (text(b.label) || category(b.category) || amount(b.expectedAmount)) b
    ],
    planned: [
      for (final p in planned)
        if (!p.deleted && (text(p.title) || category(p.category) || (p.amount != null && amount(p.amount!)))) p
    ],
    billsDb: [
      for (final b in billsDb)
        if (!b.deleted &&
            !b.isAttachment &&
            (text(b.payee) || text(b.description) || b.items.any((i) => text(i.name)) || (b.total != null && amount(b.total!))))
          b
    ],
    rows: {for (final e in rows.entries) e.key: searchRows(e.key, query, e.value)},
  );
}
