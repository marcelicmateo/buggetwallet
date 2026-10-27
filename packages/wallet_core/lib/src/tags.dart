// Tags (stage T1, docs/context/T1_SPEC.md). The main tag is a row's category (CategoryTable); extra tags are the
// owner's own labels (entity `tag`), given to rows by per-payee rule tags (`ruletag`) and per-row links (`txtag`).
// Everything here is pure and read time: nothing is written on import.
import 'categories.dart' show BudgetKind, Categorizer, CategoryTable, merchantKey, merchantName;
import 'models.dart';
import 'search.dart' show foldText;

/// One row of the synced `tag` entity (T1, schema 11; table `tags`). The id is `t` + 12 random hex characters.
class TagRow {
  final String id;
  final String name;

  /// Sort order (≥ 0); null sorts last.
  final int? position;
  final bool hidden;
  final bool deleted;

  const TagRow({required this.id, this.name = '', this.position, this.hidden = false, this.deleted = false});

  /// Longest name (characters, after trimming).
  static const maxName = 40;

  /// Most live tags a wallet may hold (`addTag` and `undeleteTag` check it).
  static const maxLive = 500;

  /// Not deleted and with a name (a row whose `name` field has not arrived yet is not live).
  bool get isLive => !deleted && name.trim().isNotEmpty;

  static TagRow fromRow(Map<String, Object?> r) => TagRow(
        id: r['id'] as String,
        name: r['name'] is String ? r['name'] as String : '',
        position: r['position'] is int ? r['position'] as int : null,
        hidden: r['hidden'] == 1,
        deleted: r['deleted'] == 1,
      );
}

/// The owner's tags ([TagRow]) resolved once, like [CategoryTable]. Live tags are ordered by position, then folded
/// label, then id. Of two live tags with the same folded label ([foldText]; two devices that added the same name
/// offline), the smallest id is the original and the others are [duplicateOf] it: [resolve] maps them to it, so their
/// rows count once, under the original.
class TagTable {
  /// The rows it was built from, as given.
  final List<TagRow> rows;
  final Map<String, TagRow> _rows = {};
  final List<String> _live = [];
  final Map<String, String> _dup = {};
  final Map<String, int> _index = {};

  static const _noPosition = 1 << 30;

  /// No tags.
  static final TagTable empty = TagTable.from(const []);

  TagTable.from(List<TagRow> rows) : rows = List.unmodifiable(rows) {
    for (final r in rows) {
      _rows[r.id] = r;
    }
    _live.addAll([
      for (final r in _rows.values)
        if (r.isLive) r.id
    ]);
    _live.sort((a, b) {
      var d = position(a).compareTo(position(b));
      if (d == 0) d = foldText(label(a)).compareTo(foldText(label(b)));
      return d != 0 ? d : a.compareTo(b);
    });
    final first = <String, String>{};
    for (final id in [..._live]..sort()) {
      final key = foldText(label(id));
      final have = first[key];
      if (have == null) {
        first[key] = id;
      } else {
        _dup[id] = have;
      }
    }
    var i = 0;
    for (final id in _live) {
      if (!_dup.containsKey(id)) _index[id] = i++;
    }
  }

  /// The trimmed name of [id]; an unknown id itself.
  String label(String id) {
    final n = _rows[id]?.name.trim() ?? '';
    return n.isEmpty ? id : n;
  }

  /// A known tag that is not deleted.
  bool isLive(String id) => _rows[id]?.isLive ?? false;

  /// Whether [id] is a stored tag (deleted or not).
  bool isKnown(String id) => _rows.containsKey(id);

  /// Hidden from pickers (rows that have it still show it).
  bool isHidden(String id) => _rows[id]?.hidden ?? false;

  /// The stored position, or a large value when there is none.
  int position(String id) => _rows[id]?.position ?? _noPosition;

  /// The original of a sync duplicate (same folded label among live tags), or null.
  String? duplicateOf(String id) => _dup[id];

  /// The tag [id] counts as: its original when it is a duplicate, itself when live, null when deleted or unknown.
  String? resolve(String id) => isLive(id) ? (_dup[id] ?? id) : null;

