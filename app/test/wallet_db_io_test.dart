// The native database files: a plaintext wallet.db is converted on first start with a key, a wallet.db without a key is set aside
// (never deleted) when a new wallet is created, forget deletes everything. Real SQLite files in a temp folder. SYNTHETIC data.
import 'dart:io';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/wallet_db_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'support/seams.dart';

void main() {
  late Directory dir;
  late String path;
  String? storedId; // the device id in the fake key store
  setUp(() {
    storedId = null;
    dir = Directory.systemTemp.createTempSync('bw-dbio-');
    path = '${dir.path}${Platform.pathSeparator}wallet.db';
    addTearDown(() {
      dir.deleteSync(recursive: true);
    });
  });

  Future<WalletController> load(VaultKey? key) async {
    final wc = await seamedLoad(loadDeps(dbDir: dir.path).copyWith(
      deviceIdReader: () async => storedId,
      deviceIdWriter: (id) async => storedId = id,
      keyReader: () async => key,
      joinMarkerReader: () async => null,
      isLocked: () => false,
      clock: () => DateTime(2026, 10, 22, 12),
    ));
    await Future<void>.delayed(Duration.zero);
    addTearDown(wc.dispose);
    wc.seams.keyWriter = (k, {passphrase}) async {};
    wc.seams.keyForgetter = () async {};
    return wc;
  }

  void plaintextWallet() {
    final r = WalletRepo.open(path);
    r.saveGoal(name: 'Old goal', target: 100000, saved: 0, monthly: 1000, sort: 1);
    r.close();
  }

  /// The folder's files, without the open database's own `-wal`/`-shm`.
  List<String> names() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).where((n) => n != 'wallet.db-wal' && n != 'wallet.db-shm').toList()..sort();

  test('a plaintext wallet.db is converted on the first start with a key, and still has its data', () async {
    plaintextWallet();
    final key = VaultKey.generate();
    final wc = await load(key);
    expect(wc.hasWallet, isTrue);
    expect(wc.goals.single.name, 'Old goal');
    expect(File(path).readAsBytesSync().sublist(0, 15), isNot('SQLite format 3'.codeUnits));
    expect(names(), ['wallet.db']); // the plaintext side copy is gone
  });

  test('joining with a key while an unkeyed wallet.db exists sets it aside as it was; nothing is converted or merged', () async {
    plaintextWallet();
    expect(await walletDbIsPlaintext(dir: dir.path), isTrue);
    final before = File(path).readAsBytesSync();
    final wc = await load(null);
    await wc.joinWallet(await VaultKey.generate().toText());
    expect(wc.goals, isEmpty);
    expect(File('$path.unopened-2026-10-22').readAsBytesSync(), before); // untouched, still plaintext
    expect(await walletDbIsPlaintext(dir: dir.path), isFalse);
  });

  test('a wallet.db without a key is left alone until a new wallet is created, then set aside with its side files', () async {
    plaintextWallet();
    File('$path-wal').writeAsStringSync('w');
    final before = File(path).readAsBytesSync();
    final wc = await load(null);
    expect(wc.hasWallet, isFalse);
    expect(wc.hasUnopenedDb, isTrue);
    expect(File(path).readAsBytesSync(), before); // untouched
    await wc.createWallet();
    expect(names(), ['wallet.db', 'wallet.db.unopened-2026-10-22', 'wallet.db.unopened-2026-10-22-wal']);
    expect(File('$path.unopened-2026-10-22').readAsBytesSync(), before);
    expect(wc.goals.map((g) => g.name), isNot(contains('Old goal')));
  });

  test('setting aside twice on one day uses a new name; without a file nothing happens', () async {
    await setAsideWalletDb('2026-10-22', dir: dir.path);
    expect(names(), isEmpty);
    File(path).writeAsStringSync('a');
    await setAsideWalletDb('2026-10-22', dir: dir.path);
    File(path).writeAsStringSync('b');
    await setAsideWalletDb('2026-10-22', dir: dir.path);
    expect(names(), ['wallet.db.unopened-2026-10-22', 'wallet.db.unopened-2026-10-22-2']);
    expect(File('$path.unopened-2026-10-22-2').readAsStringSync(), 'b');
  });

  test('a set-aside that fails half way puts the files it moved back: wallet.db and its side files stay together', () async {
    File(path).writeAsStringSync('main');
    File('$path-wal').writeAsStringSync('wal');
    File('$path-shm').writeAsStringSync('shm');
    // The target of the -shm file is taken by a folder, so that rename fails after wallet.db and -wal were moved.
    Directory('$path.unopened-2026-10-22-shm').createSync();
    await expectLater(setAsideWalletDb('2026-10-22', dir: dir.path), throwsA(anything));
    expect(File(path).readAsStringSync(), 'main', reason: 'wallet.db is back');
    expect(File('$path-wal').readAsStringSync(), 'wal');
    expect(File('$path-shm').readAsStringSync(), 'shm');
    expect(File('$path.unopened-2026-10-22').existsSync(), isFalse, reason: 'nothing is left half moved');
    expect(File('$path.unopened-2026-10-22-wal').existsSync(), isFalse);
  });

  test('a stored key that does not open the file leaves it alone', () async {
    final first = await load(VaultKey.generate());
    first.repo.close();
    final before = File(path).readAsBytesSync();
    final wc = await load(VaultKey.generate());
    expect(wc.hasWallet, isFalse);
    expect(wc.hasUnopenedDb, isTrue);
    expect(File(path).readAsBytesSync(), before);
    expect(names(), ['wallet.db']);
  });

  test('forget deletes the file and its side files; a new wallet then starts a new file', () async {
    plaintextWallet();
    final wc = await load(VaultKey.generate());
    File('$path.plain-copy').writeAsStringSync('x');
    await wc.forgetBrowser();
    expect(names(), isEmpty);
    await wc.createWallet();
    expect(names(), ['wallet.db']);
    expect(wc.goals, hasLength(2));
  });

  test('walletDbExists sees the file', () async {
    expect(await walletDbExists(dir: dir.path), isFalse);
    plaintextWallet();
    expect(await walletDbExists(dir: dir.path), isTrue);
  });

  group('device id (H6) with a real file', () {
    test('upgrade: the id inside the database moves to the store once, then it is passed on every open', () async {
      final key = VaultKey.generate();
      final dbKey = await localDbKey(key);
      final r = WalletRepo.open(path, dbKey: dbKey);
      final inside = r.deviceId;
      r.close();

      final first = await load(key);
      expect(first.repo.deviceId, inside);
      expect(storedId, inside);

      storedId = 'installidABC123'; // this install's own id: a copied database takes it
      final second = await load(key);
      expect(second.repo.deviceId, 'installidABC123');
      expect(second.repo.db.select("SELECT value FROM meta WHERE key = 'device_id'").first['value'], 'installidABC123');
    });

    test('a fresh install makes an id, stores it and the new database uses it', () async {
      final wc = await load(null);
      await wc.createWallet();
      expect(storedId, isNotNull);
      expect(wc.repo.deviceId, storedId);
    });
  });
}
