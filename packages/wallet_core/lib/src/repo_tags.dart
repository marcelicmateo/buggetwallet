part of 'repo.dart';

/// The owner's extra tags (T1, schema 11; see [TagRow], [TagTable], [tagsOf]): the `tag` entity, per-row links
/// (`txtag`, id `<txId>|<tagId>`, state `on`/`off`, never removed) and per-payee rule tags (`ruletag`, id
/// `<payee>|<tagId>`). Every rule is an [ArgumentError] with an owner-readable message, checked on local writes only
/// (sync never refuses an op). Logs carry counts only, never names or ids.
extension WalletRepoTags on WalletRepo {
  /// The trimmed [name], or an [ArgumentError] when it is empty, longer than [TagRow.maxName] characters, already the
  /// name of a live tag other than [exceptId], or the label of a live main tag (category); case and accents ignored.
  String _checkTagName(String name, TagTable t, {String? exceptId}) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Give the tag a name.');
    if (n.runes.length > TagRow.maxName) throw ArgumentError('The tag name is limited to ${TagRow.maxName} characters.');
    final key = foldText(n);
    for (final id in t.liveIds) {
      if (id != exceptId && foldText(t.label(id)) == key) throw ArgumentError('There is already a tag with this name.');
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
    final n = _checkTagName(name, t);
    if (t.liveIds.length >= TagRow.maxLive) throw ArgumentError('You can have at most ${TagRow.maxLive} tags.');
    var next = 0;
    for (final id in t.liveIds) {
      final p = t.position(id);
      if (p < (1 << 30) && p >= next) next = p + 1;
    }
    final id = _newTagId();
    _write([
      ('tag', id, {'name': n, 'position': next, 'hidden': 0, 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'tag.add', {'live': t.liveIds.length + 1});
    return id;
  }

  /// Changes the given fields only (null = unchanged). An unknown or deleted id, a bad or taken name, or a negative
  /// position: [ArgumentError].
  Future<void> updateTag(String id, {String? name, int? position, bool? hidden}) async {
    final t = tagTable();
    if (!t.isLive(id)) throw ArgumentError('No such tag.');
    if (position != null && position < 0) throw ArgumentError('Bad position.');
    final n = name == null ? null : _checkTagName(name, t, exceptId: id);
    final fields = <String, Object?>{
      if (n != null) 'name': n,
      if (position != null) 'position': position,
      if (hidden != null) 'hidden': hidden ? 1 : 0,
    };
    if (fields.isEmpty) return;
    _write([('tag', id, fields)]);
    logEvent(_log, Level.INFO, 'tag.update', {'fields': fields.length});
  }

  /// Removes a tag (`deleted: 1`). Its links and rule tags stay, unused until [undeleteTag]. Already deleted: nothing
  /// is written. Unknown id: [ArgumentError].
  Future<void> deleteTag(String id) async {
    final t = tagTable();
    if (!t.isKnown(id)) throw ArgumentError('No such tag.');
    if (!t.isLive(id)) return;
    _write([
      ('tag', id, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'tag.delete', {'live': t.liveIds.length - 1});
  }

  /// Undo of [deleteTag]: writes `deleted: 0`, so its rows have it again. A live id: nothing is written. Unknown id,
  /// a name taken in between, or [TagRow.maxLive] live tags already: [ArgumentError].
  Future<void> undeleteTag(String id) async {
    final t = tagTable();
    if (!t.isKnown(id)) throw ArgumentError('No such tag.');
    if (t.isLive(id)) return;
    final row = t.rows.lastWhere((r) => r.id == id);
    if (row.name.trim().isEmpty) throw ArgumentError('No such tag.');
    if (t.liveIds.length >= TagRow.maxLive) throw ArgumentError('You can have at most ${TagRow.maxLive} tags.');
    _checkTagName(row.name, t, exceptId: id);
    _write([
      ('tag', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'tag'});
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

  /// Turns tag [tagId] on or off for transaction [txId] by writing the link's state. On: the tag must be live; a
  /// no-op when the row already has it (a rule gives it, or the link is `on`) and the link is not `off`. Off: a no-op
  /// when the link is already `off`, or when neither a link nor a rule gives it. Unknown transaction or tag:
  /// [ArgumentError].
  Future<void> setTxTag(String txId, String tagId, bool on) async {
    final tx = transaction(txId);
    if (tx == null) throw ArgumentError('No such transaction.');
    final t = tagTable();
    if (on ? !t.isLive(tagId) : !t.isKnown(tagId)) throw ArgumentError('No such tag.');
    final linkId = '$txId|$tagId';
    final rs = db.select('SELECT state FROM tx_tags WHERE id = ?', [linkId]);
    final state = rs.isEmpty ? null : rs.first['state'] as String?;
    if (on) {
      if (state == 'on') return;
      if (state != 'off' && _ruleGives(tx, tagId, t)) return;
    } else {
      if (state == 'off') return;
      if (state != 'on' && !_ruleGives(tx, tagId, t)) return;
    }
    _write([
      ('txtag', linkId, {'tx': txId, 'tag': tagId, 'state': on ? 'on' : 'off'})
    ]);
    logEvent(_log, Level.INFO, 'tag.link', {'on': on});
  }

  /// Whether a live rule tag of [tx]'s payee gives [tagId] (through duplicates).
  bool _ruleGives(Tx tx, String tagId, TagTable t) {
    final payee = tagPayee(tx);
    if (payee == null) return false;
    final want = t.resolve(tagId);
    if (want == null) return false;
    for (final r in db.select('SELECT tag FROM rule_tags WHERE payee = ? AND deleted = 0', [payee])) {
      if (t.resolve(r['tag'] as String) == want) return true;
    }
    return false;
  }

  /// Gives (or stops giving) tag [tagId] to every row of [payee] (a `merchantKey`). On: the tag must be live. Already
  /// in that state: nothing is written. An empty payee or one with `|`, or an unknown tag: [ArgumentError].
  Future<void> setRuleTag(String payee, String tagId, bool on) async {
    if (payee.isEmpty || payee.contains('|')) throw ArgumentError('No such payee.');
    final t = tagTable();
    if (on ? !t.isLive(tagId) : !t.isKnown(tagId)) throw ArgumentError('No such tag.');
    final id = '$payee|$tagId';
    final rs = db.select('SELECT deleted FROM rule_tags WHERE id = ?', [id]);
    final live = rs.isNotEmpty && rs.first['deleted'] == 0;
    if (live == on) return;
    _write([
      ('ruletag', id, {'payee': payee, 'tag': tagId, 'deleted': on ? 0 : 1})
    ]);
    logEvent(_log, Level.INFO, 'tag.rule', {'on': on});
  }
}
