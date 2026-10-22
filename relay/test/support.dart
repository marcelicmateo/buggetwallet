import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:relay/relay.dart';
import 'package:test/test.dart';

/// Synthetic ids only.
const String w1 = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const String w2 = '00112233445566778899aabbccddeeff';
const String tokenA = 'synthetic-token-A_0123456789';
const String tokenB = 'synthetic-token-B_9876543210';

String wid(int n) => n.toRadixString(16).padLeft(32, '0');

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

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

  static Future<Harness> start({
    int maxWallets = 16,
    int maxBytes = 1024 * 1024 * 1024,
    List<String>? origins,
    Directory? dir,
    DateTime? clock,
  }) async {
    final h = Harness._(dir ?? await Directory.systemTemp.createTemp('relay-test-'), clock ?? DateTime.utc(2026, 10, 22, 10));
    h._origins = origins;
    h._maxWallets = maxWallets;
    h._maxBytes = maxBytes;
    await h._boot();
    return h;
  }

  List<String>? _origins;
  late int _maxWallets;
  late int _maxBytes;

  Future<void> _boot() async {
    relay = Relay(
      data: dir,
      origins: _origins ?? defaultOrigins,
      maxWallets: _maxWallets,
      maxBytes: _maxBytes,
      now: () => clock,
      log: logs.add,
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

  Future<http.Response> send(
    String method,
    String path, {
    String? token,
    List<int>? body,
    Map<String, String> headers = const {},
  }) async {
    final req = http.Request(method, base.resolve(path));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    req.headers.addAll(headers);
    if (body != null) req.bodyBytes = body;
    return http.Response.fromStream(await client.send(req));
  }

  Future<http.Response> get(String path, {String? token, Map<String, String> headers = const {}}) =>
      send('GET', path, token: token, headers: headers);

  Future<http.Response> putData(String wallet, String device, int seq, String body, {String? token = tokenA}) =>
      send('PUT', '/v1/w/$wallet/d/$device/$seq', token: token, body: bytes(body));

  Future<http.Response> getData(String wallet, String device, int seq, {String? token = tokenA}) =>
      get('/v1/w/$wallet/d/$device/$seq', token: token);

  Future<http.Response> ack(String wallet, String device, Map<String, Object?> acks, {String? token = tokenA}) =>
      send('PUT', '/v1/w/$wallet/ack/$device', token: token, body: bytes(jsonEncode(acks)));

  Future<http.Response> putSnapshot(String wallet, String id, Map<String, int> covers, String body, {String? token = tokenA}) =>
      send('PUT', '/v1/w/$wallet/snapshot/$id', token: token, body: bytes(body), headers: {'x-bw-covers': jsonEncode(covers)});

  Future<http.Response> getSnapshot(String wallet, String id, {String? token = tokenA}) => get('/v1/w/$wallet/snapshot/$id', token: token);

  Future<Map<String, Object?>> state(String wallet, {String token = tokenA}) async {
    final r = await get('/v1/w/$wallet/state', token: token);
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
