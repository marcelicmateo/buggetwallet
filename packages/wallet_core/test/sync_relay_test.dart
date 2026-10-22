// RelayTransport (HTTP client of docs/context/RELAY_PROTOCOL.md) against a fake http.Client and against the real relay
// server in-process; deriveKey; MemoryTransport's relay rules. All data is SYNTHETIC.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

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

/// Forwards to [inner] with the Authorization header replaced (a client with the right wallet id but a wrong token).
class _WrongToken extends http.BaseClient {
  final http.Client inner;
  _WrongToken(this.inner);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final r = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..headers['Authorization'] = 'Bearer synthetic-wrong-token-0000000000000000000000';
    if (request is http.Request) r.bodyBytes = request.bodyBytes;
    return inner.send(r);
  }
}

void main() {
  final key = VaultKey(List.generate(32, (i) => i)); // a synthetic, fixed key

  group('deriveKey', () {
    test('is HKDF-SHA256 with an empty salt; lengths and infos give the expected, unrelated bytes', () async {
      for (final (info, n) in [('bw-relay-id-v1', 16), ('bw-relay-auth-v1', 32), ('bw-local-db-v1', 32), ('x', 64)]) {
        expect(await deriveKey(key, info, length: n), await _hkdf(key.bytes, info, n), reason: info);
      }
      expect(await deriveKey(key, 'a'), isNot(await deriveKey(key, 'b')));
      expect(await deriveKey(key, 'a'), isNot(await deriveKey(VaultKey.generate(), 'a')));
      expect(await deriveKey(key, 'a'), hasLength(32));
    });

    test('relay ids: wid = 32 lowercase hex, token = 43 base64url chars without padding', () async {
      final (wid, token) = await RelayTransport(Uri.parse('http://relay.test:8787'), key).ids;
      expect(wid, _hex(await _hkdf(key.bytes, 'bw-relay-id-v1', 16)));
      expect(wid, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(token, base64Url.encode(await _hkdf(key.bytes, 'bw-relay-auth-v1', 32)).replaceAll('=', ''));
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    });
  });

  group('RelayTransport over a fake client', () {
    late List<http.Request> seen;
    late String wid, token;

    setUp(() async {
      seen = [];
      (wid, token) = await RelayTransport(Uri.parse('http://relay.test'), key).ids;
    });

    RelayTransport client(FutureOr<http.Response> Function(http.Request r) answer, {String base = 'http://relay.test:8787'}) =>
        RelayTransport(Uri.parse(base), key, client: MockClient((r) async {
          seen.add(r);
          return answer(r);
        }));

    test('state: the URL, the bearer token, the parsed JSON; 404 is an empty relay', () async {
      final body = {
        'api': 1,
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
      expect(seen.single.url.toString(), 'http://relay.test:8787/v1/w/$wid/state');
      expect(seen.single.headers['Authorization'], 'Bearer $token');
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

    test('a base address with a path, with or without a trailing slash', () async {
      for (final base in ['http://relay.test:8787/bw', 'http://relay.test:8787/bw/']) {
        seen.clear();
        await client((r) => http.Response('{"api":1,"devices":{}}', 200), base: base).state();
        expect(seen.single.url.path, '/bw/v1/w/$wid/state', reason: base);
      }
    });

    test('put, get, ack and putSnapshot send what the protocol says', () async {
      final t = client((r) => switch (r.method) {
            'GET' => http.Response.bytes([7, 8, 9], 200),
            _ => http.Response('', r.url.path.contains('/ack/') ? 204 : 201),
          });
      await t.put('dev1', 4, [1, 2, 3]);
      expect(await t.get('dev1', 4), [7, 8, 9]);
      await t.ack('dev1', {'dev2': 5, 'dev3': 0});
      await t.putSnapshot('s5-1-ab', {'dev1': 4}, [4, 5]);
      expect(await t.getSnapshot('s5-1-ab'), [7, 8, 9]);
      final [put, get, ack, snap, getSnap] = seen;
      expect((put.method, put.url.path, put.headers['Content-Type']), ('PUT', '/v1/w/$wid/d/dev1/4', 'application/octet-stream'));
      expect(put.bodyBytes, [1, 2, 3]);
      expect((get.method, get.url.path), ('GET', '/v1/w/$wid/d/dev1/4'));
      expect((ack.method, ack.url.path), ('PUT', '/v1/w/$wid/ack/dev1'));
      expect(jsonDecode(ack.body), {'dev2': 5, 'dev3': 0});
      expect((snap.method, snap.url.path), ('PUT', '/v1/w/$wid/snapshot/s5-1-ab'));
      expect(jsonDecode(snap.headers['X-BW-Covers']!), {'dev1': 4});
      expect(snap.bodyBytes, [4, 5]);
      expect(getSnap.url.path, '/v1/w/$wid/snapshot/s5-1-ab');
      for (final r in seen) {
        expect(r.headers['Authorization'], 'Bearer $token');
      }
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
        ('{"api":2,"devices":{}}', TransportFailure.newerApi),
        ('not json', TransportFailure.other),
        ('[1]', TransportFailure.other),
        ('{"devices":{}}', TransportFailure.other),
        ('{"api":1,"devices":{"d":{"first":"x"}}}', TransportFailure.other),
      ]) {
        await expectLater(
            client((r) => http.Response(body, 200)).state(), throwsA(isA<TransportException>().having((e) => e.failure, 'f', failure)),
            reason: body);
      }
    });

    test('health: /v1/health without a token; api 1 is fine, a newer one or no answer throws', () async {
      final requests = <http.Request>[];
      MockClient answering(String body) => MockClient((r) async {
            requests.add(r);
            return http.Response(body, 200);
          });
      await RelayTransport.health(Uri.parse('http://relay.test:8787'), client: answering('{"api":1}'));
      expect(requests.single.url.toString(), 'http://relay.test:8787/v1/health');
      expect(requests.single.headers.containsKey('Authorization'), isFalse);
      await expectLater(RelayTransport.health(Uri.parse('http://relay.test'), client: answering('{"api":2}')),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.newerApi)));
      await expectLater(
          RelayTransport.health(Uri.parse('http://relay.test'), client: MockClient((r) async => throw http.ClientException('down'))),
          throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.unreachable)));
    });

    test('a newer relay API ends a sync run with a SyncException; the outbox is kept', () async {
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      repo.updateSettings({'salary': 1});
      final t = client((r) => http.Response('{"api":2,"devices":{}}', 200));
      await expectLater(SyncEngine(t, key).run(repo), throwsA(isA<SyncException>()));
      expect(repo.pendingOps(), hasLength(1));
    });

    test('logs carry kinds and statuses, never the wallet id, the token or the address', () async {
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
      for (final bad in [wid, token, 'secret-host']) {
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
      b.addManual(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await eb.run(b);
      final back = await ea.run(a);
      expect((back.filesRead, back.caughtUp), (1, true));
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
      // The right wallet id with a wrong token is refused.
      final wrong = RelayTransport(base, k, client: _WrongToken(http.Client()));
      addTearDown(wrong.close);
      await expectLater(SyncEngine(wrong, k).run(WalletRepo.inMemory()), throwsA(isA<SyncException>()));
      expect(logs.join('\n'), isNot(contains((await ta.ids).$2)), reason: 'the relay never logs the token');
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
}
