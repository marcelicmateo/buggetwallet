// What only a browser can show: the relay transport builds and signs its request there (Ed25519, SHA-256, `package:http` on the
// web), with a fake HTTP client and no network, and the device-id slot of the browser key store is real localStorage.
// Run with `make web-test`. SYNTHETIC key.
@TestOn('browser')
library;

import 'package:budget_wallet/src/key_store_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';
import 'package:web/web.dart' as web;

void main() {
  test('a RelayTransport request to a local relay address is built and signed in the browser', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((request) async {
      seen.add(request);
      return http.Response('{"error":"missing"}', 404);
    });
    final key = VaultKey.generate();
    final now = DateTime.utc(2026, 10, 28, 12);
    final relay = RelayTransport(Uri.parse('http://127.0.0.1:8080'), key, client: client, now: () => now);
    await relay.state(); // 404 = a wallet the relay does not know yet
    expect(seen, hasLength(1));
    final r = seen.single;
    final (wid, pub) = await relay.ids;
    expect(r.method, 'GET');
    expect(r.url.origin, 'http://127.0.0.1:8080');
    expect(r.url.path, '/v2/w/$wid/state');
    expect(r.headers['X-BW-Time'], '${now.millisecondsSinceEpoch}');
    expect(r.headers['X-BW-Sig'], isNotEmpty);
    expect(r.headers.values.join(), isNot(contains(await key.toText())));
    expect(pub, isNotEmpty);
  });

  test('a relay on an https origin is reached the same way', () async {
    Uri? url;
    final client = MockClient((request) async {
      url = request.url;
      return http.Response('{"error":"missing"}', 404);
    });
    final relay = RelayTransport(Uri.parse('https://relay.example.test'), VaultKey.generate(), client: client);
    await relay.state();
    expect(url!.origin, 'https://relay.example.test');
  });

  test('the browser key store keeps the device id in localStorage bw.deviceId and forget removes it', () async {
    web.window.localStorage.removeItem('bw.deviceId');
    final store = KeyStore();
    expect(await store.readDeviceId(), isNull);
    await store.writeDeviceId('abc123DEF456');
    expect(web.window.localStorage.getItem('bw.deviceId'), 'abc123DEF456');
    expect(await store.readDeviceId(), 'abc123DEF456');
    await store.forget();
    expect(web.window.localStorage.getItem('bw.deviceId'), isNull);
  });
}
