// HTTP client for the relay (docs/context/RELAY_PROTOCOL.md, v2: signed requests). `package:http` and
// `package:cryptography` only, so it runs on the VM and the web.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'logs.dart';
import 'sync_engine.dart';
import 'vault.dart';

final _log = Logger('bw.relay');

/// The relay API version this build speaks.
const relayApi = 2;

/// HKDF info of the wallet id and of the Ed25519 signing seed (RELAY_PROTOCOL.md "Identity").
const relayIdInfo = 'bw-relay-id-v1';
const relaySignInfo = 'bw-relay-sign-v1';

class _Identity {
  final String wid;
  final SimpleKeyPair keyPair;
  final String pub;
  _Identity(this.wid, this.keyPair, this.pub);
}

/// [SyncTransport] over HTTP to a relay at [base] (e.g. `http://homeserver:8787`). The wallet id and the Ed25519 key
/// that signs every request are derived from [key] ([deriveKey]); the key itself never leaves the device, and the
/// relay only ever learns the public key.
class RelayTransport implements SyncTransport {
  final Uri base;
  final VaultKey key;
  final http.Client _client;
  final Duration timeout;
  final DateTime Function() _now;

  /// Added to this device's clock for `X-BW-Time`: set from the relay's `Date` header when the relay answers 401
  /// `clock` (device-local, in memory).
  int clockOffsetMs;

  RelayTransport(this.base, this.key,
      {http.Client? client, this.timeout = const Duration(seconds: 30), DateTime Function()? now, this.clockOffsetMs = 0})
      : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  static final _ed25519 = Ed25519();

  Future<_Identity>? _identity;

