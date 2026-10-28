import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'rate_limit.dart';
import 'signing.dart';
import 'wallet.dart';

const int _mib = 1024 * 1024;

/// Largest sealed op file.
const int maxFileBytes = 16 * _mib;

/// Largest snapshot.
const int maxSnapshotBytes = 64 * _mib;

const int _maxJsonBytes = 64 * 1024;

/// Largest declared blob set body (`PUT snapshot/<id>/blobs`): 100,000 hashes as a JSON array fit.
const int maxBlobSetBytes = 7 * _mib;

/// Default for [Relay.maxInFlightBytes]: request body bytes one client address may have buffered at once.
const int defaultMaxInFlightBytes = 32 * _mib;

/// Header that carries the creation token on the `PUT d/<device>/1` that creates a wallet (see `Relay.createToken`).
const String createTokenHeader = 'x-bw-create-token';
const List<String> defaultOrigins = ['http://127.0.0.1:8080', 'http://localhost:8080'];
final RegExp _timePattern = RegExp(r'^[0-9]{1,16}$');

class _HttpError implements Exception {
  _HttpError(this.status, this.message, {this.close = false});

  final int status;
  final String message;
  final bool close;
}

class _Out {
  _Out.json(this.status, Object? body)
      : bytes = utf8.encode(jsonEncode(body)),
        contentType = 'application/json; charset=utf-8',
        close = false;
  _Out.octets(this.bytes)
      : status = 200,
        contentType = 'application/octet-stream',
        close = false;
  _Out.empty(this.status)
      : bytes = const [],
        contentType = null,
        close = false;
  _Out.error(this.status, String message, {this.close = false})
      : bytes = utf8.encode(jsonEncode({'error': message})),
        contentType = 'application/json; charset=utf-8';

  final int status;
  final List<int> bytes;
  final String? contentType;
  final bool close;
}

/// The signature headers of a request and what it signs besides method and body (RELAY_PROTOCOL.md "Signed requests").
class _Sig {
  _Sig(this.method, this.host, this.path, this.time, this.sig, this.covers, {this.dev, this.devBytes, this.wsig});

  /// `X-BW-Dev` (api 5): the device key that made [sig] (`bw-relay-v5`), as sent; null = signed with the wallet key.
  final String? dev;
  final Uint8List? devBytes;

  /// `X-BW-WSig` (api 5): the wallet key's signature over the same v5 text (creation, enrolment), or null.
  final Uint8List? wsig;

  /// `GET` or `HEAD` for the read endpoints (a HEAD request is signed as `HEAD`).
  final String method;

  /// The host the client addressed (v3): [Relay.publicHost] when set, else the request's `Host` header, lower case.
  final String host;

  /// From `/v2/` on, rebuilt from the checked segments.
  final String path;
  final String time;
  final Uint8List sig;

  /// The `X-BW-Covers` value, or empty.
  final String covers;

  /// Which text verified ([Relay._verify]): 5 (a device key), 4, or 3 for an api-3 app (`bw-relay-v3`).
  int version = 4;

  String text(String method, List<int> body, {bool v3 = false}) => dev != null
      ? signedTextV5(method, host, path, covers, sha256OfBytes(body), time, dev!)
      : signedText(method, host, path, covers, sha256OfBytes(body), time, v3: v3);
}

/// What a request log line may say: kind, byte count, short wallet and device ids.
class _LogInfo {
  String kind = 'other';
  int bytes = 0;
  String wid = '-';
  String device = '-';

  /// Client address (never logged) and the body bytes this request holds in [Relay._held].
  String remote = '?';
  int held = 0;
}

/// The relay: HTTP API v2 over a data folder (docs/context/RELAY_PROTOCOL.md). It stores sealed files it cannot read.
class Relay {
  Relay({
    required this.data,
    this.origins = defaultOrigins,
    this.maxWallets = 16,
    this.maxBytes = 1024 * _mib,
    this.maxInFlightBytes = defaultMaxInFlightBytes,
    this.createToken,
    this.trustProxy = false,
    DateTime Function()? now,
    void Function(String line)? log,
    this.publicHost,
    this.hooks,
  })  : _now = now ?? DateTime.now,
        _log = log ?? stdout.writeln;

  final Directory data;
  final List<String> origins;
  final int maxWallets;
  final int maxBytes;

  /// Body bytes one client address may have buffered across its concurrent requests; a request that would pass it
  /// while others from that address hold bytes gets 429 (a lone request is limited only by its own size limit).
  final int maxInFlightBytes;

  /// When set, the `PUT d/<device>/1` that creates a wallet must carry this value in `X-BW-Create-Token` (403 otherwise).
  /// Null = creation is open (development mode). Existing wallets are not affected.
  final String? createToken;

  /// Take the client address (rate limit, in-flight cap) from the last hop of `X-Forwarded-For`; only behind a reverse
  /// proxy that is the sole way to reach the relay.
  final bool trustProxy;

  final DateTime Function() _now;
  final void Function(String) _log;

  /// The host clients address (`bw.example.org`, with `:port` when not the scheme's default), lower case. Set behind a
  /// proxy (Caddy) whose `Host` differs from what clients signed; null = the request's `Host` header is the host.
  final String? publicHost;

  /// Fault injection for tests ([RelayTestHooks]); null in production.
  final RelayTestHooks? hooks;

  final Map<String, Wallet> _wallets = {};
  final Map<String, Future<void>> _tails = {};
  final RateLimiter _limiter = RateLimiter();
  final Set<Future<void>> _inFlight = {};
  final Map<String, int> _held = {};

