// Bill files (photos, PDFs, XML) sealed with the wallet key and kept on the relay by hash (BILLS_API.md §4,
// RELAY_PROTOCOL.md "Blobs"). Web-safe: the cache and queues are device-local tables of the wallet database.
import 'dart:typed_data';

import 'bills.dart';
import 'logs.dart';
import 'repo.dart';
import 'sync_engine.dart';
import 'vault.dart';

final _log = Logger('bw.blob');

/// Largest plain file [BlobStore.add] takes (sealed it stays under the relay's 16 MiB).
const maxBlobPlainBytes = 15 << 20;

/// Cache limits (sealed bytes): native and web.
const blobCacheBytesNative = 200 << 20, blobCacheBytesWeb = 50 << 20;

/// Seals bill files, keeps them in the device-local cache (`blob_cache`, least recently used dropped past
/// [maxCacheBytes], never one still waiting for upload) and queues them for the relay (`blob_cache.uploaded` 0,
/// uploaded by `SyncEngine.run`). The cache never syncs or goes into backups: rows point to files by hash.
class BlobStore {
  final WalletRepo repo;
  final VaultKey key;
  final int maxCacheBytes;
  BlobStore(this.repo, this.key, {this.maxCacheBytes = blobCacheBytesNative});

  /// Seals [plain] (≤ [maxBlobPlainBytes], else [ArgumentError]; [type] one of [blobTypes]), keeps it in the cache and
  /// queues the upload. The hash is SHA-256 of the sealed bytes (a fresh nonce each time, so the same photo added twice
  /// gives two files).
  Future<BlobRef> add(Uint8List plain, String type) async {
    if (!blobTypes.contains(type)) throw ArgumentError('Unknown file type.');
    if (plain.isEmpty || plain.length > maxBlobPlainBytes) throw ArgumentError('The file is empty or too big.');
    final sealed = await seal(plain, key, aad: aadBlob);
    final hash = sha256Hex(sealed);
    repo.putCachedBlob(hash, sealed, queue: true);
    final dropped = repo.evictBlobs(maxCacheBytes);
    logEvent(_log, Level.INFO, 'blob.add', {'type': type, 'bytes': plain.length, 'sealedBytes': sealed.length, 'evicted': dropped});
    return BlobRef(hash: hash, type: type, bytes: plain.length);
  }

  /// The plain bytes of [hash]: from the cache, else fetched from [transport] (the SHA-256 of what arrives must be
  /// [hash], then it is unsealed with the key and cached). Null when it is not on this device and [transport] is null,
  /// unreachable, or the relay does not have it; also when what arrives fails the hash or the key (logged, not cached).
  Future<Uint8List?> read(String hash, {SyncTransport? transport}) async {
    if (!isBlobHash(hash)) return null;
    final cached = repo.cachedBlob(hash);
    if (cached != null) {
      try {
        return await unseal(cached, key, aad: aadBlob);
      } on VaultException catch (e, st) {
        // A damaged cached copy: forget it (unless it waits for upload, then it cannot be fixed here) and fetch again.
        logError(_log, 'blob.cache.bad', e, st, level: Level.WARNING);
        repo.uncacheBlob(hash);
      }
    }
    if (transport == null) return null;
    final List<int>? sealed;
    try {
      sealed = await transport.getBlob(hash);
    } on TransportException catch (e) {
      logEvent(_log, Level.WARNING, 'blob.fetch.failed', {'failure': e.failure.name});
      return null;
    }
    if (sealed == null) {
      logEvent(_log, Level.INFO, 'blob.fetch.missing');
      return null;
    }
    if (sha256Hex(sealed) != hash) {
      logEvent(_log, Level.WARNING, 'blob.fetch.refused', {'reason': 'hash', 'bytes': sealed.length});
      return null;
    }
    final Uint8List plain;
    try {
      plain = await unseal(sealed, key, aad: aadBlob);
    } on VaultException catch (e, st) {
      logError(_log, 'blob.fetch.refused', e, st, level: Level.WARNING, fields: {'reason': e.failure?.name ?? 'key'});
      return null;
    }
    repo.putCachedBlob(hash, sealed);
    final dropped = repo.evictBlobs(maxCacheBytes);
    logEvent(_log, Level.INFO, 'blob.fetch', {'bytes': plain.length, 'evicted': dropped});
    return plain;
  }
}
