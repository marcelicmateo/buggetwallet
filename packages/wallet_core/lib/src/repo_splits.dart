part of 'repo.dart';

/// Split transactions (P6, schema 13; see [SplitPart]): the `split` entity, id = the tx id, the whole split one JSON
/// field. Every rule is an [ArgumentError] with an owner-readable message, checked on local writes only (sync never
/// refuses an op; a split that stops fitting is ignored when read, `Categorizer.expand`). Logs carry counts only.
extension WalletRepoSplits on WalletRepo {
  /// Splits payment [txId] into [parts] (2..[SplitPart.maxParts]), replacing any split it has (a removed one
  /// included: this undeletes it). The payment must exist, be live and not be a transfer (paired as an own transfer,
  /// or its main tag is a transfer). Each part: a non-zero amount of the payment's sign, the amounts summing to the
  /// payment's exactly; a live main tag that is not a transfer; live extra tags (stored as the tag the owner sees,
  /// [TagTable.resolve]), no repeats, at most [SplitPart.maxTags]; a note of at most [SplitPart.maxNote] characters
  /// after trimming (empty: none). A part is in the payment's currency. Anything else: [ArgumentError].
  void setSplit(String txId, List<SplitPart> parts) {
    final tx = transaction(txId);
    if (tx == null || !tx.live) throw ArgumentError('No such transaction.');
    final cz = categorizer(withTags: false);
    if (tx.transferTo != null || cz.table.kindOf(cz.categoryOf(tx)) == BudgetKind.transfer) {
      throw ArgumentError('A transfer cannot be split.');
    }
    if (tx.amount == 0) throw ArgumentError('A payment of 0.00 cannot be split.');
    if (parts.length < SplitPart.minParts) throw ArgumentError('A split needs at least ${SplitPart.minParts} parts.');
    if (parts.length > SplitPart.maxParts) throw ArgumentError('A split can have at most ${SplitPart.maxParts} parts.');
    final tags = tagTable();
    var sum = 0;
    final clean = <SplitPart>[];
    for (final p in parts) {
      if (p.amount == 0) throw ArgumentError('Every part needs an amount.');
      if ((p.amount < 0) != (tx.amount < 0)) {
        throw ArgumentError(tx.amount < 0 ? 'Every part of an expense is money out.' : 'Every part of income is money in.');
      }
      sum += p.amount;
      if (!cz.table.isLive(p.category)) throw ArgumentError('No such main tag.');
      if (cz.table.kindOf(p.category) == BudgetKind.transfer) throw ArgumentError('A part cannot be a transfer.');
      if (p.tags.length > SplitPart.maxTags) throw ArgumentError('A part can have at most ${SplitPart.maxTags} tags.');
      final ids = <String>[];
      for (final id in p.tags) {
        final r = tags.resolve(id);
        if (r == null) throw ArgumentError('No such tag.');
        if (ids.contains(r)) throw ArgumentError('A part has the same tag twice.');
        ids.add(r);
      }
      final note = p.note?.trim();
      if (note != null && note.runes.length > SplitPart.maxNote) {
        throw ArgumentError('A part note is limited to ${SplitPart.maxNote} characters.');
      }
      clean.add(SplitPart(amount: p.amount, category: p.category, tags: ids, note: note == null || note.isEmpty ? null : note));
    }
    if (sum != tx.amount) throw ArgumentError("The parts don't add up to the payment.");
    _write([
      ('split', txId, {'parts': encodeSplitParts(clean), 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'split.set', {'parts': clean.length});
  }

  /// Removes payment [txId]'s split (`deleted: 1`): it counts whole again. A bank row that only reads its hand-added
  /// entry's split ([splitOf]) gets a removed split of its own, which stops the read-through. No split: nothing is
  /// written.
  void removeSplit(String txId) {
    final own = db.select('SELECT deleted FROM tx_splits WHERE id = ?', [txId]);
    if (own.isNotEmpty ? own.first['deleted'] == 1 : _entrySplit(txId) == null) return;
    _write([
      ('split', txId, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'split.remove', {'splits': 1});
  }

  /// Payment [txId]'s split as it counts, whether it still fits the payment or not ([splitFits]); null when it has
  /// none. Its own when it has a split row (a removed one: none); else, for a bank row that replaced a hand-added entry
  /// (`matched_to`), the entry's live split, read through the match, so a split made on the entry on any device, before
  /// or after the match, follows it (like T1's tags, but never copied). An unreadable stored split reads as an empty
  /// list (the payment counts whole, `CategorizedTx.splitBroken`).
  List<SplitPart>? splitOf(String txId) {
    final rs = db.select('SELECT parts, deleted FROM tx_splits WHERE id = ?', [txId]);
    if (rs.isNotEmpty) return rs.first['deleted'] == 1 ? null : decodeSplitParts(rs.first['parts']);
    return _entrySplit(txId);
  }

  /// The live split of the live hand-added entry matched to bank row [bankId] (the smallest entry id if several).
  List<SplitPart>? _entrySplit(String bankId) {
    final rs = db.select(
        'SELECT s.parts FROM tx t JOIN tx_splits s ON s.id = t.id '
        'WHERE t.manual = 1 AND t.deleted = 0 AND t.matched_to = ? AND s.deleted = 0 ORDER BY t.id LIMIT 1',
        [bankId]);
    return rs.isEmpty ? null : decodeSplitParts(rs.first['parts']);
  }

  /// Every split as it counts (tx id → parts, as [splitOf]: own live splits, plus entries' splits read through their
  /// match onto bank rows without a split row), in two reads: for [WalletRepo.categorizer].
  Map<String, List<SplitPart>> splits() {
    final t = PerfTimer('repo.splits');
    final out = <String, List<SplitPart>>{};
    final rows = <String>{};
    for (final r in db.select('SELECT id, parts, deleted FROM tx_splits')) {
      final id = r['id'] as String;
      rows.add(id);
      if (r['deleted'] != 1) out[id] = decodeSplitParts(r['parts']);
    }
    var through = 0;
    for (final r in db.select('SELECT t.matched_to AS bank, s.parts FROM tx t JOIN tx_splits s ON s.id = t.id '
        'WHERE t.manual = 1 AND t.deleted = 0 AND t.matched_to IS NOT NULL AND s.deleted = 0 ORDER BY t.id')) {
      final bank = r['bank'] as String;
      if (rows.add(bank)) {
        out[bank] = decodeSplitParts(r['parts']);
        through++;
      }
    }
    t.done({'splits': out.length, 'through': through});
    return out;
  }
}