  Future<_Identity> get _id => _identity ??= () async {
        final id = await deriveKey(key, relayIdInfo, length: 16);
        final seed = await deriveKey(key, relaySignInfo);
        final pair = await _ed25519.newKeyPairFromSeed(seed);
        final pub = (await pair.extractPublicKey()).bytes;
        return _Identity(id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), pair, _b64(pub));
      }();

  /// (wallet id, public key): `wid` = lowercase hex of HKDF(`bw-relay-id-v1`, 16 bytes), the public key = base64url
  /// without padding of the Ed25519 key from the seed HKDF(`bw-relay-sign-v1`, 32 bytes), as `X-BW-Pub` sends it.
  Future<(String, String)> get ids async {
    final i = await _id;
    return (i.wid, i.pub);
  }

  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  static Uri _url(Uri base, String path) {
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(path: '$prefix/$path', query: null, fragment: null);
  }

  /// Checks that a relay answers at [base] and speaks this build's API (`GET /v2/health`, not signed). A 404 there is
  /// asked again at `/v1/health` to tell an older relay apart ([TransportFailure.olderApi]). Throws
  /// [TransportException].
  static Future<void> health(Uri base, {http.Client? client, Duration timeout = const Duration(seconds: 10)}) async {
    final c = client ?? http.Client();
    try {
      final r = await _send(() => c.get(_url(base, 'v$relayApi/health')), timeout, 'health');
      if (r.statusCode == 404) {
        final old = await _send(() => c.get(_url(base, 'v1/health')), timeout, 'health');
        if (old.statusCode == 200) _api(old.body, 'health');
      }
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
      401 when _isClock(r) => TransportFailure.other,
      401 || 403 => TransportFailure.refused,
      410 => TransportFailure.gone,
      404 => TransportFailure.missing,
      409 => TransportFailure.conflict,
      400 || 422 => TransportFailure.rejected,
      413 || 507 => TransportFailure.full,
      _ => TransportFailure.other,
    };
    logEvent(_log, Level.WARNING, 'relay.failed', {'kind': kind, 'status': s, 'failure': failure.name});
    throw TransportException(failure, _isClock(r) ? 'clock' : 'status $s');
  }

  /// A 401 `{"error":"clock"}`: the signature time is outside the relay's window.
  static bool _isClock(http.Response r) {
    if (r.statusCode != 401) return false;
    try {
      final j = jsonDecode(r.body);
      return j is Map && j['error'] == 'clock';
    } on FormatException {
      return false;
    }
  }

  /// The JSON object in [body]; an `api` above [relayApi] is [TransportFailure.newerApi], below it
  /// [TransportFailure.olderApi].
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
    if (api < relayApi) {
      logEvent(_log, Level.WARNING, 'relay.olderApi', {'api': api});
      throw const TransportException(TransportFailure.olderApi, 'older api');
    }
    return Map<String, Object?>.from(j);
  }

  /// The string a v2 request signs (RELAY_PROTOCOL.md "Signed requests").
  static String signedText(String method, String path, String covers, String bodyHash, String time) =>
      'bw-relay-v2\n$method\n$path\n$covers\n$bodyHash\n$time';

  /// The largest clock offset taken from a relay's `Date` (RELAY_PROTOCOL.md "Signed requests"); a bigger one fails the call.
  static const maxClockOffset = Duration(hours: 24);

  Future<http.Response> _req(String method, String path, String kind,
      {List<int> body = const [], Map<String, String> headers = const {}, bool withPub = false}) async {
    final id = await _id;
    final signedPath = '/v$relayApi/w/${id.wid}/$path';
    final hash = (await Sha256().hash(body)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    Future<http.Response> attempt() async {
      final time = '${_now().millisecondsSinceEpoch + clockOffsetMs}';
      final sig =
          await _ed25519.sign(utf8.encode(signedText(method, signedPath, headers['X-BW-Covers'] ?? '', hash, time)), keyPair: id.keyPair);
      final req = http.Request(method, _url(base, signedPath.substring(1)))
        ..headers.addAll({...headers, 'X-BW-Time': time, 'X-BW-Sig': _b64(sig.bytes), if (withPub) 'X-BW-Pub': id.pub});
      if (method != 'GET') req.bodyBytes = body;
      return _send(() async => http.Response.fromStream(await _client.send(req)), timeout, kind);
    }

    var r = await attempt();
    if (_isClock(r)) {
      final relayTime = parseHttpDate(r.headers['date'] ?? '');
      if (relayTime != null) {
        final offset = relayTime.millisecondsSinceEpoch - _now().millisecondsSinceEpoch;
        // A `Date` over plain HTTP can be faked: an offset beyond a day would let a captured request be signed far
        // ahead and replayed later. Refuse it, keep the old offset, and do not retry.
        if (offset.abs() > maxClockOffset.inMilliseconds) {
          logEvent(_log, Level.WARNING, 'relay.clockSkew', {'kind': kind});
          throw const TransportException(TransportFailure.clockSkew, 'clock differs by more than a day');
        }
        clockOffsetMs = offset;
        // Only that the offset changed, never the clocks themselves.
        logEvent(_log, Level.INFO, 'relay.clockOffset', {'kind': kind, 'minutes': clockOffsetMs ~/ 60000});
        r = await attempt();
      }
    }
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
    // seq 1 may create the wallet on the relay: it carries the public key (trust on first use).
    await _req('PUT', 'd/$device/$seq', 'put', body: bytes, headers: _octets, withPub: seq == 1);
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

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
final _httpDate = RegExp(r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$');

/// An HTTP `Date` header (IMF-fixdate, `Thu, 22 Oct 2026 10:00:00 GMT`) as UTC, or null (web-safe: no dart:io).
DateTime? parseHttpDate(String s) {
  final m = _httpDate.firstMatch(s.trim());
  if (m == null) return null;
  final month = _months.indexOf(m.group(2)!) + 1;
  if (month == 0) return null;
  int g(int i) => int.parse(m.group(i)!);
  final (day, hour, minute, second) = (g(1), g(4), g(5), g(6));
  if (day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null;
  return DateTime.utc(g(3), month, day, hour, minute, second);
}
