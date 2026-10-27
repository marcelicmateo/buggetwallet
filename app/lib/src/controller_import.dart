// Import, backup and export in the controller: reading bank files, saved CSV layouts, backup download / restore / merge and CSV export.
// A `part` of controller.dart so it can use the cache, the loggers and `_changed`.
//
// Privacy: logs carry indexes, extensions, sizes and counts only; never a file name, a payee, an amount or a note.
part of 'controller.dart';

extension ImportAndBackup on WalletController {
  // ---------- backup, export, search (see app/CLAUDE.md, Polish) ----------
  /// True while the wallet holds nothing (no transactions, goals or wishes): the only time a backup can be restored.
  bool get walletIsEmpty => _cached(const MemoKey('walletIsEmpty'), () => repo.isEmpty);

  /// A backup of the wallet as bytes for the save dialog, with its file name (never log it). Throws [StateError] without a key.
  /// [blobs] = the bill files inside it (for the toast).
  Future<({String name, Uint8List bytes, int blobs})> backupDownload() async {
    final k = key;
    if (k == null) {
      logEvent(_backupLog, Level.INFO, 'backup.skip', {'reason': 'noKey'});
      throw StateError('No wallet key');
    }
    final sw = Stopwatch()..start();
    try {
      final made = await deps.backupBytesWriter(repo, k);
      logEvent(_backupLog, Level.INFO, 'backup.done', {
        'ms': sw.elapsedMilliseconds,
        'tx': wholeTxs.length,
        'goals': goals.length,
        'wish': wish.length,
        'bytes': made.bytes.length,
        'blobs': made.blobs,
        'blobsSkipped': made.blobsSkipped
      });
      return (name: backupFileName(today()), bytes: made.bytes, blobs: made.blobs);
    } catch (e, st) {
      logError(_backupLog, 'backup.failed', e, st);
      rethrow;
    }
  }

  /// Reads a picked backup file ([bytes]) into the empty wallet; returns the number of rows restored.
  /// With [otherKey] (the typed or scanned text of the key the backup was made with) the file is opened with that key instead of
  /// this wallet's; the restored rows then belong to this wallet. That key is used once: not stored, not logged, not kept.
  /// Throws [StateError] when the wallet is not empty, [VaultException] on a wrong key (`failure` is null when [otherKey] is not a
  /// key at all), [BackupException] on a bad file.
  Future<int> restoreBackupFile(Uint8List bytes, {String? otherKey}) async {
    final k = key;
    if (k == null) throw const BackupException(BackupFailure.unreadable, 'No wallet key on this device.');
    final sw = Stopwatch()..start();
    try {
      final opener = otherKey == null ? k : await VaultKey.parse(otherKey);
      final rows = await deps.backupBytesReader(repo, bytes, opener, k); // always the wallet's own key too
      logEvent(_backupLog, Level.INFO, 'backup.restored',
          {'ms': sw.elapsedMilliseconds, 'rows': rows, 'bytes': bytes.length, 'otherKey': otherKey != null});
      _changed();
      return rows;
    } catch (e, st) {
      logError(_backupLog, 'backup.restoreFailed', e, st, fields: {'type': e.runtimeType.toString(), 'otherKey': otherKey != null});
      rethrow;
    }
  }

  /// Merges a picked backup file ([bytes]) into this wallet: the newer change wins, field by field, nothing is doubled. With
  /// [dryRun] nothing is written and the result says what a merge would bring in. [otherKey] (typed or scanned text of the key the
  /// file was made with) opens the file instead of this wallet's key; it is used once and never stored or logged. Throws
  /// [VaultException] (wrong key; `failure` null when [otherKey] is not a key at all) and [BackupException] (bad file).
  Future<MergeResult> mergeBackupFile(Uint8List bytes, {String? otherKey, bool dryRun = false}) async {
    final k = key;
    if (k == null) throw const BackupException(BackupFailure.unreadable, 'No wallet key on this device.');
    final sw = Stopwatch()..start();
    try {
      final opener = otherKey == null ? k : await VaultKey.parse(otherKey);
      final r = await deps.backupMerger(repo, bytes, opener, dryRun: dryRun, walletKey: k);
      logEvent(_backupLog, Level.INFO, dryRun ? 'backup.mergePreview' : 'backup.merged', {
        'ms': sw.elapsedMilliseconds,
        'ops': r.ops,
        'changed': r.changed,
        'blobs': r.blobs,
        'entities': r.changedByEntity.length,
        'bytes': bytes.length,
        'otherKey': otherKey != null
      });
      if (!dryRun && (r.changed > 0 || r.blobs > 0)) _changed();
      return r;
    } catch (e, st) {
      logError(_backupLog, 'backup.mergeFailed', e, st,
          fields: {'type': e.runtimeType.toString(), 'dryRun': dryRun, 'otherKey': otherKey != null});
      rethrow;
    }
  }