  /// Test hook: called with the client address's in-flight body bytes each time a request buffers a chunk.
  void Function(int total)? onHold;
  Future<void>? _loaded;
  HttpServer? _server;

  /// Wallets known to the relay (for tests and logs).
  int get walletCount => _wallets.length;

  /// Starts listening; [port] 0 picks a free one (see [HttpServer.port]).
  Future<HttpServer> serve({String host = '127.0.0.1', int port = 8787}) async {
    await _ensureLoaded();
    final server = await HttpServer.bind(host, port);
    _server = server;
    server.listen((req) {
      late final Future<void> f;
      f = handle(req).whenComplete(() => _inFlight.remove(f));
      _inFlight.add(f);
    });
    return server;
  }

  /// Stops accepting, lets running requests finish (up to 10 s), then drops the remaining connections.
  Future<void> close() async {
    final s = _server;
    _server = null;
    if (s == null) return;
    unawaited(s.close());
    await Future.wait(_inFlight.toList()).timeout(const Duration(seconds: 10), onTimeout: () => const <void>[]);
    await s.close(force: true);
  }

  Future<void> _ensureLoaded() => _loaded ??= _load();

  Future<void> _load() async {
    await data.create(recursive: true);
    await for (final ent in data.list(followLinks: false)) {
      if (ent is! Directory) continue;
      final wid = ent.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (!widPattern.hasMatch(wid)) continue;
      final w = await Wallet.load(ent, wid, _now(), hooks: hooks);
      if (w != null) _wallets[wid] = w;
    }
  }

  /// Handles one request: never throws, always answers and logs one line.
  Future<void> handle(HttpRequest req) async {
    final info = _LogInfo();
    _Out out;
    try {
      await _ensureLoaded();
      out = await _dispatch(req, info);
    } on _HttpError catch (e) {
      out = _Out.error(e.status, e.message, close: e.close);
    } on Object catch (e) {
      info.kind = '${info.kind}!${e.runtimeType}';
      out = _Out.error(500, 'internal');
    } finally {
      _release(info);
    }
    await _send(req, out);
    _log('relay ${info.kind} ${out.status} ${info.bytes} w=${info.wid} d=${info.device}');
  }

  Future<void> _send(HttpRequest req, _Out out) async {
    final res = req.response;
    try {
      res.statusCode = out.status;
      final origin = req.headers.value('origin');
      res.headers.set('Vary', 'Origin');
      res.headers.set('Cache-Control', 'no-store');
      res.headers.date = _now(); // the relay clock: clients set their signing offset from it
      if (origin != null && origins.contains(origin)) {
        res.headers.set('Access-Control-Allow-Origin', origin);
        if (req.method == 'OPTIONS') {
          res.headers.set('Access-Control-Allow-Methods', 'GET, PUT, DELETE, OPTIONS');
          res.headers.set('Access-Control-Allow-Headers',
              'Content-Type, X-BW-Covers, X-BW-Time, X-BW-Sig, X-BW-Pub, X-BW-Create-Token, X-BW-Dev, X-BW-WSig');
          res.headers.set('Access-Control-Max-Age', '600');
        } else {
          res.headers.set('Access-Control-Expose-Headers', 'Date');
        }
      }
      if (out.status == 429) res.headers.set('Retry-After', '1');
      if (out.close) res.headers.set('Connection', 'close');
      if (out.contentType != null) res.headers.set('Content-Type', out.contentType!);
      res.contentLength = out.bytes.length;
      if (req.method != 'HEAD' && out.bytes.isNotEmpty) res.add(out.bytes);
      await res.close();
    } on Object {
      // client went away
    }
  }

