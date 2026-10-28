// Stage DK (api 5): per-device signing keys, enrolment, approve / revoke, lock (docs/context/RELAY_PROTOCOL.md "Device
// keys"). Requests are signed from the protocol text (test/support.dart), not with the relay's own code. All keys and
// data are SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

const String _state = '/v2/w/$w1/state';
const String _enrol = '/v2/w/$w1/enrol';
const String _lock = '/v2/w/$w1/lock';
String _device(String fp) => '/v2/w/$w1/devices/$fp';

List<int> _json(Object? v) => utf8.encode(jsonEncode(v));

/// Creates [w1] with device key [dev] (countersigned by the wallet key [keyA]) as stream `dev1`.
Future<http.Response> _create(Harness h, {TestKey? dev}) =>
    h.sendV5(dev ?? devA, 'PUT', '/v2/w/$w1/d/dev1/1', body: bytes('one'), wallet: keyA);

Future<http.Response> _enrolAs(Harness h, TestKey dev, {String? deviceId, TestKey? wallet}) =>
    h.sendV5(dev, 'PUT', _enrol, body: _json({if (deviceId != null) 'deviceId': deviceId}), wallet: wallet ?? keyA, withPub: false);

Future<Map<String, Object?>> _stateAs(Harness h, TestKey dev) async {
  final r = await h.sendV5(dev, 'GET', _state);
  expect(r.statusCode, 200, reason: r.body);
  return jsonDecode(r.body) as Map<String, Object?>;
}

Future<http.Response> _approve(Harness h, TestKey by, String fp) => h.sendV5(by, 'PUT', _device(fp), body: _json({'approve': true}));
Future<http.Response> _revoke(Harness h, TestKey by, String fp) => h.sendV5(by, 'PUT', _device(fp), body: _json({'revoke': true}));
Future<http.Response> _setLock(Harness h, TestKey by, bool locked) => h.sendV5(by, 'PUT', _lock, body: _json({'locked': locked}));

String? _error(http.Response r) {
  try {
    final j = jsonDecode(r.body);
    return j is Map ? j['error'] as String? : null;
  } on FormatException {
    return null;
  }
}

Matcher _status(int code, [String? error]) => isA<http.Response>()
    .having((r) => r.statusCode, 'status', code)
    .having((r) => error == null || _error(r) == error, 'error ${error ?? ''}', true);

