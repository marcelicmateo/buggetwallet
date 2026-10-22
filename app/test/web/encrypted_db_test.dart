// A keyed database on IndexedDB in the browser: sqlite3mc.wasm (fetched by tools/build.sh as web/sqlite3.wasm and
// test/sqlite3.wasm). Synthetic data. In sqlite3mc.wasm a key only works on the wrapped VFS `multipleciphers-<name>` that
// registerVirtualFileSystem(fs) also creates; opening through the plain name (or as the default VFS) gives
// "Encryption is not supported by the VFS".
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/wasm.dart';

const _key = "x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'";
const _other = "x'ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'";

void main() {
  test('keyed IndexedDB database reopens with the right key and refuses the wrong one', () async {
    final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('/sqlite3.wasm'));
    final fs = await IndexedDbFileSystem.open(dbName: 'bw-enc-test');
    sqlite.registerVirtualFileSystem(fs);
    final vfs = 'multipleciphers-${fs.name}';
    var db = sqlite.open('/enc.db', vfs: vfs)..execute('PRAGMA key = "$_key"');
    db.execute('CREATE TABLE t (v TEXT)');
    db.execute("INSERT INTO t VALUES ('alpha')");
    db.close();
    await fs.flush();

    db = sqlite.open('/enc.db', vfs: vfs)..execute('PRAGMA key = "$_key"');
    expect(db.select('SELECT v FROM t').single['v'], 'alpha');
    db.close();
    db = sqlite.open('/enc.db', vfs: vfs)..execute('PRAGMA key = "$_other"');
    expect(
      () => db.select('SELECT count(*) FROM sqlite_master'),
      throwsA(isA<SqliteException>().having((e) => e.extendedResultCode, 'code', 26)),
    );
    db.close();
    sqlite.unregisterVirtualFileSystem(fs);
    await fs.close();
    await IndexedDbFileSystem.deleteDatabase('bw-enc-test');
  });

  test('an unkeyed database opens on the wrapped VFS, and PRAGMA rekey encrypts it in place', () async {
    final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('/sqlite3.wasm'));
    final fs = InMemoryFileSystem();
    sqlite.registerVirtualFileSystem(fs);
    final vfs = 'multipleciphers-${fs.name}';
    var db = sqlite.open('/p.db', vfs: vfs);
    db.execute('CREATE TABLE t (v TEXT)');
    db.execute("INSERT INTO t VALUES ('alpha')");
    db.close();
    db = sqlite.open('/p.db', vfs: vfs);
    expect(db.select('SELECT v FROM t').single['v'], 'alpha');
    db.execute('PRAGMA rekey = "$_key"');
    db.close();
    db = sqlite.open('/p.db', vfs: vfs);
    expect(() => db.select('SELECT * FROM t'), throwsA(isA<SqliteException>()));
    db.execute('PRAGMA key = "$_key"');
    expect(db.select('SELECT v FROM t').single['v'], 'alpha');
    db.close();
  });

  test('after unregister, a second file system needs another vfsName (forget, then reopen)', () async {
    final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('/sqlite3.wasm'));
    final first = await IndexedDbFileSystem.open(dbName: 'bw-enc-test2');
    sqlite.registerVirtualFileSystem(first);
    sqlite.open('/a.db', vfs: 'multipleciphers-${first.name}')
      ..execute('PRAGMA key = "$_key"')
      ..execute('CREATE TABLE t (v TEXT)')
      ..close();
    await first.flush();
    sqlite.unregisterVirtualFileSystem(first);
    await first.close();

    // The wrapper 'multipleciphers-indexeddb' outlives unregister (re-registering the same name: RuntimeError null function).
    final second = await IndexedDbFileSystem.open(dbName: 'bw-enc-test2', vfsName: 'indexeddb-second');
    sqlite.registerVirtualFileSystem(second);
    final db = sqlite.open('/a.db', vfs: 'multipleciphers-${second.name}')..execute('PRAGMA key = "$_key"');
    expect(db.select('SELECT count(*) AS n FROM t').single['n'], 0);
    db.close();
    await second.close();
    await IndexedDbFileSystem.deleteDatabase('bw-enc-test2');
  });
}
