// ENG_UI_SPEC §6.5 big-purchase goal maths, written from the spec (not the implementation). All data SYNTHETIC.
// Expected annuity values were computed outside Dart with exact fractions (python Fraction, round half away from zero).
// Assumes readyMonth = month of `today` + months (months 0 = this month).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

const _today = '2026-11-02';

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => 1791590400000));
  tearDown(() => repo.close());

  Goal financed({
    required int price,
    int deposit = 200,
    int buy = 60,
    int rateBp = 0,
    int months = 360,
  }) {
    final id = repo.saveGoal(name: 'Home', target: 0, saved: 0, monthly: 0);
    repo.patch(GoalCols.entity, id, <Col, Object?>{
      GoalCols.price: price,
      GoalCols.depositPermille: deposit,
      GoalCols.costsPermille: buy,
      GoalCols.loanRateBp: rateBp,
      GoalCols.loanMonths: months,
    });
    return repo.goals().firstWhere((g) => g.id == id);
  }

  GoalPlan plan(Goal g, {int saved = 0, int monthly = 100000, int? rent, int toSpend = 0}) =>
      goalPlan(g, savedCents: saved, monthlyCents: monthly, compareCents: rent, toSpendPerPeriodCents: toSpend, today: _today);

  group('annuity (published examples)', () {
    // Textbook: 100 000 at 6.00 % over 30 years = 599.55 a month (price 125 000, 20 % deposit).
    test('100 000 / 6.00 % / 360 -> 599.55', () => expect(plan(financed(price: 12500000, rateBp: 600)).payment, 59955));
    // Bank calculators: 200 000 at 4.50 % over 30 years = 1 013.37.
    test('200 000 / 4.50 % / 360 -> 1013.37', () => expect(plan(financed(price: 25000000, rateBp: 450)).payment, 101337));
    // 250 000 at 3.50 % over 20 years = 1 449.90 (price 312 500).
    test('250 000 / 3.50 % / 240 -> 1449.90', () => expect(plan(financed(price: 31250000, rateBp: 350, months: 240)).payment, 144990));
    test('deposit, costs, need, loan', () {
      final p = plan(financed(price: 12500000, rateBp: 600), saved: 1000000);
      expect([p.deposit, p.costs, p.need, p.left, p.loan], [2500000, 750000, 3250000, 2250000, 10000000]);
    });
  });

  group('rate edges', () {
    test('0 % = loan / n rounded up to the cent', () {
      expect(plan(financed(price: 12500000, rateBp: 0)).payment, 27778); // 100000.00 / 360 = 277.7777..
      expect(plan(financed(price: 12500000, rateBp: 0, months: 7)).payment, 1428572); // 14285.714..
    });
    test('exactly 1 bp', () => expect(plan(financed(price: 12500000, rateBp: 1)).payment, 27820));
    test('n = 1: loan plus one month of interest', () {
      expect(plan(financed(price: 6250000, rateBp: 500, months: 1)).payment, 5020833); // 50000 * (1 + 0.05/12)
    });
    test('half cent rounds away from zero', () {
      // price 60 cents, no deposit, 10 % over 1 month: 60 * 121/120 = 60.5 -> 61
      expect(plan(financed(price: 60, deposit: 0, rateBp: 1000, months: 1)).payment, 61);
      expect(plan(financed(price: 1860, deposit: 0, rateBp: 1000, months: 1)).payment, 1876); // 1875.5
    });
  });

  group('plan edges', () {
    test('nothing left: months 0, ready this month', () {
      final p = plan(financed(price: 12500000), saved: 3250000);
      expect([p.left, p.months, p.readyMonth], [0, 0, '2026-11']);
      expect(plan(financed(price: 12500000), saved: 9999999).left, 0); // never negative
    });
    test('monthly 0 with money left: no months, no division', () {
      final p = plan(financed(price: 12500000), monthly: 0);
      expect(p.months, isNull);
      expect(p.readyMonth, isNull);
    });
    test('monthly 0 with nothing left is still 0 months', () {
      expect(plan(financed(price: 12500000), saved: 3250000, monthly: 0).months, 0);
    });
    test('negative monthly is treated like 0', () => expect(plan(financed(price: 12500000), monthly: -5).months, isNull));
    test('months is ceil: exact division and one cent more', () {
      final g = financed(price: 12500000);
      expect(plan(g, saved: 1000000, monthly: 750000).months, 3); // 2 250 000 / 750 000
      expect(plan(g, saved: 1000000, monthly: 749999).months, 4);
      expect(plan(g, saved: 1000000, monthly: 2250000).months, 1);
      expect(plan(g, saved: 1000000, monthly: 2249999).months, 2);
    });
    test('ready month crosses the year end', () {
      final g = financed(price: 12500000);
      expect(plan(g, saved: 1000000, monthly: 750000).readyMonth, '2027-02');
      expect(plan(g, saved: 1000000, monthly: 1125000).readyMonth, '2027-01'); // 2 months
      expect(plan(g, saved: 1000000, monthly: 2250000).readyMonth, '2026-12');
    });
    test('deposit 1000 permille: no loan, no payment, need = price + costs', () {
      final p = plan(financed(price: 12500000, deposit: 1000, rateBp: 600));
      expect([p.deposit, p.loan, p.payment, p.need], [12500000, 0, 0, 13250000]);
    });
    test('deposit 0: whole price is loan', () => expect(plan(financed(price: 12500000, deposit: 0)).loan, 12500000));
    test('10^11 cents price does not overflow', () {
      final p = plan(financed(price: 100000000000, rateBp: 400), saved: 0, monthly: 1);
      expect([p.deposit, p.costs, p.need, p.loan], [20000000000, 6000000000, 26000000000, 80000000000]);
      expect(p.payment, 381932236); // 800 000 000.00 at 4 % / 360
      expect(p.months, 26000000000);
      expect(plan(financed(price: 100000000000, rateBp: 0, months: 600)).payment, 133333334);
    });
    test('vs rent and money after the plan', () {
      final p = plan(financed(price: 12500000, rateBp: 600), rent: 50000, toSpend: 200000);
      expect(p.vsCompare, 59955 - 50000);
    });
    test('affordable vs short', () {
      final ok = plan(financed(price: 12500000), monthly: 100000, toSpend: 500000);
      final bad = plan(financed(price: 12500000), monthly: 100000, toSpend: 0);
      expect(ok.shortBy == null || ok.shortBy == 0, isTrue);
      expect(ok.afterPerPeriod, isNotNull);
      expect(bad.shortBy, isNotNull);
      expect(bad.shortBy! > 0, isTrue);
    });
  });

  group('goal fields', () {
    test('no read defaults: unset planner fields read as null', () {
      final id = repo.saveGoal(name: 'Car', target: 100, saved: 0, monthly: 0);
      repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.price: 100});
      final g = repo.goals().firstWhere((g) => g.id == id);
      expect(g.price, 100);
      expect([g.depositPermille, g.costsPermille, g.loanRateBp, g.loanMonths, g.compareLineId, g.boughtAt, g.loanId], everyElement(isNull));
    });
    test('boundary values accepted', () {
      final id = repo.saveGoal(name: 'Home', target: 0, saved: 0, monthly: 0);
      repo.patch(GoalCols.entity, id, <Col, Object?>{
        GoalCols.depositPermille: 1000,
        GoalCols.costsPermille: 0,
        GoalCols.loanRateBp: 10000,
        GoalCols.loanMonths: 600,
      });
      repo.patch(GoalCols.entity, id, <Col, Object?>{
        GoalCols.depositPermille: 0,
        GoalCols.costsPermille: 1000,
        GoalCols.loanRateBp: 0,
        GoalCols.loanMonths: 1,
      });
    });
    for (final (name, col, v) in <(String, Col, int)>[
      ('deposit -1', GoalCols.depositPermille, -1),
      ('deposit 1001', GoalCols.depositPermille, 1001),
      ('costs -1', GoalCols.costsPermille, -1),
      ('costs 1001', GoalCols.costsPermille, 1001),
      ('rate -1', GoalCols.loanRateBp, -1),
      ('rate 10001', GoalCols.loanRateBp, 10001),
      ('months 0', GoalCols.loanMonths, 0),
      ('months 601', GoalCols.loanMonths, 601),
    ]) {
      test('refused: $name, nothing written', () {
        final id = repo.saveGoal(name: 'Home', target: 0, saved: 0, monthly: 0);
        final before = repo.db.select('SELECT count(*) c FROM outbox').first['c'];
        expect(() => repo.patch(GoalCols.entity, id, <Col, Object?>{GoalCols.price: 5, col: v}), throwsArgumentError);
        expect(repo.db.select('SELECT count(*) c FROM outbox').first['c'], before);
      });
    }
  });

  group('goalLevers', () {
    const st = WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-10-15');
    // 12 completed months Nov 2025 .. Oct 2026; the first 9 at 100.00, the last 3 as given (cents each).
    List<CategorizedTx> series(List<int> last3) {
      final months = ['2025-11', '2025-12', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05', '2026-06', '2026-07'];
      return [
        for (final m in months) ct('$m-10', -10000, 'Groceries'),
        for (var i = 0; i < 3; i++) ct('${['2026-08', '2026-09', '2026-10'][i]}-10', -last3[i], 'Groceries'),
      ];
    }

    List<dynamic> levers(List<CategorizedTx> txs) {
      // 100.00 a month: 225 months, so a 12 € cut saves some (a lever that saves no month is dropped).
      final p = plan(financed(price: 12500000), saved: 1000000, monthly: 10000);
      return goalLevers(txs, st, CategoryTable.builtIn, _today, plan: p, incomes: const []);
    }

    int cutOf(dynamic l) => (l as dynamic).cut as int;

    test('tag exactly at its median: no lever', () {
      expect(levers(series([10000, 10000, 10000])), isEmpty);
    });
    test('mean one cent above median: nothing worth cutting (cut < 1 euro)', () {
      expect(levers(series([10000, 10000, 10003])).where((l) => cutOf(l) > 0), isEmpty);
    });
    test('12.34 above median: cut rounded down to whole euros', () {
      final l = levers(series([11234, 11234, 11234]));
      expect(l.length, 1);
      expect(cutOf(l.single), 1200);
      expect((l.single as dynamic).monthsSaved, isNotNull);
    });
    test('refunds count as negative spend', () {
      // a refund in the last month lowers that month's total back to the median: no lever
      final txs = [
        ...series([10000, 10000, 12000]),
        ct('2026-10-12', 2000, 'Groceries')
      ];
      expect(levers(txs).where((l) => cutOf(l) > 0), isEmpty);
    });
  });
}
