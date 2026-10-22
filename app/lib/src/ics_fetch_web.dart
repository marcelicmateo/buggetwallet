import 'ics_fetch.dart';

/// Links are not read in the browser (a page cannot fetch other sites); import the `.ics` file instead.
const icsLinksSupported = false;

Future<String> fetchIcs(Uri url) async => throw const IcsFetchException('Links need the app. Import the .ics file instead.');
