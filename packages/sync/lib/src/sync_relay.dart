// HTTP client for the relay (docs/context/RELAY_PROTOCOL.md, api 5 (api 4 and 3 relays too): requests signed with the host, paths under /v2/). `package:http` and
// `package:cryptography` only, so it runs on the VM and the web.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:wallet_core/wallet_core.dart';

import 'sync_engine.dart';

final _log = Logger('bw.relay');

/// The relay API version this build speaks (`api` in health and state). The URL paths stay under `/v2/`. 5: device keys.
const relayApi = 5;

/// The oldest relay API this build still syncs with: an api-3 relay (signed text `bw-relay-v3`, no declared blob sets,
/// RELAY_PROTOCOL.md "Versions").
const relayMinApi = 3;

/// HKDF info of the wallet id and of the Ed25519 signing seed (RELAY_PROTOCOL.md "Identity").
const relayIdInfo = 'bw-relay-id-v1';
const relaySignInfo = 'bw-relay-sign-v1';

class _Identity {
  final String wid;
  final SimpleKeyPair keyPair;
  final String pub;

  /// The device key (api 5) and its `devpub`, or null without one.
  final SimpleKeyPair? devPair;
  final String? devpub;
  _Identity(this.wid, this.keyPair, this.pub, this.devPair, this.devpub);
}

/// What `PUT enrol` answered: enrolled (201 or 200), or waiting for approval on a locked wallet (202).
enum EnrolResult { enrolled, pending }

/// A device key's fingerprint (RELAY_PROTOCOL.md "Identity"): the first 8 base32 characters (`A-Z2-7`) of SHA-256 of
/// the public key bytes [pub], as `ABCD-EFGH`. People compare it to approve a device.
String deviceFingerprint(List<int> pub) {
  final h = sha256Hex(pub);
  final bits = int.parse(h.substring(0, 10), radix: 16); // 40 bits: exact on the web too
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final out = StringBuffer();
  for (var i = 7; i >= 0; i--) {
    out.write(alphabet[(bits ~/ pow(32, i)) % 32]);
    if (i == 4) out.write('-');
  }
  return out.toString();
}

/// A new random device key seed (32 bytes, Ed25519; RELAY_PROTOCOL.md "Identity"): made once per install and kept
/// next to the wallet key; never synced, never in backups.
List<int> newDeviceKey() {
  final r = Random.secure();
  return List<int>.generate(32, (_) => r.nextInt(256));
}

/// [SyncTransport] over HTTP to a relay at [base] (e.g. `http://homeserver:8787`). The wallet id and the Ed25519 key
/// that signs every request are derived from [key] ([deriveKey]); the key itself never leaves the device, and the
/// relay only ever learns the public key.
class RelayTransport implements SyncTransport, DeviceKeyTransport {
  final Uri base;
  final VaultKey key;
  final http.Client _client;
  final Duration timeout;
  final DateTime Function() _now;

  /// Added to this device's clock for `X-BW-Time`: set from the relay's `Date` header when the relay answers 401
  /// `clock` (device-local, in memory). It belongs to this transport only: the app keeps one [RelayTransport] per relay
  /// address for the session, so every engine run (and the blob store) shares it; a new transport starts at 0 and
  /// learns it again with one extra round trip. Never persisted.
  int clockOffsetMs;

  /// The relay's create token (`--create-token`), sent as `X-BW-Create-Token` on every `PUT d/<device>/1` (the request
  /// that can create a wallet). Device-local, never synced or logged. A relay that needs it and gets none or a wrong one
  /// answers 403 `createToken` ([TransportFailure.createToken]).
  final String? createToken;

  /// This install's device key seed (api 5, 32 bytes, [newDeviceKey]): every request is signed with it (`X-BW-Dev`,
  /// `bw-relay-v5`), and the wallet key only countersigns creation and enrolment. Null = sign with the wallet key as
  /// an api-4 app does (tests; an install without a device key).
  final List<int>? deviceKey;

  /// This install's device id, sent with an enrolment (`deviceId`) so other devices can name a pending key.
  final String? deviceId;

  /// The api whose signed text this transport uses: 5 with a [deviceKey] (else 4), lowered to 4 or 3 once an older relay
  /// was found (a 401 that is not `clock`, `revoked` or `unenrolled`, then `/v2/health` says so). In memory, per
  /// transport.
  int signApi;

  /// The lowest relay api this transport accepts (RELAY_PROTOCOL.md "Versions", no downgrade): once a state said 5 it
  /// is raised to 5 and [onMinApi] is told, so the app can keep it per relay address (device-local) and pass it on the
  /// next transport. A 401 whose health then names an older api is [TransportFailure.olderApi], never a fallback to the
  /// wallet key.
  int minApi;

