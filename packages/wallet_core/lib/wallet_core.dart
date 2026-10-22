/// Budget Wallet core: local SQLite database, change log, end-to-end
/// encrypted relay sync and the budget engine.
///
/// Compiles for the web (dart2js and dart2wasm): the dart:io parts (`*_io.dart`) are swapped for stubs
/// (`*_web.dart`) that throw [UnsupportedError]; `tool/web_smoke.dart` is the compile check.
library;

export 'package:wallet_importer/wallet_importer.dart' show TxKind;

export 'src/backup.dart';
export 'src/budget.dart';
export 'src/categories.dart';
export 'src/dates.dart';
export 'src/export.dart';
export 'src/hlc.dart' show Hlc, HlcClock;
export 'src/local_db.dart' show localDbKey, localDbKeyInfo, openKeyed, WalletDbKeyException;
export 'src/logs.dart';
export 'src/logs_io.dart' if (dart.library.js_interop) 'src/logs_web.dart';
export 'src/matching.dart';
export 'src/models.dart';
export 'src/periods.dart';
export 'src/recurring.dart';
export 'src/repo.dart';
export 'src/search.dart';
export 'src/sync.dart';
export 'src/sync_engine.dart';
export 'src/transfers.dart';
export 'src/vault.dart';
