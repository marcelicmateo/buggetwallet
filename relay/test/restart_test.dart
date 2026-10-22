import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('layout on disk: meta.json, d/<device>/<seq>, snap/<id>', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snap');
    expect(File('${h.dir.path}/$w1/meta.json').existsSync(), isTrue);
    expect(File('${h.dir.path}/$w1/snap/s1').readAsStringSync(), 'snap');
    await h.putData(w1, 'dev1', 2, 'two');
    expect(File('${h.dir.path}/$w1/d/dev1/2').readAsStringSync(), 'two');
    // No temp files are left behind by atomic writes.
    final names = Directory(h.dir.path).listSync(recursive: true).map((e) => e.uri.pathSegments.last);
    expect(names.where((n) => n.startsWith('.tmp')), isEmpty);
  });

  test('state, files, snapshots and the public key come back from disk', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putData(w1, 'dev1', 2, 'two');
    await h.putData(w1, 'dev1', 3, 'three');
    await h.putData(w1, 'dev2', 1, 'x');
    h.advance(const Duration(minutes: 3));
    await h.ack(w1, 'dev2', {'dev1': 2});
    await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snap1');
    await h.putSnapshot(w1, 's2', {'dev1': 2}, 'snap2');
    await h.putData(w2, 'devX', 1, 'other', key: keyB);
    final before1 = await h.state(w1);
    final before2 = await h.state(w2, key: keyB);

    await h.restart();
    expect(h.relay.walletCount, 2);
    expect(await h.state(w1), before1);
    expect(await h.state(w2, key: keyB), before2);
    expect((await h.getData(w1, 'dev1', 3)).body, 'three');
    expect((await h.getData(w1, 'dev1', 1)).statusCode, 410);
    expect((await h.getSnapshot(w1, 's2')).body, 'snap2');
    expect((await h.getSnapshot(w1, 's1')).body, 'snap1');
    // Signatures are still checked against the stored key; the other wallet's key does not open this one.
    expect((await h.get('/v2/w/$w1/state', key: keyB)).statusCode, 401);
    expect((await h.get('/v2/w/$w2/state', key: keyA)).statusCode, 401);
    // Rules still hold.
    expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 200);
    expect((await h.putData(w1, 'dev1', 3, 'THREE')).statusCode, 409);
    expect((await h.putData(w1, 'dev1', 5, 'five')).statusCode, 422);
    expect((await h.putData(w1, 'dev1', 4, 'four')).statusCode, 201);
    // Acks keep their maximum across a restart.
    await h.ack(w1, 'dev2', {'dev1': 1});
    expect((await h.device(w1, 'dev2'))['acks'], {'dev1': 2});
    // Snapshot rules too.
    expect((await h.putSnapshot(w1, 's3', {'dev1': 1}, 'x')).statusCode, 409);
  });

  test('a device whose files were all pruned keeps its last across a restart', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putData(w1, 'dev1', 2, 'two');
    await h.putSnapshot(w1, 's1', {'dev1': 2}, 'snap');
    final before = await h.state(w1);
    expect((before['devices'] as Map)['dev1'], containsPair('first', 3));
    await h.restart();
    expect(await h.state(w1), before);
    expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 410);
    expect((await h.putData(w1, 'dev1', 4, 'four')).statusCode, 422);
    expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
  });

  test('lastSeen and the 90-day rule survive a restart', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putData(w1, 'dev2', 1, 'x');
    await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snap');
    await h.restart();
    expect((await h.device(w1, 'dev1'))['first'], 1);
    h.advance(const Duration(days: 91));
    await h.putData(w1, 'dev1', 2, 'two');
    expect((await h.device(w1, 'dev1'))['first'], 2);
  });

  test('a file written just before a crash (before the meta) is picked up', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.relay.close();
    File('${h.dir.path}/$w1/d/dev1/2').writeAsStringSync('two');
    File('${h.dir.path}/$w1/d/dev1/.tmp-1-1').writeAsStringSync('half');
    Directory('${h.dir.path}/$w1/d/dev9').createSync();
    File('${h.dir.path}/$w1/d/dev9/1').writeAsStringSync('nine');
    await h.restart();
    final s = await h.state(w1);
    expect((s['devices'] as Map)['dev1'], containsPair('last', 2));
    expect((s['devices'] as Map)['dev9'], containsPair('last', 1));
    expect((await h.getData(w1, 'dev1', 2)).body, 'two');
    expect(File('${h.dir.path}/$w1/d/dev1/.tmp-1-1').existsSync(), isFalse);
    expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
  });

  test('a snapshot file not named by the meta is removed on start', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snap');
    await h.relay.close();
    File('${h.dir.path}/$w1/snap/orphan').writeAsStringSync('x');
    await h.restart();
    expect(File('${h.dir.path}/$w1/snap/orphan').existsSync(), isFalse);
    expect((await h.getSnapshot(w1, 's1')).body, 'snap');
    expect((await h.getSnapshot(w1, 'orphan')).statusCode, 404);
  });

  test('a folder without a readable meta is not a wallet; the id can be created afresh', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.putData(w2, 'dev1', 1, 'two', key: keyB);
    await h.relay.close();
    File('${h.dir.path}/$w1/meta.json').writeAsStringSync('{not json');
    File('${h.dir.path}/$w2/meta.json').deleteSync();
    Directory('${h.dir.path}/not-a-wallet').createSync();
    File('${h.dir.path}/stray.txt').writeAsStringSync('x');
    await h.restart();
    expect(h.relay.walletCount, 0);
    expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 404);
    // A new first PUT starts clean: the old files are gone, not resurrected.
    expect((await h.putData(w1, 'dev1', 1, 'fresh', key: keyB)).statusCode, 201);
    expect((await h.getData(w1, 'dev1', 1, key: keyB)).body, 'fresh');
    expect((await h.state(w1, key: keyB))['devices'], hasLength(1));
  });

  test('meta with wrong-typed values does not crash the load', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.relay.close();
    final meta = jsonDecode(File('${h.dir.path}/$w1/meta.json').readAsStringSync()) as Map<String, Object?>;
    meta['devices'] = {
      'dev1': {
        'last': 'x',
        'lastSeen': 5,
        'acks': {'dev1': 'y', 'bad name': 3}
      },
    };
    meta['snapshot'] = {'id': 'missing-file', 'covers': <String, Object?>{}};
    File('${h.dir.path}/$w1/meta.json').writeAsStringSync(jsonEncode(meta));
    await h.restart();
    final s = await h.state(w1);
    expect((s['devices'] as Map)['dev1'], containsPair('last', 1)); // from the file on disk
    expect(s['snapshot'], isNull);
  });

  test('close is idempotent and a closed relay frees the port', () async {
    final h = await freshHarness();
    await h.putData(w1, 'dev1', 1, 'one');
    await h.relay.close();
    await h.relay.close();
    await h.restart();
    expect((await h.getData(w1, 'dev1', 1)).body, 'one');
  });
}
