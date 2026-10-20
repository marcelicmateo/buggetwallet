import 'dart:convert';
import 'dart:io';

import 'hlc.dart';
import 'logs.dart';
import 'repo.dart';
import 'vault.dart';

final _log = Logger('bw.backup');

/// The format written by [writeBackup]; a file with a higher one comes from a newer build.
const backupVersion = 1;

final _backupName = RegExp(r'^bw-backup-(\d{4}-\d{2}-\d{2})\.bwb$');
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Why [restoreBackup] refused a file. Key and sealing errors are [VaultException]s instead.
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

/// One backup file in the sync folder: its [name] (`bw-backup-YYYY-MM-DD.bwb`), the [date] in it (`YYYY-MM-DD`) and its
/// full [path] (what [restoreBackup] takes).
class BackupInfo {
  final String name;
  final String date;
  final String path;
  const BackupInfo(this.name, this.date, this.path);
  @override
  String toString() => 'BackupInfo($name)';
}

String _sep() => Platform.pathSeparator;

/// The folder backups live in: `<syncFolder>/budget-wallet/backups`.
String backupsFolder(String syncFolder) => '$syncFolder${_sep()}budget-wallet${_sep()}backups';

/// The full path of backup [name] in [syncFolder] (what [restoreBackup] takes).
String backupPath(String syncFolder, String name) => '${backupsFolder(syncFolder)}${_sep()}$name';

/// Writes a full snapshot of [repo] ([WalletRepo.snapshotOps]: every synced row, deleted ones included, settings
/// included, no device-local values) to `<syncFolder>/budget-wallet/backups/bw-backup-<today>.bwb`, sealed with [key]
/// like the sync files. The folder is created; the same day's file is replaced (written to a temp name first, then
/// renamed, so a reader never sees a half file). Returns the file name. [today] must be `YYYY-MM-DD`.
Future<String> writeBackup(WalletRepo repo, String syncFolder, VaultKey key, {required String today}) async {
  if (!_isoDate.hasMatch(today)) throw ArgumentError('The date is not YYYY-MM-DD.');
  final t = PerfTimer('backup.write', warnMs: 2000);
  final ops = repo.snapshotOps();
  final payload = utf8.encode(jsonEncode({
    'v': backupVersion,
    'ops': [for (final op in ops) op.toJson()]
  }));
  final sealed = await seal(payload, key);
  final dir = Directory(backupsFolder(syncFolder));
  await dir.create(recursive: true);
  final name = 'bw-backup-$today.bwb';
  final tmp = File('${dir.path}${_sep()}.$name.tmp');
  await tmp.writeAsBytes(sealed, flush: true);
  await tmp.rename('${dir.path}${_sep()}$name');
  t.done({'ops': ops.length});
  return name;
}

/// Restores the backup at [file] (a full path, see [backupPath]) into [repo], which must be empty
/// ([WalletRepo.isEmpty]; else [StateError] before the file is touched: a wallet with data merges through the sync
/// folder, never through a restore). The ops are applied through [WalletRepo.applyRemote] with `resend`, so matching,
/// pairing and bill detection run once and the restored state goes out to the other devices on the next sync like
/// this device's own writes. Returns the number of ops in the file.
///
/// A file that cannot be read, is not a backup or is of a newer format is a [BackupException]; a wrong key or a
/// damaged seal is the [VaultException] from `unseal`. Nothing is applied unless the whole file parses.
Future<int> restoreBackup(WalletRepo repo, String file, VaultKey key) async {
  if (!repo.isEmpty) throw StateError('A backup can only be restored into an empty wallet.');
  final t = PerfTimer('backup.restore', warnMs: 5000);
  final List<int> bytes;
  try {
    bytes = await File(file).readAsBytes();
  } on Object catch (e, st) {
    logError(_log, 'backup.restore.failed', e, st, fields: {'reason': BackupFailure.unreadable.name});
    throw const BackupException(BackupFailure.unreadable, 'The backup file cannot be read.');
  }
  final List<int> clear;
  try {
    clear = await unseal(bytes, key);
  } on VaultException catch (e, st) {
    logError(_log, 'backup.restore.failed', e, st, fields: {'reason': e.failure?.name ?? 'vault', 'bytes': bytes.length});
    rethrow;
  }
  final ops = _parse(clear, bytes.length);
  final changed = repo.applyRemote(ops, resend: true);
  t.done({'ops': ops.length, 'changed': changed, 'bytes': bytes.length});
  return ops.length;
}

/// The ops of an unsealed backup, or a [BackupException] (logged with the reason only).
List<Op> _parse(List<int> clear, int sealedBytes) {
  Never refuse(BackupFailure reason, Object error, StackTrace st, String message) {
    logError(_log, 'backup.restore.failed', error, st, fields: {'reason': reason.name, 'bytes': sealedBytes});
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
    logEvent(_log, Level.WARNING, 'backup.restore.failed', {'reason': BackupFailure.newerVersion.name, 'v': v});
    throw const BackupException(BackupFailure.newerVersion, 'The backup was made by a newer version of the app. Update the app first.');
  }
  final list = json['ops'];
  if (v != backupVersion || list is! List) {
    logEvent(_log, Level.WARNING, 'backup.restore.failed', {'reason': BackupFailure.damaged.name});
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

/// The backups in `<syncFolder>/budget-wallet/backups`, newest first (by the date in the name, then name), each with
/// its full path. Files
/// not named like a backup are left out; a missing folder gives an empty list.
Future<List<BackupInfo>> listBackups(String syncFolder) async {
  final dir = Directory(backupsFolder(syncFolder));
  if (!await dir.exists()) return const [];
  final out = <BackupInfo>[];
  await for (final f in dir.list()) {
    if (f is! File) continue;
    final name = f.path.split(_sep()).last;
    final m = _backupName.firstMatch(name);
    if (m != null) out.add(BackupInfo(name, m.group(1)!, f.path));
  }
  out.sort((a, b) {
    final c = b.date.compareTo(a.date);
    return c != 0 ? c : b.name.compareTo(a.name);
  });
  logEvent(_log, Level.FINE, 'backup.list', {'files': out.length});
  return out;
}
