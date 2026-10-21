import 'package:wallet_core/wallet_core.dart';

/// Web: another tab of this browser has the wallet open (it holds the `bw-wallet` Web Lock). Opening it here too would let the two
/// tabs overwrite each other's changes, so [openWalletDb] throws this instead. Never thrown on phones and computers.
class WalletInUse implements Exception {
  const WalletInUse();
  @override
  String toString() => 'WalletInUse: the wallet is open in another tab';
}

/// The wallet database as the controller sees it: the repo, a way to make sure it reached storage, and a way to wipe it.
/// `wallet_db_io.dart` (a file) and `wallet_db_web.dart` (IndexedDB) make the real ones; tests pass their own.
class WalletDb {
  final WalletRepo repo;
  final Future<void> Function()? _persist;
  final Future<void> Function()? _forget;
  WalletDb(this.repo, {Future<void> Function()? persist, Future<void> Function()? forget})
      : _persist = persist,
        _forget = forget;

  /// Does this database need [persist] calls (the browser's does)?
  bool get persists => _persist != null;

  /// Writes pending changes to storage. A file database writes on its own, so this does nothing there; in a browser it
  /// flushes the IndexedDB file system.
  Future<void> persist() async => _persist?.call();

  /// Closes the database and deletes everything stored for it.
  Future<void> forget() async {
    repo.close();
    await _forget?.call();
  }
}
