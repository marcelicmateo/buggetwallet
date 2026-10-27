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
    final r = _planManualMatches();
    if (r.open == 0) {
      _clearMatchPending();
      t.done({'manual': r.manual.length, 'open': 0, 'bank': 0, 'added': 0});
      return 0;
    }
    final plan = r.plan;
    _write([
      for (final e in plan.matchedTo.entries) ('tx', e.key, {'matched_to': e.value}),
      for (final e in plan.bankCategory.entries) ('tx', e.key, {'category': e.value}),
      ..._matchedTagLinks(plan.matchedTo),
    ]);
    _clearMatchPending();
    t.done({
      'manual': r.manual.length,
      'open': r.open,
      'bank': r.bank,
      'added': plan.added,
      'unmatched': plan.matchedTo.values.where((v) => v == null).length,
      'categories': plan.bankCategory.length,
    });
    return plan.added;
  }

  /// The [planMatches] plan over the stored rows, read only. For [previewImport] the stored rows are seen as the import
  /// would leave them: [fresh] rows (not stored yet, written after every entry, so unseen by all of them) are added,
  /// [revived] ids read as live, and [transfers] (a [TransferPlan.transferTo]) overrides `transfer_to`.
  ({MatchPlan plan, List<Tx> manual, int open, int bank}) _planManualMatches(
      {List<Tx> fresh = const [], Set<String> revived = const {}, Map<String, String?> transfers = const {}}) {
    final written = <String, String>{}, seenBank = <String, String>{};
    Tx over(Tx tx) {
      var x = revived.contains(tx.id) ? _txWith(tx, deleted: false) : tx;
      if (transfers.containsKey(x.id)) x = _txWith(x, transferTo: transfers[x.id]);
      return x;
    }

    List<Tx> rows(String where, [List<Object?> args = const []]) {
      final out = <Tx>[];
      for (final r in db.select('SELECT tx.*, c.hlc AS written FROM tx $_writtenJoin WHERE $where', args)) {
        final tx = Tx.fromRow(r);
        if (r['written'] case final String h) written[tx.id] = h;
        if (r['seen_bank'] case final String v) seenBank[tx.id] = v;
        out.add(over(tx));
      }
      return out;
    }

    // Rows the import would add: written after everything this device holds or has received.
    final extra = [for (final f in fresh) over(f)];
    if (extra.isNotEmpty) {
      final after = Hlc(_afterAllMillis, 0, deviceId).toString();
      for (final f in extra) {
        written[f.id] = after;
      }
    }
    final ids = [...revived];
    for (var i = 0; i < ids.length; i += _chunk) {
      final part = ids.sublist(i, min(i + _chunk, ids.length));
      extra.addAll(rows('tx.id IN (${List.filled(part.length, '?').join(',')})', part).where((r) => !r.manual));
    }

    const live = 'tx.manual = 0 AND tx.deleted = 0';
    final manual = rows('tx.manual = 1 AND tx.deleted = 0');
    // Every row an entry points at, deleted ones included: only a deleted target (or one that is not a bank row, or
    // was paired as an own transfer) reopens its entry. A target this device has not received yet keeps the match
    // (no unmatch/rematch churn).
    final targets = rows('tx.id IN (SELECT matched_to FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to IS NOT NULL)');
    if (extra.isNotEmpty) {
      final pointed = {for (final m in manual) m.matchedTo};
      final have = {for (final b in targets) b.id};
      targets.addAll([
        for (final x in extra)
          if (pointed.contains(x.id) && have.add(x.id)) x
      ]);
    }
    final open = openEntries(manual, {
      for (final b in targets)
        if (b.manual || b.deleted || b.transferTo != null) b.id
    });
    if (open.isEmpty) return (plan: const MatchPlan({}, {}, 0), manual: manual, open: 0, bank: 0);
    final bank = {for (final b in targets) b.id: b};
    for (final m in open) {
      final since = written[m.id];
      if (since == null || !isIsoDate(m.date)) continue;
      // Candidates for this entry only: same amount, within the window, and not on its device when it was added.
      // Without a seen_bank value, only rows written in or after the entry's millisecond (comparing the 15-digit
      // millis prefix as text is safe for any counter).
      final seen = SeenBank.of(since, seenBank[m.id]);
      final from = addDays(m.date, -matchDays), to = addDays(m.date, matchDays);
      final window = [m.amount, from, to];
      for (final b in [
        ...(seen.recorded
            ? rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ?', window)
            : rows('$live AND tx.amount = ? AND tx.date BETWEEN ? AND ? AND c.hlc >= ?', [...window, since.split(':').first])),
        for (final x in extra)
          if (!x.manual && !x.deleted && x.amount == m.amount && x.date.compareTo(from) >= 0 && x.date.compareTo(to) <= 0) x,
      ]) {
        if (written[b.id] case final String at when seen.unseen(at)) bank[b.id] = b;
      }
    }
    final cz = categorizer(withTags: false);
    final plan = planMatches(manual, [...bank.values], (b) {
      final k = cz.table.kindOf(cz.autoCategory(b));
      return k == BudgetKind.flex || k == BudgetKind.fixed;
    }, written, seenBank: seenBank);
    return (plan: plan, manual: manual, open: open.length, bank: bank.length);
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
    final r = _planPairs();
    final plan = r.plan;
    _write([
      for (final e in plan.transferTo.entries) ('tx', e.key, {'transfer_to': e.value})
    ]);
    t.done({'candidates': r.candidates, 'rows': r.rows, 'paired': plan.paired, 'reopened': plan.reopened});
    return plan.paired;
  }

  /// The [planTransfers] plan over the stored rows, read only. For [previewImport]: [fresh] rows are added as the import
  /// would write them, [revived] ids read as live, and so are the stored rows that could pair with one of them (open,
  /// the opposite amount) or point at one: a superset of what [_pairTransfers] loads after that import, and the plan
  /// only pairs rows that have a partner, so it is the same plan.
  ({TransferPlan plan, int candidates, int rows}) _planPairs({List<Tx> fresh = const [], Set<String> revived = const {}}) {
    final rows = <String, Tx>{};
    void load(String sql, [List<Object?> args = const []]) {
      for (final r in db.select(sql, args)) {
        final tx = Tx.fromRow(r);
        rows[tx.id] = revived.contains(tx.id) ? _txWith(tx, deleted: false) : tx;
      }
    }

    void loadIn(String sqlPrefix, List<Object?> values) {
      for (var i = 0; i < values.length; i += _chunk) {
        final part = values.sublist(i, min(i + _chunk, values.length));
        load('$sqlPrefix (${List.filled(part.length, '?').join(',')})', part);
      }
    }

    load('SELECT DISTINCT a.* FROM tx a JOIN tx b ON b.amount = -a.amount AND b.currency = a.currency AND b.source != a.source '
        "AND b.date BETWEEN date(a.date, '-$transferDays days') AND date(a.date, '+$transferDays days') AND ${_openTransfer('b')} "
        "WHERE a.date != '' AND (a.kind_hint = '$_own' OR b.kind_hint = '$_own') AND ${_openTransfer('a')}");
    final candidates = rows.length;
    load('SELECT a.* FROM tx a WHERE a.transfer_to IS NOT NULL AND ${_openTransfer('a')}');
    if (fresh.isNotEmpty || revived.isNotEmpty) {
      loadIn('SELECT * FROM tx WHERE id IN', [...revived]);
      final added = [
        ...fresh,
        for (final id in revived)
          if (rows[id] case final Tx x) x
      ];
      loadIn('SELECT a.* FROM tx a WHERE ${_openTransfer('a')} AND a.amount IN', [
        ...{for (final x in added) -x.amount}
      ]);
      loadIn('SELECT * FROM tx WHERE transfer_to IN', [for (final x in added) x.id]);
      for (final f in fresh) {
        rows[f.id] = f;
      }
    }
    final targets = [
      for (final r in rows.values)
        if (r.transferTo case final String to when !rows.containsKey(to)) to
    ];
    if (targets.isNotEmpty) loadIn('SELECT * FROM tx WHERE id IN', targets);
    return (plan: planTransfers([...rows.values]), candidates: candidates, rows: rows.length);
  }

  /// Most `?` parameters in one `IN (...)` list.
  static const _chunk = 500;

  /// A millisecond after every clock this wallet holds (15 digits, like every stored clock; exact on the web too).
  static const _afterAllMillis = 999999999999999;

  // ---------- import preview (Q4) ----------
  /// What [WalletRepo.importBatch] would do with [batch] (with the same [revive] set), row by row, without writing
  /// anything (no row, clock, outbox entry or device-local value; the HLC is not advanced). Reads the stored ids the
  /// same way `importBatch` does: a row beyond ±[maxAmountCents] is [PreviewStatus.tooLarge]; a stored id (or one an
  /// earlier row of the batch took) is a duplicate, or a collision when amount or description differ; a deleted one
  /// in [revive] with the same values is [PreviewStatus.revivable]; the rest are fresh. Then, only while
  /// [WalletRepo.syncCaughtUp] (otherwise the import pairs and matches nothing either), the same [planTransfers] and
  /// [planMatches] the import runs, over the stored rows plus the batch's fresh rows as unseen by every hand-added
  /// entry: a fresh row an entry ends up pointing at (a new match, or one made on another device before this row
  /// arrived) is [PreviewStatus.matchesManual] with [PreviewRow.matchedManualId]; a row the plan pairs gets
  /// [PreviewRow.transferPairId]. `importBatch(batch, revive: revive)` then writes exactly that (see
  /// `test/q4_import_preview_test.dart`). Logged as `repo.preview` on `bw.perf` (counts only).
  ImportPreview previewImport(ImportBatch batch, {Set<String> revive = const {}}) {
    final t = PerfTimer('repo.preview');
    final c = _classifyBatch(batch, revive: revive);
    final fresh = [
      for (final (i, n) in batch.transactions.indexed)
        if (c.fates[i] == _RowFate.fresh) _txOf(n)
    ];
    final revived = {
      for (final (i, n) in batch.transactions.indexed)
        if (c.fates[i] == _RowFate.revived) n.id
    };
    final ids = {for (final f in fresh) f.id, ...revived};
    // What is stored now: a revived row keeps its `transfer_to`, and an entry may already point at a batch row (matched
    // on another device before the row arrived here). The import leaves both as they are unless its plan changes them.
    final transferTo = <String, String?>{};
    final rev = [...revived];
    for (var i = 0; i < rev.length; i += _chunk) {
      final part = rev.sublist(i, min(i + _chunk, rev.length));
      for (final r in db.select('SELECT id, transfer_to FROM tx WHERE id IN (${List.filled(part.length, '?').join(',')})', part)) {
        transferTo[r['id'] as String] = r['transfer_to'] as String?;
      }
    }
    final matchedTo = <String, String?>{
      if (ids.isNotEmpty)
        for (final r in db.select('SELECT id, matched_to FROM tx WHERE manual = 1 AND deleted = 0 AND matched_to IS NOT NULL ORDER BY id'))
          r['id'] as String: r['matched_to'] as String?
    };
    // Pairing and matching run only while caught up (as in the import): only then does the plan change those links.
    if (syncCaughtUp && ids.isNotEmpty) {
      final pairs = _planPairs(fresh: fresh, revived: revived).plan.transferTo;
      transferTo.addAll(pairs);
      final m = _planManualMatches(fresh: fresh, revived: revived, transfers: pairs);
      matchedTo.addAll(m.plan.matchedTo);
    }
    final matchedBy = <String, String>{}; // bank row id -> the entry pointing at it after the import
    for (final e in [...matchedTo.keys]..sort()) {
      final to = matchedTo[e];
      if (to != null && ids.contains(to)) matchedBy.putIfAbsent(to, () => e);
    }
    final rows = <PreviewRow>[];
    for (final (i, n) in batch.transactions.indexed) {
      final fate = c.fates[i];
      final written = fate == _RowFate.fresh || fate == _RowFate.revived;
      final entry = written ? matchedBy[n.id] : null;
      rows.add(PreviewRow(
        tx: n,
        status: switch (fate) {
          _RowFate.fresh => entry != null ? PreviewStatus.matchesManual : PreviewStatus.fresh,
          _RowFate.revived => PreviewStatus.revivable,
          _RowFate.duplicate || _RowFate.skipped => PreviewStatus.duplicate,
          _RowFate.collision => PreviewStatus.collision,
          _RowFate.tooLarge => PreviewStatus.tooLarge,
        },
        matchedManualId: entry,
        transferPairId: written ? transferTo[n.id] : null,
      ));
    }
    final p = ImportPreview.of(rows);
    t.done({
      'source': sourceLogKey(batch.source),
      'rows': rows.length,
      'fresh': p.fresh,
      'dupes': p.duplicates,
      'collisions': p.collisions,
      'revivable': p.revivable,
      'matches': p.matchesManual,
      'transfers': p.transfers,
      'tooLarge': p.tooLarge,
    });
    return p;
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

/// What [WalletRepo.importBatch] does with one batch row (`_classifyBatch`).
enum _RowFate { fresh, revived, duplicate, collision, tooLarge, skipped }

/// A batch row as the import stores it (no category, not manual, live).
Tx _txOf(NormalizedTransaction n) => Tx(
      id: n.id,
      source: n.source,
      date: n.date,
      amount: n.amountMinor,
      currency: n.currency,
      bankType: n.bankType,
      description: n.description,
      kindHint: n.kindHint,
    );

const _keep = Object();

/// [t] with `transfer_to` and/or `deleted` replaced (the import preview's view of rows after the import).
Tx _txWith(Tx t, {Object? transferTo = _keep, bool? deleted}) => Tx(
      id: t.id,
      source: t.source,
      date: t.date,
      amount: t.amount,
      currency: t.currency,
      bankType: t.bankType,
      description: t.description,
      category: t.category,
      note: t.note,
      manual: t.manual,
      matchedTo: t.matchedTo,
      deleted: deleted ?? t.deleted,
      kindHint: t.kindHint,
      transferTo: identical(transferTo, _keep) ? t.transferTo : transferTo as String?,
      matchPending: t.matchPending,
      homeAmount: t.homeAmount,
    );
