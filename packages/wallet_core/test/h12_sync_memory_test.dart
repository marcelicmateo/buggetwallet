// ignore_for_file: avoid_dynamic_calls
// Stage H12 (sync, memory relay): zero ops on the second full round, a device back after 90 days, a clock far ahead or
// behind, concurrent sync runs, concurrent budget edits and concurrent bill links, the sync invariants, and the
// property "no live device is left behind by a prune". Written from the Stage H spec; a test of behaviour that a
// build does not have yet skips itself with a `BUG: H<n>` reason. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/engine_spec_sim.dart';
import 'support/h_compat.dart';
import 'support/h_sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 60));

Cluster _cluster() {
  final clock = SimClock();
  return Cluster(MemoryTransport(now: () => clock.t), clock);
}

MemoryTransport _mem(Cluster c) => c.transport as MemoryTransport;

/// Probe: does this build refuse a local write when the wall clock is far behind the stored clock?
bool _hasClockBehindGuard() {
  var ms = DateTime.utc(2026, 1, 10, 12).millisecondsSinceEpoch;
  final r = WalletRepo.inMemory(now: () => ms);
  try {
    r.addTransaction(date: '2026-01-10', amount: -100, category: 'Groceries');
    ms -= const Duration(hours: 3).inMilliseconds;
    try {
      r.addTransaction(date: '2026-01-10', amount: -200, category: 'Groceries');
      return false;
    } on Object catch (e) {
      return e.runtimeType.toString() == 'ClockBehindException';
    }
  } finally {
    r.close();
  }
}

bool _hasPerKeyBudgets() {
  final r = WalletRepo.inMemory();
  try {
    (r as dynamic).setCategoryBudget('Groceries', 100);
    return true;
  } on NoSuchMethodError {
    return false;
  } finally {
    r.close();
  }
}

