// Protocol v2 signed requests (docs/context/RELAY_PROTOCOL.md, "Signed requests" and "Threat model"): a captured
// request cannot be reused for anything else, replays inside the window change nothing, the clock window, trust on
// first use of the public key. Synthetic keys and data only.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'support.dart';

/// A wallet with two devices, three files each, both acked up to 1 and one snapshot covering 1.
Future<Harness> twoDevices() async {
  final h = await freshHarness();
  for (final d in ['dev1', 'dev2']) {
    for (var s = 1; s <= 3; s++) {
      expect((await h.putData(w1, d, s, '$d-$s')).statusCode, 201);
    }
  }
  expect((await h.ack(w1, 'dev1', {'dev2': 1})).statusCode, 204);
  expect((await h.ack(w1, 'dev2', {'dev1': 1})).statusCode, 204);
  expect((await h.putSnapshot(w1, 's1', {'dev1': 1, 'dev2': 1}, 'snap-1')).statusCode, 201);
  return h;
}

/// Every stored file of the wallet, by `device/seq`.
Future<Map<String, String>> files(Harness h) async {
  final out = <String, String>{};
  for (final d in ['dev1', 'dev2']) {
    for (var s = 1; s <= 3; s++) {
      final r = await h.getData(w1, d, s);
      out['$d/$s'] = '${r.statusCode} ${r.statusCode == 200 ? r.body : ''}';
    }
  }
  return out;
}

