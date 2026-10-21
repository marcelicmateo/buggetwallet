// dart:io error types for `describeError` (logs.dart). The web twin is `platform_error_web.dart`.
import 'dart:io';

/// Text for a dart:io error without its path, or null for anything else.
String? describePlatformError(Object e) {
  if (e is FileSystemException) {
    // The path can name a bank export or contain the user's name.
    return '${e.runtimeType}: ${e.message}${e.osError != null ? ' (${e.osError})' : ''}';
  }
  return null;
}
