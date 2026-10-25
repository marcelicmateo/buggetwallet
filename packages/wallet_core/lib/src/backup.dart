// Backups: the sealed payload the app saves through the save dialog and restores from a picked file (compiles for the web).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'bills.dart';
import 'blob_store.dart';
import 'dates.dart';
import 'hlc.dart';
import 'logs.dart';
import 'repo.dart';
import 'vault.dart';

final _log = Logger('bw.backup');

/// The format written by [backupBytes]; a file with a higher one comes from a newer build. The optional `blobs` key
/// (P10) did not change it: every build's parser reads only `v` and `ops`.
const backupVersion = 1;

/// Why a restore refused a file. Key and sealing errors are [VaultException]s instead.
enum BackupFailure {
  /// The file could not be read (missing, no permission, I/O error).
  unreadable,

  /// Unsealed, but not a backup: not JSON, not `{"v":1,"ops":[...]}`, or an op or clock that does not parse.
  damaged,

  /// A backup of a format this build does not know (`v` above [backupVersion]).
  newerVersion,

  /// A clock in it is more than [maxClockDrift] ahead of this device's clock (H7): made on a device with a wrong date,
  /// or this device's date is wrong. Nothing applied; restorable once the clocks agree.
  clockAhead,
}

/// A backup file that cannot be restored. The message names no file content and no path.
class BackupException implements Exception {
  final BackupFailure reason;
  final String message;
  const BackupException(this.reason, this.message);
  @override
  String toString() => message;
}

/// The name of the backup written on [today] (`YYYY-MM-DD`, else [ArgumentError]): `bw-backup-<today>.bwb`.
String backupFileName(String today) {
  requireIsoDate(today);
  return 'bw-backup-$today.bwb';
}

/// The most bill-file bytes [backupBytes] puts into a backup by default (16 MiB), counted as they sit in the payload
/// (base64 of the sealed files). Writing a backup holds about four times the cap at its peak (the sealed files, the
/// JSON text, its UTF-8 bytes and the sealed result: about 64 MiB at the default) plus the ops.
const backupBlobBytesDefault = 16 << 20;

/// What [backupBytesWithInfo] wrote: the sealed file ([bytes]), its op count and the bill files it carries ([blobs]
/// files taking [blobBytes] bytes in the payload (base64); [blobsSkipped] cached files of live bills that did not fit
/// under the cap).
class BackupResult {
  final Uint8List bytes;
  final int ops, blobs, blobBytes, blobsSkipped;
  const BackupResult(this.bytes, {required this.ops, required this.blobs, required this.blobBytes, required this.blobsSkipped});
}

/// What [mergeBackupBytes] brought in (with `dryRun`: would bring in). [ops] = ops in the file; [changed] = ops with at
/// least one field whose clock won here (may include equal values: a newer write of the same value counts; the app
/// calls them "updates"), per entity (`tx`, `tag`, `setting`, ... as in `entitySchema`; entities with none left out) in
/// [changedByEntity]. [blobs] = bill files put into this device's cache (dry run: the files the real merge would put,
/// counted against the merged state inside the rolled-back transaction).
class MergeResult {
  final int ops, changed, blobs;
  final Map<String, int> changedByEntity;
  const MergeResult({required this.ops, required this.changed, required this.changedByEntity, this.blobs = 0});
}

/// A full snapshot of [repo] ([WalletRepo.snapshotOps]: every synced row, deleted ones included, settings included,
/// no device-local values) as UTF-8 JSON `{"v":1,"ops":[...]}`, sealed with [key] like a sync file, with the bill files
/// that fit under [maxBlobBytes] ([backupBytesWithInfo]). What the app saves through the save dialog.
Future<Uint8List> backupBytes(WalletRepo repo, VaultKey key, {int maxBlobBytes = backupBlobBytesDefault}) async =>
    (await backupBytesWithInfo(repo, key, maxBlobBytes: maxBlobBytes)).bytes;

