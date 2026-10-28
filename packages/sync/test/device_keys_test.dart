// Stage DK (api 5): per-device keys in the client — RelayTransport (signed text v5 checked from the protocol text,
// enrolment, approve / revoke / lock, failures, mixed versions) against a fake client and the real relay, and
// MemoryTransport's device views. All data and keys are SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
List<int> _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

/// Synthetic device seeds.
final List<int> seedA = List.generate(32, (i) => 0x10 ^ i), seedB = List.generate(32, (i) => 0x20 ^ (i * 3));
final List<int> seedC = List.generate(32, (i) => 0x30 ^ (i * 5));

Matcher fails(TransportFailure f) => throwsA(isA<TransportException>().having((e) => e.failure, 'failure', f));
Matcher syncFails(String text) => throwsA(isA<SyncException>().having((e) => e.message, 'message', contains(text)));

/// Records each request's method and path, then sends it.
class _Counting extends http.BaseClient {
  final http.Client inner = http.Client();
  final List<String> seen = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seen.add('${request.method} ${request.url.path}');
    return inner.send(request);
  }
}

Future<String> _pubOf(List<int> seed) async => _b64((await (await Ed25519().newKeyPairFromSeed(seed)).extractPublicKey()).bytes);

/// Whether [r] carries an api-5 signature by device [seed] (and, with [walletPub], `X-BW-WSig` by the wallet key),
/// written from the protocol text: `bw-relay-v5` … `<time>\n<devpub>`.
Future<bool> _signedV5(http.Request r, List<int> seed, {String? walletPub}) async {
  final dev = await _pubOf(seed);
  if (r.headers['X-BW-Dev'] != dev) return false;
  final hash = _hex((await Sha256().hash(r.bodyBytes)).bytes);
  final u = r.url, def = u.scheme == 'https' ? 443 : 80;
  final host = u.hasPort && u.port != def ? '${u.host}:${u.port}' : u.host;
  final text = 'bw-relay-v5\n${r.method}\n$host\n${u.path}\n${r.headers['X-BW-Covers'] ?? ''}\n$hash\n${r.headers['X-BW-Time']}\n$dev';
  final ok = await Ed25519().verify(utf8.encode(text),
      signature: Signature(_unb64(r.headers['X-BW-Sig']!), publicKey: SimplePublicKey(_unb64(dev), type: KeyPairType.ed25519)));
  if (!ok || walletPub == null) return ok;
  final w = r.headers['X-BW-WSig'];
  return w != null &&
      await Ed25519().verify(utf8.encode(text),
          signature: Signature(_unb64(w), publicKey: SimplePublicKey(_unb64(walletPub), type: KeyPairType.ed25519)));
}

