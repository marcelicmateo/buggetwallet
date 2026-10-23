// Backups: the sealed payload the app saves through the save dialog and restores from a picked file (compiles for the web).
import 'dart:convert';
import 'dart:typed_data';

import 'dates.dart';
import 'hlc.dart';
import 'logs.dart';
import 'repo.dart';
import 'vault.dart';

final _log = Logger('bw.backup');

/// The format written by [backupBytes]; a file with a higher one comes from a newer build.
const backupVersion = 1;

/// Why a restore refused a file. Key and sealing errors are [VaultException]s instead.
enum BackupFailure {
  /// The file could not be read (missing, no permission, I/O error).
  unreadable,

  /// Unsealed, but not a backup: not JSON, not `{"v":1,"ops":[...]}`, or an op or clock that does not parse.
  damaged,

  /// A backup of a format this build does not know (`v` above [backupVersion]).
  newerVersion,
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

/// A full snapshot of [repo] ([WalletRepo.snapshotOps]: every synced row, deleted ones included, settings included,
/// no device-local values) as UTF-8 JSON `{"v":1,"ops":[...]}`, sealed with [key] like a sync file. What
/// the app saves through the save dialog. Logs `backup.write` with the op count.
Future<Uint8List> backupBytes(WalletRepo repo, VaultKey key) async {
  final t = PerfTimer('backup.write', warnMs: 2000);
  final ops = repo.snapshotOps();
  final payload = backupPayload(ops);
  final sealed = await seal(payload, key, aad: aadBackup);
  t.done({'ops': ops.length, 'bytes': sealed.length});
  return sealed;
}

/// Restores the backup [bytes] (a sealed file as [backupBytes] made it) into [repo], which must be empty
/// ([WalletRepo.isEmpty]; else [StateError] before anything is read: a wallet with data merges through the sync
/// folder, never through a restore). The ops are applied through [WalletRepo.applyRemote] with `resend`, so matching,
/// pairing and bill detection run once and the restored state goes out to the other devices on the next sync like
/// this device's own writes. Returns the number of ops in the file.
///
/// Content that is not a backup or is of a newer format is a [BackupException]; a wrong key or a damaged seal is
/// the [VaultException] from [unseal]. Nothing is applied unless the whole file parses.
Future<int> restoreBackupBytes(WalletRepo repo, List<int> bytes, VaultKey key) async {
  if (!repo.isEmpty) throw StateError('A backup can only be restored into an empty wallet.');
  final t = PerfTimer('backup.restore', warnMs: 5000);
  final List<int> clear;
  try {
    clear = await unseal(bytes, key, aad: aadBackup);
  } on VaultException catch (e, st) {
    logError(_log, 'backup.restore.failed', e, st, fields: {'reason': e.failure?.name ?? 'vault', 'bytes': bytes.length});
    rethrow;
  }
  final ops = _parse(clear, bytes.length);
  final changed = repo.applyRemote(ops, resend: true);
  t.done({'ops': ops.length, 'changed': changed, 'bytes': bytes.length});
  return ops.length;
}

/// The backup payload of [ops], unsealed: UTF-8 JSON `{"v":1,"ops":[...]}` (also a relay snapshot's content).
Uint8List backupPayload(List<Op> ops) => utf8.encode(jsonEncode({
      'v': backupVersion,
      'ops': [for (final op in ops) op.toJson()]
    }));

/// The ops of an unsealed backup payload (a relay snapshot), or a [BackupException]; logged as [event] with the
/// reason only.
List<Op> backupPayloadOps(List<int> clear, {String event = 'backup.parse.failed'}) => _parse(clear, clear.length, event: event);

/// The ops of an unsealed backup, or a [BackupException] (logged with the reason only).
List<Op> _parse(List<int> clear, int sealedBytes, {String event = 'backup.restore.failed'}) {
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
  if (v != backupVersion || list is! List) {
    logEvent(_log, Level.WARNING, event, {'reason': BackupFailure.damaged.name});
    throw const BackupException(BackupFailure.damaged, 'The backup file is damaged.');
  }
  try {
    final ops = [for (final j in list) Op.fromJson(Map<String, Object?>.from(j as Map))];
    for (final op in ops) {
      Hlc.parse(op.hlc);
    }
    return ops;
  } on Object catch (e, st) {
    refuse(BackupFailure.damaged, e, st, 'The backup file is damaged.');
  }
}
