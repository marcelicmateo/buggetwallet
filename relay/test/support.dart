import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:relay/relay.dart';
import 'package:test/test.dart';

/// Synthetic ids only.
const String w1 = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const String w2 = '00112233445566778899aabbccddeeff';

/// Synthetic signing keys (fixed seeds, derived from no wallet key).
final TestKey keyA = TestKey(List<int>.generate(32, (i) => 0xA0 ^ i));
final TestKey keyB = TestKey(List<int>.generate(32, (i) => 0xB0 ^ i));

String wid(int n) => n.toRadixString(16).padLeft(32, '0');

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

/// An Ed25519 key pair from a synthetic seed: signs requests the way the client does (written from
/// docs/context/RELAY_PROTOCOL.md, independently of the relay's code).
class TestKey {
  TestKey(this.seed);

  final List<int> seed;
  late final Future<SimpleKeyPair> _pair = Ed25519().newKeyPairFromSeed(seed);

  /// The public key as `X-BW-Pub` sends it.
  Future<String> pub() async => _b64((await (await _pair).extractPublicKey()).bytes);

  /// base64url signature over [text].
  Future<String> sign(String text) async => _b64((await Ed25519().sign(utf8.encode(text), keyPair: await _pair)).bytes);

  /// The v3 signature headers for one request to [host] (what the client addressed: lower case, `:port` unless the
  /// default). [covers] is the `X-BW-Covers` value ('' when none).
  Future<Map<String, String>> headers(String method, String path, List<int> body,
      {required int timeMs, required String host, String covers = '', bool withPub = true}) async {
    final hash = _hex((await Sha256().hash(body)).bytes);
    final text = 'bw-relay-v3\n$method\n$host\n$path\n$covers\n$hash\n$timeMs';
    return {
      'x-bw-time': '$timeMs',
      'x-bw-sig': await sign(text),
      if (withPub) 'x-bw-pub': await pub(),
    };
  }
}

/// A relay on a free port over a temp folder with a controllable clock and a captured log.
class Harness {
  Harness._(this.dir, this.clock);

  final Directory dir;
  DateTime clock;
  final List<String> logs = [];
  late Relay relay;
  late HttpServer server;
  late Uri base;
  final http.Client client = http.Client();

  /// Added to the relay clock for `X-BW-Time` of signed requests (a skewed client).
  Duration skew = Duration.zero;

  static Future<Harness> start({
    int maxWallets = 16,
    int maxBytes = 1024 * 1024 * 1024,
    int maxInFlightBytes = defaultMaxInFlightBytes,
    List<String>? origins,
    Directory? dir,
    DateTime? clock,
    String? publicHost,
    RelayTestHooks? hooks,
  }) async {
    final h = Harness._(dir ?? await Directory.systemTemp.createTemp('relay-test-'), clock ?? DateTime.utc(2026, 10, 22, 10));
    h._origins = origins;
    h._maxWallets = maxWallets;
    h._maxBytes = maxBytes;
    h._maxInFlight = maxInFlightBytes;
    h.publicHost = publicHost;
    h.hooks = hooks;
    await h._boot();
    return h;
  }

  List<String>? _origins;
  late int _maxWallets;
  late int _maxBytes;
  late int _maxInFlight;

  /// Passed to [Relay] on every boot (tests may change them before [restart]).
  String? publicHost;
  RelayTestHooks? hooks;

  /// The host signed requests name: `127.0.0.1:<port>` unless a test sets another one (a request meant for another
  /// relay).
  String? signHost;

