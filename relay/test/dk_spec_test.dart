// Stage DK spec tests (api 5), adversarial, written from docs/context/RELAY_PROTOCOL.md ("Device keys", "Signed requests",
// "Endpoints") only. Requests are signed with the helpers in support.dart (from the protocol text). SYNTHETIC keys only.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

const String _state = '/v2/w/$w1/state';
const String _enrol = '/v2/w/$w1/enrol';
const String _lock = '/v2/w/$w1/lock';
String _dev(String fp) => '/v2/w/$w1/devices/$fp';

List<int> _json(Object? v) => utf8.encode(jsonEncode(v));
Map<String, Object?> _body(http.Response r) => jsonDecode(r.body) as Map<String, Object?>;

String? _err(http.Response r) {
  try {
    final j = jsonDecode(r.body);
    return j is Map ? j['error'] as String? : null;
  } on FormatException {
    return null;
  }
}

/// The key with seed index [n] (device keys for the pending-cap tests).
TestKey _key(int n) => TestKey(List<int>.generate(32, (i) => (0x40 + n * 7) ^ (i * (n + 2))));

/// Creates [w1] with device key [dev] (default devA). Changed (security review): a wallet created by an api-5 app starts
/// locked, so on a 201 this unlocks it a second later (by the creator) and the tests here start from an unlocked wallet
/// as before; the locked start itself is pinned in device_keys_test.dart.
Future<http.Response> _create(Harness h, [TestKey? dev]) async {
  final r = await h.sendV5(dev ?? devA, 'PUT', '/v2/w/$w1/d/dev1/1', body: bytes('one'), wallet: keyA);
  if (r.statusCode == 201) {
    h.advance(const Duration(seconds: 1));
    final u = await _setLock(h, dev ?? devA, false);
    expect(jsonDecode(u.body), {'locked': false}, reason: u.body);
  }
  return r;
}

Future<http.Response> _enrolAs(Harness h, TestKey dev, {TestKey? wallet, String? deviceId}) =>
    h.sendV5(dev, 'PUT', _enrol, body: _json({if (deviceId != null) 'deviceId': deviceId}), wallet: wallet ?? keyA, withPub: false);

Future<http.Response> _approve(Harness h, TestKey by, String fp) => h.sendV5(by, 'PUT', _dev(fp), body: _json({'approve': true}));
Future<http.Response> _revoke(Harness h, TestKey by, String fp) => h.sendV5(by, 'PUT', _dev(fp), body: _json({'revoke': true}));
Future<http.Response> _setLock(Harness h, TestKey by, bool v) => h.sendV5(by, 'PUT', _lock, body: _json({'locked': v}));

Future<Map<String, Object?>> _st(Harness h, TestKey dev) async {
  final r = await h.sendV5(dev, 'GET', _state);
  expect(r.statusCode, 200, reason: r.body);
  return _body(r);
}

/// Signs once and sends; returns the answer and the exact headers (to replay).
Future<(http.Response, Map<String, String>)> _cap(Harness h, TestKey dev, String method, String path, List<int>? body,
    {TestKey? wallet, bool withPub = true}) async {
  final hs = await h.signV5(dev, method, path, body ?? const [], wallet: wallet, withPub: withPub);
  return (await h.replay(method, path, hs, body: body), hs);
}

/// wallet created by devA, devB enrolled (unlocked join).
Future<Harness> _two() async {
  final h = await freshHarness();
  expect((await _create(h)).statusCode, 201);
  h.advance(const Duration(seconds: 1));
  expect((await _enrolAs(h, devB)).statusCode, 201);
  h.advance(const Duration(seconds: 1));
  return h;
}

/// a request that does not reach 5xx whatever it carries.
Matcher get _clientError => predicate<http.Response>((r) => r.statusCode >= 400 && r.statusCode < 500, 'a 4xx answer');