  /// Called once when [minApi] rises (with the new value and the relay's instance id, if it sent one).
  final void Function(int minApi, String? instance)? onMinApi;

  RelayTransport(this.base, this.key,
      {http.Client? client,
      this.timeout = const Duration(seconds: 30),
      DateTime Function()? now,
      this.clockOffsetMs = 0,
      this.createToken,
      this.deviceKey,
      this.deviceId,
      this.minApi = relayMinApi,
      this.onMinApi})
      : _client = client ?? http.Client(),
        _now = now ?? DateTime.now,
        signApi = deviceKey == null ? 4 : relayApi {
    if (deviceKey case final k? when k.length != 32) throw ArgumentError('a device key is 32 bytes');
  }

  /// The highest api this transport can sign: 5 with a device key, else 4.
  int get _maxApi => deviceKey == null ? 4 : relayApi;

  static final _ed25519 = Ed25519();

  Future<_Identity>? _identity;

  Future<_Identity> get _id => _identity ??= () async {
        final id = await deriveKey(key, relayIdInfo, length: 16);
        final seed = await deriveKey(key, relaySignInfo);
        final pair = await _ed25519.newKeyPairFromSeed(seed);
        final pub = (await pair.extractPublicKey()).bytes;
        final dk = deviceKey;
        final devPair = dk == null ? null : await _ed25519.newKeyPairFromSeed(dk);
        final devpub = devPair == null ? null : _b64((await devPair.extractPublicKey()).bytes);
        return _Identity(id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), pair, _b64(pub), devPair, devpub);
      }();

  /// This install's device key fingerprint (`ABCD-EFGH`, shown on a device waiting for approval), or null without a
  /// [deviceKey].
  Future<String?> get fingerprint async {
    final dev = (await _id).devPair;
    return dev == null ? null : deviceFingerprint((await dev.extractPublicKey()).bytes);
  }

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

  /// Checks that a relay answers at [base] and speaks an API this build syncs with ([relayMinApi] .. [relayApi], `GET
  /// /v2/health`, not signed) and returns it. A 404 there is asked again at `/v1/health` to tell an older relay apart
  /// ([TransportFailure.olderApi]). Throws [TransportException].
  static Future<int> health(Uri base, {http.Client? client, Duration timeout = const Duration(seconds: 10)}) async {
    final c = client ?? http.Client();
    try {
      final r = await _send(() => c.get(_url(base, 'v2/health')), timeout, 'health');
      if (r.statusCode == 404) {
        final old = await _send(() => c.get(_url(base, 'v1/health')), timeout, 'health');
        if (old.statusCode == 200) _api(old.body, 'health');
      }
      _check(r, 'health');
      return _api(r.body, 'health')['api'] as int;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Bytes per second a transfer must at least average: [deadlineFor] gives 1 s per this many bytes on top of
  /// [timeout]. The relay allows 1 s per 8 KiB, so the client gives up first.
  static const minTransferRate = 64 * 1024;

  /// How long sending a request body of [bytes] (until the answer's headers), or reading an answer of [bytes], may
  /// take: [timeout] (30 s) plus 1 s per [minTransferRate] bytes, so a big bill file or snapshot on a slow uplink is not
  /// cut off while a small request still fails after [timeout].
  Duration deadlineFor(int bytes) => timeout + Duration(microseconds: bytes * Duration.microsecondsPerSecond ~/ minTransferRate);

  /// Runs [call] with an overall [timeout] (null: [call] keeps its own deadlines) and maps failures to
  /// [TransportFailure.unreachable].
  static Future<http.Response> _send(Future<http.Response> Function() call, Duration? timeout, String kind) async {
    try {
      return await (timeout == null ? call() : call().timeout(timeout));
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
      401 when _error(r) == 'revoked' => TransportFailure.revoked,
      401 when _error(r) == 'unenrolled' => TransportFailure.pending,
      409 when _error(r) == 'lastDevice' => TransportFailure.lastDevice,
      409 when _error(r) == 'pendingFull' => TransportFailure.pendingFull,
      409 when _error(r) == 'tooManyKeys' => TransportFailure.tooManyKeys,
      403 when _error(r) == 'createToken' => TransportFailure.createToken,
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
  static bool _isClock(http.Response r) => r.statusCode == 401 && _error(r) == 'clock';

  /// The `error` word of a JSON error body, or null.
  static String? _error(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      return j is Map && j['error'] is String ? j['error'] as String : null;
    } on FormatException {
      return null;
    }
  }

  /// The JSON object in [body]; an `api` above [relayApi] is [TransportFailure.newerApi], below [relayMinApi]
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
    if (api < relayMinApi) {
      logEvent(_log, Level.WARNING, 'relay.olderApi', {'api': api});
      throw const TransportException(TransportFailure.olderApi, 'older api');
    }
    return Map<String, Object?>.from(j);
  }

  /// The string a request signs (RELAY_PROTOCOL.md "Signed requests"): `bw-relay-v4`, with [api] 3 the api-3 text
  /// (`bw-relay-v3`), with [api] 5 `bw-relay-v5` ending with the device key [devpub] (`X-BW-Dev`); [host] is
  /// [signedHost] of the URL.
  static String signedText(String method, String host, String path, String covers, String bodyHash, String time,
          {int api = 4, String? devpub}) =>
      api >= 5
          ? 'bw-relay-v5\n$method\n$host\n$path\n$covers\n$bodyHash\n$time\n${devpub ?? (throw ArgumentError('v5 needs devpub'))}'
          : 'bw-relay-v${api == 3 ? 3 : 4}\n$method\n$host\n$path\n$covers\n$bodyHash\n$time';

  /// The host a request to [url] names, as its `Host` header carries it: lower case, `:port` only when it is not the
  /// scheme's default, an IPv6 address in brackets.
  static String signedHost(Uri url) {
    final h = url.host.toLowerCase();
    final host = h.contains(':') ? '[$h]' : h;
    final def = url.scheme == 'https' ? 443 : 80;
    return url.hasPort && url.port != def ? '$host:${url.port}' : host;
  }

  /// The largest clock offset taken from a relay's `Date` (RELAY_PROTOCOL.md "Signed requests"); a bigger one fails the call.
  static const maxClockOffset = Duration(hours: 24);

  /// One signed request. [withPub]: the request may create the wallet (`X-BW-Pub`, and with a device key the wallet
  /// key's countersignature `X-BW-WSig`); [withWallet]: countersign (enrolment). A 401 `unenrolled` (a device key the
  /// relay does not know yet) enrols once ([enrol]) and sends the request again; 401 `revoked` is final.
  /// [notBefore]: sign with at least this `X-BW-Time` (ms, relay clock), whatever this device's clock says.
  Future<http.Response> _req(String method, String path, String kind,
      {List<int> body = const [],
      Map<String, String> headers = const {},
      bool withPub = false,
      bool withWallet = false,
      int? notBefore}) async {
    final id = await _id;
    final signedPath = '/v2/w/${id.wid}/$path';
    final url = _url(base, signedPath.substring(1));
    final host = signedHost(url);
    final hash = (await Sha256().hash(body)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    Future<http.Response> attempt() async {
      final time = '${max(_now().millisecondsSinceEpoch + clockOffsetMs, notBefore ?? 0)}';
      // api 5: the device key signs; the wallet key countersigns what needs it. Older relays: the wallet key signs.
      final dev = signApi >= 5 ? id.devPair : null;
      final devpub = dev == null ? null : id.devpub;
      final text = utf8.encode(signedText(method, host, signedPath, headers['X-BW-Covers'] ?? '', hash, time,
          api: dev == null ? min(signApi, 4) : 5, devpub: devpub));
      final sig = await _ed25519.sign(text, keyPair: dev ?? id.keyPair);
      final wsig = dev != null && (withPub || withWallet) ? await _ed25519.sign(text, keyPair: id.keyPair) : null;
      final req = http.Request(method, url)
        ..headers.addAll({
          ...headers,
          'X-BW-Time': time,
          'X-BW-Sig': _b64(sig.bytes),
          if (devpub != null) 'X-BW-Dev': devpub,
          if (wsig != null) 'X-BW-WSig': _b64(wsig.bytes),
          if (withPub) 'X-BW-Pub': id.pub,
        });
      if (method != 'GET') req.bodyBytes = body;
      return _send(() async {
        final streamed = await _client.send(req).timeout(deadlineFor(method == 'GET' ? 0 : body.length));
        return http.Response.fromStream(streamed).timeout(deadlineFor(streamed.contentLength ?? 0));
      }, null, kind);
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
    if (r.statusCode == 401 && _error(r) == 'unenrolled' && !withWallet && signApi >= 5) {
      // A device key the relay does not know yet (a new or upgraded install): enrol it, then once more.
      if (await enrol() == EnrolResult.pending) {
        logEvent(_log, Level.INFO, 'relay.enrol.pending', {'kind': kind});
        throw const TransportException(TransportFailure.pending, 'waiting for approval');
      }
      r = await attempt();
    }
    if (r.statusCode == 401 && !_isClock(r) && _error(r) != 'revoked' && _error(r) != 'unenrolled') {
      // A relay of another api version refuses this build's signatures (the signed text names its version): ask its
      // health once, so mixed versions read as "update the app / the relay", and `refused` stays for a real key clash.
      try {
        final api = await health(base, client: _client, timeout: timeout);
        if (api > _maxApi) {
          // An install without a device key on a relay that locked the wallet: as an api-4 app, update.
          logEvent(_log, Level.WARNING, 'relay.newerApi', {'api': api});
          throw const TransportException(TransportFailure.newerApi, 'newer api');
        }
        if (api < minApi) {
          // This relay (or something answering for it) spoke a newer api before: never sign with the wallet key again.
          logEvent(_log, Level.WARNING, 'relay.downgrade', {'api': api, 'min': minApi});
          throw const TransportException(TransportFailure.olderApi, 'downgrade refused');
        }
        if (api < signApi) {
          // An older relay (api 4 or 3): sign its text with the wallet key from now on and send this request again
          // (RELAY_PROTOCOL.md "Versions"); no device features there.
          signApi = api;
          logEvent(_log, Level.INFO, 'relay.signApi', {'api': api});
          r = await attempt();
        }
      } on TransportException catch (e) {
        if (e.failure == TransportFailure.olderApi || e.failure == TransportFailure.newerApi) rethrow;
        logEvent(_log, Level.FINE, 'relay.health.after401', {'failure': e.failure.name});
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
    if ((j['api'] as int) > signApi) {
      // `{"api":5}` to a wallet-key request: the wallet requires device approval, which this transport cannot sign.
      logEvent(_log, Level.WARNING, 'relay.newerApi', {'api': j['api']});
      throw const TransportException(TransportFailure.newerApi, 'newer api');
    }
    try {
      final s = RelayState.fromJson(j);
      if ((s.api ?? 0) >= 5 && signApi >= 5 && minApi < 5) {
        minApi = 5;
        logEvent(_log, Level.INFO, 'relay.minApi', {'api': 5});
        onMinApi?.call(5, s.instance);
      }
      return s;
    } on FormatException catch (e, st) {
      logError(_log, 'relay.badState', e, st);
      throw const TransportException(TransportFailure.other, 'bad state');
    }
  }

  @override
  Future<void> put(String device, int seq, List<int> bytes) async {
    // seq 1 may create the wallet on the relay: it carries the public key (trust on first use) and the create token.
    final token = createToken;
    await _req('PUT', 'd/$device/$seq', 'put',
        body: bytes,
        headers: {..._octets, if (seq == 1 && token != null && token.isNotEmpty) 'X-BW-Create-Token': token},
        withPub: seq == 1);
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

  @override
  Future<void> putBlob(String hash, List<int> bytes) async {
    await _req('PUT', 'blob/$hash', 'putBlob', body: bytes, headers: _octets);
  }

  /// Null on 404 (never stored, deleted, or an older relay without blobs).
  @override
  Future<List<int>?> getBlob(String hash) async {
    try {
      return Uint8List.fromList((await _req('GET', 'blob/$hash', 'getBlob')).bodyBytes);
    } on TransportException catch (e) {
      if (e.failure == TransportFailure.missing) return null;
      rethrow;
    }
  }

  /// `PUT snapshot/<id>/blobs`, body = the sorted JSON array of [hashes] (api 4; signed like every body).
  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) async {
    await _req('PUT', 'snapshot/$id/blobs', 'putSnapshotBlobs',
        body: utf8.encode(jsonEncode([...hashes]..sort())), headers: {'Content-Type': 'application/json'});
  }

  // ---- device keys (api 5, RELAY_PROTOCOL.md "Device keys") ---------------------------------------------------------

  /// No device features: this transport has no device key, or the relay is older (it signs with the wallet key).
  void _needDeviceApi() {
    if (signApi < 5) throw const TransportException(TransportFailure.olderApi, 'no device keys');
  }

  /// `PUT enrol`: enrols this install's device key (countersigned by the wallet key), or asks for approval when the
  /// wallet is locked ([EnrolResult.pending]). Called by every request that gets 401 `unenrolled`. Throws
  /// [TransportFailure.revoked] for a removed key, [TransportFailure.pending] when the relay holds too many requests.
  @override
  Future<EnrolResult> enrol() async {
    _needDeviceApi();
    final id = deviceId;
    final r = await _req('PUT', 'enrol', 'enrol',
        body: utf8.encode(jsonEncode({if (id != null) 'deviceId': id})), headers: {'Content-Type': 'application/json'}, withWallet: true);
    final result = r.statusCode == 202 ? EnrolResult.pending : EnrolResult.enrolled;
    logEvent(_log, Level.INFO, 'relay.enrol', {'result': result.name});
    return result;
  }

  /// Approves the pending device key with fingerprint [fp] (`ABCD-EFGH`). Idempotent. [TransportFailure.missing] when no
  /// such key waits (or it expired), [TransportFailure.conflict] when that key was removed.
  @override
  Future<void> approveDevice(String fp) => _device(fp, 'approve');

  /// Removes (revokes) the device key with fingerprint [fp], or rejects it while pending; the relay also locks the
  /// wallet. Idempotent. [TransportFailure.lastDevice] for the wallet's last enrolled key, [TransportFailure.missing]
  /// for an unknown one.
  @override
  Future<void> revokeDevice(String fp) => _device(fp, 'revoke');

  Future<void> _device(String fp, String action) async {
    _needDeviceApi();
    if (!RegExp(r'^[A-Z2-7]{4}-[A-Z2-7]{4}$').hasMatch(fp)) throw const TransportException(TransportFailure.rejected, 'bad fingerprint');
    await _req('PUT', 'devices/$fp', action, body: utf8.encode(jsonEncode({action: true})), headers: {'Content-Type': 'application/json'});
    logEvent(_log, Level.INFO, 'relay.device', {'action': action});
  }

  /// How many times [revokeOthers] sends `devices/others` before it gives up on keys that stay active.
  static const revokeOthersRounds = 3;

  /// Revokes every device key but this install's and rejects every pending one, and locks the wallet ("Remove all
  /// other devices", for a device that may have been taken); returns how many keys it revoked (0 when replayed).
  /// The relay spares keys and requests newer than the request's `X-BW-Time` (RELAY_PROTOCOL.md "Device keys"), so a
  /// clock up to 5 min behind the relay's would spare a key approved in those minutes: after each call it reads the
  /// state again and, while another key is still active, sends it again signed 1 s after the newest remaining key's or
  /// request's time (state times are whole seconds; so the requests then waiting are rejected too), at most
  /// [revokeOthersRounds] times; then [TransportFailure.other] `others remain` (the app says to try again). Pending
  /// requests alone never fail it (a key holder can keep asking; each call rejects what it saw, none gets in without an
  /// approval), and a state read that fails after an accepted call returns the count so far.
  @override
  Future<int> revokeOthers() async {
    _needDeviceApi();
    var total = 0;
    int? notBefore;
    for (var round = 1;; round++) {
      final r = await _req('PUT', 'devices/others', 'revokeOthers',
          body: utf8.encode(jsonEncode({'revoke': true})), headers: {'Content-Type': 'application/json'}, notBefore: notBefore);
      logEvent(_log, Level.INFO, 'relay.device', {'action': 'revokeOthers', 'round': round});
      total += _revokedCount(r);
      final RelayState st;
      try {
        st = await state();
      } on TransportException catch (e) {
        // The call itself was accepted: report it as done rather than as a failure.
        logEvent(_log, Level.WARNING, 'relay.revokeOthers.unchecked', {'failure': e.failure.name});
        return total;
      }
      final keys = st.keys;
      if (keys == null) return total; // no key list (not a device-signed answer): nothing to check against
      final active = [
        for (final k in keys)
          if (!k.self && !k.isRevoked) k.added,
      ];
      if (active.isEmpty) return total;
      if (round >= revokeOthersRounds) {
        logEvent(_log, Level.WARNING, 'relay.revokeOthers.left', {'keys': active.length, 'rounds': round});
        throw const TransportException(TransportFailure.other, 'others remain');
      }
      // A time the relay accepts (within its window) and later than every key and request still there.
      final newest = [...active, for (final p in st.pending) p.at].map((t) => t?.millisecondsSinceEpoch ?? 0).fold(0, max);
      notBefore = max(newest + 1000, (notBefore ?? 0) + 1);
    }
  }

  static int _revokedCount(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['revoked'] is int) return j['revoked'] as int;
    } on FormatException {
      // fall through
    }
    throw const TransportException(TransportFailure.other, 'bad revoke answer');
  }

  /// Turns "Require approval for new devices" on or off; returns the value the relay now holds.
  @override
  Future<bool> setLocked(bool locked) async {
    _needDeviceApi();
    final r =
        await _req('PUT', 'lock', 'lock', body: utf8.encode(jsonEncode({'locked': locked})), headers: {'Content-Type': 'application/json'});
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['locked'] is bool) return j['locked'] as bool;
    } on FormatException {
      // fall through
    }
    throw const TransportException(TransportFailure.other, 'bad lock answer');
  }

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