  Future<_Out> _dispatch(HttpRequest req, _LogInfo info) async {
    final remote = _client(req);
    info.remote = remote;
    if (!_limiter.allow(remote, _now())) {
      info.kind = 'limited';
      return _Out.error(429, 'too many requests');
    }
    if (req.method == 'OPTIONS') {
      info.kind = 'options';
      return _Out.empty(204);
    }
    final seg = req.uri.pathSegments;
    if (seg.length < 2 || seg[0] != 'v2') throw _HttpError(404, 'not found');
    if (seg[1] == 'health' && seg.length == 2) {
      info.kind = 'health';
      _method(req, ['GET', 'HEAD']);
      return _Out.json(200, {'api': apiVersion});
    }
    if (seg[1] != 'w' || seg.length < 4) throw _HttpError(404, 'not found');
    final wid = seg[2];
    if (!widPattern.hasMatch(wid)) throw _HttpError(400, 'bad wallet id');
    info.wid = wid.substring(0, 6);
    final route = seg[3];
    final path = '/${seg.join('/')}';
    switch ((route, seg.length)) {
      case ('state', 4):
        info.kind = 'state';
        _method(req, ['GET', 'HEAD']);
        return _getState(wid, _signature(req, path));
      case ('d', 6):
        final device = _name(seg[4], 'bad device');
        info.device = _short(device);
        final seq = parseSeq(seg[5]);
        if (seq == null) throw _HttpError(400, 'bad seq');
        _method(req, ['GET', 'HEAD', 'PUT']);
        final sig = _signature(req, path);
        if (req.method != 'PUT') {
          info.kind = 'get-d';
          return _getData(wid, device, seq, info, sig);
        }
        info.kind = 'put-d';
        return _putData(req, wid, device, seq, info, sig);
      case ('ack', 5):
        final device = _name(seg[4], 'bad device');
        info.device = _short(device);
        info.kind = 'ack';
        _method(req, ['PUT']);
        return _putAck(req, wid, device, info, _signature(req, path));
      case ('snapshot', 5):
        final id = _name(seg[4], 'bad snapshot id');
        _method(req, ['GET', 'HEAD', 'PUT']);
        final sig = _signature(req, path);
        if (req.method != 'PUT') {
          info.kind = 'get-snap';
          return _getSnapshot(wid, id, info, sig);
        }
        info.kind = 'put-snap';
        return _putSnapshot(req, wid, id, info, sig);
      case ('snapshot', 6) when seg[5] == 'blobs':
        final id = _name(seg[4], 'bad snapshot id');
        _method(req, ['PUT']);
        info.kind = 'put-set';
        return _putBlobSet(req, wid, id, info, _signature(req, path));
      case ('enrol', 4):
        info.kind = 'enrol';
        _method(req, ['PUT']);
        final sig = _signature(req, path);
        if (sig.devBytes case final b?) info.device = _short(fingerprint(b));
        return _enrol(req, wid, info, sig);
      case ('devices', 5):
        final fp = seg[4];
        if (!fingerprintPattern.hasMatch(fp)) throw _HttpError(400, 'bad fingerprint');
        info.device = _short(fp);
        info.kind = 'device';
        _method(req, ['PUT']);
        return _putDevice(req, wid, fp, info, _signature(req, path));
      case ('lock', 4):
        info.kind = 'lock';
        _method(req, ['PUT']);
        return _putLock(req, wid, info, _signature(req, path));
      case ('blob', 5):
        final hash = seg[4];
        if (!blobHashPattern.hasMatch(hash)) throw _HttpError(400, 'bad blob hash');
        _method(req, ['GET', 'HEAD', 'PUT', 'DELETE']);
        final sig = _signature(req, path);
        switch (req.method) {
          case 'GET' || 'HEAD':
            info.kind = 'get-blob';
            return _getBlob(wid, hash, info, sig);
          case 'PUT':
            info.kind = 'put-blob';
            return _putBlob(req, wid, hash, info, sig);
          default:
            info.kind = 'delete-blob';
            return _deleteBlob(req, wid, hash, info, sig);
        }
    }
    throw _HttpError(404, 'not found');
  }

  /// The client address: the connection's, or with [trustProxy] the last hop of `X-Forwarded-For` (the one the proxy
  /// appended) when it is a valid IP address.
  String _client(HttpRequest req) {
    final peer = req.connectionInfo?.remoteAddress.address ?? '?';
    if (!trustProxy) return peer;
    final xff = req.headers['x-forwarded-for'];
    if (xff == null || xff.isEmpty) return peer;
    final last = xff.last.split(',').last.trim();
    return InternetAddress.tryParse(last)?.address ?? peer;
  }

  static String _short(String name) => name.length > 6 ? name.substring(0, 6) : name;

  static void _method(HttpRequest req, List<String> allowed) {
    if (!allowed.contains(req.method)) throw _HttpError(405, 'method not allowed');
  }

  static String _name(String s, String error) {
    if (!namePattern.hasMatch(s)) throw _HttpError(400, error);
    return s;
  }

  // ---- signatures -----------------------------------------------------------------------------------------------

  /// The one value of header [name], or null when absent; sent more than once → 400.
  static String? _header(HttpRequest req, String name, String display) {
    final v = req.headers[name];
    if (v == null || v.isEmpty) return null;
    if (v.length > 1) throw _HttpError(400, 'bad $display');
    return v.single;
  }

  /// The signature headers: 401 when missing, 400 when malformed, 401 `clock` outside [signatureWindow]. Checked before
  /// any wallet lookup or body read.
  _Sig _signature(HttpRequest req, String path) {
    final time = _header(req, 'x-bw-time', 'X-BW-Time');
    final sig = _header(req, 'x-bw-sig', 'X-BW-Sig');
    if (time == null || sig == null) throw _HttpError(401, 'unsigned');
    if (!_timePattern.hasMatch(time) || int.parse(time) > maxSeq) throw _HttpError(400, 'bad X-BW-Time');
    final bytes = decodeBase64Url(sig, 64);
    if (bytes == null) throw _HttpError(400, 'bad X-BW-Sig');
    if ((int.parse(time) - _now().millisecondsSinceEpoch).abs() > signatureWindow.inMilliseconds) throw _HttpError(401, 'clock');
    // v3 signs the host the client addressed: a request captured for one relay does not verify at another one that
    // holds the same wallet (a moved or second relay). No Host and no publicHost: the empty string, which no client signs.
    final host = (publicHost ?? req.headers.value(HttpHeaders.hostHeader) ?? '').toLowerCase();
    // api 5: the device key that signed (in the signed text) and the wallet key's countersignature where one is needed.
    final dev = _header(req, 'x-bw-dev', 'X-BW-Dev');
    final devBytes = dev == null ? null : decodeBase64Url(dev, 32);
    if (dev != null && devBytes == null) throw _HttpError(400, 'bad X-BW-Dev');
    final w = _header(req, 'x-bw-wsig', 'X-BW-WSig');
    final wsig = w == null ? null : decodeBase64Url(w, 64);
    if (w != null && wsig == null) throw _HttpError(400, 'bad X-BW-WSig');
    return _Sig(req.method, host, path, time, bytes, _header(req, 'x-bw-covers', 'X-BW-Covers') ?? '',
        dev: dev, devBytes: devBytes, wsig: wsig);
  }

