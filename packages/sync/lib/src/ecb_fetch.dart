/// UX-FX: the ECB download. Core never fetches (`WalletRepo.ecbFetchPlan` says which file and when); this is the one
/// HTTP GET, on the same `package:http` stack as the relay transport. Web-safe (no dart:io).
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:wallet_core/wallet_core.dart';

final _log = Logger('bw.fx');

/// The most bytes [fetchEcbFile] reads (the history zip is well under 1 MB, the 90-day XML far less).
const maxEcbDownloadBytes = 8 * 1024 * 1024;

/// Why [fetchEcbFile] gave up.
enum EcbFetchFailure { unreachable, timeout, status, tooLarge }

/// [fetchEcbFile] failed: [message] is short and plain, for the owner (never an address or path).
class EcbFetchException implements Exception {
  final EcbFetchFailure reason;
  final String message;
  const EcbFetchException(this.reason, this.message);

  @override
  String toString() => message;
}

/// Downloads the ECB file [f] (`EcbFile.url`: the ECB's own HTTPS address, nothing else) and returns its bytes for
/// `WalletRepo.importEcbHistory`. A plain GET: no query string and no header of ours (nothing that names the wallet or
/// the device). Stops past [maxEcbDownloadBytes] ([EcbFetchFailure.tooLarge]); a status other than 200
/// ([EcbFetchFailure.status]), no connection ([EcbFetchFailure.unreachable]) or more than [timeout] for the whole
/// download ([EcbFetchFailure.timeout]) is an [EcbFetchException]. Logs `fx.ecbFetch` with the file, outcome, status,
/// bytes and ms only. The app's order: `ecbFetchPlan` → `noteEcbAttempt` → [fetchEcbFile] → `importEcbHistory`.
Future<List<int>> fetchEcbFile(EcbFile f, {http.Client? client, Duration timeout = const Duration(seconds: 30)}) async {
  final uri = Uri.parse(f.url);
  if (uri.scheme != 'https' || uri.hasQuery) throw ArgumentError('Not the ECB address.');
  final c = client ?? http.Client();
  final sw = Stopwatch()..start();
  void log(String outcome, {int? status, int bytes = 0}) => logEvent(_log, outcome == 'ok' ? Level.INFO : Level.WARNING, 'fx.ecbFetch',
      {'file': f.name, 'outcome': outcome, if (status != null) 'status': status, 'bytes': bytes, 'ms': sw.elapsedMilliseconds});
  Future<List<int>> run() async {
    final http.StreamedResponse r;
    try {
      r = await c.send(http.Request('GET', uri));
    } on TimeoutException {
      rethrow;
    } on Object catch (e) {
      // Only the type: a client error's text names the address.
      logEvent(_log, Level.WARNING, 'fx.ecbFetch', {'file': f.name, 'outcome': 'unreachable', 'error': e.runtimeType.toString()});
      throw const EcbFetchException(EcbFetchFailure.unreachable, 'The exchange rates could not be downloaded: no connection.');
    }
    if (r.statusCode != 200) {
      unawaited(r.stream.drain<void>().catchError((_) {}));
      log('status', status: r.statusCode);
      throw const EcbFetchException(EcbFetchFailure.status, 'The ECB did not send the exchange rates. Try again later.');
    }
    if ((r.contentLength ?? 0) > maxEcbDownloadBytes) {
      unawaited(r.stream.drain<void>().catchError((_) {}));
      log('tooLarge', status: 200, bytes: r.contentLength!);
      throw const EcbFetchException(EcbFetchFailure.tooLarge, 'The exchange rates download is too large.');
    }
    final out = <int>[];
    try {
      await for (final chunk in r.stream) {
        out.addAll(chunk);
        if (out.length > maxEcbDownloadBytes) {
          log('tooLarge', status: 200, bytes: out.length);
          throw const EcbFetchException(EcbFetchFailure.tooLarge, 'The exchange rates download is too large.');
        }
      }
    } on EcbFetchException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } on Object catch (e) {
      logEvent(_log, Level.WARNING, 'fx.ecbFetch', {'file': f.name, 'outcome': 'unreachable', 'error': e.runtimeType.toString()});
      throw const EcbFetchException(EcbFetchFailure.unreachable, 'The exchange rates download was cut off.');
    }
    log('ok', status: 200, bytes: out.length);
    return out;
  }

  try {
    return await run().timeout(timeout);
  } on TimeoutException {
    log('timeout');
    throw const EcbFetchException(EcbFetchFailure.timeout, 'The exchange rates download took too long. Try again later.');
  } finally {
    if (client == null) c.close();
  }
}
