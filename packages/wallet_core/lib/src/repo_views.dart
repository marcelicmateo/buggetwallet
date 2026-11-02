part of 'repo.dart';

/// Saved Explore views (ENG §6.3, schema 21): the synced entity `view` ([ViewCols], table `views`, id `v` + 12 hex).
/// Name 1..[ViewCols.maxName] characters, query = `SeriesQuery.toJson` text; checked on local writes only. Logs counts.
extension WalletRepoViews on WalletRepo {
  String _viewName(String name) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Give the view a name.');
    final p = ViewCols.name.problem(n);
    if (p != null) throw ArgumentError('${ViewCols.name.label}: $p');
    return n;
  }

  /// Adds a view placed last and returns its id. A blank or long name, or a query `SeriesQuery.fromJson` cannot read:
  /// [ArgumentError], nothing written.
  String addView({required String name, required String query}) {
    final n = _viewName(name);
    final p = ViewCols.query.problem(query);
    if (p != null) throw ArgumentError('${ViewCols.query.label}: $p');
    final next = (db.select('SELECT MAX(sort) AS m FROM views').first['m'] as int? ?? -1) + 1;
    final r = Random.secure();
    final id = 'v${List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join()}';
    _write([
      (ViewCols.entity, id, {'name': n, 'query': query, 'pinned': 0, 'sort': next, 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'view.add');
    return id;
  }

  /// Changes the given fields of live view [id] (null = unchanged) through [patch]: a blank name, a bad query or an
  /// unknown or deleted id is an [ArgumentError].
  void patchView(String id, {String? name, String? query, bool? pinned, int? sort}) => patch(ViewCols.entity, id, {
        if (name != null) ViewCols.name: _viewName(name),
        if (query != null) ViewCols.query: query,
        if (pinned != null) ViewCols.pinned: pinned,
        if (sort != null) ViewCols.sort: sort,
      });

  /// Deletes view [id] (Undo: [undeleteView]). Already deleted: nothing written. Unknown id: [ArgumentError].
  void deleteView(String id) => _setViewDeleted(id, true);

  /// Undo of [deleteView] (the later of the two by HLC wins). A live view: nothing written. Unknown id: [ArgumentError].
  void undeleteView(String id) => _setViewDeleted(id, false);

  void _setViewDeleted(String id, bool deleted) {
    final rs = db.select('SELECT deleted FROM views WHERE id = ?', [id]);
    if (rs.isEmpty) throw ArgumentError('No such view.');
    if ((rs.first['deleted'] == 1) == deleted) return;
    _write([
      (ViewCols.entity, id, {'deleted': deleted ? 1 : 0})
    ]);
    logEvent(_log, Level.INFO, deleted ? 'view.delete' : 'repo.undelete', {if (!deleted) 'entity': 'view'});
  }

  /// The live views by sort (none last), then name, then id.
  List<SavedView> views() => [
        for (final r in db.select('SELECT * FROM views WHERE deleted = 0 ORDER BY sort IS NULL, sort, name, id'))
          SavedView(
            id: r['id'] as String,
            name: ViewCols.name.read(r) ?? '',
            query: ViewCols.query.read(r) ?? '',
            pinned: ViewCols.pinned.read(r) ?? false,
            sort: ViewCols.sort.read(r),
          )
      ];
}
