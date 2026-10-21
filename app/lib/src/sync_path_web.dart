// The browser has no sync folder and no file system: the same names as sync_path_io.dart, refusing or throwing UnsupportedError.
// The web screens never call them (Plan hides the Sync panel).
import 'dart:typed_data';

({String? path, String? reason}) checkSyncPath(String raw, {String? home}) => (path: null, reason: 'unsupported');

bool createSuggestedFolder() => false;

Future<void> createFolder(String path) => throw UnsupportedError('No folders in the browser.');

Future<String> appSyncFolder() => throw UnsupportedError('No folders in the browser.');

Future<({String path, bool inSyncFolder})> saveDiagnosticsFile(String? syncFolder, String name, Uint8List bytes) =>
    throw UnsupportedError('No folders in the browser.');
