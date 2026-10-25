// Own categories and subcategories in the controller (P1, core API in docs/context/P1_SPEC.md). A `part` of controller.dart so it can
// use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never labels or ids.
part of 'controller.dart';

final _catLog = Logger('bw.categories.ui');

extension CategoriesDb on WalletController {
  /// The built-in categories plus the owner's own: labels, kinds, children, hidden. Rebuilt on every [reload] (it comes from the
  /// categorizer), so it is always the one the shown totals were computed with.
  CategoryTable get categoryTable => categorizer.table;

  /// Adds a main category (or a subcategory when [parent] is set; its kind follows the parent) and returns its id. A refused
  /// value is an [ArgumentError] with a readable message.
  Future<String> addOwnCategory({required String name, required BudgetKind kind, String? parent}) async {
    final id = await repo.addCategory(name: name, kind: parent == null ? kind : categoryTable.kindOf(parent), parent: parent);
    logEvent(_catLog, Level.INFO, 'categories.add', {'kind': kind.name, 'child': parent != null});
    _changed();
    return id;
  }

  Future<void> renameCategory(String id, String name) async {
    await repo.updateCategory(id, name: name);
    logEvent(_catLog, Level.INFO, 'categories.rename', {'builtIn': categories.containsKey(id)});
    _changed();
  }

  Future<void> setCategoryHidden(String id, bool hidden) async {
    await repo.updateCategory(id, hidden: hidden);
    logEvent(_catLog, Level.INFO, 'categories.hide', {'hidden': hidden, 'builtIn': categories.containsKey(id)});
    _changed();
  }

  /// The ids [id] is ordered among in the Categories panel: its siblings of the same kind (a child's siblings, or the top-level
  /// categories of its kind), in table order.
  List<String> categorySiblings(String id) {
    final t = categoryTable;
    final p = t.parentOf(id);
    if (p != null) return t.childrenOf(p);
    final k = t.kindOf(id);
    return [
      for (final s in t.topLevelIds)
        if (t.kindOf(s) == k) s
    ];
  }

  /// Moves [id] one place up ([delta] -1) or down (+1) among [categorySiblings]. The positions of the group are handed out again
  /// in the new order (only the ones that change are written), so ties never leave a move without effect.
  Future<void> moveCategory(String id, int delta) async {
    final t = categoryTable;
    final g = categorySiblings(id);
    final i = g.indexOf(id), j = i + delta;
    if (i < 0 || j < 0 || j >= g.length) return;
    final order = [...g];
    order[i] = g[j];
    order[j] = g[i];
    final slots = [for (final s in g) t.position(s)]..sort();
    final distinct = slots.toSet().length == slots.length && slots.last < (1 << 30);
    final base = slots.first < (1 << 30) ? slots.first : 0;
    var written = 0;
    for (var k = 0; k < order.length; k++) {
      final pos = distinct ? slots[k] : base + k;
      if (t.position(order[k]) != pos) {
        await repo.updateCategory(order[k], position: pos);
        written++;
      }
    }
    logEvent(_catLog, Level.INFO, 'categories.move', {'written': written, 'group': g.length});
    _changed();
  }

  /// Deletes an own category; an [ArgumentError] while it still has subcategories.
  Future<void> deleteOwnCategory(String id) async {
    await repo.deleteCategory(id);
    logEvent(_catLog, Level.INFO, 'categories.delete');
    _changed();
  }

  /// Undo of [deleteOwnCategory].
  Future<void> undeleteOwnCategory(String id) async {
    await repo.undeleteCategory(id);
    logEvent(_catLog, Level.INFO, 'categories.undelete');
    _changed();
  }

  /// The category the add-expense sheet starts on: the last one used on this device while it is still live and offered.
  String? get lastExpensePick {
    final c = repo.localValue('lastExpenseCategory');
    final t = categoryTable;
    return c != null && c != 'Bank fees' && t.pickable(kinds: const {BudgetKind.flex}).contains(c) ? c : null;
  }
}