  /// The transactions of [range] as a CSV (category and cleaned description as the app shows them). [ExportFile.rows] is 0
  /// when the range holds none.
  ExportFile exportTransactions(ExportRange range) {
    final to0 = today();
    final (String from, String to) = switch (range) {
      ExportRange.period => (period().start, addDays(period().end, -1)),
      ExportRange.year => ('${to0.substring(0, 4)}-01-01', to0),
      ExportRange.all => (txs.isEmpty ? to0 : txs.last.date, txs.isEmpty ? to0 : txs.first.date),
    };
    final rows = [
      for (final t in txs)
        if (t.date.compareTo(from) >= 0 && t.date.compareTo(to) <= 0) t
    ];
    logEvent(_log, Level.INFO, 'export.transactions', {'range': range.name, 'rows': rows.length});
    return ExportFile('bw-transactions-$from-$to.csv', _csvBytes(transactionsCsv(rows, table: categoryTable, tags: tagTable)), rows.length);
  }

  /// The spending summary per month and category over every transaction.
  ExportFile exportSummary() {
    final csv = monthlySummaryCsv(txs, currency: currency, table: categoryTable);
    final months = csv.split('\n').where((l) => l.isNotEmpty).length - 1; // data lines after the header
    logEvent(_log, Level.INFO, 'export.summary', {'rows': months});
    return ExportFile('bw-summary.csv', _csvBytes(csv), months);
  }

