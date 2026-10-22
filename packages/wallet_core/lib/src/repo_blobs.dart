part of 'repo.dart';

/// Bill files: the device-local cache of sealed blobs and their upload/delete queues (never synced or backed up; see [BlobStore]).
extension WalletRepoBlobs on WalletRepo {
  int _nextBlobUse() => (db.select('SELECT MAX(used_at) AS m FROM blob_cache').first['m'] as int? ?? 0) + 1;

  /// Keeps sealed [bytes] under [hash] in the cache (most recently used), and queues it for upload with [queue].
  void putCachedBlob(String hash, List<int> bytes, {bool queue = false}) {
    db.execute(
        'INSERT OR REPLACE INTO blob_cache(hash, sealed, used_at, bytes) VALUES(?, ?, ?, ?)', [hash, bytes, _nextBlobUse(), bytes.length]);
    if (queue) db.execute('INSERT OR IGNORE INTO blob_outbox(hash) VALUES(?)', [hash]);
  }

  /// The sealed bytes cached for [hash], or null; with [touch] it becomes the most recently used.
  List<int>? cachedBlob(String hash, {bool touch = true}) {
    final rs = db.select('SELECT sealed FROM blob_cache WHERE hash = ?', [hash]);
    if (rs.isEmpty) return null;
    if (touch) db.execute('UPDATE blob_cache SET used_at = ? WHERE hash = ?', [_nextBlobUse(), hash]);
    return rs.first['sealed'] as List<int>;
  }

  /// Removes [hash] from the cache (never one still queued for upload).
  void uncacheBlob(String hash) =>
      db.execute('DELETE FROM blob_cache WHERE hash = ? AND hash NOT IN (SELECT hash FROM blob_outbox)', [hash]);

  /// Drops the least recently used cached files until the cache holds at most [maxBytes] sealed bytes; files still
  /// queued for upload are never dropped. Returns how many were dropped.
  int evictBlobs(int maxBytes) {
    var total = cachedBlobBytes, n = 0;
    if (total <= maxBytes) return 0;
    for (final r in db.select('SELECT hash, bytes FROM blob_cache WHERE hash NOT IN (SELECT hash FROM blob_outbox) ORDER BY used_at')) {
      if (total <= maxBytes) break;
      db.execute('DELETE FROM blob_cache WHERE hash = ?', [r['hash']]);
      total -= r['bytes'] as int;
      n++;
    }
    return n;
  }

  /// Sealed bytes in the cache.
  int get cachedBlobBytes => db.select('SELECT COALESCE(SUM(bytes), 0) AS s FROM blob_cache').first['s'] as int;

  /// Files waiting for upload, in hash order.
  List<String> queuedBlobs() => [for (final r in db.select('SELECT hash FROM blob_outbox ORDER BY hash')) r['hash'] as String];

  /// [hash] is on the relay: no longer queued (it stays cached).
  void blobUploaded(String hash) => db.execute('DELETE FROM blob_outbox WHERE hash = ?', [hash]);

  /// Files to delete on the relay, in hash order.
  List<String> blobDeletes() => [for (final r in db.select('SELECT hash FROM blob_delete ORDER BY hash')) r['hash'] as String];

  /// [hash] was deleted on the relay.
  void blobDeleteDone(String hash) => db.execute('DELETE FROM blob_delete WHERE hash = ?', [hash]);

  /// A file no live bill uses any more: one still queued is simply forgotten (never uploaded), one already uploaded is
  /// queued for deletion on the relay; the cached copy goes either way. Kept while a live bill points to it.
  void _dropBlob(String hash) {
    if (db.select('SELECT 1 FROM bills WHERE deleted = 0 AND blob = ?', [hash]).isNotEmpty) return;
    db.execute('DELETE FROM blob_own WHERE hash = ?', [hash]);
    final queued = db.select('SELECT 1 FROM blob_outbox WHERE hash = ?', [hash]).isNotEmpty;
    db.execute('DELETE FROM blob_outbox WHERE hash = ?', [hash]);
    if (!queued) db.execute('INSERT OR IGNORE INTO blob_delete(hash) VALUES(?)', [hash]);
    db.execute('DELETE FROM blob_cache WHERE hash = ?', [hash]);
    logEvent(_log, Level.FINE, 'blob.drop', {'queued': queued});
  }

  /// Files this device attached to a bill (`blob_own`, device-local) that no live bill points to any more: the bill was
  /// deleted on another device, or the same bill got another device's file (the later `blob` field wins). A queued
  /// upload is forgotten (never sent), an uploaded one is queued for deletion on the relay; the cached copy goes. Runs
  /// after a caught-up sync ([runPendingMatch]) and before uploading (`SyncEngine.run`); a file added but not yet
  /// attached to a bill is never touched. Returns how many were dropped.
  int dropOrphanBlobs() {
    final orphans = [
      for (final r in db.select('SELECT hash FROM blob_own WHERE hash NOT IN '
          '(SELECT blob FROM bills WHERE deleted = 0 AND blob IS NOT NULL) ORDER BY hash'))
        r['hash'] as String
    ];
    for (final h in orphans) {
      _dropBlob(h);
    }
    if (orphans.isNotEmpty) logEvent(_log, Level.INFO, 'blob.orphans', {'files': orphans.length});
    return orphans.length;
  }

  /// Cached files no live bill uses (bills deleted on another device): dropped, except those queued for upload.
  void _purgeBlobCache() {
    db.execute('DELETE FROM blob_cache WHERE hash NOT IN (SELECT hash FROM blob_outbox) '
        'AND hash NOT IN (SELECT blob FROM bills WHERE deleted = 0 AND blob IS NOT NULL)');
    final n = db.updatedRows;
    if (n > 0) logEvent(_log, Level.FINE, 'blob.purge', {'files': n});
  }
}
