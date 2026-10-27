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

/// Q7: what [searchAll]'s payments must also be. Every set field narrows; [isEmpty] = no filter. Amount bounds are on
/// the payment's absolute amount in the list's currency (`amount.abs()`, whole payment), inclusive; [from]/[to] are
/// inclusive `YYYY-MM-DD` dates; [categories] = main tag ids, a split payment fits when its own main tag or one part's
/// is in it; [hasAttachment] true/false = with/without a live attached file (`searchAll`'s `attachedTx`); [split]
/// true/false = a payment counted in parts or not; [uncategorised] = rows whose main tag the owner never chose
/// (`Tx.category` null, and not split: a split's parts are chosen).
class SearchFilter {
  final int? minCents, maxCents;
  final String? from, to;
  final Set<String> categories;
  final bool? hasAttachment;
  final bool? split;
  final bool uncategorised;
  const SearchFilter(
      {this.minCents,
      this.maxCents,
      this.from,
      this.to,
      this.categories = const {},
      this.hasAttachment,
      this.split,
      this.uncategorised = false});

  /// Nothing set: [searchAll] behaves as without a filter.
  bool get isEmpty =>
      minCents == null &&
      maxCents == null &&
      from == null &&
      to == null &&
      categories.isEmpty &&
      hasAttachment == null &&
      split == null &&
      !uncategorised;

  /// Whether payment [w] (the whole row) fits; [parts] = its parts' main tags (as originals) when it is split,
  /// [attached] whether it has a live attachment, [wanted] = [categories] as originals, [original] maps a main tag.
  bool _fits(CategorizedTx w, Set<String>? parts, bool attached, Set<String> wanted, String Function(String) original) {
    final a = w.amount.abs();
    if (minCents != null && a < minCents!) return false;
    if (maxCents != null && a > maxCents!) return false;
    if (from != null && w.date.compareTo(from!) < 0) return false;
    if (to != null && w.date.compareTo(to!) > 0) return false;
    final isSplit = parts != null;
    if (split != null && split != isSplit) return false;
    if (hasAttachment != null && hasAttachment != attached) return false;
    if (wanted.isNotEmpty && !wanted.contains(original(w.category)) && !(parts?.any(wanted.contains) ?? false)) return false;
    if (uncategorised && (w.tx.category != null || isSplit)) return false;
    return true;
  }
}

/// Where [query] (trimmed, folded with [foldText]) occurs in [text], as `(start, end)` spans of [text] itself (end
/// exclusive), in order and not overlapping, for showing the match in bold. A letter whose fold is longer or shorter
/// (`ß` → `ss`, `dj` → `d`) is mapped back to the characters it came from. Blank query → none.
List<(int, int)> matchSpans(String text, String query) {
  final q = foldText(query.trim());
  if (q.isEmpty || text.isEmpty) return const [];
  final lower = text.toLowerCase();
  if (lower.length != text.length) {
    // A case mapping that changes the length (rare, e.g. `İ`): the whole text when it matches, no positions.
    return foldText(text).contains(q) ? [(0, text.length)] : const [];
  }
  // [text] folded code unit by code unit ([_fold] keys are single units), with each folded unit's source index.
  final folded = StringBuffer();
  final src = <int>[];
  for (var i = 0; i < lower.length; i++) {
    final c = lower[i];
    final f = _fold[c] ?? c;
    for (var k = 0; k < f.length; k++) {
      folded.write(f[k]);
      src.add(i);
    }
  }
  // `dj` → `d`, as foldText does after the letters.
  var s = folded.toString();
  final map = <int>[];
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == 'd' && i + 1 < s.length && s[i + 1] == 'j') {
      sb.write('d');
      map.add(src[i]);
      i++;
      continue;
    }
    sb.write(s[i]);
    map.add(src[i]);
  }
  s = sb.toString();
  final out = <(int, int)>[];
  var at = s.indexOf(q);
  while (at >= 0) {
    final end = at + q.length;
    // The span ends where the next folded letter's source starts, so it covers the whole source letter (`ß`) and the
    // `j` of a folded `dj`.
    var e = map[end - 1] + 1;
    if (end >= map.length) {
      e = text.length;
    } else if (map[end] > e) {
      e = map[end];
    }
    final start = map[at];
    if (out.isNotEmpty && start < out.last.$2) {
      out[out.length - 1] = (out.last.$1, e);
    } else {
      out.add((start, e));
    }
    at = s.indexOf(q, end);
  }
  return out;
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
///
/// Q7: a [filter] that is not [SearchFilter.isEmpty] keeps only the payments that fit it and returns payments only (the
/// other lists stay empty); with a blank query it lists every live payment that fits. [attachedTx] = the ids of the
/// payments with a live attachment, for [SearchFilter.hasAttachment]: fill it from `WalletRepoBills.attachedTxIds()`
/// ([billsDb] never holds attachments: `bills()` leaves them out). With [table], [SearchFilter.categories] and the rows'
/// main tags compare as their originals ([CategoryTable.duplicateOf]), so a row on a sync duplicate is found by its twin.
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
  SearchFilter? filter,
  Set<String> attachedTx = const {},
}) {
  final q = foldText(query.trim());
  final f = filter == null || filter.isEmpty ? null : filter;
  if (q.isEmpty && f == null) return SearchResult.empty;
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
  // Q7: the filter, decided once per payment on its whole row (a split's parts' main tags count for [SearchFilter.categories]).
  final fits = <String, bool>{};
  String original(String c) => table?.duplicateOf(c) ?? c;
  final wanted = f == null ? const <String>{} : {for (final c in f.categories) original(c)};
  final partCats = <String, Set<String>>{};
  if (f != null) {
    for (final t in txs) {
      if (t.isPart) partCats.putIfAbsent(t.tx.id, () => {}).add(original(t.category));
    }
  }
  for (final t in txs) {
    final id = t.tx.id;
    if (!t.tx.live) continue;
    if (f != null &&
        !(fits[id] ??= f._fits(t.isPart ? t.whole ?? CategorizedTx(t.tx, t.category, t.kind, tags: t.tags) : t, partCats[id],
            attachedTx.contains(id), wanted, original))) {
      continue;
    }
    if (!t.isPart) {
      if (payment(t)) found[id] = t;
      continue;
    }
    final w = t.whole ?? CategorizedTx(t.tx, t.category, t.kind, tags: t.tags, iou: t.iou);
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
  final shown = hits.length > searchTxLimit ? hits.sublist(0, searchTxLimit) : hits;
  final parts = matchedPart.isEmpty
      ? const <String, int>{}
      : {
          for (final h in shown)
            if (matchedPart[h.tx.id] case final p?) h.tx.id: p
        };
  if (f != null) return SearchResult(txs: shown, matchedPart: parts);
  return SearchResult(
    txs: shown,
    matchedPart: parts,
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
