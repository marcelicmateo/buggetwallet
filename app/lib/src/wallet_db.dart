// Opens the wallet database: a file in the app folder on phones and computers, IndexedDB in the browser (`dart.library.js_interop`).
export 'wallet_db_base.dart';
export 'wallet_db_io.dart' if (dart.library.js_interop) 'wallet_db_web.dart' show openWalletDb;
