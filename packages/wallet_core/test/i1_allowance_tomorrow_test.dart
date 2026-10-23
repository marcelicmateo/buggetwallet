// Stage I (IC): PeriodBudget.allowanceTomorrow = max(0, round((flexBudget - spent) / (daysLeft - 1))) while daysLeft > 1,
// null when the payday is tomorrow or has passed. Expected values worked out by hand. All data is SYNTHETIC.
//
// The API does not exist on v2 yet: the whole file is skipped until the lead lifts the line below at merge.
library;

// ignore_for_file: undefined_getter
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _t = Timeout(Duration(seconds: 30));

var _n = 0;

CategorizedTx _row(String date, int cents, String category) => CategorizedTx(
      Tx(id: 'i1-${_n++}', source: 'pbz', date: date, amount: cents, description: 'Synthetic $category'),
      category,
      kindOf(category),
    );

// Salary 2000.00, rent 500, loan 200, subs 50: flexible money 1250.00 (125000) for 2026-01-15 .. 2026-02-15 (31 days).
const _st = WalletSettings(salary: 200000, rent: 50000, loan: 20000, subs: 5000, periodStart: '2026-01-15');

PeriodBudget _period(List<CategorizedTx> txs, String today, {WalletSettings st = _st}) => computePeriod(txs, st, const [], today);

void main() {
  group('allowanceTomorrow, hand-worked', () {
    test('a normal day: 21 days left on the 25th, 3000 spent -> (125000 - 3000) / 20 = 6100', () {
      final p = _period([_row('2026-01-20', -3000, 'Groceries')], '2026-01-25');
      expect(p.daysLeft, 21);
      expect(p.allowanceTomorrow, 6100);
    }, timeout: _t);

    test('today\'s spending is already off tomorrow\'s figure: 3000 + 2100 today -> (125000 - 5100) / 20 = 5995', () {
      final p = _period([_row('2026-01-20', -3000, 'Groceries'), _row('2026-01-25', -2100, 'Groceries')], '2026-01-25');
      expect(p.allowanceTomorrow, 5995);
    }, timeout: _t);

    test('first day, nothing spent: 125000 / 30 = 4166.67 rounds to 4167', () {
      final p = _period(const [], '2026-01-15');
      expect((p.daysLeft, p.allowanceTomorrow), (31, 4167));
    }, timeout: _t);

    test('rounding half up and down: 121990 / 20 = 6099.5 -> 6100, 121989 / 20 = 6099.45 -> 6099', () {
      expect(_period([_row('2026-01-20', -3010, 'Groceries')], '2026-01-25').allowanceTomorrow, 6100);
      expect(_period([_row('2026-01-20', -3011, 'Groceries')], '2026-01-25').allowanceTomorrow, 6099);
    }, timeout: _t);

    test('two days left: tomorrow is the last day, the whole rest of the money / 1', () {
      final p = _period([_row('2026-02-01', -25000, 'Groceries')], '2026-02-13');
      expect(p.daysLeft, 2);
      expect(p.allowanceTomorrow, 100000);
    }, timeout: _t);

    test('payday tomorrow (daysLeft 1): null, a new period starts', () {
      final p = _period([_row('2026-01-20', -3000, 'Groceries')], '2026-02-14');
      expect(p.daysLeft, 1);
      expect(p.allowanceTomorrow, isNull);
    }, timeout: _t);

    test('payday today or passed: null (daysLeft 0, paydayPassed)', () {
      for (final today in ['2026-02-15', '2026-02-16', '2026-03-10']) {
        final p = _period([_row('2026-01-20', -3000, 'Groceries')], today);
        expect(p.paydayPassed, isTrue, reason: today);
        expect(p.allowanceTomorrow, isNull, reason: today);
      }
    }, timeout: _t);

    test('over budget: 0, never negative, never null while days are left', () {
      final p = _period([_row('2026-01-20', -130000, 'Groceries')], '2026-01-25');
      expect(p.remaining, lessThan(0));
      expect(p.allowanceTomorrow, 0);
      // exactly used up: also 0
      expect(_period([_row('2026-01-20', -125000, 'Groceries')], '2026-01-25').allowanceTomorrow, 0);
    }, timeout: _t);

    test('a plan with no spending money at all (fixed costs above salary): 0', () {
      const st = WalletSettings(salary: 100000, rent: 90000, loan: 30000, periodStart: '2026-01-15');
      final p = _period(const [], '2026-01-25', st: st);
      expect(p.flexBudget, lessThan(0));
      expect(p.allowanceTomorrow, 0);
    }, timeout: _t);
  });

  group('allowanceTomorrow, property over random wallets (fixed seeds)', () {
    for (final seed in [11, 23, 47, 101]) {
      test('seed $seed: equals the formula and tomorrow\'s own allowance, never negative', () {
        final r = Random(seed);
        for (var i = 0; i < 60; i++) {
          final salary = 100000 + r.nextInt(300000);
          final st = WalletSettings(
              salary: salary, rent: r.nextInt(salary ~/ 3), loan: r.nextInt(30000), subs: r.nextInt(10000), periodStart: '2026-01-15');
          final txs = [
            for (var k = 0; k < r.nextInt(25); k++)
              _row(addDays('2026-01-15', r.nextInt(31)), -(100 + r.nextInt(r.nextBool() ? 20000 : 90000)),
                  ['Groceries', 'Eating out', 'Transport'][r.nextInt(3)]),
          ];
          final today = addDays('2026-01-15', r.nextInt(34)); // some days past the payday
          final p = _period(txs, today);
          final ctx = 'seed $seed #$i today $today';
          if (p.paydayPassed || p.daysLeft <= 1) {
            expect(p.allowanceTomorrow, isNull, reason: ctx);
            continue;
          }
          final a = p.allowanceTomorrow!;
          expect(a, greaterThanOrEqualTo(0), reason: ctx);
          expect(a, max(0, ((p.flexBudget - p.spent) / (p.daysLeft - 1)).round()), reason: ctx);
          // Tomorrow, with nothing more spent today, is the same wallet one day on: its allowance is the figure.
          final tomorrow = _period(txs, addDays(today, 1));
          expect(a, tomorrow.allowanceToday, reason: ctx);
        }
      }, timeout: _t);
    }
  });
}
