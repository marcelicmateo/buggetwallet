// Own categories (main tags) in the controller (P1; T1 replaced subcategories by tags, core API in docs/context/P1_SPEC.md). A `part` of controller.dart so it can
// use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never labels or ids.
part of 'controller.dart';

final _catLog = Logger('bw.categories.ui');

extension CategoriesDb on WalletController {
  /// The built-in categories (main tags) plus the owner's own: labels, kinds, hidden. Rebuilt on every [reload] (it comes from the
  /// categorizer), so it is always the one the shown totals were computed with.
  CategoryTable get categoryTable => categorizer.table;

  /// Adds a main tag and returns its id. A refused value is an [ArgumentError] with a readable message.
  Future<String> addOwnCategory({required String name, required BudgetKind kind}) async {
    final id = await repo.addCategory(name: name, kind: kind);
    logEvent(_catLog, Level.INFO, 'categories.add', {'kind': kind.name});
    _changed();
    return id;
  }

  void renameCategory(String id, String name) {
    repo.patch(CategoryCols.entity, id, {CategoryCols.name: name});
    logEvent(_catLog, Level.INFO, 'categories.rename', {'builtIn': categories.containsKey(id)});
    _changed();
  }

  void setCategoryHidden(String id, bool hidden) {
    repo.patch(CategoryCols.entity, id, {CategoryCols.hidden: hidden});
    logEvent(_catLog, Level.INFO, 'categories.hide', {'hidden': hidden, 'builtIn': categories.containsKey(id)});
    _changed();
  }

  /// The ids [id] is ordered among in the Main tags panel: the main tags of its kind, in table order.
  List<String> categorySiblings(String id) {
    final t = categoryTable;
    final k = t.kindOf(id);
    return [
      for (final s in t.topLevelIds)
        if (t.kindOf(s) == k) s
    ];
  }

  /// Moves [id] one place up ([delta] -1) or down (+1) among [categorySiblings]. The positions of the group are handed out again
  /// in the new order (only the ones that change are written), so ties never leave a move without effect.
  void moveCategory(String id, int delta) {
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
        repo.patch(CategoryCols.entity, order[k], {CategoryCols.position: pos});
        written++;
      }
    }
    logEvent(_catLog, Level.INFO, 'categories.move', {'written': written, 'group': g.length});
    _changed();
  }

  /// Deletes an own main tag.
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

  /// Saves plan lines (a fixed category of your own -> cents a month; null removes the line). Each goes through core's `setPlanLine`.
  /// Logs the count only.
  void savePlanLines(Map<String, int?> lines) {
    for (final e in lines.entries) {
      repo.setPlanLine(e.key, e.value);
    }
    logEvent(_catLog, Level.INFO, 'planLines.saved', {'count': lines.length});
    _changed();
  }

  /// The category the add-expense sheet starts on: the last one used on this device while it is still live and offered.
  String? get lastExpensePick {
    final c = repo.localValue('lastExpenseCategory');
    final t = categoryTable;
    return c != null && c != 'Bank fees' && t.pickable(kinds: const {BudgetKind.flex}).contains(c) ? c : null;
  }
}
