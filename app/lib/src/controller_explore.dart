// Explore (ENG E4) and Project (E5) in the controller. A `part` of controller.dart so it can use the cache and `_changed`. Core does the
// sums (`runQuery`, `heatmap`, `moveTogether`, `projectStats`); this file only caches them per data version and writes views and tags.
//
// Privacy: logs carry counts and enum words only, never series, view or tag names.
part of 'controller.dart';

final _exLog = Logger('bw.explore');

/// One thing the "+" picker offers as a series.
class SeriesChoice {
  final SeriesKey key;
  final String label;
  const SeriesChoice(this.key, this.label);
}

/// One row of a project's "What it went on": a main tag (or "Other"), its cents, and whether it is in the bar (a refund is not).
class ProjectPart {
  final String label;
  final int cents;
  final bool inBar;
  const ProjectPart(this.label, this.cents, this.inBar);
}

/// The rows of "What it went on" (the five biggest main tags, the rest as "Other": they add up to the project total) and the sum
/// the bar's widths are shares of (the positive rows only).
class ProjectSplit {
  final List<ProjectPart> parts;
  final int barTotal;
  const ProjectSplit(this.parts, this.barTotal);
  bool get hasRefunds => parts.any((p) => p.cents < 0);
}

extension ExploreDb on WalletController {
  /// The day index every graph reads (it holds the accounts, which account series need), once per data version.
  DayIndex get exploreIndex => dayIndex;

  /// The window of a range chip: `1y`, `3y`, `5y` (the last 1, 3 or 5 years up to today, under core's 5-year limit) or `All` (the first
  /// counted day to today). Anything else is `3y`.
  DateRange exploreWindow(String range) {
    final today = this.today(), t = DateTime.parse(today);
    String back(int years) => addDays(isoDate(DateTime.utc(t.year - years, t.month, t.day)), 1);
    final first = exploreIndex.first;
    final start = switch (range) {
      '1y' => back(1),
      '5y' => back(5),
      'All' => first == null || first.compareTo(today) > 0 ? back(1) : first,
      _ => back(3),
    };
    return DateRange(start: start, end: today);
  }

  /// What Explore opens with: spending of the three biggest main tags over 3 years, in the size the window calls for.
  SeriesQuery exploreDefaultQuery() {
    final w = exploreWindow('3y');
    return SeriesQuery(measure: Measure.spent, keys: exploreDefaultKeys(), bucket: bucketFor(w, maxBars: 72), window: w);
  }

  /// [q] per bucket, oldest first. Cached by the query's JSON.
  List<QueryRow> exploreRows(SeriesQuery q) => memo(MemoKey('explore.rows', jsonEncode(q.toJson())),
      () => timed('explore.query', () => runQuery(exploreIndex, q, today: today()), fields: {'series': q.keys.length}, warnMs: 50));

  List<HeatCell> exploreHeat(SeriesKey k, Measure m) => memo(MemoKey('explore.heat', (k.kind.index, k.id, m.index)),
      () => timed('explore.heat', () => heatmap(exploreIndex, k, today: today(), measure: m)));

  MoveTogether? exploreMove(SeriesKey a, SeriesKey b, DateRange w) =>
      memo(MemoKey('explore.move', (a.kind.index, a.id, b.kind.index, b.id, w.start, w.end)), () => moveTogether(exploreIndex, a, b, w));

  /// Payees of the spending rows, biggest first: key (`merchantKey`, as the payee series filters on), name and total. Once per data version.
  List<({String key, String label, int spent})> explorePayees() => memo(const MemoKey('explore.payees'), () {
        final spent = <String, int>{}, label = <String, String>{}, keyByText = <String, String>{};
        for (final t in txs) {
          if (!countsAsSpending(t, currency)) continue;
          final tx = t.tx;
          if (tx.source == 'manual' && (tx.note == null || tx.note!.isEmpty)) continue;
          final k = tx.source == 'manual' ? merchantKey(tx) : keyByText.putIfAbsent(tx.description, () => merchantKey(tx));
          if (k == 'x') continue;
          spent[k] = (spent[k] ?? 0) - t.amount;
          label.putIfAbsent(k, () => merchantName(tx));
        }
        return [for (final e in spent.entries) (key: e.key, label: label[e.key]!, spent: e.value)]
          ..sort((a, b) => b.spent.compareTo(a.spent));
      });

  Map<String, String> _payeeLabels() => memo(const MemoKey('explore.payeeLabels'), () => {for (final p in explorePayees()) p.key: p.label});

  /// The name of a series for chips, legend and table.
  String seriesLabel(SeriesKey k) => switch (k.kind) {
        SeriesKind.mainTag => categoryTable.label(k.id),
        SeriesKind.tag => '#${tagTable.label(k.id)}',
        SeriesKind.payee => _payeeLabels()[k.id] ?? k.id.replaceAll('_', ' '),
        SeriesKind.account => accountsAll().where((a) => a.id == k.id).map((a) => a.name).firstOrNull ?? 'Account',
      };

