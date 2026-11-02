// PS payday auto-save (docs/context/PS_SPEC.md): pay rows once per period, skip/lower, take out, and the period
// budget fed with this period's amounts. All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _start = '2026-01-15', _today = '2026-01-20';

void _plan(WalletRepo r) => r.updateSettings({'salary': 200000, 'periodStart': _start, 'paydayDay': 15});

/// The period budget as the app computes it: this period's goal amounts and the money taken out into it.
PeriodBudget _period(WalletRepo r, {String today = _today}) {
  final p = computePeriod(const [], r.settings(), r.goals(), today, table: CategoryTable.builtIn);
  return computePeriod(const [], r.settings(), r.goals(), today,
      table: CategoryTable.builtIn, goalAmounts: r.goalPeriodAmounts(p.start), goalTakenOut: r.goalTakenOutBetween(p.start, p.end));
}

int _saved(WalletRepo r, String id) => r.goals().firstWhere((g) => g.id == id).saved;

void main() {
  group('PS core, one device', () {
    late WalletRepo r;
    setUp(() {
      r = WalletRepo.inMemory();
      _plan(r);
    });

    test('auto-pay writes one pay row per goal and period; monthly 0 writes none; a new goal mid-period is paid once', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      final zero = r.saveGoal(name: 'Z', target: 100000, saved: 0, monthly: 0, sort: 2);
      r.payGoals(period: _start);
      r.payGoals(period: _start);
      expect(_saved(r, a), 6000);
      expect(r.goalContributions(zero), isEmpty);
      expect(r.goalContributions(a).single.id, 'pay:$a:$_start');
      final b = r.saveGoal(name: 'B', target: 100000, saved: 0, monthly: 3000, sort: 3);
      r.payGoals(period: _start);
      r.payGoals(period: _start);
      expect((_saved(r, a), _saved(r, b)), (6000, 3000));
      expect(r.goalPeriodAmounts(_start), {a: 5000, zero: 0, b: 3000});
      expect(_period(r).goalMonthly, 8000);
      expect(_period(r).flexBudget, 200000 - 8000);
    });

    test('amounts before the pay row exists: monthly + adjustment; default computePeriod uses monthly', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 0, monthly: 5000, sort: 1);
      expect(r.goalPeriodAmounts(_start), {a: 5000});
      expect(computePeriod(const [], r.settings(), r.goals(), _today, table: CategoryTable.builtIn).goalMonthly, 5000);
    });

    test('skip and lower: the total and the spending money move by exactly the difference; lower twice, last wins', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      r.payGoals(period: _start);
      final flex0 = _period(r).flexBudget;
      r.setGoalPeriodAmount(a, _start, 2000);
      expect(_saved(r, a), 3000);
      expect(_period(r).flexBudget, flex0 + 3000);
      r.setGoalPeriodAmount(a, _start, 0);
      expect(_saved(r, a), 1000);
      expect(_period(r).flexBudget, flex0 + 5000);
      expect(_period(r).goalMonthly, 0);
      r.setGoalPeriodAmount(a, _start, 7000);
      expect(_saved(r, a), 8000);
      expect(_period(r).flexBudget, flex0 - 2000);
      r.setGoalPeriodAmount(a, _start, 5000);
      expect(_saved(r, a), 6000);
      expect(r.goalContributions(a).map((c) => (c.id, c.amount)), contains(('adj:$a:$_start', 0)));
      expect(_period(r).flexBudget, flex0);
    });

    test('setGoalPeriodAmount before the auto-pay writes the pay row first; the auto-pay then adds nothing', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 0, monthly: 5000, sort: 1);
      r.setGoalPeriodAmount(a, _start, 1500);
      r.payGoals(period: _start);
      expect(_saved(r, a), 1500);
      expect(r.goalPeriodAmounts(_start), {a: 1500});
    });

    test('setGoalPeriodAmount refuses a negative or too large amount, an unknown or deleted goal, a total below 0', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 0, monthly: 5000, sort: 1);
      r.payGoals(period: _start);
      r.takeOutOfGoal(a, 4000, date: _today);
      expect(() => r.setGoalPeriodAmount(a, _start, -1), throwsArgumentError);
      expect(() => r.setGoalPeriodAmount(a, _start, Goal.maxContribution + 1), throwsArgumentError);
      expect(() => r.setGoalPeriodAmount('nope', _start, 0), throwsArgumentError);
      expect(() => r.setGoalPeriodAmount(a, _start, 0), throwsArgumentError, reason: '1000 left, skip takes 5000');
      r.setGoalPeriodAmount(a, _start, 4000); // exactly to 0
      expect(_saved(r, a), 0);
      r.deleteGoal(a);
      expect(() => r.setGoalPeriodAmount(a, _start, 0), throwsArgumentError);
    });

    test('take out to spending: that period +X, total −X; outside the period it does not count', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 10000, monthly: 0, sort: 1);
      final flex0 = _period(r).flexBudget;
      r.takeOutOfGoal(a, 2500, date: _today);
      r.takeOutOfGoal(a, 1000, date: '2026-02-15'); // next period
      expect(_saved(r, a), 6500);
      final p = _period(r);
      expect(p.goalTakenOut, 2500);
      expect(p.flexBudget, flex0 + 2500);
      final s = p.planSplit;
      expect(s.fixed + s.saved + s.spending - s.over, s.inTotal);
      expect(r.goalTakenOutBetween('2026-02-15', '2026-03-15'), 1000);
    });

    test('move to another goal: totals shift, spending money unchanged', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 10000, monthly: 0, sort: 1);
      final b = r.saveGoal(name: 'B', target: 100000, saved: 0, monthly: 0, sort: 2);
      final flex0 = _period(r).flexBudget;
      final id = r.takeOutOfGoal(a, 4000, date: _today, toGoalId: b);
      expect(id, startsWith('mv:'));
      expect((_saved(r, a), _saved(r, b)), (6000, 4000));
      expect(r.goalContributions(b).single.id, '$id:in');
      expect(_period(r).flexBudget, flex0);
      expect(r.goalTakenOutBetween(_start, '2026-02-15'), 0);
    });

    test('take out refuses more than saved, 0 or less, a bad date, unknown/deleted goals and the same goal', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 3000, monthly: 0, sort: 1);
      final gone = r.saveGoal(name: 'G', target: 100000, saved: 0, monthly: 0, sort: 2);
      r.deleteGoal(gone);
      final before = r.pendingOps().length;
      expect(() => r.takeOutOfGoal(a, 3001, date: _today), throwsArgumentError);
      expect(() => r.takeOutOfGoal(a, 0, date: _today), throwsArgumentError);
      expect(() => r.takeOutOfGoal(a, -5, date: _today), throwsArgumentError);
      expect(() => r.takeOutOfGoal(a, 100, date: '2026-1-5'), throwsArgumentError);
      expect(() => r.takeOutOfGoal('nope', 100, date: _today), throwsArgumentError);
      expect(() => r.takeOutOfGoal(gone, 100, date: _today), throwsArgumentError);
      expect(() => r.takeOutOfGoal(a, 100, date: _today, toGoalId: gone), throwsArgumentError);
      expect(() => r.takeOutOfGoal(a, 100, date: _today, toGoalId: a), throwsArgumentError);
      expect(r.pendingOps().length, before);
      r.takeOutOfGoal(a, 3000, date: _today);
      expect(_saved(r, a), 0);
    });

    test('periodDays takes the same goal params: each judged day equals computePeriod for that day', () {
      final a = r.saveGoal(name: 'A', target: 100000, saved: 10000, monthly: 5000, sort: 1);
      r.payGoals(period: _start);
      r.setGoalPeriodAmount(a, _start, 1000);
      r.takeOutOfGoal(a, 2000, date: _start);
      final amounts = r.goalPeriodAmounts(_start), out = r.goalTakenOutBetween(_start, '2026-02-15');
      expect(r.goalTakenOutByDate(_start, '2026-02-15'), {_start: 2000});
      final days = periodDays(const [], r.settings(), r.goals(), _today,
          table: CategoryTable.builtIn, goalAmounts: amounts, goalTakenOutByDate: r.goalTakenOutByDate(_start, '2026-02-15'));
      for (final d in days.where((d) => d.date.compareTo(_today) < 0)) {
        final p =
            computePeriod(const [], r.settings(), r.goals(), d.date, table: CategoryTable.builtIn, goalAmounts: amounts, goalTakenOut: out);
        expect(d.allowance, p.allowanceToday, reason: d.date);
      }
      expect(days.first.allowance, ((200000 - 1000 + 2000) / 31).round());
    });

    test('logs carry no amounts or goal names, only the enum words', () {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = was;
      });
      final a = r.saveGoal(name: 'Synthetic secret fund', target: 9876543, saved: 1234567, monthly: 7654321, sort: 1);
      final b = r.saveGoal(name: 'Other secret', target: 1, saved: 0, monthly: 0, sort: 2);
      r.payGoals(period: _start);
      r.setGoalPeriodAmount(a, _start, 0);
      r.takeOutOfGoal(a, 345678, date: _today);
      r.takeOutOfGoal(a, 456789, date: _today, toGoalId: b);
      final text = lines.join('\n');
      expect(text, contains('goal.periodAmount'));
      expect(text, contains('goal.takeOut'));
      for (final s in ['secret', '1234567', '7654321', '345678', '456789', '3456.78', '4567.89']) {
        expect(text, isNot(contains(s)), reason: s);
      }
    });
  });

  group('PS review fixes: a period start that moves within one period', () {
    late WalletRepo r;
    late String a;
    setUp(() {
      r = WalletRepo.inMemory();
      a = r.saveGoal(name: 'A', target: 100000, saved: 1000, monthly: 5000, sort: 1);
    });

    for (final (first, second) in [('2026-11-12', '2026-11-10'), ('2026-11-10', '2026-11-12')]) {
      test('salary parts in either order: start $first then $second pays once', () {
        r.payGoals(period: first);
        r.payGoals(period: second);
        expect(_saved(r, a), 6000);
        expect(r.goalPeriodAmounts(second), {a: 5000});
        expect(r.goalPeriodAmounts(first), {a: 5000});
      });
    }

    for (final moved in ['2026-01-14', '2026-01-16']) {
      test('startNewMonth one day off ($moved): paid once; a skip set before the shift keeps working', () {
        r.payGoals(period: _start);
        r.setGoalPeriodAmount(a, _start, 0);
        r.payGoals(period: moved);
        expect(_saved(r, a), 1000);
        expect(r.goalPeriodAmounts(moved), {a: 0});
        r.setGoalPeriodAmount(a, moved, 2000); // lands on the same adj row: last wins
        expect(_saved(r, a), 3000);
        expect(r.goalPeriodAmounts(moved), {a: 2000});
        expect(r.goalContributions(a).map((c) => c.id), containsAll(['pay:$a:$_start', 'adj:$a:$_start']));
        expect(r.goalContributions(a).length, 2);
      });
    }

    test('the next period (a month on) is paid again', () {
      r.payGoals(period: _start);
      r.payGoals(period: '2026-02-15');
      expect(_saved(r, a), 11000);
      expect(r.goalPeriodAmounts('2026-02-15'), {a: 5000});
    });
  });

  test('PS review fix: periodDays adds a take-out only from its date on (an over day before it stays over)', () {
    const st = WalletSettings(salary: 310000, periodStart: _start, paydayDay: 15);
    final txs = [ct(_start, -11000, 'Groceries')];
    const out = {'2026-01-18': 50000};
    final days = periodDays(txs, st, const [], _today, table: CategoryTable.builtIn, goalTakenOutByDate: out);
    expect(days.first.mark, DayMark.over, reason: '10000 a day, 11000 spent');
    for (final d in days.where((d) => d.date.compareTo(_today) < 0)) {
      final p = computePeriod(txs, st, const [], d.date,
          table: CategoryTable.builtIn, goalTakenOut: d.date.compareTo('2026-01-18') >= 0 ? 50000 : 0);
      expect(d.allowance, p.allowanceToday, reason: d.date);
    }
  });

  group('PS core, two devices', () {
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
      tmp = Directory.systemTemp.createTempSync('bw-ps-');
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

    test('both devices auto-pay the same period offline: counted once', () async {
      final a = device('a'), b = device('b');
      _plan(a.repo);
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      await syncAll([a, b]);
      a.repo.payGoals(period: _start);
      now += 10;
      b.repo.payGoals(period: _start);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect(_saved(d.repo, id), 6000, reason: d.name);
        expect(_period(d.repo).flexBudget, 200000 - 5000, reason: d.name);
      }
    });

    test('a skip on one device is not undone by the other device paying later; two lowers: the last wins', () async {
      final a = device('a'), b = device('b');
      _plan(a.repo);
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      await syncAll([a, b]);
      a.repo.payGoals(period: _start);
      a.repo.setGoalPeriodAmount(id, _start, 0);
      await syncAll([a, b]);
      b.repo.payGoals(period: _start);
      await syncAll([a, b]);
      expect((_saved(a.repo, id), _saved(b.repo, id)), (1000, 1000));
      a.repo.setGoalPeriodAmount(id, _start, 2000);
      now += 10;
      b.repo.setGoalPeriodAmount(id, _start, 3000);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect(_saved(d.repo, id), 4000, reason: d.name);
        expect(d.repo.goalPeriodAmounts(_start), {id: 3000}, reason: d.name);
        expect(_period(d.repo).flexBudget, 200000 - 3000, reason: d.name);
      }
    });

    test('take out and move sync: spending money and totals equal on both devices', () async {
      final a = device('a'), b = device('b');
      _plan(a.repo);
      final g1 = a.repo.saveGoal(name: 'One', target: 100000, saved: 10000, monthly: 0, sort: 1);
      final g2 = a.repo.saveGoal(name: 'Two', target: 100000, saved: 0, monthly: 0, sort: 2);
      await syncAll([a, b]);
      a.repo.takeOutOfGoal(g1, 1500, date: _today);
      b.repo.takeOutOfGoal(g1, 2500, date: _today, toGoalId: g2);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect((_saved(d.repo, g1), _saved(d.repo, g2)), (6000, 2500), reason: d.name);
        expect(_period(d.repo).goalTakenOut, 1500, reason: d.name);
      }
    });
  });
}
