part of 'repo.dart';

/// The change log: applying ops field by field ([_apply], [applyRemote]), the outbox ([markExported]), snapshots
/// ([snapshotOps]), clock stats and the device-local sync bookkeeping (cursors, recorded relay files).
extension WalletRepoSyncApply on WalletRepo {
  // ---------- change log ----------
  /// Applies [op] field by field: a field wins if its HLC is newer than the one stored for it ([clocks]).
  ///
  /// Each known field's value is checked first ([_fieldValue]): one of the wrong type (another device's bug, a damaged
  /// op) is ignored and logged as `repo.badField` with the entity and field name only, and its clock is not recorded,
  /// so a later valid write still wins. The decision depends only on the op, so every device makes the same one. The
  /// row is created only when at least one field applies: an op with no usable field leaves nothing behind.
  ///
  /// An equal clock keeps the stored value. With [repair] (ops of a repair resend, V2/VC) a field whose stored clock
  /// equals the op's but whose value differs (only a bug or damage does that) is added to [conflicts] for the owner to
  /// choose ([WalletRepoSyncApply.syncConflicts]).
  ///
  /// A row missing while this device still holds clocks for it (damage) is restored from the resend: its equal-clock
  /// fields take the resend's values. A field this device wrote later (newer clock) cannot be restored (its value is
  /// gone with the row): it becomes a conflict, and a row whose own `deleted` clock exists stays hidden (`deleted` 1,
  /// clock unchanged) until a resend field with an equal clock says otherwise or the owner chooses: a payment the owner
  /// deleted never comes back as spending by itself.
  ///
  /// Returns the fields that applied (their stored values), or null when none did.
  Map<String, Object?>? _apply(Op op, {bool repair = false, List<SyncConflict>? conflicts}) {
    final def = entitySchema[op.entity];
    if (def == null) return null;
    final table = def.table;
    final accepted = <String, Object?>{};
    Map<String, String>? stored; // field -> hlc, read once per (entity, id)
    Map<String, Object?>? row; // the stored row, read once per op and only for an equal clock in a repair
    final rowKey = '${op.entity}|${op.id}';
    bool lost() {
      if (_restoringRows.contains(rowKey)) return true;
      row ??= db.select('SELECT * FROM $table WHERE id = ?', [op.id]).firstOrNull ?? const <String, Object?>{};
      if (row!.isNotEmpty) return false;
      _restoringRows.add(rowKey);
      return true;
    }

    var restoring = false;
    for (final e in op.fields.entries) {
      final col = def.column(e.key);
      if (col == null) continue;
      final v = _fieldValue(op.entity, col, e.value);
      if (identical(v, _bad)) {
        logEvent(_log, Level.WARNING, 'repo.badField', {'entity': op.entity, 'field': e.key});
        continue;
      }
      stored ??= {
        for (final r in db.select('SELECT field, hlc FROM clocks WHERE entity = ? AND id = ?', [op.entity, op.id]))
          r['field'] as String: r['hlc'] as String
      };
      final have = stored[e.key];
      if (have != null) {
        final cmp = Hlc.compareStrings(have, op.hlc);
        if (cmp > 0) {
          // A newer local write of a field whose row is gone: its value is unknown here, so the owner decides.
          if (repair && lost()) {
            restoring = true;
            conflicts?.add(SyncConflict(
                id: SyncConflict.idOf(op.entity, op.id, col.name),
                entity: op.entity,
                rowId: op.id,
                field: col.name,
                mine: col.name == 'deleted' ? 1 : null,
                theirs: v,
                clock: have));
          }
          continue;
        }
        if (cmp == 0) {
          if (!repair) continue;
          if (lost()) {
            restoring = true;
          } else {
            final mine = row![col.name];
            if (jsonEncode(mine) != jsonEncode(v)) {
              conflicts?.add(SyncConflict(
                  id: SyncConflict.idOf(op.entity, op.id, col.name),
                  entity: op.entity,
                  rowId: op.id,
                  field: col.name,
                  mine: mine,
                  theirs: v,
                  clock: have));
            }
            continue;
          }
        }
      }
      accepted[e.key] = v;
    }
    if (accepted.isEmpty) return null;
    if (restoring && def.column('deleted') != null && stored!.containsKey('deleted') && !accepted.containsKey('deleted')) {
      // Hidden until an equal-clock `deleted` arrives or the owner chooses; its clock stays this device's.
      db.execute('INSERT OR IGNORE INTO $table(id, deleted) VALUES(?, 1)', [op.id]);
    }
    assert(!db.autocommit, 'data is written inside a transaction');
    _dataPending = true;
    if (_fxRelevant(op, accepted)) _fxPending = true;
    db.execute('INSERT OR IGNORE INTO $table(id) VALUES(?)', [op.id]);
    for (final k in accepted.keys) {
      db.execute('INSERT OR REPLACE INTO clocks(entity, id, field, hlc) VALUES(?, ?, ?, ?)', [op.entity, op.id, k, op.hlc]);
    }
    final sets = accepted.keys.map((k) => '$k = ?').join(', ');
    db.execute('UPDATE $table SET $sets WHERE id = ?', [...accepted.values, op.id]);
    return accepted;
  }

