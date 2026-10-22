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

/// The longest a whole download may take (connect, answer, every redirect and the body together).
const icsFetchTimeout = Duration(seconds: 60);

/// Most redirects followed for one link.
const icsMaxRedirects = 5;

/// Where a redirect to [location] from [from] goes. Throws [IcsFetchException] for anything that is not http(s) and for a
/// step from https down to http (the calendar would then travel unencrypted).
Uri resolveRedirect(Uri from, String location) {
  final to = from.resolve(location);
  if (to.scheme != 'http' && to.scheme != 'https') throw const IcsFetchException('The link sends you somewhere that is not a web address.');
  if (from.scheme == 'https' && to.scheme == 'http') {
    throw const IcsFetchException('The link redirects to an unencrypted address, so it was not followed.');
  }
  return to;
}
