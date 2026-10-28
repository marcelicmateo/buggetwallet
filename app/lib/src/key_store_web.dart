import 'package:wallet_core/wallet_core.dart';
import 'package:web/web.dart' as web;

import 'device_key.dart';
import 'key_vault.dart';

/// `window.localStorage` / `sessionStorage` as a [KeyValueStore].
class _BrowserStore implements KeyValueStore {
  final web.Storage _s;
  _BrowserStore(this._s);
  @override
  String? read(String name) => _s.getItem(name);
  @override
  void write(String name, String value) => _s.setItem(name, value);
  @override
  void remove(String name) => _s.removeItem(name);
}

/// The wallet key in the browser: wrapped with a passphrase in localStorage; after "Unlock" the key itself sits in sessionStorage
/// (this tab only). The passphrase is never stored. See [KeyVault].
class KeyStore {
  KeyStore();

  final KeyVault _vault = KeyVault(local: _BrowserStore(web.window.localStorage), session: _BrowserStore(web.window.sessionStorage));

  /// A wrapped key is stored but this tab is not unlocked: the app shows the Unlock screen.
  bool get isLocked => _vault.isLocked;

  /// The key of this tab, or null when nothing is stored or it is still locked.
  Future<VaultKey?> read() => _vault.read();

  /// Opens the stored key. Throws [WrongPassphrase].
  Future<VaultKey> unlock(String passphrase) => _vault.unlock(passphrase);

  /// Wraps and stores [key]; the web needs a [passphrase] (at least [minPassphraseLength] characters).
  Future<void> write(VaultKey key, {String? passphrase}) => _vault.write(key, passphrase: passphrase);

  /// Joining another wallet while one is open is not offered in the browser.
  Future<String> writeAside(String stamp, VaultKey key) => throw UnsupportedError('No set-aside key in the browser.');

  Future<void> removeAside(String slot) async {}

  Future<void> writeJoinMarker(String text) async {}

  Future<String?> readJoinMarker() async => null;

  Future<void> clearJoinMarker() async {}

  static const _idName = 'bw.deviceId';

  /// This browser's device id (H6), next to the wrapped key; not secret, so plain in localStorage. Never logged.
  Future<String?> readDeviceId() async => web.window.localStorage.getItem(_idName);

  Future<void> writeDeviceId(String id) async => web.window.localStorage.setItem(_idName, id);

  static const _devKeyName = 'bw.deviceKey';

  /// This browser's relay device key (DK): a revocable relay credential only, never a data key, so plain in localStorage.
  /// Never logged; null when none is stored or it is damaged.
  Future<List<int>?> readDeviceKey() async => decodeDeviceKey(web.window.localStorage.getItem(_devKeyName));

  Future<void> writeDeviceKey(List<int> seed) async => web.window.localStorage.setItem(_devKeyName, encodeDeviceKey(seed));

  /// Removes the stored key, its device id and device key, and this tab's copy.
  Future<void> forget() async {
    _vault.forget();
    web.window.localStorage.removeItem(_idName);
    web.window.localStorage.removeItem(_devKeyName);
  }
}
