part of 'repo.dart';

/// What runs after rows change ([_reconcile]: after [WalletRepo.importBatch], deletes and sync runs): matching
/// hand-added entries to bank rows and pairing own-account transfers.
extension WalletRepoImport on WalletRepo {
  /// The `on` links (T1) of each hand-added entry in [matchedTo] (entry id → bank row id; null = reopened, skipped), copied to its bank row
  /// (`<bankId>|<tagId>`), so the row that replaces it keeps the tags the owner gave it. `off` links are never copied,
  /// nor a link the bank row already has for that tag. Written with the match; a later reopen leaves them (like the
  /// category).
  List<(String, String, Map<String, Object?>)> _matchedTagLinks(Map<String, String?> matchedTo) {
    if (matchedTo.isEmpty) return const [];
    final out = <(String, String, Map<String, Object?>)>[];
    for (final MapEntry(key: entry, value: bank) in matchedTo.entries) {
      if (bank == null) continue; // a reopened match keeps what was copied
      final have = {
        for (final r in db.select('SELECT tag FROM tx_tags WHERE tx = ?', [bank])) r['tag'] as String
      };
      for (final r in db.select("SELECT tag FROM tx_tags WHERE tx = ? AND state = 'on' AND tag != ''", [entry])) {
        final tag = r['tag'] as String;
        if (have.add(tag)) out.add(('txtag', '$bank|$tag', {'tx': bank, 'tag': tag, 'state': 'on'}));
      }
    }
    return out;
  }

  // ---------- matching and pairing (hand-added entries ↔ bank rows, own transfers) ----------
  /// Each row's first write, for [planMatches] and `seen_bank`: the clock of its `amount`. Only the write that creates a row sets it
  /// (importBatch, addTransaction; matching, categories and deletes never touch it), and the clocks table converges to the
  /// same value on every device. If the same bank row is imported on two devices before they sync, the later import
  /// wins (highest HLC per field), so the row counts as written at that later import.
  static const _writtenJoin = "LEFT JOIN clocks c ON c.entity = 'tx' AND c.id = tx.id AND c.field = 'amount'";

  /// Matches hand-added expenses to bank rows ([planMatches]) and writes the changes. Returns the new matches.
  ///
  /// Loads the manual entries, the bank rows they point at, and for each open entry ([openEntries]) only the bank
  /// rows that could replace it, so a large history costs little. Logged as `repo.match` on `bw.perf` once per run.
  int _matchManual() {
    final t = PerfTimer('repo.match');
    final written = <String, String>{}, seenBank = <String, String>{};
    List<Tx> rows(String where, [List<Object?> args = const []]) {
      final out = <Tx>[];
      for (final r in db.select('SELECT tx.*, c.hlc AS written FROM tx $_writtenJoin WHERE $where', args)) {
        final tx = Tx.fromRow(r);
        if (r['written'] case final String h) written[tx.id] = h;
        if (r['seen_bank'] case final String v) seenBank[tx.id] = v;
        out.add(tx);
      }
      return out;
    }

    const live = 'tx.manual = 0 AND tx.deleted = 0';
    final manual = rows('tx.manual = 1 AND tx.deleted = 0');
    // Every row an entry points at, deleted ones included: only a deleted target (or one that is not a bank row, or
    // was paired as an own transfer) reopens its entry. A target this device has not received yet keeps the match
    // (no unmatch/rematch churn).
    final targets = rows('tx.id IN (SELECT matched_to FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to IS NOT NULL)');
    final open = openEntries(manual, {
      for (final b in targets)
        if (b.manual || b.deleted || b.transferTo != null) b.id
    });
    if (open.isEmpty) {
      _clearMatchPending();
      t.done({'manual': manual.length, 'open': 0, 'bank': 0, 'added': 0});
      return 0;
    }
    final bank = {for (final b in targets) b.id: b};
    for (final m in open) {
      final since = written[m.id];
      if (since == null || !isIsoDate(m.date)) continue;
      // Candidates for this entry only: same amount, within the window, and not on its device when it was added.
      // Without a seen_bank value, only rows written in or after the entry's millisecond (comparing the 15-digit
      // millis prefix as text is safe for any counter).
      final seen = SeenBank.of(since, seenBank[m.id]);
      final window = [m.amount, addDays(m.date, -matchDays), addDays(m.date, matchDays)];
      for (final b in seen.recorded
          ? rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ?', window)
          : rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ? AND c.hlc >= ?', [...window, since.split(':').first])) {
        if (written[b.id] case final String at when seen.unseen(at)) bank[b.id] = b;
      }
    }
    final cz = categorizer(withTags: false);
    final plan = planMatches(manual, [...bank.values], (b) {
      final k = cz.table.kindOf(cz.autoCategory(b));
      return k == BudgetKind.flex || k == BudgetKind.fixed;
    }, written, seenBank: seenBank);
    _write([
      for (final e in plan.matchedTo.entries) ('tx', e.key, {'matched_to': e.value}),
      for (final e in plan.bankCategory.entries) ('tx', e.key, {'category': e.value}),
      ..._matchedTagLinks(plan.matchedTo),
    ]);
    _clearMatchPending();
    t.done({
      'manual': manual.length,
      'open': open.length,
      'bank': bank.length,
      'added': plan.added,
      'unmatched': plan.matchedTo.values.where((v) => v == null).length,
      'categories': plan.bankCategory.length,
    });
    return plan.added;
  }

