// Fetching an `.ics` link: dart:io on native builds, not available in the browser (a page cannot read other sites).
export 'ics_fetch_io.dart' if (dart.library.js_interop) 'ics_fetch_web.dart';

/// Biggest calendar file we keep (a file or a link), in bytes.
const icsMaxBytes = 2 * 1024 * 1024;

/// A calendar link that could not be read. [message] is plain text for the owner and never contains the link.
class IcsFetchException implements Exception {
  final String message;
  const IcsFetchException(this.message);
  @override
  String toString() => 'IcsFetchException';
}