  /// UTF-8 with a byte order mark, so a spreadsheet reads accents correctly.
  static Uint8List _csvBytes(String csv) => Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);

  // ---------- import ----------

  /// The batch of one file and the column mapping that read it (null for a bank profile): a bank profile, a saved layout that fits, or the
  /// layout [ask] returns (saved first; [confirm] answers the "used for N payments" case). Null = the owner cancelled. When saving
  /// the layout replaced the payments of a removed one that read differently, [remap] says which (and the old layout).
  Future<(ImportBatch, CsvMapping?)?> _readImportFile(
      String name, Uint8List bytes, AskMapping? ask, ConfirmRemoval? confirm, _Remap remap) async {
    final f = <String, Object?>{'ext': fileExt(name), 'bytes': bytes.length};
    try {
      return (timed('import.parse', () => importBankFile(bytes), fields: f, warnMs: 1000), null);
    } on NeedsMapping catch (need) {
      final saved = settings.csvMappings;
      final key = matchCsvMapping(bytes, need.shape, saved);
      CsvMapping m;
      if (key != null) {
        m = saved[key]!;
      } else {
        if (ask == null) rethrow;
        final choice = await ask(need, bytes);
        if (choice == null) return null;
        final before = repo.removedCsvMapping(choice.shapeId); // what the Undo writes back
        var removed = const <String>[];
        try {
          removed = repo.setCsvMapping(choice.shapeId, choice.mapping);
        } on ArgumentError {
          final n = repo.csvRowsFor(choice.shapeId);
          if (n == 0 || confirm == null) rethrow;
          if (!await confirm(n)) return null;
          removed = repo.setCsvMapping(choice.shapeId, choice.mapping, force: true);
        }
        settings = repo.settings(); // a second file of this shape in the same pick reads with it, no new question
        if (removed.isNotEmpty) {
          // Added to what is waiting already: another file's rows, or rows an Undo took away that this reading brings back.
          repo.setLocalValue('csvRevive:${choice.shapeId}', jsonEncode({...csvReviveIds(choice.shapeId), ...removed}.toList()));
          remap
            ..id = choice.shapeId
            ..removed = removed
            ..old = before;
        }
        logEvent(_import, Level.INFO, 'import.layoutSaved', {'columns': need.shape.headers.length, 'removed': removed.length});
        m = choice.mapping;
      }
      return (
        timed('import.parse', () => parseMappedCsv(bytes, m, fileName: name, walletCurrency: currency),
            fields: {...f, 'mapped': true}, warnMs: 1000),
        m
      );
    }
  }

  /// Undo of an import that replaced a layout's earlier payments: everything now live from that layout is deleted, the earlier payments
  /// are back, and the layout is the removed one again with the reading it had ([old]), so reading the file the new way later asks again.
  void undoCsvRemap(String id, List<String> removed, CsvMapping? old) {
    final earlier = removed.toSet();
    final taken = <String>[];
    for (final t in repo.transactions(includeHidden: true)) {
      if (t.source == '$csvSourcePrefix$id' && !t.deleted && !earlier.contains(t.id)) {
        repo.deleteTransaction(t.id);
        taken.add(t.id);
      }
    }
    if (old != null) repo.setCsvMapping(id, old, force: true); // deletes what is still live (the revived ones), they come back next
    for (final r in removed) {
      repo.undeleteTransaction(r);
    }
    repo.removeCsvMapping(id);
    // The rows the new reading made stay deleted; reading the file that way again must bring them back, not skip them as known.
    repo.setLocalValue('csvRevive:$id', taken.isEmpty ? null : jsonEncode(taken));
    logEvent(_import, Level.INFO, 'csvLayout.remapUndone', {'restored': removed.length});
    _changed();
  }

  // ---------- saved CSV layouts (P12) ----------
  /// Saved file layouts, shape id → layout, sorted by name.
  List<MapEntry<String, CsvMapping>> csvLayouts() =>
      settings.csvMappings.entries.toList()..sort((a, b) => a.value.name.toLowerCase().compareTo(b.value.name.toLowerCase()));

  /// Renames layout [id]. An [ArgumentError] carries core's owner-readable text.
  void renameCsvLayout(String id, String name) {
    final m = settings.csvMappings[id];
    if (m == null) throw ArgumentError('That layout is gone.');
    repo.setCsvMapping(id, m.copyWith(name: name));
    logEvent(_import, Level.INFO, 'csvLayout.rename');
    _changed();
  }

  /// Removes layout [id] and returns it (the toast's Undo is [restoreCsvLayout]); null when it is already gone.
  CsvMapping? deleteCsvLayout(String id) {
    final m = settings.csvMappings[id];
    if (m == null) return null;
    repo.removeCsvMapping(id);
    logEvent(_import, Level.INFO, 'csvLayout.delete');
    _changed();
    return m;
  }

  /// How many payments layout [id] has imported (not deleted).
  int csvRowsFor(String id) => repo.csvRowsFor(id);

  /// Saves a changed layout [m] for [id]. Changing how it reads (columns, formats, sign) when it has imported payments throws core's
  /// [ArgumentError] unless [force]; with [force] those payments are deleted and their ids returned (the toast's Undo is
  /// [undoCsvLayoutEdit]). The ids are kept device-local as `csvRevive:<id>` for the next import of that shape.
  List<String> saveCsvLayout(String id, CsvMapping m, {bool force = false}) {
    final removed = repo.setCsvMapping(id, m, force: force);
    if (removed.isNotEmpty) repo.setLocalValue('csvRevive:$id', jsonEncode(removed));
    logEvent(_import, Level.INFO, 'csvLayout.edit', {'removed': removed.length, 'force': force});
    _changed();
    return removed;
  }

  /// The payment ids a forced edit of layout [id] removed and the next import of its shape may bring back (see [saveCsvLayout]).
  List<String> csvReviveIds(String id) {
    final v = repo.localValue('csvRevive:$id');
    if (v == null) return const [];
    try {
      return [for (final x in jsonDecode(v) as List) x as String];
    } catch (_) {
      return const [];
    }
  }

  /// Undo of a forced [saveCsvLayout]: the old layout is back and its removed payments with it.
  void undoCsvLayoutEdit(String id, CsvMapping old, List<String> removed) {
    repo.setCsvMapping(id, old, force: true);
    for (final r in removed) {
      repo.undeleteTransaction(r);
    }
    repo.setLocalValue('csvRevive:$id', null);
    logEvent(_import, Level.INFO, 'csvLayout.editUndone', {'restored': removed.length});
    _changed();
  }

  void restoreCsvLayout(String id, CsvMapping m) {
    repo.setCsvMapping(id, m);
    logEvent(_import, Level.INFO, 'csvLayout.restore');
    _changed();
  }
}
