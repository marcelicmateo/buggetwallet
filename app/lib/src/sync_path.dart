// Sync folder path checks that touch the file system (dart:io lives here, not in the screens, so they build for the web).
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The folder suggested on a phone: Syncthing's usual place in shared storage.
const androidSyncFolder = '/storage/emulated/0/Documents/BudgetWallet';

/// Checks a typed or pasted sync folder: trims it, expands a leading `~` from HOME, wants an absolute path to a folder that
/// exists (a missing one is never created). Returns the path, or the `reason` it was refused: empty, relative or missing.
@visibleForTesting
({String? path, String? reason}) checkSyncPath(String raw, {String? home}) {
  var p = raw.trim();
  if (p.isEmpty) return (path: null, reason: 'empty');
  if (p == '~' || p.startsWith('~/')) {
    final h = home ?? Platform.environment['HOME'];
    if (h != null && h.isNotEmpty) p = h + p.substring(1);
  }
  if (!p.startsWith('/') && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) return (path: null, reason: 'relative');
  if (!Directory(p).existsSync()) return (path: null, reason: 'missing');
  return (path: p, reason: null);
}

/// Creates the suggested phone folder (it may not exist before Syncthing makes it). Returns false if that failed.
bool createSuggestedFolder() {
  try {
    Directory(androidSyncFolder).createSync(recursive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}
