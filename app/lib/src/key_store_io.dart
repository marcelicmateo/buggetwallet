import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'platform.dart';

final _log = Logger('bw.key');

/// Keeps the wallet key on this device: the system keystore on phones,
/// a private file in the app's support folder on computers.
///
/// Logs where the key is kept and whether it was found, never the key or any part of it.
class KeyStore {
  static const _name = 'budget_wallet_key';
  static String get _store => isMobile ? 'secure' : 'file';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}wallet.key');
  }

  /// Only the browser build locks the key behind a passphrase.
  static bool get isLocked => false;

  /// Browser only.
  static Future<VaultKey> unlock(String passphrase) => throw UnsupportedError('Unlocking with a passphrase is for the web build.');

  static Future<VaultKey?> read() async {
    final t = PerfTimer('key.read', warnMs: 1000);
    String? text;
    if (isMobile) {
      text = await const FlutterSecureStorage().read(key: _name);
    } else {
      final f = await _file();
      if (await f.exists()) text = (await f.readAsString()).trim();
    }
    t.done({'store': _store, 'found': text != null && text.isNotEmpty});
    if (text == null || text.isEmpty) return null;
    return VaultKey.parse(text);
  }

  /// [passphrase] is for the web build and ignored here: the system keeps the key.
  static Future<void> write(VaultKey key, {String? passphrase}) async {
    final t = PerfTimer('key.write', warnMs: 1000);
    final text = await key.toText();
    if (isMobile) {
      await const FlutterSecureStorage().write(key: _name, value: text);
    } else {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(text, flush: true);
      if (!isWindows) {
        final r = await Process.run('chmod', ['600', f.path]);
        if (r.exitCode != 0) logEvent(_log, Level.WARNING, 'key.chmodFailed', {'exit': r.exitCode});
      }
    }
    t.done({'store': _store});
  }

  /// Deletes the stored key (used by "Forget this browser", which only the web build offers; kept so every build compiles).
  static Future<void> forget() async {
    if (isMobile) {
      await const FlutterSecureStorage().delete(key: _name);
    } else {
      final f = await _file();
      if (await f.exists()) await f.delete();
    }
    logEvent(_log, Level.INFO, 'key.forgotten', {'store': _store});
  }
}
