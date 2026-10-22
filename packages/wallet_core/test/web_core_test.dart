// Web-safe core (§4.8): WalletRepo.fromDatabase, the pure backup half (backupBytes / restoreBackupBytes), MemoryLogSink
// and the gzip change in vault.dart (package:archive instead of dart:io): files sealed by phones (dart:io gzip) must
// still unseal, and what the pure-Dart gzip of a web build writes must be accepted. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io' show Directory, File, gzip;
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoderWeb, GZipEncoderWeb;
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

final _aead = Xchacha20.poly1305Aead();

/// A correctly authenticated file whose content is [inner] as is (no gzip), laid out like `seal`.
Future<Uint8List> _sealRaw(List<int> inner, VaultKey key) async {
  final box = await _aead.encrypt(inner, secretKey: SecretKey(key.bytes));
  return Uint8List.fromList([...utf8.encode('BWOP1'), ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

/// The authenticated content of a sealed file: the gzip member `seal` wrote.
Future<List<int>> _openRaw(List<int> sealed, VaultKey key) => _aead.decrypt(
      SecretBox(sealed.sublist(45), nonce: sealed.sublist(5, 29), mac: Mac(sealed.sublist(29, 45))),
      secretKey: SecretKey(key.bytes),
    );

void main() {
  var now = 1767225600000;
  setUp(() => now = 1767225600000);

  group('WalletRepo.fromDatabase', () {
    test('wraps an open database: schema, migrations and writes work like inMemory, close disposes it', () {
      final db = sqlite3.openInMemory();
      final repo = WalletRepo.fromDatabase(db, file: false, now: () => now);
      expect(identical(repo.db, db), isTrue);
      expect(repo.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      expect(repo.deviceId, hasLength(16));
      expect(repo.isEmpty, isTrue);
      repo.importBatch(january);
      expect(repo.transactions(), hasLength(january.transactions.length));
      expect(repo.isEmpty, isFalse);
      repo.close();
      expect(() => db.select('SELECT 1'), throwsA(isA<Object>()), reason: 'close disposes the database it was given');
    });

    test('a database opened twice keeps its device id and data (a file database in the browser)', () {
      final db = sqlite3.openInMemory();
      final a = WalletRepo.fromDatabase(db, file: true, now: () => now);
      a.importBatch(january);
      final id = a.deviceId;
      // Same connection handed to a second repo (what a page reload does with a persistent WASM database).
      final b = WalletRepo.fromDatabase(db, file: true, now: () => now);
      expect(b.deviceId, id);
      expect(b.transactions(), hasLength(january.transactions.length));
      b.close();
    });

    test('open and inMemory still work on the VM', () {
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      expect(r.isEmpty, isTrue);
      final dir = Directory.systemTemp.createTempSync('bw-web-core-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = WalletRepo.open('${dir.path}/w.db', now: () => now);
      f.importBatch(january);
      f.close();
      final again = WalletRepo.open('${dir.path}/w.db', now: () => now);
      addTearDown(again.close);
      expect(again.transactions(), hasLength(january.transactions.length));
    });
  });

  group('backup bytes (pure half)', () {
    test('backupFileName is bw-backup-<today>.bwb and refuses anything but YYYY-MM-DD', () {
      expect(backupFileName('2026-10-21'), 'bw-backup-2026-10-21.bwb');
      for (final bad in ['2026-1-21', '21.10.2026', '', 'today', '2026-10-21T00:00']) {
        expect(() => backupFileName(bad), throwsArgumentError, reason: bad);
      }
    });

    test('backupBytes → restoreBackupBytes round trip into an empty wallet keeps rows and clocks', () async {
      final key = VaultKey.generate();
      final a = WalletRepo.inMemory(now: () => now);
      addTearDown(a.close);
      a.importBatch(january);
      now += 1000;
      a.updateSettings({'reviewDay': 3});
      final bytes = await backupBytes(a, key);
      expect(bytes.sublist(0, 5), utf8.encode('BWOP1'), reason: 'sealed like a sync file');

      final b = WalletRepo.inMemory(now: () => now);
      addTearDown(b.close);
      final ops = await restoreBackupBytes(b, bytes, key);
      expect(ops, a.snapshotOps().length);
      expect(b.transactions().map((t) => (t.id, t.amount, t.date)).toSet(), a.transactions().map((t) => (t.id, t.amount, t.date)).toSet());
      expect(b.settings().reviewDay, 3);
      Set<String> clocks(WalletRepo r) => {
            for (final row in r.db.select('SELECT entity, id, field, hlc FROM clocks')) row.values.join('|'),
          };
      expect(clocks(b), clocks(a), reason: 'the same field clocks, not fresh ones');
      expect(b.pendingOps(), isNotEmpty, reason: 'resend: the restored ops go out on the next sync');
    });

    test('refuses a wallet with data before reading the bytes', () async {
      final key = VaultKey.generate();
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      r.importBatch(january);
      await expectLater(restoreBackupBytes(r, Uint8List(0), key), throwsStateError);
    });

    test('wrong key is the VaultException, damaged or newer content a BackupException with its reason', () async {
      final key = VaultKey.generate();
      final src = WalletRepo.inMemory(now: () => now);
      addTearDown(src.close);
      src.importBatch(january);
      final bytes = await backupBytes(src, key);

      Future<void> expectRefused(List<int> data, VaultKey k, Matcher m) async {
        final r = WalletRepo.inMemory(now: () => now);
        addTearDown(r.close);
        await expectLater(restoreBackupBytes(r, data, k), m);
        expect(r.isEmpty, isTrue, reason: 'nothing applied');
      }

      await expectRefused(
          bytes, VaultKey.generate(), throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.badKey)));
      await expectRefused(await seal(utf8.encode('[1,2]'), key), key,
          throwsA(isA<BackupException>().having((e) => e.reason, 'reason', BackupFailure.damaged)));
      await expectRefused(await seal(utf8.encode('{"v":${backupVersion + 1},"ops":[]}'), key), key,
          throwsA(isA<BackupException>().having((e) => e.reason, 'reason', BackupFailure.newerVersion)));
      await expectRefused(await seal(utf8.encode('{"v":1,"ops":[{"e":"tx","id":"x","f":{},"h":"not a clock"}]}'), key), key,
          throwsA(isA<BackupException>().having((e) => e.reason, 'reason', BackupFailure.damaged)));
    });

    test('writeBackup writes exactly a backupBytes payload; restoreBackup reads it through restoreBackupBytes', () async {
      final key = VaultKey.generate();
      final dir = Directory.systemTemp.createTempSync('bw-web-core-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = WalletRepo.inMemory(now: () => now);
      addTearDown(a.close);
      a.importBatch(january);
      final name = await writeBackup(a, dir.path, key, today: '2026-10-21');
      expect(name, backupFileName('2026-10-21'));
      final fileBytes = File(backupPath(dir.path, name)).readAsBytesSync();
      // Same plaintext (the nonce differs per seal), restorable by the pure function.
      expect(await unseal(fileBytes, key), await unseal(await backupBytes(a, key), key));
      final b = WalletRepo.inMemory(now: () => now);
      addTearDown(b.close);
      expect(await restoreBackupBytes(b, fileBytes, key), a.snapshotOps().length);
      final c = WalletRepo.inMemory(now: () => now);
      addTearDown(c.close);
      expect(await restoreBackup(c, backupPath(dir.path, name), key), a.snapshotOps().length);
      expect((await listBackups(dir.path)).map((b) => b.name), [name]);
    });
  });

  group('gzip compatibility (package:archive)', () {
    final key = VaultKey([for (var i = 0; i < 32; i++) (i * 7 + 3) & 0xFF]);
    final text = utf8.encode('[{"e":"tx","id":"a","f":{"amount":-1234},"h":"1:1:a"}]' * 20);

    test('a member written by dart:io gzip (phones and desktops today) unseals', () async {
      final file = await _sealRaw(gzip.encode(text), key);
      expect(await unseal(file, key), text);
    });

    test('a member written by the pure-Dart encoder (what a web build writes) unseals, so _wholeGzip accepts it', () async {
      final z = const GZipEncoderWeb().encodeBytes(text);
      expect(z.sublist(0, 2), [0x1f, 0x8b]);
      final file = await _sealRaw(z, key);
      expect(await unseal(file, key), text);
      // An empty payload too (header + empty deflate block + trailer).
      expect(await unseal(await _sealRaw(const GZipEncoderWeb().encodeBytes(const []), key), key), isEmpty);
    });

    test('what seal writes today is one gzip member the pure-Dart decoder reads (a web build reads phone files)', () async {
      final sealed = await seal(text, key);
      final inner = await _openRaw(sealed, key);
      expect(inner.sublist(0, 2), [0x1f, 0x8b]);
      expect(const GZipDecoderWeb().decodeBytes(inner, verify: true), text);
    });

    test('a cut-off pure-Dart member is refused as damaged, never returned as a short payload', () async {
      final z = const GZipEncoderWeb().encodeBytes(text);
      for (final cut in [8, 18, z.length ~/ 2, z.length - 1]) {
        final file = await _sealRaw(z.sublist(0, cut), key);
        await expectLater(unseal(file, key), throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.damaged)),
            reason: 'cut at $cut');
      }
    });

    test('seal → unseal round trips, empty and large', () async {
      for (final plain in [<int>[], utf8.encode('x'), List<int>.generate(300000, (i) => i * 31 & 0xFF)]) {
        expect(await unseal(await seal(plain, key), key), plain, reason: '${plain.length} bytes');
      }
    });
  });

  group('MemoryLogSink', () {
    test('keeps lines in order, dumps them joined with newlines, flush and close complete', () async {
      final s = MemoryLogSink();
      expect(s.maxBytes, 2 * 1024 * 1024);
      expect(s.lines, isEmpty);
      expect(s.dump(), '');
      s.add('one');
      s.add('two');
      expect(s.lines, ['one', 'two']);
      expect(s.dump(), 'one\ntwo');
      expect(s.dropped, 0);
      await s.flush();
      expect(s.lines, ['one', 'two']);
      await s.close();
      s.add('three');
      expect(s.lines, ['one', 'two'], reason: 'closed: later lines are dropped');
    });

    test('drops the oldest lines once the UTF-8 bytes (plus newlines) pass maxBytes and counts them', () {
      final s = MemoryLogSink(maxBytes: 20);
      s.add('aaaa'); // 5 bytes with the newline
      s.add('bbbb'); // 10
      s.add('cccc'); // 15
      s.add('dddd'); // 20: still within
      expect(s.lines, ['aaaa', 'bbbb', 'cccc', 'dddd']);
      expect(s.dropped, 0);
      s.add('e'); // 22 → drop 'aaaa'
      expect(s.lines, ['bbbb', 'cccc', 'dddd', 'e']);
      expect(s.dropped, 1);
      s.add('ćć'); // 2 × 2 bytes + 1 = 5 → 22 → drop 'bbbb'
      expect(s.lines, ['cccc', 'dddd', 'e', 'ćć']);
      expect(s.dropped, 2);
      expect(s.bytes, 17);
    });

    test('a line larger than maxBytes is kept alone (the newest line is never lost)', () {
      final s = MemoryLogSink(maxBytes: 10);
      s.add('short');
      s.add('x' * 50);
      expect(s.lines, ['x' * 50]);
      expect(s.dropped, 1);
      s.add('after');
      expect(s.lines, ['after']);
      expect(s.dropped, 2);
    });

    test('maxBytes must be positive', () {
      expect(() => MemoryLogSink(maxBytes: 0), throwsArgumentError);
      expect(() => MemoryLogSink(maxBytes: -1), throwsArgumentError);
    });

    test('is a LogSink, like RotatingFileSink', () {
      final dir = Directory.systemTemp.createTempSync('bw-web-core-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sinks = <LogSink>[MemoryLogSink(), RotatingFileSink(dir)];
      expect(sinks, hasLength(2));
    });
  });

  group('web-safe sync types', () {
    test('SyncReport, SyncException and the engine are exported (no dart:io in the engine)', () {
      const r = SyncReport(1, 2, 3, problems: [SyncProblem('abcdef01', SyncProblemReason.badKey, bytes: 10)]);
      expect(r.badFiles, 1);
      expect(r.problemsByDevice, {'abcdef01': 1});
      expect([r.caughtUp, r.waiting.isEmpty, r.devices.isEmpty], [false, true, true]);
      expect(const SyncException('x').toString(), 'x');
      expect(SyncEngine(MemoryTransport(), VaultKey.generate(), appVersion: '1.2').build, endsWith('+1.2'));
      for (final f in ['sync_engine.dart', 'sync_memory.dart', 'sync_relay.dart', 'sync.dart', 'sync_problems.dart']) {
        expect(File('lib/src/$f').readAsStringSync(), isNot(contains("import 'dart:io'")), reason: f);
      }
    });
  });
}