  static const _bad = Object();

  /// The largest magnitude each synced amount column takes (Q3). Imported row amounts and recurring amounts:
  /// [legacyRowCapCents] (10^12, what builds before Q imported), so no device drops a value an older build could
  /// write; planned costs, bills, wishes, account openings and a goal's `monthly` (summed in `computePeriod`): the one
  /// cap [maxAmountCents], which every build checked when typed. Goals' `target`/`saved` and contributions have none
  /// here: `goalTotal` already clamps each contribution and the total (`test/goal_contrib_test.dart`). Other integer
  /// columns (dates in ms, sort keys, sizes, counts) have none. New local writes stay at [maxAmountCents]
  /// ([isSafeCents]: `addTransaction`, `importBatch`). A [MoneyCol] (a bill's total, an account opening) carries its
  /// own cap ([MoneyCol.cap], the same [maxAmountCents]) and is not listed here.
  static const _amountCaps = <(String, String), int>{
    ('tx', 'amount'): legacyRowCapCents,
    ('planned', 'amount'): maxAmountCents,
    ('recurring', 'expected_amount'): legacyRowCapCents,
    ('recurring', 'min_amount'): legacyRowCapCents,
    ('recurring', 'max_amount'): legacyRowCapCents,
    ('wish', 'price'): maxAmountCents,
    ('goal', 'monthly'): maxAmountCents,
    ('iou', 'amount'): maxAmountCents,
    ('iou_part', 'amount'): maxAmountCents,
  };

  /// [value] as it is stored in column [col] ([ColumnType]: a 0/1 flag takes a bool or 0/1, an integer column an
  /// int, every other column text), or [_bad] if it has the wrong type. NULL only in a nullable column. A whole
  /// number sent as a float (`12.0`) within the range a double holds exactly is accepted; fractions, huge or
  /// non-finite floats are not.
  ///
  /// Q3: an amount column ([_amountCaps]) beyond its cap is [_bad] too, so an op over it is quarantined like a
  /// wrong-typed one (logged with the entity and field only): sums of amounts stay exact (see [isSafeCents]).
  static Object? _fieldValue(String entity, ColumnDef col, Object? value) {
    if (value == null) return col.nullable ? null : _bad;
    switch (col.type) {
      case ColumnType.flag:
        return switch (value) { true || 1 => 1, false || 0 => 0, _ => _bad };
      case ColumnType.integer:
        const exact = 9007199254740992; // 2^53
        final v = switch (value) {
          final int v => v,
          final double v when v.isFinite && v == v.roundToDouble() && v.abs() <= exact => v.toInt(),
          _ => null,
        };
        if (v == null) return _bad;
        final cap = col is MoneyCol ? col.cap : _amountCaps[(entity, col.name)];
        // Both bounds, never `abs()`: the smallest int's abs() is itself (negative) and would pass.
        return cap != null && (v > cap || v < -cap) ? _bad : v;
      case ColumnType.text:
        return value is String ? value : _bad;
    }
  }