/// [backupBytes] with what it wrote. The payload also carries `"blobs": {"<hash>": "<base64 of the sealed file>"}`: the
/// files in this device's cache that live bills point to, newest bill first, while their base64 total stays within
/// [maxBlobBytes] (a file that does not fit is skipped, never cut; a smaller later one may still fit). No key when there
/// is none. Logs `backup.write` with counts and byte totals.
Future<BackupResult> backupBytesWithInfo(WalletRepo repo, VaultKey key, {int maxBlobBytes = backupBlobBytesDefault}) async {
  final t = PerfTimer('backup.write', warnMs: 2000);
  final ops = repo.snapshotOps();
  final blobs = <String, List<int>>{};
  var blobBytes = 0, skipped = 0;
  for (final (hash, sealedSize) in repo.backupBlobCandidates()) {
    final size = 4 * ((sealedSize + 2) ~/ 3); // its base64 length in the payload
    if (blobBytes + size > maxBlobBytes) {
      skipped++;
      continue;
    }
    final sealed = repo.cachedBlob(hash, touch: false);
    if (sealed == null) continue;
    blobs[hash] = sealed;
    blobBytes += size;
  }
  final sealed = await seal(backupPayload(ops, blobs: blobs), key, aad: aadBackup);
  t.done({'ops': ops.length, 'blobs': blobs.length, 'blobBytes': blobBytes, 'blobsSkipped': skipped, 'bytes': sealed.length});
  return BackupResult(sealed, ops: ops.length, blobs: blobs.length, blobBytes: blobBytes, blobsSkipped: skipped);
}

/// Restores the backup [bytes] (a sealed file as [backupBytes] made it) into [repo], which must be empty
/// ([WalletRepo.isEmpty]; else [StateError] before anything is read: a wallet with data uses [mergeBackupBytes]). The
/// ops are applied through [WalletRepo.applyRemote] with `resend`, so matching, pairing and bill detection run once and
/// the restored state goes out to the other devices on the next sync like this device's own writes. The bill files in
/// it go into the cache, queued for upload ([_takeBlobs]). Returns the number of ops in the file.
///
/// Content that is not a backup or is of a newer format is a [BackupException]; a wrong key or a damaged seal is
/// the [VaultException] from [unseal]. Nothing is applied unless the whole file parses. [key] opens the file; when it
/// is not this wallet's key, pass the wallet's as [walletKey]: the bill files (sealed with the other key) are left out.
Future<int> restoreBackupBytes(WalletRepo repo, List<int> bytes, VaultKey key, {VaultKey? walletKey}) async {
  if (!repo.isEmpty) throw StateError('A backup can only be restored into an empty wallet.');
  final t = PerfTimer('backup.restore', warnMs: 5000);
  final (ops, blobs) = await _open(repo, bytes, key, 'backup.restore.failed');
  final valid = _checkBlobs(blobs, sameKey: _sameKey(key, walletKey));
  final changed = repo.applyRemote(ops, resend: true);
  final files = _takeBlobs(repo, valid, store: true);
  t.done({'ops': ops.length, 'changed': changed, 'bytes': bytes.length, 'blobs': files});
  return ops.length;
}

