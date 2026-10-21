// Native SQLite (dart:ffi): what `WalletRepo.open` and `WalletRepo.inMemory` use. The web twin is `sqlite_web.dart`.
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

/// Opens (or creates) the database file at [path].
CommonDatabase openFileDb(String path) => sqlite3.open(path);

/// A fresh in-memory database.
CommonDatabase openMemoryDb() => sqlite3.openInMemory();
