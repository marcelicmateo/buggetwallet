// H2: payday passed, over budget, salary in parts, low income and the payday clamp. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

void main() {
  const st = WalletSettings(salary: 200000, rent: 50000, periodStart: '2026-03-15', paydayDay: 15);

  group('payday passed', () {
    test('rows on or after the payday are not counted in the ended period (spending and income)', () {
      const rcv = WalletSettings(salary: 200000, rent: 50000, periodStart: '2026-03-15', paydayDay: 15, incomeMode: 'received');
      final rows = [
        ct('2026-03-15', 200000, 'Salary'),
        ct('2026-04-14', -1000, 'Groceries'), // the period's last day: counted
        ct('2026-04-15', 210000, 'Salary'), // the next payday: next period
        ct('2026-04-16', -5000, 'Groceries'), // next period
      ];
      final p = computePeriod(rows, rcv, const [], '2026-04-20');
      expect(p.paydayPassed, isTrue);
      expect((p.received, p.spent, p.remaining), (200000, 1000, 150000 - 1000));
      expect(p.overBy, 0);
    });

    test('currentPeriodStart moves over several missed paydays in one step', () {
      expect(currentPeriodStart('2026-07-01', 1, '2026-10-20'), '2026-10-01');
      expect(currentPeriodStart('2026-07-01', 1, '2026-07-31'), '2026-07-01');
      expect(currentPeriodStart('2026-07-01', 1, '2026-08-01'), '2026-08-01');
      expect(currentPeriodStart('2026-01-31', 31, '2026-03-30'), '2026-02-28');
      // Each step is nextPayday from the step before: Feb 28 → Mar 31 is still ahead of Mar 30.
    });

    final txs = [ct('2026-03-15', 200000, 'Salary'), ct('2026-03-20', -3000, 'Groceries')];

    test('the day before payday has one day left', () {
      final p = computePeriod(txs, st, const [], '2026-04-14');
      expect((p.end, p.daysLeft, p.paydayPassed), ('2026-04-15', 1, false));
      expect(p.allowanceToday, 150000 - 3000);
    });

    for (final today in ['2026-04-15', '2026-04-16', '2026-05-30']) {
      test('on or after payday ($today): daysLeft 0, flagged, allowance 0 and never negative', () {
        final p = computePeriod([...txs, ct(today, -700, 'Groceries')], st, const [], today);
        expect((p.daysLeft, p.paydayPassed), (0, true));
        expect(p.allowanceToday, 0);
        // Today's row is dated on or after the payday: it belongs to the next period, not to the one that ended.
        expect((p.spent, p.spentToday, p.safeToday, p.overToday), (3000, 0, 0, 0));
        expect(p.length, greaterThan(0));
        expect(affordability(100, p).verdict, Verdict.later);
        expect(affordability(100, p).newDaily, 0);
      });
    }

    test('a period whose start is today has its whole length left', () {
      final p = computePeriod(const [], st, const [], '2026-03-15');
      expect((p.daysLeft, p.length, p.paydayPassed), (31, 31, false));
    });
  });

  group('over budget', () {
    test('spending past the flexible money: overBy, allowance 0, verdict overBudget', () {
      final txs = [ct('2026-03-15', 200000, 'Salary'), ct('2026-03-16', -150500, 'Groceries')];
      final p = computePeriod(txs, st, const [], '2026-03-20');
      expect(p.flexBudget, 150000);
      expect((p.remaining, p.overBy), (-500, 500));
      expect(p.allowanceToday, 0);
      expect(p.overBudget, isTrue);
      expect(affordability(0, p).verdict, Verdict.overBudget);
      expect(affordability(1, p).newDaily, 0);
    });

    test('today over its allowance, the period not: overToday only', () {
      final txs = [ct('2026-03-20', -10000, 'Groceries')];
      final p = computePeriod(txs, st, const [], '2026-03-20');
      expect(p.allowanceToday, (150000 / 26).round());
      expect(p.overToday, 10000 - p.allowanceToday);
      expect((p.overBy, p.overBudget), (0, false));
    });

    for (final (name, rent) in [('negative', 260000), ('zero', 200000)]) {
      test('planDaily $name (fixed costs eat the salary): overBudget, never now', () {
        final s = WalletSettings(salary: 200000, rent: rent, periodStart: '2026-03-15', paydayDay: 15);
        final p = computePeriod(const [], s, const [], '2026-03-20');
        expect(p.planDaily, lessThanOrEqualTo(0));
        expect(p.allowanceToday, 0);
        expect(p.overBudget, isTrue);
        for (final price in [0, 1, 100000]) {
          expect(affordability(price, p).verdict, Verdict.overBudget, reason: '$price');
        }
      });
    }

    test('verdicts below the line: now, tight and later', () {
      final p = computePeriod(const [], st, const [], '2026-03-15'); // 150000 over 31 days
      expect(affordability(1000, p).verdict, Verdict.now);
      expect(affordability(100000, p).verdict, Verdict.tight);
      expect(affordability(150000, p).verdict, Verdict.later);
      expect(affordability(150000, p).newDaily, 0);
    });
  });

  group('salary in parts (incomeMode received)', () {
    const rs = WalletSettings(salary: 200000, periodStart: '2026-03-10', paydayDay: 10, incomeMode: 'received');
    final first = ct('2026-03-10', 120000, 'Salary');

    test('samePaydayDays is a week', () => expect(samePaydayDays, 7));

    test('within the window a part short of the salary counts as the salary', () {
      for (var age = 0; age < samePaydayDays; age++) {
        final today = addDays('2026-03-10', age);
        final p = computePeriod([first], rs, const [], today);
        expect((p.received, p.income, p.lowIncome), (120000, 200000, false), reason: today);
      }
    });

    test('the second part inside the window: received is the whole salary', () {
      final p = computePeriod([first, ct('2026-03-15', 80000, 'Salary')], rs, const [], '2026-03-15');
      expect((p.received, p.income, p.lowIncome), (200000, 200000, false));
    });

    test('more than the salary in the window counts what came', () {
      final p = computePeriod([first, ct('2026-03-11', 100000, 'Salary')], rs, const [], '2026-03-12');
      expect(p.income, 220000);
    });

    test('after the window without the second part: received only, low income', () {
      final today = addDays('2026-03-10', samePaydayDays);
      final p = computePeriod([first], rs, const [], today);
      expect((p.received, p.income, p.lowIncome), (120000, 120000, true));
    });

    test('the second part after the window ends the low income', () {
      final p = computePeriod([first, ct('2026-03-19', 80000, 'Salary')], rs, const [], '2026-03-20');
      expect((p.income, p.lowIncome), (200000, false));
    });

    test('nothing received yet: the planned salary, not low', () {
      final p = computePeriod(const [], rs, const [], '2026-03-25');
      expect((p.received, p.income, p.lowIncome), (0, 200000, false));
    });
  });

  group('lowIncome (moved from the app)', () {
    test('planned mode, days 4 to 6: a short salary is not low yet (parts still landing); day 7 it is', () {
      for (var age = 4; age <= 7; age++) {
        final today = addDays('2026-03-15', age);
        final p = computePeriod([ct('2026-03-15', 120000, 'Salary')], st, const [], today);
        expect(st.incomeMode, 'planned');
        expect((p.income, p.lowIncome), (200000, age >= samePaydayDays), reason: today);
      }
    });

    test('90 % of the salary is not low, one cent less is', () {
      for (final (cents, low) in [(180000, false), (179999, true)]) {
        final p = computePeriod([ct('2026-03-15', cents, 'Salary')], st, const [], '2026-03-25');
        expect(p.lowIncome, low, reason: '$cents');
      }
    });

    test('no salary set: never low', () {
      const none = WalletSettings(periodStart: '2026-03-15', paydayDay: 15);
      expect(computePeriod([ct('2026-03-15', 1000, 'Salary')], none, const [], '2026-03-30').lowIncome, isFalse);
    });
  });

  group('payday clamp (WalletSettings validation)', () {
    test('29..31 read as 28; 1..28 kept; 0 and 32 fall back to 15', () {
      for (final (v, want) in [(1, 1), (28, 28), (29, 28), (31, 28), (0, 15), (32, 15)]) {
        expect(WalletSettings.fromMap({'paydayDay': v}).paydayDay, want, reason: '$v');
      }
    });

    test('a stored 31 gives periods ending on the 28th', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.updateSettings({'paydayDay': 31, 'periodStart': '2026-01-28'});
      final p = computePeriod(const [], r.settings(), const [], '2026-02-01');
      expect(p.end, '2026-02-28');
    });
  });
}
