// Q9 core: the recent changes list read from the clocks table. All data SYNTHETIC (well-known chains, made-up amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

/// 2026-01-01T00:00:00Z.
const _t0 = 1767225600000;

void main() {
  late WalletRepo repo;
  var now = _t0;

  /// Moves the repo clock on by a second, so each write has its own HLC millis.
  void tick() => now += 1000;

  setUp(() {
    now = _t0;
    repo = WalletRepo.inMemory(now: () => now, deviceId: 'thisdevice');
  });
  tearDown(() => repo.close());

  test('newest change first, one entry per row, with the fields of its newest clock', () {
    repo.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-02', -2340, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB')]));
    final txId = repo.transactions().single.id;
    tick();
    final goal = repo.saveGoal(name: 'Synthetic bike', target: 50000, saved: 0, monthly: 0);
    tick();
    repo.setCategory(txId, 'Eating out');

    final list = repo.recentChanges();
    expect([for (final c in list) c.entity], ['tx', 'goal']);
    final tx = list.first;
    expect(tx.id, txId);
    expect(tx.fields, ['category']);
    expect(tx.label, 'KONZUM 0000 ZAGREB · 2026-01-02');
    expect(tx.millis, _t0 + 2000);
    expect(tx.thisDevice, isTrue);
    expect(tx.node, 'thisdevice');
    expect(tx.deleted, isFalse);
    expect(list[1].id, goal);
    expect(list[1].label, 'Synthetic bike');
    expect(list[1].fields, containsAll(['name', 'target']));
  });

  test('a deleted row shows as deleted', () {
    final id = repo.addTransaction(date: '2026-01-03', amount: -500, category: 'Eating out', note: 'Synthetic coffee');
    tick();
    repo.deleteTransaction(id);
    final c = repo.recentChanges().firstWhere((c) => c.id == id);
    expect(c.deleted, isTrue);
    expect(c.fields, contains('deleted'));
    expect(c.label, 'Synthetic coffee · 2026-01-03');
  });

  test('a change from another device: its node, not this device', () {
    repo.applyRemote([
      Op('wish', 'w1', {'name': 'Synthetic lamp', 'price': 3000, 'added': _t0, 'status': 'waiting', 'deleted': 0},
          const Hlc(_t0 - 5000, 0, 'otherdevice').toString()),
    ]);
    tick();
    repo.updateSettings({'paydayDay': 10});
    final list = repo.recentChanges();
    expect(list.first.entity, 'setting');
    expect(list.first.label, 'paydayDay');
    final w = list.firstWhere((c) => c.entity == 'wish');
    expect(w.thisDevice, isFalse);
    expect(w.node, 'otherdevice');
    expect(w.millis, _t0 - 5000);
    expect(w.label, 'Synthetic lamp');
  });

  test('labels: payee rule = its key, setting = its key, never a value', () {
    repo.setMerchantRule('cinestar_zagreb', 'Eating out');
    tick();
    repo.updateSettings({'salary': 123456});
    final list = repo.recentChanges();
    expect(list.firstWhere((c) => c.entity == 'rule').label, 'cinestar_zagreb');
    final s = list.firstWhere((c) => c.entity == 'setting');
    expect(s.label, 'salary');
    expect(s.label, isNot(contains('123456')));
  });

  test('an entity this build does not know, or a row not stored, gets a generic label; a bad clock is skipped', () {
    repo.db.execute(
        "INSERT INTO clocks(entity, id, field, hlc) VALUES('future', 'f1', 'x', ?)", [const Hlc(_t0, 0, 'otherdevice').toString()]);
    repo.db.execute(
        "INSERT INTO clocks(entity, id, field, hlc) VALUES('goal', 'missing', 'name', ?)", [const Hlc(_t0, 1, 'otherdevice').toString()]);
    repo.db.execute("INSERT INTO clocks(entity, id, field, hlc) VALUES('goal', 'bad', 'name', 'not-a-clock')");
    final list = repo.recentChanges();
    expect([for (final c in list) c.id], ['missing', 'f1']);
    expect(list[0].label, 'goal');
    expect(list[1].label, 'future');
    expect(list[1].deleted, isFalse);
  });

  test('limit: the newest rows only; 0 or less = none', () {
    for (var i = 0; i < 5; i++) {
      repo.saveGoal(name: 'Goal $i', target: 1000, saved: 0, monthly: 0);
      tick();
    }
    expect([for (final c in repo.recentChanges(limit: 2)) c.label], ['Goal 4', 'Goal 3']);
    expect(repo.recentChanges(limit: 0), isEmpty);
    expect(repo.recentChanges(limit: -1), isEmpty);
    final fresh = WalletRepo.inMemory(now: () => now);
    addTearDown(fresh.close);
    expect(fresh.recentChanges(), isEmpty);
  });

  test('split and tag link are labelled by their payment; contributions by their goal', () {
    repo.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-02', -3000, 'POS plaćanje', 'POS SPAR 0000 ZAGREB')]));
    final txId = repo.transactions().single.id;
    final g = repo.saveGoal(name: 'Synthetic trip', target: 50000, saved: 0, monthly: 0);
    tick();
    repo.addGoalContribution(g, 1000, date: '2026-01-04');
    tick();
    repo.setSplit(txId, const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Health & care')]);
    final list = repo.recentChanges();
    expect(list.first.entity, 'split');
    expect(list.first.label, 'SPAR 0000 ZAGREB · 2026-01-02');
    expect(list.firstWhere((c) => c.entity == 'goal_contrib').label, 'Synthetic trip');
  });

  test('read-only, and logs counts only', () {
    repo.saveGoal(name: 'Secret synthetic name', target: 1000, saved: 0, monthly: 0);
    final before = repo.clockStats();
    final lines = <String>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    try {
      expect(repo.recentChanges(), hasLength(1));
    } finally {
      sub.cancel();
      Logger.root.level = was;
    }
    expect(repo.clockStats(), before);
    expect(lines.join('\n'), isNot(contains('Secret')));
    expect(lines.join('\n'), isNot(contains('thisdevice')));
    expect(lines.where((l) => l.contains('repo.recentChanges')), hasLength(1));
  });
}
