part of 'repo.dart';

/// Transaction rows: category and payee-rule reads and writes, deletes and their undo.
extension WalletRepoTx on WalletRepo {
  /// The live payee rules ([merchantRules]) as [MerchantRule]s, by key (for `rulesView`).
  List<MerchantRule> payeeRules() => [
        for (final MapEntry(:key, :value) in (merchantRules().entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
          MerchantRule(key, value)
      ];

  Map<String, String> merchantRules() => {
        for (final r in db.select('SELECT id, category FROM merchant_rules WHERE deleted = 0 AND category IS NOT NULL'))
          if ((r['id'], r['category']) case (final String id, final String c)) id: c,
      };

  /// The `seen_bank` value for an entry added now ([SeenBank]): per device, the highest `amount` clock of the bank
  /// rows (live or deleted) this device holds. Grouped in SQL by the node part of the clock (position 23 on: 15 millis
  /// digits, `:`, 5 counter digits, `:`), so each group's strings have one width and MAX is their HLC maximum;
  /// [SeenBank.encode] then takes the maximum per node exactly.
  String _seenBank() => SeenBank.encode([
        for (final r in db.select('SELECT MAX(c.hlc) AS h FROM clocks c JOIN tx ON tx.id = c.id '
            "WHERE c.entity = 'tx' AND c.field = 'amount' AND tx.manual = 0 GROUP BY substr(c.hlc, 23)"))
          r['h'] as String,
      ]);

  void setCategory(String txId, String? category) => _write([
        ('tx', txId, {'category': category})
      ]);

  /// Deletes a row. A hand-added expense that this bank row replaced counts again (and may be matched by a later
  /// bank row): see [planMatches]. The other side of an own transfer it was paired with is open again ([planTransfers]).
  void deleteTransaction(String txId) {
    _purgeUndo();
    // Read before any write: the links this row holds are cleared below (not caught up) or by [_reconcileLocal].
    final matched = [
      for (final r in db.select('SELECT id FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to = ?', [txId])) r['id'] as String
    ];
    final partners = [
      for (final r in db.select('SELECT id FROM tx WHERE deleted = 0 AND transfer_to = ? AND id != ?', [txId, txId])) r['id'] as String
    ];
    _write([
      ('tx', txId, {'deleted': 1})
    ]);
    if (!syncCaughtUp) {
      // New pairs and matches wait for a caught-up sync, but the links this row held are undone at once: that needs
      // only its own deletion, and a cash entry it replaced must count again now (exact money).
      _write([
        for (final r in db.select('SELECT id FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to = ?', [txId]))
          ('tx', r['id'] as String, {'matched_to': null}),
        for (final r in db.select('SELECT id FROM tx WHERE transfer_to = ? AND id != ?', [txId, txId]))
          ('tx', r['id'] as String, {'transfer_to': null}),
      ]);
    }
    // A bill paid by this row is unpaid again at once (its planned row reopens and reserves): exact money.
    final today = _today();
    final paid = [
      for (final r in db.select("SELECT * FROM bills WHERE deleted = 0 AND source != 'attachment' AND linked_tx = ?", [txId]))
        Bill.fromRow(r)
    ];
    _write([
      for (final b in paid) ..._billWrites(b, {'linked_tx': null}, today),
    ]);
    // Device-local, for undeleteTransaction: automatic linking takes only bank rows (a cash expense made from a bill
    // would come back without its bill: reserved and counted, twice), and while not caught up nothing re-links a
    // match or a pair (the entry and the row would both count).
    if (paid.isNotEmpty || matched.isNotEmpty || partners.isNotEmpty) {
      _setMeta(
          '$_undoKey$txId',
          jsonEncode({
            'at': clock.now(),
            'bills': [for (final b in paid) b.id],
            'matched': matched,
            'transfer': partners,
          }));
    }
    _reconcileLocal();
  }

  /// Meta key prefix (device-local, never synced), value JSON with `at` (wall ms) and id lists `bills`, `matched` and
  /// `transfer`: the bills [deleteTransaction] unlinked from a row, the hand-added entries it replaced
  /// (`matched_to`) and its own-transfer partners (`transfer_to`), for its undo. Removed by the undo, or after
  /// [_undoKeep] ([_purgeUndo], at open and on every delete).
  static const _undoKey = 'undo.';

  static const _undoKeep = Duration(days: 1);

  /// Drops the [_undoKey] records older than [_undoKeep] (or unreadable): the app's Undo lasts seconds.
  void _purgeUndo() {
    final cutoff = clock.now() - _undoKeep.inMilliseconds;
    final old = <String>[];
    for (final r in db.select('SELECT key, value FROM meta WHERE substr(key, 1, ${_undoKey.length}) = ?', [_undoKey])) {
      final at = _undoRecord(r['value'] as String?)?.at;
      if (at == null || at < cutoff) old.add(r['key'] as String);
    }
    for (final k in old) {
      db.execute('DELETE FROM meta WHERE key = ?', [k]);
    }
    if (old.isNotEmpty) logEvent(_log, Level.FINE, 'repo.undo.purged', {'records': old.length});
  }

  /// An [_undoKey] value; null when it is not one.
  static ({int? at, List<String> bills, List<String> matched, List<String> transfer})? _undoRecord(String? v) {
    try {
      final j = v == null ? null : jsonDecode(v);
      if (j is! Map) return null;
      List<String> ids(Object? l) => l is List ? l.whereType<String>().toList() : const <String>[];
      return (at: j['at'] is int ? j['at'] as int : null, bills: ids(j['bills']), matched: ids(j['matched']), transfer: ids(j['transfer']));
    } on FormatException catch (e, st) {
      logError(_log, 'repo.undo.badRecord', e, st);
      return null;
    }
  }

  /// Undo of [deleteTransaction] (Stage I): writes `deleted: 0` (an owner write, synced), so the row is live again with
  /// every other field as it is now (a hand-added entry keeps its `matched_to`). Per DESIGN_DECISIONS §4.10 only this
  /// write revives a deleted row, and the later of it and the delete (by HLC) wins on every device; edits made
  /// elsewhere meanwhile stay (per field). From this device's undo record, in the same write: the bill the delete
  /// unlinked is linked again when it is still live and unlinked and no other live bill holds the row (a cash expense
  /// made from a bill is never linked automatically); each hand-added entry it replaced gets `matched_to` back and each
  /// own-transfer partner `transfer_to` back when that field is still null and the entry or partner is live (while not
  /// caught up nothing re-links them, so the money would count twice). Pairing, matching and bill links then run as
  /// after any change of rows ([_reconcileLocal]). A live row: nothing is written. Throws [ArgumentError] for an id
  /// this wallet does not hold.
  void undeleteTransaction(String txId) {
    final rs = db.select('SELECT deleted, transfer_to FROM tx WHERE id = ?', [txId]);
    if (rs.isEmpty) throw ArgumentError('No such transaction.');
    if (rs.first['deleted'] == 0) return;
    final today = _today();
    final relink = <Bill>[];
    final rematch = <String>[], repair = <String>[];
    if (_undoRecord(_meta('$_undoKey$txId')) case final u?) {
      final held = db.select("SELECT 1 FROM bills WHERE deleted = 0 AND source != 'attachment' AND linked_tx = ?", [txId]).isNotEmpty;
      for (final id in u.bills) {
        final b = db.select('SELECT * FROM bills WHERE id = ? AND deleted = 0 AND linked_tx IS NULL', [id]);
        if (!held && b.isNotEmpty) relink.add(Bill.fromRow(b.first));
      }
      for (final id in u.matched) {
        if (db.select('SELECT 1 FROM tx WHERE id = ? AND manual = 1 AND deleted = 0 AND matched_to IS NULL', [id]).isNotEmpty) {
          rematch.add(id);
        }
      }
      for (final id in u.transfer) {
        if (db.select('SELECT 1 FROM tx WHERE id = ? AND deleted = 0 AND transfer_to IS NULL', [id]).isNotEmpty) repair.add(id);
      }
    }
    _write([
      ('tx', txId, {'deleted': 0}),
      // One bill per payment row (the field-pair repair would unlink the others anyway).
      for (final b in relink.take(1)) ..._billWrites(b, {'linked_tx': txId}, today),
      for (final id in rematch) ('tx', id, {'matched_to': txId}),
      for (final id in repair) ('tx', id, {'transfer_to': txId}),
      // Its own side, when a caught-up repair cleared it meanwhile (a pair is always written on both rows).
      if (repair.length == 1 && rs.first['transfer_to'] == null) ('tx', txId, {'transfer_to': repair.single}),
    ]);
    db.execute('DELETE FROM meta WHERE key = ?', ['$_undoKey$txId']);
    logEvent(_log, Level.INFO, 'repo.undelete',
        {'entity': 'tx', 'bills': relink.take(1).length, 'matches': rematch.length, 'transfers': repair.length});
    _reconcileLocal();
  }

  void setMerchantRule(String key, String category) => _write([
        ('rule', key, {'category': category, 'deleted': 0})
      ]);

  /// Removes the payee rule [key] (a tombstone; the category stays stored, so `setMerchantRule` brings it back).
  /// Nothing is written when there is no live rule.
  void removeMerchantRule(String key) {
    if (db.select('SELECT 1 FROM merchant_rules WHERE id = ? AND deleted = 0', [key]).isEmpty) return;
    _write([
      ('rule', key, {'deleted': 1})
    ]);
  }
}
