part of 'repo.dart';

/// Bill files: the device-local cache of sealed blobs and their upload state (never synced or backed up; see
/// [BlobStore]). P14: clients never delete a blob on the relay (the relay collects garbage from the snapshots'
/// declared sets), so the cache only tracks whether each file is on the relay (`blob_cache.uploaded`).
extension WalletRepoBlobs on WalletRepo {
  int _nextBlobUse() => (db.select('SELECT MAX(used_at) AS m FROM blob_cache').first['m'] as int? ?? 0) + 1;

  /// Keeps sealed [bytes] under [hash] in the cache (most recently used); with [queue] it waits for upload
  /// (`uploaded` 0). A file already cached keeps its upload state unless [queue] asks for an upload.
  void putCachedBlob(String hash, List<int> bytes, {bool queue = false}) {
    db.execute(
        'INSERT INTO blob_cache(hash, sealed, used_at, bytes, uploaded) VALUES(?, ?, ?, ?, ?) '
        'ON CONFLICT(hash) DO UPDATE SET sealed = excluded.sealed, used_at = excluded.used_at, bytes = excluded.bytes'
        '${queue ? ', uploaded = 0' : ''}',
        [hash, bytes, _nextBlobUse(), bytes.length, queue ? 0 : 1]);
  }

  /// The sealed bytes cached for [hash], or null; with [touch] it becomes the most recently used.
  List<int>? cachedBlob(String hash, {bool touch = true}) {
    final rs = db.select('SELECT sealed FROM blob_cache WHERE hash = ?', [hash]);
    if (rs.isEmpty) return null;
    if (touch) db.execute('UPDATE blob_cache SET used_at = ? WHERE hash = ?', [_nextBlobUse(), hash]);
    return rs.first['sealed'] as List<int>;
  }

  /// Whether [hash] is in the cache.
  bool hasCachedBlob(String hash) => db.select('SELECT 1 FROM blob_cache WHERE hash = ?', [hash]).isNotEmpty;

  /// Removes [hash] from the cache (never one still waiting for upload).
  void uncacheBlob(String hash) => db.execute('DELETE FROM blob_cache WHERE hash = ? AND uploaded = 1', [hash]);

  /// Drops the least recently used cached files until the cache holds at most [maxBytes] sealed bytes; files still
  /// waiting for upload, and files a pending outbox op references ([pendingBlobRefs]: the next sync PUTs them again
  /// before that op), are never dropped. Returns how many were dropped.
  int evictBlobs(int maxBytes) {
    var total = cachedBlobBytes, n = 0;
    if (total <= maxBytes) return 0;
    final pinned = pendingBlobRefs();
    for (final r in db.select('SELECT hash, bytes FROM blob_cache WHERE uploaded = 1 ORDER BY used_at')) {
      if (total <= maxBytes) break;
      if (pinned.contains(r['hash'])) continue;
      db.execute('DELETE FROM blob_cache WHERE hash = ?', [r['hash']]);
      total -= r['bytes'] as int;
      n++;
    }
    return n;
  }

  /// The cached files a live bill points to, as (hash, sealed bytes), newest bill first (by its date, then the most
  /// recently used file): what a backup carries ([backupBytes]).
  List<(String, int)> backupBlobCandidates() => [
        for (final r in db.select('SELECT c.hash AS hash, c.bytes AS bytes FROM blob_cache c JOIN '
            "(SELECT blob, MAX(COALESCE(date, '')) AS d FROM bills WHERE deleted = 0 AND blob IS NOT NULL GROUP BY blob) b "
            'ON b.blob = c.hash ORDER BY b.d DESC, c.used_at DESC, c.hash'))
          (r['hash'] as String, r['bytes'] as int),
      ];

  /// Whether a live bill points to [hash].
  bool blobInUse(String hash) => db.select('SELECT 1 FROM bills WHERE deleted = 0 AND blob = ?', [hash]).isNotEmpty;

  /// The hashes live bills point to, sorted: a snapshot's declared set (RELAY_PROTOCOL.md "Blob garbage collection").
  List<String> liveBlobHashes() => [
        for (final r in db.select('SELECT DISTINCT blob FROM bills WHERE deleted = 0 AND blob IS NOT NULL ORDER BY blob'))
          if (r['blob'] case final String h when isBlobHash(h)) h,
      ];

  /// Sealed bytes in the cache.
  int get cachedBlobBytes => db.select('SELECT COALESCE(SUM(bytes), 0) AS s FROM blob_cache').first['s'] as int;

  /// Cached files waiting for upload (`uploaded` 0), in hash order.
  List<String> queuedBlobs() =>
      [for (final r in db.select('SELECT hash FROM blob_cache WHERE uploaded = 0 ORDER BY hash')) r['hash'] as String];

  /// Of [hashes], those held in the cache, in hash order.
  List<String> cachedOf(Iterable<String> hashes) {
    final want = hashes.toSet();
    if (want.isEmpty) return const [];
    return [
      for (final r in db.select('SELECT hash FROM blob_cache ORDER BY hash'))
        if (want.contains(r['hash'])) r['hash'] as String,
    ];
  }

