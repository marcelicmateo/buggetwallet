// P14 (api 4): declared blob sets of the kept snapshots and the relay's blob GC (docs/context/RELAY_PROTOCOL.md
// "Blob garbage collection"). Synthetic bytes only.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:relay/relay.dart';
import 'package:test/test.dart';

import 'blob_test.dart' show bp, hashOf;
import 'support.dart';

String setPath(String wallet, String id) => '/v2/w/$wallet/snapshot/$id/blobs';

void main() {
  late Harness h;
  late Uint8List a, b, c;
  late String ha, hb, hc;

  setUp(() async {
    h = await freshHarness();
    expect((await h.putData(w1, 'dev1', 1, 'f1')).statusCode, 201);
    a = bytes('sealed file a');
    b = bytes('sealed file bb');
    c = bytes('sealed file ccc');
    ha = await hashOf(a);
    hb = await hashOf(b);
    hc = await hashOf(c);
  });

  Future<int> put(Uint8List body) async => (await h.send('PUT', bp(w1, await hashOf(body)), key: keyA, body: body)).statusCode;
  Future<int> putSet(String id, Object? set, {TestKey? key}) async =>
      (await h.send('PUT', setPath(w1, id), key: key ?? keyA, body: utf8.encode(jsonEncode(set)))).statusCode;
  Future<bool> has(String hash) async => (await h.get(bp(w1, hash), key: keyA)).statusCode == 200;

  /// a and b stored 31 days ago, c just now; snapshots s1 and s2 kept (no sets yet).
  Future<void> twoSnapshots() async {
    expect(await put(a), 201);
    expect(await put(b), 201);
    h.advance(const Duration(days: 31));
    expect(await put(c), 201);
    expect((await h.putSnapshot(w1, 's1', {'dev1': 1}, 'snap1')).statusCode, 201);
    expect((await h.putSnapshot(w1, 's2', {'dev1': 1}, 'snap2')).statusCode, 201);
  }

  test('GC deletes only blobs in neither set and older than 30 days; counts follow', () async {
    await twoSnapshots();
    expect(await putSet('s1', [ha]), 201);
    expect(await has(hb), isTrue, reason: 'only one kept snapshot has a set: no GC yet');
    expect(await putSet('s2', []), 201);
    expect(await has(ha), isTrue, reason: 'declared by previous');
    expect(await has(hb), isFalse, reason: 'undeclared and older than the grace');
    expect(await has(hc), isTrue, reason: 'stored within the grace');
    final st = await h.state(w1);
    expect(st['blobs'], {'count': 2, 'bytes': a.length + c.length});
    expect(st['bytes'], 5 + 5 + a.length + c.length, reason: 'kept snapshots + blobs (f1 is pruned); sets are not counted');
    expect(h.logs.where((l) => l.startsWith('relay gc ')).single, 'relay gc kept=2 deleted=1 bytes=${b.length} w=${w1.substring(0, 6)}');
    final all = h.logs.join('\n');
    for (final x in [ha, hb, hc]) {
      expect(all, isNot(contains(x.substring(0, 8))));
    }
    await h.restart();
    expect((await h.state(w1))['blobs'], {'count': 2, 'bytes': a.length + c.length}, reason: 'rebuilt from the folder');
  });

  test('a kept snapshot without a set (an api-3 app wrote it) disables GC', () async {
    await twoSnapshots();
    expect(await putSet('s2', []), 201);
    h.advance(const Duration(days: 60));
    expect(await has(ha) && await has(hb) && await has(hc), isTrue);
    // A newer snapshot without a set: s2 (with a set) becomes previous, s3 has none.
    expect((await h.putSnapshot(w1, 's3', {'dev1': 1}, 'snap3')).statusCode, 201);
    expect(await has(hb), isTrue);
    expect(h.logs.where((l) => l.startsWith('relay gc ')), isEmpty);
  });

  test('a re-upload (200) refreshes the stored time', () async {
    await twoSnapshots();
    expect(await put(b), 200);
    expect(await putSet('s1', []), 201);
    expect(await putSet('s2', []), 201);
    expect(await has(ha), isFalse);
    expect(await has(hb), isTrue, reason: 're-uploaded just now');
    expect(await has(hc), isTrue);
  });

  test('the same set again is 200 (any order), another set 409, an unknown snapshot 404', () async {
    await twoSnapshots();
    expect(await putSet('s2', [ha, hc]), 201);
    expect(await putSet('s2', [hc, ha]), 200);
    expect(await putSet('s2', [ha]), 409);
    expect(await putSet('nope', [ha]), 404);
    expect((await h.send('GET', setPath(w1, 's2'), key: keyA)).statusCode, 405);
    expect((await h.send('PUT', setPath(w2, 's2'), key: keyA, body: utf8.encode('[]'))).statusCode, 404, reason: 'unknown wallet');
  });

  test('a set that does not verify is refused; malformed sets are 400', () async {
    await twoSnapshots();
    expect(await putSet('s2', [ha], key: keyB), 401, reason: 'another key');
    expect((await h.send('PUT', setPath(w1, 's2'), body: utf8.encode('[]'))).statusCode, 401, reason: 'unsigned');
    // Captured headers with another body (a forged set): the body hash no longer matches.
    final body = utf8.encode(jsonEncode([ha]));
    final sig = await h.sign(keyA, 'PUT', setPath(w1, 's2'), body);
    expect((await h.replay('PUT', setPath(w1, 's2'), sig, body: utf8.encode('[]'))).statusCode, 401);
    // ... and on another snapshot id: the path is signed.
    expect((await h.replay('PUT', setPath(w1, 's1'), sig, body: body)).statusCode, 401);
    expect((await h.replay('PUT', setPath(w1, 's2'), sig, body: body)).statusCode, 201);
    expect((await h.replay('PUT', setPath(w1, 's2'), sig, body: body)).statusCode, 200, reason: 'a replay is harmless');
    for (final bad in [
      {'x': 1},
      'abc',
      [ha, ha],
      [ha.toUpperCase()],
      [ha.substring(1)],
      [1],
    ]) {
      expect(await putSet('s1', bad), 400, reason: '$bad');
    }
    expect((await h.send('PUT', setPath(w1, 's1'), key: keyA, body: utf8.encode('not json'))).statusCode, 400);
    final tooMany = [for (var i = 0; i <= maxDeclaredBlobs; i++) i.toRadixString(16).padLeft(64, '0')];
    expect(await putSet('s1', tooMany), 400);
    expect(await has(hb), isTrue, reason: 'nothing collected: s1 has no set');
  });

  test('a restart keeps the sets; a dropped snapshot takes its set along', () async {
    await twoSnapshots();
    expect(await putSet('s1', []), 201);
    await h.restart();
    expect(await putSet('s1', [ha]), 409, reason: 's1 kept its set');
    expect(await putSet('s2', [ha]), 201);
    expect(await has(hb), isFalse, reason: 'both sets known after the restart: GC ran');
    expect(await has(ha), isTrue);
    expect((await h.putSnapshot(w1, 's3', {'dev1': 1}, 'snap3')).statusCode, 201);
    expect(File('${h.dir.path}/$w1/sets/s1').existsSync(), isFalse);
    expect(File('${h.dir.path}/$w1/sets/s2').existsSync(), isTrue);
    File('${h.dir.path}/$w1/sets/stray').writeAsStringSync('[]');
    await h.restart();
    expect(File('${h.dir.path}/$w1/sets/stray').existsSync(), isFalse);
    expect(await putSet('s2', [ha]), 200, reason: 's2 (now previous) kept its set');
  });

  test('an unreadable set file counts as none (no GC)', () async {
    await twoSnapshots();
    expect(await putSet('s1', []), 201);
    File('${h.dir.path}/$w1/sets/s1').writeAsStringSync('{broken');
    await h.restart();
    expect(await putSet('s2', []), 201);
    expect(await has(hb), isTrue);
  });

  test('state says api 4 to a v4 request and api 3 to an api-3 app (v3 text)', () async {
    expect((await h.state(w1))['api'], 4);
    h.v3 = true;
    expect((await h.state(w1))['api'], 3);
    expect((await h.putData(w1, 'dev1', 2, 'f2')).statusCode, 201, reason: 'an api-3 app syncs as before');
    expect(await put(a), 201);
    expect((await h.putSnapshot(w1, 's1', {'dev1': 2}, 'snap1')).statusCode, 201);
    h.v3 = false;
    expect((await h.state(w1))['api'], 4);
    expect(jsonDecode((await h.get('/v2/health')).body), {'api': 4});
  });
}
