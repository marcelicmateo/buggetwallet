// The browser's way to keep the wallet key: wrapped with a passphrase in localStorage, unwrapped in sessionStorage while the tab
// lives. Pure Dart (no dart:io, no browser classes) so it runs on the VM in tests: the storage is passed in as a [KeyValueStore].
//
// Privacy: logs say where the key is kept and whether it was found or locked, never the key, the passphrase or the blob.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:wallet_core/wallet_core.dart';

final _log = Logger('bw.key');

/// PBKDF2-HMAC-SHA256 rounds for the passphrase key (OWASP 2023 advice for this hash).
const pbkdf2Iterations = 310000;

/// The shortest passphrase the app accepts when it wraps a key.
const minPassphraseLength = 8;

/// The passphrase did not open the stored key.
class WrongPassphrase implements Exception {
  const WrongPassphrase();
  @override
  String toString() => 'Wrong passphrase.';
}

/// A tiny string store: `window.localStorage` / `sessionStorage` in the browser, a map in tests.
abstract class KeyValueStore {
  String? read(String name);
  void write(String name, String value);
  void remove(String name);
}

/// [KeyValueStore] in memory (tests, and a fallback when the browser refuses storage).
class MapKeyValueStore implements KeyValueStore {
  final Map<String, String> values = {};
  @override
  String? read(String name) => values[name];
  @override
  void write(String name, String value) => values[name] = value;
  @override
  void remove(String name) => values.remove(name);
}

Future<VaultKey> _derive(String passphrase, List<int> salt, int iterations) async {
  final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
  final secret = await kdf.deriveKeyFromPassword(password: passphrase, nonce: salt);
  return VaultKey(await secret.extractBytes());
}

/// [key] wrapped with [passphrase]: `bwk1.<rounds>.<salt>.<sealed key text>` (base64url parts). A new random 16-byte salt each time.
Future<String> wrapKey(VaultKey key, String passphrase, {int iterations = pbkdf2Iterations}) async {
  final salt = SecretKeyData.random(length: 16).bytes;
  final derived = await _derive(passphrase, salt, iterations);
  final sealed = await seal(utf8.encode(await key.toText()), derived, aad: aadWebKey);
  return 'bwk1.$iterations.${base64Url.encode(salt)}.${base64Url.encode(sealed)}';
}

/// The key inside [blob] (from [wrapKey]). A wrong passphrase is [WrongPassphrase]; a blob that is not ours or is damaged is a
/// [FormatException] / [VaultException].
Future<VaultKey> unwrapKey(String blob, String passphrase) async {
  final parts = blob.split('.');
  final rounds = parts.length == 4 && parts[0] == 'bwk1' ? int.tryParse(parts[1]) : null;
  if (rounds == null || rounds < 1) throw const FormatException('The stored key is not in a known format.');
  final Uint8List salt, sealed;
  try {
    salt = base64Url.decode(parts[2]);
    sealed = base64Url.decode(parts[3]);
  } on FormatException {
    throw const FormatException('The stored key is damaged.');
  }
  final derived = await _derive(passphrase, salt, rounds);
  final List<int> plain;
  try {
    plain = await unseal(sealed, derived, aad: aadWebKey);
  } on VaultException catch (e) {
    if (e.failure == UnsealFailure.badKey) throw const WrongPassphrase();
    rethrow;
  }
  return VaultKey.parse(utf8.decode(plain));
}

/// The key store of the web build, on top of two [KeyValueStore]s.
class KeyVault {
  static const wrappedName = 'budget_wallet_key_wrapped';
  static const sessionName = 'budget_wallet_key_session';

  /// Lasts until the browser data is cleared: holds the wrapped key.
  final KeyValueStore local;

  /// Lasts as long as the tab: holds the key after it was unlocked (a reload keeps it).
  final KeyValueStore session;
  final int iterations;
  KeyVault({required this.local, required this.session, this.iterations = pbkdf2Iterations});

  /// A wrapped key is stored but this tab has not been unlocked yet.
  bool get isLocked => local.read(wrappedName) != null && !_hasSession;
  bool get _hasSession => (session.read(sessionName) ?? '').isNotEmpty;

  /// The key of this tab, or null (nothing stored, or still locked).
  Future<VaultKey?> read() async {
    final text = session.read(sessionName);
    final found = text != null && text.isNotEmpty;
    logEvent(_log, Level.INFO, 'key.read', {'store': 'browser', 'found': found, 'locked': isLocked});
    return found ? VaultKey.parse(text) : null;
  }

  /// Opens the stored key with [passphrase] and keeps it for this tab. Throws [WrongPassphrase].
  Future<VaultKey> unlock(String passphrase) async {
    final blob = local.read(wrappedName);
    if (blob == null) throw StateError('No key is stored in this browser.');
    final t = PerfTimer('key.unlock', warnMs: 3000);
    try {
      final key = await unwrapKey(blob, passphrase);
      session.write(sessionName, await key.toText());
      t.done({'store': 'browser'});
      logEvent(_log, Level.INFO, 'key.unlocked', {'store': 'browser'});
      return key;
    } on WrongPassphrase {
      logEvent(_log, Level.INFO, 'key.unlockFailed', {'store': 'browser', 'reason': 'wrongPassphrase'});
      rethrow;
    }
  }

  /// Wraps [key] with [passphrase] (at least [minPassphraseLength] characters), stores it and keeps it for this tab.
  Future<void> write(VaultKey key, {String? passphrase}) async {
    if (passphrase == null || passphrase.length < minPassphraseLength) {
      throw ArgumentError('A passphrase of at least $minPassphraseLength characters is needed to keep the key in a browser.');
    }
    final t = PerfTimer('key.write', warnMs: 3000);
    local.write(wrappedName, await wrapKey(key, passphrase, iterations: iterations));
    session.write(sessionName, await key.toText());
    t.done({'store': 'browser'});
  }

  /// Removes the wrapped key and the tab's copy.
  void forget() {
    local.remove(wrappedName);
    session.remove(sessionName);
    logEvent(_log, Level.INFO, 'key.forgotten', {'store': 'browser'});
  }
}
