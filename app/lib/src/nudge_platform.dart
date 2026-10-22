// The reminders of this platform: the Android plugin (nudge_platform_io.dart) on phones, nothing in the browser (nudge_platform_web.dart),
// so the plugin and dart:io are never loaded on the web.
export 'nudge_platform_io.dart' if (dart.library.js_interop) 'nudge_platform_web.dart' show defaultNudgePlatform;