  void markExported(int upToSeq) {
    db.execute('DELETE FROM outbox WHERE seq <= ?', [upToSeq]);
    logEvent(_log, Level.FINE, 'repo.markExported', {'upTo': upToSeq, 'removed': db.updatedRows});
  }

  /// Applies ops from another device. Returns how many changed something here.
  ///
  /// A manual entry and its bank row can arrive in either order (imported on another device before the entry
  /// synced), so matching runs after remote changes too; it is deterministic, so every device writes the same
  /// matches. With [match] false (a sync applying many files) it only records that matching is due, and the caller
  /// runs it once at the end with [runPendingMatch].
  ///
  /// With [resend] the ops are also queued in the outbox, clocks unchanged, so this device's next sync carries them
  /// to the other devices like its own writes (a restore from a backup, see `restoreBackup`). Devices that already
  /// hold those fields with the same clocks change nothing when they read them (a clock is only accepted when newer).
  ///
  /// With [resendChanged] (a merge from a backup) only the fields that changed something here are queued, each op cut
  /// to those fields with its clock unchanged; ops this wallet already held (or held newer) are not re-sent.
  ///
  /// With [repair] (a repair resend, VC) an equal clock with a different value keeps the stored value and is recorded
  /// as a device-local conflict ([syncConflicts]) for the owner to choose. Ops of unknown entities (records such as
  /// `_digest`/`_repair`, kinds of newer builds) are skipped either way.
  int applyRemote(List<Op> ops, {bool match = true, bool resend = false, bool resendChanged = false, bool repair = false}) =>
      applyRemoteByEntity(ops, match: match, resend: resend, resendChanged: resendChanged, repair: repair).values.fold(0, (a, b) => a + b);

