import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

/// Keeps the wallet key on this device: the system keystore on phones,
/// a private file in the app's support folder on computers.
class KeyStore {
  static const _name = 'budget_wallet_key';
  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}wallet.key');
  }

  static Future<VaultKey?> read() async {
    String? text;
    if (_mobile) {
      text = await const FlutterSecureStorage().read(key: _name);
    } else {
      final f = await _file();
      if (await f.exists()) text = (await f.readAsString()).trim();
    }
    if (text == null || text.isEmpty) return null;
    return VaultKey.parse(text);
  }

  static Future<void> write(VaultKey key) async {
    final text = await key.toText();
    if (_mobile) {
      await const FlutterSecureStorage().write(key: _name, value: text);
    } else {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(text, flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', f.path]);
      }
    }
  }
}
