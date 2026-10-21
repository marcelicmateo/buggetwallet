// Web twin of `backup_io.dart`: the browser has no sync folder. The web app downloads `backupBytes` and restores an
// uploaded file with `restoreBackupBytes` (both in `backup.dart`).
import 'backup.dart';
import 'repo.dart';
import 'vault.dart';

Never _unsupported() =>
    throw UnsupportedError('Backup files in a sync folder are not available on the web: use backupBytes/restoreBackupBytes');

/// Not available on the web.
String backupsFolder(String syncFolder) => _unsupported();

/// Not available on the web.
String backupPath(String syncFolder, String name) => _unsupported();

/// Not available on the web; use [backupBytes].
Future<String> writeBackup(WalletRepo repo, String syncFolder, VaultKey key, {required String today}) => _unsupported();

/// Not available on the web; use [restoreBackupBytes].
Future<int> restoreBackup(WalletRepo repo, String file, VaultKey key) => _unsupported();

/// Not available on the web.
Future<List<BackupInfo>> listBackups(String syncFolder) => _unsupported();
