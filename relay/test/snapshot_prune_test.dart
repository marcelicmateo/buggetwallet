import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

Future<void> putMany(Harness h, String dev, int n, {String wallet = w1}) async {
  for (var s = 1; s <= n; s++) {
    expect((await h.putData(wallet, dev, s, '$dev-$s')).statusCode, anyOf(200, 201));
  }
}

void main() {
  group('snapshot PUT', () {
    test('the first snapshot is 201 and can be fetched; others are 404', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 2}, 'snap-bytes')).statusCode, 201);
      final r = await h.getSnapshot(w1, 's1');
      expect(r.statusCode, 200);
      expect(r.body, 'snap-bytes');
      expect(r.headers['content-type'], 'application/octet-stream');
      expect((await h.getSnapshot(w1, 's2')).statusCode, 404);
      expect((await h.state(w1))['snapshot'], {
        'id': 's1',
        'covers': {'dev1': 2}
      });
      expect((await h.state(w1))['previous'], isNull);
    });

    test('covers must dominate the current snapshot for every device in it', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 3);
      await putMany(h, 'dev2', 3);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 2, 'dev2': 2}, 'a')).statusCode, 201);
      // Lower for one device: 409.
      expect((await h.putSnapshot(w1, 's2', {'dev1': 3, 'dev2': 1}, 'b')).statusCode, 409);
      // A device of the current snapshot missing: 409.
      expect((await h.putSnapshot(w1, 's2', {'dev1': 3}, 'b')).statusCode, 409);
      expect((await h.putSnapshot(w1, 's2', {}, 'b')).statusCode, 409);
      // Equal is fine, higher is fine.
      expect((await h.putSnapshot(w1, 's2', {'dev1': 2, 'dev2': 2}, 'b')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's3', {'dev1': 3, 'dev2': 2}, 'c')).statusCode, 201);
      final s = await h.state(w1);
      expect(s['snapshot'], {
        'id': 's3',
        'covers': {'dev1': 3, 'dev2': 2}
      });
      expect(s['previous'], {
        'id': 's2',
        'covers': {'dev1': 2, 'dev2': 2}
      });
    });

    test('a device the current snapshot does not mention may be added', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 1);
      await putMany(h, 'dev2', 1);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'a')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's2', {'dev1': 1, 'dev2': 1}, 'b')).statusCode, 201);
    });

    test('covers beyond a device last (or of an unknown device) are 422', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 3}, 'a')).statusCode, 422);
      expect((await h.putSnapshot(w1, 's1', {'ghost': 1}, 'a')).statusCode, 422);
      expect((await h.getSnapshot(w1, 's1')).statusCode, 404);
      expect((await h.state(w1))['snapshot'], isNull);
      expect((await h.putSnapshot(w1, 's1', {'ghost': 0}, 'a')).statusCode, 201);
    });

    test('422 wins over 409 when both apply', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      await h.putSnapshot(w1, 's1', {'dev1': 2}, 'a');
      expect((await h.putSnapshot(w1, 's2', {'dev1': 1, 'ghost': 5}, 'b')).statusCode, 422);
    });

    test('bad X-BW-Covers headers are 400, and nothing changes', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: bytes('a'))).statusCode, 400);
      for (final bad in ['nope', '[]', '{"dev1":"1"}', '{"dev1":-1}', '{"dev1":1.5}', '{"a b":1}', '"x"', '{"dev1":null}']) {
        final r = await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: bytes('a'), headers: {'x-bw-covers': bad});
        expect(r.statusCode, 400, reason: bad);
      }
      expect((await h.state(w1))['snapshot'], isNull);
    });

    test('the latest moves to previous and the older previous is deleted from disk', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 3);
      await h.putSnapshot(w1, 's1', {'dev1': 1}, 'one');
      await h.putSnapshot(w1, 's2', {'dev1': 2}, 'two');
      expect((await h.getSnapshot(w1, 's1')).body, 'one');
      expect((await h.getSnapshot(w1, 's2')).body, 'two');
      await h.putSnapshot(w1, 's3', {'dev1': 3}, 'three');
      expect((await h.getSnapshot(w1, 's1')).statusCode, 404);
      expect((await h.getSnapshot(w1, 's2')).body, 'two');
      expect((await h.getSnapshot(w1, 's3')).body, 'three');
      final files = Directory('${h.dir.path}/$w1/snap').listSync().map((f) => f.uri.pathSegments.last).toSet();
      expect(files, {'s2', 's3'});
    });

    test('a rejected snapshot leaves the kept ones alone', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      await h.putSnapshot(w1, 's1', {'dev1': 2}, 'one');
      await h.putSnapshot(w1, 's2', {'dev1': 1}, 'two'); // 409
      await h.putSnapshot(w1, 's3', {'dev1': 5}, 'three'); // 422
      expect((await h.getSnapshot(w1, 's1')).body, 'one');
      expect((await h.getSnapshot(w1, 's2')).statusCode, 404);
      expect((await h.getSnapshot(w1, 's3')).statusCode, 404);
      expect(Directory('${h.dir.path}/$w1/snap').listSync(), hasLength(1));
    });

    test('the same id again: 200 for the same bytes and covers, 409 otherwise', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'one')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'one')).statusCode, 200);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'ONE')).statusCode, 409);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 2}, 'one')).statusCode, 409);
      expect((await h.putSnapshot(w1, 's2', {'dev1': 2}, 'two')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'one')).statusCode, 200); // previous, idempotent
      expect((await h.state(w1))['snapshot'], {
        'id': 's2',
        'covers': {'dev1': 2}
      });
      expect((await h.getSnapshot(w1, 's1')).body, 'one');
    });

    test('413 above 64 MiB', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 1);
      final big = List<int>.filled(64 * 1024 * 1024 + 1, 7);
      final r = await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: big, headers: {'x-bw-covers': '{}'});
      expect(r.statusCode, 413);
      expect((await h.state(w1))['snapshot'], isNull);
    });

    test('snapshots of two wallets do not mix', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 1);
      await h.putData(w2, 'dev1', 1, 'x', key: keyB);
      await h.putSnapshot(w1, 's1', {'dev1': 1}, 'mine');
      expect((await h.getSnapshot(w2, 's1', key: keyB)).statusCode, 404);
      expect((await h.getSnapshot(w1, 's1', key: keyB)).statusCode, 401);
    });
  });

  group('pruning', () {
    test('nothing is pruned without a snapshot', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 3);
      await h.ack(w1, 'dev2', {'dev1': 3});
      expect((await h.device(w1, 'dev1'))['first'], 1);
    });

    test('a single device is pruned as far as the snapshot covers', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 4);
      await h.putSnapshot(w1, 's1', {'dev1': 3}, 'a');
      expect(await h.device(w1, 'dev1'), containsPair('first', 4));
      expect((await h.getData(w1, 'dev1', 4)).statusCode, 200);
      expect(File('${h.dir.path}/$w1/d/dev1/3').existsSync(), isFalse);
      expect(File('${h.dir.path}/$w1/d/dev1/4').existsSync(), isTrue);
    });

    test('every recently seen other device must have acked, the slowest one decides', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 5);
      await putMany(h, 'dev2', 1);
      await putMany(h, 'dev3', 1);
      await h.putSnapshot(w1, 's1', {'dev1': 5}, 'a');
      // dev2 and dev3 never acked dev1: nothing goes.
      expect((await h.device(w1, 'dev1'))['first'], 1);
      await h.ack(w1, 'dev2', {'dev1': 4});
      expect((await h.device(w1, 'dev1'))['first'], 1);
      await h.ack(w1, 'dev3', {'dev1': 2});
      expect((await h.device(w1, 'dev1'))['first'], 3); // up to min(5, 4, 2) = 2
      await h.ack(w1, 'dev3', {'dev1': 5});
      expect((await h.device(w1, 'dev1'))['first'], 5); // up to min(5, 4, 5) = 4
      await h.ack(w1, 'dev2', {'dev1': 5});
      expect(await h.device(w1, 'dev1'), containsPair('first', 6)); // all pruned: last + 1
      expect(await h.device(w1, 'dev1'), containsPair('last', 5));
    });

    test('both kept snapshots must cover a file', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 6);
      await h.putSnapshot(w1, 's1', {'dev1': 2}, 'a');
      expect((await h.device(w1, 'dev1'))['first'], 3); // only s1 kept so far
      await h.putSnapshot(w1, 's2', {'dev1': 6}, 'b');
      // previous is s1 (covers 2), so nothing new goes.
      expect((await h.device(w1, 'dev1'))['first'], 3);
      await h.putSnapshot(w1, 's3', {'dev1': 6}, 'c');
      // kept: s3 and s2, both cover 6.
      expect((await h.device(w1, 'dev1'))['first'], 7);
    });

    test('a snapshot that does not mention a device covers none of its files', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      await putMany(h, 'dev2', 2);
      await h.putSnapshot(w1, 's1', {'dev1': 2}, 'a');
      expect((await h.device(w1, 'dev1'))['first'], 1); // dev2 has not acked dev1
      expect((await h.device(w1, 'dev2'))['first'], 1);
    });

    test('a device does not need to ack its own files', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      await h.ack(w1, 'dev1', {'dev1': 0});
      await h.putSnapshot(w1, 's1', {'dev1': 2}, 'a');
      expect((await h.device(w1, 'dev1'))['first'], 3);
    });

    test('an ack that arrives after the snapshot triggers pruning', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 3);
      await putMany(h, 'dev2', 1);
      await h.putSnapshot(w1, 's1', {'dev1': 3}, 'a');
      expect((await h.device(w1, 'dev1'))['first'], 1);
      expect((await h.ack(w1, 'dev2', {'dev1': 3})).statusCode, 204);
      expect((await h.device(w1, 'dev1'))['first'], 4);
    });

    test('a new file after a snapshot keeps the later seqs and pruning counts bytes', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 2);
      await h.putSnapshot(w1, 's1', {'dev1': 2}, 'a');
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
      expect(await h.device(w1, 'dev1'), containsPair('first', 3));
      expect(await h.device(w1, 'dev1'), containsPair('last', 3));
    });

    group('90-day rule', () {
      Future<Harness> twoDevices() async {
        final h = await freshHarness();
        await putMany(h, 'dev1', 3);
        await putMany(h, 'dev2', 1); // dev2 seen now, never acks
        await h.putSnapshot(w1, 's1', {'dev1': 3}, 'a');
        expect((await h.device(w1, 'dev1'))['first'], 1);
        return h;
      }

      test('a device seen exactly 90 days ago still holds pruning back', () async {
        final h = await twoDevices();
        h.advance(const Duration(days: 90));
        await h.putData(w1, 'dev1', 4, 'four');
        expect((await h.device(w1, 'dev1'))['first'], 1);
      });

      test('a device unseen for 91 days no longer holds it back', () async {
        final h = await twoDevices();
        h.advance(const Duration(days: 91));
        await h.putData(w1, 'dev1', 4, 'four'); // any accepted PUT triggers the check
        expect(await h.device(w1, 'dev1'), containsPair('first', 4)); // snapshot covers 3
        expect((await h.getData(w1, 'dev1', 3)).statusCode, 410);
        // dev2 is still listed and may come back: its own file is intact.
        expect((await h.getData(w1, 'dev2', 1)).statusCode, 200);
      });

      test('an ack of the stale device brings it back as a holder', () async {
        final h = await twoDevices();
        h.advance(const Duration(days: 91));
        await h.ack(w1, 'dev2', {'dev1': 1}); // seen now, acked only 1
        expect((await h.device(w1, 'dev1'))['first'], 2);
        await h.putData(w1, 'dev1', 4, 'four');
        expect((await h.device(w1, 'dev1'))['first'], 2);
        h.advance(const Duration(days: 100));
        await h.putData(w1, 'dev1', 5, 'five');
        expect((await h.device(w1, 'dev1'))['first'], 4);
      });

      test('the stale device acks no longer count, even if they are high', () async {
        final h = await freshHarness();
        await putMany(h, 'dev1', 3);
        await putMany(h, 'dev2', 1);
        await h.ack(w1, 'dev2', {'dev1': 1});
        await h.putSnapshot(w1, 's1', {'dev1': 3}, 'a');
        expect((await h.device(w1, 'dev1'))['first'], 2);
        h.advance(const Duration(days: 120));
        await h.putData(w1, 'dev1', 4, 'four');
        expect((await h.device(w1, 'dev1'))['first'], 4);
      });
    });
  });

  group('state JSON', () {
    test('exact shape with devices, acks, snapshot and previous', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 3);
      await putMany(h, 'dev2', 1);
      h.advance(const Duration(minutes: 5));
      await h.ack(w1, 'dev2', {'dev1': 2});
      await h.putSnapshot(w1, 's1', {'dev1': 1}, 'a');
      await h.putSnapshot(w1, 's2', {'dev1': 2, 'dev2': 1}, 'b');
      expect(await h.state(w1), {
        'api': 2,
        'devices': {
          'dev1': {
            'first': 2,
            'last': 3,
            'lastSeen': '2026-10-22T10:00:00Z',
            'acks': <String, Object?>{},
          },
          'dev2': {
            'first': 1,
            'last': 1,
            'lastSeen': '2026-10-22T10:05:00Z',
            'acks': {'dev1': 2},
          },
        },
        'snapshot': {
          'id': 's2',
          'covers': {'dev1': 2, 'dev2': 1},
        },
        'previous': {
          'id': 's1',
          'covers': {'dev1': 1},
        },
        'blobs': {'count': 0, 'bytes': 0},
      });
    });

    test('snapshot and previous are null on a fresh wallet; first is 1 and lastSeen has no fraction', () async {
      final h = await freshHarness();
      h.clock = DateTime.utc(2026, 1, 2, 3, 4, 5, 678, 9);
      await h.putData(w1, 'dev1', 1, 'a');
      final r = await h.get('/v2/w/$w1/state', key: keyA);
      final j = jsonDecode(r.body) as Map<String, Object?>;
      expect(j.containsKey('snapshot'), isTrue);
      expect(j['snapshot'], isNull);
      expect(j.containsKey('previous'), isTrue);
      expect(j['previous'], isNull);
      expect(((j['devices'] as Map)['dev1'] as Map)['lastSeen'], '2026-01-02T03:04:05Z');
    });

    test('first = last + 1 when every file is pruned', () async {
      final h = await freshHarness();
      await putMany(h, 'dev1', 4);
      await h.putSnapshot(w1, 's1', {'dev1': 4}, 'a');
      expect(await h.device(w1, 'dev1'), {'first': 5, 'last': 4, 'lastSeen': '2026-10-22T10:00:00Z', 'acks': <String, Object?>{}});
      expect(Directory('${h.dir.path}/$w1/d/dev1').listSync(), isEmpty);
      // The device continues at 5.
      expect((await h.putData(w1, 'dev1', 5, 'five')).statusCode, 201);
      expect(await h.device(w1, 'dev1'), containsPair('first', 5));
    });

    test('the state needs a signature', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'a');
      expect((await h.get('/v2/w/$w1/state')).statusCode, 401);
    });
  });
}
