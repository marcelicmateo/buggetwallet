// HP-T2: invariants for backup.dart pinned from mutation testing. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show BillSource, NormalizedBill;
import 'package:wallet_sync/wallet_sync.dart';

import 'support/synthetic.dart';

const _now = 1800000000000; // fixed wall clock, ms
const _hour = 3600 * 1000;

Future<List<int>> _seal(Object json, VaultKey key) => seal(utf8.encode(jsonEncode(json)), key, aad: aadBackup);

NormalizedBill _slip(String ext, String date) =>
    NormalizedBill(source: BillSource.hub3, externalId: ext, date: date, dueDate: date, total: 4599, payee: 'Synth Energy');

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Matcher _fails(BackupFailure f) => throwsA(isA<BackupException>().having((e) => e.reason, 'reason', f));

void main() {
  late VaultKey key;
  final open = <WalletRepo>[];
  WalletRepo repo({int Function()? now}) {
    final r = WalletRepo.inMemory(now: now ?? () => _now);
    open.add(r);
    return r;
  }

  setUp(() => key = VaultKey.generate());
  tearDown(() {
    for (final r in open) {
      r.close();
    }
    open.clear();
  });

  test('file name: bw-backup-<date>.bwb, real ISO dates only', () {
    expect(backupFileName('2026-03-09'), 'bw-backup-2026-03-09.bwb');
    expect(() => backupFileName('2026-3-9'), throwsArgumentError);
    expect(() => backupFileName('2026-02-30'), throwsArgumentError);
    expect(() => backupFileName(''), throwsArgumentError);
  });

  test('restore refuses a wallet that holds anything, even a deleted row, before reading the file', () async {
    final a = repo()..importBatch(january);
    final bytes = await backupBytes(a, key);
    final b = repo();
    final id = b.addTransaction(date: '2026-03-01', amount: 100, category: 'Shopping');
    b.deleteTransaction(id);
    await expectLater(restoreBackupBytes(b, bytes, key), throwsStateError);
    await expectLater(restoreBackupBytes(b, [1, 2, 3], key), throwsStateError, reason: 'refused before the bytes are even opened');
  });

  test('restore into an empty wallet returns the op count and reproduces the state digest', () async {
    final a = repo()..importBatch(january);
    final info = await backupBytesWithInfo(a, key);
    expect(info.blobs, 0);
    expect(info.blobBytes, 0);
    expect(info.blobsSkipped, 0);
    expect(info.ops, greaterThan(0));
    final b = repo();
    expect(await restoreBackupBytes(b, info.bytes, key), info.ops);
    expect(b.stateDigest(), a.stateDigest());
    // merging the same file again changes nothing
    final again = await mergeBackupBytes(b, info.bytes, key);
    expect(again.ops, info.ops);
    expect(again.changedByEntity.values.fold(0, (x, y) => x + y), again.changed);
  });

  group('the file is checked as a whole', () {
    test('not JSON / not an object / no ops / ops not a list / blobs not a map: damaged', () async {
      for (final bad in <Object>[
        'plain',
        5,
        <Object>[],
        {'v': 1},
        {'v': 1, 'ops': 'x'},
        {'v': 1, 'ops': [], 'blobs': []},
        {'ops': []},
        {'v': '1', 'ops': []},
        {'v': 0, 'ops': []}
      ]) {
        final bytes = await _seal(bad, key);
        await expectLater(restoreBackupBytes(repo(), bytes, key), _fails(BackupFailure.damaged), reason: '$bad');
        await expectLater(mergeBackupBytes(repo(), bytes, key), _fails(BackupFailure.damaged), reason: '$bad');
      }
      final raw = await seal(utf8.encode('{not json'), key, aad: aadBackup);
      await expectLater(restoreBackupBytes(repo(), raw, key), _fails(BackupFailure.damaged));
    });

    test('a newer version is refused as such; version 1 with no ops is a valid empty backup', () async {
      await expectLater(
          restoreBackupBytes(repo(), await _seal({'v': backupVersion + 1, 'ops': []}, key), key), _fails(BackupFailure.newerVersion));
      await expectLater(
          mergeBackupBytes(repo(), await _seal({'v': backupVersion + 1, 'ops': []}, key), key), _fails(BackupFailure.newerVersion));
      final b = repo();
      expect(await restoreBackupBytes(b, await _seal({'v': backupVersion, 'ops': []}, key), key), 0);
    });

    test('one bad op or a bad clock spoils the whole file and nothing is applied', () async {
      final a = repo()..importBatch(january);
      final ops = [for (final op in a.snapshotOps()) op.toJson()];
      final spoiled = [
        ...ops,
        {...ops.first, 'h': 'not-a-clock'}
      ];
      final b = repo();
      await expectLater(restoreBackupBytes(b, await _seal({'v': 1, 'ops': spoiled}, key), key), _fails(BackupFailure.damaged));
      expect(b.isEmpty, isTrue);
      final c = repo();
      await expectLater(
          mergeBackupBytes(
              c,
              await _seal({
                'v': 1,
                'ops': [1, 2]
              }, key),
              key),
          _fails(BackupFailure.damaged));
      expect(c.isEmpty, isTrue);
    });

    test('a wrong key is a vault error, not a backup error', () async {
      final a = repo()..importBatch(january);
      final bytes = await backupBytes(a, key);
      await expectLater(restoreBackupBytes(repo(), bytes, VaultKey.generate()), throwsA(isA<VaultException>()));
      await expectLater(mergeBackupBytes(repo(), bytes, VaultKey.generate()), throwsA(isA<VaultException>()));
    });
  });

  group('clocks ahead of this device (H7)', () {
    test('exactly the drift ahead is fine, one millisecond more is refused, for restore and merge', () async {
      final drift = maxClockDrift.inMilliseconds;
      expect(drift, _hour);
      Future<List<int>> from(int writerNow) async {
        final a = repo(now: () => writerNow)..addTransaction(date: '2026-03-01', amount: 100, category: 'Shopping');
        return backupBytes(a, key);
      }

      final ok = await from(_now + drift);
      final late = await from(_now + drift + 1);
      expect(await restoreBackupBytes(repo(), ok, key), greaterThan(0));
      expect((await mergeBackupBytes(repo(), ok, key)).ops, greaterThan(0));
      final b = repo();
      await expectLater(restoreBackupBytes(b, late, key), _fails(BackupFailure.clockAhead));
      await expectLater(mergeBackupBytes(b, late, key), _fails(BackupFailure.clockAhead));
      await expectLater(mergeBackupBytes(b, late, key, dryRun: true), _fails(BackupFailure.clockAhead));
      expect(b.isEmpty, isTrue);
    });
  });

  group('merge', () {
    test('dry run changes nothing and reports what the real merge would; the real merge then matches it', () async {
      final a = repo()..importBatch(january);
      final bytes = await backupBytes(a, key);
      final b = repo();
      final before = b.stateDigest();
      final dry = await mergeBackupBytes(b, bytes, key, dryRun: true);
      expect(b.stateDigest(), before);
      expect(b.isEmpty, isTrue);
      expect(b.pendingOps(), isEmpty);
      final real = await mergeBackupBytes(b, bytes, key);
      expect((real.ops, real.changed), (dry.ops, dry.changed));
      expect(real.changedByEntity, dry.changedByEntity);
      expect(b.stateDigest(), a.stateDigest());
      final second = await mergeBackupBytes(b, bytes, key);
      expect(second.changedByEntity['tx'], isNull, reason: 'the same file again: no transaction field is newer');
    });

    test('bill files sealed with another key are left out and counted as none', () async {
      final a = repo()..importBatch(january);
      final bytes = await backupBytes(a, key);
      final r = await mergeBackupBytes(repo(), bytes, key, walletKey: VaultKey.generate());
      expect(r.blobs, 0);
    });
  });

  group('bill files', () {
    test('the default cap is 16 MiB', () => expect(backupBlobBytesDefault, 16 * 1024 * 1024));

    test('walletKey: a copy of the same key keeps the files, a key differing in any byte (first or last) drops them', () async {
      final a = repo();
      final ref = await BlobStore(a, key).add(_bytes(3000, 1), 'jpg');
      a.importBill(_slip('hub3:SYNTH:1', '2026-02-01'), file: ref);
      final info = await backupBytesWithInfo(a, key);
      expect(info.blobs, 1);
      final same = VaultKey(List<int>.of(key.bytes));
      expect((await mergeBackupBytes(repo(), info.bytes, key, walletKey: same)).blobs, 1);
      for (final i in [0, 1, 31]) {
        final other = List<int>.of(key.bytes);
        other[i] ^= 1;
        expect((await mergeBackupBytes(repo(), info.bytes, key, walletKey: VaultKey(other))).blobs, 0, reason: 'byte $i');
      }
      final b = repo();
      expect(await restoreBackupBytes(b, info.bytes, key), info.ops);
      expect(b.hasCachedBlob(ref.hash), isTrue);
    });

    test('a file already cached is not taken again: the second merge counts none', () async {
      final a = repo();
      final ref = await BlobStore(a, key).add(_bytes(3000, 1), 'jpg');
      a.importBill(_slip('hub3:SYNTH:1', '2026-02-01'), file: ref);
      final bytes = await backupBytes(a, key);
      final b = repo();
      expect((await mergeBackupBytes(b, bytes, key, dryRun: true)).blobs, 1);
      expect(b.hasCachedBlob(ref.hash), isFalse, reason: 'a dry run caches nothing');
      expect((await mergeBackupBytes(b, bytes, key)).blobs, 1);
      expect(b.hasCachedBlob(ref.hash), isTrue);
      expect((await mergeBackupBytes(b, bytes, key)).blobs, 0);
      expect((await mergeBackupBytes(b, bytes, key, dryRun: true)).blobs, 0);
    });

    test('writing a backup does not touch the cache use order', () async {
      final a = repo();
      for (final (i, ext) in ['hub3:SYNTH:1', 'hub3:SYNTH:2'].indexed) {
        final ref = await BlobStore(a, key).add(_bytes(2000 + i, i), 'jpg');
        a.importBill(_slip(ext, '2026-02-01'), file: ref);
      }
      final before = a.backupBlobCandidates().map((e) => e.$1).toList();
      await backupBytes(a, key);
      await backupBytes(a, key);
      expect(a.backupBlobCandidates().map((e) => e.$1).toList(), before);
    });
  });
}
