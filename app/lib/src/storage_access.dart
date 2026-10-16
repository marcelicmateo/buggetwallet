import 'dart:io';

import 'package:flutter/services.dart';

/// Android "All files access", needed to read and write a Syncthing folder in shared storage.
class StorageAccess {
  static const _ch = MethodChannel('budget_wallet/storage');

  static Future<bool> granted() async {
    if (!Platform.isAndroid) return true;
    return await _ch.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  }

  /// Opens the system settings page where the user allows it.
  static Future<void> request() async {
    if (Platform.isAndroid) await _ch.invokeMethod<void>('requestAllFilesAccess');
  }
}
