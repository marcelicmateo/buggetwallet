// Hardening for running behind a proxy (docs/context/RELAY_PROTOCOL.md "Creation token", "Behind a proxy", "HEAD",
// "Missing files"): creation token, X-Forwarded-For, HEAD, and diagnosable answers for files gone from disk.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

import 'support.dart';

const String token = 'synthetic-create-token-0123456789';
const String tokenHeader = 'x-bw-create-token';

Future<String> hashOf(List<int> b) async => [for (final x in (await Sha256().hash(b)).bytes) x.toRadixString(16).padLeft(2, '0')].join();

void main() {
  group('creation token', () {
    test('without the flag creation is open and a token header is ignored', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      final r = await h.send('PUT', '/v2/w/$w2/d/dev1/1', key: keyA, body: bytes('x'), headers: {tokenHeader: 'whatever'});
      expect(r.statusCode, 201);
    });

    test('a creating PUT needs the token: missing or wrong is 403 createToken and nothing is created', () async {
      final h = await freshHarness(createToken: token);
      const path = '/v2/w/$w1/d/dev1/1';
      final none = await h.send('PUT', path, key: keyA, body: bytes('one'));
      expect(none.statusCode, 403);
      expect(jsonDecode(none.body), {'error': 'createToken'});
      for (final bad in ['x', '${token}x', token.substring(1), token.toUpperCase()]) {
        final r = await h.send('PUT', path, key: keyA, body: bytes('one'), headers: {tokenHeader: bad});
        expect(r.statusCode, 403, reason: 'token "$bad"');
      }
      expect(h.relay.walletCount, 0);
      expect(Directory('${h.dir.path}/$w1').existsSync(), isFalse);
      final ok = await h.send('PUT', path, key: keyA, body: bytes('one'), headers: {tokenHeader: token});
      expect(ok.statusCode, 201);
      expect(h.relay.walletCount, 1);
    });

    test('existing wallets never need it, also after a restart', () async {
      final h = await freshHarness(createToken: token);
      await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: bytes('one'), headers: {tokenHeader: token});
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 200); // replay of seq 1 on a known wallet
      expect((await h.putData(w1, 'dev2', 1, 'other')).statusCode, 201);
      await h.restart();
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
    });

    test('reads of an unknown wallet are unchanged; a full relay does not leak to a client without the token', () async {
      final h = await freshHarness(createToken: token, maxWallets: 1);
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 404);
      expect((await h.ack(w1, 'dev1', {})).statusCode, 404);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: bytes('a'), headers: {tokenHeader: token})).statusCode, 201);
      expect((await h.putData(w2, 'dev1', 1, 'a')).statusCode, 403);
      expect((await h.putData(w2, 'dev1', 5, 'a')).statusCode, 403);
    });

    test('a refusal drains a large upload, so the client sees the 403 / 401 / 400, not a reset', () async {
      final h = await freshHarness(createToken: token);
      final big = List<int>.filled(8 * 1024 * 1024, 7);
      final denied = await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: big);
      expect(denied.statusCode, 403);
      expect(jsonDecode(denied.body), {'error': 'createToken'});
      final open = await freshHarness();
      final noPub = await open.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: big, withPub: false);
      expect(noPub.statusCode, 401);
      final badPub = await open.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: big, headers: {'x-bw-pub': 'short'});
      expect(badPub.statusCode, 400);
      expect(open.relay.walletCount, 0);
    });

    test('the token is never logged', () async {
      final h = await freshHarness(createToken: token);
      await h.putData(w1, 'dev1', 1, 'one');
      await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: bytes('one'), headers: {tokenHeader: token});
      expect(h.logs.join('\n'), isNot(contains(token)));
      expect(h.logs.first, 'relay put-d 403 0 w=${w1.substring(0, 6)} d=dev1');
    });
  });

  group('trust proxy', () {
    Future<int> health(Harness h, [String? forwarded]) async =>
        (await h.get('/v2/health', headers: {if (forwarded != null) 'x-forwarded-for': forwarded})).statusCode;

    test('by default X-Forwarded-For is ignored: one bucket for the connection', () async {
      final h = await freshHarness();
      for (var i = 0; i < 100; i++) {
        expect(await health(h, '10.0.0.$i'), 200);
      }
      expect(await health(h, '198.51.100.7'), 429);
    });

    test('with it, the last hop is the client: separate buckets, spoofed first hops do not help', () async {
      final h = await freshHarness(trustProxy: true);
      for (var i = 0; i < 100; i++) {
        expect(await health(h, '10.0.0.$i, 198.51.100.7'), 200);
      }
      expect(await health(h, '198.51.100.7'), 429);
      expect(await health(h, '203.0.113.9, 198.51.100.7'), 429);
      expect(await health(h, '198.51.100.7, 203.0.113.9'), 200); // another last hop
      expect(await health(h, '2001:db8::1'), 200);
    });

    test('with it, a missing or invalid header falls back to the connection address', () async {
      final h = await freshHarness(trustProxy: true);
      for (var i = 0; i < 50; i++) {
        await health(h);
        await health(h, 'not an address');
      }
      expect(await health(h), 429);
      expect(await health(h, '198.51.100.7'), 200);
    });

    test('logs carry no client address', () async {
      final h = await freshHarness(trustProxy: true);
      await health(h, '198.51.100.7');
      expect(h.logs.join('\n'), isNot(contains('198.51')));
    });
  });

  group('HEAD', () {
    test('health: 200 with the length of the GET and no body', () async {
      final h = await freshHarness();
      final g = await h.get('/v2/health');
      final r = await h.send('HEAD', '/v2/health');
      expect(r.statusCode, 200);
      expect(r.bodyBytes, isEmpty);
      expect(r.headers['content-length'], '${g.bodyBytes.length}');
      expect(r.headers['date'], isNotNull);
    });

    test('signed endpoints answer HEAD like GET without a body; the signature covers the method HEAD', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snapbytes');
      for (final p in ['/v2/w/$w1/state', '/v2/w/$w1/d/dev1/2', '/v2/w/$w1/snapshot/s1']) {
        final g = await h.get(p, key: keyA);
        final r = await h.send('HEAD', p, key: keyA);
        expect(r.statusCode, 200, reason: p);
        expect(r.bodyBytes, isEmpty, reason: p);
        expect(r.headers['content-length'], '${g.bodyBytes.length}', reason: p);
        // A GET signature does not authorize a HEAD (and the other way round).
        final getSig = await h.sign(keyA, 'GET', p, const []);
        expect((await h.replay('HEAD', p, getSig)).statusCode, 401, reason: p);
        final headSig = await h.sign(keyA, 'HEAD', p, const []);
        expect((await h.replay('GET', p, headSig)).statusCode, 401, reason: p);
        expect((await h.send('HEAD', p)).statusCode, 401, reason: p);
        expect((await h.send('HEAD', p, key: keyB)).statusCode, 401, reason: p);
      }
      expect((await h.send('HEAD', '/v2/w/$w1/d/dev1/9', key: keyA)).statusCode, 404);
      expect((await h.send('HEAD', '/v2/w/$w2/state', key: keyA)).statusCode, 404);
    });

    test('blobs: HEAD works, other methods stay 405', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final blob = bytes('blob bytes');
      final hash = await hashOf(blob);
      expect((await h.send('PUT', '/v2/w/$w1/blob/$hash', key: keyA, body: blob)).statusCode, 201);
      final r = await h.send('HEAD', '/v2/w/$w1/blob/$hash', key: keyA);
      expect(r.statusCode, 200);
      expect(r.headers['content-length'], '${blob.length}');
      expect((await h.send('HEAD', '/v2/w/$w1/ack/dev1', key: keyA)).statusCode, 405);
      expect((await h.send('POST', '/v2/health')).statusCode, 405);
    });

    test('HEAD is rate limited like any request', () async {
      final h = await freshHarness();
      for (var i = 0; i < 100; i++) {
        await h.send('HEAD', '/v2/health');
      }
      expect((await h.send('HEAD', '/v2/health')).statusCode, 429);
    });
  });

  group('missing files', () {
    test('a stored file gone from disk: GET 404 missing (not 500), pruned stays 410, logged as missing', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      File('${h.dir.path}/$w1/d/dev1/1').deleteSync();
      final r = await h.getData(w1, 'dev1', 1);
      expect(r.statusCode, 404);
      expect(jsonDecode(r.body), {'error': 'missing'});
      expect(h.logs.last, 'relay get-d!missing 404 0 w=${w1.substring(0, 6)} d=dev1');
      expect((await h.getData(w1, 'dev1', 2)).statusCode, 200);
      // Replaying the PUT of the lost seq is diagnosable too.
      final again = await h.putData(w1, 'dev1', 1, 'one');
      expect(again.statusCode, 404);
      expect(jsonDecode(again.body), {'error': 'missing'});
      // The relay keeps serving: a new seq still works.
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
    });

    test('a kept snapshot gone from disk: GET and a same-id PUT are 404 missing', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snapbytes')).statusCode, 201);
      File('${h.dir.path}/$w1/snap/s1').deleteSync();
      final r = await h.getSnapshot(w1, 's1');
      expect(r.statusCode, 404);
      expect(jsonDecode(r.body), {'error': 'missing'});
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snapbytes')).statusCode, 404);
      expect((await h.getSnapshot(w1, 'unknown')).statusCode, 404);
    });

    test('a blob gone from disk: GET 404 missing', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final blob = bytes('blob bytes');
      final hash = await hashOf(blob);
      await h.send('PUT', '/v2/w/$w1/blob/$hash', key: keyA, body: blob);
      File('${h.dir.path}/$w1/blobs/$hash').deleteSync();
      final r = await h.get('/v2/w/$w1/blob/$hash', key: keyA);
      expect(r.statusCode, 404);
      expect(jsonDecode(r.body), {'error': 'missing'});
    });
  });
}