  Future<void> _boot() async {
    relay = Relay(
      data: dir,
      origins: _origins ?? defaultOrigins,
      maxWallets: _maxWallets,
      maxBytes: _maxBytes,
      maxInFlightBytes: _maxInFlight,
      now: () => clock,
      log: logs.add,
      publicHost: publicHost,
      hooks: hooks,
    );
    server = await relay.serve(port: 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
  }

  /// Stops the relay and starts a new one over the same folder (state must come back from disk).
  Future<void> restart() async {
    await relay.close();
    await _boot();
  }

  Future<void> stop({bool deleteData = true}) async {
    client.close();
    await relay.close();
    if (deleteData) await dir.delete(recursive: true);
  }

  void advance(Duration d) => clock = clock.add(d);

  /// The signature headers [key] would send now for this request ([path] from `/v2/` on).
  Future<Map<String, String>> sign(TestKey key, String method, String path, List<int> body, {String covers = '', bool withPub = true}) =>
      key.headers(method, path, body,
          timeMs: clock.add(skew).millisecondsSinceEpoch, host: signHost ?? base.authority, covers: covers, withPub: withPub);

  /// Sends a request signed with [key] (unsigned when null); [headers] are added after the signature headers, so a
  /// test can override them.
  Future<http.Response> send(
    String method,
    String path, {
    TestKey? key,
    List<int>? body,
    Map<String, String> headers = const {},
    bool withPub = true,
  }) async {
    final req = http.Request(method, base.resolve(path));
    if (key != null) {
      req.headers.addAll(
          await sign(key, method, base.resolve(path).path, body ?? const [], covers: headers['x-bw-covers'] ?? '', withPub: withPub));
    }
    req.headers.addAll(headers);
    if (body != null) req.bodyBytes = body;
    return http.Response.fromStream(await client.send(req));
  }

  /// Sends exactly [headers] and [body] again (a captured request replayed by someone without the key).
  Future<http.Response> replay(String method, String path, Map<String, String> headers, {List<int>? body}) async {
    final req = http.Request(method, base.resolve(path))..headers.addAll(headers);
    if (body != null) req.bodyBytes = body;
    return http.Response.fromStream(await client.send(req));
  }

  Future<http.Response> get(String path, {TestKey? key, Map<String, String> headers = const {}}) =>
      send('GET', path, key: key, headers: headers);

  Future<http.Response> putData(String wallet, String device, int seq, String body, {TestKey? key, bool withPub = true}) =>
      send('PUT', '/v2/w/$wallet/d/$device/$seq', key: key ?? keyA, body: bytes(body), withPub: withPub);

  Future<http.Response> getData(String wallet, String device, int seq, {TestKey? key}) =>
      get('/v2/w/$wallet/d/$device/$seq', key: key ?? keyA);

  Future<http.Response> ack(String wallet, String device, Map<String, Object?> acks, {TestKey? key}) =>
      send('PUT', '/v2/w/$wallet/ack/$device', key: key ?? keyA, body: bytes(jsonEncode(acks)));

  Future<http.Response> putSnapshot(String wallet, String id, Map<String, int> covers, String body, {TestKey? key}) =>
      send('PUT', '/v2/w/$wallet/snapshot/$id', key: key ?? keyA, body: bytes(body), headers: {'x-bw-covers': jsonEncode(covers)});

  Future<http.Response> getSnapshot(String wallet, String id, {TestKey? key}) => get('/v2/w/$wallet/snapshot/$id', key: key ?? keyA);

  Future<Map<String, Object?>> state(String wallet, {TestKey? key}) async {
    final r = await get('/v2/w/$wallet/state', key: key ?? keyA);
    expect(r.statusCode, 200, reason: r.body);
    return jsonDecode(r.body) as Map<String, Object?>;
  }

  /// One device's entry of the state JSON.
  Future<Map<String, Object?>> device(String wallet, String name) async {
    final s = await state(wallet);
    return (s['devices'] as Map<String, Object?>)[name] as Map<String, Object?>;
  }
}

/// Starts a [Harness] and stops it when the test ends.
Future<Harness> freshHarness({int maxWallets = 16, int maxBytes = 1024 * 1024 * 1024, List<String>? origins}) async {
  final h = await Harness.start(maxWallets: maxWallets, maxBytes: maxBytes, origins: origins);
  addTearDown(h.stop);
  return h;
}
