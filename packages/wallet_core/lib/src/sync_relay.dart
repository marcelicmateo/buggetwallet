// HTTP client for the relay (docs/context/RELAY_PROTOCOL.md). `package:http` only, so it runs on the VM and the web.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'logs.dart';
import 'sync_engine.dart';
import 'vault.dart';

final _log = Logger('bw.relay');

/// The relay API version this build speaks.
const relayApi = 1;

/// [SyncTransport] over HTTP to a relay at [base] (e.g. `http://homeserver:8787`). The wallet id and the bearer token
/// are derived from [key] ([deriveKey]); the key itself never leaves the device.
class RelayTransport implements SyncTransport {
  final Uri base;
  final VaultKey key;
  final http.Client _client;
  final Duration timeout;
  RelayTransport(this.base, this.key, {http.Client? client, this.timeout = const Duration(seconds: 30)})
      : _client = client ?? http.Client();

  Future<(String, String)>? _ids;

  /// (wallet id, token): `wid` = lowercase hex of HKDF(`bw-relay-id-v1`, 16 bytes), `token` = base64url without padding
  /// of HKDF(`bw-relay-auth-v1`, 32 bytes).
  Future<(String, String)> get ids => _ids ??= () async {
        final id = await deriveKey(key, 'bw-relay-id-v1', length: 16);
        final auth = await deriveKey(key, 'bw-relay-auth-v1');
        return (id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), base64Url.encode(auth).replaceAll('=', ''));
      }();

  static Uri _url(Uri base, String path) {
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(path: '$prefix/$path', query: null, fragment: null);
  }

  /// Checks that a relay answers at [base] and speaks this build's API (`GET /v1/health`). Throws [TransportException].
  static Future<void> health(Uri base, {http.Client? client, Duration timeout = const Duration(seconds: 10)}) async {
    final c = client ?? http.Client();
    try {
      final r = await _send(() => c.get(_url(base, 'v1/health')), timeout, 'health');
      _check(r, 'health');
      _api(r.body, 'health');
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<http.Response> _send(Future<http.Response> Function() call, Duration timeout, String kind) async {
    try {
      return await call().timeout(timeout);
    } on TimeoutException {
      logEvent(_log, Level.WARNING, 'relay.unreachable', {'kind': kind, 'timeout': true});
      throw const TransportException(TransportFailure.unreachable, 'timeout');
    } on TransportException {
      rethrow;
    } on Object catch (e) {
      // Only the error's type: a client error's text names the address.
      logEvent(_log, Level.WARNING, 'relay.unreachable', {'kind': kind, 'error': e.runtimeType.toString()});
      throw const TransportException(TransportFailure.unreachable, 'no connection');
    }
  }

  /// Maps a non-2xx status to a [TransportException].
  static void _check(http.Response r, String kind) {
    final s = r.statusCode;
    logEvent(_log, Level.FINE, 'relay.response', {'kind': kind, 'status': s, 'bytes': r.bodyBytes.length});
    if (s >= 200 && s < 300) return;
    final failure = switch (s) {
      401 || 403 => TransportFailure.refused,
      410 => TransportFailure.gone,
      404 => TransportFailure.missing,
      409 => TransportFailure.conflict,
      400 || 422 => TransportFailure.rejected,
      413 || 507 => TransportFailure.full,
      _ => TransportFailure.other,
    };
    logEvent(_log, Level.WARNING, 'relay.failed', {'kind': kind, 'status': s, 'failure': failure.name});
    throw TransportException(failure, 'status $s');
  }

  /// The JSON object in [body]; an `api` above [relayApi] is [TransportFailure.newerApi].
  static Map<String, Object?> _api(String body, String kind) {
    final Object? j;
    try {
      j = jsonDecode(body);
    } on FormatException catch (e, st) {
      logError(_log, 'relay.badJson', e, st, fields: {'kind': kind});
      throw const TransportException(TransportFailure.other, 'not JSON');
    }
    if (j is! Map) throw const TransportException(TransportFailure.other, 'not an object');
    final api = j['api'];
    if (api is! int) throw const TransportException(TransportFailure.other, 'no api');
    if (api > relayApi) {
      logEvent(_log, Level.WARNING, 'relay.newerApi', {'api': api});
      throw const TransportException(TransportFailure.newerApi, 'newer api');
    }
    return Map<String, Object?>.from(j);
  }

  Future<http.Response> _req(String method, String path, String kind, {List<int>? body, Map<String, String> headers = const {}}) async {
    final (wid, token) = await ids;
    final req = http.Request(method, _url(base, 'v1/w/$wid/$path'))..headers.addAll({'Authorization': 'Bearer $token', ...headers});
    if (body != null) req.bodyBytes = body;
    final r = await _send(() async => http.Response.fromStream(await _client.send(req)), timeout, kind);
    _check(r, kind);
    return r;
  }

  static const _octets = {'Content-Type': 'application/octet-stream'};

  @override
  Future<RelayState> state() async {
    final http.Response r;
    try {
      r = await _req('GET', 'state', 'state');
    } on TransportException catch (e) {
      if (e.failure == TransportFailure.missing) return RelayState.empty; // a wallet the relay does not know yet
      rethrow;
    }
    final j = _api(r.body, 'state');
    try {
      return RelayState.fromJson(j);
    } on FormatException catch (e, st) {
      logError(_log, 'relay.badState', e, st);
      throw const TransportException(TransportFailure.other, 'bad state');
    }
  }

  @override
  Future<void> put(String device, int seq, List<int> bytes) async {
    await _req('PUT', 'd/$device/$seq', 'put', body: bytes, headers: _octets);
  }

  @override
  Future<List<int>> get(String device, int seq) async => (await _req('GET', 'd/$device/$seq', 'get')).bodyBytes;

  @override
  Future<void> ack(String device, Map<String, int> cursors) async {
    await _req('PUT', 'ack/$device', 'ack', body: utf8.encode(jsonEncode(cursors)), headers: {'Content-Type': 'application/json'});
  }

  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) async {
    await _req('PUT', 'snapshot/$id', 'putSnapshot', body: bytes, headers: {..._octets, 'X-BW-Covers': jsonEncode(covers)});
  }

  @override
  Future<List<int>> getSnapshot(String id) async => Uint8List.fromList((await _req('GET', 'snapshot/$id', 'getSnapshot')).bodyBytes);

  /// Closes the HTTP client.
  void close() => _client.close();
}
