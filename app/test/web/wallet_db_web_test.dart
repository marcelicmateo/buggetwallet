// The browser wallet database (R6b): keyed on the wrapped IndexedDB VFS, an unkeyed database from the previous web build is converted,
// a wrong key is refused, set-aside keeps the bytes, and forget + reopen uses a new vfsName. Real IndexedDB and sqlite3mc.wasm
// (fetched by make as test/sqlite3.wasm). The tests run in order and share the page's module state. SYNTHETIC data.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:budget_wallet/src/wallet_db_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/wasm.dart';
import 'package:wallet_core/wallet_core.dart';

Uint8List _key(int seed) => Uint8List.fromList(List.generate(32, (i) => (i + seed) & 0xff));

/// What the previous web build stored: an unkeyed wallet.db on IndexedDB, as the default VFS.
Future<void> _legacyUnkeyedWallet() async {
  final sqlite = await WasmSqlite3.loadFromUrl(Uri.parse('/sqlite3.wasm'));
  final fs = await IndexedDbFileSystem.open(dbName: 'budget-wallet', vfsName: 'legacy');
  sqlite.registerVirtualFileSystem(fs, makeDefault: true);
  final repo = WalletRepo.fromDatabase(sqlite.open('/wallet.db'), file: true);
  repo.saveGoal(name: 'Old goal', target: 100000, saved: 0, monthly: 1000, sort: 1);
  repo.close();
  await fs.flush();
  sqlite.unregisterVirtualFileSystem(fs);
  await fs.close();
}

/// Looks at the stored file system from a second, raw handle: (exists, first bytes are the plain SQLite header).
Future<({bool exists, bool plain, int size})> _peek(String path) async {
  final fs = await IndexedDbFileSystem.open(dbName: 'budget-wallet', vfsName: 'peek-${DateTime.now().microsecondsSinceEpoch}');
  try {
    if (fs.xAccess(path, 0) == 0) return (exists: false, plain: false, size: 0);
    final f = fs.xOpen(Sqlite3Filename(path), 1).file;
    final size = f.xFileSize();
    final head = Uint8List(16);
    f.xRead(head, 0);
    f.xClose();
    return (exists: true, plain: String.fromCharCodes(head.sublist(0, 15)) == 'SQLite format 3', size: size);
  } finally {
    await fs.close();
  }
}

void main() {
  setUpAll(() async {
    sqliteWasmUri = Uri.parse('/sqlite3.wasm');
    await IndexedDbFileSystem.deleteDatabase('budget-wallet');
  });

  test('nothing stored: no file, a new keyed database is created and persisted encrypted', () async {
    await claimWalletDb();
    expect(await walletDbExists(), isFalse);
    final db = await openWalletDb(_key(1));
    expect(db.converted, isFalse);
    expect(db.persists, isTrue);
    db.repo.saveGoal(name: 'Goal A', target: 5000, saved: 0, monthly: 100, sort: 1);
    await db.persist();
    db.repo.close();
    final seen = await _peek('/wallet.db');
    expect(seen.exists, isTrue);
    expect(seen.plain, isFalse); // encrypted in IndexedDB

    final again = await openWalletDb(_key(1)); // the right key reopens it, with its data
    expect(again.repo.goals().single.name, 'Goal A');
    again.repo.close();
  });

  test('the wrong key is refused and the file is untouched', () async {
    final before = await _peek('/wallet.db');
    await expectLater(openWalletDb(_key(2)), throwsA(isA<WalletDbKeyException>()));
    expect(await walletDbExists(), isTrue);
    final right = await openWalletDb(_key(1));
    expect(right.repo.goals().single.name, 'Goal A');
    await right.persist();
    right.repo.close();
    expect((await _peek('/wallet.db')).size, before.size);
  });

  test('set aside keeps the old bytes under wallet.db.unopened-<stamp> and leaves no wallet.db', () async {
    final before = await _peek('/wallet.db');
    await setAsideWalletDb('2026-10-22');
    expect(await walletDbExists(), isFalse);
    final aside = await _peek('/wallet.db.unopened-2026-10-22');
    expect(aside.exists, isTrue);
    expect(aside.size, before.size);
    expect(aside.plain, isFalse);
    final fresh = await openWalletDb(_key(3)); // a new wallet starts empty
    expect(fresh.repo.goals(), isEmpty);
    await fresh.persist();
    fresh.repo.close();
    expect((await _peek('/wallet.db.unopened-2026-10-22')).exists, isTrue); // still there
  });

  test('forget deletes the wallet but keeps set-aside copies; a reopen gets a new vfsName and a new empty keyed database', () async {
    final db = await openWalletDb(_key(3));
    await db.forget();
    expect((await _peek('/wallet.db')).exists, isFalse);
    expect((await _peek('/wallet.db.unopened-2026-10-22')).exists, isTrue); // an older wallet set aside is never deleted
    expect(await walletDbExists(), isFalse);
    final again = await openWalletDb(_key(4));
    expect(again.repo.goals(), isEmpty);
    again.repo.saveGoal(name: 'Goal B', target: 1000, saved: 0, monthly: 10, sort: 1);
    await again.persist();
    again.repo.close();
    final third = await openWalletDb(_key(4));
    expect(third.repo.goals().single.name, 'Goal B');
    await third.forget();
  });

  test('an unkeyed wallet from the previous web build opens on the wrapped VFS and is converted', () async {
    await _legacyUnkeyedWallet();
    expect((await _peek('/wallet.db')).plain, isTrue);
    expect(await walletDbExists(), isTrue);
    expect(await walletDbIsPlaintext(), isTrue);
    final db = await openWalletDb(_key(5));
    expect(db.converted, isTrue);
    expect(db.repo.goals().single.name, 'Old goal');
    await db.persist();
    db.repo.close();
    expect((await _peek('/wallet.db')).plain, isFalse);
    expect(await walletDbIsPlaintext(), isFalse);
    await expectLater(openWalletDb(_key(6)), throwsA(isA<WalletDbKeyException>()));
    final reopened = await openWalletDb(_key(5));
    expect(reopened.converted, isFalse);
    expect(reopened.repo.goals().single.name, 'Old goal');
    await reopened.forget();
  });
}
