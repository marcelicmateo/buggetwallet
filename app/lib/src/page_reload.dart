// Reloads the browser page (web); nothing on phones and computers, where the app is never "in use elsewhere".
export 'page_reload_io.dart' if (dart.library.js_interop) 'page_reload_web.dart';
