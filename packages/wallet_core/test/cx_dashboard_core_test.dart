// Stage CX core: BudgetVsActual.budgetedActual, PeriodBudget.planSplit and the fast planRecurringPayments (pinned equal
// to the matching of every row it replaced). All payees, amounts and dates are SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/src/recurring.dart' show incomeFits;
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart' show bigWalletRows;

var _seq = 0;

Tx _tx(String date, int cents, {String desc = 'POS ZORBLEX 0001 ZAGREB', String? id, String currency = 'EUR'}) => Tx(
    id: id ?? 'cx-${(_seq++).toString().padLeft(6, '0')}', source: 'pbz', date: date, amount: cents, currency: currency, description: desc);

CategorizedTx _cat(Tx t, String category) => CategorizedTx(t, category, kindOf(category));

/// The planRecurringPayments of v2 868e6c7 (every row keyed by payee), kept to prove the fast one returns the same.
RecurringPayments _legacyPlan(List<RecurringBill> bills, List<Tx> rows, {required String currency}) {
  final byPayee = <String, List<Tx>>{};
  final inByPayee = <String, List<Tx>>{};
  final dateOf = <String, String>{};
  for (final t in rows) {
    dateOf[t.id] = t.date;
    if (!t.live || t.manual || t.amount == 0 || t.date.length != 10 || t.currency != currency) continue;
    ((t.amount < 0 ? byPayee : inByPayee)[merchantKey(t)] ??= []).add(t);
  }
  final paid = <String, Tx>{};
  final parts = <String, List<Tx>>{};
  final inParts = <String>{};
  for (final b in bills) {
    if (!b.confirmed || b.payee.isEmpty || b.nextDue.length != 10 || b.expectedAmount <= 0 || b.finished) continue;
    final income = b.isIncome;
    final mine = (income ? inByPayee : byPayee)[b.payee];
    if (mine == null) continue;
    final tol = b.tolerance;
    Tx? best;
    var bestDays = 0;
    for (final t in mine) {
      if (t.id == b.lastPaidTx || !incomeFits(b, income ? t.amount : -t.amount)) continue;
      final days = daysBetween(b.nextDue, t.date).abs();
      if (days > tol) continue;
      if (best == null ||
          days < bestDays ||
          (days == bestDays && (t.date.compareTo(best.date) < 0 || (t.date == best.date && t.id.compareTo(best.id) < 0)))) {
        best = t;
        bestDays = days;
      }
    }
    if (best != null) {
      paid[b.id] = best;
      continue;
    }
    if (income) continue;
    final from = addDays(b.nextDue, -(b.manual || b.hasRange ? partsDays(b) : tol)), to = addDays(b.nextDue, tol);
    final after = b.lastPaidTx == null ? null : dateOf[b.lastPaidTx];
    final counted = [
      for (final t in mine)
        if (t.id != b.lastPaidTx &&
            -t.amount <= b.reserveAmount &&
            t.date.compareTo(from) >= 0 &&
            t.date.compareTo(to) <= 0 &&
            (after == null || t.date.compareTo(after) > 0))
          t
    ]..sort((x, y) {
        final d = x.date.compareTo(y.date);
        return d != 0 ? d : x.id.compareTo(y.id);
      });
    if (counted.isEmpty) continue;
    final threshold = partsThreshold(b);
    var sum = 0;
    Tx? completing;
    for (var i = 0; i < counted.length; i++) {
      sum -= counted[i].amount;
      if (i >= 1 && sum >= threshold) {
        completing = counted[i];
        break;
      }
    }
    if (completing != null) {
      paid[b.id] = completing;
      inParts.add(b.id);
    } else {
      parts[b.id] = List.unmodifiable(counted);
    }
  }
  return RecurringPayments(paid, parts: parts, paidInParts: inParts);
}

/// A comparable picture of a result: ids only.
Map<String, Object> _shape(RecurringPayments p) => {
      'paidBy': {for (final e in p.paidBy.entries) e.key: e.value.id},
      'parts': {
        for (final e in p.parts.entries) e.key: [for (final t in e.value) t.id]
      },
      'inParts': p.paidInParts.toList()..sort(),
    };