void main() {
  final key = VaultKey.generate();

  group('fingerprint and keys', () {
    test('deviceFingerprint: base32 of SHA-256, 8 characters as ABCD-EFGH (independent check)', () async {
      final pub = _unb64(await _pubOf(seedA));
      final h = (await Sha256().hash(pub)).bytes;
      final bits = h.take(5).map((b) => b.toRadixString(2).padLeft(8, '0')).join();
      const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
      final want = [for (var i = 0; i < 8; i++) abc[int.parse(bits.substring(i * 5, i * 5 + 5), radix: 2)]].join();
      expect(deviceFingerprint(pub), '${want.substring(0, 4)}-${want.substring(4)}');
      expect(await RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA).fingerprint, deviceFingerprint(pub));
      expect(await RelayTransport(Uri.parse('http://relay.test'), key).fingerprint, isNull);
      expect(newDeviceKey(), hasLength(32));
      expect(newDeviceKey(), isNot(newDeviceKey()));
      expect(() => RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: [1, 2]), throwsArgumentError);
    });
  });

  group('RelayTransport over a fake client', () {
    test('every request is signed v5 by the device key; seq 1 also carries X-BW-Pub and the wallet countersignature', () async {
      final reqs = <http.Request>[];
      final t = RelayTransport(Uri.parse('http://relay.test:8787'), key, deviceKey: seedA, client: MockClient((r) async {
        reqs.add(r);
        return r.url.path.endsWith('/state') ? http.Response('{"api":5,"devices":{}}', 200) : http.Response('{}', 201);
      }));
      final (_, walletPub) = await t.ids;
      await t.state();
      await t.put('d1', 1, [1, 2]);
      await t.put('d1', 2, [3]);
      expect(await _signedV5(reqs[0], seedA), isTrue);
      expect(reqs[0].headers.containsKey('X-BW-WSig'), isFalse);
      expect(await _signedV5(reqs[1], seedA, walletPub: walletPub), isTrue);
      expect(reqs[1].headers['X-BW-Pub'], walletPub);
      expect(await _signedV5(reqs[2], seedA), isTrue);
      expect(reqs[2].headers.keys.where((h) => h == 'X-BW-Pub' || h == 'X-BW-WSig'), isEmpty);
    });

    test('401 unenrolled → one enrol (wallet countersign, deviceId) → the request again; 202 → pending, no retry', () async {
      final paths = <String>[];
      var enrolAnswer = 201;
      var enrolled = false;
      final (_, walletPub) =
          await RelayTransport(Uri.parse('http://relay.test'), key, client: MockClient((r) async => throw StateError('unused'))).ids;
      final t = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedB, deviceId: 'dev2', client: MockClient((r) async {
        paths.add('${r.method} ${r.url.path.split('/').last}');
        if (r.url.path.endsWith('/enrol')) {
          expect(await _signedV5(r, seedB, walletPub: walletPub), isTrue);
          expect(jsonDecode(r.body), {'deviceId': 'dev2'});
          enrolled = enrolAnswer == 201;
          return http.Response(enrolAnswer == 201 ? '{"enrolled":true}' : '{"pending":true}', enrolAnswer);
        }
        if (!enrolled) return http.Response('{"error":"unenrolled"}', 401);
        return http.Response('{"api":5,"devices":{}}', 200);
      }));
      expect((await t.state()).api, 5);
      expect(paths, ['GET state', 'PUT enrol', 'GET state']);
      enrolled = false;
      enrolAnswer = 202;
      paths.clear();
      await expectLater(t.state(), fails(TransportFailure.pending));
      expect(paths, ['GET state', 'PUT enrol'], reason: 'no health, no third try');
    });

    test('401 revoked is final: no health check, no retry, no enrol', () async {
      final paths = <String>[];
      final t = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA, client: MockClient((r) async {
        paths.add(r.url.path);
        return http.Response('{"error":"revoked"}', 401);
      }));
      await expectLater(t.state(), fails(TransportFailure.revoked));
      await expectLater(t.put('d1', 1, [1]), fails(TransportFailure.revoked));
      await expectLater(t.getBlob('0' * 64), fails(TransportFailure.revoked));
      expect(paths, hasLength(3));
      expect(paths.where((p) => p.endsWith('/health')), isEmpty);
    });

    test('an api-5 client on an api-4 relay: falls back to wallet-key v4, no device features', () async {
      final seen = <http.Request>[];
      final t = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA, client: MockClient((r) async {
        seen.add(r);
        if (r.url.path == '/v2/health') return http.Response('{"api":4}', 200);
        if (r.headers.containsKey('X-BW-Dev')) return http.Response('{"error":"bad signature"}', 401);
        return http.Response('{"api":4,"devices":{}}', 200);
      }));
      final s = await t.state();
      expect((s.api, s.keys, s.locked), (4, null, null));
      expect(t.signApi, 4);
      expect(seen.map((r) => r.url.path.split('/').last), ['state', 'health', 'state']);
      expect(seen.last.headers.keys.where((h) => h == 'X-BW-Dev' || h == 'X-BW-WSig'), isEmpty);
      await expectLater(t.setLocked(true), fails(TransportFailure.olderApi));
      await expectLater(t.approveDevice('ABCD-EFGH'), fails(TransportFailure.olderApi));
      await expectLater(t.revokeDevice('ABCD-EFGH'), fails(TransportFailure.olderApi));
    });

    test('the state JSON: keys, pending and locked parse; missing = an older relay; malformed = other', () async {
      RelayTransport answering(String body) =>
          RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA, client: MockClient((r) async => http.Response(body, 200)));
      final s = await answering(jsonEncode({
        'api': 5,
        'devices': <String, Object?>{},
        'keys': [
          {
            'fp': 'ABCD-EFGH',
            'added': '2026-10-28T10:00:00Z',
            'by': 'wallet',
            'revoked': null,
            'deviceId': 'a',
            'device': 'a-1x',
            'self': true
          },
          {'fp': 'JKLM-NPQR', 'added': '2026-10-28T11:00:00Z', 'by': 'ABCD-EFGH', 'revoked': '2026-10-28T12:00:00Z', 'self': false},
        ],
        'pending': [
          {'fp': 'STUV-WXYZ', 'at': '2026-10-28T13:00:00Z', 'deviceId': 'c'},
        ],
        'locked': true,
      })).state();
      expect(s.keys!.map((k) => (k.fp, k.by, k.isRevoked, k.self, k.device)).toList(), [
        ('ABCD-EFGH', 'wallet', false, true, 'a-1x'),
        ('JKLM-NPQR', 'ABCD-EFGH', true, false, null),
      ]);
      expect(s.pending.single.fp, 'STUV-WXYZ');
      expect(s.locked, isTrue);
      final old = await answering('{"api":5,"devices":{}}').state();
      expect((old.keys, old.pending.length, old.locked), (null, 0, null));
      await expectLater(answering('{"api":5,"devices":{},"keys":{"x":1}}').state(), fails(TransportFailure.other));
      await expectLater(answering('{"api":5,"devices":{},"keys":[{"by":"wallet"}]}').state(), fails(TransportFailure.other));
    });

    test('a malformed fingerprint is refused before any request; lastDevice and pendingFull map to their failures', () async {
      final paths = <String>[];
      final t = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA, client: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.endsWith('/enrol')) return http.Response('{"error":"pendingFull"}', 409);
        return http.Response('{"error":"lastDevice"}', 409);
      }));
      await expectLater(t.revokeDevice('abcd-efgh'), fails(TransportFailure.rejected));
      await expectLater(t.revokeDevice('../state'), fails(TransportFailure.rejected));
      expect(paths, isEmpty);
      await expectLater(t.revokeDevice('ABCD-EFGH'), fails(TransportFailure.lastDevice));
      await expectLater(t.enrol(), fails(TransportFailure.pendingFull), reason: 'its own failure, never pending');
    });
  });

  group('end to end with the relay server (api 5)', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    final logs = <String>[];
    final transports = <RelayTransport>[];

    Future<void> boot() async {
      relay = Relay(data: dir, log: logs.add);
      final server = await relay.serve(port: 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
    }

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('bw-relay-dk-');
      logs.clear();
      await boot();
    });
    tearDown(() async {
      for (final t in transports) {
        t.close();
      }
      transports.clear();
      await relay.close();
      dir.deleteSync(recursive: true);
    });

    RelayTransport transport(List<int>? seed, {String? deviceId, http.Client? client}) {
      final t = RelayTransport(base, key, deviceKey: seed, deviceId: deviceId, client: client);
      transports.add(t);
      return t;
    }

    WalletRepo repo() {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      return r;
    }

    test('create enrols A; B joins (unlocked, enrols itself); lock; C waits, is approved by A and syncs', () async {
      final a = repo(), b = repo(), c = repo();
      final ta = transport(seedA, deviceId: a.deviceId), tb = transport(seedB, deviceId: b.deviceId);
      a.addTransaction(date: '2026-01-21', amount: -450, category: 'Eating out', note: 'synthetic');
      await SyncEngine(ta, key).run(a);
      final s1 = await ta.state();
      expect(s1.api, 5);
      expect(s1.keys!.single.fp, await ta.fingerprint);
      expect((s1.keys!.single.by, s1.keys!.single.self, s1.locked), ('wallet', true, true), reason: 'a new wallet starts locked');
      expect(await ta.setLocked(false), isFalse, reason: 'the owner opens it for joining with the wallet key');
      await SyncEngine(tb, key).run(b);
      expect(b.transactions(), hasLength(1));
      expect(tb.signApi, 5);
      final s2 = await ta.state();
      final fpB = await tb.fingerprint;
      final kb = s2.keys!.firstWhere((k) => k.fp == fpB);
      expect((kb.by, kb.deviceId, kb.self), ('wallet', b.deviceId, false));
      expect(kb.device, isNotNull, reason: 'the stream it last wrote or acked as');
      expect(await ta.setLocked(true), isTrue);
      final tc = transport(seedC, deviceId: c.deviceId);
      c.addTransaction(date: '2026-01-22', amount: -100, category: 'Eating out', note: 'synthetic');
      await expectLater(SyncEngine(tc, key).run(c), syncFails('waits for approval'));
      expect(c.pendingOps(), isNotEmpty, reason: 'nothing lost while waiting');
      final fpC = (await tc.fingerprint)!;
      expect((await ta.state()).pending.single.fp, fpC);
      expect((await ta.state()).pending.single.deviceId, c.deviceId);
      await ta.approveDevice(fpC);
      await ta.approveDevice(fpC); // idempotent
      await SyncEngine(tc, key).run(c);
      expect(c.transactions(), hasLength(2));
      await SyncEngine(ta, key).run(a);
      expect(a.transactions(), hasLength(2));
      expect((await tc.state()).keys!.firstWhere((k) => k.self).by, await ta.fingerprint);
      final pubs = [await _pubOf(seedA), await _pubOf(seedB), await _pubOf(seedC), (await ta.ids).$2];
      expect(logs.where((l) => pubs.any(l.contains)), isEmpty, reason: 'no public key in a relay log line');
    });

    test('a revoked device: every call is revoked, its sync stops with that failure, no retry and no health check', () async {
      final a = repo(), b = repo();
      final ta = transport(seedA);
      final counting = _Counting();
      final tb = transport(seedB, client: counting);
      a.updateSettings({'salary': 150000});
      await SyncEngine(ta, key).run(a);
      await ta.setLocked(false);
      await SyncEngine(tb, key).run(b);
      await ta.revokeDevice((await tb.fingerprint)!);
      await ta.revokeDevice((await tb.fingerprint)!); // idempotent
      expect((await ta.state()).locked, isTrue, reason: 'a revoke locks the wallet');
      b.updateSettings({'salary': 160000});
      counting.seen.clear();
      await expectLater(SyncEngine(tb, key).run(b), syncFails('This device was removed from the wallet.'));
      expect(counting.seen, ['GET /v2/w/${(await tb.ids).$1}/state'], reason: 'one request: no enrol, no health, no retry');
      expect(b.pendingOps(), isNotEmpty);
      await expectLater(tb.get(a.deviceId, 1), fails(TransportFailure.revoked));
      await expectLater(tb.put('x', 1, [1]), fails(TransportFailure.revoked));
      await expectLater(tb.ack('x', {}), fails(TransportFailure.revoked));
      await expectLater(tb.getBlob('0' * 64), fails(TransportFailure.revoked));
      await expectLater(tb.enrol(), fails(TransportFailure.revoked));
      await expectLater(tb.setLocked(false), fails(TransportFailure.revoked));
      await expectLater(tb.revokeDevice((await ta.fingerprint)!), fails(TransportFailure.revoked));
      // The last enrolled key cannot go.
      await expectLater(ta.revokeDevice((await ta.fingerprint)!), fails(TransportFailure.lastDevice));
      // A relay restart keeps all of it.
      await relay.close();
      await boot();
      final ta2 = transport(seedA), tb2 = transport(seedB);
      await expectLater(tb2.state(), fails(TransportFailure.revoked));
      await SyncEngine(ta2, key).run(a);
      expect((await ta2.state()).keys!.where((k) => k.isRevoked), hasLength(1));
    });

    test('an api-4 app (no device key) on this relay syncs while unlocked and gets newerApi once it is locked', () async {
      final a = repo(), old = repo();
      final ta = transport(seedA);
      final tOld = transport(null);
      a.updateSettings({'salary': 150000});
      await SyncEngine(ta, key).run(a);
      await ta.setLocked(false);
      final r = await SyncEngine(tOld, key).run(old);
      expect(r.caughtUp, isTrue);
      expect(old.settings().salary, 150000);
      expect((await tOld.state()).api, 4);
      expect((await tOld.state()).keys, isNull);
      await ta.setLocked(true);
      await expectLater(SyncEngine(tOld, key).run(old), syncFails('Update the app'));
      await expectLater(tOld.put('legacy', 1, [1]), fails(TransportFailure.newerApi));
      await ta.setLocked(false);
      expect((await tOld.state()).api, 4, reason: 'unlocking reopens it to the wallet key');
    });
  });

  group('security review', () {
    test('no downgrade: after an api-5 state the transport never falls back to the wallet key; minApi from the app too', () async {
      var api = 5;
      final seen = <http.Request>[];
      http.Client relay() => MockClient((r) async {
            seen.add(r);
            if (r.url.path == '/v2/health') return http.Response('{"api":$api}', 200);
            if (api == 5) return http.Response('{"api":5,"instance":"${'ab' * 16}","devices":{}}', 200);
            return http.Response('{"error":"bad signature"}', 401); // a "relay" that now claims api 4
          });
      final told = <(int, String?)>[];
      final t =
          RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA, client: relay(), onMinApi: (m, i) => told.add((m, i)));
      expect(t.minApi, 3, reason: 'relayMinApi');
      await t.state();
      expect(t.minApi, 5);
      expect(told, [(5, 'ab' * 16)]);
      await t.state();
      expect(told, hasLength(1), reason: 'told once');
      api = 4;
      seen.clear();
      await expectLater(t.state(), fails(TransportFailure.olderApi));
      expect(t.signApi, 5, reason: 'never lowered');
      expect(seen.where((r) => !r.headers.containsKey('X-BW-Dev') && r.url.path != '/v2/health'), isEmpty,
          reason: 'no request signed with the wallet key alone');
      // A new transport the app builds with the stored value refuses the fallback from the start.
      final t2 = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedA, client: relay(), minApi: 5);
      await expectLater(t2.state(), fails(TransportFailure.olderApi));
      expect(t2.signApi, 5);
    });

    test('pendingFull and tooManyKeys end a run with their own messages', () async {
      for (final (error, text) in [
        ('pendingFull', 'Too many devices are waiting for approval'),
        ('tooManyKeys', 'already has the most devices'),
      ]) {
        final t = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seedB, client: MockClient((r) async {
          if (r.url.path.endsWith('/enrol')) return http.Response('{"error":"$error"}', 409);
          return http.Response('{"error":"unenrolled"}', 401);
        }));
        final repo = WalletRepo.inMemory();
        addTearDown(repo.close);
        await expectLater(SyncEngine(t, key).run(repo), syncFails(text), reason: error);
      }
    });

    test('end to end: revokeOthers removes every other device and the pending ones, locks; tooManyKeys at 16', () async {
      final dir = Directory.systemTemp.createTempSync('bw-relay-dk2-');
      final relay = Relay(data: dir, log: (_) {});
      final server = await relay.serve(port: 0);
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      addTearDown(() async {
        await relay.close();
        dir.deleteSync(recursive: true);
      });
      RelayTransport tr(List<int> seed) {
        final t = RelayTransport(base, key, deviceKey: seed);
        addTearDown(t.close);
        return t;
      }

      final a = WalletRepo.inMemory();
      addTearDown(a.close);
      final ta = tr(seedA), tb = tr(seedB), tc = tr(seedC);
      a.updateSettings({'salary': 1});
      await SyncEngine(ta, key).run(a);
      // Lock changes apply only when signed later than the last one: a few ms apart on the real clock.
      Future<void> later() => Future<void>.delayed(const Duration(milliseconds: 5));
      await later();
      await ta.setLocked(false);
      expect((await tb.state()).api, 5, reason: 'B enrols itself (unlocked)');
      await later();
      await ta.setLocked(true);
      await expectLater(tc.state(), fails(TransportFailure.pending));
      expect(await ta.revokeOthers(), 1);
      await expectLater(tb.state(), fails(TransportFailure.revoked));
      await expectLater(tc.state(), fails(TransportFailure.revoked), reason: 'its request was rejected');
      final s = await ta.state();
      expect((s.locked, s.pending.length, s.keys!.where((k) => !k.isRevoked).length), (true, 0, 1));
      expect(await ta.setLocked(false), isTrue, reason: 'no unlock for 5 minutes after a revoke');
      // 16 enrolled keys at most: 15 approvals more, then the 16th is refused.
      for (var i = 0; i < 16; i++) {
        final t = tr(List.generate(32, (j) => (i * 13 + j * 3 + 1) & 0xff));
        await expectLater(t.state(), fails(TransportFailure.pending));
        if (i < 15) {
          await ta.approveDevice((await t.fingerprint)!);
        } else {
          await expectLater(ta.approveDevice((await t.fingerprint)!), fails(TransportFailure.tooManyKeys));
        }
      }
    });

    test('MemoryTransport: a created wallet is locked; revokeOthers; 16 keys at most; a fingerprint stays with its key', () async {
      var now = DateTime.utc(2026, 10, 1);
      final m = MemoryTransport(now: () => now);
      final va = m.device('key-a'), vb = m.device('key-b'), vc = m.device('key-c');
      await va.put('a', 1, [1]);
      expect(m.locked, isTrue);
      await expectLater(vb.state(), fails(TransportFailure.pending));
      await va.approveDevice(vb.fingerprint);
      await expectLater(vc.state(), fails(TransportFailure.pending));
      now = now.add(const Duration(seconds: 1));
      expect(await va.revokeOthers(), 1);
      expect(await va.revokeOthers(), 0, reason: 'again at the same time: a replay, no change');
      expect(m.revokedKeys, {vb.fingerprint, vc.fingerprint});
      expect(m.enrolledKeys, {va.fingerprint});
      // As the relay: no unlock within 5 minutes of a revoke.
      expect(await va.setLocked(false), isTrue);
      now = now.add(const Duration(minutes: 5, seconds: 1));
      expect(await va.setLocked(false), isFalse);
      for (var i = 0; i < 15; i++) {
        await m.device('more-$i').state();
      }
      await expectLater(m.device('one-too-many').state(), fails(TransportFailure.tooManyKeys));
    });
  });

  group('MemoryTransport device views', () {
    test('create enrols, join enrols (unlocked), lock → pending → approve; revoke → revoked everywhere; wallet key locked out', () async {
      final m = MemoryTransport();
      final va = m.device('key-a', deviceId: 'a'), vb = m.device('key-b', deviceId: 'b'), vc = m.device('key-c', deviceId: 'c');
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory(), c = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      addTearDown(c.close);
      a.updateSettings({'salary': 150000});
      await SyncEngine(va, key).run(a);
      expect(m.enrolledKeys, {va.fingerprint});
      final s = await va.state();
      expect((s.api, s.keys!.single.self, s.keys!.single.by, s.locked), (5, true, 'wallet', true));
      await expectLater(m.state(), fails(TransportFailure.newerApi), reason: 'a new wallet starts locked');
      expect(await va.setLocked(false), isFalse);
      await SyncEngine(vb, key).run(b);
      expect(b.settings().salary, 150000);
      expect(m.enrolledKeys, {va.fingerprint, vb.fingerprint});
      expect(await va.setLocked(true), isTrue);
      await expectLater(m.state(), fails(TransportFailure.newerApi), reason: 'the wallet key alone on a locked wallet');
      await expectLater(SyncEngine(vc, key).run(c), syncFails('waits for approval'));
      expect(m.pendingKeys, {vc.fingerprint});
      expect((await va.state()).pending.single.deviceId, 'c');
      await expectLater(vc.approveDevice(vc.fingerprint), fails(TransportFailure.pending), reason: 'not enrolled: cannot approve');
      await va.approveDevice(vc.fingerprint);
      await SyncEngine(vc, key).run(c);
      expect(c.settings().salary, 150000);
      await va.revokeDevice(vb.fingerprint);
      expect(m.revokedKeys, {vb.fingerprint});
      await expectLater(SyncEngine(vb, key).run(b), syncFails('removed from the wallet'));
      for (final call in <Future<Object?> Function()>[
        vb.state,
        () => vb.get('x', 1),
        () => vb.put('x', 1, [1]),
        () => vb.ack('x', {}),
        () => vb.getSnapshot('s'),
        () => vb.getBlob('0' * 64),
        vb.enrol,
        () => vb.setLocked(false),
        () => vb.approveDevice(vb.fingerprint),
      ]) {
        await expectLater(call(), fails(TransportFailure.revoked));
      }
      await expectLater(va.approveDevice(vb.fingerprint), fails(TransportFailure.conflict), reason: 'never brought back');
      await va.revokeDevice(vc.fingerprint);
      await expectLater(va.revokeDevice(va.fingerprint), fails(TransportFailure.lastDevice));
      await expectLater(va.revokeDevice('AAAA-AAAA'), fails(TransportFailure.missing));
      await expectLater(va.revokeDevice('nope'), fails(TransportFailure.rejected));
    });

    test('pending: at most 8, expired after 7 days; a rejected request can never enrol', () async {
      var now = DateTime.utc(2026, 10, 1);
      final m = MemoryTransport(now: () => now);
      final va = m.device('key-a');
      await va.put('a', 1, [1]);
      await va.setLocked(true);
      for (var i = 0; i < 8; i++) {
        expect(await m.device('wait-$i').enrol(), EnrolResult.pending);
      }
      await expectLater(m.device('late').enrol(), fails(TransportFailure.pendingFull));
      now = now.add(const Duration(days: 7, minutes: 1));
      expect(await m.device('late').enrol(), EnrolResult.pending);
      expect((await va.state()).pending, hasLength(1));
      final late = m.device('late');
      await va.revokeDevice(late.fingerprint);
      await expectLater(late.enrol(), fails(TransportFailure.revoked));
      expect(m.revokedKeys, {late.fingerprint});
    });

    test('revoked between two calls of one run (after state, at the upload or the ack): the run stops there', () async {
      for (final at in ['put', 'ack']) {
        final m = _RevokedAt(at);
        final r = WalletRepo.inMemory();
        addTearDown(r.close);
        r.updateSettings({'salary': 1});
        await expectLater(SyncEngine(m, key).run(r), syncFails('removed from the wallet'), reason: at);
      }
    });
  });
}

/// A relay that revokes this device right after the run's `state`: [at] (`put` or `ack`) answers `revoked`.
class _RevokedAt extends MemoryTransport {
  _RevokedAt(this.at);
  final String at;
  @override
  Future<void> put(String device, int seq, List<int> bytes) async {
    if (at == 'put') throw const TransportException(TransportFailure.revoked, 'revoked');
    return super.put(device, seq, bytes);
  }

  @override
  Future<void> ack(String device, Map<String, int> cursors) async {
    if (at == 'ack') throw const TransportException(TransportFailure.revoked, 'revoked');
    return super.ack(device, cursors);
  }
}
