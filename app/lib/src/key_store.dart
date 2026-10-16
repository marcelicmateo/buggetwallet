import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

final _log = Logger('bw.key');

/// Keeps the wallet key on this device: the system keystore on phones,
/// a private file in the app's support folder on computers.
///
/// Logs where the key is kept and whether it was found, never the key or any part of it.
class KeyStore {
  static const _name = 'budget_wallet_key';
  static bool get _mobile => Platform.isAndroid || Platform.isIOS;
  static String get _store => _mobile ? 'secure' : 'file';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}wallet.key');
  }

  static Future<VaultKey?> read() async {
    final t = PerfTimer('key.read', warnMs: 1000);
    String? text;
    if (_mobile) {
      text = await const FlutterSecureStorage().read(key: _name);
    } else {
      final f = await _file();
      if (await f.exists()) text = (await f.readAsString()).trim();
    }
    t.done({'store': _store, 'found': text != null && text.isNotEmpty});
    if (text == null || text.isEmpty) return null;
    return VaultKey.parse(text);
  }

  static Future<void> write(VaultKey key) async {
    final t = PerfTimer('key.write', warnMs: 1000);
    final text = await key.toText();
    if (_mobile) {
      await const FlutterSecureStorage().write(key: _name, value: text);
    } else {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(text, flush: true);
      if (!Platform.isWindows) {
        final r = await Process.run('chmod', ['600', f.path]);
        if (r.exitCode != 0) logEvent(_log, Level.WARNING, 'key.chmodFailed', {'exit': r.exitCode});
      }
    }
    t.done({'store': _store});
  }
}
