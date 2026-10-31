part of 'repo.dart';

/// D2 Unlink (schema 19): the owner undoes a wrong automatic cash match ([planMatches] pairs a hand-added expense with
/// a bank row on the amount, the one exception to "never on amount alone"). Owner writes, synced; logs carry counts.
extension WalletRepoMatch on WalletRepo {
  /// The ids of the live bank rows that replaced a live hand-added expense (its `matched_to`): the rows the app marks
  /// "Matched". One query; an unlinked pair, a deleted entry or a bank row not here yet is not listed.
  Set<String> matchedBankIds() => {
        for (final r in db.select('SELECT DISTINCT b.id FROM tx e JOIN tx b ON b.id = e.matched_to '
            'WHERE e.manual = 1 AND e.deleted = 0 AND b.manual = 0 AND b.deleted = 0'))
          r['id'] as String
      };

  /// Unlinks hand-added expense [entryId] from the bank row that replaced it: one write sets its `matched_to` to null
  /// and adds that row to its `match_off` ([matchOffIds]), so matching never pairs the two again on any device that
  /// runs schema 19 or newer. The entry counts again; the bank row stays as it is. The bank row no longer reads the
  /// entry's split (it is read through `matched_to`); what matching copied onto it stays (its category, when it had
  /// none, and the entry's extra tags), as when a match reopens for any other reason; so do the attachments that moved
  /// to it. The entry may match another bank row: matching runs at once (while caught up, as after a delete), so the
  /// state the owner sees is the final one. What that rematch copied onto the new row (its category, the entry's
  /// tags) is noted device-locally ([_undoMatchKey]) so [relinkMatch], the Undo, can take it back.
  ///
  /// [ArgumentError]: unknown or deleted id, not a hand-added expense, or not matched.
  void unlinkMatch(String entryId) {
    final r = _matchEntryRow(entryId, 'unlinked from');
    final bank = r['matched_to'] as String?;
    if (bank == null) throw ArgumentError('This expense is not matched with a bank row.');
    final off = [...matchOffIds(r['match_off'] as String?).where((id) => id != bank), bank];
    _write([
      ('tx', entryId, {'matched_to': null, 'match_off': encodeMatchOff(off)})
    ]);
    final mark = clock.last;
    final (_, matched) = _reconcileLocal();
    final copied = _noteRematchCopy(entryId, bank, mark);
    logEvent(_log, Level.INFO, 'match.unlink', {'off': min(off.length, maxMatchOff), 'rematched': matched, 'copied': copied});
  }

  /// Meta key prefix (device-local, never synced; under `undo.`, so `_purgeUndo` drops it after a day like the delete
  /// records) + entry id. Value JSON: `at` (wall ms), `bank` (the row the rematch after [unlinkMatch] gave the entry),
  /// `category` (the clock of the category the rematch copied onto it, absent when it copied none) and `tags` (tag id →
  /// the clock of the `on` link it copied). Matching copies a category only onto a row without one, and a tag only
  /// when the row has no link for it, so the state before the copy is "no category" / "no link".
  static const _undoMatchKey = 'undo.match.';

  /// After [unlinkMatch]'s rematch: notes what it wrote onto the entry's new bank row since [mark] (field clocks
  /// newer than it). Returns the number of copied fields noted (0 = no record kept).
  int _noteRematchCopy(String entryId, String unlinked, Hlc mark) {
    final key = '$_undoMatchKey$entryId';
    final y = db.select('SELECT matched_to FROM tx WHERE id = ?', [entryId]).first['matched_to'] as String?;
    String? newer(String entity, String id, String field) {
      final h = _clockOf(entity, id, field);
      return h != null && Hlc.compareStrings(h, mark.toString()) > 0 ? h : null;
    }

    final category = y == null || y == unlinked ? null : newer('tx', y, 'category');
    final tags = <String, String>{
      if (y != null && y != unlinked)
        for (final r in db.select("SELECT tag FROM tx_tags WHERE tx = ? AND state = 'on'", [y]))
          if (newer('txtag', '$y|${r['tag']}', 'state') case final h?) r['tag'] as String: h
    };
    if (category == null && tags.isEmpty) {
      db.execute('DELETE FROM meta WHERE key = ?', [key]);
      return 0;
    }
    _setMeta(key, jsonEncode({'at': clock.now(), 'bank': y, if (category != null) 'category': category, 'tags': tags}));
    return tags.length + (category == null ? 0 : 1);
  }

