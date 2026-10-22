import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ics_fetch.dart';

/// True where links can be fetched at all.
const icsLinksSupported = true;

const _redirects = {301, 302, 303, 307, 308};

/// Downloads the text of [url] (http or https; a `webcal://` link is read as https). One overall [timeout] covers the whole
/// download, so a server that sends a byte now and then cannot hold it open. Redirects are followed by hand (at most
/// [icsMaxRedirects], never from https to http). Throws [IcsFetchException] with a plain message; the link itself is never put
/// in a message or a log.
Future<String> fetchIcs(Uri url, {Duration timeout = icsFetchTimeout}) async {
  final u = url.scheme == 'webcal' ? url.replace(scheme: 'https') : url;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await _download(client, u).timeout(timeout);
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

Future<String> _download(HttpClient client, Uri start) async {
  var current = start;
  for (var hop = 0; hop <= icsMaxRedirects; hop++) {
    final req = await client.getUrl(current);
    req.followRedirects = false;
    final res = await req.close();
    if (_redirects.contains(res.statusCode)) {
      final to = res.headers.value(HttpHeaders.locationHeader);
      if (to == null) throw const IcsFetchException("The link moved but didn't say where.");
      current = resolveRedirect(current, to);
      await res.drain<void>();
      continue;
    }
    if (res.statusCode != 200) throw IcsFetchException('The link answered with an error (${res.statusCode}).');
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
      if (bytes.length > icsMaxBytes) throw const IcsFetchException('That calendar is bigger than 2 MB.');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
  throw const IcsFetchException('The link redirects too many times.');
}
