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
  /// Returns the fields that applied (their stored values), or null when none did.
  Map<String, Object?>? _apply(Op op) {
    final def = entitySchema[op.entity];
    if (def == null) return null;
    final table = def.table;
    final accepted = <String, Object?>{};
    Map<String, String>? stored; // field -> hlc, read once per (entity, id)
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
      if (have != null && Hlc.compareStrings(have, op.hlc) >= 0) continue;
      accepted[e.key] = v;
    }
    if (accepted.isEmpty) return null;
    assert(!db.autocommit, 'data is written inside a transaction');
    _dataPending = true;
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
  /// ([isSafeCents]: `addTransaction`, `importBatch`).
  static const _amountCaps = <(String, String), int>{
    ('tx', 'amount'): legacyRowCapCents,
    ('planned', 'amount'): maxAmountCents,
    ('bill', 'total'): maxAmountCents,
    ('recurring', 'expected_amount'): legacyRowCapCents,
    ('recurring', 'min_amount'): legacyRowCapCents,
    ('recurring', 'max_amount'): legacyRowCapCents,
    ('wish', 'price'): maxAmountCents,
    ('account', 'opening'): maxAmountCents,
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
        final cap = _amountCaps[(entity, col.name)];
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
  int applyRemote(List<Op> ops, {bool match = true, bool resend = false, bool resendChanged = false}) =>
      applyRemoteByEntity(ops, match: match, resend: resend, resendChanged: resendChanged).values.fold(0, (a, b) => a + b);

  /// [applyRemote], returning how many ops changed a field, per entity (entities with none left out).
  ///
  /// With [dryRun] the ops are applied in a transaction that is rolled back: the counts are those a real apply would
  /// give, and tables, clocks, outbox, the HLC (in memory and stored) and the match flag stay exactly as they were;
  /// nothing is queued and matching does not run. [beforeRollback] runs inside that transaction after the ops, so it
  /// reads the merged state (the backup's bill-file count).
  Map<String, int> applyRemoteByEntity(List<Op> ops,
      {bool match = true, bool resend = false, bool resendChanged = false, bool dryRun = false, void Function()? beforeRollback}) {
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
      }
      t.done({'ops': ops.length, 'changed': changed, 'dryRun': true});
      return byEntity;
    }
    _tx(() {
      for (final op in ops) {
        clock.receive(Hlc.parse(op.hlc));
        final accepted = _apply(op);
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
    });
    t.done({'ops': ops.length, 'changed': changed, 'resend': resend, 'resendChanged': resendChanged});
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
