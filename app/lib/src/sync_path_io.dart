// Sync folder path checks that touch the file system (dart:io lives here, not in the screens, so they build for the web).
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'sync_path_base.dart';

/// Checks a typed or pasted sync folder: trims it, expands a leading `~` from HOME, wants an absolute path to a folder that
/// exists (a missing one is never created). Returns the path, or the `reason` it was refused: empty, relative or missing.
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

/// Makes the folder [path] (and its parents).
Future<void> createFolder(String path) => Directory(path).create(recursive: true);

/// Default folder on iPhone: the app's Documents folder, visible in the Files app.
Future<String> appSyncFolder() async {
  final docs = await getApplicationDocumentsDirectory();
  final d = Directory('${docs.path}${Platform.pathSeparator}BudgetWalletSync');
  await d.create(recursive: true);
  return d.path;
}

/// Writes [bytes] as [name] into `<syncFolder>/diagnostics/` (or the app documents folder when there is no sync folder) and
/// returns the path. Also tells which of the two it used.
Future<({String path, bool inSyncFolder})> saveDiagnosticsFile(String? syncFolder, String name, Uint8List bytes) async {
  final sep = Platform.pathSeparator;
  final base = syncFolder ?? (await getApplicationDocumentsDirectory()).path;
  final dir = Directory('$base${sep}diagnostics');
  await dir.create(recursive: true);
  final f = File('${dir.path}$sep$name');
  await f.writeAsBytes(bytes, flush: true);
  return (path: f.path, inSyncFolder: syncFolder != null);
}