  /// [ids] each [resolve]d (dead ones dropped), without repeats, in table order; unmodifiable (P6: a split part's tags).
  List<String> resolveAll(Iterable<String> ids) {
    final out = <String>{
      for (final id in ids)
        if (resolve(id) case final r?) r
    };
    return out.isEmpty ? const [] : List.unmodifiable(_ordered(out));
  }

  /// The live tags, originals only (hidden ones included), in order.
  List<String> get ids => [
        for (final id in _live)
          if (!_dup.containsKey(id)) id
      ];

  /// The live tag ids in order, duplicates and hidden ones included (what `addTag` counts against [TagRow.maxLive]).
  List<String> get liveIds => List.unmodifiable(_live);

  /// What a picker offers: live, not hidden, not a duplicate, in order.
  List<String> pickable() => [
        for (final id in _live)
          if (!_dup.containsKey(id) && !isHidden(id)) id
      ];

  /// [ids] (resolved originals) in table order; unknown ones dropped.
  List<String> _ordered(Iterable<String> ids) => [...ids.where(_index.containsKey)]..sort((a, b) => _index[a]!.compareTo(_index[b]!));
}

/// The payee key tags go by: [merchantKey], or null for a row that has none (a hand-added row without a note, or a
/// description with nothing left after cleaning).
String? tagPayee(Tx t) {
  if (t.source == 'manual' && (t.note == null || t.note!.trim().isEmpty)) return null;
  final k = merchantKey(t);
  return k == 'x' ? null : k;
}

/// The extra tags of [t]: the live rule tags of its payee ([ruleTags], payee → tag ids) plus its links in state `on`
/// ([links], tx id → tag id → on), minus its links in state `off`. Each id is resolved through [tags]
/// ([TagTable.resolve]: a duplicate counts as its original, a dead tag is dropped). In table order; unmodifiable.
List<String> tagsOf(Tx t,
    {required TagTable tags, required Map<String, Set<String>> ruleTags, required Map<String, Map<String, bool>> links}) {
  if (ruleTags.isEmpty && (links[t.id]?.isEmpty ?? true)) return const [];
  final payee = tagPayee(t);
  final fromRules = payee == null ? null : ruleTags[payee];
  final own = links[t.id];
  if ((fromRules == null || fromRules.isEmpty) && (own == null || own.isEmpty)) return const [];
  final on = <String>{};
  final off = <String>{};
  for (final id in fromRules ?? const <String>{}) {
    if (tags.resolve(id) case final r?) on.add(r);
  }
  for (final MapEntry(key: id, value: state) in (own ?? const <String, bool>{}).entries) {
    if (tags.resolve(id) case final r?) (state ? on : off).add(r);
  }
  on.removeAll(off);
  if (on.isEmpty) return const [];
  return List.unmodifiable(tags._ordered(on));
}

/// One read of the three tag tables (`WalletRepo.tagContext`), so a whole categorize pass fills
/// [CategorizedTx.tags] without a read per row.
class TagContext {
  final TagTable tags;

  /// Payee (`merchantKey`) → live rule tag ids.
  final Map<String, Set<String>> ruleTags;

  /// Tx id → tag id → `true` for `on`, `false` for `off`.
  final Map<String, Map<String, bool>> links;

  const TagContext({required this.tags, this.ruleTags = const {}, this.links = const {}});

  static final TagContext empty = TagContext(tags: TagTable.empty);

  /// [tagsOf] for [t].
  List<String> of(Tx t) => tagsOf(t, tags: tags, ruleTags: ruleTags, links: links);

  /// The tag ids [t]'s links turn `off` (for [suggestTags]' `off`).
  Set<String> offTags(Tx t) => {
        for (final MapEntry(key: id, value: on) in (links[t.id] ?? const <String, bool>{}).entries)
          if (!on) id
      };
}

