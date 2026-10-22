import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ics_fetch.dart';

/// True where links can be fetched at all.
const icsLinksSupported = true;

/// Downloads the text of [url] (http or https; a `webcal://` link is read as https). Throws [IcsFetchException] with a plain
/// message; the link itself is never put in a message or a log.
Future<String> fetchIcs(Uri url) async {
  final u = url.scheme == 'webcal' ? url.replace(scheme: 'https') : url;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(u).timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw IcsFetchException('The link answered with an error (${res.statusCode}).');
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > icsMaxBytes) throw const IcsFetchException('That calendar is bigger than 2 MB.');
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on IcsFetchException {
    rethrow;
  } on TimeoutException {
    throw const IcsFetchException('The link took too long to answer.');
  } on SocketException {
    throw const IcsFetchException("Couldn't reach the link. Check the network.");
  } on HandshakeException {
    throw const IcsFetchException("Couldn't open a secure connection to the link.");
  } on HttpException {
    throw const IcsFetchException("Couldn't read the link.");
  } finally {
    client.close(force: true);
  }
}
