// Where AppLog keeps its lines: rotating files in the app folder (log_backend_io.dart) or a bounded buffer in memory in the browser
// (log_backend_web.dart, `dart.library.js_interop`). Both have the same members; AppLog does not know which one it has.
export 'log_backend_io.dart' if (dart.library.js_interop) 'log_backend_web.dart' show LogBackend, memoryFacts, nativeInfo;
export 'log_stats.dart';