  /// 401 unless [sig] signs this request ([method], [body]): with `X-BW-Dev` the v5 text by that device key, else for
  /// the wallet key [pub] the v4 text, or the v3 text of an api-3 app ([_Sig.version] says which).
  static Future<void> _verify(Uint8List pub, _Sig sig, String method, List<int> body) async {
    if (!await _verified(pub, sig, method, body)) throw _HttpError(401, 'bad signature');
  }

  /// The wallet key's countersignature (`X-BW-WSig`, over the v5 text) for [pub]: 401 `unsigned` when absent, 401
  /// `bad signature` when it does not verify.
  static Future<void> _verifyWallet(Uint8List pub, _Sig sig, String method, List<int> body) async {
    final w = sig.wsig;
    if (w == null) throw _HttpError(401, 'unsigned');
    if (!await verifySignature(pub, w, sig.text(method, body))) throw _HttpError(401, 'bad signature');
  }

  /// Who may (RELAY_PROTOCOL.md "Checks", step 7), after the signature verified: a revoked device key → 401 `revoked`,
  /// one not enrolled → 401 `unenrolled`, the wallet key on a locked wallet → 401 `locked`. Checked before and again
  /// inside the wallet lock (a revoke wins over a request verified just before it).
  static void _admit(Wallet w, _Sig sig) {
    final dev = sig.dev;
    if (dev == null) {
      if (w.locked) throw _HttpError(401, 'locked');
      return;
    }
    final k = w.keys[dev];
    if (k == null) throw _HttpError(401, 'unenrolled');
    if (k.revoked != null) throw _HttpError(401, 'revoked');
  }

  /// [_admit] inside the wallet lock, then [f].
  Future<T> _lockedAs<T>(String wid, _Sig sig, Future<T> Function(Wallet w) f) => _locked(wid, () {
        final w = _known(wid);
        _admit(w, sig);
        return f(w);
      });

  /// Records the stream a device key last wrote or acked as (state `keys[].device`); saved with the caller's meta save.
  static void _touchKey(Wallet w, _Sig sig, String device) {
    final dev = sig.dev;
    if (dev != null) w.keys[dev]?.device = device;
  }

  static Future<bool> _verified(Uint8List pub, _Sig sig, String method, List<int> body) async {
    if (sig.dev case final _?) {
      if (!await verifySignature(sig.devBytes!, sig.sig, sig.text(method, body))) return false;
      sig.version = 5;
      return true;
    }
    if (await verifySignature(pub, sig.sig, sig.text(method, body))) return true;
    if (!await verifySignature(pub, sig.sig, sig.text(method, body, v3: true))) return false;
    sig.version = 3;
    return true;
  }

  /// A known wallet: 404 when the relay does not hold [wid].
  Wallet _known(String wid) => _wallets[wid] ?? (throw _HttpError(404, 'unknown wallet'));

  // ---- body ---------------------------------------------------------------------------------------------------------

  /// Reads the body (at most [limit] bytes: 413 beyond). The bytes count against the client address's in-flight
  /// budget ([maxInFlightBytes]) until the request is answered; passing it while other requests from that address
  /// hold bytes is 429. Either refusal drains (and discards) a little more so the client sees the status.
  Future<Uint8List> _readBody(HttpRequest req, int limit, _LogInfo info) async {
    var over = req.contentLength > limit;
    var busy = !over && req.contentLength > 0 && _wouldPass(info, req.contentLength);
    final b = BytesBuilder(copy: false);
    var n = 0;
    var drained = 0;
    await for (final chunk in req) {
      if (over || busy) {
        drained += chunk.length;
        if (drained > limit * 2) break; // enough of a polite drain
        continue;
      }
      n += chunk.length;
      if (n > limit) {
        over = true;
        _release(info);
        b.clear();
        continue;
      }
      if (_wouldPass(info, chunk.length)) {
        busy = true;
        _release(info);
        b.clear();
        continue;
      }
      _hold(info, chunk.length);
      b.add(chunk);
    }
    info.bytes = over ? limit + 1 : n;
    if (over) throw _HttpError(413, 'too big', close: true);
    if (busy) throw _HttpError(429, 'too many bytes in flight', close: true);
    return b.takeBytes();
  }

  /// Refuses a body without buffering it: reads and discards up to 2× [limit] (so the client sees the status), then
  /// throws [status].
  Future<Never> _refuseBody(HttpRequest req, int limit, int status, String message) async {
    var drained = 0;
    await for (final chunk in req) {
      drained += chunk.length;
      if (drained > limit * 2) break;
    }
    throw _HttpError(status, message, close: true);
  }

  /// Whether [more] bytes would put this address over [maxInFlightBytes] while other requests of it hold bytes.
  bool _wouldPass(_LogInfo info, int more) {
    final all = _held[info.remote] ?? 0;
    return all + more > maxInFlightBytes && all - info.held > 0;
  }

  void _hold(_LogInfo info, int n) {
    info.held += n;
    _held[info.remote] = (_held[info.remote] ?? 0) + n;
    onHold?.call(_held[info.remote]!);
  }

  void _release(_LogInfo info) {
    if (info.held == 0) return;
    final left = (_held[info.remote] ?? 0) - info.held;
    info.held = 0;
    if (left > 0) {
      _held[info.remote] = left;
    } else {
      _held.remove(info.remote);
    }
  }