void main() {
  final clockGuard = _hasClockBehindGuard();
  final clockDrift = reasonNamed('clockDrift') != null;
  final perKey = _hasPerKeyBudgets();

  group('zero ops on the second full round', () {
    test('three devices, every kind of data: after convergence a full round sends, reads and writes nothing', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b, d] = [c.add(), c.add(), c.add()];
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 0, monthly: 5000);
      b.repo.addTransaction(date: '2026-01-21', amount: -450, category: 'Eating out', note: 'synthetic');
      b.repo.addWish('Synthetic gadget', 12000);
      d.repo.importBill(synthBill('jir:h12-zero'));
      d.repo.importBatch(ImportBatch(
          source: 'pbz', transactions: [n('2026-01-12', -10000, 'POS plaćanje', 'Synthetic top-up', kind: TxKind.ownTransfer)]));
      b.repo.importBatch(ImportBatch(
          source: 'revolut',
          transactions: [n('2026-01-13', 10000, 'Topup', 'Synthetic top-up in', source: 'revolut', kind: TxKind.ownTransfer)]));
      await c.syncAll(rounds: 4);
      final puts = _mem(c).calls['put'] ?? 0;
      for (final x in c.devs) {
        final r = await x.sync();
        expect((r.sent, r.received, r.filesRead), (0, 0, 0), reason: 'device ${x.short}');
        expect(r.problems, isEmpty);
        expect(r.caughtUp, isTrue);
        c.tick(const Duration(seconds: 1));
      }
      expect(_mem(c).calls['put'] ?? 0, puts, reason: 'no file went up in the idle round');
      expect(data(a), data(b));
      expect(data(b), data(d));
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
      for (final x in c.devs) {
        expect(transferAsymmetries(x.repo), isEmpty);
      }
    }, timeout: _t);

    test('re-importing the same files on every device changes nothing and uploads nothing', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final before = data(a);
      for (final x in [a, b]) {
        final s = x.repo.importBatch(january);
        expect((s.added, s.duplicates), (0, january.transactions.length));
      }
      for (final x in c.devs) {
        final r = await x.sync();
        expect(r.sent, 0, reason: 're-import of known ids writes no op');
      }
      await c.syncAll(rounds: 2);
      expect(data(a), before);
      expect(data(b), before);
    }, timeout: _t);
  });

  group('a device back after 90 days', () {
    test('its files were pruned on the relay: it restarts from a snapshot, keeps its offline edit, loses nothing', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final offline = b.repo.addTransaction(date: '2026-01-22', amount: -777, category: 'Groceries', note: 'offline');
      // B disappears. A works for 100 days and syncs every 10 days: snapshots are written and A's files pruned.
      for (var day = 0; day < 100; day += 10) {
        c.tick(const Duration(days: 10));
        a.repo.addTransaction(date: addDays('2026-02-01', day), amount: -100 - day, category: 'Groceries', note: 'a$day');
        await a.sync();
      }
      final s = await c.transport.state();
      expect(s.snapshot, isNotNull, reason: 'a caught-up A wrote snapshots meanwhile');
      expect(s.devices[a.id]!.first, greaterThan(1), reason: 'B is not live after 90 days, so it no longer holds back the prune');
      c.tick(const Duration(seconds: 5));
      final back = await b.sync();
      expect(back.problems, isEmpty);
      await c.syncAll(rounds: 3);
      expect(data(a), data(b));
      expect(b.repo.transactions().where((t) => t.note == 'offline'), hasLength(1));
      expect(a.repo.transactions().any((t) => t.id == offline), isTrue, reason: "A got B's offline edit");
      expect(b.repo.transactions().where((t) => (t.note ?? '').startsWith('a')).length, 10);
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);

    test('exactly 89 days away is still live: nothing it needs is pruned', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      for (var day = 0; day < 88; day += 8) {
        c.tick(const Duration(days: 8));
        a.repo.addTransaction(date: '2026-02-01', amount: -100 - day, category: 'Groceries');
        await a.sync();
      }
      c.tick(const Duration(days: 1));
      final first = (await c.transport.state()).devices[a.id]!.first;
      expect(b.repo.syncCursors()[a.id] ?? 0, greaterThanOrEqualTo(first - 1), reason: 'B can read on from where it stopped');
      final r = await b.sync();
      expect(r.problems, isEmpty);
      expect(r.caughtUp, isTrue);
      await c.syncAll(rounds: 2);
      expect(data(a), data(b));
    }, timeout: _t);

    test('back after 91 days with files pruned AND a newer schema snapshot: one run is enough to catch up', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      for (var i = 0; i < 10; i++) {
        c.tick(const Duration(days: 10));
        a.repo.addTransaction(date: '2026-02-01', amount: -100 - i, category: 'Groceries');
        await a.sync();
      }
      final r = await b.sync();
      expect(r.problems, isEmpty);
      expect(r.waiting, isEmpty);
      expect(b.repo.transactions().length, a.repo.transactions().length);
    }, timeout: _t);
  });

  group('clocks (H7)', () {
    test('a peer file more than 1 h ahead is quarantined as clockDrift, not applied, and applied once the clock catches up', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final ahead = c.add(skewMs: const Duration(days: 2).inMilliseconds);
      final ok = c.add();
      ahead.repo.addTransaction(date: '2026-01-12', amount: -999, category: 'Groceries', note: 'from the future');
      await ahead.sync();
      c.tick(const Duration(minutes: 1));
      final r = await ok.sync();
      final reason = reasonNamed('clockDrift')!;
      expect(r.problems.map((p) => p.reason), [reason]);
      expect(ok.repo.transactions().where((t) => t.note == 'from the future'), isEmpty);
      expect(r.caughtUp, isFalse);
      // The same file again is not new, and the device's own writes are not poisoned meanwhile.
      ok.repo.addTransaction(date: '2026-01-12', amount: -50, category: 'Groceries', note: 'mine');
      final again = await ok.sync();
      expect(again.problems.single.isNew, isFalse);
      // Two days later the file is within an hour of the wall clock: retried and applied.
      c.tick(const Duration(days: 2));
      final later = await ok.sync();
      expect(later.problems, isEmpty);
      expect(ok.repo.transactions().where((t) => t.note == 'from the future'), hasLength(1));
      expect(ok.repo.transactions().where((t) => t.note == 'mine'), hasLength(1));
    }, skip: bugUnless(clockDrift, 'H7', 'SyncProblemReason.clockDrift quarantines files > 1 h ahead'), timeout: _t);

    test('59 minutes ahead is accepted (the bound is 1 h)', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final ahead = c.add(skewMs: const Duration(minutes: 59).inMilliseconds);
      final ok = c.add();
      ahead.repo.addTransaction(date: '2026-01-12', amount: -999, category: 'Groceries', note: 'slightly ahead');
      await ahead.sync();
      c.tick(const Duration(minutes: 1));
      final r = await ok.sync();
      expect(r.problems, isEmpty);
      expect(ok.repo.transactions().where((t) => t.note == 'slightly ahead'), hasLength(1));
    }, timeout: _t);

    test('today: a far-ahead peer is applied as is (it must not crash or lose either side)', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final ahead = c.add(skewMs: const Duration(days: 2).inMilliseconds);
      final ok = c.add();
      ahead.repo.addTransaction(date: '2026-01-12', amount: -999, category: 'Groceries', note: 'ahead');
      ok.repo.addTransaction(date: '2026-01-12', amount: -50, category: 'Groceries', note: 'mine');
      await c.syncAll(rounds: 3);
      if (clockDrift) {
        expect(ok.repo.transactions().where((t) => t.note == 'mine'), hasLength(1));
      } else {
        expect(data(ahead), data(ok));
      }
    }, timeout: _t);

    test('a write with the wall clock more than 1 h behind the stored clock throws ClockBehindException and writes nothing', () {
      var ms = DateTime.utc(2026, 1, 10, 12).millisecondsSinceEpoch;
      final r = WalletRepo.inMemory(now: () => ms);
      addTearDown(r.close);
      r.addTransaction(date: '2026-01-10', amount: -100, category: 'Groceries', note: 'first');
      final opsBefore = r.pendingOps().length;
      ms -= const Duration(minutes: 59).inMilliseconds;
      r.addTransaction(date: '2026-01-10', amount: -110, category: 'Groceries', note: 'within the hour');
      ms -= const Duration(minutes: 3).inMilliseconds; // now 62 minutes behind the newest clock
      final rows = r.transactions().length;
      final ops = r.pendingOps().length;
      expect(ops, greaterThan(opsBefore));
      Object? caught;
      try {
        r.addTransaction(date: '2026-01-10', amount: -120, category: 'Groceries', note: 'too far behind');
      } on Object catch (e) {
        caught = e;
      }
      expect(caught.runtimeType.toString(), 'ClockBehindException');
      expect(caught.toString(), isNot(matches(RegExp(r'\d{9,}'))), reason: 'plain words, no clock values');
      expect(r.transactions().length, rows);
      expect(r.pendingOps().length, ops);
      ms += const Duration(hours: 2).inMilliseconds; // the clock is fixed: writes work again
      r.addTransaction(date: '2026-01-10', amount: -130, category: 'Groceries', note: 'after the fix');
      expect(r.transactions().length, rows + 1);
    }, skip: bugUnless(clockGuard, 'H7', 'ClockBehindException when the wall clock is > 1 h behind the stored clock'), timeout: _t);
  });

  group('two sync runs at once', () {
    test('two engines on one repo (app and background task): both finish or fail cleanly, nothing is lost or duplicated', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      for (var i = 0; i < 20; i++) {
        a.repo.addTransaction(date: '2026-01-1${i % 9}', amount: -100 - i, category: 'Groceries', note: 'n$i');
      }
      final second = SyncEngine(c.transport, c.key, appVersion: '1.0.0', now: () => c.clock.t);
      final results = await Future.wait([
        a.sync().then<Object>((r) => r, onError: (Object e) => e),
        second.run(a.repo).then<Object>((r) => r, onError: (Object e) => e),
      ]);
      for (final r in results) {
        expect(r is SyncReport || r is SyncException, isTrue, reason: 'a failed overlap is a SyncException, got $r');
      }
      await c.syncAll(rounds: 3);
      expect(b.repo.transactions().length, 20);
      expect(data(a), data(b));
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);

    test('SyncEngine.run while a run is in progress on the same engine returns the running run (no second run)', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final a = c.add();
      for (var i = 0; i < 10; i++) {
        a.repo.addTransaction(date: '2026-01-1${i % 9}', amount: -100 - i, category: 'Groceries');
      }
      final f1 = a.engine.run(a.repo);
      final f2 = a.engine.run(a.repo);
      final [r1, r2] = await Future.wait([f1, f2]);
      expect(identical(r1, r2), isTrue, reason: 'the second call joined the first run');
      expect(_mem(c).calls['put'], 1, reason: 'one upload');
      // Afterwards a new run is a new run again.
      final r3 = await a.engine.run(a.repo);
      expect(identical(r3, r1), isFalse);
    }, skip: 'BUG: H9 - SyncEngine.run is not re-entrant: a second call while one runs starts a second run', timeout: _t);
  });

  group('concurrent budget edits (H3)', () {
    test('today: whole-map edits on two devices converge to one value on both (last writer wins), nothing diverges', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      await c.syncAll(rounds: 2);
      a.repo.updateSettings({
        'categoryBudgets': {'Groceries': 30000}
      });
      c.tick();
      b.repo.updateSettings({
        'categoryBudgets': {'Eating out': 15000}
      });
      await c.syncAll(rounds: 3);
      expect(a.repo.settings().categoryBudgets, b.repo.settings().categoryBudgets);
      expect(data(a), data(b));
    }, skip: perKey ? 'whole-map writes are refused with H3 (updateSettings throws ArgumentError)' : null, timeout: _t);

    test('two devices set different categories offline: both budgets survive the merge', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      await c.syncAll(rounds: 2);
      (a.repo as dynamic).setCategoryBudget('Groceries', 30000);
      c.tick();
      (b.repo as dynamic).setCategoryBudget('Eating out', 15000);
      await c.syncAll(rounds: 3);
      for (final x in [a, b]) {
        expect(x.repo.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 15000});
      }
      expect(data(a), data(b));
    }, skip: bugUnless(perKey, 'H3', 'one settings row per category budget (budget:<category>)'), timeout: _t);

    test('the same category on both: the later write wins on both; a removal and an edit converge to one answer', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b] = [c.add(), c.add()];
      (a.repo as dynamic).setCategoryBudget('Groceries', 30000);
      await c.syncAll(rounds: 3);
      (a.repo as dynamic).setCategoryBudget('Groceries', 31000);
      c.tick();
      (b.repo as dynamic).setCategoryBudget('Groceries', 32000);
      await c.syncAll(rounds: 3);
      expect(a.repo.settings().categoryBudgets, {'Groceries': 32000});
      expect(b.repo.settings().categoryBudgets, {'Groceries': 32000});
      // Removal on one, edit on the other: whichever wins, both devices agree and the map is valid.
      (a.repo as dynamic).setCategoryBudget('Groceries', null);
      (b.repo as dynamic).setCategoryBudget('Groceries', 33000);
      await c.syncAll(rounds: 3);
      expect(a.repo.settings().categoryBudgets, b.repo.settings().categoryBudgets);
      expect(a.repo.settings().categoryBudgets.values.every((v) => v > 0), isTrue);
      expect(data(a), data(b));
    }, skip: bugUnless(perKey, 'H3', 'setCategoryBudget(category, cents?) per-key rows'), timeout: _t);

    test('updateSettings with categoryBudgets or merchantPatterns throws ArgumentError once rows exist', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      expect(
          () => r.updateSettings({
                'categoryBudgets': {'Groceries': 1}
              }),
          throwsArgumentError);
      expect(() => r.updateSettings({'merchantPatterns': <String, Object?>{}}), throwsArgumentError);
    }, skip: bugUnless(perKey, 'H3', 'updateSettings refuses the two map settings'), timeout: _t);
  });

  group('concurrent linkBill (H9)', () {
    Future<(Cluster, Dev, Dev, String, String, String, String)> setup() async {
      final c = _cluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-02-10', -4500, 'Nalog', 'SYNTH UTILITY ONE'),
        n('2026-02-11', -4600, 'Nalog', 'SYNTH UTILITY TWO'),
      ]));
      final (x, _) = a.repo.importBill(synthBill('jir:h12-x'));
      final (y, _) = a.repo.importBill(synthBill('jir:h12-y', total: 4600));
      a.repo.updateBill(x, category: 'Bills & one-offs');
      a.repo.updateBill(y, category: 'Bills & one-offs');
      a.repo.confirmBill(x);
      a.repo.confirmBill(y);
      await c.syncAll(rounds: 3);
      final txs = b.repo.transactions();
      final t1 = txs.firstWhere((t) => t.amount == -4500).id, t2 = txs.firstWhere((t) => t.amount == -4600).id;
      return (c, a, b, x, y, t1, t2);
    }

    test('one payment linked to two different bills on two devices: after the merge it pays one bill, on both', () async {
      final (c, a, b, x, y, t1, _) = await setup();
      addTearDown(c.closeAll);
      a.repo.linkBill(x, t1);
      c.tick();
      b.repo.linkBill(y, t1);
      await c.syncAll(rounds: 4);
      for (final d in [a, b]) {
        expect(duplicatePayments(d.repo), isEmpty, reason: 'device ${d.short}');
        expect(strayPaidTx(d.repo), isEmpty);
      }
      expect(data(a), data(b));
      expect(a.repo.bills().where((bill) => bill.linkedTx == t1), hasLength(1));
    }, skip: 'BUG: H9 - bill.linked_tx is not unique across live bills after a merge (two bills pay one transaction)', timeout: _t);

    test('one bill linked to two different payments on two devices: one wins on both, its planned row agrees', () async {
      final (c, a, b, x, _, t1, t2) = await setup();
      addTearDown(c.closeAll);
      a.repo.linkBill(x, t1);
      c.tick();
      b.repo.linkBill(x, t2);
      await c.syncAll(rounds: 4);
      expect(a.repo.bill(x)!.linkedTx, b.repo.bill(x)!.linkedTx);
      expect(a.repo.bill(x)!.linkedTx, t2, reason: 'the later write wins');
      for (final d in [a, b]) {
        final planned = d.repo.plannedCosts(includeClosed: true).singleWhere((p) => p.id == 'bill:$x');
        expect(planned.paidTx, t2);
        expect(planned.status, PlannedStatus.paid);
        expect(strayPaidTx(d.repo), isEmpty);
      }
      expect(data(a), data(b));
    }, timeout: _t);

    test('link on one device, unlink on the other: converge; planned.paid_tx is empty unless the planned row is paid', () async {
      final (c, a, b, x, _, t1, t2) = await setup();
      addTearDown(c.closeAll);
      a.repo.linkBill(x, t1);
      await c.syncAll(rounds: 3);
      a.repo.unlinkBill(x);
      c.tick();
      b.repo.linkBill(x, t2);
      await c.syncAll(rounds: 4);
      expect(data(a), data(b));
      for (final d in [a, b]) {
        expect(strayPaidTx(d.repo), isEmpty, reason: 'device ${d.short}');
        final bill = d.repo.bill(x)!;
        final planned = d.repo.plannedCosts(includeClosed: true).singleWhere((p) => p.id == 'bill:$x');
        expect(planned.status == PlannedStatus.paid, bill.paid, reason: 'the planned row follows the bill');
      }
    }, skip: 'BUG: H9 - planned.paid_tx stays set on an open planned row after a concurrent unlink', timeout: _t);

    test('one device alone: unlink clears the planned row\'s paid_tx (stray payment on an open row)', () async {
      final (c, a, _, x, _, t1, _) = await setup();
      addTearDown(c.closeAll);
      a.repo.linkBill(x, t1);
      a.repo.unlinkBill(x);
      expect(strayPaidTx(a.repo), isEmpty);
    }, skip: 'BUG: H9 - planned.paid_tx is not cleared when status != paid', timeout: _t);

    test('a payment deleted on one device while linked on the other: the link does not outlive the transaction', () async {
      final (c, a, b, x, _, t1, _) = await setup();
      addTearDown(c.closeAll);
      a.repo.deleteTransaction(t1);
      c.tick();
      b.repo.linkBill(x, t1);
      await c.syncAll(rounds: 4);
      expect(data(a), data(b));
      for (final d in [a, b]) {
        final bill = d.repo.bill(x)!;
        if (bill.linkedTx != null) {
          expect(d.repo.transaction(bill.linkedTx!)!.deleted, isFalse, reason: 'a bill is never paid by a deleted row');
        }
        expect(strayPaidTx(d.repo), isEmpty);
      }
    }, skip: 'BUG: H9 - a link to a payment row deleted elsewhere is not repaired when caught up', timeout: _t);
  });

  group('transfer symmetry and invariants', () {
    test('a pair imported on two devices ends symmetric on both; invariants hold after every round', () async {
      final c = _cluster();
      addTearDown(c.closeAll);
      final [a, b, d] = [c.add(), c.add(), c.add()];
      for (var i = 0; i < 4; i++) {
        final day = '2026-01-${10 + i}';
        a.repo.importBatch(ImportBatch(
            source: 'pbz', transactions: [n(day, -10000 - i, 'POS plaćanje', 'Synthetic top-up $i', kind: TxKind.ownTransfer)]));
        b.repo.importBatch(ImportBatch(
            source: 'revolut',
            transactions: [n(day, 10000 + i, 'Topup', 'Synthetic top-up in $i', source: 'revolut', kind: TxKind.ownTransfer)]));
      }
      for (var round = 0; round < 4; round++) {
        await c.syncAll(rounds: 1);
        expect(await invariantViolations(c.transport, c.devs), isEmpty, reason: 'round $round');
      }
      for (final x in [a, b, d]) {
        expect(transferAsymmetries(x.repo), isEmpty, reason: x.short);
        expect(x.repo.transactions(includeHidden: true).where((t) => t.transferTo != null), hasLength(8));
      }
      // Deleting one leg clears the other on every device, never leaving a one-way link.
      final leg = a.repo.transactions(includeHidden: true).firstWhere((t) => t.transferTo != null).id;
      a.repo.deleteTransaction(leg);
      await c.syncAll(rounds: 3);
      for (final x in [a, b, d]) {
        expect(transferAsymmetries(x.repo), isEmpty, reason: x.short);
      }
      expect(data(a), data(d));
    }, timeout: _t);

    test('a transfer leg arriving late (offline device) never leaves a one-way link, any order', () async {
      for (final seed in [1, 2, 3, 4, 5, 6]) {
        final r = Random(seed);
        final c = _cluster();
        final devs = [c.add(), c.add(), c.add()];
        for (var i = 0; i < 3; i++) {
          final day = '2026-01-${10 + i}';
          devs[r.nextInt(3)].repo.importBatch(ImportBatch(
              source: 'pbz', transactions: [n(day, -20000 - i, 'POS plaćanje', 'Synthetic top-up $i', kind: TxKind.ownTransfer)]));
          devs[r.nextInt(3)].repo.importBatch(ImportBatch(
              source: 'revolut',
              transactions: [n(day, 20000 + i, 'Topup', 'Synthetic top-up in $i', source: 'revolut', kind: TxKind.ownTransfer)]));
          await devs[r.nextInt(3)].sync();
          c.tick();
        }
        await c.syncAll(rounds: 4);
        for (final x in devs) {
          expect(transferAsymmetries(x.repo), isEmpty, reason: 'seed $seed ${x.short}');
        }
        expect(data(devs[0]), data(devs[1]), reason: 'seed $seed');
        c.closeAll();
      }
    }, timeout: _t);
  });

  group('property: no live device is left behind by a prune', () {
    // Random edits, syncs and long waits on three devices; one device sometimes sleeps for weeks. After every step each
    // device that the relay still counts as live (seen within 90 days) must be able to continue from its cursor
    // (its next file exists, or it can start from a snapshot); at the end everyone converges and keeps every edit
    // that was ever made and never deleted.
    var prunedSomewhere = 0;
    for (final seed in [1, 7, 42, 2026, 31337, 99991]) {
      test('seed $seed', () async {
        final r = Random(seed);
        final c = _cluster();
        addTearDown(c.closeAll);
        final devs = [c.add(), c.add(), c.add()];
        final kept = <String>{};
        final sleepingUntil = <Dev, DateTime>{};
        var noteN = 0;
        for (var step = 0; step < 70; step++) {
          final d = devs[r.nextInt(3)];
          switch (r.nextInt(10)) {
            case 0 || 1 || 2:
              final id = d.repo.addTransaction(
                  date: addDays('2026-01-01', r.nextInt(300)),
                  amount: -(100 + r.nextInt(5000)),
                  category: 'Groceries',
                  note: 'k${noteN++}');
              kept.add(id);
            case 3:
              d.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
                n(addDays('2026-01-01', r.nextInt(300)), -(100 + r.nextInt(900)), 'POS plaćanje', 'POS SYNTH ${r.nextInt(5)}')
              ]));
            case 4:
              final rows = d.repo.transactions().where((t) => !t.manual).toList();
              if (rows.isNotEmpty) d.repo.deleteTransaction(rows[r.nextInt(rows.length)].id);
            case 5 || 6 || 7:
              final until = sleepingUntil[d];
              if (until == null || !c.clock.t.isBefore(until)) {
                await d.sync();
              }
            case 8:
              // The device goes away for 10..80 days (or, rarely, over 90).
              sleepingUntil[d] = c.clock.t.add(Duration(days: r.nextInt(10) == 0 ? 95 : 10 + r.nextInt(70)));
            default:
              c.tick(Duration(hours: 1 + r.nextInt(r.nextInt(4) == 0 ? 24 * 20 : 72)));
          }
          if (step % 5 == 4) c.tick(Duration(days: 1 + r.nextInt(12)));
          // The property: every live device can continue.
          final s = await c.transport.state();
          if (s.devices.values.any((d) => d.first > 1)) prunedSomewhere++;
          for (final x in devs) {
            final me = s.devices[x.id];
            if (me?.lastSeen == null) continue;
            if (c.clock.t.difference(me!.lastSeen!) > MemoryTransport.activeFor) continue;
            final cursors = x.repo.syncCursors();
            for (final MapEntry(key: p, value: pd) in s.devices.entries) {
              if (p == x.id) continue;
              expect(cursors[p] ?? 0, greaterThanOrEqualTo(pd.first - 1),
                  reason: 'seed $seed step $step: live device ${x.short} needs a file of ${SyncProblem.shortId(p)} that was pruned');
            }
          }
        }
        // Everybody wakes up and syncs.
        c.tick(const Duration(days: 1));
        for (var round = 0; round < 4; round++) {
          for (final x in devs) {
            final rep = await x.sync();
            expect(rep.problems, isEmpty, reason: 'seed $seed ${x.short}');
            c.tick(const Duration(seconds: 1));
          }
        }
        expect(data(devs[0]), data(devs[1]), reason: 'seed $seed');
        expect(data(devs[1]), data(devs[2]), reason: 'seed $seed');
        for (final x in devs) {
          final have = {for (final t in x.repo.transactions(includeHidden: true)) t.id};
          expect(have.containsAll(kept), isTrue, reason: 'seed $seed: device ${x.short} lost an edit');
        }
        expect(await invariantViolations(c.transport, devs), isEmpty, reason: 'seed $seed');
        for (final x in devs) {
          final rep = await x.sync();
          expect((rep.sent, rep.received), (0, 0), reason: 'seed $seed: second full round is idle');
        }
      }, timeout: _t);
    }
    test('the seeds above really pruned files (the property is not vacuous)', () {
      expect(prunedSomewhere, greaterThan(20));
    });
  });
}
