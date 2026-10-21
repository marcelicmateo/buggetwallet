// Sync through a shared folder (dart:io). The web twin is `folder_sync_web.dart`; the types the app's screens read
// (`SyncException`, `SyncReport`, `SyncProblem`) are in `sync.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/common.dart' show SqliteException;

import 'hlc.dart';
import 'logs.dart';
import 'repo.dart';
import 'sync.dart';
import 'sync_problems.dart';
import 'vault.dart';

final _log = Logger('bw.sync');

/// What is logged of a sync file name: its sequence number only (`0000000042` of `0000000042.bwop`). Conflict
/// copies add a file-sync device id to the name, and device folder names are random ids, so neither is logged.
String _seq(String name) => RegExp(r'^\d+').stringMatch(name) ?? '?';

/// SQLite result codes that are about this device's database, not about the file being applied (busy, locked, out of
/// memory, read-only, I/O error, damaged database, disk full, cannot open, not a database). Those stop the run, and
/// the file is read again next time, instead of being refused for good.
const _dbTrouble = {5, 6, 7, 8, 10, 11, 13, 14, 26};

/// A file refused for [reason]; [error] is what was thrown.
class _Refused implements Exception {
  final SyncProblemReason reason;
  final Object error;
  final StackTrace stack;
  _Refused(this.reason, this.error, this.stack);
}

/// Unseals, parses and applies one sync file (matching is left to the caller). Returns (fields changed, ops read).
/// Throws [_Refused] when the file cannot be used. Database errors from [_dbTrouble] are rethrown as they are.
/// The file is applied in one transaction: a refused file changes nothing.
Future<(int, int)> _applyFile(WalletRepo repo, VaultKey key, List<int> bytes) async {
  final List<int> clear;
  try {
    clear = await unseal(bytes, key);
  } on VaultException catch (e, st) {
    throw _Refused(
        switch (e.failure) {
          UnsealFailure.badKey => SyncProblemReason.badKey,
          UnsealFailure.newerFormat => SyncProblemReason.unknownVersion,
          _ => SyncProblemReason.corrupt,
        },
        e,
        st);
  }
  final List<Op> ops;
  try {
    ops = [for (final j in jsonDecode(utf8.decode(clear)) as List) Op.fromJson(Map<String, Object?>.from(j as Map))];
    for (final op in ops) {
      Hlc.parse(op.hlc); // a clock that does not parse makes the whole file damaged, before anything is applied
    }
  } on Object catch (e, st) {
    throw _Refused(SyncProblemReason.corrupt, e, st);
  }
  try {
    return (repo.applyRemote(ops, match: false), ops.length);
  } on SqliteException catch (e, st) {
    if (_dbTrouble.contains(e.resultCode)) rethrow;
    throw _Refused(SyncProblemReason.applyFailed, e, st);
  } on Object catch (e, st) {
    throw _Refused(SyncProblemReason.applyFailed, e, st);
  }
}

/// Sync through a shared folder kept in step by Syncthing (or any file sync).
///
/// Layout inside the chosen folder:
/// ```
/// budget-wallet/vault.json                      key fingerprint (no secrets)
/// budget-wallet/devices/<deviceId>/<n>.bwop     encrypted batches of changes
/// ```
/// Each device only ever writes into its own folder, so file sync never sees
/// conflicting edits. Files are never rewritten, which also makes them safe to
/// sync in any order.
class FolderSync {
  final String folder;
  final VaultKey key;

  /// The app's version, if the caller knows it: files refused because the database rejected them, or as a newer
  /// format, are read again once after it changes.
  final String appVersion;
  FolderSync(this.folder, this.key, {this.appVersion = ''});

  /// What a quarantined file's record says about the build that refused it ([BadFile.build]): the file format this
  /// build reads, the database schema (a bump replays every peer file once, see [WalletRepo.schemaVersion], and may
  /// make a refused file apply) and the app version. Files refused as [SyncProblemReason.badKey] or
  /// [SyncProblemReason.corrupt] are never retried for a build change: only a changed file is.
  String get build => '$syncReaderVersion.${WalletRepo.schemaVersion}+$appVersion';

  Directory get _root => Directory('$folder${Platform.pathSeparator}budget-wallet');
  Directory get _devices => Directory('${_root.path}${Platform.pathSeparator}devices');

  Future<void> _checkVault() async {
    await _devices.create(recursive: true);
    final f = File('${_root.path}${Platform.pathSeparator}vault.json');
    final kid = await key.keyId();
    if (await f.exists()) {
      Object? j;
      try {
        j = jsonDecode(await f.readAsString());
      } on FormatException catch (e, st) {
        j = null;
        logError(_log, 'sync.vault.unreadable', e, st);
      }
      if (j is! Map) {
        // Empty, cut off (half-synced) or not an object: never guess, and never overwrite another wallet's file.
        logEvent(_log, Level.WARNING, 'sync.vault.invalid');
        throw const SyncException('The sync folder\'s wallet file is damaged or not synced yet. Try again after it has synced.');
      }
      if (j['kid'] != kid) {
        logEvent(_log, Level.WARNING, 'sync.vault.mismatch');
        throw const SyncException(
            'This sync folder belongs to a wallet with a different key. Join that wallet with its key, or pick another folder.');
      }
    } else {
      await f.writeAsString(jsonEncode({'v': 1, 'kid': kid}));
      logEvent(_log, Level.INFO, 'sync.vault.created');
    }
  }

