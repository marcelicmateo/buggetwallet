// Encrypted local database (§4.9, R6a): `localDbKey`, `openKeyed`, `WalletRepo.open(dbKey:)` and the crash-safe
// conversion of a plaintext wallet (side copy, recovery). Synthetic data only.
import 'dart:io';

import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/src/sqlite_io.dart' show openKeyedFileDb, plainCopySuffix;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

class _Crash implements Exception {}

/// Every table, row by row (rowid order), as text: what a conversion must keep identical.
Map<String, List<String>> dumpDb(CommonDatabase db) => {
      for (final t in db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"))
        t['name'] as String: [for (final r in db.select('SELECT * FROM "${t['name']}" ORDER BY rowid')) '$r'],
    };

Map<String, List<String>> dumpFile(String path, [List<int>? dbKey]) {
  final db = dbKey == null ? sqlite3.open(path) : openKeyed(() => sqlite3.open(path), dbKey);
  try {
    return dumpDb(db);
  } finally {
    db.close();
  }
}

bool isPlaintext(String path) {
  final f = File(path).openSync();
  try {
    return String.fromCharCodes(f.readSync(16)).startsWith('SQLite format 3');
  } finally {
    f.closeSync();
  }
}

Matcher get notADatabase => throwsA(isA<SqliteException>().having((e) => e.extendedResultCode & 0xff, 'code', 26));

void main() {
  late Directory dir;
  late String path;
  late VaultKey key;
  late List<int> dbKey;
  var now = DateTime.utc(2026, 1, 20, 9).millisecondsSinceEpoch;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bw-localdb');
    path = '${dir.path}/wallet.db';
    key = VaultKey.generate();
    dbKey = await localDbKey(key);
    now = DateTime.utc(2026, 1, 20, 9).millisecondsSinceEpoch;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A plaintext wallet as an older build leaves it: imported rows, a goal, a setting, a pending outbox.
  WalletRepo plainWallet() {
    final repo = WalletRepo.open(path, now: () => now);
    repo.importBatch(january);
    repo.saveGoal(name: 'Bike', target: 50000, saved: 1000, monthly: 2000);
    repo.addManual(date: '2026-01-19', amount: 1250, category: 'Groceries', note: 'market');
    repo.updateSettings({'reviewDay': 3});
    return repo;
  }

  group('localDbKey', () {
    test('32 bytes, deterministic, per wallet, and not a relay derivation', () async {
      expect(dbKey, hasLength(32));
      expect(await localDbKey(key), dbKey);
      expect(await localDbKey(await VaultKey.parse(await key.toText())), dbKey, reason: 'same wallet key text, same db key');
      expect(await localDbKey(VaultKey.generate()), isNot(dbKey));
      expect(await deriveKey(key, 'bw-local-db-v1'), dbKey);
      expect(await deriveKey(key, 'bw-relay-sign-v1'), isNot(dbKey));
      final id = await deriveKey(key, 'bw-relay-id-v1', length: 16);
      expect(dbKey.sublist(0, 16), isNot(id));
    });
  });

  group('WalletRepo.open with dbKey', () {
    test('a new database is encrypted from the start and reopens with the key', () {
      var repo = WalletRepo.open(path, dbKey: dbKey, now: () => now);
      repo.importBatch(january);
      final device = repo.deviceId;
      final txs = repo.transactions().length;
      repo.close();
      expect(isPlaintext(path), isFalse);
      expect(File('$path$plainCopySuffix').existsSync(), isFalse);

      final plain = sqlite3.open(path);
      expect(() => plain.select('SELECT count(*) FROM sqlite_master'), notADatabase, reason: 'no key, no data');
      plain.close();

      repo = WalletRepo.open(path, dbKey: dbKey, now: () => now);
      expect(repo.deviceId, device);
      expect(repo.transactions(), hasLength(txs));
      repo.close();
    });

    test('reopening keyed again and again changes nothing and never converts twice', () {
      plainWallet().close();
      final expected = dumpFile(path);
      for (var i = 0; i < 3; i++) {
        final repo = WalletRepo.open(path, dbKey: dbKey, now: () => now);
        expect(dumpDb(repo.db), expected, reason: 'open $i');
        repo.close();
        expect(isPlaintext(path), isFalse);
        expect(File('$path$plainCopySuffix').existsSync(), isFalse);
      }
      // openKeyed may be handed the same opener more than once: two connections at the same time read the same data.
      final one = openKeyed(() => sqlite3.open(path), dbKey);
      final two = openKeyed(() => sqlite3.open(path), dbKey);
      expect(dumpDb(two), dumpDb(one));
      one.close();
      two.close();
    });

    test('a plaintext wallet with sync state is converted in place: every table identical, sync goes on', () async {
      final net = Net();
      final a = Device('a', null, key, () => now, net: net);
      final b = Device('b', dir, key, () => now, dbPath: path, net: net); // plaintext, as an older build
      a.repo.importBatch(january);
      a.repo.saveGoal(name: 'Trip', target: 90000, saved: 0, monthly: 5000);
      await a.run();
      await b.run();
      b.repo.addManual(date: '2026-01-19', amount: 480, category: 'Coffee', note: 'pending');
      expect(b.repo.syncCursors(), isNotEmpty);
      final cursors = b.repo.syncCursors();
      b.repo.close();
      expect(isPlaintext(path), isTrue);
      final before = dumpFile(path);
      expect(before['outbox'], isNotEmpty, reason: 'an unsent op waits in the outbox');

      final b2 = Device('b', dir, key, () => now, dbPath: path, dbKey: dbKey, net: net);
      expect(isPlaintext(path), isFalse);
      expect(File('$path$plainCopySuffix').existsSync(), isFalse);
      expect(dumpDb(b2.repo.db), before);
      expect(b2.repo.syncCursors(), cursors);

      now += 60000;
      final r = await b2.run();
      expect(r.sent, greaterThan(0), reason: 'the outbox survived the conversion');
      await a.run();
      expect(a.repo.transactions().where((t) => t.manual), hasLength(1));
      b2.repo.close();
      a.repo.close();
    });

    test('a plaintext wallet left with an un-checkpointed WAL (app killed) loses nothing', () {
      final repo = plainWallet();
      repo.db.execute('PRAGMA wal_autocheckpoint=0');
      repo.addManual(date: '2026-01-20', amount: 999, category: 'Coffee', note: 'in the wal');
      final crashed = '${dir.path}/crashed.db';
      File(path).copySync(crashed);
      File('$path-wal').copySync('$crashed-wal');
      final live = dumpDb(repo.db);
      repo.close();
      expect(File('$crashed-wal').lengthSync(), greaterThan(0));

      final keyed = WalletRepo.open(crashed, dbKey: dbKey, now: () => now);
      expect(dumpDb(keyed.db), live);
      keyed.close();
      expect(isPlaintext(crashed), isFalse);
    });

    test('an encrypted wallet with an un-checkpointed WAL survives a wrong-key and a no-key open', () async {
      final repo = WalletRepo.open(path, dbKey: dbKey, now: () => now)..importBatch(january);
      repo.db.execute('PRAGMA wal_autocheckpoint=0');
      repo.addManual(date: '2026-01-20', amount: 999, category: 'Coffee', note: 'in the wal');
      final crashed = '${dir.path}/crashed.db';
      File(path).copySync(crashed);
      File('$path-wal').copySync('$crashed-wal');
      final live = dumpDb(repo.db);
      repo.close();

      final other = await localDbKey(VaultKey.generate());
      expect(() => WalletRepo.open(crashed, dbKey: other, now: () => now), throwsA(isA<WalletDbKeyException>()));
      expect(() => WalletRepo.open(crashed, now: () => now), notADatabase);
      final keyed = WalletRepo.open(crashed, dbKey: dbKey, now: () => now);
      expect(dumpDb(keyed.db), live);
      keyed.close();
    });

    test('a wrong key is a WalletDbKeyException and leaves the file as it was', () async {
      final repo = WalletRepo.open(path, dbKey: dbKey, now: () => now)..importBatch(january);
      repo.close();
      final bytes = File(path).readAsBytesSync();
      final other = await localDbKey(VaultKey.generate());
      expect(() => WalletRepo.open(path, dbKey: other, now: () => now), throwsA(isA<WalletDbKeyException>()));
      expect(() => openKeyed(() => sqlite3.open(path), other), throwsA(isA<WalletDbKeyException>()));
      expect(File(path).readAsBytesSync(), bytes);
      expect(File('$path$plainCopySuffix').existsSync(), isFalse);
      final again = WalletRepo.open(path, dbKey: dbKey, now: () => now);
      expect(again.transactions(), isNotEmpty);
      again.close();
    });

    test('an encrypted wallet opened without a key fails on the first read, the file unchanged', () {
      WalletRepo.open(path, dbKey: dbKey, now: () => now).close();
      final bytes = File(path).readAsBytesSync();
      expect(() => WalletRepo.open(path, now: () => now), notADatabase);
      expect(File(path).readAsBytesSync(), bytes);
    });

    test('a key that is not 32 bytes is an ArgumentError', () {
      expect(() => openKeyed(() => sqlite3.open(path), [1, 2, 3]), throwsArgumentError);
    });
  });

  group('interrupted conversion', () {
    for (final step in ['copied', 'rekeyed', 'verified']) {
      test('a crash after "$step" is recovered from the side copy at the next open', () {
        plainWallet().close();
        final expected = dumpFile(path);
        expect(() => openKeyedFileDb(path, dbKey, step: (s) => s == step ? throw _Crash() : null), throwsA(isA<_Crash>()));
        expect(File('$path$plainCopySuffix').existsSync(), isTrue, reason: 'the copy outlives the crash');

        final repo = WalletRepo.open(path, dbKey: dbKey, now: () => now);
        expect(dumpDb(repo.db), expected);
        repo.close();
        expect(isPlaintext(path), isFalse);
        expect(File('$path$plainCopySuffix').existsSync(), isFalse);
      });
    }

    test('a main file damaged mid-rekey (torn pages, hot journal) is replaced by the copy', () {
      plainWallet().close();
      final expected = dumpFile(path);
      expect(() => openKeyedFileDb(path, dbKey, step: (s) => s == 'copied' ? throw _Crash() : null), throwsA(isA<_Crash>()));
      final f = File(path);
      final torn = f.readAsBytesSync()..fillRange(4096, 8192, 0xa5);
      f.writeAsBytesSync(torn);
      File('$path-journal').writeAsBytesSync(List.filled(512, 7));

      final repo = WalletRepo.open(path, dbKey: dbKey, now: () => now);
      expect(dumpDb(repo.db), expected);
      repo.close();
      expect(File('$path-journal').existsSync(), isFalse);
    });

    test('an incomplete copy (crash while copying) is dropped; the untouched main file converts', () {
      plainWallet().close();
      final expected = dumpFile(path);
      File('$path$plainCopySuffix.tmp').writeAsBytesSync([1, 2, 3]);
      final repo = WalletRepo.open(path, dbKey: dbKey, now: () => now);
      expect(dumpDb(repo.db), expected);
      repo.close();
      expect(File('$path$plainCopySuffix.tmp').existsSync(), isFalse);
    });
  });

  test('open time for a perf-sized wallet (~20k rows), keyed vs plaintext (numbers in the output, no limit)', () {
    final repo = WalletRepo.open(path, now: () => now);
    final start = DateTime.utc(2021, 1, 1);
    final txs = [
      for (var i = 0; i < 20000; i++)
        n(start.add(Duration(days: i ~/ 11)).toIso8601String().substring(0, 10), -(100 + i % 9000), 'POS plaćanje',
            'SHOP ${i % 400} ZAGREB',
            occ: i),
    ];
    repo.importBatch(ImportBatch(source: 'pbz', transactions: txs));
    repo.close();

    int median(List<int> xs) => (xs..sort())[xs.length ~/ 2];
    List<int> opens(List<int>? k) => [
          for (var i = 0; i < 5; i++)
            () {
              final sw = Stopwatch()..start();
              final r = WalletRepo.open(path, dbKey: k, now: () => now);
              final ms = sw.elapsedMilliseconds;
              expect(r.transactions().length, greaterThanOrEqualTo(20000));
              r.close();
              return ms;
            }(),
        ];

    final plain = opens(null);
    final sw = Stopwatch()..start();
    WalletRepo.open(path, dbKey: dbKey, now: () => now).close();
    final convert = sw.elapsedMilliseconds;
    final keyed = opens(dbKey);
    stdout.writeln('local db perf: ${File(path).lengthSync() ~/ 1024} KiB; open plaintext median ${median(plain)} ms $plain, '
        'convert $convert ms, open keyed median ${median(keyed)} ms $keyed');
  });
}