/// Extra tags to suggest for [t] (never applied): tags on at least 2 other live rows of [history] with the same payee
/// ([tagPayee]), not already on [t] (its row in [history]) and not turned off on it ([off]: the tag ids of [t]'s `off`
/// links, `TagContext.offTags`). Pickable tags only. Ordered by count, then the most recent use, then the label; at most [limit].
/// P6: expects whole payments (`Categorizer.categorize`, one row per payment), never the expanded list (`Categorizer.expand`).
List<String> suggestTags(Tx t, List<CategorizedTx> history, TagTable tags, {int limit = 5, Set<String> off = const {}}) {
  final payee = tagPayee(t);
  if (payee == null || limit <= 0) return const [];
  final pickable = tags.pickable().toSet();
  final exclude = <String>{
    for (final id in off)
      if (tags.resolve(id) case final r?) r
  };
  final count = <String, int>{};
  final last = <String, String>{};
  for (final h in history) {
    if (h.tx.id == t.id) {
      for (final id in h.tags) {
        exclude.add(tags.resolve(id) ?? id);
      }
      continue;
    }
    if (!h.tx.live || tagPayee(h.tx) != payee) continue;
    for (final id in {for (final x in h.tags) tags.resolve(x)}) {
      if (id == null || !pickable.contains(id)) continue;
      count[id] = (count[id] ?? 0) + 1;
      final l = last[id];
      if (l == null || h.date.compareTo(l) > 0) last[id] = h.date;
    }
  }
  final out = [
    for (final MapEntry(key: id, value: n) in count.entries)
      if (n >= 2 && !exclude.contains(id)) id
  ]..sort((a, b) {
      var d = count[b]!.compareTo(count[a]!);
      if (d == 0) d = last[b]!.compareTo(last[a]!);
      if (d == 0) d = foldText(tags.label(a)).compareTo(foldText(tags.label(b)));
      return d != 0 ? d : a.compareTo(b);
    });
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// [candidates] ordered: first those used with [t]'s payee on other live rows of [history], by count; then by how
/// often they are used on all live rows; then their given order. [used] gives a row's (resolved) ids.
List<String> _recommended(Tx t, List<CategorizedTx> history, List<String> candidates, Iterable<String> Function(CategorizedTx) used) {
  final payee = tagPayee(t);
  final mine = <String, int>{};
  final all = <String, int>{};
  for (final h in history) {
    if (!h.tx.live || h.tx.id == t.id) continue;
    final same = payee != null && tagPayee(h.tx) == payee;
    for (final id in used(h)) {
      all[id] = (all[id] ?? 0) + 1;
      if (same) mine[id] = (mine[id] ?? 0) + 1;
    }
  }
  final index = {for (var i = 0; i < candidates.length; i++) candidates[i]: i};
  return [...candidates]..sort((a, b) {
      var d = (mine[b] ?? 0).compareTo(mine[a] ?? 0);
      if (d == 0) d = (all[b] ?? 0).compareTo(all[a] ?? 0);
      return d != 0 ? d : index[a]!.compareTo(index[b]!);
    });
}

/// The main tags (built-in and own categories) to offer for [t]: [CategoryTable.pickable] (of [kinds] when given),
/// first those used with its payee by count, then by how often they are used overall, then the table order. A sync
/// duplicate's rows count for its original.
/// P6: expects whole payments (`Categorizer.categorize`, one row per payment), never the expanded list (`Categorizer.expand`).
List<String> recommendedMainTags(Tx t, List<CategorizedTx> history, CategoryTable table, {Set<BudgetKind>? kinds}) =>
    _recommended(t, history, table.pickable(kinds: kinds), (h) => [table.duplicateOf(h.category) ?? h.category]);

/// The extra tags to offer for [t] ([TagTable.pickable]) in the same order as [recommendedMainTags].
/// P6: expects whole payments (`Categorizer.categorize`, one row per payment), never the expanded list (`Categorizer.expand`).
List<String> recommendedTags(Tx t, List<CategorizedTx> history, TagTable tags) => _recommended(
    t,
    history,
    tags.pickable(),
    (h) => {
          for (final id in h.tags)
            if (tags.resolve(id) case final r?) r
        });

/// Shortest typed text (folded, trimmed) that [suggestCategoriesForText] looks up in the history.
const _suggestMinChars = 3;

/// Main tags to offer while the owner types a hand-added payment's [text] (Q1; never applied, never from the amount):
/// first the category the personal patterns and built-in rules give the text ([Categorizer.merchantCategory]); then
/// the categories of live rows of [history] whose folded description or note ([foldText]) holds the folded text (at
/// least 3 characters), by how many rows, then the newest row, then the id; a sync duplicate counts for its original.
/// Only what the caller's picker offers: [CategoryTable.pickable] of [Categorizer.table] (live, not hidden) of [kinds]
/// (all when null), minus [exclude]; applied to every step before [limit] cuts, so the Add expense sheet
/// (`kinds: {BudgetKind.flex}`, `exclude: {'Bank fees'}`) never gets a transfer, income or fixed tag. Each once, at
/// most [limit]. Blank text → none.
List<String> suggestCategoriesForText(String text, List<CategorizedTx> history, Categorizer c,
    {int limit = 3, Set<BudgetKind>? kinds, Set<String> exclude = const {}}) {
  final q = foldText(text.trim());
  if (q.isEmpty || limit <= 0) return const [];
  final table = c.table;
  final pickable = table.pickable(kinds: kinds).toSet()..removeAll(exclude);
  String? usable(String? id) {
    if (id == null) return null;
    final r = table.duplicateOf(id) ?? id;
    return pickable.contains(r) ? r : null;
  }

  final out = <String>[];
  if (usable(c.merchantCategory(text)) case final r?) out.add(r);
  if (q.length >= _suggestMinChars) {
    final count = <String, int>{};
    final last = <String, String>{};
    final seen = <String>{};
    for (final h in history) {
      if (!h.tx.live || !seen.add('${h.tx.id}|${h.part}')) continue;
      final note = h.partNote ?? h.tx.note;
      if (!foldText(h.tx.description).contains(q) && !(note != null && foldText(note).contains(q))) continue;
      final id = usable(h.category);
      if (id == null) continue;
      count[id] = (count[id] ?? 0) + 1;
      final l = last[id];
      if (l == null || h.date.compareTo(l) > 0) last[id] = h.date;
    }
    final ranked = [...count.keys]..sort((a, b) {
        var d = count[b]!.compareTo(count[a]!);
        if (d == 0) d = last[b]!.compareTo(last[a]!);
        return d != 0 ? d : a.compareTo(b);
      });
    for (final id in ranked) {
      if (!out.contains(id)) out.add(id);
    }
  }
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// Payee names to complete a hand-added payment's note with (Q1): the distinct merchant names ([merchantName]) of live
/// bank rows and the notes of live rows in [history] that hold the folded [prefix] ([foldText]); those starting with
/// it first, then the others, each newest first (date, then id, descending). A name counts once (folded, trimmed),
/// spelled as on its newest row. A hand-added row's name is its note only (never its category). At most [limit].
List<String> recentPayees(List<CategorizedTx> history, String prefix, {int limit = 5}) {
  if (limit <= 0) return const [];
  final q = foldText(prefix.trim());
  final rows = [
    for (final h in history)
      if (h.tx.live) h.tx
  ]..sort((a, b) {
      final d = b.date.compareTo(a.date);
      return d != 0 ? d : b.id.compareTo(a.id);
    });
  final starts = <String>[], contains = <String>[];
  final seen = <String>{};
  void consider(String? name) {
    final s = name?.trim();
    if (s == null || s.isEmpty) return;
    final f = foldText(s);
    if (!f.contains(q) || !seen.add(f)) return;
    (f.startsWith(q) ? starts : contains).add(s);
  }

  for (final t in rows) {
    if (t.source != 'manual' && !t.manual) {
      final name = merchantName(t);
      if (name != '(no description)') consider(name);
    }
    consider(t.note);
    if (starts.length >= limit) break;
  }
  final out = [...starts, ...contains];
  return out.length > limit ? out.sublist(0, limit) : out;
}
