// Body limits before buffering (stage R review L7): a PUT that cannot create a wallet is refused before its body is
// read, and one client address cannot make the relay buffer more than `maxInFlightBytes` across concurrent requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'support.dart';

/// A raw HTTP PUT that declares [length] body bytes but sends only [part] (the socket stays open). Signed for a body
/// of [length] zero bytes: callers send zeros only.
Future<Socket> rawPut(Harness h, String path, int length, List<int> part) async {
  final sig = await h.sign(keyA, 'PUT', path, Uint8List(length));
  final s = await Socket.connect('127.0.0.1', h.server.port);
  final head = [for (final e in sig.entries) '${e.key}: ${e.value}\r\n'].join();
  s.write('PUT $path HTTP/1.1\r\nHost: ${h.base.authority}\r\n${head}Content-Length: $length\r\n\r\n');
  s.add(part);
  await s.flush();
  return s;
}

/// The status code of the first answer on [s].
Future<int> statusOf(Socket s) async {
  final head = latin1.decode(await s.first.timeout(const Duration(seconds: 10)));
  return int.parse(head.split(' ')[1]);
}

void main() {
  group('unknown wallet: refused without buffering the body', () {
    test('seq other than 1 is 422 and the body is never buffered; nothing is created', () async {
      final h = await freshHarness();
      var held = 0;
      h.relay.onHold = (total) => held = total;
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/2', key: keyA, body: Uint8List(8 << 20))).statusCode, 422);
      expect(held, 0);
      expect(h.relay.walletCount, 0);
    });

    test('a full relay is 507 and the body is never buffered', () async {
      final h = await freshHarness(maxWallets: 1);
      expect((await h.putData(wid(1), 'dev1', 1, 'a')).statusCode, 201);
      var held = 0;
      h.relay.onHold = (total) => held = total;
      expect((await h.send('PUT', '/v2/w/${wid(2)}/d/dev1/1', key: keyA, body: Uint8List(8 << 20))).statusCode, 507);
      expect(held, 0);
      expect(h.relay.walletCount, 1);
    });

    test('a client that sends the whole body still reads the status', () async {
      final h = await freshHarness(maxWallets: 1);
      final big = Uint8List(8 << 20);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/3', key: keyA, body: big)).statusCode, 422);
      expect((await h.putData(wid(1), 'dev1', 1, 'a')).statusCode, 201);
      expect((await h.send('PUT', '/v2/w/${wid(2)}/d/dev1/1', key: keyA, body: big)).statusCode, 507);
      expect(h.relay.walletCount, 1);
      // The relay still answers normally afterwards.
      expect((await h.putData(wid(1), 'dev1', 2, 'b')).statusCode, 201);
    });

    test('seq 1 of an unknown wallet is still created', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
      expect(h.relay.walletCount, 1);
    });
  });

  group('in-flight body bytes per client address', () {
    late Harness h;
    setUp(() async {
      h = await Harness.start(maxInFlightBytes: 1 << 20);
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
    });

    test('a second concurrent body past the cap is 429; after the first one ends it is accepted', () async {
      final held = Completer<void>();
      h.relay.onHold = (total) {
        if (total >= 800 << 10 && !held.isCompleted) held.complete();
      };
      final first = await rawPut(h, '/v2/w/$w1/d/dev1/2', 900 << 10, Uint8List(800 << 10));
      await held.future.timeout(const Duration(seconds: 10));
      h.relay.onHold = null;
      final second = Uint8List(600 << 10);
      final r = await h.send('PUT', '/v2/w/$w1/d/dev2/1', key: keyA, body: second);
      expect(r.statusCode, 429);
      expect(r.headers['retry-after'], '1');
      first.add(Uint8List(100 << 10));
      await first.flush();
      expect(await statusOf(first), 201);
      first.destroy();
      expect((await h.send('PUT', '/v2/w/$w1/d/dev2/1', key: keyA, body: second)).statusCode, 201);
    });

    test('a lone request larger than the cap is limited only by its own size limit', () async {
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/2', key: keyA, body: Uint8List(3 << 20))).statusCode, 201);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/3', key: keyA, body: Uint8List(2 << 20))).statusCode, 201);
    });
  });
}