  static Map<String, Object?> _jsonMap(List<int> body) {
    try {
      final v = jsonDecode(utf8.decode(body));
      if (v is Map<String, Object?>) return v;
    } on FormatException {
      // fall through
    }
    throw _HttpError(400, 'bad json');
  }

  // ---- locks --------------------------------------------------------------------------------------------------------

  Future<T> _locked<T>(String wid, Future<T> Function() f) {
    final prev = _tails[wid] ?? Future<void>.value();
    final run = prev.then((_) => f());
    late final Future<void> tail;
    tail = run.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_tails[wid], tail)) _tails.remove(wid);
    });
    _tails[wid] = tail;
    return run;
  }

  // ---- handlers -----------------------------------------------------------------------------------------------------

  Future<_Out> _getState(String wid, _Sig sig) async {
    final w = _known(wid);
    if (!await _verified(w.pubBytes, sig, sig.method, const [])) {
      // An api-2 app (its `bw-relay-v2` text, no host) gets only `{"api":5}`, which it reads as "update the app"
      // instead of "this relay refused the wallet". Nothing else is in the answer.
      final legacy = signedTextV2(sig.method, sig.path, sig.covers, sha256OfBytes(const []), sig.time);
      if (sig.dev == null && await verifySignature(w.pubBytes, sig.sig, legacy)) return _Out.json(200, {'api': apiVersion});
      throw _HttpError(401, 'bad signature');
    }
    // The wallet key on a locked wallet (an api-4 or api-3 app): only `{"api":5}`, so it asks for an update.
    if (sig.dev == null && w.locked) return _Out.json(200, {'api': apiVersion});
    _admit(w, sig);
    return _locked(wid, () async {
      if (sig.dev == null && w.locked) return _Out.json(200, {'api': apiVersion});
      _admit(w, sig);
      // An api-3 app (v3 text) is told api 3, an api-4 app 4, so they sync on as before (RELAY_PROTOCOL.md "Versions").
      return _Out.json(200, w.stateJson(maxBytes: maxBytes, api: sig.version, self: sig.dev, now: _now()));
    });
  }

  Future<_Out> _getData(String wid, String device, int seq, _LogInfo info, _Sig sig) async {
    final w = _known(wid);
    await _verify(w.pubBytes, sig, sig.method, const []);
    _admit(w, sig);
    return _lockedAs(wid, sig, (w) async {
      final st = w.devices[device];
      if (st == null || seq > st.last) throw _HttpError(404, 'not stored');
      if (seq < st.first) throw _HttpError(410, 'pruned');
      final bytes = await _stored(w.dataFile(device, seq), info);
      info.bytes = bytes.length;
      return _Out.octets(bytes);
    });
  }

  /// Reads a file the meta says exists. A missing file (the data folder was damaged or restored from an older copy) is
  /// 404 `missing` (410 stays for pruned), logged as kind `...!missing`. Any other read error stays a 500 `storage`.
  Future<Uint8List> _stored(File f, _LogInfo info) async {
    try {
      return await f.readAsBytes();
    } on PathNotFoundException {
      info.kind = '${info.kind}!missing';
      throw _HttpError(404, 'missing');
    } on FileSystemException {
      throw _HttpError(500, 'storage');
    }
  }

  Future<_Out> _putData(HttpRequest req, String wid, String device, int seq, _LogInfo info, _Sig sig) async {
    final known = _wallets[wid];
    final String pub;
    if (known != null) {
      pub = known.pub;
    } else {
      // An unknown wallet: refuse what cannot create it before reading (and buffering) a body. Checked again in the lock.
      // The creation token is a header check, so it comes first: a client without it learns nothing about capacity.
      if (!_createTokenOk(req)) await _refuseBody(req, maxFileBytes, 403, 'createToken');
      if (seq != 1) await _refuseBody(req, maxFileBytes, 422, 'seq beyond last + 1');
      if (_wallets.length >= maxWallets) await _refuseBody(req, maxFileBytes, 507, 'relay full');
      final h = _header(req, 'x-bw-pub', 'X-BW-Pub');
      if (h == null) await _refuseBody(req, maxFileBytes, 401, 'unknown wallet without X-BW-Pub');
      if (decodeBase64Url(h, 32) == null) await _refuseBody(req, maxFileBytes, 400, 'bad X-BW-Pub');
      // api 5: the device key signs, the wallet key countersigns (both must verify).
      if (sig.dev != null && sig.wsig == null) await _refuseBody(req, maxFileBytes, 401, 'unsigned');
      pub = h;
    }
    final body = await _readBody(req, maxFileBytes, info);
    final pubBytes = known?.pubBytes ?? decodeBase64Url(pub, 32)!;
    await _verify(pubBytes, sig, 'PUT', body);
    if (known == null && sig.dev != null) await _verifyWallet(pubBytes, sig, 'PUT', body);
    if (known != null) _admit(known, sig);
    return _locked(wid, () async {
      final w = _wallets[wid];
      // Trust on first use: a creation that lost the race to another key is refused here.
      if (w != null && !constantTimeEquals(pub, w.pub)) throw _HttpError(401, 'bad signature');
      if (w == null) return _createWallet(wid, pub, device, seq, body, sig.dev);
      _admit(w, sig);
      final st = w.devices[device];
      final first = st?.first ?? 1;
      final last = st?.last ?? 0;
      _touchKey(w, sig, device);
      if (seq <= last) {
        // Known device: it is alive whatever the answer.
        st!.lastSeen = _now();
        await w.saveMeta();
        if (seq < first) throw _HttpError(410, 'pruned');
        final stored = await _stored(w.dataFile(device, seq), info);
        if (_same(stored, body)) return _Out.json(200, {'seq': seq});
        throw _HttpError(409, 'other bytes stored');
      }
      if (seq > last + 1) {
        if (st != null) {
          st.lastSeen = _now();
          await w.saveMeta();
        }
        throw _HttpError(422, 'seq beyond last + 1');
      }
      if (w.totalBytes + body.length > maxBytes) throw _HttpError(507, 'wallet full');
      await w.writeData(device, seq, body);
      w.bytes += body.length;
      final dev = w.devices.putIfAbsent(device, () => DeviceState(_now()));
      dev.last = seq;
      dev.lastSeen = _now();
      await w.saveMeta();
      await w.prune(_now());
      return _Out.json(201, {'seq': seq});
    });
  }

  /// Whether creation is open ([createToken] null) or the request carries the token (constant-time compare; the token is
  /// never logged). The caller answers 403 `createToken` otherwise, draining the body first so the client sees the status.
  bool _createTokenOk(HttpRequest req) {
    final want = createToken;
    if (want == null) return true;
    final got = _header(req, createTokenHeader, 'X-BW-Create-Token');
    return got != null && constantTimeEquals(got, want);
  }

  /// The first accepted `PUT d/...` of a wallet creates it and stores its public key [pub] (trust on first use).
  /// With [dev] (api 5) that device key is enrolled `by: "wallet"`.
  Future<_Out> _createWallet(String wid, String pub, String device, int seq, Uint8List body, String? dev) async {
    if (seq != 1) throw _HttpError(422, 'seq beyond last + 1');
    if (_wallets.length >= maxWallets) throw _HttpError(507, 'relay full');
    if (body.length > maxBytes) throw _HttpError(507, 'wallet full');
    final dir = Directory('${data.path}/$wid');
    final w = Wallet(wid, dir, pub, hooks: hooks);
    if (dev != null) w.keys[dev] = DeviceKey(fingerprint(decodeBase64Url(dev, 32)!), _now(), 'wallet', device: device);
    _wallets[wid] = w; // reserve the slot before any await
    try {
      if (await dir.exists()) await dir.delete(recursive: true); // left over from an interrupted creation
      await w.writeData(device, 1, body);
      w.bytes = body.length;
      final st = DeviceState(_now())..last = 1;
      w.devices[device] = st;
      await w.saveMeta();
    } on Object {
      _wallets.remove(wid);
      rethrow;
    }
    return _Out.json(201, {'seq': seq});
  }

  Future<_Out> _putAck(HttpRequest req, String wid, String device, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    final body = await _readBody(req, _maxJsonBytes, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    _admit(known, sig);
    final raw = _jsonMap(body);
    final acks = <String, int>{};
    for (final e in raw.entries) {
      final v = e.value;
      if (!namePattern.hasMatch(e.key) || v is! int || v < 0 || v > maxSeq) throw _HttpError(400, 'bad ack');
      acks[e.key] = v;
    }
    return _lockedAs(wid, sig, (w) async {
      for (final e in acks.entries) {
        if (e.value > (w.devices[e.key]?.last ?? 0)) throw _HttpError(422, 'ack beyond last');
      }
      _touchKey(w, sig, device);
      final dev = w.devices.putIfAbsent(device, () => DeviceState(_now()));
      dev.lastSeen = _now();
      for (final e in acks.entries) {
        if (e.value > (dev.acks[e.key] ?? -1)) dev.acks[e.key] = e.value;
      }
      await w.saveMeta();
      await w.prune(_now());
      return _Out.empty(204);
    });
  }

  Future<_Out> _putSnapshot(HttpRequest req, String wid, String id, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    final covers = _parseCovers(sig.covers.isEmpty ? null : sig.covers);
    final body = await _readBody(req, maxSnapshotBytes, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    _admit(known, sig);
    return _lockedAs(wid, sig, (w) async {
      final existing = w.snapshot?.id == id ? w.snapshot : (w.previous?.id == id ? w.previous : null);
      if (existing != null) {
        final stored = await _stored(w.snapFile(id), info);
        if (_same(stored, body) && _sameCovers(existing.covers, covers)) return _Out.json(200, {'id': id});
        throw _HttpError(409, 'snapshot id in use');
      }
      for (final e in covers.entries) {
        if (e.value > (w.devices[e.key]?.last ?? 0)) throw _HttpError(422, 'covers beyond last');
      }
      final cur = w.snapshot;
      if (cur != null) {
        for (final e in cur.covers.entries) {
          if ((covers[e.key] ?? 0) < e.value) throw _HttpError(409, 'does not dominate');
        }
      }
      // Snapshots are what frees room, so only the kept snapshots (and the blobs) count here, not the files they will prune.
      if ((cur?.size ?? 0) + w.blobBytes + body.length > maxBytes) throw _HttpError(507, 'wallet full');
      await writeAtomic(w.snapFile(id), body);
      final dropped = w.previous;
      w.previous = cur;
      w.snapshot = Snap(id, covers, body.length);
      w.bytes += body.length;
      await w.saveMeta();
      if (dropped != null) {
        w.bytes -= dropped.size;
        for (final f in [w.snapFile(dropped.id), w.setFile(dropped.id)]) {
          try {
            await f.delete();
          } on FileSystemException {
            // already gone (or never declared)
          }
        }
      }
      await w.prune(_now());
      return _Out.json(201, {'id': id});
    });
  }

  /// `PUT snapshot/<id>/blobs`: the declared set of a kept snapshot (RELAY_PROTOCOL.md "Blob garbage collection"),
  /// stored once; a new one runs the blob GC.
  Future<_Out> _putBlobSet(HttpRequest req, String wid, String id, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    final body = await _readBody(req, maxBlobSetBytes, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    _admit(known, sig);
    final set = parseBlobSet(body);
    if (set == null) throw _HttpError(400, 'bad blob set');
    return _lockedAs(wid, sig, (w) async {
      final snap = w.snapshot?.id == id ? w.snapshot : (w.previous?.id == id ? w.previous : null);
      if (snap == null) throw _HttpError(404, 'no such snapshot');
      if (snap.blobSet case final had?) {
        if (had.length == set.length && had.containsAll(set)) return _Out.json(200, {'id': id});
        throw _HttpError(409, 'blob set already declared');
      }
      await writeAtomic(w.setFile(id), encodeBlobSet(set));
      snap.blobSet = set;
      final gc = await w.collectBlobs(_now());
      if (gc case (final kept, final deleted, final freed)) {
        _log('relay gc kept=$kept deleted=$deleted bytes=$freed w=${info.wid}');
      }
      return _Out.json(201, {'id': id});
    });
  }

  Future<_Out> _getSnapshot(String wid, String id, _LogInfo info, _Sig sig) async {
    final w = _known(wid);
    await _verify(w.pubBytes, sig, sig.method, const []);
    _admit(w, sig);
    return _lockedAs(wid, sig, (w) async {
      if (w.snapshot?.id != id && w.previous?.id != id) throw _HttpError(404, 'no such snapshot');
      final bytes = await _stored(w.snapFile(id), info);
      info.bytes = bytes.length;
      return _Out.octets(bytes);
    });
  }

  Future<_Out> _getBlob(String wid, String hash, _LogInfo info, _Sig sig) async {
    final w = _known(wid);
    await _verify(w.pubBytes, sig, sig.method, const []);
    _admit(w, sig);
    return _lockedAs(wid, sig, (w) async {
      try {
        final bytes = await w.blobFile(hash).readAsBytes();
        info.bytes = bytes.length;
        return _Out.octets(bytes);
      } on PathNotFoundException {
        throw _HttpError(404, 'missing');
      } on FileSystemException {
        throw _HttpError(500, 'storage');
      }
    });
  }

  Future<_Out> _putBlob(HttpRequest req, String wid, String hash, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    final body = await _readBody(req, maxFileBytes, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    _admit(known, sig);
    if (sha256OfBytes(body) != hash) throw _HttpError(400, 'hash');
    return _lockedAs(wid, sig, (w) async {
      final file = w.blobFile(hash);
      if (await file.exists()) {
        // A re-upload refreshes the stored time, which only ever delays GC (a client re-PUTs before ops that reference it).
        await _touch(file, body);
        return _Out.json(200, {'hash': hash});
      }
      if (w.totalBytes + body.length > maxBytes) throw _HttpError(507, 'wallet full');
      await writeAtomic(file, body);
      w.blobCount++;
      w.blobBytes += body.length;
      await _touch(file, body);
      return _Out.json(201, {'hash': hash});
    });
  }

  /// Sets a blob's stored time (its modification time) to the relay clock. If that fails, the file is written again
  /// (temp + rename: a new modification time, the file's own clock); if that fails too, 500, so the client's ops wait
  /// for a later PUT. Never an old stored time behind a success answer (GC would see the file as older than it is).
  Future<void> _touch(File f, List<int> body) async {
    try {
      final hook = hooks?.touchBlob;
      if (hook != null) {
        await hook(f, _now());
      } else {
        await f.setLastModified(_now());
      }
      return;
    } on FileSystemException {
      // rewritten below
    }
    try {
      await writeAtomic(f, body);
    } on FileSystemException {
      throw _HttpError(500, 'storage');
    }
  }

  /// api 4: clients never delete blobs (only [Wallet.collectBlobs] does), so a DELETE (an api-3 app's) is answered 204
  /// and changes nothing.
  Future<_Out> _deleteBlob(HttpRequest req, String wid, String hash, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    final body = await _readBody(req, _maxJsonBytes, info);
    if (body.isNotEmpty) throw _HttpError(400, 'body not allowed');
    await _verify(known.pubBytes, sig, 'DELETE', body);
    _admit(known, sig);
    return _Out.empty(204);
  }

  // ---- device keys (api 5) --------------------------------------------------------------------------------------------

  /// Bodies of the device endpoints (`enrol`, `devices/<fp>`, `lock`).
  static const int _maxDeviceJson = 1024;

  /// The device endpoints need a device key: 401 `device` (body drained) for a wallet-key request.
  Future<void> _needDevice(HttpRequest req, _Sig sig) async {
    if (sig.dev == null) await _refuseBody(req, _maxDeviceJson, 401, 'device');
  }

  /// `PUT enrol` (RELAY_PROTOCOL.md "Device keys"): signed by the new device key and countersigned by the wallet key.
  Future<_Out> _enrol(HttpRequest req, String wid, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    await _needDevice(req, sig);
    if (sig.wsig == null) await _refuseBody(req, _maxDeviceJson, 401, 'unsigned');
    final body = await _readBody(req, _maxDeviceJson, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    await _verifyWallet(known.pubBytes, sig, 'PUT', body);
    final raw = _jsonMap(body);
    final id = raw['deviceId'];
    if (raw.keys.any((k) => k != 'deviceId') || (id != null && (id is! String || !namePattern.hasMatch(id)))) {
      throw _HttpError(400, 'bad enrol');
    }
    final deviceId = id as String?;
    final dev = sig.dev!;
    final fp = fingerprint(sig.devBytes!);
    return _locked(wid, () async {
      final w = _known(wid);
      final k = w.keys[dev];
      if (k != null) {
        if (k.revoked != null) throw _HttpError(401, 'revoked');
        return _Out.json(200, {'enrolled': true});
      }
      final now = _now();
      final expired = w.dropExpired(now);
      final other = w.keyOf(fp);
      if (other != null && other != dev) {
        if (expired) await w.saveMeta();
        throw _HttpError(409, 'fingerprint');
      }
      if (!w.locked) {
        w.pending.remove(dev);
        w.keys[dev] = DeviceKey(fp, now, 'wallet', deviceId: deviceId);
        await w.saveMeta();
        _log('relay keys enrolled=${w.activeKeys} pending=${w.pending.length} w=${info.wid}');
        return _Out.json(201, {'enrolled': true});
      }
      if (w.pending.containsKey(dev)) {
        if (expired) await w.saveMeta();
        return _Out.json(202, {'pending': true});
      }
      if (w.pending.length >= maxPending) {
        if (expired) await w.saveMeta();
        throw _HttpError(409, 'pendingFull');
      }
      w.pending[dev] = PendingKey(fp, now, deviceId);
      await w.saveMeta();
      _log('relay keys enrolled=${w.activeKeys} pending=${w.pending.length} w=${info.wid}');
      return _Out.json(202, {'pending': true});
    });
  }

  /// `PUT devices/<fp>` `{"approve":true}` or `{"revoke":true}`, by an enrolled device key.
  Future<_Out> _putDevice(HttpRequest req, String wid, String fp, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    await _needDevice(req, sig);
    final body = await _readBody(req, _maxDeviceJson, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    _admit(known, sig);
    final raw = _jsonMap(body);
    if (raw.length != 1 || raw.values.single != true || !(raw.containsKey('approve') || raw.containsKey('revoke'))) {
      throw _HttpError(400, 'bad device change');
    }
    final approve = raw.containsKey('approve');
    info.kind = approve ? 'approve' : 'revoke';
    return _lockedAs(wid, sig, (w) async {
      final now = _now();
      var changed = w.dropExpired(now);
      final target = w.keyOf(fp);
      if (target == null) {
        if (changed) await w.saveMeta();
        throw _HttpError(404, 'no such key');
      }
      final k = w.keys[target];
      var status = 201;
      if (approve) {
        if (k?.revoked != null) {
          if (changed) await w.saveMeta();
          throw _HttpError(409, 'revoked');
        }
        if (k != null) {
          status = 200;
        } else {
          final p = w.pending.remove(target)!;
          w.keys[target] = DeviceKey(p.fp, now, sig.dev!, deviceId: p.deviceId);
          changed = true;
        }
      } else {
        status = 200;
        if (k == null) {
          // A pending key rejected: recorded as revoked, so it can never enrol.
          final p = w.pending.remove(target)!;
          w.keys[target] = DeviceKey(p.fp, now, sig.dev!, revoked: now, deviceId: p.deviceId);
          changed = true;
        } else if (k.revoked == null) {
          if (w.activeKeys <= 1) {
            if (changed) await w.saveMeta();
            throw _HttpError(409, 'lastDevice');
          }
          k.revoked = now;
          // A removed device still holds the wallet key: without the lock it would enrol a fresh device key at once.
          w.locked = true;
          final t = int.parse(sig.time);
          if (t > w.lockTime) w.lockTime = t;
          changed = true;
        }
      }
      if (changed) await w.saveMeta();
      _log('relay keys enrolled=${w.activeKeys} pending=${w.pending.length} w=${info.wid}');
      return _Out.json(status, {'fp': fp, 'status': w.keys[target]!.revoked == null ? 'enrolled' : 'revoked'});
    });
  }

  /// `PUT lock` `{"locked":bool}`, by an enrolled device key; applied only when signed later than the last change.
  Future<_Out> _putLock(HttpRequest req, String wid, _LogInfo info, _Sig sig) async {
    final known = _known(wid);
    await _needDevice(req, sig);
    final body = await _readBody(req, _maxDeviceJson, info);
    await _verify(known.pubBytes, sig, 'PUT', body);
    _admit(known, sig);
    final raw = _jsonMap(body);
    final v = raw['locked'];
    if (raw.length != 1 || v is! bool) throw _HttpError(400, 'bad lock');
    final t = int.parse(sig.time);
    return _lockedAs(wid, sig, (w) async {
      if (t > w.lockTime) {
        w.lockTime = t;
        w.locked = v;
        await w.saveMeta();
      }
      return _Out.json(200, {'locked': w.locked});
    });
  }

  static Map<String, int> _parseCovers(String? header) {
    if (header == null) throw _HttpError(400, 'missing X-BW-Covers');
    try {
      final v = jsonDecode(header);
      if (v is Map<String, Object?>) {
        final out = <String, int>{};
        for (final e in v.entries) {
          final n = e.value;
          if (!namePattern.hasMatch(e.key) || n is! int || n < 0 || n > maxSeq) throw const FormatException();
          out[e.key] = n;
        }
        return out;
      }
    } on FormatException {
      // fall through
    }
    throw _HttpError(400, 'bad X-BW-Covers');
  }

  static bool _sameCovers(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
