// Web twin of `platform_error_io.dart`: the browser has no dart:io errors.

/// Always null on the web (no dart:io error types).
String? describePlatformError(Object e) => null;
