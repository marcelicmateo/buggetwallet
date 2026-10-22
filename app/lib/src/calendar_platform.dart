// The calendars of this platform: the Android plugin (calendar_source_native.dart) on phones, nothing in the browser, so the plugin
// is never loaded on the web. Same pairing as nudge_platform.dart.
export 'calendar_source_native.dart' if (dart.library.js_interop) 'calendar_source_web.dart' show defaultCalendarSource;