const _payeeNames = ['ZORBLEX', 'QUORVANT', 'BLIMMET', 'FRASKO', 'TELVANO', 'MURLIX'];
String _desc(int i) => 'POS ${_payeeNames[i]} 00${i}1 ZAGREB';
final _payees = [for (var i = 0; i < _payeeNames.length; i++) merchantKey(_tx('2026-01-01', -1, desc: _desc(i)))];

/// A seeded random wallet: rows of a few payees around many due dates (both directions, refunds, parts, other
/// currencies, deleted and hand-added rows, odd dates) and bills of every period class, ranges, instalments, incomes,
/// manual bills and odd states.
({List<RecurringBill> bills, List<Tx> rows}) _randomWallet(int seed) {
  final r = Random(seed);
  const base = '2025-06-01';
  final rows = <Tx>[];
  final n = 150 + r.nextInt(400);
  for (var i = 0; i < n; i++) {
    final p = r.nextInt(_payeeNames.length);
    final date = addDays(base, r.nextInt(500));
    final magnitude = [5000, 2500, 4800, 5400, 1200, 9000, 100 + r.nextInt(20000)][r.nextInt(7)];
    final sign = r.nextInt(6) == 0 ? 1 : -1;
    final odd = r.nextInt(40);
    rows.add(Tx(
      id: 'r${r.nextInt(n * 2).toString().padLeft(5, '0')}', // duplicate ids on purpose
      source: odd == 0 ? 'manual' : 'pbz',
      manual: odd == 0,
      date: odd == 1 ? '2025-7-1' : (odd == 2 ? '' : date),
      amount: odd == 3 ? 0 : sign * magnitude,
      currency: odd == 4 ? 'USD' : 'EUR',
      description: _desc(p),
      deleted: odd == 5,
    ));
  }
  const intervals = [7, 14, 20, 30, 31, 28, 91, 365, 45];
  final bills = <RecurringBill>[];
  final nb = 1 + r.nextInt(12);
  for (var i = 0; i < nb; i++) {
    final interval = intervals[r.nextInt(intervals.length)];
    final expected = [5000, 2500, 1200, 9000, 0][r.nextInt(5)];
    final ranged = r.nextInt(4) == 0;
    final income = r.nextInt(5) == 0;
    final payee = switch (r.nextInt(10)) { 0 => '', 1 => 'nobody_pays', _ => _payees[r.nextInt(_payees.length)] };
    final due = r.nextInt(30) == 0 ? '2025-13-45' : addDays(base, r.nextInt(520) - 10);
    bills.add(RecurringBill(
      id: 'rec:cx-$seed-$i',
      payee: payee,
      label: 'Synthetic $i',
      category: 'Bills & subscriptions',
      expectedAmount: expected,
      intervalDays: interval,
      nextDue: due,
      status: r.nextInt(6) == 0 ? 'candidate' : 'confirmed',
      lastPaidTx: r.nextBool() && rows.isNotEmpty ? rows[r.nextInt(rows.length)].id : (r.nextInt(8) == 0 ? 'gone' : null),
      minAmount: ranged ? 2000 : null,
      maxAmount: ranged ? 6000 : null,
      endsOn: r.nextInt(5) == 0 ? addDays(base, r.nextInt(500)) : null,
      manual: r.nextInt(3) == 0,
      direction: income ? RecurringBill.directionIn : null,
    ));
  }
  return (bills: bills, rows: rows);
}

/// Median ms of [runs] calls of [f] after two warm-up calls.
double _medianMs(void Function() f, {int runs = 7}) {
  f();
  f();
  final ms = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    f();
    ms.add(sw.elapsedMicroseconds / 1000);
  }
  ms.sort();
  return ms[runs ~/ 2];
}

