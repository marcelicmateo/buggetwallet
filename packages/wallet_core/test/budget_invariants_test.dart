// Property tests for the budget engine: pay periods, safe to spend, affordability and goals, on random SYNTHETIC
// wallets and random "today"s. Expected values come from brute-force sums written here, not from the implementation.
// Seeds are fixed; BW_FUZZ_ITERATIONS / BW_FUZZ_SEED run more or other wallets.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart' show fuzzIterations, fuzzSeed;
import 'support/synthetic.dart';

final _allCategories = categories.keys.toList();

/// A random wallet: salary most months (1-3 parts between the 10th and the 20th), random spending, refunds,
/// extras, transfers, deleted and matched rows.
({List<CategorizedTx> txs, String from, String to}) _wallet(Random r) {
  final from = ['2025-11-01', '2026-01-01', '2027-10-01', '2028-01-01', '2026-06-01'][r.nextInt(5)];
  final months = 2 + r.nextInt(20);
  final txs = <CategorizedTx>[];
  bool deleted() => r.nextInt(25) == 0;
  String? matched() => r.nextInt(30) == 0 ? 'bank-${r.nextInt(99)}' : null;
  var monthStart = from;
  for (var m = 0; m < months; m++) {
    if (r.nextInt(8) != 0) {
      var d = addDays(monthStart, 9 + r.nextInt(6));
      for (var k = 0, parts = 1 + r.nextInt(3); k < parts; k++) {
        txs.add(ct(d, 50000 + r.nextInt(100000), 'Salary', deleted: deleted()));
        d = addDays(d, 1 + r.nextInt(5));
      }
    }
    monthStart = '${nextPayday(monthStart, 1).substring(0, 8)}01';
  }
  final to = addDays(monthStart, -1);
  for (var d = from; d.compareTo(to) <= 0; d = addDays(d, 1)) {
    for (var k = r.nextInt(3); k > 0; k--) {
      final c = _allCategories[r.nextInt(_allCategories.length)];
      final kind = kindOf(c);
      final mag = 1 + r.nextInt(20000);
      final sign = switch (kind) {
        BudgetKind.income || BudgetKind.extra => 1,
        BudgetKind.transfer => r.nextBool() ? 1 : -1,
        _ => r.nextInt(12) == 0 ? 1 : -1, // refunds now and then
      };
      if (kind == BudgetKind.income && r.nextInt(3) != 0) continue; // salary mostly comes from the monthly parts above
      txs.add(ct(d, sign * mag, c, deleted: deleted(), matchedTo: matched()));
    }
  }
  return (txs: txs, from: from, to: to);
}

String _randomDay(Random r, String from, String to) => addDays(from, r.nextInt(daysBetween(from, to) + 60) - 15);

WalletSettings _settings(Random r, String from, String to) => WalletSettings(
      salary: r.nextInt(300000),
      rent: r.nextInt(80000),
      loan: r.nextInt(40000),
      subs: r.nextInt(5000),
      paydayDay: 1 + r.nextInt(31),
      periodStart: r.nextInt(3) == 0 ? null : _randomDay(r, from, to),
      incomeMode: r.nextBool() ? 'planned' : 'received',
    );

bool _in(String d, String from, String toIncl) => d.compareTo(from) >= 0 && d.compareTo(toIncl) <= 0;

Map<String, Object?> _view(PeriodSummary p) =>
    {'start': p.start, 'end': p.end, 'income': p.income, 'out': p.out, 'byCategory': p.byCategory, 'running': p.running};

