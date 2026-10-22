// The bill inputs of this platform: the Android plugins (bill_inputs_io.dart) on phones, nothing in the browser
// (bill_inputs_web.dart), so mobile_scanner, ML Kit and the share plugin are never loaded on the web. Same pairing as
// calendar_platform.dart.
export 'bill_inputs_io.dart' if (dart.library.js_interop) 'bill_inputs_web.dart' show defaultBillInputs;
