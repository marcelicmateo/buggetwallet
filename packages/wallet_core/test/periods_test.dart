// Saving or losing per pay period (M3): periodSummaries, PeriodSummary, trendNet.
// All data here is synthetic. Expected values are worked out by hand from the feature spec.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

/// A comparable view of a period.
Map<String, Object?> view(PeriodSummary p) => {
      'start': p.start,
      'end': p.end,
      'income': p.income,
      'out': p.out,
      'byCategory': p.byCategory,
      'running': p.running,
    };

Map<String, Object?> period(String start, String end,
        {int income = 0, int out = 0, Map<String, int> byCategory = const {}, bool running = false}) =>
    {
      'start': start,
      'end': end,
      'income': income,
      'out': out,
      'byCategory': byCategory,
      'running': running,
    };

List<Map<String, Object?>> views(List<PeriodSummary> ps) => ps.map(view).toList();

List<String> starts(List<PeriodSummary> ps) => ps.map((p) => p.start).toList();

/// A period with a given net (income 1000 cents, out = 1000 − net).
PeriodSummary withNet(String start, int net, {bool running = false}) =>
    PeriodSummary(start: start, end: '', income: 1000, out: 1000 - net, byCategory: const {}, running: running);

void main() {
  const st = WalletSettings(); // paydayDay 15, no periodStart

  group('periodSummaries: totals', () {
    // Salary in three parts (10th, 12th, 14th Sep) = one payday 2026-09-10; October in two parts = payday 2026-10-11.
    final txs = [
      ct('2026-08-30', -1111, 'Groceries'), // before the first payday: no period
      ct('2026-09-10', 100000, 'Salary'),
      ct('2026-09-12', 50000, 'Salary'),
      ct('2026-09-14', 25000, 'Salary'),
      ct('2026-09-10', -40000, 'Rent'),
      ct('2026-09-15', -3000, 'Groceries'),
      ct('2026-09-18', -9999, 'Shopping', deleted: true), // not live
      ct('2026-09-19', -3000, 'Groceries', manual: true, matchedTo: 'bank-row'), // replaced by a bank row: not live
      ct('2026-09-20', -2000, 'Groceries'),
      ct('2026-09-22', 500, 'Groceries'), // refund lowers out
      ct('2026-09-25', -20000, 'Internal transfer'), // PBZ -> Revolut top-up
      ct('2026-09-27', 30000, 'Loan received'), // transfer kind: not income
      ct('2026-09-28', 12000, 'Extra income'), // extras are income
      ct('2026-10-10', -1500, 'Eating out'), // last day of the first period
      ct('2026-10-11', 100000, 'Salary'),
      ct('2026-10-12', -1299, 'Bills & subscriptions'),
      ct('2026-10-14', 60000, 'Salary'),
      ct('2026-10-16', -800, 'Groceries'), // today counts
      ct('2026-10-17', -5000, 'Groceries'), // after today: ignored
    ];
    final expected = [
      // income 100000+50000+25000+12000; out 40000+3000+2000−500+1500
      period('2026-09-10', '2026-10-11', income: 187000, out: 46000, byCategory: {'Rent': 40000, 'Groceries': 4500, 'Eating out': 1500}),
      // running: end = nextPayday(2026-10-11, 15)
      period('2026-10-11', '2026-11-15',
          income: 160000, out: 2099, byCategory: {'Bills & subscriptions': 1299, 'Groceries': 800}, running: true),
    ];

    test('salary parts, transfers, extras, refunds, non-live and future rows', () {
      expect(views(periodSummaries(txs, st, '2026-10-16')), expected);
    });

    test('input order does not matter (sync can deliver rows in any order)', () {
      expect(views(periodSummaries(txs.reversed.toList(), st, '2026-10-16')), expected);
      final shuffled = [...txs]..shuffle(Random(42));
      expect(views(periodSummaries(shuffled, st, '2026-10-16')), expected);
    });

    test('net and savings rate of the computed periods', () {
      final ps = periodSummaries(txs, st, '2026-10-16');
      expect(ps[0].net, 141000);
      expect(ps[0].savingsRate, closeTo(141000 / 187000, 1e-9));
      expect(ps[1].net, 157901);
    });
  });

  group('periodSummaries: paydays', () {
    test('a part more than 20 days after the payday START begins a new payday, even if close to the previous part', () {
      final txs = [
        ct('2026-03-10', 1000, 'Salary'),
        ct('2026-03-25', 1000, 'Salary'), // 15 days after 03-10: same payday
        ct('2026-04-05', 1000, 'Salary'), // 26 days after 03-10 (11 after 03-25): new payday
      ];
      expect(views(periodSummaries(txs, st, '2026-04-20')), [
        period('2026-03-10', '2026-04-05', income: 2000),
        period('2026-04-05', '2026-05-15', income: 1000, running: true),
      ]);
    });

    test('exactly 20 days after the payday start is still the same payday', () {
      final txs = [ct('2026-03-10', 1000, 'Salary'), ct('2026-03-30', 1000, 'Salary')];
      expect(views(periodSummaries(txs, st, '2026-04-08')), [
        period('2026-03-10', '2026-04-15', income: 2000, running: true),
      ]);
    });

    test('21 days after the payday start is a new payday', () {
      final txs = [ct('2026-03-10', 1000, 'Salary'), ct('2026-03-31', 1000, 'Salary')];
      expect(views(periodSummaries(txs, st, '2026-04-08')), [
        period('2026-03-10', '2026-03-31', income: 1000),
        period('2026-03-31', '2026-04-15', income: 1000, running: true),
      ]);
    });

    test('extras and transfers never create a payday', () {
      final txs = [
        ct('2026-09-10', 1000, 'Salary'),
        ct('2026-10-05', 5000, 'Extra income'), // 25 days later, but not salary
        ct('2026-10-06', 50000, 'Loan received'), // transfer
        ct('2026-10-07', 7000, 'Internal transfer'),
      ];
      expect(views(periodSummaries(txs, st, '2026-10-12')), [
        period('2026-09-10', '2026-10-15', income: 6000, running: true),
      ]);
    });

    test('deleted or matched salary rows do not create a payday or count as income', () {
      final txs = [
        ct('2026-09-10', 1000, 'Salary'),
        ct('2026-10-02', 2000, 'Salary', deleted: true), // 22 days later, but deleted
        ct('2026-10-03', 3000, 'Salary', manual: true, matchedTo: 'bank-row'), // replaced
      ];
      expect(views(periodSummaries(txs, st, '2026-10-12')), [
        period('2026-09-10', '2026-10-15', income: 1000, running: true),
      ]);
    });

    test('salary dated after today is ignored', () {
      final txs = [ct('2026-09-10', 1000, 'Salary'), ct('2026-10-20', 1000, 'Salary')];
      expect(views(periodSummaries(txs, st, '2026-10-14')), [
        period('2026-09-10', '2026-10-15', income: 1000, running: true),
      ]);
    });

    test('salary landing today starts the running period', () {
      final txs = [
        ct('2026-09-14', 1000, 'Salary'),
        ct('2026-10-15', -300, 'Groceries'),
        ct('2026-10-16', 1500, 'Salary'),
        ct('2026-10-16', -200, 'Groceries'),
      ];
      expect(views(periodSummaries(txs, st, '2026-10-16')), [
        period('2026-09-14', '2026-10-16', income: 1000, out: 300, byCategory: {'Groceries': 300}),
        period('2026-10-16', '2026-11-15', income: 1500, out: 200, byCategory: {'Groceries': 200}, running: true),
      ]);
    });
  });

  group('periodSummaries: missing salary', () {
    test('no salary for >45 days up to today: payday assumed on paydayDay, clamped (31 -> 30 Sep)', () {
      const st31 = WalletSettings(paydayDay: 31);
      final txs = [
        ct('2026-08-12', 200000, 'Salary'),
        ct('2026-09-29', -1000, 'Groceries'),
        ct('2026-09-30', -2000, 'Groceries'),
        ct('2026-10-05', -40000, 'Rent'),
      ];
      // 2026-08-12 -> today 2026-10-16 is 65 days. Assumed: 2026-09-30 (Sep has 30 days); 2026-10-31 is after today.
      final ps = periodSummaries(txs, st31, '2026-10-16');
      expect(views(ps), [
        period('2026-08-12', '2026-09-30', income: 200000, out: 1000, byCategory: {'Groceries': 1000}),
        period('2026-09-30', '2026-10-31', out: 42000, byCategory: {'Groceries': 2000, 'Rent': 40000}, running: true),
      ]);
      expect(ps.last.net, -42000);
      expect(ps.last.savingsRate, isNull);
    });

    test('missing salary between two real paydays: assumed payday on paydayDay, clamped (29 -> 28 Feb)', () {
      const st29 = WalletSettings(paydayDay: 29);
      final txs = [
        ct('2026-01-05', 1000, 'Salary'),
        ct('2026-02-27', -100, 'Groceries'),
        ct('2026-02-28', -200, 'Groceries'),
        ct('2026-03-25', 3000, 'Salary'), // 79 days after 01-05
      ];
      // RX7d/RX7e: 5 Jan is December's salary (29 Dec, exactly 7 days late), so assumed 2026-01-29 and 2026-02-28
      // (before RX7d 2026-02-28 only); 2026-03-29 comes after the real 03-25 payday (its early salary), so not assumed.
      expect(views(periodSummaries(txs, st29, '2026-04-01')), [
        period('2026-01-05', '2026-01-29', income: 1000),
        period('2026-01-29', '2026-02-28', out: 100, byCategory: {'Groceries': 100}),
        period('2026-02-28', '2026-03-25', out: 200, byCategory: {'Groceries': 200}),
        period('2026-03-25', '2026-04-29', income: 3000, running: true),
      ]);
    });

    test('typical missing June salary: June period starts on paydayDay of the month after the last payday', () {
      // Reading of the spec: "assumed on paydayDay of each following month" = each month after the last payday's
      // month, once the gap exceeds 45 days (05-12 -> 07-13 is 62 days), so 2026-06-15 is assumed.
      final txs = [
        ct('2026-05-12', 1000, 'Salary'),
        ct('2026-06-14', -100, 'Groceries'),
        ct('2026-06-15', -200, 'Groceries'),
        ct('2026-07-13', 1000, 'Salary'),
      ];
      expect(views(periodSummaries(txs, st, '2026-07-20')), [
        period('2026-05-12', '2026-06-15', income: 1000, out: 100, byCategory: {'Groceries': 100}),
        period('2026-06-15', '2026-07-13', out: 200, byCategory: {'Groceries': 200}),
        period('2026-07-13', '2026-08-15', income: 1000, running: true),
      ]);
    });

    test('no assumed payday a few days before a late real salary (paydayDay 10, salary on the 13th)', () {
      const st10 = WalletSettings(paydayDay: 10);
      final txs = [
        ct('2026-08-12', 1000, 'Salary'),
        ct('2026-09-20', -100, 'Groceries'),
        ct('2026-10-11', -200, 'Groceries'),
        ct('2026-10-13', 3000, 'Salary'), // September's salary is missing; October's is 3 days late
      ];
      // 09-10 is assumed (33 days before 10-13); 10-10 is not (only 3 days before the real 10-13 payday).
      expect(views(periodSummaries(txs, st10, '2026-10-20')), [
        period('2026-08-12', '2026-09-10', income: 1000),
        period('2026-09-10', '2026-10-13', out: 300, byCategory: {'Groceries': 300}),
        period('2026-10-13', '2026-11-10', income: 3000, running: true),
      ]);
    });

    test('a 45-day gap is not missing salary', () {
      final txs = [ct('2026-03-01', 1000, 'Salary'), ct('2026-04-15', 1000, 'Salary')]; // exactly 45 days
      expect(starts(periodSummaries(txs, st, '2026-04-20')), ['2026-03-01', '2026-04-15']);
    });
  });

  group('periodSummaries: periodStart', () {
    final txs = [
      ct('2026-09-14', 1000, 'Salary'),
      ct('2026-10-11', -300, 'Groceries'),
      ct('2026-10-12', -400, 'Groceries'),
    ];

    test('periodStart >20 days after the last payday starts the current period before salary import', () {
      const s = WalletSettings(periodStart: '2026-10-12'); // 28 days after 09-14
      expect(views(periodSummaries(txs, s, '2026-10-13')), [
        period('2026-09-14', '2026-10-12', income: 1000, out: 300, byCategory: {'Groceries': 300}),
        period('2026-10-12', '2026-11-15', out: 400, byCategory: {'Groceries': 400}, running: true),
      ]);
    });

    test('periodStart within 20 days of the last payday is not a new payday', () {
      const s = WalletSettings(periodStart: '2026-09-30'); // 16 days after 09-14
      expect(views(periodSummaries(txs, s, '2026-10-13')), [
        period('2026-09-14', '2026-10-15', income: 1000, out: 700, byCategory: {'Groceries': 700}, running: true),
      ]);
    });

    test('periodStart after today is ignored', () {
      const s = WalletSettings(periodStart: '2026-10-14');
      expect(starts(periodSummaries(txs, s, '2026-10-13')), ['2026-09-14']);
    });

    test('periodStart with no salary at all gives one running period from periodStart', () {
      const s = WalletSettings(periodStart: '2026-10-01');
      final only = [ct('2026-09-30', -100, 'Groceries'), ct('2026-10-02', -200, 'Groceries')];
      expect(views(periodSummaries(only, s, '2026-10-16')), [
        period('2026-10-01', '2026-11-15', out: 200, byCategory: {'Groceries': 200}, running: true),
      ]);
    });
  });

  group('periodSummaries: list shape', () {
    test('no salary and no periodStart: empty list', () {
      expect(periodSummaries(const [], st, '2026-10-16'), isEmpty);
      final noSalary = [
        ct('2026-09-01', -500, 'Groceries'),
        ct('2026-09-15', 5000, 'Extra income'),
        ct('2026-10-01', 20000, 'Internal transfer'),
      ];
      expect(periodSummaries(noSalary, st, '2026-10-16'), isEmpty);
    });

    final monthly = [
      for (final m in ['01', '02', '03', '04', '05']) ct('2026-$m-12', 1000, 'Salary'),
    ];

    test('running only on the last period; each end is the next start', () {
      final ps = periodSummaries(monthly, st, '2026-05-20');
      expect(starts(ps), ['2026-01-12', '2026-02-12', '2026-03-12', '2026-04-12', '2026-05-12']);
      expect(ps.map((p) => p.running).toList(), [false, false, false, false, true]);
      expect(ps.map((p) => p.end).toList(), ['2026-02-12', '2026-03-12', '2026-04-12', '2026-05-12', '2026-06-15']);
    });

    test('count keeps the newest periods', () {
      final ps = periodSummaries(monthly, st, '2026-05-20', count: 3);
      expect(starts(ps), ['2026-03-12', '2026-04-12', '2026-05-12']);
      expect(ps.map((p) => p.running).toList(), [false, false, true]);
      expect(ps.first.end, '2026-04-12');
    });

    test('default count is 12', () {
      final txs = [
        for (var k = 0; k < 14; k++) ct('${2025 + (k ~/ 12)}-${((k % 12) + 1).toString().padLeft(2, '0')}-12', 1000, 'Salary'),
      ]; // 2025-01-12 .. 2026-02-12
      final ps = periodSummaries(txs, st, '2026-02-20');
      expect(ps.length, 12);
      expect(ps.first.start, '2025-03-12');
      expect(ps.last.start, '2026-02-12');
      expect(ps.last.running, isTrue);
    });
  });

  group('PeriodSummary', () {
    test('net and savingsRate', () {
      const saving = PeriodSummary(start: '2026-01-12', end: '2026-02-12', income: 2000, out: 500, byCategory: {}, running: false);
      expect(saving.net, 1500);
      expect(saving.savingsRate, closeTo(0.75, 1e-12));

      const losing = PeriodSummary(start: '2026-01-12', end: '2026-02-12', income: 1000, out: 1500, byCategory: {}, running: false);
      expect(losing.net, -500);
      expect(losing.savingsRate, closeTo(-0.5, 1e-12));

      const noIncome = PeriodSummary(start: '2026-01-12', end: '2026-02-12', income: 0, out: 500, byCategory: {}, running: false);
      expect(noIncome.net, -500);
      expect(noIncome.savingsRate, isNull);

      const nothing = PeriodSummary(start: '2026-01-12', end: '2026-02-12', income: 0, out: 0, byCategory: {}, running: false);
      expect(nothing.savingsRate, isNull);
    });
  });

  group('trendNet', () {
    final ps = [
      withNet('2026-01-12', 100),
      withNet('2026-02-12', 200),
      withNet('2026-03-12', 301),
      withNet('2026-04-12', -400),
      withNet('2026-05-12', 50),
      withNet('2026-06-12', -153),
      withNet('2026-07-12', 999, running: true),
    ];

    test('window 3: nulls until 3 completed periods, rounded averages, null for the running period', () {
      // 601/3=200.33→200; 101/3=33.67→34; −49/3=−16.33→−16; −503/3=−167.67→−168
      expect(trendNet(ps, window: 3), [null, null, 200, 34, -16, -168, null]);
    });

    test('default window is 3', () {
      expect(trendNet(ps), trendNet(ps, window: 3));
    });

    test('window 1 is each completed net', () {
      expect(trendNet(ps, window: 1), [100, 200, 301, -400, 50, -153, null]);
    });

    test('fewer completed periods than the window: all null', () {
      expect(trendNet(ps.sublist(4), window: 3), [null, null, null]);
      expect(trendNet(const [], window: 3), isEmpty);
    });
  });
}
