// RelayTransport (HTTP client of docs/context/RELAY_PROTOCOL.md) against a fake http.Client and against the real relay
// server in-process; deriveKey; MemoryTransport's relay rules. All data is SYNTHETIC.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/synthetic.dart';

/// HKDF-SHA256 (RFC 5869) written out with plain HMAC, empty salt: an independent check of [deriveKey].
Future<List<int>> _hkdf(List<int> ikm, String info, int length) async {
  final hmac = Hmac.sha256();
  final prk = await hmac.calculateMac(ikm, secretKey: SecretKey(List.filled(32, 0)));
  final out = <int>[];
  var t = <int>[];
  for (var i = 1; out.length < length; i++) {
    t = (await hmac.calculateMac([...t, ...utf8.encode(info), i], secretKey: SecretKey(prk.bytes))).bytes;
    out.addAll(t);
  }
  return out.sublist(0, length);
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

List<int> _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

/// Forwards to [inner] with one bit of `X-BW-Sig` flipped (a client with the right wallet id but a wrong signature).
class _BadSignature extends http.BaseClient {
  final http.Client inner;
  _BadSignature(this.inner);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final sig = _unb64(request.headers['X-BW-Sig']!)..[0] ^= 1;
    final r = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..headers['X-BW-Sig'] = _b64(sig);
    if (request is http.Request) r.bodyBytes = request.bodyBytes;
    return inner.send(r);
  }
}

/// Whether [r] carries a v4 signature by [pub] over [path] (from `/v2/` on), written from the protocol text.
Future<bool> _signedBy(http.Request r, String pub, {String? path}) async {
  final hash = _hex((await Sha256().hash(r.bodyBytes)).bytes);
  // v4 (RELAY_PROTOCOL.md): the host the client addressed, lower case, the port only when not the scheme's default.
  final u = r.url, def = u.scheme == 'https' ? 443 : 80;
  final host = u.hasPort && u.port != def ? '${u.host.toLowerCase()}:${u.port}' : u.host.toLowerCase();
  final text =
      'bw-relay-v4\n${r.method}\n$host\n${path ?? r.url.path}\n${r.headers['X-BW-Covers'] ?? ''}\n$hash\n${r.headers['X-BW-Time']}';
  return Ed25519().verify(utf8.encode(text),
      signature: Signature(_unb64(r.headers['X-BW-Sig']!), publicKey: SimplePublicKey(_unb64(pub), type: KeyPairType.ed25519)));
}

/// A relay stand-in that checks only the time window (5 min) against [relayNow] and answers 401 clock with a Date.
http.Response _clockGate(http.Request r, DateTime relayNow, {bool sendDate = true, bool alwaysClock = false}) {
  final t = int.parse(r.headers['X-BW-Time']!);
  if (alwaysClock || (t - relayNow.millisecondsSinceEpoch).abs() > 300000) {
    return http.Response('{"error":"clock"}', 401, headers: {if (sendDate) 'date': HttpDate.format(relayNow)});
  }
  return http.Response('{"api":3,"devices":{}}', 200);
}

