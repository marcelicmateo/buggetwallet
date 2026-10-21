// Where the wallet key lives: the system keystore or a private file (key_store_io.dart), or a passphrase-wrapped copy in the
// browser (key_store_web.dart, `dart.library.js_interop`). Both have the same members, so the screens compile everywhere.
export 'key_store_io.dart' if (dart.library.js_interop) 'key_store_web.dart' show KeyStore;
export 'key_vault.dart' show WrongPassphrase, minPassphraseLength;
