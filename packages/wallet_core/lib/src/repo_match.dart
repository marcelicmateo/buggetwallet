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
  /// state the owner sees is the final one. [relinkMatch] is the Undo.
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
    final (_, matched) = _reconcileLocal();
    logEvent(_log, Level.INFO, 'match.unlink', {'off': min(off.length, maxMatchOff), 'rematched': matched});
  }

  /// The Undo of [unlinkMatch]: hand-added expense [entryId] is replaced by bank row [bankId] again (`matched_to`),
  /// and [bankId] leaves its `match_off`. If matching gave the entry another row since, that row is free again. The
  /// entry's extra tags are copied to the row as a new match does; attachments it got meanwhile move on the next match run.
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
    _write([
      ('tx', entryId, {'matched_to': bankId, 'match_off': encodeMatchOff(off)}),
      ..._matchedTagLinks({entryId: bankId}),
    ]);
    _reconcileLocal();
    logEvent(_log, Level.INFO, 'match.relink', {'off': off.length, 'freed': had != null && had != bankId ? 1 : 0});
  }

  /// The stored row of live hand-added expense [entryId] ([ArgumentError] otherwise; [what] completes the message).
  Map<String, Object?> _matchEntryRow(String entryId, String what) {
    final rs = db.select('SELECT manual, deleted, matched_to, match_off FROM tx WHERE id = ?', [entryId]);
    if (rs.isEmpty || rs.first['deleted'] == 1) throw ArgumentError('No such transaction.');
    if (rs.first['manual'] != 1) throw ArgumentError('Only an expense you added yourself can be $what a bank row.');
    return rs.first;
  }
}