void main() {
  group('a captured request cannot be reused for anything else', () {
    test('another path, method, body, covers or time is 401 and changes nothing', () async {
      final h = await twoDevices();
      final before = await h.state(w1);
      const ackPath = '/v2/w/$w1/ack/dev1';
      final ackBody = bytes(jsonEncode({'dev2': 1}));
      final captured = await h.sign(keyA, 'PUT', ackPath, ackBody);
      expect((await h.replay('PUT', ackPath, captured, body: ackBody)).statusCode, 204, reason: 'the genuine request');

      // Same headers, other path (another device, another endpoint).
      expect((await h.replay('PUT', '/v2/w/$w1/ack/dev2', captured, body: ackBody)).statusCode, 401);
      expect((await h.replay('PUT', '/v2/w/$w1/d/dev1/4', captured, body: ackBody)).statusCode, 401);
      // Other method on a path that has both.
      const getPath = '/v2/w/$w1/d/dev1/3';
      final getSig = await h.sign(keyA, 'GET', getPath, const []);
      expect((await h.replay('PUT', getPath, getSig, body: const [])).statusCode, 401);
      // Other body.
      expect((await h.replay('PUT', ackPath, captured, body: bytes(jsonEncode({'dev2': 3})))).statusCode, 401);
      expect((await h.replay('PUT', ackPath, captured, body: [...ackBody, 32])).statusCode, 401);
      // Other covers on a snapshot.
      const snapPath = '/v2/w/$w1/snapshot/s2';
      final covers = jsonEncode({'dev1': 2, 'dev2': 2});
      final snapSig = await h.sign(keyA, 'PUT', snapPath, bytes('snap-2'), covers: covers);
      expect(
          (await h.replay(
                  'PUT',
                  snapPath,
                  {
                    ...snapSig,
                    'x-bw-covers': jsonEncode({'dev1': 3, 'dev2': 3})
                  },
                  body: bytes('snap-2')))
              .statusCode,
          401);
      expect((await h.replay('PUT', snapPath, snapSig, body: bytes('snap-2'))).statusCode, 400, reason: 'covers signed but not sent');
      expect((await h.replay('PUT', snapPath, {...snapSig, 'x-bw-covers': '{}'}, body: bytes('snap-2'))).statusCode, 401);
      // Other time (the signature is over the time it carries).
      final later = '${h.clock.millisecondsSinceEpoch + 1000}';
      expect((await h.replay('PUT', ackPath, {...captured, 'x-bw-time': later}, body: ackBody)).statusCode, 401);
      // Another wallet id.
      expect((await h.replay('PUT', '/v2/w/$w2/ack/dev1', captured, body: ackBody)).statusCode, 404);

      expect(await h.state(w1), before);
    });

    test('the attack from the v1 problem: acks up to last plus two junk snapshots now fail, nothing is pruned', () async {
      final h = await twoDevices();
      final filesBefore = await files(h);
      final stateBefore = await h.state(w1);
      // The sniffer holds one genuine request (a state read) and replays its headers on everything it wants.
      final captured = await h.sign(keyA, 'GET', '/v2/w/$w1/state', const []);
      for (final d in ['dev1', 'dev2']) {
        final body = bytes(jsonEncode({'dev1': 3, 'dev2': 3}));
        expect((await h.replay('PUT', '/v2/w/$w1/ack/$d', captured, body: body)).statusCode, 401);
      }
      for (final id in ['junk1', 'junk2']) {
        final r = await h.replay(
            'PUT',
            '/v2/w/$w1/snapshot/$id',
            {
              ...captured,
              'x-bw-covers': jsonEncode({'dev1': 3, 'dev2': 3})
            },
            body: bytes('junk'));
        expect(r.statusCode, 401);
      }
      // Nor can it block a device with a junk file at its next seq.
      expect((await h.replay('PUT', '/v2/w/$w1/d/dev1/4', captured, body: bytes('junk'))).statusCode, 401);
      expect(await files(h), filesBefore);
      expect(await h.state(w1), stateBefore);
      expect(Directory('${h.dir.path}/$w1/snap').listSync().map((f) => f.uri.pathSegments.last), ['s1']);
    });
  });

  group('replays inside the window change nothing', () {
    test('PUT d: same bytes again is 200, state unchanged except lastSeen', () async {
      final h = await twoDevices();
      const path = '/v2/w/$w1/d/dev1/4';
      final body = bytes('dev1-4');
      final captured = await h.sign(keyA, 'PUT', path, body);
      expect((await h.replay('PUT', path, captured, body: body)).statusCode, 201);
      final after = await h.device(w1, 'dev1');
      h.advance(const Duration(minutes: 4));
      for (var i = 0; i < 3; i++) {
        expect((await h.replay('PUT', path, captured, body: body)).statusCode, 200);
      }
      final again = await h.device(w1, 'dev1');
      expect(again['last'], after['last']);
      expect(again['first'], after['first']);
      expect((await h.getData(w1, 'dev1', 4)).body, 'dev1-4');
    });

    test('ack: a replayed lower ack never lowers the stored one', () async {
      final h = await twoDevices();
      const path = '/v2/w/$w1/ack/dev2';
      final low = bytes(jsonEncode({'dev1': 1}));
      final captured = await h.sign(keyA, 'PUT', path, low);
      expect((await h.ack(w1, 'dev2', {'dev1': 3})).statusCode, 204);
      expect((await h.replay('PUT', path, captured, body: low)).statusCode, 204);
      expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 3});
    });

    test('snapshot: the same one again is 200; an older one replayed after a newer one cannot take over', () async {
      final h = await twoDevices();
      const path = '/v2/w/$w1/snapshot/s2';
      final covers = jsonEncode({'dev1': 2, 'dev2': 2});
      final body = bytes('snap-2');
      final captured = await h.sign(keyA, 'PUT', path, body, covers: covers);
      final headers = {...captured, 'x-bw-covers': covers};
      expect((await h.replay('PUT', path, headers, body: body)).statusCode, 201);
      final once = await h.state(w1);
      expect((await h.replay('PUT', path, headers, body: body)).statusCode, 200);
      expect(await h.state(w1), once);
      // Two newer snapshots push s2 out; its replay now does not dominate.
      expect((await h.putSnapshot(w1, 's3', {'dev1': 3, 'dev2': 3}, 'snap-3')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's4', {'dev1': 3, 'dev2': 3}, 'snap-4')).statusCode, 201);
      final later = await h.state(w1);
      expect((await h.replay('PUT', path, headers, body: body)).statusCode, 409);
      expect(await h.state(w1), later);
    });
  });

  group('time window', () {
    test('exactly 5 min off either way is accepted; 1 ms more is 401 clock with a Date header', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      for (final ms in [-300000, 300000]) {
        h.skew = Duration(milliseconds: ms);
        expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 200, reason: '$ms');
      }
      for (final ms in [-300001, 300001, 86400000]) {
        h.skew = Duration(milliseconds: ms);
        final r = await h.get('/v2/w/$w1/state', key: keyA);
        expect(r.statusCode, 401, reason: '$ms');
        expect(jsonDecode(r.body), {'error': 'clock'});
        expect(HttpDate.parse(r.headers['date']!), DateTime.utc(2026, 10, 22, 10), reason: 'the relay clock');
      }
    });

    test('a captured request expires: replayed after 5 min it is 401 clock and changes nothing', () async {
      final h = await twoDevices();
      const path = '/v2/w/$w1/d/dev1/4';
      final captured = await h.sign(keyA, 'PUT', path, bytes('dev1-4'));
      h.advance(const Duration(minutes: 5, seconds: 1));
      final r = await h.replay('PUT', path, captured, body: bytes('dev1-4'));
      expect(r.statusCode, 401);
      expect(jsonDecode(r.body), {'error': 'clock'});
      expect((await h.device(w1, 'dev1'))['last'], 3);
    });

    test('a write outside the window on an unknown wallet creates nothing', () async {
      final h = await freshHarness();
      h.skew = const Duration(minutes: -6);
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 401);
      expect(h.relay.walletCount, 0);
      expect(Directory('${h.dir.path}/$w1').existsSync(), isFalse);
    });
  });

  group('keys and headers', () {
    test('wrong key on a known wallet: 401 on every endpoint, nothing changes', () async {
      final h = await twoDevices();
      final before = await h.state(w1);
      expect((await h.get('/v2/w/$w1/state', key: keyB)).statusCode, 401);
      expect((await h.getData(w1, 'dev1', 1, key: keyB)).statusCode, 401);
      expect((await h.getSnapshot(w1, 's1', key: keyB)).statusCode, 401);
      expect((await h.putData(w1, 'dev1', 4, 'x', key: keyB)).statusCode, 401);
      expect((await h.putData(w1, 'dev9', 1, 'x', key: keyB)).statusCode, 401);
      expect((await h.ack(w1, 'dev1', {'dev2': 3}, key: keyB)).statusCode, 401);
      expect((await h.putSnapshot(w1, 's9', {'dev1': 3, 'dev2': 3}, 'x', key: keyB)).statusCode, 401);
      expect(await h.state(w1), before);
    });

    test('X-BW-Pub is ignored once the wallet exists', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      const path = '/v2/w/$w1/state';
      final signedA = await h.sign(keyA, 'GET', path, const []);
      expect((await h.replay('GET', path, {...signedA, 'x-bw-pub': await keyB.pub()})).statusCode, 200);
      final signedB = await h.sign(keyB, 'GET', path, const []);
      expect((await h.replay('GET', path, {...signedB, 'x-bw-pub': await keyB.pub()})).statusCode, 401);
      expect((await h.putData(w1, 'dev2', 1, 'x', key: keyB)).statusCode, 401, reason: 'its own X-BW-Pub does not help');
    });

    test('creation: a signature that does not match X-BW-Pub creates nothing', () async {
      final h = await freshHarness();
      const path = '/v2/w/$w1/d/dev1/1';
      final signedB = await h.sign(keyB, 'PUT', path, bytes('one'));
      final r = await h.replay('PUT', path, {...signedB, 'x-bw-pub': await keyA.pub()}, body: bytes('one'));
      expect(r.statusCode, 401);
      expect(h.relay.walletCount, 0);
      expect(Directory('${h.dir.path}/$w1').existsSync(), isFalse);
      // Signed over another body than the one sent.
      final signedA = await h.sign(keyA, 'PUT', path, bytes('one'));
      expect((await h.replay('PUT', path, signedA, body: bytes('two'))).statusCode, 401);
      expect(h.relay.walletCount, 0);
    });

    test('creation without X-BW-Pub is 401, with a malformed one 400; nothing is created', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, 'one', withPub: false)).statusCode, 401);
      const path = '/v2/w/$w1/d/dev1/1';
      final pub = await keyA.pub();
      for (final bad in ['', 'x', '${pub}A', pub.substring(1), '${pub.substring(0, 42)}=', '${pub.substring(0, 42)}+', '$pub=']) {
        final signed = await h.sign(keyA, 'PUT', path, bytes('one'));
        final r = await h.replay('PUT', path, {...signed, 'x-bw-pub': bad}, body: bytes('one'));
        expect(r.statusCode, bad.isEmpty ? anyOf(400, 401) : 400, reason: bad);
      }
      expect(h.relay.walletCount, 0);
    });

    test('missing signature headers are 401 unsigned; malformed ones 400', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      const path = '/v2/w/$w1/state';
      expect((await h.get(path)).statusCode, 401);
      final good = await h.sign(keyA, 'GET', path, const []);
      expect((await h.replay('GET', path, {'x-bw-time': good['x-bw-time']!})).statusCode, 401);
      expect((await h.replay('GET', path, {'x-bw-sig': good['x-bw-sig']!})).statusCode, 401);
      final now = good['x-bw-time']!;
      for (final t in ['abc', '-1', '+$now', '$now.0', '1' * 17, '9007199254740992', '0x10']) {
        expect((await h.replay('GET', path, {...good, 'x-bw-time': t})).statusCode, 400, reason: 'time $t');
      }
      final sig = good['x-bw-sig']!;
      for (final s in ['', 'x', sig.substring(1), '${sig}A', '$sig==', '${sig.substring(0, 85)}/', '${sig.substring(0, 85)}+']) {
        expect((await h.replay('GET', path, {...good, 'x-bw-sig': s})).statusCode, s.isEmpty ? anyOf(400, 401) : 400, reason: 'sig $s');
      }
      expect((await h.replay('GET', path, good)).statusCode, 200, reason: 'the untouched headers still work');
    });

    test('a signature header sent twice is 400', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      const path = '/v2/w/$w1/state';
      final good = await h.sign(keyA, 'GET', path, const []);
      final s = await Socket.connect('127.0.0.1', h.server.port);
      addTearDown(s.destroy);
      s.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nx-bw-time: ${good['x-bw-time']}\r\nx-bw-sig: ${good['x-bw-sig']}\r\n'
          'x-bw-sig: ${good['x-bw-sig']}\r\n\r\n');
      await s.flush();
      final head = latin1.decode(await s.first.timeout(const Duration(seconds: 10)));
      expect(head.split(' ')[1], '400');
    });

    test('the health endpoint needs no signature', () async {
      final h = await freshHarness();
      final r = await h.get('/v2/health');
      expect(r.statusCode, 200);
      expect(jsonDecode(r.body), {'api': 4});
    });

    test('two concurrent creations with different keys: one wins, the other is 401', () async {
      final h = await freshHarness();
      final rs = await Future.wait([
        h.putData(w1, 'dev1', 1, 'a', key: keyA),
        h.putData(w1, 'dev2', 1, 'b', key: keyB),
      ]);
      expect(rs.map((r) => r.statusCode).toList()..sort(), [201, 401]);
      final winner = rs[0].statusCode == 201 ? keyA : keyB;
      final loser = identical(winner, keyA) ? keyB : keyA;
      expect((await h.get('/v2/w/$w1/state', key: winner)).statusCode, 200);
      expect((await h.get('/v2/w/$w1/state', key: loser)).statusCode, 401);
      expect(((await h.state(w1, key: winner))['devices'] as Map).keys, hasLength(1));
    });
  });

  group('storage', () {
    test('meta.json holds the public key and nothing that can sign', () async {
      final h = await twoDevices();
      final meta = jsonDecode(File('${h.dir.path}/$w1/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta.keys.toSet(), {'v', 'pub', 'instance', 'devices', 'snapshot', 'previous'});
      expect(meta['v'], 2);
      expect(meta['pub'], await keyA.pub());
      final text = File('${h.dir.path}/$w1/meta.json').readAsStringSync();
      expect(text, isNot(contains(base64Url.encode(keyA.seed).replaceAll('=', ''))));
      expect(text, isNot(contains(base64.encode(keyA.seed))));
      expect(text, isNot(contains([for (final b in keyA.seed) b.toRadixString(16).padLeft(2, '0')].join())));
      expect(text, isNot(contains('tokenHash')));
    });

    test('restart keeps the public key: the owner still signs, another key still cannot', () async {
      final h = await twoDevices();
      await h.restart();
      expect((await h.putData(w1, 'dev1', 4, 'dev1-4')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 5, 'x', key: keyB)).statusCode, 401);
      expect((await h.get('/v2/w/$w1/state', key: keyB)).statusCode, 401);
    });

    test('a v1 meta (token hash, no key) is not a wallet: the id is created afresh', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.relay.close();
      final f = File('${h.dir.path}/$w1/meta.json');
      final meta = jsonDecode(f.readAsStringSync()) as Map<String, Object?>
        ..remove('pub')
        ..['v'] = 1
        ..['tokenHash'] = 'ab' * 32;
      f.writeAsStringSync(jsonEncode(meta));
      await h.restart();
      expect(h.relay.walletCount, 0);
      expect((await h.putData(w1, 'dev1', 1, 'fresh', key: keyB)).statusCode, 201);
      expect((await h.getData(w1, 'dev1', 1, key: keyB)).body, 'fresh');
    });

    test('a GET signed over a non-empty body hash is refused (GETs sign the empty body)', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      const path = '/v2/w/$w1/state';
      final wrong = await h.sign(keyA, 'GET', path, Uint8List.fromList([1]));
      expect((await h.replay('GET', path, wrong)).statusCode, 401);
    });
  });
}
