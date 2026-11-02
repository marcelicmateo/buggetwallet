part of 'repo.dart';

/// The owner's own categories (main tags), and overrides of the built-ins (P1, entity `category`, schema 10;
/// see [CategoryRow] and [CategoryTable]). Every rule is an [ArgumentError] with an owner-readable message. Logs carry
/// counts and kinds only, never labels.
extension WalletRepoCategories on WalletRepo {
  /// The trimmed [name], or an [ArgumentError] when it is empty or longer than [CategoryRow.maxName] characters.
  static String _checkName(String name) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Give the category a name.');
    if (n.runes.length > CategoryRow.maxName) throw ArgumentError('The category name is limited to ${CategoryRow.maxName} characters.');
    return n;
  }

  /// Throws when a live category not in [except] already has [label], case and accents ignored ([foldText]).
  static void _checkUniqueLabel(CategoryTable t, String label, {Set<String> except = const {}}) {
    final key = foldText(label.trim());
    for (final s in t.topLevelIds) {
      if (!except.contains(s) && foldText(t.label(s).trim()) == key) throw ArgumentError('There is already a category with this name.');
    }
  }

  /// The next free position: the largest live one + 1.
  static int _nextPosition(CategoryTable t) {
    var next = 0;
    for (final s in t.topLevelIds) {
      final p = t.position(s);
      if (p < (1 << 30) && p >= next) next = p + 1;
    }
    return next;
  }

  /// [id] and the live sync duplicates of it ([CategoryTable.duplicateOf]). A duplicate itself is acted on alone (the
  /// owner cleaning up the copy), an original with its whole group.
  static List<String> _group(CategoryTable t, String id) => [id, ...t.topLevelIds.where((x) => x != id && t.duplicateOf(x) == id)];

  int _liveCustomCount(CategoryTable t) => t.rows.where((r) => r.isLiveCustom).length;

  /// Adds a custom category (a main tag) and returns its id (`k` + 12 hex). A [parent] is refused (T1: subcategories
  /// were replaced by tags). A bad name, a label already used, or more than [CategoryRow.maxCustom] live custom
  /// categories: [ArgumentError].
  Future<String> addCategory({required String name, required BudgetKind kind, String? parent}) async {
    if (parent != null) throw ArgumentError('Use a tag for this.');
    final n = _checkName(name);
    final t = categoryTable();
    if (_liveCustomCount(t) >= CategoryRow.maxCustom) throw ArgumentError('You can have at most ${CategoryRow.maxCustom} own categories.');
    _checkUniqueLabel(t, n);
    final id = _newCategoryId();
    _write([
      ('category', id, {'name': n, 'kind': kind.name, 'position': _nextPosition(t), 'hidden': 0, 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'category.add', {'kind': kind.name});
    return id;
  }

  /// `k` + 12 random hex characters: never a built-in name, never seen before.
  String _newCategoryId() {
    final r = Random.secure();
    final sb = StringBuffer('k');
    for (var i = 0; i < 12; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  /// Changes the given fields only (null = unchanged). On a built-in id it writes an override: [name] (the label),
  /// [position] and [hidden] only. The change goes to [id]'s whole sync duplicate group, so the category the owner
  /// sees changes as one. A [parent] is refused (T1: use a tag); [clearParent] is accepted and does nothing (every
  /// category is top-level). A label already used, a negative position, or an unknown or deleted id: [ArgumentError].
  /// A thin wrapper over [patch] (F2).
  Future<void> updateCategory(String id, {String? name, int? position, bool? hidden, String? parent, bool clearParent = false}) async =>
      patch(CategoryCols.entity, id, {
        if (parent != null) CategoryCols.parent: parent else if (clearParent) CategoryCols.parent: clearValue,
        if (name != null) CategoryCols.name: name,
        if (position != null) CategoryCols.position: position,
        if (hidden != null) CategoryCols.hidden: hidden,
      });

  static const _categoryEdited = <Col>{CategoryCols.parent, CategoryCols.name, CategoryCols.position, CategoryCols.hidden};

  /// [patch] of a category: [updateCategory]'s rules, written to [id]'s whole sync duplicate group (a parent is refused,
  /// clearing it does nothing; position none = the default order).
  int _patchCategory(String id, Map<Col, Object?> v) {
    WalletRepoPatch._needValues(v);
    if (v[CategoryCols.parent] != null) throw ArgumentError('Use a tag for this.');
    final t = categoryTable();
    final builtIn = categories.containsKey(id);
    if (!builtIn && !t.isLive(id)) throw ArgumentError('No such category.');
    final name = v[CategoryCols.name] as String?, position = v[CategoryCols.position] as int?, hidden = v[CategoryCols.hidden] as bool?;
    if (position != null && position < 0) throw ArgumentError('Bad position.');
    final n = name == null ? null : _checkName(name);
    final group = _group(t, id);
    if (n != null) _checkUniqueLabel(t, n, except: group.toSet());
    final fields = <String, Object?>{
      if (n != null) 'name': n,
      if (v.containsKey(CategoryCols.position)) 'position': position,
      if (hidden != null) 'hidden': hidden ? 1 : 0,
      ..._patchRest(v, _categoryEdited),
    };
    if (fields.isEmpty) return 0;
    _write([for (final g in group) ('category', g, fields)]);
    logEvent(_log, Level.INFO, 'category.update', {'fields': fields.length, 'builtIn': builtIn, 'group': group.length});
    return fields.length;
  }

  /// Removes a custom category (`deleted: 1`; the row stays for [undeleteCategory], and rows pointing at it fall back
  /// until then), with the custom members of its sync duplicate group. A built-in (hide it instead) or an unknown id:
  /// [ArgumentError].
  Future<void> deleteCategory(String id) async {
    if (categories.containsKey(id)) throw ArgumentError('A built-in category cannot be deleted; hide it instead.');
    final t = categoryTable();
    if (!t.isCustom(id)) throw ArgumentError('No such category.');
    if (!t.isLive(id)) return;
    final group = [
      for (final g in _group(t, id))
        if (t.isCustom(g)) g
    ];
    _write([
      for (final g in group) ('category', g, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'category.delete', {'kind': t.kindOf(id).name, 'group': group.length});
  }

  /// Undo of [deleteCategory]: writes `deleted: 0` for [id] and every deleted custom category with the same folded
  /// label that the same delete removed (its duplicate group, the same `deleted` clock; synced, the later write by HLC
  /// wins). A live or built-in id: nothing
  /// is written. Unknown id, a label taken in between, or more than [CategoryRow.maxCustom] live custom categories
  /// after it: [ArgumentError].
  Future<void> undeleteCategory(String id) async {
    if (categories.containsKey(id)) return;
    final t = categoryTable();
    if (!t.isCustom(id)) throw ArgumentError('No such category.');
    if (t.isLive(id)) return;
    final key = foldText(t.label(id).trim());
    final together = _deletedWith('category', id);
    final group = {
      id,
      for (final r in t.rows)
        if (!r.isOverride && r.deleted && r.kind != null && together.contains(r.id) && foldText(t.label(r.id).trim()) == key) r.id
    };
    if (_liveCustomCount(t) + group.length > CategoryRow.maxCustom) {
      throw ArgumentError('You can have at most ${CategoryRow.maxCustom} own categories.');
    }
    _checkUniqueLabel(t, t.label(id));
    _write([
      for (final g in group) ('category', g, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'category', 'group': group.length});
  }

  /// The stored category rows (custom ones and built-in overrides), ordered by position, then id; deleted custom
  /// rows only with [includeDeleted] (an override's `deleted` is ignored: it is always listed).
  List<CategoryRow> categoryRows({bool includeDeleted = false}) => [
        for (final r in db.select('SELECT * FROM categories ORDER BY position, id').map(CategoryRow.fromRow))
          if (includeDeleted || !r.deleted || r.isOverride) r,
      ];
}
