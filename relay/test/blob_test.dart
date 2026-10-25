// Blobs (docs/context/RELAY_PROTOCOL.md "Blobs"): content-addressed sealed files per wallet.
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<String> hashOf(List<int> b) async => [for (final x in (await Sha256().hash(b)).bytes) x.toRadixString(16).padLeft(2, '0')].join();

String bp(String wallet, String hash) => '/v2/w/$wallet/blob/$hash';

void main() {
  late Harness h;
  late Uint8List data;
  late String hash;

  setUp(() async {
    h = await freshHarness();
    expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
    data = bytes('sealed photo bytes');
    hash = await hashOf(data);
  });

  Future<int> put(Uint8List b, {TestKey? key, String wallet = w1}) async =>
      (await h.send('PUT', bp(wallet, await hashOf(b)), key: key ?? keyA, body: b)).statusCode;

  group('happy paths', () {
    test('PUT 201, again 200, GET returns the bytes, DELETE 204 and the blob stays (api 4)', () async {
      expect(await put(data), 201);
      expect(await put(data), 200);
      final g = await h.get(bp(w1, hash), key: keyA);
      expect(g.statusCode, 200);
      expect(g.headers['content-type'], 'application/octet-stream');
      expect(g.bodyBytes, data);
      expect((await h.send('DELETE', bp(w1, hash), key: keyA)).statusCode, 204);
      expect((await h.get(bp(w1, hash), key: keyA)).bodyBytes, data);
    });

    test('GET of a never stored blob is 404', () async {
      expect((await h.get(bp(w1, hash), key: keyA)).statusCode, 404);
    });

    test('DELETE is a no-op (v4 and an api-3 app\'s v3 signature alike)', () async {
      expect((await h.send('DELETE', bp(w1, hash), key: keyA)).statusCode, 204);
      expect(await put(data), 201);
      expect((await h.send('DELETE', bp(w1, hash), key: keyA)).statusCode, 204);
      h.v3 = true;
      expect((await h.send('DELETE', bp(w1, hash), key: keyA)).statusCode, 204);
      h.v3 = false;
      expect((await h.state(w1))['blobs'], {'count': 1, 'bytes': data.length});
      expect(File('${h.dir.path}/$w1/blobs/$hash').existsSync(), isTrue);
    });

    test('an empty blob is allowed', () async {
      expect(await put(Uint8List(0)), 201);
      expect((await h.get(bp(w1, await hashOf(const [])), key: keyA)).bodyBytes, isEmpty);
    });

    test('blobs of two wallets are separate', () async {
      expect((await h.putData(w2, 'dev1', 1, 'a', key: keyB)).statusCode, 201);
      expect(await put(data), 201);
      expect((await h.get(bp(w2, hash), key: keyB)).statusCode, 404);
      expect((await h.get(bp(w1, hash), key: keyB)).statusCode, 401);
    });

    test('PUT and DELETE do not change lastSeen', () async {
      final before = (await h.device(w1, 'dev1'))['lastSeen'];
      h.advance(const Duration(hours: 1));
      await put(data);
      await h.send('DELETE', bp(w1, hash), key: keyA);
      expect((await h.device(w1, 'dev1'))['lastSeen'], before);
    });
  });

  group('refusals', () {
    test('hash mismatch is 400 hash and nothing is stored', () async {
      final other = await hashOf(bytes('something else'));
      final r = await h.send('PUT', bp(w1, other), key: keyA, body: data);
      expect(r.statusCode, 400);
      expect(r.body, contains('"hash"'));
      expect((await h.get(bp(w1, other), key: keyA)).statusCode, 404);
      expect((await h.state(w1))['blobs'], {'count': 0, 'bytes': 0});
    });

    test('bad names are 400 for all three methods', () async {
      for (final bad in ['abc', hash.toUpperCase(), '${hash}0', hash.substring(1), 'g' * 64, 'x.y']) {
        for (final m in ['GET', 'PUT', 'DELETE']) {
          final r = await h.send(m, '/v2/w/$w1/blob/$bad', key: keyA, body: m == 'PUT' ? data : null);
          expect(r.statusCode, 400, reason: '$m $bad');
        }
      }
    });

    test('other methods are 405 and extra segments 404', () async {
      for (final m in ['POST', 'PATCH']) {
        expect((await h.send(m, bp(w1, hash), key: keyA)).statusCode, 405, reason: m);
      }
      expect((await h.get('${bp(w1, hash)}/x', key: keyA)).statusCode, 404);
    });

    test('unsigned, wrong key and clock skew are 401 for all three methods', () async {
      for (final m in ['GET', 'PUT', 'DELETE']) {
        final body = m == 'PUT' ? data : null;
        expect((await h.send(m, bp(w1, hash), body: body)).statusCode, 401, reason: 'unsigned $m');
        expect((await h.send(m, bp(w1, hash), key: keyB, body: body)).statusCode, 401, reason: 'wrong key $m');
        h.skew = const Duration(minutes: 10);
        final r = await h.send(m, bp(w1, hash), key: keyA, body: body);
        h.skew = Duration.zero;
        expect(r.statusCode, 401, reason: 'clock $m');
        expect(r.body, contains('clock'));
      }
      expect((await h.get(bp(w1, hash), key: keyA)).statusCode, 404, reason: 'nothing was stored');
    });

    test('a signature for another method does not carry over', () async {
      expect(await put(data), 201);
      final putSig = await h.sign(keyA, 'PUT', bp(w1, hash), data);
      expect((await h.replay('DELETE', bp(w1, hash), putSig)).statusCode, 401);
      final getSig = await h.sign(keyA, 'GET', bp(w1, hash), const []);
      expect((await h.replay('DELETE', bp(w1, hash), getSig)).statusCode, 401);
      expect((await h.get(bp(w1, hash), key: keyA)).statusCode, 200);
    });

    test('a replayed PUT is harmless (200)', () async {
      final sig = await h.sign(keyA, 'PUT', bp(w1, hash), data);
      expect((await h.replay('PUT', bp(w1, hash), sig, body: data)).statusCode, 201);
      expect((await h.replay('PUT', bp(w1, hash), sig, body: data)).statusCode, 200);
    });

    test('unknown wallet is 404 for all three methods and creates nothing', () async {
      for (final m in ['GET', 'PUT', 'DELETE']) {
        final r = await h.send(m, bp(w2, hash), key: keyB, body: m == 'PUT' ? data : null);
        expect(r.statusCode, 404, reason: m);
      }
      expect(h.relay.walletCount, 1);
    });

    test('DELETE with a body is refused', () async {
      expect(await put(data), 201);
      expect((await h.send('DELETE', bp(w1, hash), key: keyA, body: data)).statusCode, 400);
      expect((await h.get(bp(w1, hash), key: keyA)).statusCode, 200);
    });

    test('over 16 MiB is 413, exactly 16 MiB is accepted', () async {
      final big = Uint8List(16 * 1024 * 1024 + 1);
      final r = await h.send('PUT', bp(w1, await hashOf(big)), key: keyA, body: big);
      expect(r.statusCode, 413);
      expect(await put(Uint8List(16 * 1024 * 1024)), 201);
      expect((await h.putData(w1, 'dev1', 2, 'b')).statusCode, 201, reason: 'the relay still answers');
    });
  });

  group('--max-bytes counts blobs', () {
    test('blob, file and snapshot PUTs all count the blobs', () async {
      final small = await freshHarness(maxBytes: 100);
      Future<int> sput(Uint8List b) async => (await small.send('PUT', bp(w1, await hashOf(b)), key: keyA, body: b)).statusCode;
      expect((await small.putData(w1, 'dev1', 1, 'x' * 10)).statusCode, 201); // 10
      expect(await sput(Uint8List(60)), 201); // 70
      expect(await sput(Uint8List(31)), 507); // 101
      expect(await sput(Uint8List(60)), 200, reason: 'already stored adds no byte');
      // A file PUT that would pass the limit with the blob counted is refused.
      expect((await small.putData(w1, 'dev1', 2, 'z' * 31)).statusCode, 507);
      // A snapshot likewise: blobs 60 + snapshot 41 > 100.
      expect((await small.putSnapshot(w1, 's2', {'dev1': 1}, 'q' * 41)).statusCode, 507);
      expect((await small.putSnapshot(w1, 's2', {'dev1': 1}, 'q' * 40)).statusCode, 201);
      // A DELETE frees nothing (api 4: only GC deletes blobs).
      expect((await small.send('DELETE', bp(w1, await hashOf(Uint8List(60))), key: keyA)).statusCode, 204);
      expect(await sput(Uint8List(55)), 507);
    });

    test('a refused blob leaves nothing behind', () async {
      final small = await freshHarness(maxBytes: 50);
      expect((await small.putData(w1, 'dev1', 1, 'x')).statusCode, 201);
      final b = Uint8List(60);
      expect((await small.send('PUT', bp(w1, await hashOf(b)), key: keyA, body: b)).statusCode, 507);
      expect((await small.state(w1))['blobs'], {'count': 0, 'bytes': 0});
      final dir = Directory('${small.dir.path}/$w1/blobs');
      expect(dir.existsSync() ? dir.listSync() : <FileSystemEntity>[], isEmpty);
    });

    test('state reports bytes (files + snapshots + blobs) and maxBytes (Stage I)', () async {
      final small = await freshHarness(maxBytes: 100);
      Future<int> sput(Uint8List b) async => (await small.send('PUT', bp(w1, await hashOf(b)), key: keyA, body: b)).statusCode;
      expect((await small.putData(w1, 'dev1', 1, 'x' * 10)).statusCode, 201);
      var st = await small.state(w1);
      expect((st['bytes'], st['maxBytes']), (10, 100));
      expect(await sput(Uint8List(60)), 201);
      st = await small.state(w1);
      expect((st['bytes'], st['maxBytes']), (70, 100));
      expect(await sput(Uint8List(31)), 507);
      expect((await small.state(w1))['bytes'], 70, reason: 'a refused PUT adds nothing');
      expect((await small.putData(w1, 'dev1', 2, 'y' * 20)).statusCode, 201);
      expect((await small.state(w1))['bytes'], 90);
      await small.restart();
      expect((await small.state(w1))['bytes'], 90, reason: 'rebuilt from the folder');
      expect((await small.send('DELETE', bp(w1, await hashOf(Uint8List(60))), key: keyA)).statusCode, 204);
      expect((await small.state(w1))['bytes'], 90, reason: 'a DELETE changes nothing');
    });
  });

  group('state, pruning, restart', () {
    test('state counts blobs', () async {
      expect((await h.state(w1))['blobs'], {'count': 0, 'bytes': 0});
      final b2 = bytes('another');
      await put(data);
      await put(b2);
      await put(data);
      expect((await h.state(w1))['blobs'], {'count': 2, 'bytes': data.length + b2.length});
    });

    test('blobs survive pruning and a restart', () async {
      expect(await put(data), 201);
      for (var i = 2; i <= 4; i++) {
        await h.putData(w1, 'dev1', i, 'f$i');
      }
      await h.putSnapshot(w1, 's1', {'dev1': 4}, 'snap');
      await h.putSnapshot(w1, 's2', {'dev1': 4}, 'snap2');
      await h.putSnapshot(w1, 's3', {'dev1': 4}, 'snap3');
      expect((await h.getData(w1, 'dev1', 1)).statusCode, 410, reason: 'files were pruned');
      expect((await h.get(bp(w1, hash), key: keyA)).bodyBytes, data);
      final before = await h.state(w1);
      await h.restart();
      expect(await h.state(w1), before);
      expect((await h.state(w1))['blobs'], {'count': 1, 'bytes': data.length});
      expect((await h.get(bp(w1, hash), key: keyA)).bodyBytes, data);
      expect(await put(data), 200);
      expect((await h.send('DELETE', bp(w1, hash), key: keyA)).statusCode, 204);
      await h.restart();
      expect((await h.get(bp(w1, hash), key: keyA)).bodyBytes, data, reason: 'snapshots without declared sets: no GC');
      expect((await h.state(w1))['blobs'], {'count': 1, 'bytes': data.length});
    });

    test('restart counts blobs toward --max-bytes and removes temp files', () async {
      final small = await freshHarness(maxBytes: 50);
      expect((await small.putData(w1, 'dev1', 1, 'x')).statusCode, 201);
      final b = Uint8List(40);
      expect((await small.send('PUT', bp(w1, await hashOf(b)), key: keyA, body: b)).statusCode, 201);
      File('${small.dir.path}/$w1/blobs/.tmp-1-1').writeAsStringSync('junk');
      await small.restart();
      expect(File('${small.dir.path}/$w1/blobs/.tmp-1-1').existsSync(), isFalse);
      expect((await small.state(w1))['blobs'], {'count': 1, 'bytes': 40});
      expect((await small.putData(w1, 'dev1', 2, 'y' * 10)).statusCode, 507);
    });

    test('concurrent PUTs of the same blob: one 201, the rest 200, one file', () async {
      final rs = await Future.wait([for (var i = 0; i < 6; i++) h.send('PUT', bp(w1, hash), key: keyA, body: data)]);
      final codes = rs.map((r) => r.statusCode).toList()..sort();
      expect(codes, [200, 200, 200, 200, 200, 201]);
      expect((await h.state(w1))['blobs'], {'count': 1, 'bytes': data.length});
      final names = Directory('${h.dir.path}/$w1/blobs').listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, [hash]);
    });
  });

  group('log', () {
    test('kind, status and size are logged; the hash and body never', () async {
      await put(data);
      await h.get(bp(w1, hash), key: keyA);
      await h.send('DELETE', bp(w1, hash), key: keyA);
      final lines = h.logs.where((l) => l.contains('blob')).toList();
      expect(lines.length, 3);
      expect(lines[0], 'relay put-blob 201 ${data.length} w=${w1.substring(0, 6)} d=-');
      expect(lines[1], 'relay get-blob 200 ${data.length} w=${w1.substring(0, 6)} d=-');
      expect(lines[2], startsWith('relay delete-blob 204 0 '));
      final all = h.logs.join('\n');
      expect(all, isNot(contains(hash.substring(0, 8))));
      expect(all, isNot(contains('sealed photo')));
    });
  });

  group('CORS', () {
    test('preflight lists DELETE', () async {
      final r = await h.send('OPTIONS', bp(w1, hash), headers: {'origin': defaultOrigins.first, 'access-control-request-method': 'DELETE'});
      expect(r.statusCode, 204);
      expect(r.headers['access-control-allow-methods'], 'GET, PUT, DELETE, OPTIONS');
    });
  });
}
