// Backup files in the sync folder (dart:io). The web twin is `backup_web.dart`; the sealed payload itself
// (`backupBytes`, `restoreBackupBytes`) is in `backup.dart` and compiles for the web.
import 'dart:io';

import 'backup.dart';
import 'logs.dart';
import 'repo.dart';
import 'vault.dart';

final _log = Logger('bw.backup');

final _backupName = RegExp(r'^bw-backup-(\d{4}-\d{2}-\d{2})\.bwb$');

String _sep() => Platform.pathSeparator;

/// The folder backups live in: `<syncFolder>/budget-wallet/backups`.
String backupsFolder(String syncFolder) => '$syncFolder${_sep()}budget-wallet${_sep()}backups';

/// The full path of backup [name] in [syncFolder] (what [restoreBackup] takes).
String backupPath(String syncFolder, String name) => '${backupsFolder(syncFolder)}${_sep()}$name';

/// Writes a full snapshot of [repo] ([backupBytes]: every synced row, deleted ones included, settings included, no
/// device-local values) to `<syncFolder>/budget-wallet/backups/bw-backup-<today>.bwb`, sealed with [key] like the
/// sync files. The folder is created; the same day's file is replaced (written to a temp name first, then renamed, so
/// a reader never sees a half file). Returns the file name. [today] must be `YYYY-MM-DD`.
Future<String> writeBackup(WalletRepo repo, String syncFolder, VaultKey key, {required String today}) async {
  final name = backupFileName(today);
  final sealed = await backupBytes(repo, key);
  final dir = Directory(backupsFolder(syncFolder));
  await dir.create(recursive: true);
  final tmp = File('${dir.path}${_sep()}.$name.tmp');
  await tmp.writeAsBytes(sealed, flush: true);
  await tmp.rename('${dir.path}${_sep()}$name');
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
  final List<int> bytes;
  try {
    bytes = await File(file).readAsBytes();
  } on Object catch (e, st) {
    logError(_log, 'backup.restore.failed', e, st, fields: {'reason': BackupFailure.unreadable.name});
    throw const BackupException(BackupFailure.unreadable, 'The backup file cannot be read.');
  }
  return restoreBackupBytes(repo, bytes, key);
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
