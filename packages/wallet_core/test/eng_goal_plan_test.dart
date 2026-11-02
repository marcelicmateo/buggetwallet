// ENG E6 (ENG_UI_SPEC §5.5, §6.5): big-purchase goal fields (schema 21), `goalPlan` and `goalLevers`. All data SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _today = '2026-11-02';
const _v21Cols = [
  'price',
  'deposit_permille',
  'costs_permille',
  'loan_rate_bp',
  'loan_months',
  'compare_line_id',
  'bought_at',
  'loan_id',
];

Goal _goal({int price = 0, int? deposit, int? costs = 60, int? rate, int? months = 360}) =>
    Goal(id: 'g1', name: 'Car', price: price, depositPermille: deposit, costsPermille: costs, loanRateBp: rate, loanMonths: months);

GoalPlan _plan(Goal g, {int saved = 0, int monthly = 0, int? compare, int toSpend = 0}) =>
    goalPlan(g, savedCents: saved, monthlyCents: monthly, compareCents: compare, toSpendPerPeriodCents: toSpend, today: _today);

/// What a schema-20 build reads from the relay: goal ops without the v21 fields (it does not know them, so they are
/// never stored and get no clock).
class _Schema20Reader implements SyncTransport {
  final SyncTransport inner;
  final VaultKey key;
  int stripped = 0;
  _Schema20Reader(this.inner, this.key);

  Future<List<int>> _rewrite(List<int> bytes, List<int> aad) async {
    final j = jsonDecode(utf8.decode(await unseal(bytes, key, aad: aad)));
    final ops = (j is Map ? j['ops'] : j) as List;
    var n = 0;
    final out = <Map<String, Object?>>[];
    for (final o in ops.cast<Map<String, Object?>>()) {
      if (o['e'] != 'goal' || o['f'] is! Map) {
        out.add(o);
        continue;
      }
      final f = Map<String, Object?>.of(o['f'] as Map<String, Object?>);
      n += f.length;
      f.removeWhere((k, _) => _v21Cols.contains(k));
      n -= f.length;
      out.add({...o, 'f': f});
    }
    if (n == 0) return bytes;
    stripped += n;
    return seal(utf8.encode(jsonEncode(j is Map ? {...j, 'ops': out} : out)), key, aad: aad);
  }

  @override
  Future<List<int>> get(String device, int seq) async => _rewrite(await inner.get(device, seq), aadSyncFile(device, seq));
  @override
  Future<List<int>> getSnapshot(String id) async => _rewrite(await inner.getSnapshot(id), aadSnapshot(id));
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) => inner.put(device, seq, bytes);
  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) => inner.putSnapshot(id, covers, bytes);
  @override
  Future<void> putBlob(String hash, List<int> bytes) => inner.putBlob(hash, bytes);
  @override
  Future<List<int>?> getBlob(String hash) => inner.getBlob(hash);
  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) => inner.putSnapshotBlobs(id, hashes);
}

