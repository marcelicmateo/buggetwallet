// Stage I (IC): WalletRepo.undeleteTransaction(id) / undeleteGoal(id) write `deleted: 0` through the owner write path
// (synced). A goal's contributions were hidden, not deleted, so they come back. A matched hand-added expense keeps its
// match. Unknown id = ArgumentError; a live row = no-op. All data is SYNTHETIC.
//
// The API does not exist on v2 yet: the whole file is skipped until the lead lifts the line below at merge.
@Skip('BUG: I4 - WalletRepo.undeleteTransaction / undeleteGoal')
library;

// ignore_for_file: undefined_method
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

void main() {
  late int now;
  late WalletRepo repo;

  setUp(() {
    now = 1791590400000; // 2026-10-10
    repo = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => repo.close());

  group('undeleteTransaction', () {
    test('a deleted bank row is live again, as it was (category, note, amount)', () {
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-10-05', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL ZAGREB')]));
      final id = repo.transactions().single.id;
      repo.setCategory(id, 'Eating out');
      now += 1000;
      repo.deleteTransaction(id);
      expect(repo.transactions(), isEmpty);
      now += 1000;
      repo.undeleteTransaction(id);
      final t = repo.transactions().single;
      expect((t.id, t.amount, t.date, t.deleted), (id, -2340, '2026-10-05', false));
      expect(repo.transaction(id)!.deleted, isFalse);
    }, timeout: _t);

    test('the restore is a synced write: a pending op with deleted 0', () {
      final id = repo.addTransaction(date: '2026-10-05', amount: 1200, category: 'Groceries');
      repo.deleteTransaction(id);
      final before = repo.pendingOps().length;
      repo.undeleteTransaction(id);
      final ops = repo.pendingOps().toList();
      expect(ops.length, greaterThan(before));
      expect(ops.last.$2.fields['deleted'], 0);
    }, timeout: _t);

    test('a matched hand-added expense keeps its match on undo', () {
      final cash = repo.addTransaction(date: '2026-10-05', amount: 2500, category: 'Groceries');
      final bank = n('2026-10-06', -2500, 'POS plaćanje', 'PBZ POS SYNTHETIC SHOP ZAGREB');
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [bank]));
      expect(repo.transaction(cash)!.matchedTo, bank.id, reason: 'setup: the import matched the cash entry');
      repo.deleteTransaction(cash);
      now += 1000;
      repo.undeleteTransaction(cash);
      final t = repo.transaction(cash)!;
      expect((t.deleted, t.matchedTo), (false, bank.id));
      // still counted once: the bank row is live, the entry hidden
      expect([for (final x in repo.transactions()) x.id], [bank.id]);
    }, timeout: _t);

    test('unknown id: ArgumentError, nothing written', () {
      final before = repo.pendingOps().length;
      expect(() => repo.undeleteTransaction('nope'), throwsArgumentError);
      expect(repo.pendingOps().length, before);
    }, timeout: _t);

    test('a live row: no-op, no new op', () {
      final id = repo.addTransaction(date: '2026-10-05', amount: 1200, category: 'Groceries');
      final before = repo.pendingOps().length;
      repo.undeleteTransaction(id);
      expect(repo.pendingOps().length, before);
      expect(repo.transactions().single.id, id);
    }, timeout: _t);
  });

  group('undeleteGoal', () {
    test('the goal and its contributions come back, the saved total as before', () {
      final g = repo.saveGoal(name: 'Bike', target: 100000, saved: 10000, monthly: 5000);
      repo.addGoalContribution(g, 2500, date: '2026-10-02');
      repo.addGoalContribution(g, 1500, date: '2026-10-03');
      final total = repo.goals().single.saved;
      expect(total, 14000);
      repo.deleteGoal(g);
      expect(repo.goals(), isEmpty);
      expect(repo.goalContributions(g), isEmpty);
      now += 1000;
      repo.undeleteGoal(g);
      final back = repo.goals().single;
      expect((back.id, back.name, back.target, back.monthly, back.saved), (g, 'Bike', 100000, 5000, total));
      expect(repo.goalContributions(g).map((c) => c.amount), [2500, 1500]);
    }, timeout: _t);

    test('unknown id: ArgumentError; a live goal: no-op', () {
      expect(() => repo.undeleteGoal('nope'), throwsArgumentError);
      final g = repo.saveGoal(name: 'Trip', target: 50000, saved: 0, monthly: 0);
      final before = repo.pendingOps().length;
      repo.undeleteGoal(g);
      expect(repo.pendingOps().length, before);
      expect(repo.goals().single.id, g);
    }, timeout: _t);
  });

  group('two devices', () {
    late VaultKey key;
    late Net net;
    var clock = 1791590400000;
    setUp(() {
      key = VaultKey.generate();
      net = Net();
      clock = 1791590400000;
    });

    Future<void> settle(List<Device> ds) async {
      for (var i = 0; i < 3; i++) {
        for (final d in ds) {
          clock += 1000;
          d.deliver(net, Random(1));
          await d.run();
        }
      }
    }

    test('a delete undone on A reaches B: both show the row live', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final id = a.repo.addTransaction(date: '2026-10-05', amount: 1200, category: 'Groceries');
      await settle([a, b]);
      a.repo.deleteTransaction(id);
      await settle([a, b]);
      expect(b.repo.transactions(), isEmpty);
      clock += 1000;
      a.repo.undeleteTransaction(id);
      await settle([a, b]);
      expect(a.repo.transactions().map((t) => t.id), [id]);
      expect(b.repo.transactions().map((t) => t.id), [id]);
    }, timeout: _t);

    test('delete on A, undo on B after it synced, concurrent edit on A: all converge', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final g = a.repo.saveGoal(name: 'Bike', target: 100000, saved: 0, monthly: 0);
      a.repo.addGoalContribution(g, 4000, date: '2026-10-02');
      await settle([a, b]);
      clock += 1000;
      a.repo.deleteGoal(g);
      await settle([a, b]);
      expect(b.repo.goals(), isEmpty);
      clock += 1000;
      b.repo.undeleteGoal(g);
      await settle([a, b]);
      for (final d in [a, b]) {
        expect(d.repo.goals().single.saved, 4000, reason: d.name);
        expect(d.repo.goalContributions(g).length, 1, reason: d.name);
      }
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
    }, timeout: _t);

    test('a later delete on the other device beats an earlier undo (last writer wins), both converge', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final id = a.repo.addTransaction(date: '2026-10-05', amount: 1200, category: 'Groceries');
      await settle([a, b]);
      a.repo.deleteTransaction(id);
      await settle([a, b]);
      clock += 1000;
      a.repo.undeleteTransaction(id);
      clock += 1000;
      b.repo.deleteTransaction(id); // after A's undo in time, but before it has seen it
      await settle([a, b]);
      expect(a.repo.transactions().map((t) => t.id), b.repo.transactions().map((t) => t.id));
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
    }, timeout: _t);
  });
}
