// Web twin of `sqlite_io.dart`: the browser has no file database to open by path. The web app opens a
// `package:sqlite3/wasm.dart` database itself and hands it to `WalletRepo.fromDatabase`.
import 'package:sqlite3/common.dart';

/// Not available on the web; use `WalletRepo.fromDatabase`.
CommonDatabase openFileDb(String path) =>
    throw UnsupportedError('WalletRepo.open is not available on the web: open a WASM database and use WalletRepo.fromDatabase');

/// Not available on the web; use `WalletRepo.fromDatabase`.
CommonDatabase openMemoryDb() =>
    throw UnsupportedError('WalletRepo.inMemory is not available on the web: open a WASM database and use WalletRepo.fromDatabase');
