// Spec tests for M5 backups (DESIGN_DECISIONS §4.7), written from the spec only. All data is SYNTHETIC.
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

  /// What a user sees, independent of clocks and bookkeeping.
  Map<String, Object?> view(WalletRepo r) {
    final txs = r.transactions(includeHidden: true);
    return {
      'txs': [for (final t in txs) '${t.id}|${t.date}|${t.amount}|${t.category}|${t.note}|${t.description}|${t.deleted}'],
      'total': txs.where((t) => t.live).fold<int>(0, (s, t) => s + t.amount),
      'goals': [for (final g in r.goals()) '${g.id}|${g.name}|${g.target}|${g.saved}|${g.monthly}'],
      'contribs': {
        for (final g in r.goals()) g.id: [for (final c in r.goalContributions(g.id)) '${c.goalId}|${c.amount}|${c.date}']..sort(),
      },
      'wish': [for (final w in r.wishlist()) '${w.id}|${w.name}|${w.price}|${w.status}'],
      'rules': r.merchantRules(),
      'settings': '${r.settings().salary}|${r.settings().rent}|${r.settings().paydayDay}|${r.settings().categoryBudgets}',
    };
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-backup-');
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

  Future<(Device, String)> richWallet() async {
    final a = device('a'), b = device('b');
    a.repo.importBatch(january);
    a.repo.updateSettings({
      'salary': 150000,
      'rent': 40000,
      'paydayDay': 15,
      'categoryBudgets': const {'Groceries': 30000},
    });
    final gid = a.repo.saveGoal(name: 'Synthetic trip', target: 90000, saved: 1000, monthly: 5000);
    a.repo.addWish('Synthetic headphones', 12999);
    a.repo.setMerchantRule('lidl', 'Groceries');
    final mid = a.repo.addManual(date: '2026-01-21', amount: 1250, category: 'Eating out', note: 'lunch');
    await syncAll([a, b]);
    b.repo.addGoalContribution(gid, 2500, date: '2026-01-22');
    a.repo.addGoalContribution(gid, 700, date: '2026-01-23');
    b.repo.addManual(date: '2026-01-24', amount: 999, category: 'Shopping', note: 'gift');
    await syncAll([a, b]);
    a.repo.deleteTransaction(mid);
    await syncAll([a, b]);
    expect(view(a.repo), view(b.repo), reason: 'precondition: both devices converged');
    return (a, tmp.path);
  }

  group('writeBackup / listBackups', () {
    test('file name, location, and the file is not plain text', () async {
      final a = device('a');
      a.repo.importBatch(january);
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-03-05');
      expect(name, 'bw-backup-2026-03-05.bwb');
      final f = File('${tmp.path}/budget-wallet/backups/$name');
      expect(f.existsSync(), isTrue);
      final bytes = f.readAsBytesSync();
      expect(bytes, isNotEmpty);
      final text = String.fromCharCodes(bytes);
      expect(text.contains('Neto'), isFalse, reason: 'sealed with the wallet key');
      expect(text.contains('LIDL'), isFalse);
    });

    test('same-day backup overwrites; a different day adds a file', () async {
      final a = device('a');
      a.repo.importBatch(january);
      await writeBackup(a.repo, tmp.path, key, today: '2026-03-05');
      a.repo.addManual(date: '2026-03-05', amount: 100, category: 'Shopping');
      await writeBackup(a.repo, tmp.path, key, today: '2026-03-05');
      expect(await listBackups(tmp.path), hasLength(1));
      final fresh = WalletRepo.inMemory();
      final file = '${tmp.path}/budget-wallet/backups/bw-backup-2026-03-05.bwb';
      await restoreBackup(fresh, file, key);
      expect(view(fresh), view(a.repo), reason: 'the second write won');
      fresh.close();
      await writeBackup(a.repo, tmp.path, key, today: '2026-03-06');
      expect(await listBackups(tmp.path), hasLength(2));
    });

    test('list: newest first, with name and date; empty when the folder is missing', () async {
      expect(await listBackups('${tmp.path}/nope'), isEmpty);
      expect(await listBackups(tmp.path), isEmpty);
      final a = device('a');
      for (final d in ['2026-01-31', '2026-03-05', '2025-12-31', '2026-02-01']) {
        await writeBackup(a.repo, tmp.path, key, today: d);
      }
      File('${tmp.path}/budget-wallet/backups/notes.txt').writeAsStringSync('not a backup');
      final l = await listBackups(tmp.path);
      expect([for (final b in l) b.date], ['2026-03-05', '2026-02-01', '2026-01-31', '2025-12-31']);
      expect([for (final b in l) b.name], [
        'bw-backup-2026-03-05.bwb',
        'bw-backup-2026-02-01.bwb',
        'bw-backup-2026-01-31.bwb',
        'bw-backup-2025-12-31.bwb',
      ]);
    });

    test('an empty wallet can be backed up and restored (nothing to see)', () async {
      final a = device('a');
      expect(a.repo.isEmpty, isTrue);
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-03-05');
      final fresh = WalletRepo.inMemory();
      final n = await restoreBackup(fresh, '${tmp.path}/budget-wallet/backups/$name', key);
      expect(n, 0);
      expect(fresh.isEmpty, isTrue);
      fresh.close();
    });
  });

  group('restoreBackup', () {
    test('round trip after two devices synced and a row was deleted: totals, categories, settings, contributions equal', () async {
      final (a, _) = await richWallet();
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-02-01');
      final fresh = WalletRepo.inMemory();
      expect(fresh.isEmpty, isTrue);
      final n = await restoreBackup(fresh, '${tmp.path}/budget-wallet/backups/$name', key);
      expect(n, greaterThan(0));
      expect(fresh.isEmpty, isFalse);
      expect(view(fresh), view(a.repo));
      final g = fresh.goals().single;
      expect(g.saved, 1000 + 2500 + 700, reason: 'base plus both devices contributions');
      expect(fresh.settings().categoryBudgets, {'Groceries': 30000});
      expect(fresh.merchantRules()['lidl'], 'Groceries');
      final cat = fresh.categorizer();
      expect([for (final t in fresh.transactions()) cat.categoryOf(t)], [for (final t in a.repo.transactions()) a.repo.categorizer().categoryOf(t)]);
      expect(fresh.transactions().any((t) => t.note == 'lunch'), isFalse, reason: 'the deleted row stays deleted');
      fresh.close();
    });

    test('restored wallet keeps working: a later sync does not duplicate or lose anything', () async {
      final (a, _) = await richWallet();
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-02-01');
      final c = device('c');
      await restoreBackup(c.repo, '${tmp.path}/budget-wallet/backups/$name', key);
      await syncAll([a, c]);
      await syncAll([a, c]);
      expect(view(c.repo), view(a.repo));
    });

    test('refused on a wallet with data: StateError and the wallet is unchanged', () async {
      final (a, _) = await richWallet();
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-02-01');
      final other = WalletRepo.inMemory();
      other.addManual(date: '2026-01-02', amount: 500, category: 'Groceries', note: 'mine');
      final before = dump(other);
      final pending = other.pendingOps().length;
      await expectLater(restoreBackup(other, '${tmp.path}/budget-wallet/backups/$name', key), throwsA(isA<StateError>()));
      expect(dump(other), before);
      expect(other.pendingOps(), hasLength(pending));
      other.close();
      // Also refused on the source wallet itself (restoring over yourself is not a merge path).
      final b = dump(a.repo);
      await expectLater(restoreBackup(a.repo, '${tmp.path}/budget-wallet/backups/$name', key), throwsA(isA<StateError>()));
      expect(dump(a.repo), b);
    });

    test('a wallet holding only a setting or only a goal is not empty', () async {
      final a = device('a');
      a.repo.importBatch(january);
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-02-01');
      final s = WalletRepo.inMemory()..updateSettings({'salary': 100});
      expect(s.isEmpty, isFalse);
      await expectLater(restoreBackup(s, '${tmp.path}/budget-wallet/backups/$name', key), throwsA(isA<StateError>()));
      final g = WalletRepo.inMemory()..saveGoal(name: 'x', target: 1, saved: 0, monthly: 0);
      expect(g.isEmpty, isFalse);
      s.close();
      g.close();
    });

    test('wrong key: VaultException, wallet stays empty', () async {
      final a = device('a');
      a.repo.importBatch(january);
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-02-01');
      final fresh = WalletRepo.inMemory();
      await expectLater(
          restoreBackup(fresh, '${tmp.path}/budget-wallet/backups/$name', VaultKey.generate()), throwsA(isA<VaultException>()));
      expect(fresh.isEmpty, isTrue);
      fresh.close();
    });

    test('truncated or garbled file never half-restores', () async {
      final a = device('a');
      a.repo.importBatch(january);
      final name = await writeBackup(a.repo, tmp.path, key, today: '2026-02-01');
      final path = '${tmp.path}/budget-wallet/backups/$name';
      final bytes = File(path).readAsBytesSync();
      for (final cut in [0, 5, bytes.length ~/ 2, bytes.length - 1]) {
        final f = File('${tmp.path}/cut$cut.bwb')..writeAsBytesSync(bytes.sublist(0, cut));
        final fresh = WalletRepo.inMemory();
        await expectLater(restoreBackup(fresh, f.path, key), throwsA(anyOf(isA<VaultException>(), isA<BackupException>())), reason: 'cut at $cut');
        expect(fresh.isEmpty, isTrue, reason: 'cut at $cut');
        fresh.close();
      }
      await expectLater(restoreBackup(WalletRepo.inMemory(), '${tmp.path}/missing.bwb', key), throwsA(isA<Exception>()));
    });

    test('a sealed non-backup payload is a BackupException', () async {
      final junk = await seal('{"not":"a list of ops"}'.codeUnits, key);
      final f = File('${tmp.path}/junk.bwb')..writeAsBytesSync(junk);
      final fresh = WalletRepo.inMemory();
      await expectLater(restoreBackup(fresh, f.path, key), throwsA(isA<BackupException>()));
      final junk2 = await seal('not json at all'.codeUnits, key);
      final f2 = File('${tmp.path}/junk2.bwb')..writeAsBytesSync(junk2);
      await expectLater(restoreBackup(fresh, f2.path, key), throwsA(isA<BackupException>()));
      expect(fresh.isEmpty, isTrue);
      fresh.close();
    });
  });
}
