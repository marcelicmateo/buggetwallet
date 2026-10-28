// BP: budget presets (averages, spend less, fit the plan, 50/30/20) and monthlyFlex. SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

var _seq = 0;

/// A row in [currency] with the kind the [table] gives its category.
CategorizedTx row(String date, int cents, String category, {String currency = 'EUR', CategoryTable? table}) => CategorizedTx(
      Tx(id: 'bp-${_seq++}', source: 'pbz', date: date, amount: cents, currency: currency),
      category,
      (table ?? CategoryTable.builtIn).kindOf(category),
    );

const _month = '2026-07';
const _kPets = 'k0123456789ab';
const _kInsurance = 'kba9876543210';

int _sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);

void main() {
  final table = CategoryTable.from([
    const CategoryRow(id: _kPets, name: 'Pets', kind: BudgetKind.flex),
    const CategoryRow(id: _kInsurance, name: 'Insurance', kind: BudgetKind.fixed),
  ]);
  const st = WalletSettings(salary: 200000, rent: 50000, loan: 20000, subs: 5000, currency: 'EUR');
  const emptySalary = WalletSettings(currency: 'EUR');

  // Groceries: 3 months 31000, 6 months 51000, 12 months 61000. Eating out: 3 months 12000, 6 and 12 months 18000.
  final history = [
    ct('2026-06-10', -31000, 'Groceries'),
    ct('2026-02-10', -20000, 'Groceries'),
    ct('2025-08-10', -10000, 'Groceries'),
    ct('2026-06-12', -12000, 'Eating out'),
    ct('2026-01-12', -6000, 'Eating out'),
    ct('2026-03-01', -300000, 'Rent'),
    ct('2026-05-05', 5000, 'Shopping'), // refund only: net negative, never proposed
    ct('2026-07-05', -99000, 'Groceries'), // the month itself is left out
    ct('2026-06-15', 150000, 'Salary'), // income is no spending
    row('2026-06-11', -999999, 'Groceries', currency: 'USD'), // foreign rows are left out
    ct('2026-06-13', -77000, 'Groceries', deleted: true),
  ];

  BudgetPreset preset(BudgetPresetKind k, List<CategorizedTx> txs,
          {WalletSettings s = st, CategoryTable? t, List<Goal> goals = const []}) =>
      budgetPreset(k, txs, s, _month, currency: 'EUR', table: t, goals: goals);

  group('averages', () {
    test('avg3, avg6 and avg12 round the exact average UP to 1000 cents', () {
      final a3 = preset(BudgetPresetKind.avg3, history);
      expect(a3.budgets, {'Groceries': 11000, 'Eating out': 4000});
      expect(a3.total, 15000);
      expect(a3.empty, isNull);
      expect(preset(BudgetPresetKind.avg6, history).budgets, {'Groceries': 9000, 'Eating out': 3000, 'Rent': 50000});
      final a12 = preset(BudgetPresetKind.avg12, history);
      expect(a12.budgets, {'Groceries': 6000, 'Eating out': 2000, 'Rent': 25000});
      expect(a12.total, 33000);
    });

    test('avg6 equals suggestBudgets', () {
      final p = preset(BudgetPresetKind.avg6, history);
      expect(p.budgets, suggestBudgets(history, _month, currency: 'EUR'));
      // The exact sum is rounded, not the average to the cent: 6001 / 6 = 1000.17 cents -> 2000, not 1000.
      final odd = [ct('2026-03-10', -6001, 'Cash')];
      expect(preset(BudgetPresetKind.avg6, odd).budgets, suggestBudgets(odd, _month, currency: 'EUR'));
      expect(preset(BudgetPresetKind.avg6, odd).budgets, {'Cash': 2000});
    });

    test('foreign rows, deleted rows and the month itself do not count', () {
      expect(preset(BudgetPresetKind.avg6, history).budgets['Groceries'], 9000);
      final usd = budgetPreset(BudgetPresetKind.avg6, history, st, _month, currency: 'USD');
      expect(usd.budgets, {'Groceries': 167000});
    });

    test('no spending gives an empty preset with a reason', () {
      for (final (k, months) in [
        (BudgetPresetKind.avg3, 3),
        (BudgetPresetKind.avg6, 6),
        (BudgetPresetKind.avg12, 12),
      ]) {
        final p = preset(k, const []);
        expect(p.budgets, isEmpty);
        expect(p.total, 0);
        expect(p.empty, 'No spending in the last $months months.');
      }
      // History older than the window is no history for avg3; the month itself is no history.
      expect(preset(BudgetPresetKind.avg3, [ct('2025-10-10', -5000, 'Groceries')]).empty, isNotNull);
      expect(preset(BudgetPresetKind.avg6, [ct('2026-07-10', -5000, 'Groceries')]).budgets, isEmpty);
    });

    test('a custom category is proposed under its own id', () {
      final rows = [row('2026-06-10', -24000, _kPets, table: table)];
      expect(preset(BudgetPresetKind.avg6, rows, t: table).budgets, {_kPets: 4000});
    });
  });

  group('spendLess', () {
    test('90 % of the exact 6-month average, rounded DOWN to 1000 cents', () {
      final p = preset(BudgetPresetKind.spendLess, history);
      // Groceries 51000 * 0.9 / 6 = 7650 -> 7000; Eating out 18000 * 0.9 / 6 = 2700 -> 2000; Rent 300000 -> 45000.
      expect(p.budgets, {'Groceries': 7000, 'Eating out': 2000, 'Rent': 45000});
      expect(p.total, 54000);
    });

    test('a category that rounds to 0 is dropped', () {
      // 6000 over 6 months: 900 per month -> 0.
      final p = preset(BudgetPresetKind.spendLess, [ct('2026-06-10', -6000, 'Cash'), ct('2026-06-11', -60000, 'Shopping')]);
      expect(p.budgets, {'Shopping': 9000});
      expect(preset(BudgetPresetKind.spendLess, [ct('2026-06-10', -6000, 'Cash')]).empty, 'No spending in the last 6 months.');
    });

    test('exact integer boundary', () {
      // 66667 * 9 / 60 = 10000.05 -> 10000; 66666 * 9 / 60 = 9999.9 -> 9000.
      expect(preset(BudgetPresetKind.spendLess, [ct('2026-06-10', -66667, 'Cash')]).budgets, {'Cash': 10000});
      expect(preset(BudgetPresetKind.spendLess, [ct('2026-06-10', -66666, 'Cash')]).budgets, {'Cash': 9000});
    });

    test('no history', () {
      final p = preset(BudgetPresetKind.spendLess, const []);
      expect(p.budgets, isEmpty);
      expect(p.total, 0);
      expect(p.empty, 'No spending in the last 6 months.');
    });
  });

  group('monthlyFlex', () {
    test('salary minus rent, loan, subs, plan lines and goals', () {
      expect(monthlyFlex(st), 125000);
      final goals = [const Goal(id: 'g1', name: 'A', monthly: 10000), const Goal(id: 'g2', name: 'B', monthly: 2500)];
      expect(monthlyFlex(st, goals: goals), 112500);
      const withLine = WalletSettings(
          salary: 200000, rent: 50000, loan: 20000, subs: 5000, currency: 'EUR', planLines: {_kInsurance: 3000, 'kdead00000000': 9999});
      // Only the live custom fixed category's line counts; with the built-in table there is none.
      expect(monthlyFlex(withLine, table: table), 122000);
      expect(monthlyFlex(withLine), 125000);
      expect(monthlyFlex(withLine, goals: goals, table: table), 109500);
    });

    test('never below 0', () {
      expect(monthlyFlex(const WalletSettings(salary: 100000, rent: 90000, loan: 20000)), 0);
      expect(monthlyFlex(emptySalary), 0);
      expect(monthlyFlex(st, goals: [const Goal(id: 'g', name: 'Big', monthly: 999999)]), 0);
    });
  });

  group('fitPlan', () {
    test('splits the flex money over flex categories by 6-month share, exactly', () {
      final goals = [const Goal(id: 'g1', name: 'A', monthly: 10000)];
      final p = preset(BudgetPresetKind.fitPlan, history, goals: goals);
      // 125000 - 10000 = 115000 -> 1150 EUR over Groceries 51000 and Eating out 18000 (Rent is fixed, left out).
      expect(p.total, 115000);
      expect(_sum(p.budgets), 115000);
      // 1150 * 51000 / 69000 = 850 exactly.
      expect(p.budgets, {'Groceries': 85000, 'Eating out': 30000});
    });

    test('largest remainder: parts sum exactly to the whole euros of the flex money', () {
      const s = WalletSettings(salary: 200000, rent: 50000, loan: 20000, subs: 5000, currency: 'EUR', planLines: {_kInsurance: 15000});
      final p = preset(BudgetPresetKind.fitPlan, history, s: s, t: table);
      // 1100 EUR: 1100 * 51000 / 69000 = 813.04, 1100 * 18000 / 69000 = 286.96: Eating out has the larger remainder.
      expect(p.budgets, {'Groceries': 81300, 'Eating out': 28700});
      expect(p.total, 110000);
    });

    test('the flex money is floored to whole euros', () {
      const s = WalletSettings(salary: 200099, rent: 50000, loan: 20000, subs: 5000, currency: 'EUR');
      final p = preset(BudgetPresetKind.fitPlan, history, s: s);
      expect(monthlyFlex(s), 125099);
      expect(p.total, 125000);
      expect(_sum(p.budgets), 125000);
    });

    test('ties go to the earlier category of the table, deterministically', () {
      List<CategorizedTx> equal(List<String> cats) => [for (final c in cats) ct('2026-06-10', -60000, c)];
      WalletSettings flex(int cents) => WalletSettings(salary: cents, currency: 'EUR');
      final cats = ['Eating out', 'Groceries', 'Food delivery']; // row order must not matter
      // 100 EUR over 3 equal categories: 33 each, 1 left -> Groceries (first in the table).
      var p = preset(BudgetPresetKind.fitPlan, equal(cats), s: flex(10000));
      expect(p.budgets, {'Groceries': 3400, 'Food delivery': 3300, 'Eating out': 3300});
      expect(p.total, 10000);
      // 101 EUR: two extra euros go to the first two.
      p = preset(BudgetPresetKind.fitPlan, equal(cats), s: flex(10100));
      expect(p.budgets, {'Groceries': 3400, 'Food delivery': 3400, 'Eating out': 3300});
      expect(p.total, 10100);
      expect(preset(BudgetPresetKind.fitPlan, equal(cats.reversed.toList()), s: flex(10100)).budgets, p.budgets);
    });

    test('awkward remainders always sum to the total', () {
      final cats = ['Groceries', 'Food delivery', 'Eating out', 'Shopping', 'Cash', 'Bank fees', 'To people'];
      final rows = [
        for (var i = 0; i < cats.length; i++) ct('2026-06-10', -(1234 + i * 777), cats[i]),
      ];
      for (final euros in [1, 2, 7, 99, 100, 101, 1234, 99999]) {
        final p = preset(BudgetPresetKind.fitPlan, rows, s: WalletSettings(salary: euros * 100 + 99, currency: 'EUR'));
        expect(p.total, euros * 100, reason: '$euros');
        expect(_sum(p.budgets), euros * 100, reason: '$euros');
        expect(p.budgets.values.every((v) => v > 0 && v % 100 == 0), isTrue, reason: '$euros');
      }
    });

    test('a category whose share is below one euro is dropped but the total stays exact', () {
      final rows = [ct('2026-06-10', -1000000, 'Groceries'), ct('2026-06-10', -100, 'Cash')];
      final p = preset(BudgetPresetKind.fitPlan, rows, s: const WalletSettings(salary: 5000, currency: 'EUR'));
      expect(p.budgets, {'Groceries': 5000});
      expect(p.total, 5000);
    });

    test('only flex categories get money; custom flex included, custom fixed left out', () {
      final rows = [
        row('2026-06-10', -30000, 'Groceries', table: table),
        row('2026-06-10', -30000, _kPets, table: table),
        row('2026-06-10', -90000, _kInsurance, table: table),
        ct('2026-06-10', -90000, 'Rent'),
        ct('2026-06-10', -90000, 'Bills & subscriptions'),
      ];
      final p = preset(BudgetPresetKind.fitPlan, rows, t: table);
      expect(p.budgets, {'Groceries': 62500, _kPets: 62500});
      expect(p.total, 125000);
    });

    test('salary 0 asks for the salary', () {
      final p = preset(BudgetPresetKind.fitPlan, history, s: emptySalary);
      expect(p.budgets, isEmpty);
      expect(p.total, 0);
      expect(p.empty, 'Set your salary in the payday plan first.');
    });

    test('no history gives a reason', () {
      final p = preset(BudgetPresetKind.fitPlan, const []);
      expect(p.budgets, isEmpty);
      expect(p.total, 0);
      expect(p.empty, 'No spending in the last 6 months.');
    });

    test('history without flex spending gives a reason', () {
      final p = preset(BudgetPresetKind.fitPlan, [ct('2026-06-10', -50000, 'Rent')]);
      expect(p.budgets, isEmpty);
      expect(p.empty, 'No flexible spending in the last 6 months.');
    });

    test('nothing left after fixed costs and goals gives a reason, never a negative budget', () {
      const s = WalletSettings(salary: 100000, rent: 90000, loan: 20000, currency: 'EUR');
      final p = preset(BudgetPresetKind.fitPlan, history, s: s);
      expect(p.budgets, isEmpty);
      expect(p.total, 0);
      expect(p.empty, isNotNull);
    });

    test('foreign rows are ignored', () {
      final rows = [ct('2026-06-10', -20000, 'Groceries'), row('2026-06-10', -980000, 'Eating out', currency: 'USD')];
      expect(preset(BudgetPresetKind.fitPlan, rows).budgets.keys, ['Groceries']);
    });
  });

  group('fiftyThirtyTwenty', () {
    test('30 % of the salary in whole euros, split by flex share', () {
      final p = preset(BudgetPresetKind.fiftyThirtyTwenty, history);
      // 600 EUR over 51000 : 18000 -> 443.48 and 156.52: the extra euro goes to Eating out.
      expect(p.total, 60000);
      expect(p.budgets, {'Groceries': 44300, 'Eating out': 15700});
    });

    test('the 30 % is floored to whole euros', () {
      const s = WalletSettings(salary: 333333, currency: 'EUR'); // 99999.9 cents -> 999 EUR
      final p = preset(BudgetPresetKind.fiftyThirtyTwenty, history, s: s);
      expect(p.total, 99900);
      expect(_sum(p.budgets), 99900);
    });

    test('ignores rent, loan, subs and goals', () {
      final goals = [const Goal(id: 'g', name: 'G', monthly: 999999)];
      expect(preset(BudgetPresetKind.fiftyThirtyTwenty, history, goals: goals).total, 60000);
    });

    test('salary 0 and no history give reasons', () {
      expect(preset(BudgetPresetKind.fiftyThirtyTwenty, history, s: emptySalary).empty, 'Set your salary in the payday plan first.');
      final p = preset(BudgetPresetKind.fiftyThirtyTwenty, const []);
      expect(p.budgets, isEmpty);
      expect(p.empty, 'No spending in the last 6 months.');
    });

    test('ties and a custom flex category', () {
      final rows = [row('2026-06-10', -50000, 'Groceries', table: table), row('2026-06-10', -50000, _kPets, table: table)];
      // Salary 3367 EUR -> 30 % = 1010.1 -> 1010 EUR: 505 each.
      final even = preset(BudgetPresetKind.fiftyThirtyTwenty, rows, s: const WalletSettings(salary: 336700, currency: 'EUR'), t: table);
      expect(even.budgets, {'Groceries': 50500, _kPets: 50500});
      // Salary 3350 EUR -> 1005 EUR: 502 each, the extra euro goes to Groceries (built-in first).
      final tie = preset(BudgetPresetKind.fiftyThirtyTwenty, rows, s: const WalletSettings(salary: 335000, currency: 'EUR'), t: table);
      expect(tie.budgets, {'Groceries': 50300, _kPets: 50200});
      expect(tie.total, 100500);
    });
  });
}
