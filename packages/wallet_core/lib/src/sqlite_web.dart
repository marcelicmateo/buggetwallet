// Web twin of `sqlite_io.dart`: the browser has no file database to open by path. The web app opens a
// `package:sqlite3/wasm.dart` database itself (keyed with `openKeyed`) and hands it to `WalletRepo.fromDatabase`.
import 'package:sqlite3/common.dart';

/// Not available on the web; use `WalletRepo.fromDatabase`.
CommonDatabase openFileDb(String path) =>
    throw UnsupportedError('WalletRepo.open is not available on the web: open a WASM database and use WalletRepo.fromDatabase');

/// Not available on the web; use `WalletRepo.fromDatabase`.
CommonDatabase openMemoryDb() =>
    throw UnsupportedError('WalletRepo.inMemory is not available on the web: open a WASM database and use WalletRepo.fromDatabase');

/// Not available on the web; use `openKeyed` and `WalletRepo.fromDatabase`.
CommonDatabase openKeyedFileDb(String path, List<int> dbKey, {void Function(String step)? step}) =>
    throw UnsupportedError('WalletRepo.open is not available on the web: open a WASM database with openKeyed');

/// Not available on the web (no second connection, no isolates); `WalletRepo.fromDatabase` repos never call it.
Future<T> readInIsolate<T>(String path, List<int>? dbKey, T Function(CommonDatabase db) read) =>
    throw UnsupportedError('readInIsolate is not available on the web');