void main() {
  group('BudgetVsActual.budgetedActual', () {
    const month = '2026-03', today = '2026-03-20';
    final txs = [
      _cat(_tx('2026-03-02', -30000, desc: 'POS LIDL ZAGREB'), 'Groceries'), // budget 25000: over
      _cat(_tx('2026-03-03', -6400, desc: 'POS MCDONALDS ZAGREB'), 'Eating out'), // budget 15000: under
      _cat(_tx('2026-03-04', -2000, desc: 'POS ZARA ZAGREB'), 'Shopping'), // budget 0: over a zero budget
      _cat(_tx('2026-03-05', -9900, desc: 'POS STEAM GAMES'), 'Games & apps'), // no budget: left out
    ];

    test('Σ actual of the budgeted lines = budgetTotal − remainingTotal (over, under, zero, no budget)', () {
      final b = budgetVsActual(txs, month, const {'Groceries': 25000, 'Eating out': 15000, 'Shopping': 0, 'Car & transport': 4000},
          today: today, currency: 'EUR');
      expect(b.budgetedActual, 30000 + 6400 + 2000); // Car & transport budgeted with nothing spent counts 0
      expect(b.budgetedActual, b.budgetTotal - b.remainingTotal!);
      expect(b.actualTotal - b.budgetedActual, 9900); // the unbudgeted line
    });

    test('only an over line, only an under line', () {
      for (final budgets in const [
        {'Groceries': 10000},
        {'Eating out': 99000},
      ]) {
        final b = budgetVsActual(txs, month, budgets, today: today, currency: 'EUR');
        expect(b.budgetedActual, b.budgetTotal - b.remainingTotal!);
        expect(b.budgetedActual, b.lines.firstWhere((l) => l.budget != null).actual);
      }
    });

    test('nothing budgeted: 0, remainingTotal null', () {
      final b = budgetVsActual(txs, month, const {}, today: today, currency: 'EUR');
      expect((b.budgetedActual, b.remainingTotal, b.budgetedCount), (0, null, 0));
    });

    test('a budget with no spend at all: 0', () {
      final b = budgetVsActual(const [], month, const {'Groceries': 25000}, today: today, currency: 'EUR');
      expect((b.budgetedActual, b.remainingTotal), (0, 25000));
    });
  });

  group('PeriodBudget.planSplit', () {
    // Period 2026-02-15 .. 2026-03-15, today 2026-03-01.
    const today = '2026-03-01';
    final goals = [const Goal(id: 'g1', name: 'Synthetic goal', monthly: 10000)];
    final flexBill = RecurringBill(
        id: 'rec:cx-flex',
        payee: _payees[1],
        label: 'Synthetic club',
        category: 'Shopping',
        expectedAmount: 4000,
        nextDue: '2026-03-05',
        status: 'confirmed');
    const planned = [PlannedCost(id: 'p-cx', title: 'Synthetic gift', date: '2026-03-08', amount: 6000, category: 'Shopping')];
    final income = RecurringBill(
        id: RecurringBill.incomeIdFor(_payees[2]),
        payee: _payees[2],
        label: 'Synthetic gig',
        category: 'Extra income',
        expectedAmount: 25000,
        nextDue: '2026-03-20',
        status: 'confirmed',
        direction: RecurringBill.directionIn);
    WalletSettings settings(int salary, {String incomeMode = 'planned'}) => WalletSettings.fromMap({
          'salary': salary,
          'rent': 50000,
          'loan': 20000,
          'subs': 3000,
          'periodStart': '2026-02-15',
          'paydayDay': 15,
          'incomeMode': incomeMode,
        });
    PeriodBudget period(WalletSettings st, List<CategorizedTx> txs, {List<RecurringBill>? bills}) =>
        computePeriod(txs, st, goals, today, bills: bills ?? [flexBill, income], planned: planned, table: CategoryTable.builtIn);

    void holds(PeriodBudget p) {
      final s = p.planSplit;
      expect(s.fixed + s.saved + s.spending - s.over, s.inTotal);
      expect(s.inTotal, p.income + p.landedIncome);
      expect(s.fixed, p.fixedPlan + p.beforePayday);
      expect(s.saved, p.goalMonthly);
      expect(s.spending - s.over, p.flexBudget);
      expect(s.spending >= 0 && s.over >= 0 && (s.spending == 0 || s.over == 0), isTrue);
    }

    test('an ordinary period: fixed lines + before payday, goals, the flexible money', () {
      final p = period(settings(200000), const []);
      expect(p.planSplit, const PlanSplit(inTotal: 200000, fixed: 73000 + 4000 + 6000, saved: 10000, spending: 107000, over: 0));
      holds(p);
    });

    test('landed extra income is in the money in and in the spending slice', () {
      final landed = _cat(_tx('2026-02-20', 25000, desc: _desc(2)), 'Extra income');
      final p = period(settings(200000), [landed]);
      expect(p.landedIncome, 25000);
      expect(p.planSplit, const PlanSplit(inTotal: 225000, fixed: 83000, saved: 10000, spending: 132000, over: 0));
      holds(p);
    });

    test('over the plan: the spending slice is 0 and over is the shortfall', () {
      final p = period(settings(80000), const []);
      expect(p.flexBudget, -13000);
      expect(p.planSplit, const PlanSplit(inTotal: 80000, fixed: 83000, saved: 10000, spending: 0, over: 13000));
      holds(p);
    });

    test('exactly on the money: spending 0 and over 0', () {
      final p = period(settings(93000), const []);
      expect(p.planSplit, const PlanSplit(inTotal: 93000, fixed: 83000, saved: 10000, spending: 0, over: 0));
      holds(p);
    });

    test('zero salary: everything planned is over', () {
      final p = period(settings(0), const [], bills: const []);
      expect(p.planSplit, const PlanSplit(inTotal: 0, fixed: 73000 + 6000, saved: 10000, spending: 0, over: 89000));
      holds(p);
    });

    test('received mode counts the salary rows that came in', () {
      final salary = _cat(_tx('2026-02-16', 150000, desc: 'Neto placa'), 'Salary');
      final p = period(settings(200000, incomeMode: 'received'), [salary]);
      expect(p.income, 150000);
      expect(p.planSplit, const PlanSplit(inTotal: 150000, fixed: 83000, saved: 10000, spending: 57000, over: 0));
      holds(p);
      // Received mode with a refund of the extra income: landed never goes below 0.
      final refund = _cat(_tx('2026-02-21', -3000, desc: _desc(2)), 'Extra income');
      holds(period(settings(200000, incomeMode: 'received'), [salary, refund]));
    });

    test('a bill in a fixed category is not reserved twice', () {
      final rentBill = RecurringBill(
          id: 'rec:cx-fixed',
          payee: _payees[3],
          label: 'Synthetic rent',
          category: 'Bills & subscriptions',
          expectedAmount: 3000,
          nextDue: '2026-03-04',
          status: 'confirmed');
      final p = period(settings(200000), const [], bills: [rentBill]);
      expect(p.planSplit.fixed, 73000 + 6000);
      holds(p);
    });
  });

  group('goalTotals', () {
    test('no goals: zeros', () {
      expect(goalTotals(const []), const GoalTotals(saved: 0, target: 0, count: 0));
    });

    test('plain sums; a negative saved total and a target of 0 count as they are', () {
      const goals = [
        Goal(id: 'g1', name: 'Synthetic A', target: 100000, saved: 25000),
        Goal(id: 'g2', name: 'Synthetic B', target: 0, saved: 4000),
        Goal(id: 'g3', name: 'Synthetic C', target: 30000, saved: -1500),
      ];
      expect(goalTotals(goals), const GoalTotals(saved: 27500, target: 130000, count: 3));
      // The fold the app used before.
      expect(goalTotals(goals).saved, goals.fold<int>(0, (a, g) => a + g.saved));
    });

    test('from the repo: a deleted goal and its contributions are left out; a goal at the cap counts in full', () {
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      final a = repo.saveGoal(name: 'Synthetic A', target: 50000, saved: 10000, monthly: 0);
      final b = repo.saveGoal(name: 'Synthetic B', target: 20000, saved: 3000, monthly: 0);
      final big = repo.saveGoal(name: 'Synthetic C', target: 0, saved: Goal.maxSaved, monthly: 0);
      repo.addGoalContribution(a, 2500);
      repo.addGoalContribution(b, 7000);
      expect(() => repo.addGoalContribution(big, 1), throwsArgumentError); // the repo keeps a total within the cap
      repo.deleteGoal(b);
      expect(goalTotals(repo.goals()), const GoalTotals(saved: 12500 + Goal.maxSaved, target: 50000, count: 2));
    });
  });

  group('planRecurringPayments (fast) = matching every row', () {
    test('seeded random wallets', () {
      var paidSeen = 0, partsSeen = 0, inPartsSeen = 0;
      for (var seed = 0; seed < 400; seed++) {
        final w = _randomWallet(seed);
        Object? run(RecurringPayments Function() f) {
          try {
            return _shape(f());
          } catch (e) {
            return e.runtimeType;
          }
        }

        final want = run(() => _legacyPlan(w.bills, w.rows, currency: 'EUR'));
        final got = run(() => planRecurringPayments(w.bills, w.rows, currency: 'EUR'));
        expect(got, want, reason: 'seed $seed');
        if (want
            case {'paidBy': final Map<String, String> p, 'parts': final Map<String, List<String>> q, 'inParts': final List<String> s}) {
          paidSeen += p.length;
          partsSeen += q.length;
          inPartsSeen += s.length;
        }
      }
      // The wallets do reach every path.
      expect(paidSeen, greaterThan(50));
      expect(partsSeen, greaterThan(20));
      expect(inPartsSeen, greaterThan(5));
    });

    test('a bill with no rows near its due date, and no confirmed bill at all', () {
      final rows = [_tx('2026-01-05', -5000), _tx('2026-03-05', -5000)];
      final bill = RecurringBill(
          id: 'rec:cx-far',
          payee: _payees[0],
          label: 'Synthetic',
          category: 'Shopping',
          expectedAmount: 5000,
          nextDue: '2026-02-05',
          status: 'confirmed');
      expect(planRecurringPayments([bill], rows, currency: 'EUR').isEmpty, isTrue);
      expect(_shape(planRecurringPayments([bill], rows, currency: 'EUR')), _shape(_legacyPlan([bill], rows, currency: 'EUR')));
      expect(planRecurringPayments(const [], rows, currency: 'EUR').isEmpty, isTrue);
    });

    test('20k rows: the same as before and < 50 ms (measured 3–5 ms, was 83–175 ms)', () {
      const today = '2026-10-25';
      final rows = wholePayments(bigWalletRows(today, days: 2000, perDay: 10));
      expect(rows.length, greaterThan(19000));
      String keyOf(String desc) => merchantKey(_tx(today, -1, desc: desc));
      RecurringBill bill(String id, String desc, int cents, String nextDue,
              {int interval = 30, int? min, int? max, bool manual = false, String? direction, String category = 'Shopping'}) =>
          RecurringBill(
              id: id,
              payee: keyOf(desc),
              label: 'Synthetic $id',
              category: category,
              expectedAmount: cents,
              intervalDays: interval,
              nextDue: nextDue,
              status: 'confirmed',
              minAmount: min,
              maxAmount: max,
              manual: manual,
              direction: direction);
      final bills = [
        bill('rec:netflix', 'POS NETFLIX.COM', 1299, '2026-11-05', category: 'Bills & subscriptions'),
        bill('rec:lidl', 'POS LIDL HRVATSKA ZAGREB', 3000, '2026-10-24', interval: 7, min: 1000, max: 8000, manual: true),
        bill('rec:konzum', 'POS KONZUM 0000 ZAGREB', 4000, '2026-10-20', interval: 14),
        bill('rec:ikea', 'POS IKEA ZAGREB', 6000, '2026-10-10', interval: 91, manual: true),
        bill('rec:steam', 'POS STEAM GAMES', 5000, '2026-09-30', interval: 365, min: 2000, max: 8000),
        bill('rec:loan', 'Naplata kredita 0000000000', 25000, '2026-10-18', category: 'Loan'),
        bill('recin:salary', 'Neto placa dio 2', 40000, '2026-10-13', direction: RecurringBill.directionIn, category: 'Extra income'),
      ];
      expect(_shape(planRecurringPayments(bills, rows, currency: 'EUR')), _shape(_legacyPlan(bills, rows, currency: 'EUR')));
      final before = _medianMs(() => _legacyPlan(bills, rows, currency: 'EUR'), runs: 3);
      final after = _medianMs(() => planRecurringPayments(bills, rows, currency: 'EUR'));
      // ignore: avoid_print
      print('planRecurringPayments 20k rows: before ${before.toStringAsFixed(1)} ms, after ${after.toStringAsFixed(1)} ms');
      expect(after, lessThan(50));
    });
  });
}
