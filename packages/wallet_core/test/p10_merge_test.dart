// P10 core: merge from a backup (the newer change wins, field by field; nothing doubled) and bill files in backups
// (docs/context/P10_SPEC.md §1, §2, §4). All data SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/src/backup.dart' show backupPayloadOps;
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

NormalizedBill _slip(String ext, String date) =>
    NormalizedBill(source: BillSource.hub3, externalId: ext, date: date, dueDate: date, total: 4599, payee: 'Synth Energy');

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late VaultKey key;
  var now = 1772323200000; // 2026-03-01
  final open = <WalletRepo>[];
  WalletRepo repo() {
    final r = WalletRepo.inMemory(now: () => now);
    open.add(r);
    return r;
  }

  setUp(() {
    key = VaultKey.generate();
    now = 1772323200000;
  });
  tearDown(() {
    for (final r in open) {
      r.close();
    }
    open.clear();
  });

  /// Everything a merge may touch: data rows, field clocks, outbox, meta (stored HLC, match flag), the in-memory HLC and
  /// the bill-file tables.
  Map<String, Object?> state(WalletRepo r) => {
        ...dump(r),
        'outbox': [for (final row in r.db.select('SELECT * FROM outbox ORDER BY seq')) Map<String, Object?>.from(row)],
        'meta': [for (final row in r.db.select('SELECT * FROM meta ORDER BY key')) Map<String, Object?>.from(row)],
        'hlc': r.clock.last.toString(),
        for (final t in ['blob_cache', 'blob_outbox', 'blob_own', 'blob_delete'])
          t: [for (final row in r.db.select('SELECT * FROM $t ORDER BY hash')) Map<String, Object?>.from(row)],
      };

  Future<WalletRepo> copyOf(WalletRepo from) async {
    final r = repo();
    await restoreBackupBytes(r, await backupBytes(from, key), key);
    r.markExported(1 << 40);
    return r;
  }

  group('merge: newer wins per field', () {
    test('A newer opening, B newer name: both kept, either direction, and the two wallets end equal', () async {
      final a = repo();
      final id = await a.addAccount(name: 'Synth Cash', currency: 'EUR', opening: 1000, openingDate: '2026-02-01');
      final b = await copyOf(a);
      now += 1000;
      await a.updateAccount(id, name: 'Synth A');
      await b.updateAccount(id, opening: 1111);
      now += 1000;
      await a.updateAccount(id, opening: 2222);
      await b.updateAccount(id, name: 'Synth B');

      final intoB = await mergeBackupBytes(b, await backupBytes(a, key), key);
      expect(intoB.changed, 1, reason: 'one op (the opening edit) is newer; the older name edit is not');
      expect(intoB.changedByEntity, {'account': 1});
      expect(b.accounts().single.name, 'Synth B');
      expect(b.accounts().single.opening, 2222);

      final intoA = await mergeBackupBytes(a, await backupBytes(b, key), key);
      expect(intoA.changed, 1);
      expect(a.accounts().single.name, 'Synth B');
      expect(a.accounts().single.opening, 2222);
      expect(dump(a)['accounts'], dump(b)['accounts']);
      expect(dump(a)['clocks'], dump(b)['clocks'], reason: 'each field keeps the clock of the write that set it');
    });

    test('rows only on one side; a newer delete in the backup wins, an older one does not; nothing is doubled', () async {
      final a = repo();
      a.importBatch(january);
      final b = await copyOf(a);
      final ids = january.transactions.map((t) => t.id).toList();
      final (edited, undone) = (ids[3], ids[2]);
      now += 1000;
      b.setCategory(edited, 'Shopping');
      a.deleteTransaction(undone);
      b.deleteTransaction(undone);
      final onlyB = b.addTransaction(date: '2026-02-20', amount: 1234, category: 'Groceries');
      final acc = await a.addAccount(name: 'Synth Cash', currency: 'EUR', opening: 500, openingDate: '2026-02-01');
      now += 1000;
      a.deleteTransaction(edited); // newer than B's category edit
      b.undeleteTransaction(undone); // newer than A's delete

      final r = await mergeBackupBytes(b, await backupBytes(a, key), key);
      expect(b.transaction(edited)!.deleted, isTrue, reason: 'the delete is newer');
      expect(b.transaction(undone)!.deleted, isFalse, reason: "the backup's delete is older than the undo here");
      expect(b.transaction(onlyB), isNotNull);
      expect(b.transaction(onlyB)!.deleted, isFalse);
      expect(b.accounts().map((x) => x.id), [acc]);
      expect(b.transactions(includeHidden: true).length, ids.length + 1, reason: 'nothing doubled');
      expect(r.changedByEntity['account'], 1);
      expect(r.changedByEntity['tx'], 1, reason: 'only the delete of the edited row changed something');
    });

    test('merging the same backup twice: the second time nothing changes and nothing is queued', () async {
      final a = repo();
      a.importBatch(january);
      final b = repo();
      b.addTransaction(date: '2026-02-20', amount: 1234, category: 'Groceries');
      b.markExported(1 << 40);
      final file = await backupBytes(a, key);
      final first = await mergeBackupBytes(b, file, key);
      expect(first.changed, greaterThan(0));
      expect(first.ops, a.snapshotOps().length);
      b.markExported(1 << 40);
      final before = dump(b);
      final second = await mergeBackupBytes(b, file, key);
      expect(second.changed, 0);
      expect(second.changedByEntity, isEmpty);
      expect(b.pendingOps(), isEmpty);
      expect(dump(b), before);
    });
  });

  test('an op that wins only some of its fields is queued cut to them, with its own clock', () async {
    final x = repo();
    x.importBatch(january);
    final id = january.transactions[3].id;
    final older = Hlc(now + 500, 0, 'peer').toString();
    now += 1000;
    x.setCategory(id, 'Shopping');
    x.markExported(1 << 40);
    final file = await seal(
        backupPayload([
          Op('tx', id, {'category': 'Groceries', 'note': 'synthetic note'}, older)
        ]),
        key,
        aad: aadBackup);
    final r = await mergeBackupBytes(x, file, key);
    expect(r.changed, 1);
    expect(x.transaction(id)!.category, 'Shopping');
    expect(x.transaction(id)!.note, 'synthetic note');
    final queued = x.pendingOps().single.$2;
    expect((queued.entity, queued.id, queued.hlc), ('tx', id, older));
    expect(queued.fields, {'note': 'synthetic note'});
  });

  group('dry run', () {
    test('changes nothing (tables, clocks, outbox, meta, HLC) and reports the counts of the real merge', () async {
      final a = repo();
      a.importBatch(january);
      final id = await a.addAccount(name: 'Synth Cash', currency: 'EUR', opening: 1000, openingDate: '2026-02-01');
      final b = await copyOf(a);
      b.addTransaction(date: '2026-02-20', amount: 1234, category: 'Groceries');
      now += 5000;
      await a.updateAccount(id, name: 'Synth A');
      a.setCategory(january.transactions[3].id, 'Shopping');
      a.updateSettings({'salary': 160000});
      final file = await backupBytes(a, key);
      now += 1000;

      final before = state(b);
      final dry = await mergeBackupBytes(b, file, key, dryRun: true);
      expect(state(b), before);
      final dry2 = await mergeBackupBytes(b, file, key, dryRun: true);
      expect(dry2.changedByEntity, dry.changedByEntity);

      final real = await mergeBackupBytes(b, file, key);
      expect(dry.changed, greaterThan(0));
      expect((dry.ops, dry.changed), (real.ops, real.changed));
      expect(dry.changedByEntity, real.changedByEntity);
      expect(b.accounts().single.name, 'Synth A');
      expect(b.settings().salary, 160000);
    });
  });

  group('only changed fields are queued; another device converges', () {
    late Directory tmp;
    final devices = <Device>[];
    setUp(() => tmp = Directory.systemTemp.createTempSync('bw-p10-'));
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('a merge on one synced device reaches the other; the outbox holds just the changed fields', () async {
      final net = Net();
      Device device(String name) {
        final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now, net: net);
        devices.add(d);
        return d;
      }

      Future<void> syncAll(List<Device> ds) async {
        for (var round = 0; round < 2; round++) {
          for (final d in ds) {
            d.deliver(net, Random(round));
            await d.run();
          }
        }
      }

      final x = device('x'), y = device('y');
      x.repo.importBatch(january);
      final id = await x.repo.addAccount(name: 'Synth Cash', currency: 'EUR', opening: 1000, openingDate: '2026-02-01');
      await syncAll([x, y]);
      // An offline copy of the wallet (an old phone) that edits on its own, then is backed up.
      final old = await copyOf(x.repo);
      now += 1000;
      x.repo.setCategory(january.transactions[2].id, 'Shopping'); // newer on the relay side below
      now += 1000;
      await old.updateAccount(id, opening: 4321);
      old.setCategory(january.transactions[2].id, 'Groceries'); // newer than x's edit
      old.addTransaction(date: '2026-02-21', amount: 999, category: 'Groceries');
      await syncAll([x, y]);
      expect(x.repo.pendingOps(), isEmpty);
      now += 1000;

      final r = await mergeBackupBytes(x.repo, await backupBytes(old, key), key);
      expect(r.changedByEntity, {'account': 1, 'tx': 2});
      final queued = x.repo.pendingOps().map((e) => e.$2).toList();
      expect(queued, hasLength(r.changed));
      final account = queued.singleWhere((o) => o.entity == 'account');
      expect(account.fields.keys.toSet(), {'opening', 'opening_date'}, reason: 'the name (not newer) is not re-sent');
      await syncAll([x, y]);
      expect(y.repo.accounts().single.opening, 4321);
      expect(y.repo.transaction(january.transactions[2].id)!.category, 'Groceries');
      expect(dump(y.repo), dump(x.repo));
    });
  });

  group('refused files apply nothing', () {
    late WalletRepo b;
    late Map<String, Object?> before;
    setUp(() {
      b = repo();
      b.addTransaction(date: '2026-02-20', amount: 1234, category: 'Groceries');
      before = state(b);
    });

    test('damaged content (not a backup, bad op, blobs not a map), truncated, wrong key', () async {
      Future<List<int>> sealed(String json) async => seal(utf8.encode(json), key, aad: aadBackup);
      for (final json in ['not json', '{"v":1}', '{"v":1,"ops":[{"e":"tx"}]}', '{"v":1,"ops":[],"blobs":[1]}']) {
        await expectLater(mergeBackupBytes(b, await sealed(json), key),
            throwsA(isA<BackupException>().having((e) => e.reason, 'reason', BackupFailure.damaged)));
        await expectLater(mergeBackupBytes(b, await sealed(json), key, dryRun: true), throwsA(isA<BackupException>()));
      }
      await expectLater(mergeBackupBytes(b, await sealed('{"v":2,"ops":[]}'), key),
          throwsA(isA<BackupException>().having((e) => e.reason, 'reason', BackupFailure.newerVersion)));
      final a = repo();
      a.importBatch(january);
      final file = await backupBytes(a, key);
      await expectLater(mergeBackupBytes(b, file.sublist(0, file.length - 5), key), throwsA(isA<VaultException>()));
      await expectLater(mergeBackupBytes(b, file, VaultKey.generate()), throwsA(isA<VaultException>()));
      expect(state(b), before);
    });

    test('a backup with clocks more than the drift ahead of this device: clockAhead', () async {
      final ahead = WalletRepo.inMemory(now: () => now + 3 * 3600 * 1000);
      open.add(ahead);
      ahead.importBatch(january);
      await expectLater(mergeBackupBytes(b, await backupBytes(ahead, key), key),
          throwsA(isA<BackupException>().having((e) => e.reason, 'reason', BackupFailure.clockAhead)));
      expect(state(b), before);
    });
  });

  group('bill files in backups', () {
    /// A wallet with three bills, each with its own file, dated oldest to newest; the middle one's file is the largest.
    /// Returns their hashes newest first.
    Future<(WalletRepo, List<String>)> billWallet() async {
      final a = repo();
      final hashes = <String>[];
      for (final (i, date) in ['2026-02-01', '2026-02-10', '2026-02-20'].indexed) {
        final ref = await BlobStore(a, key).add(_bytes(const [2000, 6000, 2500][i], i), 'jpg');
        a.importBill(_slip('hub3:SYNTH:$i', date), file: ref);
        hashes.insert(0, ref.hash);
      }
      return (a, hashes);
    }

    /// The size a file takes in the payload (base64 of its sealed bytes): what the cap counts.
    int inPayload(WalletRepo r, String h) => base64Encode(r.cachedBlob(h, touch: false)!).length;

    test(
        'newest first up to the cap (base64 size): a total exactly at the cap fits, a file that would pass it is skipped and '
        'an older smaller one still fits', () async {
      final (a, h) = await billWallet();
      final cap = inPayload(a, h[0]) + inPayload(a, h[2]);
      expect(inPayload(a, h[0]) + inPayload(a, h[1]), greaterThan(cap));
      final info = await backupBytesWithInfo(a, key, maxBlobBytes: cap);
      expect((info.blobs, info.blobsSkipped, info.blobBytes), (2, 1, cap));
      final payload = jsonDecode(utf8.decode(await unseal(info.bytes, key, aad: aadBackup))) as Map;
      expect((payload['blobs'] as Map).keys.toSet(), {h[0], h[2]}, reason: 'the middle (largest) file is skipped, not the oldest');
      for (final x in [h[0], h[2]]) {
        expect(base64Decode((payload['blobs'] as Map)[x] as String), a.cachedBlob(x, touch: false));
      }
      final tight = await backupBytesWithInfo(a, key, maxBlobBytes: cap - 1);
      expect((tight.blobs, tight.blobsSkipped), (1, 2), reason: 'one byte less: the oldest no longer fits');
      // An older build's parser reads only "v" and "ops": the version stays 1 and the ops are the same.
      expect(payload['v'], 1);
      expect(backupVersion, 1);
      expect((payload['ops'] as List).length, info.ops);
      final none = await backupBytesWithInfo(a, key, maxBlobBytes: 0);
      expect((none.blobs, none.blobsSkipped), (0, 3));
      final plain = jsonDecode(utf8.decode(await unseal(none.bytes, key, aad: aadBackup))) as Map;
      expect(plain.containsKey('blobs'), isFalse);
      // A deleted bill's file is not carried.
      a.deleteBill(a.bills().firstWhere((x) => x.blob == h[2]).id);
      expect((await backupBytesWithInfo(a, key)).blobs, 2);
    });

    test('restore puts the files into the cache, queued for upload, not owned; the old key path leaves them out', () async {
      final (a, h) = await billWallet();
      final file = await backupBytes(a, key);
      final b = repo();
      await restoreBackupBytes(b, file, key);
      for (final x in h) {
        expect(b.cachedBlob(x, touch: false), a.cachedBlob(x, touch: false));
      }
      expect(b.queuedBlobs(), (h.toList()..sort()));
      expect(b.db.select('SELECT * FROM blob_own'), isEmpty);
      expect(await BlobStore(b, key).read(h[0]), _bytes(2500, 2));

      final c = repo();
      await restoreBackupBytes(c, file, key, walletKey: VaultKey.generate());
      expect(c.bills(), hasLength(3));
      expect(c.queuedBlobs(), isEmpty);
      expect(c.cachedBlobBytes, 0);
    });

    test('merge brings the files in (dry run counts them, writes none); merging again adds nothing', () async {
      final (a, h) = await billWallet();
      final file = await backupBytes(a, key);
      final b = repo();
      b.addTransaction(date: '2026-02-20', amount: 1234, category: 'Groceries');
      final before = state(b);
      final dry = await mergeBackupBytes(b, file, key, dryRun: true);
      expect(dry.blobs, 3);
      expect(state(b), before);
      final real = await mergeBackupBytes(b, file, key);
      expect(real.blobs, 3);
      expect(real.changedByEntity['bill'], 3);
      expect(b.queuedBlobs(), (h.toList()..sort()));
      final again = await mergeBackupBytes(b, file, key);
      expect((again.changed, again.blobs), (0, 0));
    });

    test('a tampered file, a bad hash or bad base64 is skipped; the rest of the backup applies', () async {
      final (a, h) = await billWallet();
      final good = a.cachedBlob(h[0], touch: false)!;
      final tampered = List<int>.of(a.cachedBlob(h[1], touch: false)!)..[40] ^= 1;
      final payload = jsonDecode(utf8.decode(backupPayload(a.snapshotOps(), blobs: {h[0]: good, h[1]: tampered}))) as Map;
      (payload['blobs'] as Map)[h[2]] = '***not base64***';
      (payload['blobs'] as Map)['nothash'] = base64Encode(good);
      final file = await seal(utf8.encode(jsonEncode(payload)), key, aad: aadBackup);
      final b = repo();
      await restoreBackupBytes(b, file, key);
      expect(b.bills(), hasLength(3));
      expect(b.queuedBlobs(), [h[0]]);
      expect(b.cachedBlob(h[1], touch: false), isNull);
      expect(b.cachedBlob(h[2], touch: false), isNull);
      // The relay snapshot parser (the same rules older builds use) reads the ops and ignores the files.
      expect(backupPayloadOps(utf8.encode(jsonEncode(payload))), hasLength(a.snapshotOps().length));
    });

    test('a file whose bill is deleted here by a newer delete is not taken', () async {
      final (a, h) = await billWallet();
      final b = await copyOf(a);
      b.db.execute('DELETE FROM blob_cache');
      b.db.execute('DELETE FROM blob_outbox');
      now += 1000;
      b.deleteBill(b.bills().firstWhere((x) => x.blob == h[0]).id);
      final r = await mergeBackupBytes(b, await backupBytes(a, key), key);
      expect(r.blobs, 2);
      expect(b.cachedBlob(h[0], touch: false), isNull);
    });
  });
}