  Future<SyncReport> run(WalletRepo repo) async {
    if (!await Directory(folder).exists()) {
      // No path in the message: it is logged, and paths can contain the user's name.
      throw const SyncException('The sync folder is missing. Check that it still exists, or pick it again.');
    }
    await _checkVault();
    final sep = Platform.pathSeparator;

    // 1. Export this device's pending changes as one encrypted file.
    var sent = 0;
    final pending = repo.pendingOps();
    final export = PerfTimer('sync.export', warnMs: 500);
    if (pending.isNotEmpty) {
      final mine = Directory('${_devices.path}$sep${repo.deviceId}');
      await mine.create(recursive: true);
      final n = repo.nextFileNumber();
      final name = '${n.toString().padLeft(10, '0')}.bwop';
      final payload = utf8.encode(jsonEncode([for (final (_, op) in pending) op.toJson()]));
      final tmp = File('${mine.path}$sep.$name.tmp');
      final sealed = await seal(payload, key);
      await tmp.writeAsBytes(sealed, flush: true);
      await tmp.rename('${mine.path}$sep$name');
      repo.markExported(pending.last.$1);
      sent = pending.length;
      export.done({'ops': sent, 'file': n, 'jsonBytes': payload.length, 'bytes': sealed.length});
    } else {
      logEvent(_log, Level.FINE, 'sync.export.none');
    }

    // 2. Read every file from other devices that hasn't been applied yet. Hand-added expenses are matched to bank
    //    rows once at the end, not after every file (a new device's first sync can read hundreds).
    //    A file that cannot be used is skipped (the others still apply: ops are per-field last-writer-wins, so order
    //    does not matter) and quarantined ([BadFiles]): it is read again only once it changes, or after an update for
    //    a newer format. The quarantine is separate from `peer_files`, so a schema upgrade (which forgets the files
    //    read, [WalletRepo.schemaVersion]) lists a quarantined file again but, unchanged, still skips it.
    var received = 0, filesRead = 0, opsRead = 0, bytesRead = 0, devices = 0, known = 0;
    final problems = <SyncProblem>[];
    final bad = BadFiles.load(repo), listed = <String>{};
    var badChanged = false, complete = false;
    final apply = PerfTimer('sync.apply', warnMs: 1000);
    try {
      await for (final dev in _devices.list()) {
        if (dev is! Directory) continue;
        final device = dev.path.split(sep).last;
        if (device == repo.deviceId) continue;
        devices++;
        final files =
            await dev.list().where((f) => f is File && f.path.endsWith('.bwop') && !f.path.split(sep).last.startsWith('.')).toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          final name = f.path.split(sep).last;
          if (repo.peerFileSeen(device, name)) continue;
          final k = BadFile.keyOf(device, name);
          listed.add(k);
          final List<int> bytes;
          try {
            bytes = await (f as File).readAsBytes();
          } on Object catch (e, st) {
            // Removed or locked while syncing: not the file's fault, so not quarantined; read again next run.
            logError(_log, 'sync.file.unreadable', e, st, fields: {'file': _seq(name)});
            problems.add(SyncProblem(SyncProblem.shortId(device), SyncProblemReason.unreadable, bytes: 0));
            continue;
          }
          final was = bad.byKey[k];
          if (was != null && !was.retryAfterUpgrade(build) && was.hash == await fileHash(bytes)) {
            problems.add(was.problem(isNew: false));
            known++;
            continue;
          }
          final int changed, count;
          try {
            (changed, count) = await _applyFile(repo, key, bytes);
          } on _Refused catch (r) {
            logError(_log, 'sync.file.failed', r.error, r.stack,
                fields: {'file': _seq(name), 'reason': r.reason.name, 'bytes': bytes.length});
            bad.byKey[k] = BadFile(device, name, r.reason, size: bytes.length, hash: await fileHash(bytes), build: build);
            badChanged = true;
            problems.add(SyncProblem(SyncProblem.shortId(device), r.reason, bytes: bytes.length));
            continue;
          }
          if (bad.byKey.remove(k) != null) badChanged = true;
          received += changed;
          repo.markPeerFile(device, name);
          filesRead++;
          opsRead += count;
          bytesRead += bytes.length;
          logEvent(_log, Level.FINE, 'sync.file', {'file': _seq(name), 'bytes': bytes.length, 'ops': count, 'changed': changed});
        }
      }
      complete = true;
    } finally {
      // Quarantined files that are gone (or applied by now) are forgotten, but only after a complete listing.
      if (complete) {
        final gone = [
          for (final k in bad.byKey.keys)
            if (!listed.contains(k)) k
        ];
        for (final k in gone) {
          bad.byKey.remove(k);
        }
        badChanged |= gone.isNotEmpty;
      }
      if (badChanged) bad.save(repo);
      repo.runPendingMatch(); // also if reading the folder failed midway: what was applied gets matched
    }
    final fresh = problems.where((p) => p.isNew).length;
    apply.done({
      'devices': devices,
      'files': filesRead,
      'ops': opsRead,
      'changed': received,
      'bytes': bytesRead,
      'bad': problems.length,
      'known': known,
    });
    if (problems.isNotEmpty) {
      logEvent(_log, fresh > 0 ? Level.WARNING : Level.INFO, 'sync.files.skipped', {'bad': problems.length, 'new': fresh});
    }
    return SyncReport(sent, received, filesRead, problems: problems);
  }
}
