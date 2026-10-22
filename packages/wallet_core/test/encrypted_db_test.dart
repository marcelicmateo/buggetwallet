// Proof that the sqlite3 build (hook user-define `source: sqlite3mc`, SQLite3 Multiple Ciphers) opens keyed databases the way
// stage R6 needs: key right after open, wrong key fails, plaintext converts to encrypted. Synthetic data only.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// A raw 256-bit key as SQLite3MultipleCiphers (and SQLCipher) read it: `x'<64 hex>'` skips the passphrase KDF.
String rawKey(int seed) => "x'${List.generate(32, (i) => ((i * 7 + seed) & 0xff).toRadixString(16).padLeft(2, '0')).join()}'";

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('bw-enc');
    path = '${dir.path}/w.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void fill(Database db) {
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    db.execute("INSERT INTO t (v) VALUES ('alpha'), ('beta')");
  }

  String head() {
    final f = File(path).openSync();
    try {
      return String.fromCharCodes(f.readSync(15));
    } finally {
      f.closeSync();
    }
  }

  int count(Database db) => db.select('SELECT count(*) AS n FROM t').single['n'] as int;

  test('keyed db: reopen with the right key; the file is not plaintext SQLite', () {
    final key = rawKey(1);
    var db = sqlite3.open(path)..execute('PRAGMA key = "$key"');
    fill(db);
    db.close();
    expect(head(), isNot(startsWith('SQLite format 3')));
    db = sqlite3.open(path)..execute('PRAGMA key = "$key"');
    expect(db.select('SELECT v FROM t ORDER BY id').map((r) => r['v']), ['alpha', 'beta']);
    db.close();
  });

  test('wrong key and no key fail on the first read with SQLITE_NOTADB (26)', () {
    var db = sqlite3.open(path)..execute('PRAGMA key = "${rawKey(1)}"');
    fill(db);
    db.close();
    for (final key in [rawKey(2), null]) {
      db = sqlite3.open(path);
      if (key != null) db.execute('PRAGMA key = "$key"'); // setting a key never fails; the first read does
      expect(
        () => db.select('SELECT count(*) FROM sqlite_master'),
        throwsA(
          isA<SqliteException>()
              .having((e) => e.extendedResultCode, 'code', 26)
              .having((e) => e.message, 'message', 'file is not a database'),
        ),
        reason: 'key $key',
      );
      db.close();
    }
  });

  test('passphrase keys work too', () {
    var db = sqlite3.open(path)..execute("PRAGMA key = 'correct horse'");
    fill(db);
    db.close();
    db = sqlite3.open(path)..execute("PRAGMA key = 'correct horse'");
    expect(count(db), 2);
    db.close();
  });

  test('a plaintext db is encrypted in place by PRAGMA rekey', () {
    var db = sqlite3.open(path);
    fill(db);
    db.execute('PRAGMA rekey = "${rawKey(3)}"');
    db.close();
    expect(head(), isNot(startsWith('SQLite format 3')));
    db = sqlite3.open(path)..execute('PRAGMA key = "${rawKey(3)}"');
    expect(count(db), 2);
    db.close();
  });

  test('PRAGMA rekey changes the key of an encrypted db', () {
    var db = sqlite3.open(path)..execute('PRAGMA key = "${rawKey(1)}"');
    fill(db);
    db.execute('PRAGMA rekey = "${rawKey(2)}"');
    db.close();
    db = sqlite3.open(path)..execute('PRAGMA key = "${rawKey(2)}"');
    expect(count(db), 2);
    db.close();
  });

  test("a plaintext db opens without any key (today's behaviour)", () {
    var db = sqlite3.open(path);
    fill(db);
    db.close();
    expect(head(), startsWith('SQLite format 3'));
    db = sqlite3.open(path);
    expect(count(db), 2);
    db.close();
  });

  test('ATTACH ... KEY copies a plaintext db into a new encrypted file', () {
    final plain = sqlite3.open(path);
    fill(plain);
    final out = '${dir.path}/enc.db';
    plain.execute("ATTACH DATABASE '$out' AS enc KEY \"${rawKey(4)}\"");
    plain.execute('CREATE TABLE enc.t (id INTEGER PRIMARY KEY, v TEXT)');
    plain.execute('INSERT INTO enc.t SELECT * FROM main.t');
    plain.close();
    final db = sqlite3.open(out)..execute('PRAGMA key = "${rawKey(4)}"');
    expect(count(db), 2);
    db.close();
  });
}
