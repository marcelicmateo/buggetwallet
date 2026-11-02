// Stage ZC Z1: own unit tests for series.dart (DayIndex, bucketed series). SYNTHETIC rows only: made-up amounts,
// well-known chains and brands; fixed dates, no real clock.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';

DateRange dr(String a, String b) => DateRange(start: a, end: b);

final table = CategoryTable.builtIn;

int sumSpent(Iterable<SeriesBar> bars) => bars.fold(0, (s, e) => s + e.spent);

/// A seeded synthetic wallet of [days] days from [from]: spending in several categories (refunds included), salary,
/// extra income, transfers, deleted rows, USD rows and tags.
List<CategorizedTx> wallet(String from, int days, {int seed = 7}) {
  final rnd = Random(seed);
  const spend = ['Groceries', 'Eating out', 'Shopping', 'Car & transport', 'Rent'];
  final out = <CategorizedTx>[];
  for (var d = 0; d < days; d++) {
    final day = addDays(from, d);
    for (var k = rnd.nextInt(5); k > 0; k--) {
      final c = spend[rnd.nextInt(spend.length)];
      final cents = 50 + rnd.nextInt(12000);
      final r = switch (rnd.nextInt(14)) {
        0 => row(day, cents, c), // refund
        1 => row(day, -cents, c, currency: 'USD'),
        2 => row(day, -cents, c, deleted: true),
        3 => row(day, -cents, 'Internal transfer'),
        4 => row(day, cents, 'Extra income'),
        _ => row(day, -cents, c, desc: rnd.nextBool() ? 'POS LIDL HRVATSKA ZAGREB' : 'POS KONZUM 0000 ZAGREB'),
      };
      out.add(rnd.nextInt(4) == 0 ? CategorizedTx(r.tx, r.category, r.kind, tags: const ['trip']) : r);
    }
    if (dayOf(day) == 10) out.add(row(day, 150000 + rnd.nextInt(900), 'Salary'));
  }
  return out;
}