void main() {
  group('create and enrol', () {
    test('the creating PUT enrols its device key by "wallet"; state lists it to device requests only', () async {
      final h = await freshHarness();
      expect(await _create(h), _status(201));
      final s = await _stateAs(h, devA);
      expect(s['api'], 5);
      expect(s['locked'], false);
      expect(s['pending'], isEmpty);
      final keys = (s['keys'] as List).cast<Map<String, Object?>>();
      expect(keys.single['fp'], await devA.fp());
      expect(keys.single['by'], 'wallet');
      expect(keys.single['self'], true);
      expect(keys.single['revoked'], isNull);
      expect(keys.single['device'], 'dev1');
      // The wallet key (an api-4 app) still works while the wallet is not locked, and sees no device fields.
      final legacy = await h.state(w1);
      expect(legacy['api'], 4);
      expect(legacy.containsKey('keys'), isFalse);
      expect((await h.putData(w1, 'old', 1, 'x')).statusCode, 201);
    });

    test('a creation needs both signatures: no X-BW-WSig → 401 unsigned, a wrong one → 401, nothing created', () async {
      final h = await freshHarness();
      final noW = await h.sendV5(devA, 'PUT', '/v2/w/$w1/d/dev1/1', body: bytes('one'), headers: {'x-bw-pub': await keyA.pub()});
      expect(noW, _status(401, 'unsigned'));
      final wrongW =
          await h.sendV5(devA, 'PUT', '/v2/w/$w1/d/dev1/1', body: bytes('one'), wallet: keyB, headers: {'x-bw-pub': await keyA.pub()});
      expect(wrongW, _status(401, 'bad signature'));
      expect(h.relay.walletCount, 0);
      expect(Directory('${h.dir.path}/$w1').existsSync(), isFalse);
    });

    test('an unknown device key is 401 unenrolled everywhere but enrol; enrol (wallet countersign) → 201, again 200', () async {
      final h = await freshHarness();
      await _create(h);
      for (final (m, p, b) in [
        ('GET', _state, null),
        ('GET', '/v2/w/$w1/d/dev1/1', null),
        ('PUT', '/v2/w/$w1/d/dev2/1', bytes('two')),
        ('PUT', '/v2/w/$w1/ack/dev2', _json({'dev1': 1})),
        ('PUT', _lock, _json({'locked': true})),
        ('PUT', _device(await devA.fp()), _json({'revoke': true})),
      ]) {
        expect(await h.sendV5(devB, m, p, body: b), _status(401, 'unenrolled'), reason: '$m $p');
      }
      expect(await h.sendV5(devB, 'PUT', _enrol, body: _json({})), _status(401, 'unsigned'), reason: 'no wallet countersignature');
      expect(await _enrolAs(h, devB, wallet: keyB), _status(401, 'bad signature'), reason: 'another wallet key');
      expect(await h.send('PUT', _enrol, key: keyA, body: _json({})), _status(401, 'device'), reason: 'the wallet key alone');
      expect(await _enrolAs(h, devB, deviceId: 'b2'), _status(201));
      expect(await _enrolAs(h, devB, deviceId: 'b2'), _status(200));
      expect(await h.sendV5(devB, 'PUT', '/v2/w/$w1/d/dev2/1', body: bytes('two')), _status(201));
      final keys = ((await _stateAs(h, devA))['keys'] as List).cast<Map<String, Object?>>();
      final fpB = await devB.fp();
      final b = keys.firstWhere((k) => k['fp'] == fpB);
      expect((b['by'], b['deviceId'], b['device'], b['self']), ('wallet', 'b2', 'dev2', false));
    });

    test('an api-5 creation that loses the race to a wallet-key creation is unenrolled, then enrols', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'old', 1, 'x')).statusCode, 201);
      expect(await _create(h), _status(401, 'unenrolled'));
      expect(await _enrolAs(h, devA), _status(201));
      expect(await _create(h), _status(201));
    });
  });

  group('locked wallet', () {
    test('lock: the wallet key gets 401 locked, its GET state only {"api":5}; a new key waits, approve, then it syncs', () async {
      final h = await freshHarness();
      await _create(h);
      final lock = await _setLock(h, devA, true);
      expect(lock, _status(200));
      expect(jsonDecode(lock.body), {'locked': true});
      expect(jsonDecode((await h.get(_state, key: keyA)).body), {'api': 5});
      expect(await h.putData(w1, 'old', 1, 'x'), _status(401, 'locked'));
      expect(await h.getData(w1, 'dev1', 1), _status(401, 'locked'));
      expect(await _enrolAs(h, devB, deviceId: 'b2'), _status(202));
      expect(await _enrolAs(h, devB, deviceId: 'b2'), _status(202), reason: 'asked again: still pending');
      expect(await h.sendV5(devB, 'GET', _state), _status(401, 'unenrolled'));
      final s = await _stateAs(h, devA);
      final pending = (s['pending'] as List).cast<Map<String, Object?>>();
      final fpB = await devB.fp();
      expect(pending.single['fp'], fpB);
      expect(pending.single['deviceId'], 'b2');
      expect(s['locked'], true);
      expect(await _approve(h, devB, fpB), _status(401, 'unenrolled'), reason: 'a pending key cannot approve itself');
      expect(await _approve(h, devA, fpB), _status(201));
      expect(await _approve(h, devA, fpB), _status(200), reason: 'approve again: harmless');
      final sB = await _stateAs(h, devB);
      final kB = (sB['keys'] as List).cast<Map<String, Object?>>().firstWhere((k) => k['self'] == true);
      expect(kB['by'], await devA.fp());
      expect(sB['pending'], isEmpty);
      expect(await h.sendV5(devB, 'PUT', '/v2/w/$w1/d/dev2/1', body: bytes('two')), _status(201));
      expect(await h.sendV5(devB, 'GET', '/v2/w/$w1/d/dev1/1'), _status(200));
    });

    test('a replayed approve is harmless; a lock request older than the last change is a no-op (replayed lock)', () async {
      final h = await freshHarness();
      await _create(h);
      final lockHeaders = await h.signV5(devA, 'PUT', _lock, _json({'locked': true}));
      expect(await h.replay('PUT', _lock, lockHeaders, body: _json({'locked': true})), _status(200));
      final fpB = await devB.fp();
      expect(await _enrolAs(h, devB), _status(202));
      final ap = await h.signV5(devA, 'PUT', _device(fpB), _json({'approve': true}));
      expect(await h.replay('PUT', _device(fpB), ap, body: _json({'approve': true})), _status(201));
      expect(await h.replay('PUT', _device(fpB), ap, body: _json({'approve': true})), _status(200));
      h.advance(const Duration(seconds: 30));
      expect(jsonDecode((await _setLock(h, devA, false)).body), {'locked': false});
      // The captured lock (30 s older than the unlock) replayed inside the window changes nothing.
      final again = await h.replay('PUT', _lock, lockHeaders, body: _json({'locked': true}));
      expect(jsonDecode(again.body), {'locked': false});
      expect((await _stateAs(h, devA))['locked'], false);
    });

    test('pending: at most 8; a 9th is 409 pendingFull until one expires (7 days)', () async {
      final h = await freshHarness();
      await _create(h);
      await _setLock(h, devA, true);
      for (var i = 0; i < 8; i++) {
        expect(await _enrolAs(h, TestKey(List<int>.generate(32, (j) => (i * 37 + j * 11 + 5) & 0xff))), _status(202));
      }
      expect(await _enrolAs(h, devB), _status(409, 'pendingFull'));
      h.advance(const Duration(days: 7, minutes: 1));
      expect(await _enrolAs(h, devB), _status(202));
      final pending = (await _stateAs(h, devA))['pending'] as List;
      expect(pending, hasLength(1));
      h.advance(const Duration(days: 8));
      expect((await _stateAs(h, devA))['pending'], isEmpty, reason: 'expired entries are not listed');
      expect(await _approve(h, devA, await devB.fp()), _status(404), reason: 'an expired request cannot be approved');
    });
  });

  group('revoke', () {
    test('a revoked key gets 401 revoked on every endpoint; the revoke locks the wallet; replays harmless', () async {
      final h = await freshHarness();
      await _create(h);
      expect(await _enrolAs(h, devB), _status(201));
      final fpB = await devB.fp();
      final rv = await h.signV5(devA, 'PUT', _device(fpB), _json({'revoke': true}));
      expect(await h.replay('PUT', _device(fpB), rv, body: _json({'revoke': true})), _status(200));
      expect(await h.replay('PUT', _device(fpB), rv, body: _json({'revoke': true})), _status(200), reason: 'again: harmless');
      final s = await _stateAs(h, devA);
      expect(s['locked'], true, reason: 'the removed device still holds the wallet key');
      final kB = (s['keys'] as List).cast<Map<String, Object?>>().firstWhere((k) => k['fp'] == fpB);
      expect(kB['revoked'], isNotNull);
      final hash = [for (final x in (await Sha256().hash(bytes('blob'))).bytes) x.toRadixString(16).padLeft(2, '0')].join();
      for (final (m, p, b, c) in [
        ('GET', _state, null, ''),
        ('GET', '/v2/w/$w1/d/dev1/1', null, ''),
        ('PUT', '/v2/w/$w1/d/dev2/1', bytes('two'), ''),
        ('PUT', '/v2/w/$w1/ack/dev2', _json({'dev1': 1}), ''),
        ('PUT', '/v2/w/$w1/snapshot/s1', bytes('snap'), '{"dev1":1}'),
        ('GET', '/v2/w/$w1/snapshot/s1', null, ''),
        ('PUT', '/v2/w/$w1/blob/$hash', bytes('blob'), ''),
        ('GET', '/v2/w/$w1/blob/$hash', null, ''),
        ('PUT', _lock, _json({'locked': false}), ''),
        ('PUT', _device(await devA.fp()), _json({'revoke': true}), ''),
        ('PUT', _device(fpB), _json({'approve': true}), ''),
      ]) {
        final r = await h.sendV5(devB, m, p, body: b, headers: {if (c.isNotEmpty) 'x-bw-covers': c});
        expect(r, _status(401, 'revoked'), reason: '$m $p');
      }
      expect(await _enrolAs(h, devB), _status(401, 'revoked'), reason: 'cannot enrol again, even with the wallet key');
      expect(await _approve(h, devA, fpB), _status(409, 'revoked'), reason: 'an approve never brings it back');
      expect(await h.get(_state, key: keyA), _status(200));
      expect(jsonDecode((await h.get(_state, key: keyA)).body), {'api': 5}, reason: 'the wallet key alone is locked out');
    });

    test('revoking the last enrolled key is refused (409 lastDevice); a device may remove itself while another remains', () async {
      final h = await freshHarness();
      await _create(h);
      final fpA = await devA.fp();
      expect(await _revoke(h, devA, fpA), _status(409, 'lastDevice'));
      await _enrolAs(h, devB);
      expect(await _revoke(h, devB, await devB.fp()), _status(200));
      expect(await _revoke(h, devA, fpA), _status(409, 'lastDevice'), reason: 'B is revoked: A is the last one');
      expect(await h.sendV5(devA, 'GET', _state), _status(200));
    });

    test('revoking a pending key rejects it for good; unknown fingerprint 404', () async {
      final h = await freshHarness();
      await _create(h);
      await _setLock(h, devA, true);
      expect(await _enrolAs(h, devC), _status(202));
      final fpC = await devC.fp();
      expect(await _revoke(h, devA, fpC), _status(200));
      expect(await _enrolAs(h, devC), _status(401, 'revoked'));
      expect(await _approve(h, devA, fpC), _status(409, 'revoked'));
      expect((await _stateAs(h, devA))['pending'], isEmpty);
      expect(await _approve(h, devA, 'AAAA-AAAA'), _status(404));
      expect(await _revoke(h, devA, 'AAAA-AAAA'), _status(404));
    });
  });

  group('storage', () {
    test('a restart keeps keys, pending and locked (meta v3)', () async {
      final h = await freshHarness();
      await _create(h);
      await _enrolAs(h, devB);
      await _revoke(h, devA, await devB.fp());
      expect(await _enrolAs(h, devC, deviceId: 'c3'), _status(202));
      final before = await _stateAs(h, devA);
      await h.restart();
      expect(await _stateAs(h, devA), before);
      expect(await h.sendV5(devB, 'GET', _state), _status(401, 'revoked'));
      final meta = jsonDecode(File('${h.dir.path}/$w1/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta['v'], 3);
      expect(meta['locked'], true);
      expect((meta['keys'] as Map).keys, hasLength(2));
      expect((meta['pending'] as Map).keys, hasLength(1));
    });

    test('a v2 meta (api-4 relay) loads with no keys and unlocked; devices enrol once and it is saved as v3', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'old', 1, 'x')).statusCode, 201);
      final f = File('${h.dir.path}/$w1/meta.json');
      final meta = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      for (final k in ['keys', 'pending', 'locked', 'lockTime']) {
        meta.remove(k);
      }
      meta['v'] = 2;
      f.writeAsStringSync(jsonEncode(meta));
      await h.restart();
      expect((await h.state(w1))['api'], 4);
      expect(await h.sendV5(devA, 'GET', _state), _status(401, 'unenrolled'));
      expect(await _enrolAs(h, devA), _status(201));
      expect((await _stateAs(h, devA))['keys'], hasLength(1));
      final saved = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      expect(saved['v'], 3);
      expect((saved['devices'] as Map).keys.toList(), ['old'], reason: 'the stream data is kept');
    });

    test('logs carry fingerprints (shortened) and counts, never a device public key or signature', () async {
      final h = await freshHarness();
      await _create(h);
      await _enrolAs(h, devB);
      await _revoke(h, devA, await devB.fp());
      final secrets = [await devA.pub(), await devB.pub(), await keyA.pub(), await devB.fp()];
      for (final l in h.logs) {
        for (final s in secrets) {
          expect(l.contains(s), isFalse, reason: l);
        }
      }
      expect(h.logs.where((l) => l.startsWith('relay keys enrolled=')), isNotEmpty);
      final short = (await devB.fp()).substring(0, 6);
      expect(h.logs.any((l) => l.startsWith('relay revoke 200') && l.contains('d=$short')), isTrue);
    });
  });

  group('hostile input → 4xx, never 5xx', () {
    test('malformed X-BW-Dev / X-BW-WSig, fingerprints and bodies', () async {
      final h = await freshHarness();
      await _create(h);
      final fpA = await devA.fp();
      final cases = <(String, String, List<int>?, Map<String, String>)>[
        ('GET', _state, null, {'x-bw-dev': 'short'}),
        ('GET', _state, null, {'x-bw-dev': '${'A' * 42}='}),
        ('GET', _state, null, {'x-bw-dev': '${'A' * 42}+'}),
        ('PUT', _enrol, _json({}), {'x-bw-wsig': 'x' * 85}),
        ('PUT', _enrol, _json({}), {'x-bw-wsig': '!' * 86}),
        ('PUT', '/v2/w/$w1/devices/abcd-efgh', _json({'approve': true}), {}),
        ('PUT', '/v2/w/$w1/devices/ABCD-EFG1', _json({'approve': true}), {}),
        ('PUT', '/v2/w/$w1/devices/ABCDEFGH', _json({'approve': true}), {}),
        ('PUT', '/v2/w/$w1/devices/ABCD-EFGHI', _json({'approve': true}), {}),
        ('PUT', _device(fpA), utf8.encode('not json'), {}),
        ('PUT', _device(fpA), _json([1]), {}),
        ('PUT', _device(fpA), _json({'approve': false}), {}),
        ('PUT', _device(fpA), _json({'approve': true, 'revoke': true}), {}),
        ('PUT', _device(fpA), _json({'approve': 1}), {}),
        ('PUT', _device(fpA), _json({'delete': true}), {}),
        ('PUT', _device(fpA), List.filled(2000, 0x20), {}),
        ('PUT', _lock, _json({'locked': 'yes'}), {}),
        ('PUT', _lock, _json({'locked': true, 'x': 1}), {}),
        ('PUT', _lock, _json(null), {}),
        ('PUT', _enrol, _json({'deviceId': 'bad id'}), {}),
        ('PUT', _enrol, _json({'deviceId': 7}), {}),
        ('PUT', _enrol, _json({'other': 'x'}), {}),
        ('GET', _enrol, null, {}),
        ('GET', _lock, null, {}),
        ('DELETE', _device(fpA), null, {}),
        ('PUT', '/v2/w/$w1/devices', _json({}), {}),
        ('PUT', '/v2/w/$w1/devices/$fpA/x', _json({}), {}),
      ];
      for (final (m, p, b, hd) in cases) {
        // Device-signed as devA (enrolled) with the overrides after the signature headers; enrol also countersigned.
        final r = await h.sendV5(p == _enrol ? devB : devA, m, p, body: b, wallet: p == _enrol ? keyA : null, withPub: false, headers: hd);
        expect(r.statusCode, inInclusiveRange(400, 499), reason: '$m $p $hd → ${r.statusCode} ${r.body}');
      }
      // The same headers twice → 400.
      final req = http.Request('GET', h.base.resolve(_state))..headers.addAll(await h.signV5(devA, 'GET', _state, const []));
      req.headers['x-bw-dev'] = '${req.headers['x-bw-dev']},${req.headers['x-bw-dev']}';
      final twice = await http.Response.fromStream(await h.client.send(req));
      expect(twice.statusCode, inInclusiveRange(400, 499));
      // A legacy request to a device endpoint, a device signature by the wrong key, an unknown wallet.
      expect(await h.send('PUT', _lock, key: keyA, body: _json({'locked': true})), _status(401, 'device'));
      final forged = await h.signV5(devB, 'GET', _state, const []);
      forged['x-bw-dev'] = await devA.pub();
      expect(await h.replay('GET', _state, forged), _status(401, 'bad signature'));
      expect(await h.sendV5(devA, 'PUT', '/v2/w/$w2/lock', body: _json({'locked': true})), _status(404));
      expect(h.logs.where((l) => l.split(' ').elementAtOrNull(2)?.startsWith('5') ?? false), isEmpty);
    });
  });
}
