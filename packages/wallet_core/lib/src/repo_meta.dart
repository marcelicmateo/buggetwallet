part of 'repo.dart';

/// Open-time repairs and migrations ([_migrate]) and the `meta` table helpers behind [WalletRepo.localValue].
extension WalletRepoMeta on WalletRepo {
  /// The folder sync's bookkeeping (`peer_files`: which files of the shared folder were read) means nothing on a relay,
  /// whose sequence numbers start over (every device's first relay file is its whole state), so it is dropped once.
  void _dropFolderSync() {
    if (db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'peer_files'").isEmpty) return;
    final n = db.select('SELECT COUNT(*) AS n FROM peer_files').first['n'] as int;
    db.execute('DROP TABLE peer_files');
    logEvent(_log, Level.INFO, 'repo.peerFiles.dropped', {'files': n});
  }

  /// Builds before a synced entity existed skipped its ops but still advanced their sync cursors past the files
  /// holding them. So when an existing database is opened by a build with a newer [schemaVersion], it forgets how far
  /// it applied each device (`sync_cursor`): the next sync starts over like a new device (the latest snapshot when one
  /// of this schema or newer exists, else every file still on the relay), ops already applied change nothing (their
  /// clocks are not newer), and the skipped ones apply. A new database just records the version.
  ///
  /// Below version 4, Revolut Exchange legs were imported with the `ownTransfer` hint, which lets them anchor a pair
  /// across sources; `importBatch` skips known ids and never edits `kind_hint`, so they are rewritten here once to
  /// `exchange` through [_write] (the change syncs) and reconciled at once, which dissolves their pairs.
  void _migrate() {
    final from = int.tryParse(_meta('schema') ?? '') ?? 1;
    if (from >= WalletRepo.schemaVersion) return;
    var replay = 0, rehinted = 0, perKey = 0;
    if (!_created) {
      replay = db.select('SELECT COUNT(*) AS n FROM sync_cursor').first['n'] as int;
      db.execute('DELETE FROM sync_cursor');
      if (from < 4) {
        final stale = db.select("SELECT id FROM tx WHERE source = 'revolut' AND bank_type = ? AND kind_hint = ?",
            [revolutExchangeType, TxKind.ownTransfer.name]);
        rehinted = stale.length;
        _writeInternal([
          for (final r in stale) ('tx', r['id'] as String, {'kind_hint': TxKind.exchange.name})
        ]);
      }
      if (from < 8) perKey = WalletRepoSettings(this)._migratePerKeySettings();
    }
    _setMeta('schema', '${WalletRepo.schemaVersion}');
    logEvent(_log, Level.INFO, 'repo.migrate', {
      'from': from,
      'to': WalletRepo.schemaVersion,
      'new': _created,
      'replayDevices': replay,
      'rehinted': rehinted,
      'perKeySettings': perKey
    });
    if (rehinted > 0) _reconcileLocal();
  }

  // ---------- meta ----------
  String? _meta(String key) {
    final rs = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String?;
  }

  void _setMeta(String key, String? value) => db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)', [key, value]);
}