void main() {
  group('annuity: published examples', () {
    // Standard fixed-rate mortgage tables (monthly compounding, r = annual / 12), e.g. Wikipedia "Mortgage
    // calculator" and any bank amortization calculator: 200 000 at 6.5 % / 30 y = 1 264.14; 100 000 at 5 % / 15 y =
    // 790.79; 300 000 at 4 % / 30 y = 1 432.25. Checked again with exact fractions (Python Fraction).
    test('200 000 / 6.5 % / 360 = 1264.14', () => expect(annuityPayment(20000000, 650, 360), 126414));
    test('100 000 / 5 % / 180 = 790.79', () => expect(annuityPayment(10000000, 500, 180), 79079));
    test('300 000 / 4 % / 360 = 1432.25', () => expect(annuityPayment(30000000, 400, 360), 143225));
    test('through goalPlan: 20 % deposit of 250 000 at 6.5 % = the 200 000 loan', () {
      final p = _plan(_goal(price: 25000000, deposit: 200, rate: 650));
      expect([p.deposit, p.costs, p.need, p.loan, p.payment], [5000000, 1500000, 6500000, 20000000, 126414]);
    });
    test('fewer than 1 month: the whole loan at once; no loan: 0', () {
      expect(annuityPayment(123456, 650, 0), 123456);
      expect(annuityPayment(123456, 0, -3), 123456);
      expect(annuityPayment(0, 650, 360), 0);
    });
  });

  group('goalPlan edges', () {
    test('0 %: loan ÷ months rounded up to the cent; null rate reads as 0 %', () {
      expect(_plan(_goal(price: 10000000, deposit: 0, rate: 0)).payment, 27778);
      expect(_plan(_goal(price: 10000000, deposit: 0)).payment, 27778);
      expect(_plan(_goal(price: 3600, deposit: 0, rate: 0)).payment, 10, reason: 'exact division stays exact');
    });
    test('no read defaults: null costs = 0; a loan without a length has no payment yet', () {
      final p = _plan(_goal(price: 10000000, deposit: 200, costs: null, months: null), compare: 1, toSpend: 5);
      expect([p.costs, p.loan, p.payment, p.vsCompare, p.afterPerPeriod, p.shortBy], [0, 8000000, null, null, null, null]);
    });
    test('nothing left: months 0, ready this month, never a negative left', () {
      final p = _plan(_goal(price: 10000000, deposit: 200), saved: 99999999);
      expect([p.left, p.months, p.readyMonth], [0, 0, '2026-11']);
    });
    test('monthly 0 with money left: months and ready month null', () {
      final p = _plan(_goal(price: 10000000, deposit: 200), saved: 100);
      expect([p.months, p.readyMonth, p.left], [null, null, 2600000 - 100]);
    });
    test('null deposit = paid in full: no loan, need = price + costs', () {
      final p = _plan(_goal(price: 10000000, rate: 500));
      expect([p.deposit, p.loan, p.payment, p.need], [10000000, 0, 0, 10600000]);
    });
    test('permilles round half away from zero once', () {
      final p = _plan(_goal(price: 1, deposit: 500)); // 0.5 → 1; 1 × 60 ‰ = 0.06 → 0
      expect([p.deposit, p.costs, p.loan], [1, 0, 0]);
    });
    test('a 10^11-cent price at 8 % over 600 months: exact, no overflow', () {
      final p = _plan(_goal(price: 100000000000, deposit: 920, rate: 800, months: 600), monthly: 1);
      expect([p.loan, p.payment, p.need, p.months], [8000000000, 54341941, 98000000000, 98000000000]);
      expect(_plan(_goal(price: 100000000000, deposit: 200, rate: 400)).payment, 381932236);
    });
    test('vs the compared line and money after: after when it fits, short by when not, none compared', () {
      final g = _goal(price: 25000000, deposit: 200, rate: 650); // 1264.14 a month
      final fits = _plan(g, compare: 80000, toSpend: 100000);
      expect([fits.vsCompare, fits.afterPerPeriod, fits.shortBy], [46414, 100000 - 46414, null]);
      final short = _plan(g, compare: 80000, toSpend: 40000);
      expect([short.afterPerPeriod, short.shortBy], [null, 6414]);
      expect(_plan(g, compare: 200000).afterPerPeriod, 200000 - 126414, reason: 'cheaper than the line frees money');
      final none = _plan(g, toSpend: 200000);
      expect([none.vsCompare, none.afterPerPeriod], [null, 200000 - 126414]);
    });
  });

  group('goal fields (schema 21)', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => 1791590400000));
    tearDown(() => repo.close());

    List<Object?> fields(Goal g) =>
        [g.price, g.depositPermille, g.costsPermille, g.loanRateBp, g.loanMonths, g.compareLineId, g.boughtAt, g.loanId];

    test('patch round trip and clear', () {
      final id = repo.saveGoal(name: 'Boat', target: 0, saved: 0, monthly: 0);
      expect(fields(repo.goals().single), List.filled(8, null));
      repo.patch(GoalCols.entity, id, <Col, Object?>{
        GoalCols.price: 30000000,
        GoalCols.depositPermille: 150,
        GoalCols.costsPermille: 45,
        GoalCols.loanRateBp: 375,
        GoalCols.loanMonths: 300,
        GoalCols.compareLineId: 'rent',
        GoalCols.boughtAt: '2026-10-01',
        GoalCols.loanId: 'l1',
      });
      expect(fields(repo.goals().single), [30000000, 150, 45, 375, 300, 'rent', '2026-10-01', 'l1']);
      repo.addGoalContribution(id, 500);
      repo.saveGoal(id: id, name: 'Boat', target: 0, saved: 500, monthly: 1000);
      expect(repo.goals().single.loanRateBp, 375, reason: 'saveGoal and contributions keep the planner fields');
      repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.costsPermille: null, GoalCols.loanMonths: clearValue});
      expect([repo.goals().single.costsPermille, repo.goals().single.loanMonths], [null, null]);
    });

    test('refused: a bought date in the future, a deleted goal; nothing written', () {
      final id = repo.saveGoal(name: 'Boat', target: 0, saved: 0, monthly: 0);
      expect(() => repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.boughtAt: '2099-01-01'}), throwsArgumentError);
      repo.deleteGoal(id);
      expect(() => repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.price: 1}), throwsArgumentError);
      expect(repo.db.select('SELECT price, bought_at FROM goals WHERE id = ?', [id]).first.values, [null, null]);
    });

    test('backup round trip keeps the fields', () async {
      final id = repo.saveGoal(name: 'Boat', target: 0, saved: 0, monthly: 0);
      repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.price: 123400, GoalCols.loanMonths: 12});
      final key = VaultKey.generate();
      final fresh = WalletRepo.inMemory(now: () => 1791590400000);
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, await backupBytes(repo, key), key);
      expect(fields(fresh.goals().single), [123400, null, null, null, 12, null, null, null]);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    final devices = <Device>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-eng-goal-');
      key = VaultKey.generate();
      net = Net();
      now = DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    List<Object?> fields(WalletRepo r) {
      final g = r.goals().single;
      return [g.name, g.monthly, g.price, g.depositPermille, g.loanRateBp];
    }

    test('edits of different fields on two devices both land (last writer wins per field)', () async {
      final a = Device('a', null, key, () => now, net: net), b = Device('b', null, key, () => now, net: net);
      devices.addAll([a, b]);
      final id = a.repo.saveGoal(name: 'Car', target: 0, saved: 0, monthly: 0);
      now += 1000;
      await a.run();
      await b.run();
      a.repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.price: 20000000, GoalCols.loanRateBp: 450});
      now += 1000;
      b.repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.depositPermille: 100, GoalCols.price: 21000000});
      now += 1000;
      await a.run();
      await b.run();
      await a.run();
      for (final d in [a, b]) {
        expect(fields(d.repo), ['Car', 0, 21000000, 100, 450], reason: d.name);
      }
    });

    test('a schema-20 device ignores the fields, keeps them on the new one, and gets them on upgrade', () async {
      final neu = Device('new', null, key, () => now, net: net);
      final old = Device('old', tmp, key, () => now, dbPath: '${tmp.path}/old.db', net: net);
      devices.addAll([neu, old]);
      old.repo.db.execute("UPDATE meta SET value = '20' WHERE key = 'schema'");
      late _Schema20Reader reader;
      Future<SyncReport> oldRun() {
        reader = _Schema20Reader(old.relay, key);
        return SyncEngine(reader, key).run(old.repo);
      }

      final id = neu.repo.saveGoal(name: 'Car', target: 0, saved: 0, monthly: 0);
      neu.repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.price: 20000000, GoalCols.loanRateBp: 650});
      now += 1000;
      await neu.run();
      now += 1000;
      expect((await oldRun()).problems, isEmpty);
      expect(reader.stripped, 2);
      expect(fields(old.repo), ['Car', 0, null, null, null]);
      expect(old.repo.db.select("SELECT COUNT(*) AS n FROM clocks WHERE entity = 'goal' AND field = 'price'").first['n'], 0,
          reason: 'no clock: it replays later');
      // The old build edits the goal: its op carries only the fields it knows.
      old.repo.saveGoal(id: id, name: 'Van', target: 0, saved: 0, monthly: 5000);
      now += 1000;
      await oldRun();
      now += 1000;
      await neu.run();
      expect(fields(neu.repo), ['Van', 5000, 20000000, null, 650]);

      old.reopen(); // 20 → 21: cursors cleared, the skipped fields replay
      expect(old.repo.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      now += 1000;
      await old.run();
      expect(fields(old.repo), ['Van', 5000, 20000000, null, 650]);
    });
  });

  group('goalLevers', () {
    const st = WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-10-15');
    // The 12 completed months before November 2026.
    final months = [for (var m = 11; m <= 22; m++) '${2025 + (m - 1) ~/ 12}-${((m - 1) % 12 + 1).toString().padLeft(2, '0')}'];
    List<CategorizedTx> rows(String category, List<int> perMonth) => [
          for (var i = 0; i < 12; i++)
            if (perMonth[i] != 0) ct('${months[i]}-05', -perMonth[i], category)
        ];
    final g = _goal(price: 10000000, deposit: 200); // need 2 600 000
    GoalPlan plan({int monthly = 100000}) => _plan(g, monthly: monthly); // 26 months
    RecurringBill inc(String id, int amount,
            {String category = 'Extra income', String status = 'confirmed', String? direction = 'in', int days = 30, String? endsOn}) =>
        RecurringBill(
            id: id,
            payee: id,
            label: id,
            category: category,
            expectedAmount: amount,
            intervalDays: days,
            nextDue: '2026-11-20',
            status: status,
            direction: direction,
            endsOn: endsOn);

    test('a tag above its median: cut floored to euros, months saved; others stay out', () {
      final txs = [
        ...rows('Eating out', [...List.filled(9, 20000), 30050, 30050, 30050]), // mean 300.50, median 200 → 100
        ...rows('Groceries', List.filled(12, 40000)), // at its median
        ...rows('Shopping', [...List.filled(9, 10000), 0, 0, 0]), // below
        ct('2026-11-01', -999999, 'Eating out'), // the running month never counts
        ct('2025-10-31', -999999, 'Eating out'), // before the window
      ];
      final l = goalLevers(txs, st, CategoryTable.builtIn, _today, plan: plan());
      expect(l.map((x) => (x.kind, x.key, x.cut, x.months, x.monthsSaved)), [(GoalLeverKind.tag, 'Eating out', 10000, 24, 2)]);
    });

    test('a lever that saves no month is dropped (left 3000 €, 1000 € a month, cut 12 €)', () {
      final small = _goal(price: 300000, costs: 0); // paid in full: need 3000.00
      final p = _plan(small, monthly: 100000); // 3 months
      final txs = rows('Eating out', [...List.filled(9, 10000), 11234, 11234, 11234]); // cut 12.00
      expect(goalLevers(txs, st, CategoryTable.builtIn, _today, plan: p), isEmpty);
    });

    test('median of 12 is the mean of the 6th and 7th; empty months count as 0', () {
      final txs = rows('Eating out', [0, 0, 0, 0, 0, 10000, 10000, 10000, 20000, 20000, 20000, 20000]);
      expect(goalLevers(txs, st, CategoryTable.builtIn, _today, plan: plan()).single.cut, 10000);
    });

    test('foreign rows without a rate, transfers and income never count', () {
      final eur = rows('Eating out', List.filled(12, 10000));
      const usd = CategorizedTx(Tx(id: 'usd', source: 'rev', date: '2026-10-05', amount: -500000, currency: 'USD', description: 'x'),
          'Eating out', BudgetKind.flex);
      final txs = [...eur, usd, ct('2026-10-06', -500000, 'Internal transfer'), ct('2026-10-07', 900000, 'Salary')];
      expect(goalLevers(txs, st, CategoryTable.builtIn, _today, plan: plan()), isEmpty);
    });

    test('confirmed side incomes (kind extra) at their monthly figure; salary, other kinds, candidates, bills and finished ones left out',
        () {
      final l = goalLevers(const [], st, CategoryTable.builtIn, _today,
          plan: plan(),
          incomes: [
            inc('side', 30000),
            inc('yearly', 120000, days: 365), // 100.00 a month
            inc('salary', 250000, category: 'Salary'), // the plan counts it as salary already
            inc('flex', 40000, category: 'Shopping'), // not a side income
            inc('cand', 50000, status: 'candidate'),
            inc('bill', 50000, direction: null),
            inc('ended', 50000, endsOn: '2026-10-20'),
          ]);
      expect(l.map((x) => (x.kind, x.key, x.cut, x.months, x.monthsSaved)),
          [(GoalLeverKind.income, 'side', 30000, 20, 6), (GoalLeverKind.income, 'yearly', 10000, 24, 2)]);
    });

    test('plan with no monthly: months from the lever alone, months saved null; nothing left: no levers', () {
      final txs = rows('Eating out', [...List.filled(9, 0), 130000, 130000, 130000]); // median 0 → cut 1300.00
      final l = goalLevers(txs, st, CategoryTable.builtIn, _today, plan: plan(monthly: 0)).single;
      expect([l.cut, l.months, l.monthsSaved], [130000, 20, null]);
      expect(goalLevers(txs, st, CategoryTable.builtIn, _today, plan: _plan(g, saved: 2600000)), isEmpty);
    });
  });
}