/// Merges the backup [bytes] into [repo] (with data or not) by the sync rule: field by field the newer change (HLC)
/// wins and an older or equal one changes nothing, so nothing is doubled and merging the same file again changes
/// nothing. Same checks as [restoreBackupBytes] (wrong key, damaged, newer format, clock ahead: an exception, nothing
/// applied). Only the fields that changed something are queued for the other devices
/// (`applyRemote(resendChanged: true)`); matching runs afterwards as after a sync (when caught up). Bill files go
/// into the cache as in a restore; [walletKey] as there.
///
/// With [dryRun] the apply is rolled back: the counts are those of the real merge, and tables, clocks, outbox, HLC
/// and cache stay exactly as they were (the app's preview).
Future<MergeResult> mergeBackupBytes(WalletRepo repo, List<int> bytes, VaultKey key, {bool dryRun = false, VaultKey? walletKey}) async {
  final t = PerfTimer('backup.merge', warnMs: 5000);
  final (ops, blobs) = await _open(repo, bytes, key, 'backup.merge.failed');
  final valid = _checkBlobs(blobs, sameKey: _sameKey(key, walletKey));
  var files = 0;
  // A dry run counts the files inside its rolled-back transaction, so a bill deleted here (or brought in) counts as
  // in the real merge.
  final byEntity = repo.applyRemoteByEntity(ops,
      resendChanged: true, dryRun: dryRun, beforeRollback: dryRun ? () => files = _takeBlobs(repo, valid, store: false) : null);
  if (!dryRun) files = _takeBlobs(repo, valid, store: true);
  final changed = byEntity.values.fold(0, (a, b) => a + b);
  t.done({'ops': ops.length, 'changed': changed, 'dryRun': dryRun, 'bytes': bytes.length, 'blobs': files});
  return MergeResult(ops: ops.length, changed: changed, changedByEntity: byEntity, blobs: files);
}

bool _sameKey(VaultKey key, VaultKey? walletKey) {
  if (walletKey == null) return true;
  for (var i = 0; i < key.bytes.length; i++) {
    if (key.bytes[i] != walletKey.bytes[i]) return false;
  }
  return true;
}

/// Unseals and parses a backup file and checks its clocks (H7); every failure is logged as [event] and thrown.
Future<(List<Op>, Map<Object?, Object?>)> _open(WalletRepo repo, List<int> bytes, VaultKey key, String event) async {
  final List<int> clear;
  try {
    clear = await unseal(bytes, key, aad: aadBackup);
  } on VaultException catch (e, st) {
    logError(_log, event, e, st, fields: {'reason': e.failure?.name ?? 'vault', 'bytes': bytes.length});
    rethrow;
  }
  final (ops, blobs) = _parse(clear, bytes.length, event: event);
  var newest = 0;
  for (final op in ops) {
    newest = max(newest, Hlc.parse(op.hlc).millis);
  }
  final ahead = newest - repo.clock.now();
  if (ahead > maxClockDrift.inMilliseconds) {
    logEvent(_log, Level.WARNING, event, {'reason': BackupFailure.clockAhead.name, 'aheadMin': ahead ~/ 60000});
    throw const BackupException(
        BackupFailure.clockAhead, "The backup has changes dated later than this device's clock. Check the date and time on both devices.");
  }
  return (ops, blobs);
}

/// The bill files of a backup whose SHA-256 of the sealed bytes is their hash, as (hash, sealed); the others are
/// counted and logged as `backup.blobBad`. None with [sameKey] false (sealed with another wallet's key).
List<(String, List<int>)> _checkBlobs(Map<Object?, Object?> blobs, {required bool sameKey}) {
  final out = <(String, List<int>)>[];
  var bad = 0;
  for (final MapEntry(:key, :value) in blobs.entries) {
    List<int>? sealed;
    if (key is String && isBlobHash(key) && value is String) {
      try {
        sealed = base64Decode(value);
      } on FormatException catch (e, st) {
        logError(_log, 'backup.blobBad', e, st, level: Level.FINE);
      }
    }
    if (sealed == null || sha256Hex(sealed) != key) {
      bad++;
      continue;
    }
    if (sameKey) out.add((key as String, sealed));
  }
  if (bad > 0) logEvent(_log, Level.WARNING, 'backup.blobBad', {'files': bad});
  if (blobs.isNotEmpty && !sameKey) logEvent(_log, Level.INFO, 'backup.blobs', {'files': 0, 'inFile': blobs.length, 'otherKey': true});
  return out;
}