  /// [applyRemote], returning how many ops changed a field, per entity (entities with none left out).
  ///
  /// With [dryRun] the ops are applied in a transaction that is rolled back: the counts are those a real apply would
  /// give, and tables, clocks, outbox, the HLC (in memory and stored) and the match flag stay exactly as they were;
  /// nothing is queued and matching does not run. [beforeRollback] runs inside that transaction after the ops, so it
  /// reads the merged state (the backup's bill-file count).
  Map<String, int> applyRemoteByEntity(List<Op> ops,
      {bool match = true,
      bool resend = false,
      bool resendChanged = false,
      bool dryRun = false,
      bool repair = false,
      void Function()? beforeRollback}) {
    final t = PerfTimer('repo.applyRemote');
    final byEntity = <String, int>{};
    var changed = 0;
    if (dryRun) {
      // No clock.receive: _apply decides on the stored clocks only, and the in-memory HLC is not rolled back by SQLite.
      db.execute('BEGIN');
      try {
        for (final op in ops) {
          if (_apply(op) != null) {
            byEntity[op.entity] = (byEntity[op.entity] ?? 0) + 1;
            changed++;
          }
        }
        beforeRollback?.call();
      } finally {
        if (!db.autocommit) db.execute('ROLLBACK');
        _dataPending = false;
        _fxPending = false; // nothing was committed: no fill
        _fxHome = null;
      }
      t.done({'ops': ops.length, 'changed': changed, 'dryRun': true});
      return byEntity;
    }
    final conflicts = <SyncConflict>[];
    if (!repair) _restoringRows.clear();
    _tx(() {
      for (final op in ops) {
        clock.receive(Hlc.parse(op.hlc));
        final accepted = _apply(op, repair: repair, conflicts: conflicts);
        if (accepted != null) {
          byEntity[op.entity] = (byEntity[op.entity] ?? 0) + 1;
          changed++;
        }
        if (resend) {
          db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
        } else if (resendChanged && accepted != null) {
          db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(Op(op.entity, op.id, accepted, op.hlc).toJson())]);
        }
      }
      _setMeta('hlc', clock.last.toString());
      if (changed > 0) _setMeta('match_pending', '1');
      if (conflicts.isNotEmpty) _addConflicts(conflicts);
    });
    t.done({'ops': ops.length, 'changed': changed, 'resend': resend, 'resendChanged': resendChanged, 'repair': repair});
    if (match && syncCaughtUp) runPendingMatch();
    return byEntity;
  }

  /// The whole wallet as ops: for every row of every synced entity (deleted rows included, so a restore reproduces
  /// the state exactly) one op per distinct field clock, holding the fields written with that clock and their current
  /// values. A field with no clock (never written: the column default) is left out, so a restore records the same
  /// clocks as this device holds; a row with no clocked field at all gives no op. Device-local values (`local.*`
  /// meta, the outbox, sync cursors) are not included. Ordered by entity, id, clock.
  List<Op> snapshotOps() {
    final t = PerfTimer('repo.snapshot', warnMs: 1000);
    final out = <Op>[];
    for (final e in entitySchema.entries) {
      final entity = e.key;
      final def = e.value;
      final clocks = <String, Map<String, String>>{}; // id -> field -> hlc
      for (final r in db.select('SELECT id, field, hlc FROM clocks WHERE entity = ? ORDER BY id', [entity])) {
        if ((r['id'], r['field'], r['hlc']) case (final String id, final String f, final String h)) {
          if (def.column(f) != null) (clocks[id] ??= {})[f] = h;
        }
      }
      for (final r in db.select('SELECT * FROM ${def.table} ORDER BY id')) {
        final id = r['id'] as String;
        final byClock = <String, Map<String, Object?>>{};
        for (final MapEntry(key: f, value: h) in (clocks[id] ?? const {}).entries) {
          (byClock[h] ??= {})[f] = r[f];
        }
        final hlcs = byClock.keys.toList()..sort(Hlc.compareStrings);
        for (final h in hlcs) {
          out.add(Op(entity, id, byClock[h]!, h));
        }
      }
    }
    t.done({'ops': out.length});
    return out;
  }

  /// Queues the whole synced state ([snapshotOps], original clocks) in the outbox, so this device's next upload carries
  /// it to the other devices (V2 repair, after a state digest mismatch). Devices holding a field with the same or a
  /// newer clock change nothing (a repair applies these with the equal-clock tie-break). Returns the ops queued.
  int queueStateResend() {
    final ops = snapshotOps();
    _tx(() {
      for (final op in ops) {
        db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
      }
    });
    logEvent(_log, Level.INFO, 'repo.resendState', {'ops': ops.length});
    return ops.length;
  }

  /// Device-local key of the open conflicts (JSON list of [SyncConflict.toJson], oldest first).
  static const syncConflictsKey = 'syncConflicts';

  /// At most this many open conflicts are kept (the oldest dropped first, counted in the log).
  static const maxSyncConflicts = 500;

  List<Map<String, Object?>> _storedConflicts() {
    final raw = localValue(syncConflictsKey);
    if (raw == null) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List<Object?>)
          if (j is Map) Map<String, Object?>.from(j)
      ];
    } on Object catch (e, st) {
      logError(_log, 'repo.conflicts.unreadable', e, st);
      return [];
    }
  }

  void _saveConflicts(List<Map<String, Object?>> list) => setLocalValue(syncConflictsKey, list.isEmpty ? null : jsonEncode(list));

  /// Records [found] (one entry per field: a field seen again keeps one entry with the latest `theirs`).
  void _addConflicts(List<SyncConflict> found) {
    final list = _liveConflicts(_storedConflicts()).$1; // settled ones go before the cap counts
    for (final c in found) {
      list
        ..removeWhere((j) => SyncConflict.fromJson(j)?.id == c.id)
        ..add(c.toJson());
    }
    final dropped = list.length > maxSyncConflicts ? list.length - maxSyncConflicts : 0;
    if (dropped > 0) {
      list.removeRange(0, dropped);
      setLocalValue(syncConflictsDroppedKey, '1');
    }
    _saveConflicts(list);
    logEvent(_log, Level.WARNING, 'repo.conflicts', {'found': found.length, 'open': list.length, 'dropped': dropped});
  }

  /// The open conflicts (VC): fields this device and another hold with the same clock but different values, found by
  /// a repair resend; ordered by entity, row id, field. An entry whose field clock changed since (an edit on any
  /// device settles it), whose row is gone or whose value now equals the other device's is dropped here. `mine` is
  /// the value stored now.
  List<SyncConflict> syncConflicts() {
    final list = _storedConflicts();
    if (list.isEmpty) return const [];
    final (keep, out) = _liveConflicts(list);
    if (keep.length != list.length) {
      _saveConflicts(keep);
      logEvent(_log, Level.INFO, 'repo.conflicts.settled', {'settled': list.length - keep.length, 'open': keep.length});
    }
    out.sort((a, b) {
      final e = a.entity.compareTo(b.entity);
      if (e != 0) return e;
      final r = a.rowId.compareTo(b.rowId);
      return r != 0 ? r : a.field.compareTo(b.field);
    });
    return out;
  }

  /// Device-local mark (`'1'`): the [maxSyncConflicts] cap dropped entries, so some differences have no open entry;
  /// `SyncEngine` lets one more repair run once the list is empty, and clears it.
  static const syncConflictsDroppedKey = 'syncConflictsDropped';

  /// Drops every open conflict (VC): `SyncEngine` calls it when every peer digest it compared matched this device's,
  /// so no device holds the other values any more (a device wiped or retired since). Returns how many were open.
  int dropSyncConflicts() {
    final n = _storedConflicts().length;
    if (n > 0) {
      _saveConflicts(const []);
      logEvent(_log, Level.INFO, 'repo.conflicts.dropped', {'dropped': n});
    }
    return n;
  }

  /// The entries of [list] still open (field clock unchanged, row there, value still differs), with `mine` read now.
  (List<Map<String, Object?>>, List<SyncConflict>) _liveConflicts(List<Map<String, Object?>> list) {
    final keep = <Map<String, Object?>>[];
    final out = <SyncConflict>[];
    for (final j in list) {
      final c = SyncConflict.fromJson(j);
      final def = c == null ? null : entitySchema[c.entity];
      if (c == null || def == null || def.column(c.field) == null) continue;
      final clockNow = db.select('SELECT hlc FROM clocks WHERE entity = ? AND id = ? AND field = ?', [c.entity, c.rowId, c.field]);
      if (clockNow.isEmpty || clockNow.first['hlc'] != c.clock) continue;
      final row = db.select('SELECT ${c.field} AS v FROM ${def.table} WHERE id = ?', [c.rowId]);
      if (row.isEmpty) continue;
      final mine = row.first['v'];
      if (jsonEncode(mine) == jsonEncode(c.theirs)) continue;
      keep.add(j);
      out.add(SyncConflict.fromJson(j, mine: mine)!);
    }
    return (keep, out);
  }

  /// The owner's choice for conflict [id] (VC): writes the kept value ([keepMine]: this device's, else the other
  /// device's) as an owner write with a new clock, so it reaches every device and settles the conflict there too;
  /// the entry is removed. An id not open ([syncConflicts]) is an [ArgumentError].
  void resolveSyncConflict(String id, {required bool keepMine}) {
    final c = syncConflicts().where((c) => c.id == id).firstOrNull;
    if (c == null) throw ArgumentError.value(id, 'id', 'no such open conflict');
    _write([
      (c.entity, c.rowId, {c.field: keepMine ? c.mine : c.theirs})
    ]);
    _saveConflicts([
      for (final j in _storedConflicts())
        if (SyncConflict.fromJson(j)?.id != id) j
    ]);
    logEvent(_log, Level.INFO, 'repo.conflicts.resolved', {'entity': c.entity, 'keepMine': keepMine});
  }

  /// Lowercase hex SHA-256 of the synced state in a canonical form (V2): every entity of [entitySchema] by name (a
  /// line with the entity and its synced column names, sorted), then its rows (deleted ones included) by id (SQLite
  /// binary order, the same on the VM and the web), one JSON line each: the id, then per column its value and field
  /// clock (null when never written). Device-local tables and values (meta, outbox, cursors, caches) are left out. Two
  /// devices that applied the same ops give the same digest (no map-order dependence; values are SQLite integers, text
  /// or null).
  ///
  /// Cached per [dataVersion]: a second call without a data change in between returns the same text without reading
  /// the tables ([stateDigestComputations] counts the real computations). A change behind the change log (raw SQL, a
  /// bug) is seen once the next data change moves [dataVersion].
  String stateDigest() {
    if (_digestCache case (final int v, final String hex) when v == dataVersion) return hex;
    final t = PerfTimer('repo.stateDigest', warnMs: 1000);
    final (hex, rows) = _canonicalDigest(db);
    _digestCache = (dataVersion, hex);
    _digestRuns++;
    t.done({'rows': rows, 'isolate': false});
    return hex;
  }

  /// [stateDigest] of the state at data version [atVersion] (default: [dataVersion] now), computed off this isolate
  /// for a database file opened by [WalletRepo.open] (native): a new isolate reads the file on its own read-only
  /// connection (same key) in one read transaction, so the UI isolate stays free on a big wallet. In-memory and
  /// [WalletRepo.fromDatabase] repos (tests, the web) compute it here, like [stateDigest]. Shares its cache.
  ///
  /// Null when the data is not (or no longer) at [atVersion]: a write committed while the file was being read moves
  /// [dataVersion], and the result, which may hold the state before or after that write, is discarded (never cached).
  /// The caller records nothing then and asks again later. A failed isolate read (logged) falls back to [stateDigest].
  Future<String?> stateDigestAsync({int? atVersion}) async {
    final v = atVersion ?? dataVersion;
    if (v != dataVersion) return null;
    if (_digestCache case (final int c, final String hex) when c == v) return hex;
    final file = _file;
    if (file == null) return stateDigest();
    final t = PerfTimer('repo.stateDigest', warnMs: 1000);
    logEvent(_log, Level.FINER, 'repo.stateDigest.isolate'); // also the tests' cue to write meanwhile
    final String hex;
    final int rows;
    try {
      (hex, rows) = await sqlite.readInIsolate(file.$1, file.$2, WalletRepo.debugDigestReader ?? _canonicalDigest);
    } catch (e, st) {
      logError(_log, 'repo.stateDigest.isolateFailed', e, st);
      return v == dataVersion ? stateDigest() : null;
    }
    if (v != dataVersion) {
      t.done({'rows': rows, 'isolate': true, 'stale': true});
      return null;
    }
    _digestCache = (v, hex);
    _digestRuns++;
    t.done({'rows': rows, 'isolate': true});
    return hex;
  }

  /// How many times [stateDigest] really read the tables (not served from its cache), since the repo was opened.
  int get stateDigestComputations => _digestRuns;

  /// Whether nothing has been put into this wallet yet: no transactions, goals, goal contributions, wishes, recurring
  /// bills, planned costs, bills (receipts, slips), accounts, categories (overrides included), tags, tag links, rule
  /// tags, merchant rules (deleted rows count: they were data once) and no synced settings. Only such a wallet may
  /// take a restore from a backup; anything else merges through the sync folder.
  bool get isEmpty {
    for (final e in entitySchema.values) {
      if (db.select('SELECT 1 FROM ${e.table} LIMIT 1').isNotEmpty) return false;
    }
    return true;
  }

  /// How many field clocks the wallet holds ([count]) and the newest of them ([maxHlc]; `null` when there are none).
  /// Not a change mark: a peer op that replaces a field's clock with one older than the newest overall changes data and
  /// leaves both as they were. Use [dataVersion] to tell whether wallet data changed.
  ({int count, String? maxHlc}) clockStats() {
    final r = db.select('SELECT count(*) AS n, max(hlc) AS m FROM clocks').first;
    return (count: r['n'] as int, maxHlc: r['m'] as String?);
  }

  // ---------- sync bookkeeping (device-local, never synced) ----------
  /// How far this device applied each other device's relay files (device id → last applied seq; absent = none).
  /// Advanced file by file by `SyncEngine`, raised to a snapshot's covers; a schema bump clears it ([_migrate]).
  Map<String, int> syncCursors() => {
        for (final r in db.select('SELECT device, seq FROM sync_cursor')) r['device'] as String: r['seq'] as int,
      };

  /// Sets [device]'s cursor; 0 forgets it (the relay lost that device's files, which start again at 1).
  void setSyncCursor(String device, int seq) => seq <= 0
      ? db.execute('DELETE FROM sync_cursor WHERE device = ?', [device])
      : db.execute('INSERT OR REPLACE INTO sync_cursor(device, seq) VALUES(?, ?)', [device, seq]);

  /// Records that relay file [seq] of [device] (this device's own uploads included) held [ops] ops, for the snapshot
  /// rule ("500 ops behind the newest snapshot").
  void recordSyncFile(String device, int seq, int ops) =>
      db.execute('INSERT OR REPLACE INTO sync_files(device, seq, ops) VALUES(?, ?, ?)', [device, seq, ops]);

  /// Ops in recorded files not covered by [covers] (device → seq; a device not in it covers nothing).
  int syncOpsAfter(Map<String, int> covers) {
    var n = 0;
    for (final r in db.select('SELECT device, seq, ops FROM sync_files')) {
      if ((r['seq'] as int) > (covers[r['device']] ?? 0)) n += r['ops'] as int;
    }
    return n;
  }

  /// Forgets recorded files that [covers] covers.
  void forgetSyncFiles(Map<String, int> covers) {
    for (final MapEntry(key: d, value: s) in covers.entries) {
      db.execute('DELETE FROM sync_files WHERE device = ? AND seq <= ?', [d, s]);
    }
  }
}

