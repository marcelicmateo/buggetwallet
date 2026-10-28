import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'device_key.dart';
import 'platform.dart';

final _log = Logger('bw.key');

/// Keeps the wallet key on this device: the system keystore on phones,
/// a private file in the app's support folder on computers.
///
/// Logs where the key is kept and whether it was found, never the key or any part of it.
class KeyStore {
  static const _name = 'budget_wallet_key';
  static const _idName = 'budget_wallet_device_id';
  static const _devKeyName = 'budget_wallet_device_key';
  static String get _store => isMobile ? 'secure' : 'file';

  /// [keyDir] is for tests: they point the desktop key file at a temporary folder (null = the app's support folder).
  KeyStore({Directory? keyDir}) : _keyDir = keyDir;

  final Directory? _keyDir;

  Future<File> _file([String name = 'wallet.key']) async {
    final dir = _keyDir ?? await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// `chmod` (not on Windows); a failure is logged by [event] and does not stop the write.
  static Future<void> _chmod(String mode, String path, String event) async {
    if (isWindows) return;
    try {
      final r = await Process.run('chmod', [mode, path]);
      if (r.exitCode != 0) logEvent(_log, Level.WARNING, event, {'exit': r.exitCode});
    } on ProcessException {
      logEvent(_log, Level.WARNING, event, {'exit': -1});
    }
  }

  /// Only the browser build locks the key behind a passphrase.
  bool get isLocked => false;

  /// Browser only.
  Future<VaultKey> unlock(String passphrase) => throw UnsupportedError('Unlocking with a passphrase is for the web build.');

  Future<VaultKey?> read() async {
    final t = PerfTimer('key.read', warnMs: 1000);
    String? text;
    if (isMobile) {
      text = await const FlutterSecureStorage().read(key: _name);
    } else {
      final f = await _file();
      if (await f.exists()) {
        // An install from before the private modes: tighten the folder and the file on the next read, not only on the next write.
        await _chmod('700', f.parent.path, 'key.dirChmodFailed');
        await _chmod('600', f.path, 'key.chmodFailed');
        text = (await f.readAsString()).trim();
      }
    }
    t.done({'store': _store, 'found': text != null && text.isNotEmpty});
    if (text == null || text.isEmpty) return null;
    return VaultKey.parse(text);
  }

  /// [passphrase] is for the web build and ignored here: the system keeps the key.
  Future<void> write(VaultKey key, {String? passphrase}) async {
    final t = PerfTimer('key.write', warnMs: 1000);
    final text = await key.toText();
    if (isMobile) {
      await const FlutterSecureStorage().write(key: _name, value: text);
    } else {
      await _writePrivate(await _file(), text);
    }
    t.done({'store': _store});
  }

  /// Keeps the key of a wallet that is being set aside under its own slot, `<name>.aside.<stamp>` (`-2`, `-3`… when taken, like the
  /// database copy), and returns the slot. The slot is never read by the app yet (reopening a set-aside wallet is not built).
  Future<String> writeAside(String stamp, VaultKey key) async {
    final text = await key.toText();
    var slot = 'aside.$stamp';
    for (var n = 2; await _asideExists(slot); n++) {
      slot = 'aside.$stamp-$n';
    }
    if (isMobile) {
      await const FlutterSecureStorage().write(key: '${_name}_$slot', value: text);
    } else {
      await _writePrivate(await _file('wallet.key.$slot'), text);
    }
    return slot;
  }

  Future<bool> _asideExists(String slot) async =>
      isMobile ? await const FlutterSecureStorage().containsKey(key: '${_name}_$slot') : await (await _file('wallet.key.$slot')).exists();

  /// The "join pending" marker of Join another wallet (relay address and a fresh device id, no key): a private side file / secure
  /// storage entry next to the key, never in the database, so a start after a crash can finish the join.
  Future<void> writeJoinMarker(String text) async {
    if (isMobile) {
      await const FlutterSecureStorage().write(key: '${_name}_join_pending', value: text);
    } else {
      await _writePrivate(await _file('join.pending'), text);
    }
  }

  Future<String?> readJoinMarker() async {
    if (isMobile) return const FlutterSecureStorage().read(key: '${_name}_join_pending');
    final f = await _file('join.pending');
    return await f.exists() ? (await f.readAsString()).trim() : null;
  }

  Future<void> clearJoinMarker() async {
    if (isMobile) {
      await const FlutterSecureStorage().delete(key: '${_name}_join_pending');
    } else {
      final f = await _file('join.pending');
      if (await f.exists()) await f.delete();
    }
  }

  /// Takes back a slot made by [writeAside] whose set-aside did not happen.
  Future<void> removeAside(String slot) async {
    if (isMobile) {
      await const FlutterSecureStorage().delete(key: '${_name}_$slot');
    } else {
      final f = await _file('wallet.key.$slot');
      if (await f.exists()) await f.delete();
    }
  }

  /// The folder is private (0700); the text goes into a temp file there that is 0600 before any byte is written, then renamed
  /// over [f], so it is never readable by others and a crash never leaves half a file.
  Future<void> _writePrivate(File f, String text) async {
    await f.parent.create(recursive: true);
    await _chmod('700', f.parent.path, 'key.dirChmodFailed');
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.create();
      await _chmod('600', tmp.path, 'key.chmodFailed');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    } on Object {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // nothing more to do
      }
      rethrow;
    }
  }

  /// This install's device id (H6), kept next to the key (not in the database, so a copied database does not share it);
  /// null when none is stored yet. The value is never logged.
  Future<String?> readDeviceId() async {
    String? text;
    if (isMobile) {
      text = await const FlutterSecureStorage().read(key: _idName);
    } else {
      final f = await _file('device.id');
      if (await f.exists()) text = (await f.readAsString()).trim();
    }
    logEvent(_log, Level.FINE, 'deviceId.read', {'store': _store, 'found': text != null && text.isNotEmpty});
    return text == null || text.isEmpty ? null : text;
  }

  Future<void> writeDeviceId(String id) async {
    if (isMobile) {
      await const FlutterSecureStorage().write(key: _idName, value: id);
    } else {
      await _writePrivate(await _file('device.id'), id);
    }
    logEvent(_log, Level.INFO, 'deviceId.write', {'store': _store});
  }

  /// This install's relay device key (DK): a 32-byte Ed25519 seed, kept next to the device id (secure storage on phones, the
  /// 0600 file `device.key` on computers). Never synced, in no backup, never logged; null when none is stored or it is damaged.
  Future<List<int>?> readDeviceKey() async {
    String? text;
    if (isMobile) {
      text = await const FlutterSecureStorage().read(key: _devKeyName);
    } else {
      final f = await _file('device.key');
      if (await f.exists()) text = (await f.readAsString()).trim();
    }
    final bytes = decodeDeviceKey(text);
    logEvent(_log, Level.FINE, 'deviceKey.read', {'store': _store, 'found': bytes != null});
    return bytes;
  }

  Future<void> writeDeviceKey(List<int> seed) async {
    final text = encodeDeviceKey(seed);
    if (isMobile) {
      await const FlutterSecureStorage().write(key: _devKeyName, value: text);
    } else {
      await _writePrivate(await _file('device.key'), text);
    }
    logEvent(_log, Level.INFO, 'deviceKey.write', {'store': _store});
  }

  /// Deletes the stored key, device id and device key (used by "Forget this browser", which only the web build offers; kept so every build compiles).
  Future<void> forget() async {
    if (isMobile) {
      await const FlutterSecureStorage().delete(key: _name);
      await const FlutterSecureStorage().delete(key: _idName);
      await const FlutterSecureStorage().delete(key: _devKeyName);
      await const FlutterSecureStorage().delete(key: '${_name}_join_pending');
    } else {
      for (final n in ['wallet.key', 'device.id', 'device.key', 'join.pending']) {
        final f = await _file(n);
        if (await f.exists()) await f.delete();
      }
    }
    logEvent(_log, Level.INFO, 'key.forgotten', {'store': _store});
  }
}
