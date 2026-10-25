// Stage N2 (spec §5): accounts need no sync, backup or migration code. Two devices sync an account and a correction,
// a backup round trip keeps accounts (deleted ones too), and the schema 7 old-build fixtures open and migrate to 9.
// All data SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';
import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = n2Now;
  final devices = <Device>[];

  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  Future<void> syncAll(List<Device> ds) async {
    for (var round = 0; round < 3; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        await d.run();
        d.upload(net);
      }
    }
  }

  List<Map<String, Object?>> rows(WalletRepo r) =>
      [for (final x in r.db.select('SELECT * FROM accounts ORDER BY id')) Map<String, Object?>.from(x)];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-n2-');
    key = VaultKey.generate();
    net = Net();
    now = n2Now;
  });
  tearDown(() {
    for (final d in devices) {
      d.repo.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  group('two devices', () {
    test('an account added on A reaches B with every field; a correction on B reaches A', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addAccount(name: 'Bank 1', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-09-30');
      await syncAll([a, b]);
      final got = b.repo.accounts().single;
      expect((got.id, got.name, got.source, got.currency, got.opening, got.openingDate, got.deleted),
          (id, 'Bank 1', 'pbz', 'EUR', 100000, '2026-09-30', false));
      now += 60000;
      await b.repo.correctBalance(id, balance: 91234, date: '2026-10-09');
      await syncAll([a, b]);
      final back = a.repo.accounts().single;
      expect((back.opening, back.openingDate), (91234, '2026-10-09'));
      expect(rows(a.repo), rows(b.repo), reason: 'same values and the same clocks columns');
    }, timeout: _t);

    test('a cash account (null source) keeps null across sync', () async {
      final a = device('a'), b = device('b');
      await a.repo.addAccount(name: 'Cash', source: null, currency: 'EUR', opening: 2500, openingDate: '2026-10-01');
      await syncAll([a, b]);
      expect(b.repo.accounts().single.isCash, isTrue);
    }, timeout: _t);

    test('different fields edited offline on two devices merge; the same field: the later write wins', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 1000, openingDate: '2026-09-01');
      await syncAll([a, b]);
      now += 1000;
      await a.repo.updateAccount(id, name: 'Main');
      now += 1000;
      await b.repo.updateAccount(id, opening: 2000);
      now += 1000;
      await a.repo.updateAccount(id, opening: 3000);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final x = d.repo.accounts().single;
        expect((x.name, x.opening), ('Main', 3000), reason: d.name);
      }
      expect(rows(a.repo), rows(b.repo));
    }, timeout: _t);

    test('a delete on A and a restore on B: the later write wins on both, in either arrival order', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 1000, openingDate: '2026-09-01');
      await syncAll([a, b]);
      now += 1000;
      await a.repo.deleteAccount(id);
      await syncAll([a, b]);
      expect(b.repo.accounts(), isEmpty);
      now += 1000;
      await b.repo.undeleteAccount(id);
      await syncAll([a, b]);
      expect(a.repo.accounts().single.id, id);
      expect(rows(a.repo), rows(b.repo));
    }, timeout: _t);

    test('a third device joining late gets the account and its latest correction', () async {
      final a = device('a'), b = device('b');
      final id = await a.repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 1000, openingDate: '2026-09-01');
      await syncAll([a, b]);
      now += 1000;
      await b.repo.correctBalance(id, balance: 4242, date: '2026-10-02');
      await syncAll([a, b]);
      final c = device('c');
      await syncAll([a, b, c]);
      expect(c.repo.accounts().single.opening, 4242);
      expect(rows(c.repo), rows(a.repo));
    }, timeout: _t);

    test('two devices adding the same cash account offline both sync without error and converge identically', () async {
      final a = device('a'), b = device('b');
      final ia = await a.repo.addAccount(name: 'Cash', source: null, currency: 'EUR', opening: 100, openingDate: '2026-10-01');
      final ib = await b.repo.addAccount(name: 'Cash', source: null, currency: 'EUR', opening: 200, openingDate: '2026-10-01');
      await syncAll([a, b]);
      expect(rows(a.repo), rows(b.repo));
      expect(a.repo.accounts(), hasLength(2), reason: 'sync cannot refuse; the app lets the owner delete one');
      final smallest = ia.compareTo(ib) < 0 ? ia : ib;
      final other = smallest == ia ? ib : ia;
      for (final d in [a, b]) {
        final bal = accountBalances(d.repo.accounts(), const []);
        final kept = bal.firstWhere((x) => x.account.id == smallest);
        final dup = bal.firstWhere((x) => x.account.id == other);
        expect(kept.duplicateOf, isNull, reason: d.name);
        expect(dup.duplicateOf, smallest, reason: d.name);
        expect((dup.rowsCounted, dup.lastRowDate), (0, null));
        expect(dup.balance, dup.account.opening);
        expect(balanceTotals(bal), {'EUR': kept.account.opening}, reason: 'counted once');
      }
    }, timeout: _t);
  });

  group('backup', () {
    test('a backup round trip keeps accounts, including a deleted one and the corrected opening', () async {
      final a = device('a');
      final bank = await a.repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-09-30');
      final cash = await a.repo.addAccount(name: 'Cash', source: null, currency: 'EUR', opening: 5000, openingDate: '2026-10-01');
      final gone = await a.repo.addAccount(name: 'Old', source: 'revolut', currency: 'USD', opening: 7, openingDate: '2026-08-01');
      now += 1000;
      await a.repo.correctBalance(bank, balance: 98765, date: '2026-10-08');
      await a.repo.deleteAccount(gone);
      expect(a.repo.isEmpty, isFalse);

      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory(now: () => now);
      addTearDown(fresh.close);
      expect(fresh.isEmpty, isTrue);
      final count = await restoreBackupBytes(fresh, file, key);
      expect(count, a.repo.snapshotOps().length);
      expect(rows(fresh), rows(a.repo));
      expect(fresh.accounts().map((x) => x.id).toSet(), {bank, cash});
      expect(fresh.accounts().firstWhere((x) => x.id == bank).opening, 98765);
      expect(fresh.accounts(includeDeleted: true).firstWhere((x) => x.id == gone).deleted, isTrue);
    }, timeout: _t);

    test('a wallet holding only an account is not empty (restore refuses it)', () async {
      final a = device('a');
      final b = device('b');
      expect(a.repo.isEmpty, isTrue);
      await a.repo.addAccount(name: 'Cash', source: null, currency: 'EUR', opening: 0, openingDate: '2026-10-01');
      expect(a.repo.isEmpty, isFalse);
      final file = await backupBytes(b.repo, key);
      await expectLater(restoreBackupBytes(a.repo, file, key), throwsStateError);
      expect(a.repo.accounts(), hasLength(1));
    }, timeout: _t);

    test('a restored backup reaches another device with the accounts', () async {
      final a = device('a');
      await a.repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 321, openingDate: '2026-09-30');
      final file = await backupBytes(a.repo, key);
      final c = device('c');
      await restoreBackupBytes(c.repo, file, key);
      final d = device('d');
      await syncAll([c, d]);
      expect(d.repo.accounts().single.opening, 321);
    }, timeout: _t);
  });

  group('schema 7 -> 9', () {
    final dir = Directory('test/fixtures/old_builds');
    final fixKey = VaultKey(List<int>.generate(32, (i) => i + 1));

    String copy(String file) {
      final d = Directory.systemTemp.createTempSync('bw-n2-old-');
      addTearDown(() => d.deleteSync(recursive: true));
      final out = '${d.path}/$file';
      File('${dir.path}/$file').copySync(out);
      return out;
    }

    for (final keyed in [false, true]) {
      final file = 'schema7_${keyed ? 'keyed' : 'plain'}.db';
      test('$file opens at the current schema (9+) with an empty accounts table, keeps its rows, and accepts accounts', () async {
        final path = copy(file);
        final r = WalletRepo.open(path, dbKey: keyed ? await localDbKey(fixKey) : null);
        addTearDown(r.close);
        expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(9));
        expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '${WalletRepo.schemaVersion}');
        expect(r.accounts(includeDeleted: true), isEmpty);
        expect(r.transactions(includeHidden: true), isNotEmpty);
        expect(r.settings().salary, 150000);
        final id = await r.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 100, openingDate: '2026-01-01');
        expect(r.accounts().single.id, id);
      }, timeout: _t);
    }

    test('the migration writes no account ops and a second open changes nothing', () async {
      final path = copy('schema7_plain.db');
      final first = WalletRepo.open(path);
      final ops = first.pendingOps().where((o) => o.$2.entity == 'account');
      expect(ops, isEmpty);
      final total = first.pendingOps().length;
      first.close();
      final again = WalletRepo.open(path);
      addTearDown(again.close);
      expect(again.pendingOps().length, total);
      expect(again.accounts(includeDeleted: true), isEmpty);
    }, timeout: _t);

    test('the schema 7 backup restores into a schema 9 wallet with no accounts', () async {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      await restoreBackupBytes(r, File('${dir.path}/schema7.bwb').readAsBytesSync(), fixKey);
      expect(r.accounts(includeDeleted: true), isEmpty);
      expect(r.transactions(includeHidden: true), isNotEmpty);
    }, timeout: _t);

    test('an upgraded wallet syncs its accounts to a new device', () async {
      final path = copy('schema7_plain.db');
      final old = WalletRepo.open(path, now: () => now);
      addTearDown(old.close);
      final oldDev = Device('old', null, key, () => now)..repo = old;
      devices.add(oldDev);
      final fresh = device('fresh');
      await old.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 555, openingDate: '2026-01-01');
      await syncAll([oldDev, fresh]);
      expect(fresh.repo.accounts().single.opening, 555);
      expect(fresh.repo.transactions(includeHidden: true).length, old.transactions(includeHidden: true).length);
    }, timeout: _t);
  });
}