void main() {
  final base = fuzzSeed(2026);
  final n = fuzzIterations(250);

  group('periodSummaries invariants on random wallets', () {
    test('contiguous, each live non-transfer row counted once, totals add up, transfers never count ($n wallets)', () {
      for (var i = 0; i < n; i++) {
        final seed = base + i;
        final r = Random(seed);
        final w = _wallet(r);
        final st = _settings(r, w.from, w.to);
        final today = _randomDay(r, w.from, w.to);
        final why = 'seed $seed today $today paydayDay ${st.paydayDay} periodStart ${st.periodStart}';
        final ps = periodSummaries(w.txs, st, today, count: 10000);

        final hasSalary = w.txs.any((t) => t.tx.live && t.kind == BudgetKind.income && t.amount > 0 && t.date.compareTo(today) <= 0);
        final hasStart = st.periodStart != null && st.periodStart!.compareTo(today) <= 0;
        expect(ps.isEmpty, !(hasSalary || hasStart), reason: why);
        if (ps.isEmpty) continue;

        for (var k = 0; k < ps.length; k++) {
          expect(ps[k].start.compareTo(today), lessThanOrEqualTo(0), reason: '$why: start after today');
          expect(ps[k].end.compareTo(ps[k].start), greaterThan(0), reason: '$why: empty period');
          expect(ps[k].running, k == ps.length - 1, reason: '$why: running flag');
          if (k + 1 < ps.length) expect(ps[k].end, ps[k + 1].start, reason: '$why: gap/overlap after ${ps[k].start}');
        }
        expect(ps.last.end, nextPayday(ps.last.start, st.paydayDay), reason: why);

        // Every real payday (first salary part) starts a period.
        for (final d in salaryPaydays(w.txs, today, currency: 'EUR')) {
          expect(ps.map((p) => p.start), contains(d), reason: '$why: payday $d');
        }

        // Brute force per period: live rows with start <= date < end (the running one: up to today).
        var totalIn = 0, totalOut = 0;
        for (var k = 0; k < ps.length; k++) {
          final p = ps[k];
          final lastDay = p.running ? today : addDays(p.end, -1);
          var inc = 0, out = 0;
          final byCat = <String, int>{};
          for (final t in w.txs) {
            if (!t.tx.live || !_in(t.date, p.start, lastDay)) continue;
            if (t.kind == BudgetKind.income || t.kind == BudgetKind.extra) inc += t.amount;
            if (t.kind == BudgetKind.fixed || t.kind == BudgetKind.flex) {
              out -= t.amount;
              byCat[t.category] = (byCat[t.category] ?? 0) - t.amount;
            }
          }
          expect((p.income, p.out), (inc, out), reason: '$why: period ${p.start}');
          expect(p.byCategory, byCat, reason: '$why: categories ${p.start}');
          totalIn += inc;
          totalOut += out;
        }
        // Totals over the whole range [first start, today]: every row in exactly one period.
        var wantIn = 0, wantOut = 0;
        for (final t in w.txs.where((t) => t.tx.live && _in(t.date, ps.first.start, today))) {
          if (t.kind == BudgetKind.income || t.kind == BudgetKind.extra) wantIn += t.amount;
          if (t.kind == BudgetKind.fixed || t.kind == BudgetKind.flex) wantOut -= t.amount;
        }
        expect((totalIn, totalOut), (wantIn, wantOut), reason: why);
        expect(ps.fold<int>(0, (s, p) => s + p.net), wantIn - wantOut, reason: why);

        // Transfers never change anything; input order never matters.
        final noTransfers = w.txs.where((t) => t.kind != BudgetKind.transfer).toList();
        final shuffled = [...w.txs]..shuffle(r);
        final extraTransfers = [
          ...w.txs,
          for (var k = 0; k < 10; k++) ct(_randomDay(r, w.from, w.to), r.nextInt(99999) - 50000, 'Internal transfer')
        ];
        final views = ps.map(_view).toList();
        expect(periodSummaries(noTransfers, st, today, count: 10000).map(_view).toList(), views, reason: '$why: transfers counted');
        expect(periodSummaries(extraTransfers, st, today, count: 10000).map(_view).toList(), views, reason: '$why: transfers counted');
        expect(periodSummaries(shuffled, st, today, count: 10000).map(_view).toList(), views, reason: '$why: order');

        // count keeps the newest periods; trend and overview are consistent.
        final k = 1 + r.nextInt(ps.length);
        expect(periodSummaries(w.txs, st, today, count: k).map(_view).toList(), views.sublist(ps.length - k), reason: '$why: count $k');
        final trend = trendNet(ps);
        expect(trend.length, ps.length);
        expect(trend.last, isNull, reason: 'running period has no trend value');
        final ov = savingsOverview(ps);
        expect(ov.periods, ps.length - 1);
        expect(ov.net, ps.take(ps.length - 1).fold<int>(0, (s, p) => s + p.net));
        expect(ov.saved, ps.take(ps.length - 1).where((p) => p.net > 0).length);
      }
    });
  });

  group('computePeriod (safe to spend) identities', () {
    test('budget maths on random wallets and days ($n cases)', () {
      for (var i = 0; i < n; i++) {
        final seed = base * 31 + i;
        final r = Random(seed);
        final w = _wallet(r);
        final st0 = _settings(r, w.from, w.to);
        final today = _randomDay(r, w.from, w.to);
        // The app always passes a period start (a detected payday, else today), on or before today.
        final saved = st0.periodStart != null && st0.periodStart!.compareTo(today) <= 0 ? st0.periodStart : null;
        final st = WalletSettings.fromMap(
            {...st0.toMap(), 'periodStart': saved ?? salaryPaydays(w.txs, today, currency: 'EUR').lastOrNull ?? today});
        final goals = [for (var g = r.nextInt(4); g > 0; g--) Goal(id: 'g$g', name: 'Synthetic $g', monthly: r.nextInt(20000))];
        final why = 'seed $seed today $today start ${st.periodStart} paydayDay ${st.paydayDay}';
        final p = computePeriod(w.txs, st, goals, today, table: CategoryTable.builtIn);

        expect(p.start, st.periodStart, reason: why);
        expect(p.end, nextPayday(p.start, st.paydayDay), reason: why);
        expect(p.length, daysBetween(p.start, p.end).clamp(1, 1000), reason: why);
        // H2: the real count of days left, 0 once the payday passed; never a negative allowance.
        expect(p.paydayPassed, today.compareTo(p.end) >= 0, reason: why);
        expect(p.daysLeft, p.paydayPassed ? 0 : daysBetween(today, p.end), reason: why);
        if (!p.paydayPassed) expect(p.daysLeft, greaterThanOrEqualTo(1), reason: why);
        expect(p.allowanceToday, greaterThanOrEqualTo(0), reason: why);
        expect(p.overBy, p.remaining < 0 ? -p.remaining : 0, reason: why);
        expect(p.overToday, p.safeToday < 0 ? -p.safeToday : 0, reason: why);
        expect(p.overBudget, p.overBy > 0 || p.planDaily <= 0, reason: why);
        expect(p.fixedPlan, st.rent + st.loan + st.subs, reason: why);
        expect(p.goalMonthly, goals.fold<int>(0, (s, g) => s + g.monthly), reason: why);
        expect(p.flexBudget, p.income - p.fixedPlan - p.goalMonthly, reason: why);
        expect(p.remaining, p.flexBudget - p.spent, reason: why);
        expect(p.safeToday, p.allowanceToday - p.spentToday, reason: why);
        final leftForToday = p.flexBudget - (p.spent - p.spentToday);
        expect(p.allowanceToday, p.paydayPassed || leftForToday <= 0 ? 0 : (leftForToday / p.daysLeft).round(), reason: why);
        // I: tomorrow's allowance if nothing more is spent today; null when the payday is tomorrow or has passed.
        final leftAfterToday = p.flexBudget - p.spent;
        expect(p.allowanceTomorrow,
            p.paydayPassed || p.daysLeft <= 1 ? isNull : (leftAfterToday <= 0 ? 0 : (leftAfterToday / (p.daysLeft - 1)).round()),
            reason: why);
        if (p.allowanceTomorrow case final t?) expect(t, greaterThanOrEqualTo(0), reason: why);
        // Oracle: with planned income and no rows after today, tomorrow's computePeriod gives that allowance exactly.
        if (st.incomeMode == 'planned' && p.allowanceTomorrow != null) {
          final upToToday = [
            for (final t in w.txs)
              if (t.date.compareTo(today) <= 0) t
          ];
          final now = computePeriod(upToToday, st, goals, today, table: CategoryTable.builtIn);
          final next = computePeriod(upToToday, st, goals, addDays(today, 1), table: CategoryTable.builtIn);
          expect(next.allowanceToday, now.allowanceTomorrow, reason: '$why: tomorrow, nothing more spent');
        }

        expect(p.planDaily, (p.flexBudget / p.length).round(), reason: why);
        expect(p.elapsed, inInclusiveRange(0.0, 1.0), reason: why);
        expect(p.aheadOfPace, (p.flexBudget * p.elapsed).round() - p.spent, reason: why);

        // Brute force over live rows in [start, today], or [start, payday) once the payday has passed (later rows are the
        // next period's).
        final lastDay = p.paydayPassed ? addDays(p.end, -1) : today;
        final live = w.txs.where((t) => t.tx.live && _in(t.date, p.start, lastDay)).toList();
        int sum(Iterable<CategorizedTx> xs) => xs.fold(0, (s, t) => s + t.amount);
        expect(p.spent, -sum(live.where((t) => t.kind == BudgetKind.flex)), reason: why);
        expect(p.spentToday, -sum(live.where((t) => t.kind == BudgetKind.flex && t.date == today)), reason: why);
        expect(p.received, sum(live.where((t) => t.kind == BudgetKind.income)), reason: why);
        expect(p.extras, sum(live.where((t) => t.kind == BudgetKind.extra)), reason: why);
        final fixed = <String, int>{};
        for (final t in live.where((t) => t.kind == BudgetKind.fixed)) {
          fixed[t.category] = (fixed[t.category] ?? 0) - t.amount;
        }
        expect(p.fixedPaid, fixed, reason: why);
        // H2: in the first samePaydayDays days a received salary short of the plan counts as the plan.
        final arriving = !p.paydayPassed && daysBetween(p.start, today) < samePaydayDays;
        expect(p.income, st.incomeMode == 'received' && p.received > 0 ? (arriving ? max(p.received, st.salary) : p.received) : st.salary,
            reason: why);
        expect(p.lowIncome, p.received > 0 && p.received * 10 < st.salary * 9 && !arriving && daysBetween(p.start, today) >= 4,
            reason: why);

        // Extras and transfers are never daily money; planned salary ignores what actually arrived.
        final more = [
          ...w.txs,
          ct(today, 12345, 'Extra income'),
          ct(today, -40000, 'Internal transfer'),
          ct(today, 30000, 'Loan received'),
        ];
        final q = computePeriod(more, st, goals, today, table: CategoryTable.builtIn);
        expect((q.flexBudget, q.allowanceToday, q.safeToday, q.spent), (p.flexBudget, p.allowanceToday, p.safeToday, p.spent), reason: why);
        if (st.incomeMode == 'planned') {
          final salaryLater = computePeriod([...w.txs, ct(today, 99999, 'Salary')], st, goals, today, table: CategoryTable.builtIn);
          expect(salaryLater.flexBudget, p.flexBudget, reason: '$why: planned income must not follow received salary');
        }
        // Spending today lowers safe-to-spend by exactly that amount; tomorrow's allowance spreads the rest.
        final spend = 1 + r.nextInt(5000);
        final s2 = computePeriod([...w.txs, ct(today, -spend, 'Groceries')], st, goals, today, table: CategoryTable.builtIn);
        if (p.paydayPassed) {
          // After the payday, today's row belongs to the next period: the ended period does not move.
          expect((s2.safeToday, s2.allowanceToday, s2.remaining), (p.safeToday, p.allowanceToday, p.remaining), reason: why);
        } else {
          expect(s2.safeToday, p.safeToday - spend, reason: why);
          expect(s2.allowanceToday, p.allowanceToday, reason: '$why: today\'s allowance is fixed at the start of the day');
          expect(s2.remaining, p.remaining - spend, reason: why);
        }
      }
    });

    test('a new wallet (nothing set) gives zero budget, not errors', () {
      final p = computePeriod(const [], const WalletSettings(), const [], '2026-02-28', table: CategoryTable.builtIn);
      expect((p.flexBudget, p.spent, p.remaining, p.allowanceToday, p.safeToday), (0, 0, 0, 0, 0));
      expect(p.daysLeft, greaterThanOrEqualTo(1));
    });

    WalletSettings plan(String start) => WalletSettings(salary: 300000, paydayDay: 10, periodStart: start);

    test('allowanceTomorrow: null on the day before payday and once the payday passed', () {
      final st = plan('2026-03-10');
      expect(computePeriod(const [], st, const [], '2026-04-09', table: CategoryTable.builtIn).daysLeft, 1);
      expect(computePeriod(const [], st, const [], '2026-04-09', table: CategoryTable.builtIn).allowanceTomorrow, isNull);
      expect(computePeriod(const [], st, const [], '2026-04-10', table: CategoryTable.builtIn).paydayPassed, isTrue);
      expect(computePeriod(const [], st, const [], '2026-04-10', table: CategoryTable.builtIn).allowanceTomorrow, isNull);
      expect(computePeriod(const [], st, const [], '2026-04-12', table: CategoryTable.builtIn).allowanceTomorrow, isNull);
      // Two days left: everything not spent yet goes to tomorrow.
      final p = computePeriod([ct('2026-04-08', -1000, 'Groceries')], st, const [], '2026-04-08', table: CategoryTable.builtIn);
      expect(p.daysLeft, 2);
      expect(p.allowanceTomorrow, p.flexBudget - 1000);
    });

    test('allowanceTomorrow: 0 when over budget, never negative; spreads the rest over the days after today', () {
      final st = plan('2026-03-10');
      final over = computePeriod([ct('2026-03-20', -400000, 'Groceries')], st, const [], '2026-03-20', table: CategoryTable.builtIn);
      expect(over.overBy, greaterThan(0));
      expect(over.allowanceTomorrow, 0);
      final exact = computePeriod([ct('2026-03-20', -300000, 'Groceries')], st, const [], '2026-03-20', table: CategoryTable.builtIn);
      expect(exact.remaining, 0);
      expect(exact.allowanceTomorrow, 0);
      // 21 days left on 2026-03-20: 3000.00 − 100.00 over the 20 days after today = 145.00 a day.
      final p = computePeriod([ct('2026-03-20', -10000, 'Groceries')], st, const [], '2026-03-20', table: CategoryTable.builtIn);
      expect(p.daysLeft, 21);
      expect(p.allowanceTomorrow, 14500);
      // Spending more today lowers it; spending today never changes today's allowance.
      final more = computePeriod([ct('2026-03-20', -30000, 'Groceries')], st, const [], '2026-03-20', table: CategoryTable.builtIn);
      expect(more.allowanceTomorrow, 13500);
      expect(more.allowanceToday, p.allowanceToday);
    });
  });

  group('affordability', () {
    test('verdict is monotonic in price and "now" never means money you do not have ($n cases)', () {
      int rank(Verdict v) => v.index; // now < tight < later < overBudget
      for (var i = 0; i < n; i++) {
        final seed = base * 7 + i;
        final r = Random(seed);
        final w = _wallet(r);
        final today = _randomDay(r, w.from, w.to);
        final st = WalletSettings(
            salary: r.nextInt(300000),
            rent: r.nextInt(80000),
            paydayDay: 1 + r.nextInt(31),
            periodStart: salaryPaydays(w.txs, today, currency: 'EUR').lastOrNull ?? today);
        final p = computePeriod(w.txs, st, const [], today, table: CategoryTable.builtIn);
        final prices = [for (var k = 0; k < 30; k++) r.nextInt(400000)]..sort();
        Affordability? prev;
        for (final price in prices) {
          final a = affordability(price, p);
          final left = p.flexBudget - p.spent - price;
          final why = 'seed $seed price $price flex ${p.flexBudget} spent ${p.spent} daysLeft ${p.daysLeft} planDaily ${p.planDaily}';
          expect(a.newDaily, p.overBudget || p.paydayPassed || left <= 0 ? 0 : (left / p.daysLeft).round(), reason: why);
          expect(a.newDaily, greaterThanOrEqualTo(0), reason: why);
          if (p.overBudget) expect(a.verdict, Verdict.overBudget, reason: '$why: the plan is over');
          if (a.verdict == Verdict.now) expect(left, greaterThan(0), reason: '$why: "now" with nothing left');
          if (a.verdict == Verdict.tight) expect(left, greaterThan(0), reason: why);
          if (a.verdict == Verdict.later) expect(left <= 0 || a.newDaily < p.planDaily * 0.75, isTrue, reason: why);
          if (prev != null) {
            expect(rank(a.verdict), greaterThanOrEqualTo(rank(prev.verdict)), reason: '$why: cheaper was ${prev.verdict}');
            expect(a.newDaily, lessThanOrEqualTo(prev.newDaily), reason: why);
          }
          prev = a;
        }
        expect(affordability(1 << 40, p).verdict, p.overBudget ? Verdict.overBudget : Verdict.later);
      }
    });
  });

  group('monthsToGoal', () {
    test('smallest whole number of months that reaches the target ($n cases)', () {
      final r = Random(base);
      for (var i = 0; i < n * 4; i++) {
        final g = Goal(id: 'g', name: 'Synthetic', target: r.nextInt(1000000), saved: r.nextInt(600000), monthly: r.nextInt(30000) - 2000);
        final m = monthsToGoal(g);
        final left = g.target - g.saved;
        final why = 'target ${g.target} saved ${g.saved} monthly ${g.monthly}';
        if (left <= 0) {
          expect(m, 0, reason: why);
        } else if (g.monthly <= 0) {
          expect(m, isNull, reason: why);
        } else {
          expect(m! * g.monthly, greaterThanOrEqualTo(left), reason: why);
          expect((m - 1) * g.monthly, lessThan(left), reason: why);
        }
      }
      expect(monthsToGoal(const Goal(id: 'g', name: 'x', target: 100000, saved: 0, monthly: 10000)), 10);
      expect(monthsToGoal(const Goal(id: 'g', name: 'x', target: 100001, saved: 0, monthly: 10000)), 11);
      expect(monthsToGoal(const Goal(id: 'g', name: 'x', target: 100000, saved: 100000, monthly: 0)), 0);
    });
  });
}