/// Puts the checked bill files ([_checkBlobs]) that a live bill points to and that are not cached yet into the cache,
/// queued for upload (the relay keeps a hash once, so uploading one it already has changes nothing); `blob_own` is
/// not set (the file was attached elsewhere). With [store] false (a dry run, called inside its transaction) nothing is
/// written and the same files are counted. Returns the files taken. Logs counts and byte totals only.
int _takeBlobs(WalletRepo repo, List<(String, List<int>)> valid, {required bool store}) {
  if (valid.isEmpty) return 0;
  var taken = 0, bytes = 0;
  for (final (hash, sealed) in valid) {
    if (repo.cachedBlob(hash, touch: false) != null || !repo.blobInUse(hash)) continue;
    if (store) repo.putCachedBlob(hash, sealed, queue: true);
    taken++;
    bytes += sealed.length;
  }
  logEvent(_log, Level.INFO, 'backup.blobs', {'files': taken, 'bytes': bytes, 'checked': valid.length, 'dryRun': !store});
  return taken;
}

/// The backup payload of [ops], unsealed: UTF-8 JSON `{"v":1,"ops":[...]}` (also a relay snapshot's content), plus
/// `"blobs": {"<hash>": "<base64>"}` when [blobs] holds sealed bill files.
Uint8List backupPayload(List<Op> ops, {Map<String, List<int>> blobs = const {}}) => utf8.encode(jsonEncode({
      'v': backupVersion,
      'ops': [for (final op in ops) op.toJson()],
      if (blobs.isNotEmpty) 'blobs': {for (final MapEntry(:key, :value) in blobs.entries) key: base64Encode(value)},
    }));

/// The ops of an unsealed backup payload (a relay snapshot), or a [BackupException]; logged as [event] with the
/// reason only.
List<Op> backupPayloadOps(List<int> clear, {String event = 'backup.parse.failed'}) => _parse(clear, clear.length, event: event).$1;

/// The ops and the raw `blobs` map (empty when absent) of an unsealed backup, or a [BackupException] (logged with the
/// reason only). A `blobs` value that is not a map makes the file damaged; its entries are checked by [_checkBlobs].
(List<Op>, Map<Object?, Object?>) _parse(List<int> clear, int sealedBytes, {String event = 'backup.restore.failed'}) {
  Never refuse(BackupFailure reason, Object error, StackTrace st, String message) {
    logError(_log, event, error, st, fields: {'reason': reason.name, 'bytes': sealedBytes});
    throw BackupException(reason, message);
  }

  final Object? json;
  try {
    json = jsonDecode(utf8.decode(clear));
  } on Object catch (e, st) {
    refuse(BackupFailure.damaged, e, st, 'The backup file is damaged.');
  }
  if (json is! Map) throw const BackupException(BackupFailure.damaged, 'The backup file is damaged.');
  final v = json['v'];
  if (v is int && v > backupVersion) {
    logEvent(_log, Level.WARNING, event, {'reason': BackupFailure.newerVersion.name, 'v': v});
    throw const BackupException(BackupFailure.newerVersion, 'The backup was made by a newer version of the app. Update the app first.');
  }
  final list = json['ops'];
  final blobs = json['blobs'];
  if (v != backupVersion || list is! List || (blobs != null && blobs is! Map)) {
    logEvent(_log, Level.WARNING, event, {'reason': BackupFailure.damaged.name});
    throw const BackupException(BackupFailure.damaged, 'The backup file is damaged.');
  }
  try {
    final ops = [for (final j in list) Op.fromJson(Map<String, Object?>.from(j as Map))];
    for (final op in ops) {
      Hlc.parse(op.hlc);
    }
    return (ops, blobs is Map ? Map<Object?, Object?>.from(blobs) : const <Object?, Object?>{});
  } on Object catch (e, st) {
    refuse(BackupFailure.damaged, e, st, 'The backup file is damaged.');
  }
}