  /// The stored clock of [field] of row [id] of [entity]; null when never written.
  String? _clockOf(String entity, String id, String field) =>
      db.select('SELECT hlc FROM clocks WHERE entity = ? AND id = ? AND field = ?', [entity, id, field]).firstOrNull?['hlc'] as String?;

  /// The writes that take back what the rematch after an unlink copied onto its row ([_undoMatchKey] record of
  /// [entryId]), for each field whose clock is still the copy's (a later write, here or synced, stays). None when the
  /// row is now matched with another expense (what it carries is that match's now) or is [bankId] itself.
  List<(String, String, Map<String, Object?>)> _rematchCopyUndo(String entryId, String bankId) {
    final v = _meta('$_undoMatchKey$entryId');
    Object? j;
    try {
      j = v == null ? null : jsonDecode(v);
    } on FormatException catch (e, st) {
      logError(_log, 'match.undoRecord.bad', e, st);
    }
    if (j is! Map || j['bank'] is! String) return const [];
    final y = j['bank'] as String;
    if (y == bankId) return const [];
    if (db.select('SELECT 1 FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to = ? AND id != ?', [y, entryId]).isNotEmpty) {
      return const [];
    }
    final tags = j['tags'];
    return [
      if (j['category'] case final String h when _clockOf('tx', y, 'category') == h) ('tx', y, {'category': null}),
      if (tags is Map)
        for (final MapEntry(:key, :value) in tags.entries)
          if (key is String && value is String && _clockOf('txtag', '$y|$key', 'state') == value)
            ('txtag', '$y|$key', {'tx': y, 'tag': key, 'state': ''}),
    ];
  }

  /// The Undo of [unlinkMatch]: hand-added expense [entryId] is replaced by bank row [bankId] again (`matched_to`),
  /// and [bankId] leaves its `match_off`. If matching gave the entry another row since, that row is free again, and
  /// what that rematch copied onto it (its category, the entry's tags; noted by [unlinkMatch] on this device) is taken
  /// back, field by field, unless written since (that write stays). The entry's extra tags are copied to [bankId] as a
  /// new match does; attachments it got meanwhile move on the next match run.
  ///
  /// [ArgumentError]: unknown or deleted entry, not a hand-added expense, or [bankId] is not a row it was unlinked
  /// from. [StateError]: the bank row is no longer in the wallet (deleted, or not here), is now one side of an own
  /// transfer, or another expense is matched with it now.
  void relinkMatch(String entryId, String bankId) {
    final r = _matchEntryRow(entryId, 'linked to');
    final off = [...matchOffIds(r['match_off'] as String?)];
    if (!off.remove(bankId)) throw ArgumentError('This expense was not unlinked from that bank row.');
    final b = transaction(bankId);
    if (b == null || b.deleted || b.manual) throw StateError('That bank row is no longer in the wallet.');
    if (b.transferTo != null) throw StateError('That bank row is now a transfer between your accounts.');
    if (db.select('SELECT 1 FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to = ? AND id != ?', [bankId, entryId]).isNotEmpty) {
      throw StateError('That bank row is now matched with another expense.');
    }
    final had = r['matched_to'] as String?;
    final restore = _rematchCopyUndo(entryId, bankId);
    _write([
      ('tx', entryId, {'matched_to': bankId, 'match_off': encodeMatchOff(off)}),
      ..._matchedTagLinks({entryId: bankId}),
      ...restore,
    ]);
    db.execute('DELETE FROM meta WHERE key = ?', ['$_undoMatchKey$entryId']);
    _reconcileLocal();
    logEvent(
        _log, Level.INFO, 'match.relink', {'off': off.length, 'freed': had != null && had != bankId ? 1 : 0, 'restored': restore.length});
  }

  /// The stored row of live hand-added expense [entryId] ([ArgumentError] otherwise; [what] completes the message).
  Map<String, Object?> _matchEntryRow(String entryId, String what) {
    final rs = db.select('SELECT manual, deleted, matched_to, match_off FROM tx WHERE id = ?', [entryId]);
    if (rs.isEmpty || rs.first['deleted'] == 1) throw ArgumentError('No such transaction.');
    if (rs.first['manual'] != 1) throw ArgumentError('Only an expense you added yourself can be $what a bank row.');
    return rs.first;
  }
}
