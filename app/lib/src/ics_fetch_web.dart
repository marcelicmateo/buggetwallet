import 'ics_fetch.dart';

/// Links are not read in the browser (a page cannot fetch other sites); import the `.ics` file instead.
const icsLinksSupported = false;

/// [timeout] is the same overall limit as on the phone; nothing is fetched here, so it never runs.
Future<String> fetchIcs(Uri url, {Duration timeout = icsFetchTimeout}) async =>
    throw const IcsFetchException('Links need the app. Import the .ics file instead.');