/// The canonical synced-state hash of [db] ([WalletRepoSyncApply.stateDigest]) and the row count it read. Top-level and
/// free of repo state, so [WalletRepoSyncApply.stateDigestAsync] can run it in another isolate on its own connection.
(String, int) _canonicalDigest(CommonDatabase db) {
  final sink = const DartSha256().newHashSink();
  final buf = StringBuffer(); // hashed in chunks of about 64 KiB: one UTF-8 conversion per chunk, not per row
  void flush() {
    sink.add(utf8.encode(buf.toString()));
    buf.clear();
  }

  var rows = 0;
  for (final entity in entitySchema.keys.toList()..sort()) {
    final def = entitySchema[entity]!;
    final cols = def.columnNames.toList()..sort();
    buf
      ..write(jsonEncode([entity, cols]))
      ..write('\n');
    final clocks = <String, Map<String, String>>{}; // id -> field -> hlc
    for (final r in db.select('SELECT id, field, hlc FROM clocks WHERE entity = ?', [entity])) {
      if ((r['id'], r['field'], r['hlc']) case (final String id, final String f, final String h)) (clocks[id] ??= {})[f] = h;
    }
    for (final r in db.select('SELECT id, ${cols.join(', ')} FROM ${def.table} ORDER BY id').rows) {
      final id = r[0] as String;
      final c = clocks[id] ?? const <String, String>{};
      final line = <Object?>[id];
      for (var i = 0; i < cols.length; i++) {
        line
          ..add(r[i + 1])
          ..add(c[cols[i]]);
      }
      buf
        ..write(jsonEncode(line))
        ..write('\n');
      if (buf.length > 65536) flush();
      rows++;
    }
  }
  flush();
  sink.close();
  return (sink.hashSync().bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), rows);
}
