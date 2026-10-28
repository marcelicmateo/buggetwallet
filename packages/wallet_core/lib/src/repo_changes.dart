part of 'repo.dart';

/// Recent changes (Q9): the newest change of each synced row, from the device-local `clocks` table.
extension WalletRepoChanges on WalletRepo {
  /// The [limit] most recently changed rows on this device, newest first: per (entity, id) of `clocks` its newest HLC
  /// (string order, as every HLC this format writes sorts) and the fields written with it ([ChangeEntry]); ties by
  /// entity, then id. Labels per entity: a payment = its merchant name ([merchantName]) and date; goal, wish, account,
  /// category, tag = name (a built-in category without its own label = its id); recurring bill = label (else payee);
  /// bill = payee (else description); planned cost = title; setting = its key (never the value); payee rule and rule tag =
  /// the payee key; goal contribution = its goal's name; split and tag link = their payment's label; weekly review = its
  /// date; anything else (an entity this build does not know, a row not stored) = the entity name.
  /// [ChangeEntry.deleted] = the row's `deleted` is 1. Read-only; logs the count and time only. [limit] ≤ 0 → none.
  List<ChangeEntry> recentChanges({int limit = 100}) {
    if (limit <= 0) return const [];
    final sw = Stopwatch()..start();
    final rs = db.select('''
WITH last AS (SELECT entity, id, max(hlc) AS h FROM clocks GROUP BY entity, id ORDER BY h DESC, entity, id LIMIT ?)
SELECT c.entity AS entity, c.id AS id, c.field AS field, c.hlc AS hlc
FROM clocks c JOIN last l ON c.entity = l.entity AND c.id = l.id AND c.hlc = l.h''', [limit]);
    final groups = <String, ({String entity, String id, String hlc, List<String> fields})>{};
    for (final r in rs) {
      final e = r['entity'] as String, id = r['id'] as String;
      groups
          .putIfAbsent('$e\u0000$id', () => (entity: e, id: id, hlc: r['hlc'] as String, fields: <String>[]))
          .fields
          .add(r['field'] as String);
    }
    final ids = <String, Set<String>>{};
    for (final g in groups.values) {
      ids.putIfAbsent(g.entity, () => {}).add(g.id);
    }
    final rows = {for (final MapEntry(key: e, value: s) in ids.entries) e: _changeRows(e, s)};
    // Rows other labels need: a split's or tag link's payment, a contribution's goal.
    final txIds = <String>{
      ...?ids['split'],
      for (final id in ids['txtag'] ?? const <String>{}) id.split('|').first,
    }..removeAll(rows['tx']?.keys ?? const <String>[]);
    final goalIds = <String>{
      for (final r in rows['goal_contrib']?.values ?? const <Map<String, Object?>>[])
        if (r['goal_id'] case final String g) g
    }..removeAll(rows['goal']?.keys ?? const <String>[]);
    final txs = {...?rows['tx'], ..._changeRows('tx', txIds)};
    final goals = {...?rows['goal'], ..._changeRows('goal', goalIds)};

    String? text(Map<String, Object?>? r, String col) => switch (r?[col]) { final String s when s.trim().isNotEmpty => s, _ => null };
    String? txLabel(String id) {
      final r = txs[id];
      if (r == null) return null;
      final t = Tx.fromRow(r);
      return '${merchantName(t)} · ${t.date}';
    }

    String label(String entity, String id, Map<String, Object?>? r) {
      final l = switch (entity) {
        _ when r == null && entity != 'setting' && entity != 'rule' && entity != 'split' && entity != 'txtag' => null,
        'tx' => txLabel(id),
        'goal' || 'wish' || 'account' || 'tag' => text(r, 'name'),
        'category' => text(r, 'name') ?? id,
        'recurring' => text(r, 'label') ?? text(r, 'payee'),
        'bill' => text(r, 'payee') ?? text(r, 'description'),
        'planned' => text(r, 'title'),
        'setting' || 'rule' => id,
        'ruletag' => text(r, 'payee'),
        'goal_contrib' => text(goals[r?['goal_id']], 'name'),
        'split' => txLabel(id),
        'txtag' => txLabel(id.split('|').first),
        'review' => id,
        _ => text(r, 'name') ?? text(r, 'title') ?? text(r, 'label') ?? text(r, 'payee') ?? text(r, 'person'),
      };
      return l ?? entity;
    }

    final out = <ChangeEntry>[];
    var bad = 0;
    for (final g in groups.values) {
      final Hlc h;
      try {
        h = Hlc.parse(g.hlc);
      } on FormatException catch (e, st) {
        bad++;
        if (bad == 1) logError(_log, 'repo.recentChanges.badClock', e, st);
        continue;
      }
      final r = rows[g.entity]?[g.id];
      out.add(ChangeEntry(g.entity, g.id, List.unmodifiable(g.fields..sort()), h.millis, h.node, h.node == deviceId,
          label(g.entity, g.id, r), r?['deleted'] == 1));
    }
    out.sort((a, b) {
      final ga = groups['${a.entity}\u0000${a.id}']!.hlc, gb = groups['${b.entity}\u0000${b.id}']!.hlc;
      var d = Hlc.compareStrings(gb, ga);
      if (d == 0) d = a.entity.compareTo(b.entity);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
    logEvent(_log, Level.FINE, 'repo.recentChanges', {'rows': out.length, 'bad': bad, 'ms': sw.elapsedMilliseconds});
    return out;
  }

  /// The stored rows of [entity] with [ids] (id → row, `SELECT *`); none for an entity this build does not know.
  Map<String, Map<String, Object?>> _changeRows(String entity, Set<String> ids) {
    final def = entitySchema[entity];
    if (def == null || ids.isEmpty) return const {};
    final out = <String, Map<String, Object?>>{};
    final list = [...ids];
    const chunk = 500;
    for (var i = 0; i < list.length; i += chunk) {
      final part = list.sublist(i, i + chunk > list.length ? list.length : i + chunk);
      final rs = db.select('SELECT * FROM ${def.table} WHERE id IN (${List.filled(part.length, '?').join(', ')})', part);
      for (final r in rs) {
        out[r['id'] as String] = {for (final k in r.keys) k: r[k]};
      }
    }
    return out;
  }
}