void main() {
  final key = VaultKey(List.generate(32, (i) => i)); // a synthetic, fixed key

  group('deriveKey', () {
    test('is HKDF-SHA256 with an empty salt; lengths and infos give the expected, unrelated bytes', () async {
      for (final (info, n) in [('bw-relay-id-v1', 16), ('bw-relay-sign-v1', 32), ('bw-local-db-v1', 32), ('x', 64)]) {
        expect(await deriveKey(key, info, length: n), await _hkdf(key.bytes, info, n), reason: info);
      }
      expect(await deriveKey(key, 'a'), isNot(await deriveKey(key, 'b')));
      expect(await deriveKey(key, 'a'), isNot(await deriveKey(VaultKey.generate(), 'a')));
      expect(await deriveKey(key, 'a'), hasLength(32));
    });

    test('relay ids: wid = 32 lowercase hex, pub = the Ed25519 key of the bw-relay-sign-v1 seed, 43 base64url chars', () async {
      final (wid, pub) = await RelayTransport(Uri.parse('http://relay.test:8787'), key).ids;
      expect(wid, _hex(await _hkdf(key.bytes, 'bw-relay-id-v1', 16)));
      expect(wid, matches(RegExp(r'^[0-9a-f]{32}$')));
      final pair = await Ed25519().newKeyPairFromSeed(await _hkdf(key.bytes, 'bw-relay-sign-v1', 32));
      expect(pub, _b64((await pair.extractPublicKey()).bytes));
      expect(pub, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      final (_, otherPub) = await RelayTransport(Uri.parse('http://relay.test:8787'), VaultKey.generate()).ids;
      expect(otherPub, isNot(pub));
    });
  });

  group('RelayTransport over a fake client', () {
    late List<http.Request> seen;
    late String wid, pub;

    setUp(() async {
      seen = [];
      (wid, pub) = await RelayTransport(Uri.parse('http://relay.test'), key).ids;
    });

    RelayTransport client(FutureOr<http.Response> Function(http.Request r) answer, {String base = 'http://relay.test:8787'}) =>
        RelayTransport(Uri.parse(base), key, client: MockClient((r) async {
          seen.add(r);
          return answer(r);
        }));

    test('state: the URL, a valid signature, the parsed JSON; 404 is an empty relay', () async {
      final body = {
        'api': 3,
        'devices': {
          'dev1': {
            'first': 3,
            'last': 12,
            'lastSeen': '2026-10-22T10:00:00Z',
            'acks': {'dev2': 5}
          },
          'dev2': {'first': 1, 'last': 0, 'lastSeen': '2026-10-21T10:00:00Z', 'acks': <String, int>{}},
        },
        'snapshot': {
          'id': 's5-1-ab',
          'covers': {'dev1': 12}
        },
        'previous': null,
      };
      final t = client((r) => http.Response(jsonEncode(body), 200));
      final s = await t.state();
      expect(seen.single.method, 'GET');
      expect(seen.single.url.toString(), 'http://relay.test:8787/v2/w/$wid/state');
      expect(await _signedBy(seen.single, pub), isTrue);
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
      expect(seen.single.headers.containsKey('X-BW-Pub'), isFalse);
      expect(seen.single.bodyBytes, isEmpty);
      expect((s.devices['dev1']!.first, s.devices['dev1']!.last), (3, 12));
      expect(s.devices['dev1']!.acks, {'dev2': 5});
      expect(s.devices['dev1']!.lastSeen, DateTime.utc(2026, 10, 22, 10));
      expect((s.snapshot!.id, s.previous), ('s5-1-ab', null));
      expect(s.snapshot!.covers, {'dev1': 12});
      expect(RelayState.fromJson(jsonDecode(jsonEncode(s.toJson()))).devices['dev1']!.last, 12);

      final empty = await client((r) => http.Response('{"error":"no such wallet"}', 404)).state();
      expect(empty.devices, isEmpty);
      expect(empty.snapshot, isNull);
    });

    test('a base address with a path, with or without a trailing slash; the signed path starts at /v2/', () async {
      for (final base in ['http://relay.test:8787/bw', 'http://relay.test:8787/bw/']) {
        seen.clear();
        await client((r) => http.Response('{"api":3,"devices":{}}', 200), base: base).state();
        expect(seen.single.url.path, '/bw/v2/w/$wid/state', reason: base);
        expect(await _signedBy(seen.single, pub, path: '/v2/w/$wid/state'), isTrue, reason: base);
      }
    });

    test('put, get, ack and putSnapshot send what the protocol says', () async {
      final t = client((r) => switch (r.method) {
            'GET' => http.Response.bytes([7, 8, 9], 200),
            _ => http.Response('', r.url.path.contains('/ack/') ? 204 : 201),
          });
      await t.put('dev1', 1, [1]);
      await t.put('dev1', 4, [1, 2, 3]);
      expect(await t.get('dev1', 4), [7, 8, 9]);
      await t.ack('dev1', {'dev2': 5, 'dev3': 0});
      await t.putSnapshot('s5-1-ab', {'dev1': 4}, [4, 5]);
      expect(await t.getSnapshot('s5-1-ab'), [7, 8, 9]);
      final [first, put, get, ack, snap, getSnap] = seen;
      expect(first.headers['X-BW-Pub'], pub, reason: 'seq 1 may create the wallet');
      expect(put.headers.containsKey('X-BW-Pub'), isFalse);
      expect((put.method, put.url.path, put.headers['Content-Type']), ('PUT', '/v2/w/$wid/d/dev1/4', 'application/octet-stream'));
      expect(put.bodyBytes, [1, 2, 3]);
      expect((get.method, get.url.path), ('GET', '/v2/w/$wid/d/dev1/4'));
      expect((ack.method, ack.url.path), ('PUT', '/v2/w/$wid/ack/dev1'));
      expect(jsonDecode(ack.body), {'dev2': 5, 'dev3': 0});
      expect((snap.method, snap.url.path), ('PUT', '/v2/w/$wid/snapshot/s5-1-ab'));
      expect(jsonDecode(snap.headers['X-BW-Covers']!), {'dev1': 4});
      expect(snap.bodyBytes, [4, 5]);
      expect(getSnap.url.path, '/v2/w/$wid/snapshot/s5-1-ab');
      for (final r in seen) {
        expect(await _signedBy(r, pub), isTrue, reason: '${r.method} ${r.url.path}');
        expect(r.headers['X-BW-Time'], matches(RegExp(r'^[0-9]{13}$')));
        expect(r.headers['X-BW-Sig'], matches(RegExp(r'^[A-Za-z0-9_-]{86}$')));
      }
      // Covers are signed: the same snapshot with other covers carries another signature.
      final again = seen.length;
      await t.putSnapshot('s5-1-ab', {'dev1': 3}, [4, 5]);
      expect(
          await _signedBy(
              http.Request('PUT', seen[again].url)
                ..headers.addAll({...seen[again].headers, 'X-BW-Covers': snap.headers['X-BW-Covers']!})
                ..bodyBytes = [4, 5],
              pub),
          isFalse);
    });

    test('status codes map to failures', () async {
      const want = {
        400: TransportFailure.rejected,
        401: TransportFailure.refused,
        403: TransportFailure.refused,
        404: TransportFailure.missing,
        409: TransportFailure.conflict,
        410: TransportFailure.gone,
        413: TransportFailure.full,
        422: TransportFailure.rejected,
        429: TransportFailure.other,
        500: TransportFailure.other,
        507: TransportFailure.full,
      };
      for (final MapEntry(key: status, value: failure) in want.entries) {
        final t = client((r) => http.Response('{"error":"synthetic"}', status));
        await expectLater(t.put('dev1', 1, [1]), throwsA(isA<TransportException>().having((e) => e.failure, 'failure', failure)),
            reason: '$status');
        await expectLater(t.get('dev1', 1), throwsA(isA<TransportException>().having((e) => e.failure, 'failure', failure)));
      }
    });

    test('no connection or a timeout is unreachable; a newer api is newerApi; a body that is not state is other', () async {
      final down =
          RelayTransport(Uri.parse('http://relay.test'), key, client: MockClient((r) async => throw http.ClientException('down', r.url)));
      await expectLater(down.state(), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.unreachable)));
      final slow = RelayTransport(Uri.parse('http://relay.test'), key,
          timeout: const Duration(milliseconds: 20),
          client: MockClient((r) => Future.delayed(const Duration(seconds: 2), () => http.Response('{}', 200))));
      await expectLater(slow.get('d', 1), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.unreachable)));
      for (final (body, failure) in [
        ('{"api":5,"devices":{}}', TransportFailure.newerApi),
        ('{"api":2,"devices":{}}', TransportFailure.olderApi),
        ('{"api":1,"devices":{}}', TransportFailure.olderApi),
        ('not json', TransportFailure.other),
        ('[1]', TransportFailure.other),
        ('{"devices":{}}', TransportFailure.other),
        ('{"api":3,"devices":{"d":{"first":"x"}}}', TransportFailure.other),
      ]) {
        await expectLater(
            client((r) => http.Response(body, 200)).state(), throwsA(isA<TransportException>().having((e) => e.failure, 'f', failure)),
            reason: body);
      }
    });

    test('health: /v2/health not signed; api 2 is fine, a newer one, an older relay or no answer throws', () async {
      final requests = <http.Request>[];
      MockClient answering(String body) => MockClient((r) async {
            requests.add(r);
            return http.Response(body, 200);
          });
      expect(await RelayTransport.health(Uri.parse('http://relay.test:8787'), client: answering('{"api":3}')), 3,
          reason: 'an api-3 relay is still fine (P14)');
      expect(requests.single.url.toString(), 'http://relay.test:8787/v2/health');
      expect(await RelayTransport.health(Uri.parse('http://relay.test'), client: answering('{"api":4}')), 4);
      requests.removeLast();
      expect(requests.single.headers.keys.where((h) => h.startsWith('X-BW') || h == 'Authorization'), isEmpty);
      await expectLater(RelayTransport.health(Uri.parse('http://relay.test'), client: answering('{"api":5}')),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.newerApi)));
      // A v1 relay: /v2/health is an unknown path there, /v1/health says api 1.
      final v1 = MockClient(
          (r) async => r.url.path == '/v1/health' ? http.Response('{"api":1}', 200) : http.Response('{"error":"not found"}', 404));
      await expectLater(RelayTransport.health(Uri.parse('http://relay.test'), client: v1),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.olderApi)));
      // Nothing at either path: missing, not olderApi.
      await expectLater(
          RelayTransport.health(Uri.parse('http://relay.test'), client: MockClient((r) async => http.Response('{"error":"x"}', 404))),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.missing)));
      await expectLater(
          RelayTransport.health(Uri.parse('http://relay.test'), client: MockClient((r) async => throw http.ClientException('down'))),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.unreachable)));
    });

    test('a newer relay API ends a sync run with a SyncException; the outbox is kept', () async {
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      repo.updateSettings({'salary': 1});
      final t = client((r) => http.Response('{"api":5,"devices":{}}', 200));
      await expectLater(SyncEngine(t, key).run(repo), throwsA(isA<SyncException>()));
      expect(repo.pendingOps(), hasLength(1));
      final old = client((r) => http.Response('{"api":1,"devices":{}}', 200));
      await expectLater(
          SyncEngine(old, key).run(repo), throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('older version'))));
      expect(repo.pendingOps(), hasLength(1));
    });

    test('clock: a skewed device takes the offset from Date and retries once; later requests sign right away', () async {
      final relayNow = DateTime.utc(2026, 10, 22, 10);
      for (final skew in [const Duration(hours: -3), const Duration(minutes: 6), const Duration(hours: 23)]) {
        seen.clear();
        final t = RelayTransport(Uri.parse('http://relay.test'), key,
            now: () => relayNow.add(skew),
            client: MockClient((r) async {
              seen.add(r);
              return _clockGate(r, relayNow);
            }));
        expect((await t.state()).devices, isEmpty, reason: '$skew');
        expect(seen, hasLength(2), reason: 'one refusal, one retry');
        expect(t.clockOffsetMs, -skew.inMilliseconds);
        expect(int.parse(seen[1].headers['X-BW-Time']!), relayNow.millisecondsSinceEpoch);
        expect(await _signedBy(seen[1], pub), isTrue);
        await t.state();
        expect(seen, hasLength(3), reason: 'the offset is kept');
      }
    });

    test('clock: a Date more than 24 h away is not trusted: no retry, no far-time signature, no offset kept', () async {
      final relayNow = DateTime.utc(2026, 10, 22, 10);
      for (final fake in [const Duration(days: 30), const Duration(days: -30), const Duration(hours: 25)]) {
        seen.clear();
        // The device's clock is right; a man in the middle answers 401 clock with a Date [fake] away from it.
        final t = RelayTransport(Uri.parse('http://relay.test'), key,
            now: () => relayNow,
            client: MockClient((r) async {
              seen.add(r);
              return http.Response('{"error":"clock"}', 401, headers: {'date': HttpDate.format(relayNow.add(fake))});
            }));
        await expectLater(t.state(), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.clockSkew)));
        expect(seen, hasLength(1), reason: 'no retry: $fake');
        expect(t.clockOffsetMs, 0, reason: 'offset kept only when accepted');
        t.close();
      }
    });

    test('clock: a Date 2 h away is taken: one refusal, one retry that succeeds', () async {
      final relayNow = DateTime.utc(2026, 10, 22, 10);
      final t = RelayTransport(Uri.parse('http://relay.test'), key,
          now: () => relayNow.add(const Duration(hours: 2)),
          client: MockClient((r) async {
            seen.add(r);
            return _clockGate(r, relayNow);
          }));
      expect((await t.state()).devices, isEmpty);
      expect(seen, hasLength(2));
      expect(t.clockOffsetMs, -2 * 3600000);
      expect(int.parse(seen[1].headers['X-BW-Time']!), relayNow.millisecondsSinceEpoch);
    });

    test('clock: the engine reports a skewed clock in words, without times or hosts', () async {
      final relayNow = DateTime.utc(2026, 10, 22, 10);
      final t = RelayTransport(Uri.parse('http://relay.test'), key,
          now: () => relayNow,
          client: MockClient((r) async =>
              http.Response('{"error":"clock"}', 401, headers: {'date': HttpDate.format(relayNow.add(const Duration(days: 30)))})));
      final repo = WalletRepo.inMemory();
      await expectLater(
          SyncEngine(t, key).run(repo),
          throwsA(isA<SyncException>()
              .having((e) => e.message, 'message', allOf(contains('differ by more than a day'), isNot(contains('relay.test'))))));
    });

    test('clock: a relay that keeps saying clock, or gives no Date, fails the call without looping', () async {
      final relayNow = DateTime.utc(2026, 10, 22, 10);
      final always = RelayTransport(Uri.parse('http://relay.test'), key,
          now: () => relayNow,
          client: MockClient((r) async {
            seen.add(r);
            return _clockGate(r, relayNow, alwaysClock: true);
          }));
      await expectLater(always.put('dev1', 2, [1]),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.other).having((e) => e.message, 'm', 'clock')));
      expect(seen, hasLength(2));
      seen.clear();
      final noDate = RelayTransport(Uri.parse('http://relay.test'), key,
          now: () => relayNow.add(const Duration(hours: 1)),
          client: MockClient((r) async {
            seen.add(r);
            return _clockGate(r, relayNow, sendDate: false);
          }));
      await expectLater(noDate.state(), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.other)));
      expect(seen, hasLength(1));
      expect(noDate.clockOffsetMs, 0);
      // A plain 401 (wrong key) is not retried; only the relay's health is asked once (another api version?).
      seen.clear();
      await expectLater(client((r) => http.Response('{"error":"bad signature"}', 401)).state(),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.refused)));
      expect([for (final r in seen) r.url.path.split('/').last], ['state', 'health']);
    });

    test('parseHttpDate reads IMF-fixdate and refuses anything else', () {
      expect(parseHttpDate('Thu, 22 Oct 2026 10:00:07 GMT'), DateTime.utc(2026, 10, 22, 10, 0, 7));
      expect(parseHttpDate(HttpDate.format(DateTime.utc(2027, 1, 2, 3, 4, 5))), DateTime.utc(2027, 1, 2, 3, 4, 5));
      for (final bad in [
        '',
        'Thu, 22 Foo 2026 10:00:00 GMT',
        'Thu, 22 Oct 2026 10:00:00 CET',
        'Thursday, 22-Oct-26 10:00:00 GMT',
        'Thu, 32 Oct 2026 10:00:00 GMT',
        'Thu, 22 Oct 2026 25:00:00 GMT',
        '1792663200000'
      ]) {
        expect(parseHttpDate(bad), isNull, reason: bad);
      }
    });

    test('logs carry kinds and statuses, never the wallet id, the key, a signature or the address', () async {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = was;
      });
      final t = client((r) => http.Response('{"error":"x"}', 401), base: 'http://secret-host.test:8787');
      await expectLater(t.state(), throwsA(isA<TransportException>()));
      final down = RelayTransport(Uri.parse('http://secret-host.test'), key,
          client: MockClient((r) async => throw http.ClientException('cannot reach secret-host.test', r.url)));
      await expectLater(down.state(), throwsA(isA<TransportException>()));
      final text = lines.join('\n');
      expect(text, contains('relay.failed {"kind":"state","status":401,"failure":"refused"}'));
      expect(text, contains('relay.unreachable'));
      for (final bad in [wid, pub, 'secret-host', ...seen.map((r) => r.headers['X-BW-Sig']).nonNulls]) {
        expect(text, isNot(contains(bad)), reason: bad);
      }
    });
  });

  group('MemoryTransport follows the relay rules', () {
    late MemoryTransport m;
    var now = DateTime.utc(2026, 10, 22);
    setUp(() {
      now = DateTime.utc(2026, 10, 22);
      m = MemoryTransport(now: () => now);
    });
    Matcher fails(TransportFailure f) => throwsA(isA<TransportException>().having((e) => e.failure, 'failure', f));

    test('files: no gaps, never overwritten, same bytes again are fine; gets of unknown or pruned files', () async {
      await expectLater(m.put('d1', 2, [1]), fails(TransportFailure.rejected), reason: 'the first file is seq 1');
      expect((await m.state()).devices, isEmpty, reason: 'a refused first PUT creates nothing');
      await m.put('d1', 1, [1]);
      await m.put('d1', 1, [1]);
      await expectLater(m.put('d1', 1, [2]), fails(TransportFailure.conflict));
      await expectLater(m.put('d1', 3, [3]), fails(TransportFailure.rejected));
      await expectLater(m.get('d1', 2), fails(TransportFailure.missing));
      await expectLater(m.get('nobody', 1), fails(TransportFailure.missing));
      await expectLater(m.put('bad/name', 1, [1]), fails(TransportFailure.rejected));
      await expectLater(m.put('d1', 0, [1]), fails(TransportFailure.rejected));
      expect(m.files.keys, ['d/d1/1']);
      expect(() => m.files.clear(), throwsUnsupportedError);
    });

    test('acks only grow, never pass last; an ack makes a device appear; lastSeen follows now', () async {
      await m.put('d1', 1, [1]);
      await expectLater(m.ack('d2', {'d1': 2}), fails(TransportFailure.rejected));
      expect((await m.state()).devices.keys, ['d1'], reason: 'a refused ack creates nothing');
      await m.ack('d2', {'d1': 1});
      now = now.add(const Duration(hours: 1));
      await m.ack('d2', {'d1': 0});
      final s = await m.state();
      expect(s.devices['d2']!.acks, {'d1': 1});
      expect(s.devices['d2']!.lastSeen, now);
      expect((s.devices['d2']!.first, s.devices['d2']!.last), (1, 0));
    });

    test('snapshots: 422 beyond last before 409 not dominating; same id again; previous kept; pruning after acks', () async {
      for (var s = 1; s <= 3; s++) {
        await m.put('d1', s, [s]);
      }
      await m.ack('d2', {'d1': 2});
      await expectLater(m.putSnapshot('s1', {'d1': 4}, [9]), fails(TransportFailure.rejected));
      await m.putSnapshot('s1', {'d1': 3}, [9]);
      await m.putSnapshot('s1', {'d1': 3}, [9]); // the same again
      await expectLater(m.putSnapshot('s1', {'d1': 3}, [8]), fails(TransportFailure.conflict));
      await expectLater(m.putSnapshot('s2', {'d1': 2}, [8]), fails(TransportFailure.conflict));
      await expectLater(m.putSnapshot('s2', {}, [8]), fails(TransportFailure.conflict), reason: 'a missing device counts as 0');
      var s = await m.state();
      expect(s.devices['d1']!.first, 3, reason: 'd2 acked 2: files 1 and 2 go');
      await m.ack('d2', {'d1': 3});
      s = await m.state();
      expect((s.devices['d1']!.first, s.devices['d1']!.last), (4, 3));
      await expectLater(m.get('d1', 1), fails(TransportFailure.gone));
      await expectLater(m.put('d1', 2, [2]), fails(TransportFailure.gone));
      await m.put('d1', 4, [4]);
      await m.putSnapshot('s2', {'d1': 4}, [7]);
      s = await m.state();
      expect((s.snapshot!.id, s.previous!.id), ('s2', 's1'));
      expect(await m.getSnapshot('s1'), [9]);
      await m.putSnapshot('s3', {'d1': 4}, [6]);
      await expectLater(m.getSnapshot('s1'), fails(TransportFailure.missing), reason: 'only two are kept');
      expect(m.files.keys.where((k) => k.startsWith('snapshot/')).toSet(), {'snapshot/s3', 'snapshot/s2'});
    });

    test('a device silent for more than 90 days no longer holds files back; offline fails everything', () async {
      await m.put('d1', 1, [1]);
      await m.ack('d2', {});
      await m.putSnapshot('s1', {'d1': 1}, [9]);
      expect((await m.state()).devices['d1']!.first, 1);
      now = now.add(const Duration(days: 91));
      await m.put('d1', 2, [2]);
      expect((await m.state()).devices['d1']!.first, 2);
      m.offline = true;
      await expectLater(m.state(), fails(TransportFailure.unreachable));
      await expectLater(m.get('d1', 2), fails(TransportFailure.unreachable));
    });
  });

  group('end to end with the relay server', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    final logs = <String>[];

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('bw-relay-e2e-');
      relay = Relay(data: dir, log: logs.add);
      final server = await relay.serve(port: 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
    });
    tearDown(() async {
      await relay.close();
      dir.deleteSync(recursive: true);
    });

    // Changed (P14): a deleted bill's file stays on the relay (no client DELETE); the snapshot declares its live files.
    test('a bill file goes up with the run, the other device fetches it, a delete never removes it', () async {
      final k = VaultKey.generate();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      final ta = RelayTransport(base, k), tb = RelayTransport(base, k);
      addTearDown(ta.close);
      addTearDown(tb.close);
      final plain = List.generate(5000, (i) => (i * 7) & 0xff);
      final ref = await BlobStore(a, k).add(Uint8List.fromList(plain), 'pdf');
      final (id, _) = a.importBill(
          const NormalizedBill(source: BillSource.pdf, externalId: 'jir:synthetic-e2e', date: '2026-02-25', total: 100),
          file: ref);
      final up = await SyncEngine(ta, k).run(a);
      expect((up.blobsSent, up.blobsWaiting), (1, 0), reason: 'refused while the wallet did not exist, sent after the first file');
      await SyncEngine(tb, k).run(b);
      expect(b.bills().single.blob, ref.hash);
      expect(await BlobStore(b, k).read(ref.hash, transport: tb), plain);
      expect(await tb.getBlob('0' * 64), isNull);
      a.deleteBill(id);
      await SyncEngine(ta, k).run(a);
      await SyncEngine(tb, k).run(b);
      expect(b.bills().where((x) => !x.deleted), isEmpty);
      expect(await tb.getBlob(ref.hash), isNotNull);
      expect(logs.where((l) => l.contains('delete-blob')), isEmpty, reason: 'no DELETE ever reaches the relay');
      expect(logs.where((l) => l.contains('put-blob 201')), hasLength(1));
      expect(ta.signApi, 4);
    });

    test('snapshots declare the live bills\' files to the real relay (api 4); an api-3 app\'s signature still works', () async {
      final k = VaultKey.generate();
      var now = DateTime.utc(2026, 10, 1);
      final a = WalletRepo.inMemory();
      addTearDown(a.close);
      final ta = RelayTransport(base, k);
      addTearDown(ta.close);
      final ref = await BlobStore(a, k).add(Uint8List.fromList(List.generate(800, (i) => i & 0xff)), 'jpg');
      a.importBill(const NormalizedBill(source: BillSource.pdf, externalId: 'jir:synthetic-set', date: '2026-02-25', total: 100),
          file: ref);
      // The snapshot rule writes one once the newest is older than 7 days.
      await SyncEngine(ta, k, now: () => now).run(a);
      now = now.add(const Duration(days: 8));
      await SyncEngine(ta, k, now: () => now).run(a);
      expect(logs.where((l) => l.startsWith('relay put-snap 201')), hasLength(1));
      expect(logs.where((l) => l.startsWith('relay put-set 201')), hasLength(1));
      final (wid, _) = await ta.ids;
      final sets = Directory('${dir.path}/$wid/sets').listSync().whereType<File>().toList();
      expect(jsonDecode(sets.single.readAsStringSync()), [ref.hash]);
      // The same transport signing as an api-3 app: the relay answers its state with api 3.
      ta.signApi = 3;
      expect((await ta.state()).api, 3);
      ta.signApi = 4;
      expect((await ta.state()).api, 4);
    });

    test('two devices sync through the relay: first connect, edits both ways, caught up, acks, devices listed', () async {
      await RelayTransport.health(base);
      final k = VaultKey.generate();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      final ta = RelayTransport(base, k), tb = RelayTransport(base, k);
      addTearDown(ta.close);
      addTearDown(tb.close);
      final ea = SyncEngine(ta, k), eb = SyncEngine(tb, k);
      a.importBatch(january);
      a.updateSettings({'salary': 150000});
      final first = await ea.run(a);
      expect((first.sent, first.caughtUp), (a.snapshotOps().length, true));
      final got = await eb.run(b);
      expect((got.filesRead, got.caughtUp), (1, true));
      expect(b.transactions().length, january.transactions.length);
      b.addTransaction(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await eb.run(b);
      final back = await ea.run(a);
      expect((back.filesRead, back.caughtUp), (2, true), reason: "B's digest file after applying A's data (V2), then its edit");
      expect(a.transactions().where((t) => t.manual).length, 1);
      await eb.run(b);
      final s = await ta.state();
      expect(s.devices.keys.toSet(), {a.deviceId, b.deviceId});
      expect(s.devices[b.deviceId]!.acks[a.deviceId], s.devices[a.deviceId]!.last);
      expect(back.devices.map((d) => d.isThis), containsAll([true, false]));
      expect(a.settings().salary, b.settings().salary);
      expect(a.transactions().map((t) => (t.id, t.amount, t.deleted)).toSet(),
          b.transactions().map((t) => (t.id, t.amount, t.deleted)).toSet());
      // Another wallet's key is another wallet id: it sees an empty relay and leaves this one alone.
      final other = WalletRepo.inMemory();
      addTearDown(other.close);
      final to = RelayTransport(base, VaultKey.generate());
      addTearDown(to.close);
      expect((await to.state()).devices, isEmpty);
      await SyncEngine(to, VaultKey.generate()).run(other);
      expect(other.transactions(), isEmpty);
      // The right wallet id with a wrong signature is refused, and changes nothing.
      final before = await ta.state();
      final wrong = RelayTransport(base, k, client: _BadSignature(http.Client()));
      addTearDown(wrong.close);
      await expectLater(SyncEngine(wrong, k).run(WalletRepo.inMemory()),
          throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('another key'))));
      expect((await ta.state()).toJson(), before.toJson());
      expect(logs.join('\n'), isNot(contains((await ta.ids).$2)), reason: 'the relay never logs the public key');
    });

    test('a device whose clock is off by an hour syncs: one clock refusal, then the offset holds', () async {
      final k = VaultKey.generate();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      final ta = RelayTransport(base, k, now: () => DateTime.now().add(const Duration(hours: 1)));
      final tb = RelayTransport(base, k, now: () => DateTime.now().subtract(const Duration(minutes: 30)));
      addTearDown(ta.close);
      addTearDown(tb.close);
      a.importBatch(january);
      final logsBefore = logs.length;
      expect((await SyncEngine(ta, k).run(a)).caughtUp, isTrue);
      expect(ta.clockOffsetMs, closeTo(-3600000, 10000));
      expect((await SyncEngine(tb, k).run(b)).caughtUp, isTrue);
      expect(b.transactions().length, january.transactions.length);
      final refusals = logs.skip(logsBefore).where(RegExp(r'^relay \S+ 401 ').hasMatch).length;
      expect(refusals, 2, reason: 'one per device, then every request signs inside the window');
    });

    test('a snapshot through the relay: written, used by a new device, files pruned once acked', () async {
      final k = VaultKey.generate();
      var now = DateTime.utc(2026, 1, 10);
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory(), c = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      addTearDown(c.close);
      final t = RelayTransport(base, k);
      addTearDown(t.close);
      SyncEngine engine() => SyncEngine(t, k, now: () => now);
      a.importBatch(january);
      await engine().run(a);
      await engine().run(b);
      now = now.add(const Duration(days: 8));
      a.updateSettings({'rent': 55000});
      await engine().run(a); // caught up, 8 days since its first sync: writes the snapshot
      var s = await t.state();
      expect(s.snapshot, isNotNull);
      await engine().run(b);
      await engine().run(a);
      final rc = await engine().run(c);
      expect(rc.caughtUp, isTrue);
      expect((c.settings().rent, c.transactions().length), (55000, january.transactions.length));
      s = await t.state();
      expect(s.devices[a.deviceId]!.first, greaterThan(1), reason: 'files the snapshot covers and both acked are pruned');
    });
  });

  // Stage H seams end to end: the client's create token against a relay that requires one (H11), and the host in the
  // v3 signature against a relay with a public host set (H8), each through the real `Relay` and `RelayTransport`.
  group('end to end: create token and public host', () {
    final dirs = <Directory>[];
    final relays = <Relay>[];
    tearDown(() async {
      for (final r in relays) {
        await r.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
      relays.clear();
      dirs.clear();
    });

    Future<Uri> start({String? createToken, String? Function(int port)? publicHost}) async {
      // Pick a free port first, so a public host naming that port can be given to the constructor.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final dir = Directory.systemTemp.createTempSync('bw-relay-seam-');
      dirs.add(dir);
      final relay = Relay(data: dir, log: (_) {}, createToken: createToken, publicHost: publicHost?.call(port));
      relays.add(relay);
      await relay.serve(port: port);
      return Uri.parse('http://127.0.0.1:$port');
    }

    const token = 'synthetic-create-token-0001';

    test('without the token the first run stops with the create-token message; with it the wallet is created', () async {
      final base = await start(createToken: token);
      final k = VaultKey.generate();
      final a = WalletRepo.inMemory();
      addTearDown(a.close);
      a.importBatch(january);
      final none = RelayTransport(base, k);
      addTearDown(none.close);
      await expectLater(
          SyncEngine(none, k).run(a), throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('create token'))));
      final wrong = RelayTransport(base, k, createToken: 'synthetic-wrong-token-0002');
      addTearDown(wrong.close);
      await expectLater(SyncEngine(wrong, k).run(a), throwsA(isA<SyncException>()));
      final right = RelayTransport(base, k, createToken: token);
      addTearDown(right.close);
      final r = await SyncEngine(right, k).run(a);
      expect(r.caughtUp, isTrue);
      // A second device of the same wallet needs no token: the wallet exists.
      final b = WalletRepo.inMemory();
      addTearDown(b.close);
      final plain = RelayTransport(base, k);
      addTearDown(plain.close);
      await SyncEngine(plain, k).run(b);
      expect(b.transactions().length, january.transactions.length);
    });

    test('a relay whose public host is the address the client uses verifies; another public host refuses', () async {
      final ok = await start(publicHost: (port) => '127.0.0.1:$port');
      final k = VaultKey.generate();
      final a = WalletRepo.inMemory();
      addTearDown(a.close);
      a.importBatch(january);
      final t = RelayTransport(ok, k);
      addTearDown(t.close);
      expect((await SyncEngine(t, k).run(a)).caughtUp, isTrue);

      final other = await start(publicHost: (_) => 'wallet.example.org');
      final t2 = RelayTransport(other, k);
      addTearDown(t2.close);
      final b = WalletRepo.inMemory();
      addTearDown(b.close);
      b.importBatch(january);
      // Signed for 127.0.0.1:<port>, checked against wallet.example.org: a bad signature, never a stored file.
      await expectLater(SyncEngine(t2, k).run(b), throwsA(isA<SyncException>()));
      expect(dirs.last.listSync().whereType<Directory>(), isEmpty);
    });
  });
}