  void _clearMatchPending() => db.execute("DELETE FROM meta WHERE key = 'match_pending'");

  /// A live bank row that needs a transfer partner: no `transfer_to`, or a link that no longer holds because the
  /// partner here is deleted, is a manual row, points elsewhere, or neither side is a hinted own transfer (mirrors
  /// `openTransfers`; a partner not here at all keeps the link). `x` is the row's alias.
  static String _openTransfer(String x) => '($x.manual = 0 AND $x.deleted = 0 AND $x.amount != 0 AND ($x.transfer_to IS NULL '
      'OR $x.transfer_to = $x.id OR EXISTS (SELECT 1 FROM tx p WHERE p.id = $x.transfer_to AND (p.deleted = 1 OR p.manual = 1 '
      "OR IFNULL(p.transfer_to, '') != $x.id OR ($x.kind_hint IS NOT '$_own' AND p.kind_hint IS NOT '$_own')))))";

  static const _own = 'ownTransfer';

  /// Pairs own-account transfers ([planTransfers]) and writes the links. Returns the new pairs.
  ///
  /// Loads only the rows that can pair: open rows with an open opposite-amount row of the same currency in another
  /// source within [transferDays], one of the two a hinted own transfer (a self-join on `amount`, indexed), plus open
  /// rows with a stale link (to clear it; a pair with no hint on either side is stale) and the rows those links point
  /// at (so the plan checks them the same way). Logged as `repo.transfers` on `bw.perf`.
  int _pairTransfers() {
    final t = PerfTimer('repo.transfers');
    final rows = <String, Tx>{};
    void load(String sql, [List<Object?> args = const []]) {
      for (final r in db.select(sql, args)) {
        final tx = Tx.fromRow(r);
        rows[tx.id] = tx;
      }
    }

    load('SELECT DISTINCT a.* FROM tx a JOIN tx b ON b.amount = -a.amount AND b.currency = a.currency AND b.source != a.source '
        "AND b.date BETWEEN date(a.date, '-$transferDays days') AND date(a.date, '+$transferDays days') AND ${_openTransfer('b')} "
        "WHERE a.date != '' AND (a.kind_hint = '$_own' OR b.kind_hint = '$_own') AND ${_openTransfer('a')}");
    final candidates = rows.length;
    load('SELECT a.* FROM tx a WHERE a.transfer_to IS NOT NULL AND ${_openTransfer('a')}');
    final targets = [
      for (final r in rows.values)
        if (r.transferTo case final String to when !rows.containsKey(to)) to
    ];
    if (targets.isNotEmpty) {
      load('SELECT * FROM tx WHERE id IN (${List.filled(targets.length, '?').join(',')})', targets);
    }
    final plan = planTransfers([...rows.values]);
    _write([
      for (final e in plan.transferTo.entries) ('tx', e.key, {'transfer_to': e.value})
    ]);
    t.done({'candidates': candidates, 'rows': rows.length, 'paired': plan.paired, 'reopened': plan.reopened});
    return plan.paired;
  }

  /// After rows changed (import, delete, remote ops): pairs own-account transfers, then matches hand-added expenses
  /// (a paired row is a transfer, so it is no longer a payment a cash entry could be), then links confirmed bills to
  /// their payments ([planBillLinks]). Returns (pairs, matches).
  (int, int) _reconcile() => _asInternal(() {
        final pairs = _pairTransfers();
        final matches = _matchManual();
        _moveMatchedAttachments();
        _repairFieldPairs();
        _autoLinkBills();
        return (pairs, matches);
      });

  /// After a local change of rows (import, delete, a migration rewrite): pairing and matching at once when
  /// [syncCaughtUp], else only marked due ([runPendingMatch] runs it on the next caught-up sync). Returns (pairs,
  /// matches), (0, 0) when deferred.
  (int, int) _reconcileLocal() {
    if (syncCaughtUp) return _reconcile();
    _setMeta('match_pending', '1');
    logEvent(_log, Level.INFO, 'repo.match.deferred');
    return (0, 0);
  }

  /// Runs transfer pairing and matching if ops applied with `applyRemote(match: false)` changed something since it
  /// last ran (also after a crash mid-sync: the flag is stored). `SyncEngine.run` calls it once, only when caught up.
  void runPendingMatch() {
    if (_meta('match_pending') == null) return;
    _asInternal(() {
      _reconcile();
      refreshRecurring(_today());
    });
  }
}
