import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'rate_limit.dart';
import 'wallet.dart';

const int _mib = 1024 * 1024;

/// Largest sealed op file.
const int maxFileBytes = 16 * _mib;

/// Largest snapshot.
const int maxSnapshotBytes = 64 * _mib;

const int _maxJsonBytes = 64 * 1024;

/// Default for [Relay.maxInFlightBytes]: request body bytes one client address may have buffered at once.
const int defaultMaxInFlightBytes = 32 * _mib;
const List<String> defaultOrigins = ['http://127.0.0.1:8080', 'http://localhost:8080'];

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

/// The relay: HTTP API v1 over a data folder (docs/context/RELAY_PROTOCOL.md). It stores sealed files it cannot read.
class Relay {
  Relay({
    required this.data,
    this.origins = defaultOrigins,
    this.maxWallets = 16,
    this.maxBytes = 1024 * _mib,
    this.maxInFlightBytes = defaultMaxInFlightBytes,
    DateTime Function()? now,
    void Function(String line)? log,
  })  : _now = now ?? DateTime.now,
        _log = log ?? stdout.writeln;

  final Directory data;
  final List<String> origins;
  final int maxWallets;
  final int maxBytes;

  /// Body bytes one client address may have buffered across its concurrent requests; a request that would pass it
  /// while others from that address hold bytes gets 429 (a lone request is limited only by its own size limit).
  final int maxInFlightBytes;
  final DateTime Function() _now;
  final void Function(String) _log;

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
      final w = await Wallet.load(ent, wid, _now());
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
      if (origin != null && origins.contains(origin)) {
        res.headers.set('Access-Control-Allow-Origin', origin);
        if (req.method == 'OPTIONS') {
          res.headers.set('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS');
          res.headers.set('Access-Control-Allow-Headers', 'Authorization, Content-Type, X-BW-Covers');
          res.headers.set('Access-Control-Max-Age', '600');
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
    final remote = req.connectionInfo?.remoteAddress.address ?? '?';
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
    if (seg.length < 2 || seg[0] != 'v1') throw _HttpError(404, 'not found');
    if (seg[1] == 'health' && seg.length == 2) {
      info.kind = 'health';
      _method(req, ['GET']);
      return _Out.json(200, {'api': 1});
    }
    if (seg[1] != 'w' || seg.length < 4) throw _HttpError(404, 'not found');
    final wid = seg[2];
    if (!widPattern.hasMatch(wid)) throw _HttpError(400, 'bad wallet id');
    info.wid = wid.substring(0, 6);
    final route = seg[3];
    switch ((route, seg.length)) {
      case ('state', 4):
        info.kind = 'state';
        _method(req, ['GET']);
        return _getState(req, wid);
      case ('d', 6):
        final device = _name(seg[4], 'bad device');
        info.device = _short(device);
        final seq = parseSeq(seg[5]);
        if (seq == null) throw _HttpError(400, 'bad seq');
        _method(req, ['GET', 'PUT']);
        if (req.method == 'GET') {
          info.kind = 'get-d';
          return _getData(req, wid, device, seq, info);
        }
        info.kind = 'put-d';
        return _putData(req, wid, device, seq, info);
      case ('ack', 5):
        final device = _name(seg[4], 'bad device');
        info.device = _short(device);
        info.kind = 'ack';
        _method(req, ['PUT']);
        return _putAck(req, wid, device, info);
      case ('snapshot', 5):
        final id = _name(seg[4], 'bad snapshot id');
        _method(req, ['GET', 'PUT']);
        if (req.method == 'GET') {
          info.kind = 'get-snap';
          return _getSnapshot(req, wid, id, info);
        }
        info.kind = 'put-snap';
        return _putSnapshot(req, wid, id, info);
    }
    throw _HttpError(404, 'not found');
  }

  static String _short(String name) => name.length > 6 ? name.substring(0, 6) : name;

  static void _method(HttpRequest req, List<String> allowed) {
    if (!allowed.contains(req.method)) throw _HttpError(405, 'method not allowed');
  }

  static String _name(String s, String error) {
    if (!namePattern.hasMatch(s)) throw _HttpError(400, error);
    return s;
  }

  // ---- auth ---------------------------------------------------------------------------------------------------------

  /// The bearer token of the request; 401 when absent or malformed.
  static String _bearer(HttpRequest req) {
    final h = req.headers.value('authorization');
    if (h != null && h.length > 7 && h.substring(0, 7).toLowerCase() == 'bearer ') {
      final t = h.substring(7).trim();
      if (t.isNotEmpty && t.length <= 512 && !t.contains(' ')) return t;
    }
    throw _HttpError(401, 'unauthorized');
  }

  /// Looks up a known wallet for a read or ack: 404 unknown, 401 wrong or missing token.
  Wallet _known(HttpRequest req, String wid) {
    final w = _wallets[wid];
    if (w == null) throw _HttpError(404, 'unknown wallet');
    if (!constantTimeEquals(sha256Hex(_bearer(req)), w.tokenHash)) throw _HttpError(401, 'unauthorized');
    return w;
  }

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

  Future<Map<String, Object?>> _readJsonMap(HttpRequest req, _LogInfo info) async {
    final body = await _readBody(req, _maxJsonBytes, info);
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

  Future<_Out> _getState(HttpRequest req, String wid) {
    final w = _known(req, wid);
    return _locked(wid, () async => _Out.json(200, w.stateJson()));
  }

  Future<_Out> _getData(HttpRequest req, String wid, String device, int seq, _LogInfo info) {
    final w = _known(req, wid);
    return _locked(wid, () async {
      final st = w.devices[device];
      if (st == null || seq > st.last) throw _HttpError(404, 'not stored');
      if (seq < st.first) throw _HttpError(410, 'pruned');
      try {
        final bytes = await w.dataFile(device, seq).readAsBytes();
        info.bytes = bytes.length;
        return _Out.octets(bytes);
      } on FileSystemException {
        throw _HttpError(500, 'storage');
      }
    });
  }

  Future<_Out> _putData(HttpRequest req, String wid, String device, int seq, _LogInfo info) async {
    final token = _bearer(req);
    final hash = sha256Hex(token);
    final known = _wallets[wid];
    if (known != null && !constantTimeEquals(hash, known.tokenHash)) throw _HttpError(401, 'unauthorized');
    if (known == null) {
      // An unknown wallet: refuse what cannot create it before reading (and buffering) a body. Checked again in the lock.
      if (seq != 1) await _refuseBody(req, maxFileBytes, 422, 'seq beyond last + 1');
      if (_wallets.length >= maxWallets) await _refuseBody(req, maxFileBytes, 507, 'relay full');
    }
    final body = await _readBody(req, maxFileBytes, info);
    return _locked(wid, () async {
      final w = _wallets[wid];
      if (w != null && !constantTimeEquals(hash, w.tokenHash)) throw _HttpError(401, 'unauthorized');
      if (w == null) return _createWallet(wid, hash, device, seq, body);
      final st = w.devices[device];
      final first = st?.first ?? 1;
      final last = st?.last ?? 0;
      if (seq <= last) {
        // Known device: it is alive whatever the answer.
        st!.lastSeen = _now();
        await w.saveMeta();
        if (seq < first) throw _HttpError(410, 'pruned');
        final stored = await w.dataFile(device, seq).readAsBytes();
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
      if (w.bytes + body.length > maxBytes) throw _HttpError(507, 'wallet full');
      await writeAtomic(w.dataFile(device, seq), body);
      w.bytes += body.length;
      final dev = w.devices.putIfAbsent(device, () => DeviceState(_now()));
      dev.last = seq;
      dev.lastSeen = _now();
      await w.saveMeta();
      await w.prune(_now());
      return _Out.json(201, {'seq': seq});
    });
  }

  /// The first accepted `PUT d/...` of a wallet creates it and sets its token hash (trust on first use).
  Future<_Out> _createWallet(String wid, String hash, String device, int seq, Uint8List body) async {
    if (seq != 1) throw _HttpError(422, 'seq beyond last + 1');
    if (_wallets.length >= maxWallets) throw _HttpError(507, 'relay full');
    if (body.length > maxBytes) throw _HttpError(507, 'wallet full');
    final dir = Directory('${data.path}/$wid');
    final w = Wallet(wid, dir, hash);
    _wallets[wid] = w; // reserve the slot before any await
    try {
      if (await dir.exists()) await dir.delete(recursive: true); // left over from an interrupted creation
      await writeAtomic(w.dataFile(device, 1), body);
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

  Future<_Out> _putAck(HttpRequest req, String wid, String device, _LogInfo info) async {
    _known(req, wid);
    final raw = await _readJsonMap(req, info);
    final acks = <String, int>{};
    for (final e in raw.entries) {
      final v = e.value;
      if (!namePattern.hasMatch(e.key) || v is! int || v < 0 || v > maxSeq) throw _HttpError(400, 'bad ack');
      acks[e.key] = v;
    }
    return _locked(wid, () async {
      final w = _known(req, wid);
      for (final e in acks.entries) {
        if (e.value > (w.devices[e.key]?.last ?? 0)) throw _HttpError(422, 'ack beyond last');
      }
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

  Future<_Out> _putSnapshot(HttpRequest req, String wid, String id, _LogInfo info) async {
    _known(req, wid);
    final covers = _parseCovers(req.headers.value('x-bw-covers'));
    final body = await _readBody(req, maxSnapshotBytes, info);
    return _locked(wid, () async {
      final w = _known(req, wid);
      final existing = w.snapshot?.id == id ? w.snapshot : (w.previous?.id == id ? w.previous : null);
      if (existing != null) {
        final stored = await w.snapFile(id).readAsBytes();
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
      // Snapshots are what frees room, so only the kept snapshots count here, not the files they will prune.
      if ((cur?.size ?? 0) + body.length > maxBytes) throw _HttpError(507, 'wallet full');
      await writeAtomic(w.snapFile(id), body);
      final dropped = w.previous;
      w.previous = cur;
      w.snapshot = Snap(id, covers, body.length);
      w.bytes += body.length;
      await w.saveMeta();
      if (dropped != null) {
        w.bytes -= dropped.size;
        try {
          await w.snapFile(dropped.id).delete();
        } on FileSystemException {
          // already gone
        }
      }
      await w.prune(_now());
      return _Out.json(201, {'id': id});
    });
  }

  Future<_Out> _getSnapshot(HttpRequest req, String wid, String id, _LogInfo info) {
    final w = _known(req, wid);
    return _locked(wid, () async {
      if (w.snapshot?.id != id && w.previous?.id != id) throw _HttpError(404, 'no such snapshot');
      try {
        final bytes = await w.snapFile(id).readAsBytes();
        info.bytes = bytes.length;
        return _Out.octets(bytes);
      } on FileSystemException {
        throw _HttpError(500, 'storage');
      }
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
