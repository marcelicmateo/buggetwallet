// Web twin of `folder_sync_io.dart`: the browser has no shared folder (no Syncthing). Sync for the web build is the
// relay transport of the sync redesign; until then the constructor throws.
import 'repo.dart';
import 'sync.dart';
import 'vault.dart';

/// Not available on the web: the constructor throws [UnsupportedError]. Same public members as the native class.
class FolderSync {
  final String folder;
  final VaultKey key;
  final String appVersion;

  FolderSync(this.folder, this.key, {this.appVersion = ''}) {
    throw UnsupportedError('FolderSync is not available on the web');
  }

  String get build => '$syncReaderVersion.${WalletRepo.schemaVersion}+$appVersion';

  Future<SyncReport> run(WalletRepo repo) => throw UnsupportedError('FolderSync is not available on the web');
}
