import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import 'platform.dart';

final _log = Logger('bw.storage');

/// Android "All files access", needed to read and write a Syncthing folder in shared storage.
class StorageAccess {
  static const _ch = MethodChannel('budget_wallet/storage');

  static Future<bool> granted() async {
    if (!isAndroid) return true;
    final ok = await _ch.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    logEvent(_log, Level.FINE, 'storage.granted', {'granted': ok});
    return ok;
  }

  /// Opens the system settings page where the user allows it.
  static Future<void> request() async {
    if (!isAndroid) return;
    logEvent(_log, Level.INFO, 'storage.request');
    await _ch.invokeMethod<void>('requestAllFilesAccess');
  }
}