  /// What the picker lists for [kind] (payees: the 60 biggest).
  List<SeriesChoice> seriesChoices(SeriesKind kind) => switch (kind) {
        SeriesKind.mainTag => [for (final id in categoryTable.spending) SeriesChoice(SeriesKey(kind, id), categoryTable.label(id))],
        SeriesKind.tag => [for (final id in tagTable.liveIds) SeriesChoice(SeriesKey(kind, id), '#${tagTable.label(id)}')],
        SeriesKind.payee => [for (final p in explorePayees().take(60)) SeriesChoice(SeriesKey(kind, p.key), p.label)],
        SeriesKind.account => [for (final a in accountsAll()) SeriesChoice(SeriesKey(kind, a.id), a.name)],
      };

  /// The three main tags with the most spending in the last year: the series Explore opens with.
  List<SeriesKey> exploreDefaultKeys() => memo(const MemoKey('explore.defaults'), () {
        final from = addDays(today(), -365);
        final by = <String, int>{};
        for (final t in txs) {
          if (t.date.compareTo(from) >= 0 && countsAsSpending(t, currency)) by[t.category] = (by[t.category] ?? 0) - t.amount;
        }
        final top = by.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
        return [for (final e in top.take(3)) SeriesKey(SeriesKind.mainTag, e.key)];
      });

  /// [q] as the CSV of exactly its buckets: oldest first, one column per series, then `together`. Money as exact decimals.
  ExportFile exploreCsv(SeriesQuery q) {
    final rows = exploreRows(q);
    final digits = storageDigitsOf(currency);
    String v(int n) => q.measure == Measure.count ? '$n' : centsToDecimal(n, digits: digits);
    final b =
        StringBuffer('from,to,${[for (final k in q.keys) csvField(seriesLabel(k))].join(',')}${q.keys.length > 1 ? ',together' : ''}\n');
    for (final r in rows) {
      b.write('${r.bucket.start},${r.bucket.end},${[
        for (final k in q.keys) v(r.cents[k] ?? 0)
      ].join(',')}${q.keys.length > 1 ? ',${v(r.together)}' : ''}\n');
    }
    logEvent(_exLog, Level.INFO, 'explore.export', {'rows': rows.length, 'series': q.keys.length, 'bucket': q.bucket.name});
    return ExportFile('bw-explore-${q.window.start}-${q.window.end}.csv', ImportAndBackup._csvBytes(b.toString()), rows.length);
  }

  // ---- saved views (a view write changes no payment, so the list is refreshed without a full reload) ----

  List<SavedView> exploreViews() => memo(const MemoKey('explore.views'), repo.views);

  void _viewsChanged() {
    _memo.remove(const MemoKey('explore.views'));
    _memo.removeWhere((k, _) => k.name.startsWith('ov.pin')); // Overview's pinned list and tiles read the same views
    _refreshView();
    _syncSoon();
  }

  /// Saves [q] under [name]; core's `ArgumentError` text for a blank or long name.
  String saveExploreView(String name, SeriesQuery q) {
    final id = repo.addView(name: name, query: jsonEncode(q.toJson()));
    logEvent(_exLog, Level.INFO, 'explore.view.save', {'series': q.keys.length, 'bucket': q.bucket.name, 'measure': q.measure.name});
    _viewsChanged();
    return id;
  }

  void renameExploreView(String id, String name) {
    repo.patchView(id, name: name);
    _viewsChanged();
  }

  void pinExploreView(String id, bool pinned) {
    repo.patchView(id, pinned: pinned);
    logEvent(_exLog, Level.INFO, 'explore.view.pin', {'pinned': pinned});
    _viewsChanged();
  }

  void deleteExploreView(String id) {
    repo.deleteView(id);
    logEvent(_exLog, Level.INFO, 'explore.view.delete');
    _viewsChanged();
  }

  void undeleteExploreView(String id) {
    repo.undeleteView(id);
    _viewsChanged();
  }

  // ---- projects ----

  /// Stats of extra tag [tagId] seen as a project. Once per data version.
  ProjectStats projectOf(String tagId) => memo(
      MemoKey('project.stats', tagId),
      () => timed('project.stats',
          () => projectStats(tagId, txs, tags: tagContext, table: categoryTable, currency: currency, today: today(), st: settings),
          fields: {'tx': txs.length}, warnMs: 150));

  /// [projectOf]'s main-tag split as rows. Once per data version.
  ProjectSplit projectSplit(String tagId) => memo(MemoKey('project.split', tagId), () {
        final s = projectOf(tagId);
        final parts = <ProjectPart>[for (final p in s.byMainTag.take(5)) ProjectPart(categoryTable.label(p.$1), p.$2, p.$2 > 0)];
        if (s.byMainTag.length > 5) {
          final rest = s.byMainTag.skip(5).fold<int>(0, (a, p) => a + p.$2);
          parts.add(ProjectPart('Other', rest, rest > 0));
        }
        return ProjectSplit(parts, parts.where((p) => p.inBar).fold<int>(0, (a, p) => a + p.cents));
      });

  /// Turns [tagId] on (Tag, Tag all) or off (Skip, Undo) for the payments [txIds]. An "off" link is what keeps a payment out of the
  /// project's "not tagged yet" list.
  Future<void> tagPayments(Iterable<String> txIds, String tagId, bool on) async {
    var n = 0;
    for (final id in txIds) {
      await repo.setTxTag(id, tagId, on);
      n++;
    }
    logEvent(_exLog, Level.INFO, 'project.tag', {'on': on, 'payments': n});
    _changed();
  }
}
