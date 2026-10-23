import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('health and routing', () {
    test('health needs no signature and says api 2', () async {
      final h = await freshHarness();
      final r = await h.get('/v2/health');
      expect(r.statusCode, 200);
      expect(jsonDecode(r.body), {'api': 3});
      expect(r.headers['content-type'], contains('application/json'));
    });

    test('unknown paths are 404 and wrong methods 405, both as JSON errors', () async {
      final h = await freshHarness();
      for (final p in ['/', '/v2', '/v1/health', '/v2/w', '/v2/w/$w1', '/v2/w/$w1/nope', '/v2/health/x', '/v2/w/$w1/state/']) {
        final r = await h.get(p);
        expect(r.statusCode, 404, reason: p);
        expect(jsonDecode(r.body), {'error': isA<String>()});
      }
      expect((await h.send('POST', '/v2/health')).statusCode, 405);
      expect((await h.send('POST', '/v2/w/$w1/state', key: keyA)).statusCode, 405);
      expect((await h.send('DELETE', '/v2/w/$w1/d/a/1', key: keyA)).statusCode, 405);
      expect((await h.send('GET', '/v2/w/$w1/ack/a', key: keyA)).statusCode, 405);
    });
  });

  group('names', () {
    test('bad wallet ids are 400', () async {
      final h = await freshHarness();
      for (final bad in ['A1B2C3D4E5F60718293A4B5C6D7E8F90', 'abc', '${w1}0', w1.substring(1), 'g' * 32, '%20' * 11]) {
        expect((await h.get('/v2/w/$bad/state', key: keyA)).statusCode, 400, reason: bad);
      }
    });

    test('bad device names and seqs are 400, and nothing is created', () async {
      final h = await freshHarness();
      for (final bad in ['a.b', 'a b', 'a' * 65, 'a%2Fb', 'ü']) {
        expect((await h.putData(w1, bad, 1, 'x')).statusCode, 400, reason: bad);
        expect((await h.getData(w1, bad, 1)).statusCode, 400, reason: bad);
        expect((await h.ack(w1, bad, {})).statusCode, 400, reason: bad);
      }
      for (final bad in ['0', '01', '-1', '1.5', 'abc', '9007199254740992', '99999999999999999999', '+1', '1e3']) {
        expect((await h.send('PUT', '/v2/w/$w1/d/a/$bad', key: keyA, body: bytes('x'))).statusCode, 400, reason: bad);
        expect((await h.get('/v2/w/$w1/d/a/$bad', key: keyA)).statusCode, 400, reason: bad);
      }
      expect((await h.putSnapshot(w1, 'a b', {}, 'x')).statusCode, 400);
      expect((await h.getSnapshot(w1, 'a' * 65)).statusCode, 400);
      expect(h.relay.walletCount, 0);
    });

    test('the longest names and the highest seq are accepted by the parser', () async {
      final h = await freshHarness();
      final dev = 'D' * 64;
      expect((await h.putData(w1, dev, 1, 'x')).statusCode, 201);
      // 2^53 - 1 is a valid seq (a gap, so 422 rather than 400).
      expect((await h.putData(w1, dev, 9007199254740991, 'x')).statusCode, 422);
      expect((await h.getData(w1, dev, 9007199254740991)).statusCode, 404);
    });
  });

  group('wallet creation (signing details: signing_test.dart)', () {
    test('the first PUT creates the wallet and stores its public key', () async {
      final h = await freshHarness();
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 404);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 200);
    });

    test('a later PUT with another key cannot take over the wallet', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      expect((await h.putData(w1, 'dev2', 1, 'evil', key: keyB)).statusCode, 401);
      expect(((await h.state(w1))['devices'] as Map).keys, ['dev1']);
    });

    test('unknown wallet: every signed GET and the ack and snapshot PUTs are 404', () async {
      final h = await freshHarness();
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 404);
      expect((await h.getData(w1, 'dev1', 1)).statusCode, 404);
      expect((await h.getSnapshot(w1, 's1')).statusCode, 404);
      expect((await h.ack(w1, 'dev1', {})).statusCode, 404);
      expect((await h.putSnapshot(w1, 's1', {}, 'x')).statusCode, 404);
      expect(h.relay.walletCount, 0);
    });

    test('a first PUT with seq above 1 is 422 and creates nothing', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 422);
      expect(h.relay.walletCount, 0);
      expect((await h.get('/v2/w/$w1/state', key: keyB)).statusCode, 404);
    });
  });

  group('PUT d', () {
    test('201, then 200 for the same bytes, 409 for other bytes (never overwritten)', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 200);
      final r = await h.putData(w1, 'dev1', 1, 'ONE');
      expect(r.statusCode, 409);
      expect(jsonDecode(r.body), {'error': isA<String>()});
      expect((await h.getData(w1, 'dev1', 1)).body, 'one');
      expect((await h.putData(w1, 'dev1', 1, 'on')).statusCode, 409); // prefix
      expect((await h.putData(w1, 'dev1', 1, 'one!')).statusCode, 409); // longer
    });

    test('no gaps: seq above last + 1 is 422, last + 1 is 201', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 422);
      expect((await h.getData(w1, 'dev1', 3)).statusCode, 404);
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
      expect((await h.device(w1, 'dev1'))['last'], 3);
    });

    test('a new device in an existing wallet starts at 1, devices count independently', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      expect((await h.putData(w1, 'dev2', 2, 'x')).statusCode, 422);
      expect(((await h.state(w1))['devices'] as Map).keys, ['dev1']); // 422 does not create a device
      expect((await h.putData(w1, 'dev2', 1, 'x')).statusCode, 201);
      expect((await h.device(w1, 'dev2'))['last'], 1);
    });

    test('empty body is a valid sealed file', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, '')).statusCode, 201);
      expect((await h.getData(w1, 'dev1', 1)).bodyBytes, isEmpty);
      expect((await h.putData(w1, 'dev1', 1, '')).statusCode, 200);
    });

    test('binary bytes round-trip unchanged', () async {
      final h = await freshHarness();
      final all = Uint8List.fromList([for (var i = 0; i < 1024; i++) i % 256]);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: all)).statusCode, 201);
      final r = await h.getData(w1, 'dev1', 1);
      expect(r.bodyBytes, all);
      expect(r.headers['content-type'], 'application/octet-stream');
    });

    test('410 for a pruned seq, even with identical bytes', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      expect((await h.putSnapshot(w1, 's1', {'dev1': 2}, 'snap')).statusCode, 201);
      expect((await h.device(w1, 'dev1'))['first'], 3);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 410);
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 410);
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
    });

    test('413 at 16 MiB + 1, 16 MiB itself is fine, and the rejected PUT stores nothing', () async {
      final h = await freshHarness();
      final big = Uint8List(16 * 1024 * 1024 + 1);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: big)).statusCode, 413);
      expect(h.relay.walletCount, 0);
      final ok = Uint8List(16 * 1024 * 1024);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: ok)).statusCode, 201);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/2', key: keyA, body: big)).statusCode, 413);
      expect((await h.device(w1, 'dev1'))['last'], 1);
      // The relay still answers after the rejection.
      expect((await h.get('/v2/health')).statusCode, 200);
    });

    test('413 also when the length is not announced (chunked)', () async {
      final h = await freshHarness();
      final chunk = Uint8List(1024 * 1024);
      final req = http.StreamedRequest('PUT', h.base.resolve('/v2/w/$w1/d/dev1/1'))
        ..headers.addAll(await h.sign(keyA, 'PUT', '/v2/w/$w1/d/dev1/1', Uint8List(17 * chunk.length)));
      final send = h.client.send(req);
      for (var i = 0; i < 17; i++) {
        req.sink.add(chunk);
      }
      await req.sink.close();
      final r = await http.Response.fromStream(await send);
      expect(r.statusCode, 413);
      expect(h.relay.walletCount, 0);
    });

    test('concurrent PUTs of one seq: exactly one wins, the rest see 409 or 200', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final rs = await Future.wait([
        for (var i = 0; i < 12; i++) h.putData(w1, 'dev1', 2, 'v${i % 3}'),
      ]);
      expect(rs.where((r) => r.statusCode == 201), hasLength(1));
      final winner = (await h.getData(w1, 'dev1', 2)).body;
      for (var i = 0; i < 12; i++) {
        expect(rs[i].statusCode, anyOf(201, 200, 409));
        if (rs[i].statusCode == 200 || rs[i].statusCode == 201) expect('v${i % 3}', winner);
      }
    });

    test('concurrent PUTs of consecutive seqs: all land in order or get 422', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final rs = await Future.wait([for (var s = 2; s <= 9; s++) h.putData(w1, 'dev1', s, 's$s')]);
      final stored = rs.where((r) => r.statusCode == 201).length;
      final last = (await h.device(w1, 'dev1'))['last'] as int;
      expect(last, stored + 1);
      for (var s = 1; s <= last; s++) {
        expect((await h.getData(w1, 'dev1', s)).statusCode, 200);
      }
    });

    test('a PUT refreshes the device lastSeen', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      expect((await h.device(w1, 'dev1'))['lastSeen'], '2026-10-22T10:00:00Z');
      h.advance(const Duration(hours: 5, seconds: 7));
      await h.putData(w1, 'dev1', 2, 'two');
      expect((await h.device(w1, 'dev1'))['lastSeen'], '2026-10-22T15:00:07Z');
      h.advance(const Duration(hours: 1));
      await h.putData(w1, 'dev1', 2, 'two'); // 200: the device is alive
      expect((await h.device(w1, 'dev1'))['lastSeen'], '2026-10-22T16:00:07Z');
      h.advance(const Duration(hours: 1));
      await h.putData(w1, 'dev1', 2, 'other'); // 409 too
      expect((await h.device(w1, 'dev1'))['lastSeen'], '2026-10-22T17:00:07Z');
    });
  });

  group('GET d', () {
    test('200 bytes, 404 never stored, 410 pruned', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      expect((await h.getData(w1, 'dev1', 2)).body, 'two');
      expect((await h.getData(w1, 'dev1', 3)).statusCode, 404);
      expect((await h.getData(w1, 'nobody', 1)).statusCode, 404);
      await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snap');
      expect((await h.getData(w1, 'dev1', 1)).statusCode, 410);
      expect((await h.getData(w1, 'dev1', 2)).statusCode, 200);
      await h.putSnapshot(w1, 's2', {'dev1': 2}, 'snap2');
      expect((await h.getData(w1, 'dev1', 2)).statusCode, 200); // the previous snapshot covers only 1
      await h.putSnapshot(w1, 's3', {'dev1': 2}, 'snap3');
      expect((await h.getData(w1, 'dev1', 2)).statusCode, 410);
      expect((await h.getData(w1, 'dev1', 3)).statusCode, 404); // never stored, not pruned
    });

    test('a device known only from an ack has no files: 404', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.ack(w1, 'dev2', {});
      expect((await h.getData(w1, 'dev2', 1)).statusCode, 404);
    });
  });

  group('acks', () {
    test('204, stored per device and peer, and they only grow', () async {
      final h = await freshHarness();
      for (var s = 1; s <= 5; s++) {
        await h.putData(w1, 'dev1', s, 's$s');
      }
      await h.putData(w1, 'dev2', 1, 'x');
      expect((await h.ack(w1, 'dev2', {'dev1': 3})).statusCode, 204);
      expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 3});
      expect((await h.ack(w1, 'dev2', {'dev1': 2})).statusCode, 204);
      expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 3});
      expect((await h.ack(w1, 'dev2', {'dev1': 5})).statusCode, 204);
      expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 5});
      expect((await h.ack(w1, 'dev2', {'dev1': 5, 'dev2': 1})).statusCode, 204);
      expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 5, 'dev2': 1});
    });

    test('an ack above the peer last is 422 and nothing of the request applies', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      await h.putData(w1, 'dev2', 1, 'x');
      expect((await h.ack(w1, 'dev2', {'dev1': 3})).statusCode, 422);
      expect((await h.ack(w1, 'dev2', {'dev1': 2, 'ghost': 1})).statusCode, 422); // unknown peer has last 0
      expect((await h.device(w1, 'dev2'))['acks'], isEmpty);
      expect((await h.ack(w1, 'dev2', {'dev1': 2, 'ghost': 0})).statusCode, 204);
    });

    test('an ack of 0 is accepted and changes nothing', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      expect((await h.ack(w1, 'dev1', {'dev1': 0})).statusCode, 204);
      expect((await h.device(w1, 'dev1'))['acks'], {'dev1': 0});
    });

    test('malformed bodies are 400', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      for (final body in [
        '',
        'nope',
        '[]',
        '"x"',
        '{"dev1": "1"}',
        '{"dev1": 1.5}',
        '{"dev1": -1}',
        '{"dev1": null}',
        '{"a b": 1}',
        '{"dev1": 9007199254740992}'
      ]) {
        final r = await h.send('PUT', '/v2/w/$w1/ack/dev1', key: keyA, body: utf8.encode(body));
        expect(r.statusCode, 400, reason: body);
      }
      expect((await h.send('PUT', '/v2/w/$w1/ack/dev1', key: keyA, body: Uint8List.fromList([0xff, 0xfe]))).statusCode, 400);
    });

    test('an oversized ack body is 413', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final r = await h.send('PUT', '/v2/w/$w1/ack/dev1', key: keyA, body: Uint8List(70 * 1024));
      expect(r.statusCode, 413);
    });

    test('an ack makes the device appear and refreshes lastSeen, even when empty', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      h.advance(const Duration(days: 2));
      expect((await h.ack(w1, 'dev2', {})).statusCode, 204);
      expect(await h.device(w1, 'dev2'), {'first': 1, 'last': 0, 'lastSeen': '2026-10-24T10:00:00Z', 'acks': <String, Object?>{}});
      h.advance(const Duration(minutes: 3));
      await h.ack(w1, 'dev2', {});
      expect((await h.device(w1, 'dev2'))['lastSeen'], '2026-10-24T10:03:00Z');
    });

    test('a failed ack does not refresh lastSeen', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      h.advance(const Duration(days: 1));
      expect((await h.ack(w1, 'dev1', {'dev1': 9})).statusCode, 422);
      expect((await h.device(w1, 'dev1'))['lastSeen'], '2026-10-22T10:00:00Z');
    });
  });
}
