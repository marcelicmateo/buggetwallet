// Bill files (BILLS_API.md §4, RELAY_PROTOCOL.md "Blobs"): BlobStore, the engine's upload/delete queues, MemoryTransport
// and RelayTransport blob calls. SYNTHETIC bytes only.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

Uint8List bytes(int n, [int seed = 7]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

const bill = NormalizedBill(source: BillSource.photo, externalId: 'jir:synthetic-1', date: '2026-02-25', total: 1999, payee: 'Synthetic');

List<int> _unb64(String s) => base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

void main() {
  late VaultKey key;
  late MemoryTransport relay;
  late WalletRepo a;
  final open = <WalletRepo>[];
  WalletRepo mk() => WalletRepo.inMemory()..also(open.add);

  setUp(() {
    key = VaultKey.generate();
    relay = MemoryTransport();
    a = mk();
  });
  tearDown(() {
    for (final r in open) {
      r.close();
    }
    open.clear();
  });

  group('BlobStore', () {
    test('add seals, hashes the sealed bytes, caches and queues; read from the cache', () async {
      final store = BlobStore(a, key);
      final plain = bytes(4000);
      final ref = await store.add(plain, 'jpg');
      expect(isBlobHash(ref.hash), isTrue);
      expect((ref.type, ref.bytes), ('jpg', 4000));
      expect(sha256Hex(a.cachedBlob(ref.hash)!), ref.hash);
      expect(a.queuedBlobs(), [ref.hash]);
      expect(await store.read(ref.hash), plain);
      await expectLater(store.add(plain, 'gif'), throwsArgumentError);
      await expectLater(store.add(Uint8List(0), 'jpg'), throwsArgumentError);
    });

    test('LRU: the least recently used uploaded file goes first; queued ones never', () async {
      final store = BlobStore(a, key, maxCacheBytes: 10000);
      final r1 = await store.add(bytes(3000, 1), 'pdf');
      final r2 = await store.add(bytes(3000, 2), 'pdf');
      for (final h in [r1.hash, r2.hash]) {
        a.markBlobUploaded(h);
      }
      await store.read(r1.hash); // r1 is now more recent than r2
      final r3 = await store.add(bytes(3000, 3), 'pdf');
      final r4 = await store.add(bytes(3000, 4), 'pdf'); // over 10000: r2 goes; r3, r4 are queued
      expect(a.cachedBlob(r2.hash, touch: false), isNull);
      expect(a.cachedBlob(r1.hash, touch: false), isNotNull);
      expect(a.queuedBlobs()..sort(), ([r3.hash, r4.hash]..sort()));
      final r5 = await store.add(bytes(3000, 5), 'pdf');
      expect(a.cachedBlob(r1.hash, touch: false), isNull);
      for (final r in [r3, r4, r5]) {
        expect(a.cachedBlob(r.hash, touch: false), isNotNull, reason: 'queued files stay even over the limit');
      }
      expect(a.evictBlobs(0), 0, reason: 'nothing left that may go: every cached file is queued');
      expect(a.cachedBlobBytes, greaterThan(0));
    });

    test('another device fetches through the engine-uploaded relay copy; a tampered copy is refused and not cached', () async {
      final store = BlobStore(a, key);
      final plain = bytes(2500);
      final ref = await store.add(plain, 'png');
      a.importBill(bill, file: ref);
      final first = await SyncEngine(relay, key).run(a);
      expect((first.blobsSent, first.blobsWaiting), (1, 0));
      expect(relay.blobs.keys, [ref.hash]);
      final b = mk();
      await SyncEngine(relay, key).run(b);
      expect(b.bills().single.file, ref);
      final other = BlobStore(b, key);
      expect(await other.read(ref.hash), isNull, reason: 'not on this device, no transport');
      expect(await other.read(ref.hash, transport: relay), plain);
      expect(await other.read(ref.hash), plain, reason: 'cached now');
      final c = mk();
      relay.tamperBlob(ref.hash);
      expect(await BlobStore(c, key).read(ref.hash, transport: relay), isNull);
      expect(c.cachedBlob(ref.hash), isNull);
      expect(await BlobStore(c, VaultKey.generate()).read('0' * 64, transport: relay), isNull);
    });

    // Changed (P14): clients never delete blobs; a deleted bill's file stays cached (until evicted) and on the relay.
    test('deleteBill: the file stays cached and on the relay; a queued one still goes up; no DELETE is ever sent', () async {
      final store = BlobStore(a, key);
      final up = await store.add(bytes(100, 1), 'pdf');
      final (id, _) = a.importBill(bill, file: up);
      await SyncEngine(relay, key).run(a);
      a.deleteBill(id);
      expect(a.cachedBlob(up.hash), isNotNull);
      final queued = await store.add(bytes(100, 2), 'pdf');
      final (id2, _) = a.importBill(const NormalizedBill(source: BillSource.pdf, externalId: 'jir:synthetic-2'), file: queued);
      a.deleteBill(id2);
      expect(a.queuedBlobs(), [queued.hash]);
      await SyncEngine(relay, key).run(a);
      expect(relay.blobs.keys.toSet(), {up.hash, queued.hash});
      expect(relay.calls['deleteBlob'], isNull);
      expect(a.queuedBlobs(), isEmpty);
    });

    test('a re-import whose file the bill does not take drops that file again', () async {
      final store = BlobStore(a, key);
      final f1 = await store.add(bytes(100, 1), 'jpg'), f2 = await store.add(bytes(100, 2), 'jpg');
      a.importBill(bill, file: f1);
      a.importBill(bill, file: f2);
      expect(a.bills().single.blob, f1.hash);
      expect(a.queuedBlobs(), [f1.hash]);
    });

    // Changed (P14): kept until LRU eviction, so an undelete finds the file again.
    test('a bill deleted on another device: its cached file stays here until evicted', () async {
      final ref = await BlobStore(a, key).add(bytes(300), 'jpg');
      final (id, _) = a.importBill(bill, file: ref);
      await SyncEngine(relay, key).run(a);
      final b = mk();
      await SyncEngine(relay, key).run(b);
      await BlobStore(b, key).read(ref.hash, transport: relay);
      expect(b.cachedBlob(ref.hash, touch: false), isNotNull);
      a.deleteBill(id);
      await SyncEngine(relay, key).run(a);
      await SyncEngine(relay, key).run(b);
      expect(b.bills().where((x) => !x.deleted), isEmpty);
      expect(b.cachedBlob(ref.hash, touch: false), isNotNull);
      expect(b.evictBlobs(0), 1, reason: 'uploaded and no pending op: evictable');
    });

    test('a new relay: the first run creates the wallet with the ops, then uploads the waiting file', () async {
      final ref = await BlobStore(a, key).add(bytes(300), 'jpg');
      a.importBill(bill, file: ref);
      final r = await SyncEngine(relay, key).run(a);
      expect((r.blobsSent, r.blobsWaiting), (1, 0));
      expect(relay.calls['putBlob'], 2, reason: 'refused before the wallet existed, sent once it did');
    });

    test('an older relay without blob routes: queued, reported waiting, the ops still sync', () async {
      relay.blobRoutes = false;
      final ref = await BlobStore(a, key).add(bytes(300), 'jpg');
      a.importBill(bill, file: ref);
      final r = await SyncEngine(relay, key).run(a);
      expect((r.sent > 0, r.blobsSent, r.blobsWaiting), (true, 0, 1));
      relay.blobRoutes = true;
      final r2 = await SyncEngine(relay, key).run(a);
      expect((r2.blobsSent, r2.blobsWaiting), (1, 0));
    });

    // Changed (P10 §2): a backup now carries the cached files of live bills (up to a cap); the queues stay device-local.
    test('blob queues are device-local: not in snapshots; files in a backup only under its cap', () async {
      final ref = await BlobStore(a, key).add(bytes(300), 'jpg');
      a.importBill(bill, file: ref);
      final ops = a.snapshotOps();
      expect(ops.map((o) => o.entity).toSet(), {'bill'});
      final restored = mk();
      await restoreBackupBytes(restored, await backupBytes(a, key, maxBlobBytes: 0), key);
      expect(restored.queuedBlobs(), isEmpty);
      expect(restored.cachedBlobBytes, 0);
      final withFile = mk();
      await restoreBackupBytes(withFile, await backupBytes(a, key), key);
      expect(withFile.queuedBlobs(), [ref.hash], reason: 'queued for upload again (idempotent on the relay)');
    });

    test('logs carry no hash, size of a named file or key; enum words and counts only', () async {
      final lines = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(sub.cancel);
      final ref = await BlobStore(a, key).add(bytes(300), 'jpg');
      final (id, _) = a.importBill(bill, file: ref);
      await SyncEngine(relay, key).run(a);
      await BlobStore(mk(), key).read(ref.hash, transport: relay);
      a.deleteBill(id);
      await SyncEngine(relay, key).run(a);
      final all = lines.join('\n');
      expect(all, contains('blob.add'));
      for (final bad in [ref.hash, ref.hash.substring(0, 12), id, 'Synthetic', 'synthetic-1', '1999']) {
        expect(all, isNot(contains(bad)), reason: bad);
      }
    });
  });

  group('RelayTransport blob calls', () {
    late List<http.Request> seen;
    late String wid, pub;
    setUp(() async {
      seen = [];
      (wid, pub) = await RelayTransport(Uri.parse('http://relay.test'), key).ids;
    });
    RelayTransport client(FutureOr<http.Response> Function(http.Request r) answer) =>
        RelayTransport(Uri.parse('http://relay.test:8787'), key, client: MockClient((r) async {
          seen.add(r);
          return answer(r);
        }));

    Future<bool> signedBy(http.Request r) async {
      final hash = [for (final b in (await Sha256().hash(r.bodyBytes)).bytes) b.toRadixString(16).padLeft(2, '0')].join();
      // v4 (RELAY_PROTOCOL.md): the host the client addressed, lower case, the port only when not the scheme's default.
      final u = r.url, def = u.scheme == 'https' ? 443 : 80;
      final host = u.hasPort && u.port != def ? '${u.host.toLowerCase()}:${u.port}' : u.host.toLowerCase();
      final text = 'bw-relay-v4\n${r.method}\n$host\n${r.url.path}\n${r.headers['X-BW-Covers'] ?? ''}\n$hash\n${r.headers['X-BW-Time']}';
      return Ed25519().verify(utf8.encode(text),
          signature: Signature(_unb64(r.headers['X-BW-Sig']!), publicKey: SimplePublicKey(_unb64(pub), type: KeyPairType.ed25519)));
    }

    // Changed (P14): no DELETE any more; the declared set of a snapshot goes as a signed JSON body.
    test('PUT and GET at /v2/w/<wid>/blob/<hash>, the declared set at snapshot/<id>/blobs, all signed', () async {
      final h = 'ab' * 32, h2 = '01' * 32;
      final t = client((r) => switch (r.method) {
            'PUT' => http.Response('', 201),
            _ => http.Response.bytes([1, 2, 3], 200),
          });
      await t.putBlob(h, [9, 9]);
      expect(await t.getBlob(h), [1, 2, 3]);
      await t.putSnapshotBlobs('s15-1-ab', [h, h2]);
      expect([for (final r in seen) r.method], ['PUT', 'GET', 'PUT']);
      for (final r in seen.take(2)) {
        expect(r.url.toString(), 'http://relay.test:8787/v2/w/$wid/blob/$h');
      }
      expect(seen[2].url.toString(), 'http://relay.test:8787/v2/w/$wid/snapshot/s15-1-ab/blobs');
      for (final r in seen) {
        expect(await signedBy(r), isTrue, reason: r.method);
      }
      expect(seen[0].bodyBytes, [9, 9]);
      expect(seen[0].headers['Content-Type'], startsWith('application/octet-stream'));
      expect(jsonDecode(utf8.decode(seen[2].bodyBytes)), [h2, h], reason: 'sorted');
      expect(seen[2].headers['Content-Type'], startsWith('application/json'));
      expect(RelayTransport.signedText('PUT', 'relay.test:8787', '/v2/w/x/blob/$h', '', 'e3b0', '1'),
          'bw-relay-v4\nPUT\nrelay.test:8787\n/v2/w/x/blob/$h\n\ne3b0\n1');
      expect(RelayTransport.signedText('PUT', 'relay.test:8787', '/v2/w/x/blob/$h', '', 'e3b0', '1', api: 3),
          'bw-relay-v3\nPUT\nrelay.test:8787\n/v2/w/x/blob/$h\n\ne3b0\n1');
    });

    test('404: GET is null, PUT and the declared set are missing; 507 is full; 400 hash is rejected', () async {
      var status = 404;
      final t = client((r) => http.Response('{"error":"x"}', status));
      final h = 'cd' * 32;
      expect(await t.getBlob(h), isNull);
      await expectLater(
          t.putBlob(h, [1]), throwsA(isA<TransportException>().having((e) => e.failure, 'failure', TransportFailure.missing)));
      await expectLater(
          t.putSnapshotBlobs('s1', [h]), throwsA(isA<TransportException>().having((e) => e.failure, 'failure', TransportFailure.missing)));
      status = 507;
      await expectLater(t.putBlob(h, [1]), throwsA(isA<TransportException>().having((e) => e.failure, 'failure', TransportFailure.full)));
      status = 400;
      await expectLater(
          t.putBlob(h, [1]), throwsA(isA<TransportException>().having((e) => e.failure, 'failure', TransportFailure.rejected)));
      status = 500;
      await expectLater(t.getBlob(h), throwsA(isA<TransportException>()));
    });
  });

  group('MemoryTransport blob rules', () {
    test('hash checked, unknown wallet 404, idempotent PUT, absent GET null; no delete call exists', () async {
      final body = [1, 2, 3];
      final h = sha256Hex(body);
      await expectLater(relay.putBlob(h, body), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.missing)));
      await relay.put('dev1', 1, [0]);
      await expectLater(
          relay.putBlob('0' * 64, body), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.rejected)));
      await expectLater(
          relay.putBlob('XY', body), throwsA(isA<TransportException>().having((e) => e.failure, 'f', TransportFailure.rejected)));
      await relay.putBlob(h, body);
      await relay.putBlob(h, body);
      expect(await relay.getBlob(h), body);
      expect(await relay.getBlob('9' * 64), isNull);
    });
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