  /// [hash] is on the relay (it stays cached).
  void markBlobUploaded(String hash) => db.execute('UPDATE blob_cache SET uploaded = 1 WHERE hash = ?', [hash]);

  /// The blob [op] references (RELAY_PROTOCOL.md "Client rules for blobs"): for a bill op, the hash it sets `blob` to
  /// while the bill is live here (or the op makes it live), or, when it makes the bill live (`deleted` 0) without
  /// setting `blob`, the bill's current file here. An op of a bill deleted here (an old op in a whole-state upload)
  /// references nothing: no device needs that file unless the bill comes back, and that op references it again. A
  /// field this device already holds with a newer clock (the op was overtaken, e.g. by another device's file for the
  /// same bill) references nothing either: it would change nothing anywhere, so it neither waits nor pins the cache.
  String? blobRefOf(Op op) {
    if (op.entity != 'bill') return null;
    final f = op.fields;
    if (f['deleted'] == 1) return null;
    final clocks = {
      for (final r in db.select("SELECT field, hlc FROM clocks WHERE entity = 'bill' AND id = ? AND field IN ('blob', 'deleted')", [op.id]))
        r['field'] as String: r['hlc'] as String,
    };
    bool overtaken(String field) => switch (clocks[field]) {
          final String h => Hlc.compareStrings(h, op.hlc) > 0,
          null => false,
        };
    final rs = db.select('SELECT blob, deleted FROM bills WHERE id = ?', [op.id]);
    final undeletes = f['deleted'] == 0 && !overtaken('deleted');
    final live = rs.isEmpty || rs.first['deleted'] == 0 || undeletes;
    if (f.containsKey('blob') && !overtaken('blob')) {
      final h = f['blob'];
      return live && h is String && isBlobHash(h) ? h : null;
    }
    if (!undeletes) return null;
    final h = rs.isEmpty ? null : rs.first['blob'];
    return h is String && isBlobHash(h) ? h : null;
  }

  /// The blobs the pending outbox ops reference ([blobRefOf]).
  Set<String> pendingBlobRefs() => {
        for (final r in db.select('SELECT op FROM outbox WHERE op LIKE ?', ['{"e":"bill"%']))
          if (blobRefOf(Op.fromJson(jsonDecode(r['op'] as String) as Map<String, Object?>)) case final h?) h,
      };

  /// Puts ops held back for their blob ([SyncEngine]: upload before ops) into the outbox again, after the ones up to
  /// [upToSeq] (null: none) were exported; one transaction, so a held op is never lost.
  void markExportedHolding(int? upToSeq, List<Op> held) {
    db.execute('BEGIN');
    try {
      if (upToSeq != null) db.execute('DELETE FROM outbox WHERE seq <= ?', [upToSeq]);
      for (final op in held) {
        db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
    logEvent(_log, Level.FINE, 'repo.markExported', {'upTo': upToSeq ?? 0, 'held': held.length});
  }

  /// A file added for a bill that did not take it (the bill already had one): forgotten when it never reached the
  /// relay and no bill points to it. Local only; nothing is ever deleted on the relay.
  void _forgetUnusedBlob(String hash) {
    if (blobInUse(hash)) return;
    db.execute('DELETE FROM blob_cache WHERE hash = ? AND uploaded = 0', [hash]);
    if (db.updatedRows > 0) logEvent(_log, Level.FINE, 'blob.forget');
  }

  /// Schema 15 (P14): `blob_cache` gains `uploaded` (1 = on the relay) from the old `blob_outbox` queue, and the
  /// `blob_outbox`, `blob_delete` and `blob_own` tables go (clients no longer delete blobs). Device-local tables only.
  void _migrateBlobTables() {
    final cols = {for (final r in db.select('PRAGMA table_info(blob_cache)')) r['name'] as String};
    final hasOutbox = db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'blob_outbox'").isNotEmpty;
    if (cols.contains('uploaded') && !hasOutbox) return;
    var queued = 0, lost = 0;
    db.execute('BEGIN');
    try {
      if (!cols.contains('uploaded')) {
        db.execute('ALTER TABLE blob_cache ADD COLUMN uploaded INTEGER NOT NULL DEFAULT 0');
        db.execute('UPDATE blob_cache SET uploaded = 1');
      }
      if (hasOutbox) {
        db.execute('UPDATE blob_cache SET uploaded = 0 WHERE hash IN (SELECT hash FROM blob_outbox)');
        queued = db.updatedRows;
        lost = (db.select('SELECT COUNT(*) AS n FROM blob_outbox').first['n'] as int) - queued;
        db.execute('DROP TABLE blob_outbox');
      }
      db.execute('DROP TABLE IF EXISTS blob_delete');
      db.execute('DROP TABLE IF EXISTS blob_own');
      // Builds before P14 deleted files on the relay (a bill deleted, a losing file): the next sync puts every cached
      // file of a live bill again, which repairs one deleted while a device still pointed at it.
      setLocalValue(WalletRepo.blobReuploadKey, '1');
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
    logEvent(_log, Level.INFO, 'repo.blobTables.migrated', {'queued': queued, 'notCached': lost});
  }
}