void main() {
  group('create, join, locked join', () {
    test('create enrols the creator by "wallet"; a creation with X-BW-Dev but no (or a foreign) X-BW-WSig creates nothing', () async {
      final h = await freshHarness();
      final noWSig = await h.sendV5(devA, 'PUT', '/v2/w/$w1/d/dev1/1', body: bytes('one'));
      expect(noWSig.statusCode, 401);
      final foreign = await h.sendV5(devA, 'PUT', '/v2/w/$w1/d/dev1/1', body: bytes('one'), wallet: keyA, headers: {
        'x-bw-pub': await keyB.pub(), // wallet key announced is B, countersignature is A's
      });
      expect(foreign.statusCode, 401);
      expect((await h.sendV5(devA, 'GET', _state)).statusCode, 404, reason: 'nothing created');
      expect((await _create(h)).statusCode, 201);
      final s = await _st(h, devA);
      final k = (s['keys'] as List).cast<Map<String, Object?>>().single;
      expect(k['fp'], await devA.fp());
      expect(k['by'], 'wallet');
      expect(k['revoked'], isNull);
      expect(k['self'], true);
    });

    test('join while unlocked needs the wallet countersignature; the right wallet key enrols (201), again 200', () async {
      final h = await _two(); // devB enrolled in _two
      expect((await _enrolAs(h, devB)).statusCode, 200);
      // no WSig at all
      final bare = await h.sendV5(devC, 'PUT', _enrol, body: _json({}));
      expect(bare, _clientError);
      expect(bare.statusCode, isNot(anyOf(200, 201, 202)));
      // another wallet's key countersigns
      final foreign = await _enrolAs(h, devC, wallet: keyB);
      expect(foreign.statusCode, 401);
      expect(_err(await h.sendV5(devC, 'GET', _state)), 'unenrolled');
      expect((await _enrolAs(h, devC, deviceId: 'phone2')).statusCode, 201);
      final keys = ((await _st(h, devA))['keys'] as List).cast<Map<String, Object?>>();
      expect(keys.map((k) => k['fp']), [await devA.fp(), await devB.fp(), await devC.fp()], reason: 'oldest first');
      expect(keys.last['deviceId'], 'phone2');
      expect(keys.last['by'], 'wallet');
    });

    test('locked join: pending (202, again 202 with the same time), unenrolled until approved, approve 201, then it syncs', () async {
      final h = await _two();
      expect((await _setLock(h, devA, true)).statusCode, 200);
      expect((await _enrolAs(h, devC, deviceId: 'x')).statusCode, 202);
      final at1 = ((await _st(h, devA))['pending'] as List).single as Map<String, Object?>;
      h.advance(const Duration(minutes: 1));
      expect((await _enrolAs(h, devC, deviceId: 'x')).statusCode, 202);
      final at2 = ((await _st(h, devA))['pending'] as List).single as Map<String, Object?>;
      expect(at2['at'], at1['at'], reason: 'the time of the first ask is kept');
      expect(at1['fp'], await devC.fp());
      for (final p in [(_state, 'GET'), ('/v2/w/$w1/d/dev1/1', 'GET'), ('/v2/w/$w1/d/c/1', 'PUT')]) {
        final r = await h.sendV5(devC, p.$2, p.$1, body: p.$2 == 'PUT' ? bytes('x') : null);
        expect((r.statusCode, _err(r)), (401, 'unenrolled'), reason: '${p.$2} ${p.$1}');
      }
      final ap = await _approve(h, devA, await devC.fp());
      expect(ap.statusCode, 201);
      expect(_body(ap), {'fp': await devC.fp(), 'status': 'enrolled'});
      expect((await h.sendV5(devC, 'PUT', '/v2/w/$w1/d/c/1', body: bytes('x'))).statusCode, 201);
      final s = await _st(h, devA);
      expect(s['pending'], isEmpty);
      final k = (s['keys'] as List).cast<Map<String, Object?>>().last;
      expect(k['by'], await devA.fp(), reason: 'by = the approver');
      expect(s['locked'], true, reason: 'approving does not unlock');
    });

    test('approve: unknown fp 404, bad fp 400, bad bodies 400, an enrolled key 200, oversized enrol 413', () async {
      final h = await _two();
      expect((await _approve(h, devA, await devC.fp())).statusCode, 404);
      expect((await _approve(h, devA, await devB.fp())).statusCode, 200);
      for (final fp in ['abcd-efgh', 'ABCDEFGH', 'ABCD-EFG', 'ABCD-EFG1', 'ABCD-EFGHI']) {
        expect(await h.sendV5(devA, 'PUT', _dev(fp), body: _json({'approve': true})), _clientError, reason: fp);
      }
      for (final b in [
        <String, Object?>{},
        {'approve': 'yes'},
        {'approve': true, 'revoke': true}
      ]) {
        final r = await h.sendV5(devA, 'PUT', _dev(await devB.fp()), body: _json(b));
        expect(r.statusCode, lessThan(500), reason: '$b');
      }
      final garbage = await h.sendV5(devA, 'PUT', _dev(await devB.fp()), body: bytes('not json'));
      expect(garbage.statusCode, 400);
      expect((await h.sendV5(devC, 'PUT', _enrol, body: bytes('{'), wallet: keyA, withPub: false)).statusCode, 400);
      expect((await h.sendV5(devC, 'PUT', _enrol, body: _json({'deviceId': 5}), wallet: keyA, withPub: false)).statusCode, lessThan(500));
      final big = await h.sendV5(devC, 'PUT', _enrol, body: _json({'deviceId': 'x' * 2000}), wallet: keyA, withPub: false);
      expect(big.statusCode, 413);
    });
  });

  group('revoke', () {
    test('after revoke every endpoint answers 401 revoked for that key (and the others still work)', () async {
      final h = await _two();
      final blob = bytes('sealed blob bytes');
      final hash = [for (final b in (await Sha256().hash(blob)).bytes) b.toRadixString(16).padLeft(2, '0')].join();
      expect((await h.sendV5(devA, 'PUT', '/v2/w/$w1/blob/$hash', body: blob)).statusCode, 201);
      final snap = await h.sendV5(devA, 'PUT', '/v2/w/$w1/snapshot/s1', body: bytes('snap'), headers: {'x-bw-covers': '{"dev1":1}'});
      expect(snap.statusCode, 201, reason: snap.body);

      final calls = <(String, String, List<int>?, Map<String, String>)>[
        ('GET', _state, null, {}),
        ('HEAD', _state, null, {}),
        ('PUT', '/v2/w/$w1/d/dev1/2', bytes('two'), {}),
        ('PUT', '/v2/w/$w1/d/devb/1', bytes('b'), {}),
        ('GET', '/v2/w/$w1/d/dev1/1', null, {}),
        ('PUT', '/v2/w/$w1/ack/devb', _json({'dev1': 1}), {}),
        ('GET', '/v2/w/$w1/snapshot/s1', null, {}),
        ('PUT', '/v2/w/$w1/snapshot/s2', bytes('snap'), {'x-bw-covers': '{"dev1":1}'}),
        ('PUT', '/v2/w/$w1/snapshot/s1/blobs', _json([hash]), {}),
        ('GET', '/v2/w/$w1/blob/$hash', null, {}),
        ('HEAD', '/v2/w/$w1/blob/$hash', null, {}),
        ('PUT', '/v2/w/$w1/blob/$hash', blob, {}),
        ('DELETE', '/v2/w/$w1/blob/$hash', null, {}),
        ('PUT', _enrol, _json({}), {}),
        ('PUT', _dev(await devA.fp()), _json({'approve': true}), {}),
        ('PUT', _dev(await devA.fp()), _json({'revoke': true}), {}),
        ('PUT', _lock, _json({'locked': false}), {}),
      ];
      // control: the enrolled devA is not refused with revoked / unenrolled on the same calls (except self-revoke below)
      for (final c in calls.where((c) => !c.$2.contains('/devices/'))) {
        final r = await h.sendV5(devA, c.$1, c.$2, body: c.$3, headers: c.$4, wallet: c.$2 == _enrol ? keyA : null, withPub: false);
        expect(r.statusCode, isNot(401), reason: 'control ${c.$1} ${c.$2}');
      }
      expect((await _revoke(h, devA, await devB.fp())).statusCode, 200);
      for (final c in calls) {
        final r = await h.sendV5(devB, c.$1, c.$2, body: c.$3, headers: c.$4, wallet: c.$2 == _enrol ? keyA : null, withPub: false);
        expect(r.statusCode, 401, reason: '${c.$1} ${c.$2}');
        if (c.$1 != 'HEAD') expect(_err(r), 'revoked', reason: '${c.$1} ${c.$2}');
      }
      // devA still works, and the revoked key stays listed
      final keys = ((await _st(h, devA))['keys'] as List).cast<Map<String, Object?>>();
      final fpB = await devB.fp();
      expect(keys.firstWhere((k) => k['fp'] == fpB)['revoked'], isNotNull);
    });

    test('revoke also locks; revoking again is 200 and changes nothing; approving a revoked key is 409 revoked', () async {
      final h = await _two();
      expect((await _st(h, devA))['locked'], false);
      final r1 = await _revoke(h, devA, await devB.fp());
      expect(_body(r1), {'fp': await devB.fp(), 'status': 'revoked'});
      final before = await _st(h, devA);
      expect(before['locked'], true);
      h.advance(const Duration(seconds: 30));
      expect((await _revoke(h, devA, await devB.fp())).statusCode, 200);
      final after = await _st(h, devA);
      expect(after['keys'], before['keys'], reason: 'the revoke time is kept');
      final ap = await _approve(h, devA, await devB.fp());
      expect((ap.statusCode, _err(ap)), (409, 'revoked'));
      expect((await _st(h, devA))['keys'], before['keys']);
    });

    test('the wallet key alone after a lock cannot enrol (only pending), approve, unlock, read or write', () async {
      final h = await _two();
      await _revoke(h, devA, await devB.fp());
      // plain v4 wallet-key requests
      for (final r in [
        await h.putData(w1, 'dev1', 2, 'two'),
        await h.getData(w1, 'dev1', 1),
        await h.ack(w1, 'dev1', {'dev1': 1}),
        await h.getSnapshot(w1, 's1'),
        await h.send('PUT', '/v2/w/$w1/blob/${'0' * 64}', key: keyA, body: bytes('x')),
        await h.send('GET', '/v2/w/$w1/blob/${'0' * 64}', key: keyA),
      ]) {
        expect((r.statusCode, _err(r)), (401, 'locked'));
      }
      final st = await h.get(_state, key: keyA);
      expect(st.statusCode, 200);
      expect(_body(st), {'api': 5}, reason: 'nothing else leaks');
      h.v3 = true;
      final st3 = await h.get(_state, key: keyA);
      expect(st3.statusCode, 200);
      expect(_body(st3), {'api': 5});
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 401);
      h.v3 = false;
      // device endpoints need X-BW-Dev
      for (final p in [
        ('PUT', _enrol, _json({})),
        ('PUT', _dev(await devB.fp()), _json({'approve': true})),
        ('PUT', _lock, _json({'locked': false})),
      ]) {
        final r = await h.send(p.$1, p.$2, key: keyA, body: p.$3);
        expect((r.statusCode, _err(r)), (401, 'device'), reason: p.$2);
      }
      expect((await _st(h, devA))['locked'], true);
      // a new device key countersigned by the wallet key is only pending
      expect((await _enrolAs(h, devC)).statusCode, 202);
      expect((await h.sendV5(devC, 'GET', _state)).statusCode, 401);
      // the revoked key cannot enrol again either
      final again = await _enrolAs(h, devB);
      expect((again.statusCode, _err(again)), (401, 'revoked'));
    });

    test('revoking a pending fingerprint rejects it for ever; unknown fingerprint 404', () async {
      final h = await _two();
      await _setLock(h, devA, true);
      await _enrolAs(h, devC);
      expect((await _revoke(h, devA, await devC.fp())).statusCode, 200);
      expect((await _st(h, devA))['pending'], isEmpty);
      h.advance(const Duration(seconds: 2));
      await _setLock(h, devA, false);
      final r = await _enrolAs(h, devC);
      expect((r.statusCode, _err(r)), (401, 'revoked'));
      expect((await _revoke(h, devA, await _key(30).fp())).statusCode, 404);
    });

    test('the last enrolled key cannot be revoked (lastDevice); a device may revoke itself while another remains', () async {
      final h = await freshHarness();
      await _create(h);
      final r = await _revoke(h, devA, await devA.fp());
      expect((r.statusCode, _err(r)), (409, 'lastDevice'));
      expect((await _st(h, devA))['locked'], false, reason: 'refused revoke does not lock');
      await _enrolAs(h, devB);
      expect((await _revoke(h, devB, await devA.fp())).statusCode, 200, reason: 'devB revokes devA');
      final last = await _revoke(h, devB, await devB.fp());
      expect((last.statusCode, _err(last)), (409, 'lastDevice'));
      final h2 = await _two();
      expect((await _revoke(h2, devB, await devB.fp())).statusCode, 200, reason: 'self-revoke with another remaining');
      expect(_err(await h2.sendV5(devB, 'GET', _state)), 'revoked');
    });
  });

  group('who may', () {
    test('only enrolled, non-revoked keys approve / revoke / lock', () async {
      final h = await _two();
      await _setLock(h, devA, true);
      await _enrolAs(h, devC); // pending
      final stranger = _key(1);
      await _revoke(h, devA, await devB.fp());
      final fpC = await devC.fp();
      for (final who in [devC, stranger, devB]) {
        final want = who == devB ? 'revoked' : 'unenrolled';
        for (final r in [
          await _approve(h, who, fpC),
          await _revoke(h, who, await devA.fp()),
          await _setLock(h, who, false),
        ]) {
          expect((r.statusCode, _err(r)), (401, want));
        }
      }
      final s = await _st(h, devA);
      expect(s['locked'], true);
      expect((s['pending'] as List).length, 1);
      expect((s['keys'] as List).length, 2);
    });

    test('lock/unlock by an enrolled key returns the value now; unlock reopens the wallet to the wallet key', () async {
      final h = await _two();
      final l = await _setLock(h, devA, true);
      expect(_body(l), {'locked': true});
      h.advance(const Duration(seconds: 2));
      expect(_body(await _setLock(h, devB, false)), {'locked': false});
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201, reason: 'wallet key works again');
      for (final b in [
        <String, Object?>{},
        {'locked': 'yes'},
        {'locked': null},
        {'locked': 1}
      ]) {
        expect(await h.sendV5(devA, 'PUT', _lock, body: _json(b)), _clientError, reason: '$b');
      }
      expect((await h.sendV5(devA, 'PUT', _lock, body: bytes('zzz'))).statusCode, 400);
    });
  });

  group('replays', () {
    test('approve / revoke / lock / enrol replayed inside the window change nothing more; outside the window refused', () async {
      final h = await _two();
      await _setLock(h, devA, true);
      final enrolReq = await _cap(h, devC, 'PUT', _enrol, _json({'deviceId': 'c'}), wallet: keyA, withPub: false);
      expect(enrolReq.$1.statusCode, 202);
      final fpC = await devC.fp();
      final approveReq = await _cap(h, devA, 'PUT', _dev(fpC), _json({'approve': true}));
      expect(approveReq.$1.statusCode, 201);
      final revokeReq = await _cap(h, devA, 'PUT', _dev(await devB.fp()), _json({'revoke': true}));
      expect(revokeReq.$1.statusCode, 200);
      final lockReq = await _cap(h, devA, 'PUT', _lock, _json({'locked': true}));
      final base = await _st(h, devA);
      h.advance(const Duration(minutes: 2));
      // replay of the enrol of an enrolled key: 200, nothing pending again
      final e = await h.replay('PUT', _enrol, enrolReq.$2, body: _json({'deviceId': 'c'}));
      expect(e.statusCode, 200);
      final a = await h.replay('PUT', _dev(fpC), approveReq.$2, body: _json({'approve': true}));
      expect(a.statusCode, 200);
      final r = await h.replay('PUT', _dev(await devB.fp()), revokeReq.$2, body: _json({'revoke': true}));
      expect(r.statusCode, 200);
      final l = await h.replay('PUT', _lock, lockReq.$2, body: _json({'locked': true}));
      expect(l.statusCode, 200);
      final now = await _st(h, devA);
      expect(now['keys'], base['keys']);
      expect(now['pending'], base['pending']);
      expect(now['locked'], true);
      // the replayed enrol after a later revoke of C is revoked, not re-enrolled
      await _revoke(h, devA, fpC);
      final e2 = await h.replay('PUT', _enrol, enrolReq.$2, body: _json({'deviceId': 'c'}));
      expect((e2.statusCode, _err(e2)), (401, 'revoked'));
      // outside the window (5 minutes): clock
      h.advance(const Duration(minutes: 4));
      for (final x in [
        ('PUT', _enrol, enrolReq.$2, _json({'deviceId': 'c'})),
        ('PUT', _dev(fpC), approveReq.$2, _json({'approve': true})),
        ('PUT', _dev(await devB.fp()), revokeReq.$2, _json({'revoke': true})),
        ('PUT', _lock, lockReq.$2, _json({'locked': true})),
      ]) {
        final o = await h.replay(x.$1, x.$2, x.$3, body: x.$4);
        expect((o.statusCode, _err(o)), (401, 'clock'), reason: x.$2);
      }
    });

    test('a lock then unlock replayed in the wrong order does not flip the state', () async {
      final h = await _two();
      final lockReq = await _cap(h, devA, 'PUT', _lock, _json({'locked': true}));
      expect(lockReq.$1.statusCode, 200);
      h.advance(const Duration(seconds: 3));
      final unlockReq = await _cap(h, devA, 'PUT', _lock, _json({'locked': false}));
      expect(_body(unlockReq.$1), {'locked': false});
      // wrong order: the older lock again, and the unlock again
      final again = await h.replay('PUT', _lock, lockReq.$2, body: _json({'locked': true}));
      expect(again.statusCode, 200);
      expect(_body(again), {'locked': false}, reason: 'no-op with the current value');
      expect((await _st(h, devA))['locked'], false);
      final again2 = await h.replay('PUT', _lock, unlockReq.$2, body: _json({'locked': false}));
      expect(_body(again2), {'locked': false});
      // equal time: a second change with the same X-BW-Time is not "later"
      h.advance(const Duration(seconds: 1));
      final lock2 = await _cap(h, devA, 'PUT', _lock, _json({'locked': true}));
      expect(_body(lock2.$1), {'locked': true});
      final unlock2 = await _cap(h, devA, 'PUT', _lock, _json({'locked': false}));
      expect(_body(unlock2.$1), {'locked': true}, reason: 'same millisecond: not later than lockTime');
    });

    test('a revoke sets lockTime: an older unlock cannot reopen the wallet', () async {
      final h = await _two();
      h.skew = const Duration(seconds: -2);
      final oldUnlock = await _cap(h, devA, 'PUT', _lock, _json({'locked': false}));
      h.skew = Duration.zero;
      expect((await _revoke(h, devA, await devB.fp())).statusCode, 200);
      final r = await h.replay('PUT', _lock, oldUnlock.$2, body: _json({'locked': false}));
      expect(r.statusCode, 200);
      expect(_body(r), {'locked': true});
      expect((await _st(h, devA))['locked'], true);
    });
  });

  group('signature binding', () {
    test('a request signed for one wallet or host does not verify at another', () async {
      final h = await freshHarness();
      await _create(h);
      // second wallet, same device key, other wallet key
      expect((await h.sendV5(devA, 'PUT', '/v2/w/$w2/d/dev1/1', body: bytes('one'), wallet: keyB)).statusCode, 201);
      final hs = await h.signV5(devA, 'GET', '/v2/w/$w1/state', const []);
      final cross = await h.replay('GET', '/v2/w/$w2/state', hs);
      expect((cross.statusCode, _err(cross)), (401, 'bad signature'));
      // a lock for w1 replayed at w2
      final lk = await h.signV5(devA, 'PUT', _lock, _json({'locked': true}));
      expect((await h.replay('PUT', '/v2/w/$w2/lock', lk, body: _json({'locked': true}))).statusCode, 401);
      expect((await _st(h, devA))['locked'], false);
      // enrol countersigned for w1 does not enrol at w2 (other wallet key and path)
      final en = await h.signV5(devB, 'PUT', _enrol, _json({}), wallet: keyA);
      expect((await h.replay('PUT', '/v2/w/$w2/enrol', en, body: _json({}))).statusCode, 401);
      // other host
      h.signHost = 'other.example.org';
      final host = await h.sendV5(devA, 'GET', _state);
      expect((host.statusCode, _err(host)), (401, 'bad signature'));
      h.signHost = null;
      expect((await h.sendV5(devA, 'GET', _state)).statusCode, 200);
    });

    test('a GET signature does not authorize HEAD; v4 text with X-BW-Dev, v5 text without it, a swapped key all fail', () async {
      final h = await _two();
      final get = await h.signV5(devA, 'GET', _state, const []);
      expect((await h.replay('HEAD', _state, get)).statusCode, 401);
      // v4 text signed by the device key but sent with X-BW-Dev
      final v4 = await h.sign(devA, 'GET', _state, const []);
      final withDev = await h.replay('GET', _state, {...v4, 'x-bw-dev': await devA.pub()});
      expect(withDev.statusCode, 401);
      // v5 headers without X-BW-Dev: only v4/v3 with the wallet key are checked
      final noDev = Map.of(get)..remove('x-bw-dev');
      expect((await h.replay('GET', _state, noDev)).statusCode, 401);
      // devA's signature under devB's public key
      final swapped = {...get, 'x-bw-dev': await devB.pub()};
      expect((await h.replay('GET', _state, swapped)).statusCode, 401);
      // a device key's v4 signature as a wallet-key request (no X-BW-Dev)
      expect((await h.replay('GET', _state, v4)).statusCode, 401);
      // an unenrolled key with a valid signature is "unenrolled", not "bad signature"
      expect(_err(await h.sendV5(devC, 'GET', _state)), 'unenrolled');
    });

    test('malformed, duplicated, mismatched X-BW-Dev / X-BW-WSig answer 4xx, never 5xx; nothing changes', () async {
      final h = await _two();
      final before = await _st(h, devA);
      final good = await h.signV5(devC, 'PUT', _enrol, _json({}), wallet: keyA, withPub: false);
      final badDev = <String>[
        '',
        'short',
        'A' * 42,
        'A' * 44,
        '!' * 43,
        '${'A' * 42}=',
        '${'A' * 21} ${'A' * 21}',
        await devA.pub() + await devB.pub(),
      ];
      for (final d in badDev) {
        for (final p in [
          ('GET', _state, <int>[]),
          ('PUT', _enrol, _json({})),
          ('PUT', _lock, _json({'locked': true})),
          ('PUT', '/v2/w/$w1/d/dev1/9', bytes('x')),
        ]) {
          final r = await h.replay(p.$1, p.$2, {...good, 'x-bw-dev': d}, body: p.$3.isEmpty ? null : p.$3);
          expect(r, _clientError, reason: 'dev "$d" ${p.$2}');
        }
      }
      for (final w in ['', 'x', 'A' * 85, 'A' * 87, '!' * 86, 'A' * 86, (await keyB.sign('other text'))]) {
        final r = await h.replay('PUT', _enrol, {...good, 'x-bw-wsig': w}, body: _json({}));
        expect(r, _clientError, reason: 'wsig "$w"');
      }
      // WSig of the right wallet key but over another text
      final wrongText = await h.replay('PUT', _enrol, {...good, 'x-bw-wsig': await keyA.sign('bw-relay-v5\nPUT\nx')}, body: _json({}));
      expect(wrongText.statusCode, 401);
      // WSig made by the device key instead of the wallet key
      final bySelf = await h.replay('PUT', _enrol, {...good, 'x-bw-wsig': good['x-bw-sig']!}, body: _json({}));
      expect(bySelf.statusCode, 401);
      // X-BW-Dev of devC but signature of devA
      final mism = await h.signV5(devA, 'PUT', _enrol, _json({}), wallet: keyA, withPub: false);
      final m = await h.replay('PUT', _enrol, {...mism, 'x-bw-dev': await devC.pub()}, body: _json({}));
      expect(m.statusCode, 401);
      // sent twice (raw client: two header lines)
      for (final hdr in ['x-bw-dev', 'x-bw-wsig', 'x-bw-sig', 'x-bw-time']) {
        final c = HttpClient();
        try {
          final req = await c.putUrl(h.base.resolve(_enrol));
          good.forEach((k, v) => req.headers.set(k, v));
          req.headers.add(hdr, good[hdr]!);
          req.add(_json({}));
          final resp = await req.close();
          await resp.drain<void>();
          expect(resp.statusCode, allOf(greaterThanOrEqualTo(400), lessThan(500)), reason: 'duplicate $hdr');
        } finally {
          c.close(force: true);
        }
      }
      expect(await _st(h, devA), before);
      // the good request still works afterwards
      expect((await h.replay('PUT', _enrol, good, body: _json({}))).statusCode, 201);
    });

    test('X-BW-Dev present but X-BW-Time or X-BW-Sig missing: 401 unsigned', () async {
      final h = await _two();
      final good = await h.signV5(devA, 'GET', _state, const []);
      expect((await h.replay('GET', _state, Map.of(good)..remove('x-bw-sig'))).statusCode, 401);
      expect((await h.replay('GET', _state, Map.of(good)..remove('x-bw-time'))).statusCode, 401);
      expect((await h.replay('GET', _state, {'x-bw-dev': await devA.pub()})).statusCode, 401);
    });
  });

  group('pending cap, expiry, restart', () {
    test('8 pending at most (9th 409 pendingFull, a known one still 202); each drops 7 days after its first ask', () async {
      final h = await _two();
      await _setLock(h, devA, true);
      for (var i = 0; i < 8; i++) {
        expect((await _enrolAs(h, _key(i))).statusCode, 202, reason: 'key $i');
      }
      final full = await _enrolAs(h, _key(8));
      expect((full.statusCode, _err(full)), (409, 'pendingFull'));
      expect((await _enrolAs(h, _key(3))).statusCode, 202);
      expect((await _st(h, devA))['pending'] as List, hasLength(8));
      // approving one frees a place
      expect((await _approve(h, devA, await _key(0).fp())).statusCode, 201);
      expect((await _enrolAs(h, _key(8))).statusCode, 202);
      // 6 days 23 h later the first asks are still there, after 7 days they are gone (and cannot be approved)
      h.advance(const Duration(days: 6, hours: 23));
      expect((await _st(h, devA))['pending'] as List, hasLength(8));
      h.advance(const Duration(hours: 2));
      final s = await _st(h, devA);
      expect(s['pending'], isEmpty);
      final ap = await _approve(h, devA, await _key(5).fp());
      expect(ap.statusCode, 404);
      expect((await h.sendV5(_key(5), 'GET', _state)).statusCode, 401);
      // and the places are free again
      expect((await _enrolAs(h, _key(5))).statusCode, 202);
    });

    test('restart keeps keys, revoked, pending and locked', () async {
      final h = await _two();
      await _setLock(h, devA, true);
      await _enrolAs(h, devC, deviceId: 'cc');
      await _enrolAs(h, _key(2));
      await _revoke(h, devA, await _key(2).fp());
      final before = await _st(h, devA);
      expect(before['locked'], true);
      await h.restart();
      final after = await _st(h, devA);
      expect(after['keys'], before['keys']);
      expect(after['pending'], before['pending']);
      expect(after['locked'], true);
      expect((await _approve(h, devA, await devC.fp())).statusCode, 201);
      await _revoke(h, devA, await devB.fp());
      await h.restart();
      expect(_err(await h.sendV5(devB, 'GET', _state)), 'revoked');
      expect((await h.putData(w1, 'dev1', 2, 'x')).statusCode, 401, reason: 'still locked');
      expect((await h.sendV5(devC, 'GET', _state)).statusCode, 200);
    });
  });

  group('api-4 and api-3 clients', () {
    test('wallet-key v4 / v3 work while unlocked (state says 4 / 3); after a lock the documented 401 locked, state {"api":5}', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201, reason: 'api-4 app creates the wallet');
      expect((await h.state(w1))['api'], 4);
      expect((await _enrolAs(h, devA)).statusCode, 201, reason: 'a device enrols with the wallet key alone');
      h.v3 = true;
      expect((await h.state(w1))['api'], 3);
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201);
      h.v3 = false;
      expect((await _setLock(h, devA, true)).statusCode, 200);
      for (final v3 in [false, true]) {
        h.v3 = v3;
        final w = await h.putData(w1, 'dev1', 3, 'three');
        expect((w.statusCode, _err(w)), (401, 'locked'));
        final g = await h.getData(w1, 'dev1', 1);
        expect((g.statusCode, _err(g)), (401, 'locked'));
        expect((await h.ack(w1, 'dev1', {'dev1': 1})).statusCode, 401);
        final s = await h.get(_state, key: keyA);
        expect(s.statusCode, 200);
        expect(_body(s), {'api': 5});
      }
      h.v3 = false;
      expect((await h.get('/v2/health')).body, contains('"api":5'));
      // the device sees the stored data intact, nothing was written
      expect(((await _st(h, devA))['devices'] as Map<String, Object?>)['dev1'], containsPair('last', 2));
      h.advance(const Duration(seconds: 2));
      await _setLock(h, devA, false);
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
    });
  });
}
