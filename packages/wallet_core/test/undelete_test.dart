// Stage I (IC): undo of a delete — WalletRepo.undeleteTransaction / undeleteGoal, against DESIGN_DECISIONS §4.10.
// SYNTHETIC data only: made-up payees, descriptions and amounts.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const today = '2026-03-01';
final noon = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;

NormalizedBill slip({String ext = 'jir:undo-slip', String? due = '2026-03-10', int total = 4599, String payee = 'Synth Water'}) =>
    NormalizedBill(source: BillSource.receiptQr, externalId: ext, date: '2026-02-27', dueDate: due, total: total, payee: payee);

void main() {
  group('one device', () {
    late WalletRepo r;
    var now = noon;
    setUp(() {
      now = noon;
      r = WalletRepo.inMemory(now: () => now);
    });
    tearDown(() => r.close());

    test('an unknown id throws ArgumentError; a live row or goal is a no-op (nothing written)', () {
      expect(() => r.undeleteTransaction('no-such-tx'), throwsArgumentError);
      expect(() => r.undeleteGoal('no-such-goal'), throwsArgumentError);
      final m = r.addTransaction(date: '2026-02-20', amount: 1200, category: 'Groceries');
      final g = r.saveGoal(name: 'Synthetic trip', target: 50000, saved: 0, monthly: 1000);
      final before = r.pendingOps().length;
      r.undeleteTransaction(m);
      r.undeleteGoal(g);
      expect(r.pendingOps().length, before);
      expect(r.transaction(m)!.deleted, isFalse);
    });

    test('a deleted row comes back as it was, and counts again', () {
      final m = r.addTransaction(date: '2026-02-20', amount: 1200, category: 'Groceries', note: 'synthetic note');
      final row = r.transaction(m)!;
      r.deleteTransaction(m);
      expect(r.transactions().map((t) => t.id), isNot(contains(m)));
      now += 1000;
      r.undeleteTransaction(m);
      final back = r.transaction(m)!;
      expect((back.deleted, back.amount, back.date, back.category, back.note), (false, row.amount, row.date, row.category, row.note));
      expect(r.transactions().map((t) => t.id), contains(m));
      final ops = [
        for (final (_, op) in r.pendingOps())
          if (op.id == m) op
      ];
      expect(ops.last.fields, {'deleted': 0}, reason: 'one synced owner write of deleted: 0');
    });

    test('a matched hand-added expense keeps its match on undo (the bank row still counts once)', () {
      final m = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic');
      now += 1000;
      expect(r.importBatch(january).matched, 1);
      final bank = r.transaction(m)!.matchedTo!;
      r.deleteTransaction(m);
      expect(r.transaction(m)!.matchedTo, bank);
      r.undeleteTransaction(m);
      expect(r.transaction(m)!.matchedTo, bank);
      expect(r.transactions().where((t) => t.amount == -2340 && t.live).map((t) => t.id), [bank]);
    });

    test('undoing a deleted bank row re-runs matching: the reopened entry is replaced by it again', () {
      final m = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out');
      now += 1000;
      r.importBatch(january);
      final bank = r.transaction(m)!.matchedTo!;
      r.deleteTransaction(bank);
      expect(r.transaction(m)!.matchedTo, isNull, reason: 'the entry counts again while its bank row is deleted');
      r.undeleteTransaction(bank);
      expect(r.transaction(bank)!.deleted, isFalse);
      expect(r.transaction(m)!.matchedTo, bank);
      expect(r.transactions().where((t) => t.amount == -2340 && t.live).map((t) => t.id), [bank]);
    });

    test('a goal comes back with its contributions', () {
      final g = r.saveGoal(name: 'Synthetic bike', target: 90000, saved: 10000, monthly: 2000);
      r.addGoalContribution(g, 2500, date: '2026-02-20');
      r.deleteGoal(g);
      expect(r.goals(), isEmpty);
      expect(r.goalContributions(g), isEmpty);
      now += 1000;
      r.undeleteGoal(g);
      expect(r.goals().single.saved, 12500);
      expect(r.goalContributions(g).map((c) => c.amount), [2500]);
    });
  });

  group('a cash expense made from a bill', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => noon));
    tearDown(() => repo.close());

    PeriodBudget period() => computePeriod([for (final t in repo.transactions()) repo.categorizer().categorize(t)],
        const WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-02-15'), const [], today,
        bills: repo.recurringBills(), planned: repo.plannedCosts());

    test('deleted then undone: the bill is paid again, not reserved, and the expense counts once', () {
      final (id, _) = repo.importBill(slip());
      final txId = repo.addExpenseFromBill(id, category: 'Bills & one-offs');
      final paid = period();
      expect((paid.reservedPlanned, paid.spent), (0, 4599));
      repo.deleteTransaction(txId);
      expect(repo.bill(id)!.linkedTx, isNull);
      final open = period();
      expect((open.reservedPlanned, open.spent), (4599, 0), reason: 'deleted: the bill reserves again');
      repo.undeleteTransaction(txId);
      expect(repo.bill(id)!.linkedTx, txId);
      final p = repo.plannedCosts(includeClosed: true).firstWhere((p) => p.id == WalletRepo.billPlannedId(id));
      expect(p.isOpen, isFalse);
      final back = period();
      expect((back.reservedPlanned, back.spent), (0, 4599), reason: 'counted once, as before the delete');
      // A second undo, or an undo after the record is used, writes nothing.
      final n = repo.pendingOps().length;
      repo.undeleteTransaction(txId);
      expect(repo.pendingOps().length, n);
    });

    test('the bill is not linked again when another payment took it meanwhile', () {
      final (id, _) = repo.importBill(slip());
      final first = repo.addExpenseFromBill(id, category: 'Bills & one-offs');
      repo.deleteTransaction(first);
      final second = repo.addExpenseFromBill(id, category: 'Bills & one-offs');
      repo.undeleteTransaction(first);
      expect(repo.bill(id)!.linkedTx, second);
      expect(repo.transaction(first)!.deleted, isFalse);
    });

    test('the undo record is purged after a day: the row still comes back, the bill stays open', () {
      var now = noon;
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      final (id, _) = r.importBill(slip());
      final tx = r.addExpenseFromBill(id, category: 'Bills & one-offs');
      r.deleteTransaction(tx);
      expect(r.db.select("SELECT key FROM meta WHERE key LIKE 'undo%'"), hasLength(1));
      now += const Duration(days: 1, minutes: 1).inMilliseconds;
      r.deleteTransaction(r.addTransaction(date: '2026-03-02', amount: 100, category: 'Groceries'));
      expect(r.db.select("SELECT key FROM meta WHERE key LIKE 'undo%'"), isEmpty);
      r.undeleteTransaction(tx);
      expect(r.transaction(tx)!.deleted, isFalse);
      expect(r.bill(id)!.linkedTx, isNull, reason: 'the record is gone: the row comes back, the bill stays open');
    });
  });

  group('two devices (§4.10)', () {
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
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-undo-');
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

    test('delete on A, undo on A: B converges to the live row', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      await syncAll([a, b]);
      final row = a.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      now += 1000;
      a.repo.deleteTransaction(row);
      await syncAll([a, b]);
      expect(b.repo.transaction(row)!.deleted, isTrue);
      now += 1000;
      a.repo.undeleteTransaction(row);
      await syncAll([a, b]);
      expect(b.repo.transaction(row)!.deleted, isFalse);
      expect(dump(a.repo), dump(b.repo));
    });

    test('tx: delete on A, edit on B, then undo on A: the row is live with B\'s edit (the later deleted: 0 wins)', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      await syncAll([a, b]);
      final row = a.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      now += 1000;
      a.repo.deleteTransaction(row);
      now += 1000;
      b.repo.setCategory(row, 'Groceries'); // B has not seen the delete
      now += 1000;
      a.repo.undeleteTransaction(row);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final t = d.repo.transaction(row)!;
        expect((t.deleted, t.category), (false, 'Groceries'), reason: d.name);
      }
      expect(dump(a.repo), dump(b.repo));
    });

    test('tx: an edit alone never revives the row; a delete on B after the undo wins (later write)', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      await syncAll([a, b]);
      final row = a.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      now += 1000;
      a.repo.deleteTransaction(row);
      now += 1000;
      b.repo.setCategory(row, 'Groceries');
      await syncAll([a, b]);
      expect(b.repo.transaction(row)!.deleted, isTrue, reason: 'delete wins over an edit (§4.10)');
      now += 1000;
      a.repo.undeleteTransaction(row);
      now += 1000;
      b.repo.deleteTransaction(row); // B has not seen the undo: its delete is later
      await syncAll([a, b]);
      expect(a.repo.transaction(row)!.deleted, isTrue);
      expect(dump(a.repo), dump(b.repo));
    });

    test('goal: delete on A, edit on B, then undo on A: live with B\'s edit and every contribution', () async {
      final a = device('a'), b = device('b');
      final g = a.repo.saveGoal(name: 'Synthetic trip', target: 50000, saved: 1000, monthly: 500);
      a.repo.addGoalContribution(g, 700, date: '2025-12-20');
      await syncAll([a, b]);
      now += 1000;
      a.repo.deleteGoal(g);
      now += 1000;
      b.repo.saveGoal(id: g, name: 'Synthetic trip', target: 60000, saved: 2000, monthly: 500); // +300 on B
      now += 1000;
      a.repo.undeleteGoal(g);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final goal = d.repo.goals().single;
        expect((goal.target, goal.saved), (60000, 2000), reason: d.name);
        expect(d.repo.goalContributions(g).map((c) => c.amount), unorderedEquals([700, 300]), reason: d.name);
      }
      expect(dump(a.repo), dump(b.repo));
    });
  });
}
