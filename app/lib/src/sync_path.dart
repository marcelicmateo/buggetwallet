// Folder work for the sync folder: checks, creating folders, the logs file. dart:io lives in sync_path_io.dart, not in the screens
// or the controller, so the app builds for the web (sync_path_web.dart has the same names and does nothing: no sync folder there).
export 'sync_path_base.dart';
export 'sync_path_io.dart' if (dart.library.js_interop) 'sync_path_web.dart';