void main() {
  const today = '2026-10-20';

  group('month buckets equal the month functions', () {
    final rows = wallet('2025-01-01', 640);
    final ix = DayIndex(rows, currency: 'EUR');
    // Whole months, a clipped window, and a window holding today.
    final windows = [dr('2025-01-01', '2026-09-30'), dr('2025-03-17', '2025-11-04'), dr('2026-05-01', '2026-10-31')];

    test('spendingSeries == spendingByMonth (spent and partial)', () {
      for (final w in windows) {
        final old = spendingByMonth(rows, w, currency: 'EUR', today: today);
        final bars = spendingSeries(ix, w, Bucket.month, today: today);
        expect(bars.length, old.length);
        for (var k = 0; k < old.length; k++) {
          expect(monthOf(bars[k].span.start), old[k].month);
          expect(bars[k].spent, old[k].spent, reason: old[k].month);
          expect(bars[k].partial, old[k].partial, reason: old[k].month);
        }
      }
    });

    test('tag and merchant filters == tagTrend / merchantTrend', () {
      final w = windows[1];
      final tag = tagTrend('trip', rows, w, today: today, currency: 'EUR');
      expect(spendingSeries(ix, w, Bucket.month, today: today, tag: 'trip').map((e) => e.spent).toList(), tag.map((e) => e.spent));
      final key = merchantsIn('Groceries', rows, w, currency: 'EUR', table: table).first.key;
      final m = merchantTrend('Groceries', key, rows, w, currency: 'EUR', today: today, table: table);
      expect(spendingSeries(ix, w, Bucket.month, today: today, category: 'Groceries', merchantKey: key).map((e) => e.spent).toList(),
          m.map((e) => e.spent));
    });

    test('incomeSeries == incomeVsSpending', () {
      for (final w in windows) {
        final old = incomeVsSpending(rows, w, currency: 'EUR', today: today);
        final bars = incomeSeries(ix, w, Bucket.month, today: today);
        expect(bars.length, old.length);
        for (var k = 0; k < old.length; k++) {
          final (a, b) = (bars[k], old[k]);
          expect([a.income, a.extra, a.spent, a.net, a.partial], [b.income, b.extra, b.spent, b.net, b.partial], reason: b.month);
        }
      }
    });

    test('budgetSeries == budgetVsActualSeries for whole months: budgeted, actual and over (several categories)', () {
      final budgets = {'Groceries': 30000, 'Eating out': 9000, 'Shopping': 0, 'Car & transport': 250000, 'Bills & subscriptions': 5000};
      final w = windows[0];
      final old = budgetVsActualSeries(rows, w, budgets, today: today, currency: 'EUR', table: table);
      final bars = budgetSeries(ix, w, Bucket.month, budgets, today: today, table: table);
      expect(bars.length, old.length);
      var anyOver = false;
      for (var k = 0; k < old.length; k++) {
        expect([bars[k].budgeted, bars[k].actual, bars[k].over], [old[k].budgeted, old[k].actual, old[k].over], reason: old[k].month);
        expect(bars[k].prorated, isFalse);
        // over is per category, so it can be above max(0, actual − budgeted).
        if (bars[k].over > max(0, bars[k].actual - bars[k].budgeted)) anyOver = true;
      }
      expect(anyOver, isTrue, reason: 'the wallet should have a month where one category is over and another under');
      // Quarters: budgeted and actual are the sums of their months; over is per category over the whole quarter (an
      // over month and an under month of one category net out), so it is at most the months' overs summed.
      final year = dr('2025-01-01', '2025-12-31');
      final q = budgetSeries(ix, year, Bucket.quarter, budgets, today: today, table: table);
      final perCat = {
        for (final c in budgets.keys) c: budgetSeries(ix, year, Bucket.month, budgets, today: today, table: table, category: c)
      };
      for (var i = 0; i < 4; i++) {
        final ms = bars.sublist(i * 3, i * 3 + 3);
        var over = 0;
        for (final m in perCat.values) {
          final part = m.sublist(i * 3, i * 3 + 3);
          over += max(0, part.fold<int>(0, (s, e) => s + e.actual) - part.fold<int>(0, (s, e) => s + e.budgeted));
        }
        expect([
          q[i].budgeted,
          q[i].actual,
          q[i].over
        ], [
          ms.fold<int>(0, (s, e) => s + e.budgeted),
          ms.fold<int>(0, (s, e) => s + e.actual),
          over,
        ]);
        expect(q[i].over, lessThanOrEqualTo(ms.fold<int>(0, (s, e) => s + e.over)));
      }
    });
  });

  group('buckets add up', () {
    final rows = wallet('2025-06-01', 500, seed: 3);
    final ix = DayIndex(rows, currency: 'EUR');

    test('the buckets of a window add up to the window, for every size and many windows', () {
      final rnd = Random(5);
      for (var i = 0; i < 60; i++) {
        final s = addDays('2025-05-20', rnd.nextInt(400));
        final w = dr(s, addDays(s, rnd.nextInt(200)));
        final total = ix.spent(w);
        for (final b in Bucket.values) {
          expect(sumSpent(spendingSeries(ix, w, b, today: today)), total, reason: '$w $b');
          final inc = incomeSeries(ix, w, b, today: today);
          expect(inc.fold<int>(0, (s, e) => s + e.income), ix.income(w));
          expect(inc.fold<int>(0, (s, e) => s + e.extra), ix.extra(w));
        }
      }
    });

    test('days add up to their week, weeks (partial ones once) to their month', () {
      final w = dr('2025-09-01', '2026-02-28');
      final days = spendingSeries(ix, w, Bucket.day, today: today);
      final weeks = spendingSeries(ix, w, Bucket.week, today: today);
      for (final wk in weeks) {
        expect(sumSpent(days.where((d) => wk.span.contains(d.span.start))), wk.spent, reason: '${wk.span}');
      }
      for (final m in spendingSeries(ix, w, Bucket.month, today: today)) {
        // The weeks clipped at this month: the week pieces from bucketsOf over the month itself.
        final pieces = spendingSeries(ix, m.span, Bucket.week, today: today);
        expect(sumSpent(pieces), m.spent);
        expect(sumSpent(days.where((d) => m.span.contains(d.span.start))), m.spent);
      }
    });

    test('pro-rated budget: days add up to the week, weeks to the month, months to the budget', () {
      final budgets = {'Groceries': 30001, 'Rent': 45000, 'Eating out': 7};
      final w = dr('2025-12-01', '2026-03-31');
      final days = budgetSeries(ix, w, Bucket.day, budgets, today: today, table: table);
      final weeks = budgetSeries(ix, w, Bucket.week, budgets, today: today, table: table);
      final months = budgetSeries(ix, w, Bucket.month, budgets, today: today, table: table);
      for (final wk in weeks) {
        final inWeek = days.where((d) => wk.span.contains(d.span.start));
        expect(inWeek.fold<int>(0, (s, e) => s + e.budgeted), wk.budgeted);
        expect(inWeek.fold<int>(0, (s, e) => s + e.actual), wk.actual);
      }
      for (final m in months) {
        expect(m.budgeted, 30001 + 45000 + 7);
        final inMonth = days.where((d) => m.span.contains(d.span.start));
        expect(inMonth.fold<int>(0, (s, e) => s + e.budgeted), m.budgeted);
        expect(inMonth.fold<int>(0, (s, e) => s + e.actual), m.actual);
      }
    });
  });

  group('calendar edges', () {
    test('a week over New Year is one bucket and labelled with both years', () {
      final r = [row('2026-12-31', -100, 'Groceries'), row('2027-01-01', -200, 'Groceries'), row('2027-01-04', -400, 'Groceries')];
      final bars = spendingSeries(DayIndex(r, currency: 'EUR'), dr('2026-12-28', '2027-01-10'), Bucket.week, today: '2027-02-01');
      expect(bars.map((e) => e.span).toList(), [dr('2026-12-28', '2027-01-03'), dr('2027-01-04', '2027-01-10')]);
      expect(bars.map((e) => e.spent).toList(), [300, 400]);
      expect(bucketLabel(bars.first.span, Bucket.week), '28 Dec 26 – 3 Jan 27');
      expect(bucketLabel(dr('2026-09-28', '2026-10-04'), Bucket.week), '28 Sep – 4 Oct');
      expect(bucketLabel(dr('2026-10-05', '2026-10-11'), Bucket.week), '5–11 Oct');
      expect(bucketLabel(dr('2026-10-12', '2026-10-12'), Bucket.week), '12 Oct');
    });

    test('the DST weeks (EU: 29 Mar and 25 Oct 2026) have 7 days each and keep every row', () {
      for (final (mon, sun) in [('2026-03-23', '2026-03-29'), ('2026-10-19', '2026-10-25')]) {
        final r = [for (var d = 0; d < 9; d++) row(addDays(mon, d - 1), -(d + 1), 'Groceries')];
        final ix = DayIndex(r, currency: 'EUR');
        final weeks = bucketsOf(dr(mon, sun), Bucket.week);
        expect(weeks, [dr(mon, sun)]);
        expect(bucketsOf(dr(mon, sun), Bucket.day).length, 7);
        expect(ix.spent(weeks.single), 2 + 3 + 4 + 5 + 6 + 7 + 8);
        expect(sumSpent(spendingSeries(ix, dr(addDays(mon, -1), addDays(sun, 1)), Bucket.day, today: '2027-01-01')), 45);
      }
    });

    test('Monday-start weeks for every weekday a window can start on', () {
      for (var d = 0; d < 14; d++) {
        final s = addDays('2026-10-05', d);
        final b = bucketsOf(dr(s, addDays(s, 30)), Bucket.week);
        for (final e in b.skip(1)) {
          expect(parseIso(e.start).weekday, DateTime.monday);
        }
        expect(parseIso(b.first.end).weekday == DateTime.sunday || b.length == 1, isTrue);
      }
    });
  });

  group('money rules', () {
    test('a refund lowers its bucket; a net refund is below zero', () {
      final r = [row('2026-10-05', -1000, 'Shopping'), row('2026-10-06', 1500, 'Shopping'), row('2026-10-13', -200, 'Shopping')];
      final bars = spendingSeries(DayIndex(r, currency: 'EUR'), dr('2026-10-05', '2026-10-18'), Bucket.week, today: today);
      expect(bars.map((e) => e.spent).toList(), [-500, 200]);
      final bb = budgetSeries(DayIndex(r, currency: 'EUR'), dr('2026-10-05', '2026-10-11'), Bucket.week, {'Shopping': 3100},
          today: today, table: table);
      expect(bb.single.actual, -500);
      expect(bb.single.over, 0);
    });

    test('other currencies are never mixed in: each index counts only its own currency', () {
      final r = [
        row('2026-10-05', -1000, 'Shopping'),
        row('2026-10-05', -7, 'Shopping', currency: 'USD'),
        row('2026-10-07', 900, 'Salary', currency: 'USD')
      ];
      final eur = DayIndex(r, currency: 'EUR'), usd = DayIndex(r, currency: 'USD');
      final w = dr('2026-10-01', '2026-10-31');
      expect([eur.spent(w), eur.income(w)], [1000, 0]);
      expect([usd.spent(w), usd.income(w)], [7, 900]);
      expect([eur.first, eur.last], ['2026-10-05', '2026-10-05']);
      expect([usd.first, usd.last], ['2026-10-05', '2026-10-07']);
    });

    test('largest remainder: every month adds up exactly, extra cents on the earliest days', () {
      final rnd = Random(9);
      final ix = DayIndex(const [], currency: 'EUR');
      for (var i = 0; i < 200; i++) {
        final cents = i < 5 ? [0, 1, 27, 28, 31][i] : rnd.nextInt(10000000);
        final month = '20${24 + rnd.nextInt(6)}-${(1 + rnd.nextInt(12)).toString().padLeft(2, '0')}';
        final w = dr('$month-01', '$month-${daysInMonth(month)}');
        final days = budgetSeries(ix, w, Bucket.day, {'Groceries': cents}, today: today, table: table);
        expect(days.fold<int>(0, (s, e) => s + e.budgeted), cents, reason: '$month $cents');
        final n = days.length, base = cents ~/ n, rem = cents % n;
        for (var k = 0; k < n; k++) {
          expect(days[k].budgeted, base + (k < rem ? 1 : 0));
        }
      }
    });

    test('pro-rating is per category: two 1-cent budgets give day 1 two cents, day 2 none', () {
      final ix = DayIndex([row('2026-10-02', -1, 'Shopping')], currency: 'EUR');
      final days =
          budgetSeries(ix, dr('2026-10-01', '2026-10-03'), Bucket.day, {'Groceries': 1, 'Shopping': 1}, today: today, table: table);
      expect(days.map((e) => e.budgeted).toList(), [2, 0, 0]);
      expect(days[1].actual, 1);
      expect(days[1].over, 1); // Shopping's share that day is 0
    });

    test('over is per category: one over, one under does not cancel', () {
      final r = [row('2026-10-05', -5000, 'Groceries'), row('2026-10-05', -10, 'Shopping')];
      final m = budgetSeries(
              DayIndex(r, currency: 'EUR'), dr('2026-10-01', '2026-10-31'), Bucket.month, {'Groceries': 4000, 'Shopping': 9000},
              today: today, table: table)
          .single;
      expect([m.budgeted, m.actual, m.over], [13000, 5010, 1000]);
    });

    test('a clipped month counts only its days and is prorated; a whole one is exact', () {
      final r = [row('2026-09-02', -400, 'Groceries'), row('2026-10-05', -300, 'Groceries'), row('2026-10-25', -200, 'Groceries')];
      final bars = budgetSeries(DayIndex(r, currency: 'EUR'), dr('2026-09-01', '2026-10-10'), Bucket.month, {'Groceries': 3100},
          today: today, table: table);
      expect(bars.map((e) => e.span).toList(), [dr('2026-09-01', '2026-09-30'), dr('2026-10-01', '2026-10-10')]);
      expect([bars[0].budgeted, bars[0].actual, bars[0].prorated, bars[0].partial], [3100, 400, false, false]);
      expect([bars[1].budgeted, bars[1].actual, bars[1].prorated, bars[1].partial], [1000, 300, true, true]);
      final q = budgetSeries(DayIndex(r, currency: 'EUR'), dr('2026-08-15', '2026-09-30'), Bucket.quarter, {'Groceries': 3100},
              today: today, table: table)
          .single;
      expect([q.budgeted, q.prorated], [3100 * 17 ~/ 31 + 3100, true]);
    });

    test('a budget for an unknown category counts its share, never any actual', () {
      final r = [row('2026-10-05', -300, 'Groceries')];
      final b = budgetSeries(DayIndex(r, currency: 'EUR'), dr('2026-10-01', '2026-10-31'), Bucket.month, {'Nope': 500},
          today: today, table: table);
      expect([b.single.budgeted, b.single.actual, b.single.over], [500, 0, 0]);
    });

    test('category: without a budget entry it counts nowhere; a budget set to 0 is real and its spending is over', () {
      final r = [row('2026-10-05', -300, 'Groceries'), row('2026-10-06', -50, 'Shopping')];
      final ix = DayIndex(r, currency: 'EUR');
      for (final b in Bucket.values) {
        final w = dr('2026-09-15', '2026-10-31');
        final none = budgetSeries(ix, w, b, {'Shopping': 3100}, today: today, table: table, category: 'Groceries');
        final shopping = budgetSeries(ix, w, b, {'Shopping': 3100}, today: today, table: table, category: 'Shopping');
        expect(none.length, shopping.length);
        for (var k = 0; k < none.length; k++) {
          expect([none[k].budgeted, none[k].actual, none[k].over], [0, 0, 0], reason: '$b ${none[k].span}');
          expect(none[k].prorated, shopping[k].prorated, reason: 'prorated follows the bucket');
          expect(none[k].span, shopping[k].span);
        }
        final zero = budgetSeries(ix, w, b, {'Groceries': 0}, today: today, table: table, category: 'Groceries');
        expect(zero.fold<int>(0, (s, e) => s + e.budgeted), 0);
        expect(zero.fold<int>(0, (s, e) => s + e.actual), 300, reason: '$b');
        expect(zero.fold<int>(0, (s, e) => s + e.over), 300, reason: '$b');
      }
      final month =
          budgetSeries(ix, dr('2026-10-01', '2026-10-31'), Bucket.month, const {}, today: today, table: table, category: 'Groceries');
      expect([month.single.budgeted, month.single.actual, month.single.over, month.single.prorated], [0, 0, 0, false]);
    });
  });

  group('limits', () {
    test('windows of 5 years or more are refused by bucketsOf and every series function', () {
      final ix = DayIndex(const [], currency: 'EUR');
      final ok = dr('2026-01-01', '2030-12-31'), tooLong = dr('2026-01-01', '2031-01-01');
      expect(bucketsOf(ok, Bucket.quarter).length, 20);
      expect(spendingSeries(ix, ok, Bucket.quarter, today: today).length, 20);
      final calls = <void Function()>[
        () => bucketsOf(tooLong, Bucket.month),
        () => spendingSeries(ix, tooLong, Bucket.month, today: today),
        () => incomeSeries(ix, tooLong, Bucket.month, today: today),
        () => budgetSeries(ix, tooLong, Bucket.month, const {}, today: today, table: table),
      ];
      for (final c in calls) {
        expect(c, throwsArgumentError);
      }
      // From a leap day: 5 years on is 1 Mar 2033 (no 29 Feb then).
      expect(bucketsOf(dr('2028-02-29', '2033-02-28'), Bucket.month), isNotEmpty);
      expect(() => bucketsOf(dr('2028-02-29', '2033-03-01'), Bucket.month), throwsArgumentError); // quarters and years: no limit (ENG)
    });

    test('a bad today is refused', () {
      final ix = DayIndex(const [], currency: 'EUR');
      expect(() => spendingSeries(ix, dr('2026-10-01', '2026-10-31'), Bucket.week, today: '2026-13-01'), throwsArgumentError);
    });

    test('an empty index: no extents, zero bars of the right count', () {
      final ix = DayIndex(const [], currency: 'EUR');
      expect([ix.first, ix.last], [null, null]);
      final w = dr('2026-01-01', '2026-12-31');
      expect(spendingSeries(ix, w, Bucket.month, today: today).map((e) => e.spent), List.filled(12, 0));
      expect(incomeSeries(ix, w, Bucket.quarter, today: today).map((e) => e.net), List.filled(4, 0));
      expect(ix.spent(w, category: 'Groceries', tag: 'x', merchantKey: 'y'), 0);
      final only =
          DayIndex([row('2026-10-05', -1, 'Internal transfer'), row('2026-10-06', -1, 'Groceries', deleted: true)], currency: 'EUR');
      expect([only.first, only.last], [null, null]);
    });
  });

  test('perf: 20k rows over 5 years, 40-bucket windows read within a frame', () {
    const end = '2026-10-31';
    final rows = bigWalletRows(end, days: 1826, perDay: 11);
    expect(rows.length, greaterThan(18000));
    final build = Stopwatch()..start();
    final ix = DayIndex(rows, currency: 'EUR');
    build.stop();
    final budgets = {'Groceries': 40000, 'Eating out': 15000, 'Shopping': 20000, 'Car & transport': 12000};
    final reads = <String, List<int>>{};
    void time(String name, void Function() f) {
      final sw = Stopwatch()..start();
      f();
      (reads[name] ??= []).add(sw.elapsedMicroseconds);
    }

    for (var i = 0; i < 100; i++) {
      final dayEnd = addDays(end, -i * 3), weekEnd = addDays(end, -i * 7);
      time('day40', () => spendingSeries(ix, dr(addDays(dayEnd, -39), dayEnd), Bucket.day, today: end));
      time('week40', () => spendingSeries(ix, dr(addDays(weekEnd, -279), weekEnd), Bucket.week, today: end));
      time('month40', () => incomeSeries(ix, dr(addDays(dayEnd, -1200), dayEnd), Bucket.month, today: end));
      time('budgetWeek40', () => budgetSeries(ix, dr(addDays(weekEnd, -279), weekEnd), Bucket.week, budgets, today: end, table: table));
      time('tagDay40', () => spendingSeries(ix, dr(addDays(dayEnd, -39), dayEnd), Bucket.day, today: end, category: 'Groceries'));
    }
    final report = <String>['rows ${rows.length}', 'build ${build.elapsedMilliseconds} ms'];
    for (final MapEntry(key: k, value: v) in reads.entries) {
      final s = [...v]..sort();
      report.add('$k first ${v.first} us, p50 ${s[s.length ~/ 2]} us, max ${s.last} us');
      expect(s[s.length ~/ 2], lessThan(16000), reason: k);
    }
    // ignore: avoid_print
    print('series perf: ${report.join('; ')}');
    expect(build.elapsedMilliseconds, lessThan(2000));
  });
}
