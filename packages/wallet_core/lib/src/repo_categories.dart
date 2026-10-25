part of 'repo.dart';

/// The owner's own categories and subcategories, and overrides of the built-ins (P1, entity `category`, schema 10;
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

  /// Throws when a live sibling (top-level when [parent] is null, else a child of [parent]) other than [exceptId]
  /// already has [label], case and accents ignored ([foldText]).
  static void _checkUniqueLabel(CategoryTable t, String label, String? parent, {String? exceptId}) {
    final key = foldText(label.trim());
    for (final s in parent == null ? t.topLevelIds : t.childrenOf(parent)) {
      if (s != exceptId && foldText(t.label(s).trim()) == key) {
        throw ArgumentError(
            parent == null ? 'There is already a category with this name.' : 'There is already a subcategory with this name here.');
      }
    }
  }

  /// [parent] must be a live top-level category (not [self]) of [kind].
  static void _checkParent(CategoryTable t, String parent, BudgetKind kind, {String? self}) {
    if (parent == self) throw ArgumentError('A category cannot be its own parent.');
    if (!t.isLive(parent)) throw ArgumentError('The parent category does not exist.');
    if (t.parentOf(parent) != null) throw ArgumentError('Subcategories go one level deep: pick a main category as the parent.');
    if (t.kindOf(parent) != kind) throw ArgumentError('A subcategory has the same kind as its parent.');
  }

  /// The next free position among [parent]'s live children (top-level when null): the largest one + 1.
  static int _nextPosition(CategoryTable t, String? parent) {
    var next = 0;
    for (final s in parent == null ? t.topLevelIds : t.childrenOf(parent)) {
      final p = t.position(s);
      if (p < (1 << 30) && p >= next) next = p + 1;
    }
    return next;
  }

  int _liveCustomCount(CategoryTable t) => t.rows.where((r) => !r.isOverride && !r.deleted).length;

  /// Adds a custom category and returns its id (`k` + 12 hex). With [parent] it is a subcategory: the parent must be a
  /// live top-level category of the same [kind]. A bad name, a label already used among its siblings, a bad parent or
  /// more than [CategoryRow.maxCustom] live custom categories: [ArgumentError].
  Future<String> addCategory({required String name, required BudgetKind kind, String? parent}) async {
    final n = _checkName(name);
    final t = categoryTable();
    if (_liveCustomCount(t) >= CategoryRow.maxCustom) throw ArgumentError('You can have at most ${CategoryRow.maxCustom} own categories.');
    if (parent != null) _checkParent(t, parent, kind);
    _checkUniqueLabel(t, n, parent);
    final id = _newCategoryId();
    _write([
      ('category', id, {'name': n, 'kind': kind.name, 'parent': parent, 'position': _nextPosition(t, parent), 'hidden': 0, 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'category.add', {'kind': kind.name, 'child': parent != null});
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
  /// [position] and [hidden] only; a parent there is an [ArgumentError]. On a custom one [parent] moves it under a
  /// live top-level category of the same kind (refused while it has live children: one level only) and
  /// [clearParent] makes it top-level. A label already used at the target place, a negative position, or an unknown
  /// or deleted id: [ArgumentError].
  Future<void> updateCategory(String id, {String? name, int? position, bool? hidden, String? parent, bool clearParent = false}) async {
    final t = categoryTable();
    final builtIn = categories.containsKey(id);
    if (!builtIn && !t.isLive(id)) throw ArgumentError('No such category.');
    if (builtIn && (parent != null || clearParent)) throw ArgumentError('A built-in category cannot become a subcategory.');
    if (position != null && position < 0) throw ArgumentError('Bad position.');
    final n = name == null ? null : _checkName(name);
    final moving = !builtIn && (clearParent || (parent != null && parent != t.parentOf(id)));
    final target = clearParent ? null : (parent ?? t.parentOf(id));
    if (moving && target != null) {
      if (t.childrenOf(id).isNotEmpty) throw ArgumentError('A category with subcategories cannot become a subcategory.');
      _checkParent(t, target, t.kindOf(id), self: id);
    }
    if (n != null || moving) _checkUniqueLabel(t, n ?? t.label(id), target, exceptId: id);
    final fields = <String, Object?>{
      if (n != null) 'name': n,
      if (position != null) 'position': position,
      if (hidden != null) 'hidden': hidden ? 1 : 0,
      if (moving) 'parent': target,
      // A row moved to another place goes last there unless a position was given.
      if (moving && position == null) 'position': _nextPosition(t, target),
    };
    if (fields.isEmpty) return;
    _write([('category', id, fields)]);
    logEvent(_log, Level.INFO, 'category.update', {'fields': fields.length, 'builtIn': builtIn, 'moved': moving});
  }

  /// Removes a custom category (`deleted: 1`; the row stays for [undeleteCategory], and rows pointing at it fall back
  /// until then). A built-in (hide it instead), an unknown id, or one with live subcategories: [ArgumentError].
  Future<void> deleteCategory(String id) async {
    if (categories.containsKey(id)) throw ArgumentError('A built-in category cannot be deleted; hide it instead.');
    final t = categoryTable();
    if (!t.isCustom(id)) throw ArgumentError('No such category.');
    if (!t.isLive(id)) return;
    if (t.childrenOf(id).isNotEmpty) throw ArgumentError('Move or delete its subcategories first.');
    _write([
      ('category', id, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'category.delete', {'kind': t.kindOf(id).name});
  }

  /// Undo of [deleteCategory]: writes `deleted: 0` (synced; the later write by HLC wins). A live or built-in id:
  /// nothing is written. Unknown id, a label taken in between at its place, or [CategoryRow.maxCustom] live custom
  /// categories already: [ArgumentError].
  Future<void> undeleteCategory(String id) async {
    if (categories.containsKey(id)) return;
    final t = categoryTable();
    if (!t.isCustom(id)) throw ArgumentError('No such category.');
    if (t.isLive(id)) return;
    if (_liveCustomCount(t) >= CategoryRow.maxCustom) throw ArgumentError('You can have at most ${CategoryRow.maxCustom} own categories.');
    final after = CategoryTable.from([
      for (final r in t.rows)
        r.id == id ? CategoryRow(id: r.id, name: r.name, kind: r.kind, parent: r.parent, position: r.position, hidden: r.hidden) : r,
    ]);
    _checkUniqueLabel(after, after.label(id), after.parentOf(id), exceptId: id);
    _write([
      ('category', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'category'});
  }

  /// The stored category rows (custom ones and built-in overrides), ordered by position, then id; deleted custom
  /// rows only with [includeDeleted] (an override's `deleted` is ignored: it is always listed).
  List<CategoryRow> categoryRows({bool includeDeleted = false}) => [
        for (final r in db.select('SELECT * FROM categories ORDER BY position, id').map(CategoryRow.fromRow))
          if (includeDeleted || !r.deleted || r.isOverride) r,
      ];
}
