// M5 backups, core half: snapshot ops, restore into an empty wallet, the resend to other devices. All data SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = 1767225600000;
  final devices = <Device>[];
  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  Future<void> syncAll(List<Device> ds) async {
    for (var round = 0; round < 2; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        await d.run();
        d.upload(net);
      }
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-backup-core-');
    key = VaultKey.generate();
    net = Net();
    now = 1767225600000;
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  /// [json] (already a string) sealed with the wallet key, like a backup file.
  Future<List<int>> sealed(String json) async => seal(utf8.encode(json), key);

  group('snapshotOps', () {
    test('one op per row and clock, fields grouped by the write that set them; defaults without a clock are left out', () {
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      r.importBatch(january);
      final id = january.transactions[3].id;
      now += 1000;
      r.setCategory(id, 'Groceries');
      final ops = r.snapshotOps().where((o) => o.entity == 'tx' && o.id == id).toList();
      expect(ops, hasLength(2), reason: 'the import and the category edit have different clocks');
      expect(Hlc.compareStrings(ops[0].hlc, ops[1].hlc), lessThan(0), reason: 'ordered by clock');
      expect(ops[0].fields.keys.toSet(), {'source', 'date', 'amount', 'currency', 'bank_type', 'description', 'manual'});
      expect(ops[1].fields, {'category': 'Groceries'});
      expect(ops.any((o) => o.fields.containsKey('deleted')), isFalse, reason: 'never written: the column default');
      expect(r.snapshotOps().where((o) => o.entity == 'tx').length, january.transactions.length + 1);
    });

    test('an empty wallet gives no ops; device-local values are not included', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.setLocalValue('syncFolder', 'somewhere');
      expect(r.snapshotOps(), isEmpty);
    });

    test('ordered by entity, id, clock and deterministic', () {
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      r.importBatch(january);
      r.saveGoal(name: 'Synthetic', target: 100, saved: 0, monthly: 0);
      r.updateSettings({'salary': 1});
      final a = r.snapshotOps(), b = r.snapshotOps();
      expect([for (final o in a) o.toJson()], [for (final o in b) o.toJson()]);
      expect({for (final o in a) o.entity}.toList(), ['tx', 'goal', 'setting'], reason: 'entities in the sync map order');
      for (final entity in ['tx', 'goal', 'setting']) {
        final keys = [
          for (final o in a)
            if (o.entity == entity) '${o.id}\u0000${o.hlc}'
        ];
        expect(keys, [...keys]..sort(), reason: 'ordered by id, then clock within $entity');
      }
    });
  });

  group('backupBytes', () {
    test('payload is {"v":1,"ops":[...]} sealed with the wallet key', () async {
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      r.importBatch(january);
      final clear = await unseal(await backupBytes(r, key), key);
      final json = jsonDecode(utf8.decode(clear)) as Map;
      expect(json['v'], 1);
      expect((json['ops'] as List).length, january.transactions.length);
      final op = Op.fromJson(Map<String, Object?>.from((json['ops'] as List).first as Map));
      expect(op.entity, 'tx');
      expect(op.fields['amount'], isA<int>());
    });

    test('backupFileName: today must be a date (it becomes the file name)', () {
      expect(backupFileName('2026-03-05'), 'bw-backup-2026-03-05.bwb');
      expect(() => backupFileName('../x'), throwsA(isA<ArgumentError>()));
      expect(() => backupFileName('2026-3-5'), throwsA(isA<ArgumentError>()));
    });
  });

  group('restoreBackup', () {
    test('tables and clocks are identical after the round trip (deleted rows, settings, rules, bills included)', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000, 'rent': 40000, 'reviewDay': 3});
      a.repo.setMerchantRule('lidl', 'Groceries');
      final gid = a.repo.saveGoal(name: 'Synthetic', target: 90000, saved: 1000, monthly: 5000);
      a.repo.addWish('Synthetic thing', 12999);
      final mid = a.repo.addTransaction(date: '2026-01-21', amount: 1250, category: 'Eating out', note: 'lunch');
      await syncAll([a, b]);
      now += 60000;
      b.repo.addGoalContribution(gid, 2500, date: '2026-01-22');
      b.repo.setCategory(january.transactions[2].id, 'Shopping');
      b.repo.decideWish(b.repo.wishlist().single.id, 'skipped');
      await syncAll([a, b]);
      now += 60000;
      a.repo.deleteTransaction(mid);
      a.repo.deleteGoal(gid);
      a.repo.db.execute('SELECT 1'); // keep the clock as is
      await syncAll([a, b]);
      expect(dump(a.repo), dump(b.repo), reason: 'precondition');

      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      final n = await restoreBackupBytes(fresh, file, key);
      expect(n, a.repo.snapshotOps().length);
      expect(dump(fresh), dump(a.repo), reason: 'every value and every field clock');
      expect(fresh.transactions(includeHidden: true).where((t) => t.deleted).map((t) => t.id), [mid]);
      expect(fresh.goals(), isEmpty, reason: 'the deleted goal stays deleted');
      expect(fresh.settings().reviewDay, 3);
      expect(fresh.isEmpty, isFalse);
    });

    test('restored ops are queued for the next sync; other devices apply them without any change', () async {
      final a = device('a');
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      await syncAll([a]);
      final file = await backupBytes(a.repo, key);

      final c = device('c');
      final n = await restoreBackupBytes(c.repo, file, key);
      expect(c.repo.pendingOps(), hasLength(n), reason: 'the snapshot goes out like local writes');
      c.deliver(net, Random(1));
      final sent = await c.run();
      expect(sent.sent, n);
      expect(sent.received, 0, reason: 'a already held every field at the same clock');
      c.upload(net);
      a.deliver(net, Random(2));
      final got = await a.run();
      expect(got.filesRead, 1);
      expect(got.received, 0, reason: 'nothing newer in the restored ops');
      expect(dump(a.repo), dump(c.repo));
      expect(bookkeeping(c.repo)['outbox'], 0);
    });

    test('a wallet with only a merchant rule is not empty', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      expect(r.isEmpty, isTrue);
      r.setMerchantRule('synthetic_shop', 'Groceries');
      expect(r.isEmpty, isFalse);
    });

    test('BackupException reasons: newerVersion, damaged; messages carry no content', () async {
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      Future<BackupException> refused(List<int> bytes) async {
        try {
          await restoreBackupBytes(fresh, bytes, key);
        } on BackupException catch (e) {
          expect(e.toString(), isNot(contains('ops')));
          return e;
        }
        fail('restored');
      }

      expect((await refused(await sealed('{"v":2,"ops":[]}'))).reason, BackupFailure.newerVersion);
      expect((await refused(await sealed('{"v":1}'))).reason, BackupFailure.damaged);
      expect((await refused(await sealed('{"ops":[]}'))).reason, BackupFailure.damaged);
      expect((await refused(await sealed('[]'))).reason, BackupFailure.damaged);
      expect(
          (await refused(await sealed('{"v":1,"ops":[{"e":"tx","id":"x","f":{"amount":1},"h":"junk"}]}'))).reason, BackupFailure.damaged);
      expect((await refused(await sealed('{"v":1,"ops":[1]}'))).reason, BackupFailure.damaged);
      expect((await refused(await sealed('{"v":"1","ops":[]}'))).reason, BackupFailure.damaged);
      expect(fresh.isEmpty, isTrue);
      expect(fresh.pendingOps(), isEmpty);
    });

    test('ops of an entity this build does not know are skipped, the rest restores', () async {
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      const h = '001767225600000:00000:synthetic';
      final file = await sealed('{"v":1,"ops":[{"e":"future","id":"f","f":{"x":1},"h":"$h"},'
          '{"e":"goal","id":"g","f":{"name":"Synthetic","target":100,"saved":0,"monthly":0,"sort":1,"deleted":0},"h":"$h"}]}');
      expect(await restoreBackupBytes(fresh, file, key), 2);
      expect(fresh.goals().single.name, 'Synthetic');
    });

    test('logs carry counts and reasons only', () async {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(() {
        sub.cancel();
        Logger.root.level = was;
      });
      final a = device('a');
      a.repo.importBatch(january);
      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, file, key);
      final empty = WalletRepo.inMemory();
      addTearDown(empty.close);
      await expectLater(restoreBackupBytes(empty, await sealed('{"v":2,"ops":[]}'), key), throwsA(isA<BackupException>()));
      final text = lines.join('\n');
      expect(text, contains('backup.write {"ms":'));
      expect(text, contains('"ops":${january.transactions.length}'));
      expect(text, contains('backup.restore {"ms":'));
      expect(text, contains('backup.restore.failed'));
      expect(text, contains('"reason":"newerVersion"'));
      expect(text, isNot(contains(tmp.path)));
      for (final t in january.transactions) {
        expect(text, isNot(contains(t.description)));
        expect(text, isNot(contains('${t.amountMinor}')));
      }
    });
  });
}
