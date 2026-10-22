import 'dart:io';

import 'package:relay/relay.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('rate limit', () {
    test('burst of 100, then 429 with Retry-After, then 20 per second', () async {
      final h = await freshHarness();
      for (var i = 0; i < 100; i++) {
        expect((await h.get('/v2/health')).statusCode, 200, reason: 'request $i');
      }
      final limited = await h.get('/v2/health');
      expect(limited.statusCode, 429);
      expect(limited.headers['retry-after'], '1');
      expect((await h.get('/v2/health')).statusCode, 429);
      h.advance(const Duration(seconds: 1));
      for (var i = 0; i < 20; i++) {
        expect((await h.get('/v2/health')).statusCode, 200, reason: 'refill $i');
      }
      expect((await h.get('/v2/health')).statusCode, 429);
      h.advance(const Duration(milliseconds: 50)); // one token
      expect((await h.get('/v2/health')).statusCode, 200);
      expect((await h.get('/v2/health')).statusCode, 429);
    });

    test('every kind of request counts, including OPTIONS and failures', () async {
      final h = await freshHarness();
      for (var i = 0; i < 50; i++) {
        await h.get('/nope');
        await h.send('OPTIONS', '/v2/w/$w1/state');
      }
      expect((await h.get('/v2/health')).statusCode, 429);
    });

    test('a limited request does not reach the wallet', () async {
      final h = await freshHarness();
      for (var i = 0; i < 100; i++) {
        await h.get('/v2/health');
      }
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 429);
      h.advance(const Duration(seconds: 5));
      expect(h.relay.walletCount, 0);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
    });

    test('the bucket refills at most to the burst and clients are separate', () {
      final l = RateLimiter();
      final t0 = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < 100; i++) {
        expect(l.allow('a', t0), isTrue);
      }
      expect(l.allow('a', t0), isFalse);
      expect(l.allow('b', t0), isTrue);
      final later = t0.add(const Duration(hours: 1));
      for (var i = 0; i < 100; i++) {
        expect(l.allow('a', later), isTrue);
      }
      expect(l.allow('a', later), isFalse);
      // A clock that goes backwards neither refills nor breaks.
      expect(l.allow('a', t0), isFalse);
    });
  });

  group('507 limits', () {
    test('a wallet over --max-wallets is refused, existing wallets keep working', () async {
      final h = await freshHarness(maxWallets: 2);
      expect((await h.putData(wid(1), 'dev1', 1, 'a')).statusCode, 201);
      expect((await h.putData(wid(2), 'dev1', 1, 'a')).statusCode, 201);
      final r = await h.putData(wid(3), 'dev1', 1, 'a');
      expect(r.statusCode, 507);
      expect(h.relay.walletCount, 2);
      expect((await h.get('/v2/w/${wid(3)}/state', key: keyA)).statusCode, 404);
      expect((await h.putData(wid(2), 'dev1', 2, 'b')).statusCode, 201);
      expect((await h.putData(wid(1), 'dev2', 1, 'b')).statusCode, 201);
    });

    test('concurrent creations never exceed --max-wallets', () async {
      final h = await freshHarness(maxWallets: 3);
      final rs = await Future.wait([for (var i = 1; i <= 8; i++) h.putData(wid(i), 'dev1', 1, 'a')]);
      expect(rs.where((r) => r.statusCode == 201), hasLength(3));
      expect(rs.where((r) => r.statusCode == 507), hasLength(5));
      expect(h.relay.walletCount, 3);
    });

    test('the cap survives a restart', () async {
      final h = await freshHarness(maxWallets: 1);
      await h.putData(wid(1), 'dev1', 1, 'a');
      await h.restart();
      expect((await h.putData(wid(2), 'dev1', 1, 'a')).statusCode, 507);
    });

    test('a wallet over --max-bytes is refused, at the boundary exactly', () async {
      final h = await freshHarness(maxBytes: 100);
      expect((await h.putData(w1, 'dev1', 1, 'x' * 60)).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 2, 'x' * 41)).statusCode, 507);
      expect((await h.putData(w1, 'dev1', 2, 'x' * 40)).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 3, 'x')).statusCode, 507);
      expect((await h.device(w1, 'dev1'))['last'], 2);
      // Another wallet has its own budget.
      expect((await h.putData(w2, 'dev1', 1, 'x' * 100, key: keyB)).statusCode, 201);
    });

    test('a first PUT larger than --max-bytes creates nothing', () async {
      final h = await freshHarness(maxBytes: 10);
      expect((await h.putData(w1, 'dev1', 1, 'x' * 11)).statusCode, 507);
      expect(h.relay.walletCount, 0);
    });

    test('a snapshot may exceed the room taken by files, because pruning frees it', () async {
      final h = await freshHarness(maxBytes: 100);
      await h.putData(w1, 'dev1', 1, 'x' * 40);
      await h.putData(w1, 'dev1', 2, 'x' * 40);
      expect((await h.putData(w1, 'dev1', 3, 'x' * 40)).statusCode, 507);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 2}, 'y' * 50)).statusCode, 201); // 130 for a moment, then 50
      expect((await h.device(w1, 'dev1'))['first'], 3);
      expect((await h.putData(w1, 'dev1', 3, 'x' * 40)).statusCode, 201); // 50 + 40
      expect((await h.putData(w1, 'dev1', 4, 'x' * 11)).statusCode, 507);
      expect((await h.putData(w1, 'dev1', 4, 'x' * 10)).statusCode, 201);
    });

    test('kept snapshots together are limited by --max-bytes; a dropped previous is freed', () async {
      final h = await freshHarness(maxBytes: 100);
      await h.putData(w1, 'dev1', 1, 'x' * 10);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'y' * 101)).statusCode, 507);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'y' * 50)).statusCode, 201);
      expect((await h.putSnapshot(w1, 's2', {'dev1': 1}, 'y' * 50)).statusCode, 201); // 50 + 50 kept
      expect((await h.putSnapshot(w1, 's3', {'dev1': 1}, 'y' * 50)).statusCode, 201); // s1 dropped: 50 + 50
      expect((await h.getSnapshot(w1, 's1')).statusCode, 404);
      expect((await h.putSnapshot(w1, 's4', {'dev1': 1}, 'y' * 51)).statusCode, 507); // 51 + 50
      expect((await h.getSnapshot(w1, 's4')).statusCode, 404);
      expect((await h.getSnapshot(w1, 's3')).statusCode, 200);
    });
  });

  group('CORS', () {
    const allowed = 'http://127.0.0.1:8080';

    test('an allowed origin is echoed on every kind of answer', () async {
      final h = await freshHarness();
      for (final p in ['/v2/health', '/nope', '/v2/w/$w1/state']) {
        final r = await h.get(p, headers: {'origin': allowed});
        expect(r.headers['access-control-allow-origin'], allowed, reason: p);
        expect(r.headers['vary'], contains('Origin'), reason: p);
      }
      final other = await h.get('/v2/health', headers: {'origin': 'http://localhost:8080'});
      expect(other.headers['access-control-allow-origin'], 'http://localhost:8080');
    });

    test('a denied origin gets no CORS headers (and the same answer otherwise)', () async {
      final h = await freshHarness();
      for (final o in [
        'http://evil.example',
        'http://127.0.0.1:8081',
        'https://127.0.0.1:8080',
        'http://127.0.0.1:8080/',
        'null',
        '*',
        ''
      ]) {
        final r = await h.get('/v2/health', headers: {'origin': o});
        expect(r.statusCode, 200, reason: o);
        expect(r.headers.containsKey('access-control-allow-origin'), isFalse, reason: o);
      }
      expect((await h.get('/v2/health')).headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('errors carry the CORS header too, so the browser can read them', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'a');
      final r = await h.get('/v2/w/$w1/state', key: keyB, headers: {'origin': allowed});
      expect(r.statusCode, 401);
      expect(r.headers['access-control-allow-origin'], allowed);
      expect(r.headers['access-control-expose-headers'], 'Date', reason: 'the client reads the relay clock');
      expect(r.headers['date'], isNotNull);
    });

    test('preflight: 204 with methods and headers for an allowed origin', () async {
      final h = await freshHarness();
      for (final p in ['/v2/health', '/v2/w/$w1/d/dev1/1', '/v2/w/$w1/snapshot/s1', '/anything/at/all']) {
        final r = await h.send('OPTIONS', p, headers: {'origin': allowed, 'access-control-request-method': 'PUT'});
        expect(r.statusCode, 204, reason: p);
        expect(r.bodyBytes, isEmpty);
        expect(r.headers['access-control-allow-origin'], allowed);
        expect(r.headers['access-control-allow-methods'], 'GET, PUT, OPTIONS');
        expect(r.headers['access-control-allow-headers'], 'Content-Type, X-BW-Covers, X-BW-Time, X-BW-Sig, X-BW-Pub');
      }
    });

    test('preflight from a denied origin is still 204 but grants nothing', () async {
      final h = await freshHarness();
      final r = await h.send('OPTIONS', '/v2/health', headers: {'origin': 'http://evil.example'});
      expect(r.statusCode, 204);
      expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
      expect(r.headers.containsKey('access-control-allow-methods'), isFalse);
    });

    test('preflight needs no signature and touches no wallet', () async {
      final h = await freshHarness();
      expect((await h.send('OPTIONS', '/v2/w/$w1/d/dev1/1', headers: {'origin': allowed})).statusCode, 204);
      expect(h.relay.walletCount, 0);
    });

    test('a configured origin list replaces the defaults', () async {
      final h = await freshHarness(origins: ['https://app.example']);
      expect((await h.get('/v2/health', headers: {'origin': 'https://app.example'})).headers['access-control-allow-origin'],
          'https://app.example');
      expect((await h.get('/v2/health', headers: {'origin': allowed})).headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('an empty origin list allows no browser', () async {
      final h = await freshHarness(origins: []);
      expect((await h.get('/v2/health', headers: {'origin': allowed})).headers.containsKey('access-control-allow-origin'), isFalse);
    });
  });

  group('logs', () {
    test('one line per request: kind, status, bytes and short ids; nothing sensitive', () async {
      final h = await freshHarness();
      const device = 'laptop-device-with-long-name';
      const secret = 'SECRET-BODY-TEXT';
      await h.putData(w1, device, 1, secret);
      await h.putData(w1, device, 1, 'other');
      await h.putData(w1, device, 1, secret, key: keyB);
      await h.getData(w1, device, 1);
      await h.getData(w1, device, 9);
      await h.state(w1);
      await h.ack(w1, device, {device: 1});
      await h.putSnapshot(w1, 'snapshot-with-long-id', {device: 1}, secret);
      await h.getSnapshot(w1, 'snapshot-with-long-id');
      await h.get('/v2/health');
      await h.get('/v2/w/${w1.toUpperCase()}/state', key: keyA);
      await h.get('/nothing-here/x');
      await h.send('OPTIONS', '/v2/w/$w1/state');
      await h.get('/v2/w/$w1/d/$device/not-a-number', key: keyA);

      expect(h.logs.length, 14);
      final line = RegExp(r'^relay [a-z0-9!A-Za-z-]+ \d{3} \d+ w=([0-9a-f]{6}|-) d=\S{1,6}$');
      for (final l in h.logs) {
        expect(l, matches(line));
      }
      final all = h.logs.join('\n');
      expect(all, isNot(contains(await keyA.pub())));
      expect(all, isNot(contains(await keyB.pub())));
      expect(all, isNot(matches(RegExp(r'[A-Za-z0-9_-]{40,}'))), reason: 'no signature, key or long id');
      expect(all, isNot(contains(secret)));
      expect(all, isNot(contains(w1))); // never the full id
      expect(all, isNot(contains(w1.toUpperCase())));
      expect(all, isNot(contains(device)));
      expect(all, isNot(contains('snapshot-with-long-id')));
      expect(all, isNot(contains('127.0.0.1')));
      expect(all, isNot(contains('::1')));
      expect(all, isNot(contains(h.dir.path)));
      // The useful parts are there.
      expect(h.logs[0], 'relay put-d 201 ${secret.length} w=${w1.substring(0, 6)} d=laptop');
      expect(h.logs[1], contains(' 409 '));
      expect(h.logs[2], contains(' 401 '));
      expect(h.logs[3], 'relay get-d 200 ${secret.length} w=${w1.substring(0, 6)} d=laptop');
      expect(h.logs[4], contains(' 404 '));
      expect(h.logs[9], 'relay health 200 0 w=- d=-');
      expect(h.logs[10], contains(' 400 '));
      expect(h.logs[10], contains('w=-'));
    });

    test('an internal error is logged by type only', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      // Break the storage under the relay.
      await Directory('${h.dir.path}/$w1/d/dev1').delete(recursive: true);
      File('${h.dir.path}/$w1/d/dev1').writeAsStringSync('in the way');
      final r = await h.putData(w1, 'dev1', 2, 'two');
      expect(r.statusCode, 500);
      expect(r.body, '{"error":"internal"}');
      expect(h.logs.last, contains(' 500 '));
      expect(h.logs.last, isNot(contains(h.dir.path)));
      expect(h.logs.last, isNot(contains(w1)));
    });
  });
}
