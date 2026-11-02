part of 'repo.dart';

/// The owner's extra tags (T1, schema 11; see [TagRow], [TagTable], [tagsOf]): the `tag` entity, per-row links
/// (`txtag`, id `<txId>|<tagId>`, state `on`/`off`, never removed) and per-payee rule tags (`ruletag`, id
/// `<payee>|<tagId>`). Every rule is an [ArgumentError] with an owner-readable message, checked on local writes only
/// (sync never refuses an op). Logs carry counts only, never names or ids.
extension WalletRepoTags on WalletRepo {
  /// The trimmed [name], or an [ArgumentError] when it is empty, longer than [TagRow.maxName] characters, already the
  /// name of a live tag other than [except], or the label of a live main tag (category); case and accents ignored.
  String _checkTagName(String name, TagTable t, {Set<String> except = const {}}) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Give the tag a name.');
    if (n.runes.length > TagRow.maxName) throw ArgumentError('The tag name is limited to ${TagRow.maxName} characters.');
    final key = foldText(n);
    for (final id in t.liveIds) {
      if (!except.contains(id) && foldText(t.label(id)) == key) throw ArgumentError('There is already a tag with this name.');
    }
    final cats = categoryTable();
    for (final c in cats.topLevelIds) {
      if (foldText(cats.label(c).trim()) == key) throw ArgumentError('There is already a main tag with this name.');
    }
    return n;
  }

  /// `t` + 12 random hex characters.
  String _newTagId() {
    final r = Random.secure();
    final sb = StringBuffer('t');
    for (var i = 0; i < 12; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  /// Adds a tag and returns its id, placed last. A bad or taken name ([_checkTagName]) or [TagRow.maxLive] live tags
  /// already: [ArgumentError].
  Future<String> addTag(String name) async {
    final t = tagTable();
    final row = _newTagRow(name, t);
    _write([row]);
    logEvent(_log, Level.INFO, 'tag.add', {'live': t.liveIds.length + 1});
    return row.$2;
  }

  /// The write of a new tag [name] placed last (shared by [addTag] and `buyGoal`): a bad or taken name
  /// ([_checkTagName]) or [TagRow.maxLive] live tags already: [ArgumentError].
  (String, String, Map<String, Object?>) _newTagRow(String name, TagTable t) {
    final n = _checkTagName(name, t);
    if (t.liveIds.length >= TagRow.maxLive) throw ArgumentError('You can have at most ${TagRow.maxLive} tags.');
    var next = 0;
    for (final id in t.liveIds) {
      final p = t.position(id);
      if (p < (1 << 30) && p >= next) next = p + 1;
    }
    return ('tag', _newTagId(), {'name': n, 'position': next, 'hidden': 0, 'deleted': 0});
  }

  /// [id] and the live sync duplicates that resolve to it ([TagTable.resolve]), or empty when it is not live. A
  /// duplicate itself is acted on alone (the owner cleaning up the copy), an original with its whole group.
  static List<String> _group(TagTable t, String id) {
    if (!t.isLive(id)) return const [];
    return [id, ...t.liveIds.where((x) => x != id && t.resolve(x) == id)];
  }

  /// Changes the given fields only (null = unchanged), on [id]'s whole duplicate group ([TagTable.resolve]), so the
  /// tag the owner sees changes as one. An unknown or deleted id, a bad or taken name, or a negative position:
  /// [ArgumentError]. A thin wrapper over [patch] (F2).
  Future<void> updateTag(String id, {String? name, int? position, bool? hidden}) async => patch(TagCols.entity, id, {
        if (name != null) TagCols.name: name,
        if (position != null) TagCols.position: position,
        if (hidden != null) TagCols.hidden: hidden,
      });

  static const _tagEdited = <Col>{TagCols.name, TagCols.position, TagCols.hidden};

  /// [patch] of a tag: [updateTag]'s rules, written to [id]'s whole duplicate group (position none = last).
  int _patchTag(String id, Map<Col, Object?> v) {
    WalletRepoPatch._needValues(v);
    final t = tagTable();
    if (!t.isLive(id)) throw ArgumentError('No such tag.');
    final name = v[TagCols.name] as String?, position = v[TagCols.position] as int?, hidden = v[TagCols.hidden] as bool?;
    if (position != null && position < 0) throw ArgumentError('Bad position.');
    final group = _group(t, id);
    final n = name == null ? null : _checkTagName(name, t, except: group.toSet());
    final fields = <String, Object?>{
      if (n != null) 'name': n,
      if (v.containsKey(TagCols.position)) 'position': position,
      if (hidden != null) 'hidden': hidden ? 1 : 0,
      ..._patchRest(v, _tagEdited),
    };
    if (fields.isEmpty) return 0;
    _write([for (final g in group) ('tag', g, fields)]);
    logEvent(_log, Level.INFO, 'tag.update', {'fields': fields.length, 'group': group.length});
    return fields.length;
  }

  /// Removes a tag (`deleted: 1`) with its whole duplicate group. Its links and rule tags stay, unused until
  /// [undeleteTag]. Already deleted: nothing is written. Unknown id: [ArgumentError].
  Future<void> deleteTag(String id) async {
    final t = tagTable();
    if (!t.isKnown(id)) throw ArgumentError('No such tag.');
    if (!t.isLive(id)) return;
    final group = _group(t, id);
    _write([
      for (final g in group) ('tag', g, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'tag.delete', {'live': t.liveIds.length - group.length, 'group': group.length});
  }

  /// The ids of [entity] whose `deleted` field was written in the same millisecond by the same device as [id]'s (one
  /// write ticks one clock per op: same millis and node, counters in a row): the members of a duplicate group one
  /// delete removed together.
  Set<String> _deletedWith(String entity, String id) {
    final rs = db.select("SELECT hlc FROM clocks WHERE entity = ? AND id = ? AND field = 'deleted'", [entity, id]);
    if (rs.isEmpty) return {id};
    final mine = Hlc.parse(rs.first['hlc'] as String);
    return {
      id,
      for (final r in db.select("SELECT id, hlc FROM clocks WHERE entity = ? AND field = 'deleted' AND hlc LIKE ?",
          [entity, '${mine.millis.toString().padLeft(15, '0')}:%']))
        if (Hlc.parse(r['hlc'] as String).node == mine.node) r['id'] as String
    };
  }

  /// Undo of [deleteTag]: writes `deleted: 0` for [id] and every deleted tag with the same folded name that the same
  /// delete removed (its duplicate group; the same `deleted` clock), so its rows have it again. A live id: nothing is written. Unknown id, a name taken in
  /// between, or more than [TagRow.maxLive] live tags after it: [ArgumentError].
  Future<void> undeleteTag(String id) async {
    final t = tagTable();
    if (!t.isKnown(id)) throw ArgumentError('No such tag.');
    if (t.isLive(id)) return;
    final row = t.rows.lastWhere((r) => r.id == id);
    if (row.name.trim().isEmpty) throw ArgumentError('No such tag.');
    final key = foldText(row.name.trim());
    final together = _deletedWith('tag', id);
    final group = {
      id,
      for (final r in t.rows)
        if (r.deleted && together.contains(r.id) && r.name.trim().isNotEmpty && foldText(r.name.trim()) == key) r.id
    };
    if (t.liveIds.length + group.length > TagRow.maxLive) throw ArgumentError('You can have at most ${TagRow.maxLive} tags.');
    _checkTagName(row.name, t, except: group);
    _write([
      for (final g in group) ('tag', g, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'tag', 'group': group.length});
  }

  /// The stored tags, by position, then id; deleted ones only with [includeDeleted].
  List<TagRow> tags({bool includeDeleted = false}) => [
        for (final r in db.select('SELECT * FROM tags ORDER BY position IS NULL, position, id').map(TagRow.fromRow))
          if (includeDeleted || !r.deleted) r,
      ];

  /// Every stored tag (deleted ones included, so links to them resolve as dead) as a [TagTable].
  TagTable tagTable() => TagTable.from(tags(includeDeleted: true));

  /// Payee (`merchantKey`) → the tag ids its live rule tags give.
  Map<String, Set<String>> ruleTags() {
    final out = <String, Set<String>>{};
    for (final r in db.select("SELECT payee, tag FROM rule_tags WHERE deleted = 0 AND payee != '' AND tag != ''")) {
      (out[r['payee'] as String] ??= {}).add(r['tag'] as String);
    }
    return out;
  }

  /// Tx id → tag id → `true` (`on`) or `false` (`off`): every link with a known state.
  Map<String, Map<String, bool>> tagLinks() {
    final out = <String, Map<String, bool>>{};
    for (final r in db.select("SELECT tx, tag, state FROM tx_tags WHERE state IN ('on', 'off') AND tx != '' AND tag != ''")) {
      (out[r['tx'] as String] ??= {})[r['tag'] as String] = r['state'] == 'on';
    }
    return out;
  }

  /// One read of the three tag tables, for a whole categorize pass ([Categorizer.tagContext], [categorizer]).
  TagContext tagContext() {
    final t = PerfTimer('repo.tagContext');
    final ctx = TagContext(tags: tagTable(), ruleTags: ruleTags(), links: tagLinks());
    t.done({'tags': ctx.tags.liveIds.length, 'rules': ctx.ruleTags.length, 'links': ctx.links.length});
    return ctx;
  }

  /// Turns tag [tagId] on or off for transaction [txId], judged by the row's effective tags ([tagsOf]) and written on
  /// the tag the owner sees ([TagTable.resolve]: a sync duplicate counts as its original). On: the tag must be live; a
  /// no-op when the row already has it; else the original's link is written `on`, and any link of the group that is
  /// `off` too. Off: the original's link is written `off`, and any link of the group that is `on` too (a rule tag stays:
  /// `off` overrides it on this row); a row without the tag still gets an `off` link ("not this project", so Project
  /// candidates leave it out for good), a no-op only when a link of the group is already `off`. A tag that is not live
  /// (off only): its own link, as stored. Unknown transaction or tag: [ArgumentError].
  Future<void> setTxTag(String txId, String tagId, bool on) async {
    final tx = transaction(txId);
    if (tx == null) throw ArgumentError('No such transaction.');
    final t = tagTable();
    if (on ? !t.isLive(tagId) : !t.isKnown(tagId)) throw ArgumentError('No such tag.');
    final links = <String, bool>{
      for (final r in db.select("SELECT tag, state FROM tx_tags WHERE tx = ? AND state IN ('on', 'off')", [txId]))
        r['tag'] as String: r['state'] == 'on',
    };
    final o = t.resolve(tagId);
    final changes = <(String, String, Map<String, Object?>)>[];
    void link(String tag, bool state) => changes.add(('txtag', '$txId|$tag', {'tx': txId, 'tag': tag, 'state': state ? 'on' : 'off'}));
    if (o == null) {
      if (links[tagId] == true) link(tagId, false);
    } else {
      final payee = tagPayee(tx);
      final rules = <String>{
        if (payee != null)
          for (final r in db.select('SELECT tag FROM rule_tags WHERE payee = ? AND deleted = 0', [payee])) r['tag'] as String
      };
      final has = tagsOf(tx, tags: t, ruleTags: {if (payee != null) payee: rules}, links: {txId: links}).contains(o);
      if (has != on) {
        link(o, on);
        for (final MapEntry(key: g, value: state) in links.entries) {
          if (g != o && t.resolve(g) == o && state != on) link(g, on);
        }
      } else if (!on && !links.entries.any((e) => !e.value && t.resolve(e.key) == o)) {
        link(o, false);
      }
    }
    if (changes.isEmpty) return;
    _write(changes);
    logEvent(_log, Level.INFO, 'tag.link', {'on': on, 'links': changes.length});
  }

  /// Gives (or stops giving) tag [tagId] to every row of [payee] (a `merchantKey`), judged on the tag the owner sees
  /// ([TagTable.resolve]). On: the tag must be live; a no-op when a live rule of its group already gives it, else the
  /// original's rule is written. Off: every live rule of the group is removed (none: nothing written). A tag that is
  /// not live (off only): its own rule. An empty payee or one with `|`, or an unknown tag: [ArgumentError].
  Future<void> setRuleTag(String payee, String tagId, bool on) async {
    if (payee.isEmpty || payee.contains('|')) throw ArgumentError('No such payee.');
    final t = tagTable();
    if (on ? !t.isLive(tagId) : !t.isKnown(tagId)) throw ArgumentError('No such tag.');
    final o = t.resolve(tagId);
    final live = [
      for (final r in db.select('SELECT tag FROM rule_tags WHERE payee = ? AND deleted = 0', [payee]))
        if (o == null ? r['tag'] == tagId : t.resolve(r['tag'] as String) == o) r['tag'] as String
    ];
    final changes = <(String, String, Map<String, Object?>)>[
      if (on && live.isEmpty) ('ruletag', '$payee|$o', {'payee': payee, 'tag': o, 'deleted': 0}),
      if (!on)
        for (final g in live) ('ruletag', '$payee|$g', {'payee': payee, 'tag': g, 'deleted': 1}),
    ];
    if (changes.isEmpty) return;
    _write(changes);
    logEvent(_log, Level.INFO, 'tag.rule', {'on': on, 'rules': changes.length});
  }
}
