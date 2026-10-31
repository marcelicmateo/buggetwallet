// ZC Z2: spec tests for the bucketed series (docs/context/ZC_SPEC.md §3, §4, §6), written from the spec only.
// SYNTHETIC rows: made-up amounts, well-known chains. Dates are fixed; no real clock.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';

DateRange dr(String a, String b) => DateRange(start: a, end: b);

DayIndex ix(List<CategorizedTx> rows, {String currency = 'EUR'}) => DayIndex(rows, currency: currency);

CategorizedTx withTags(CategorizedTx t, List<String> tags) => CategorizedTx(t.tx, t.category, t.kind, tags: tags);

CategorizedTx iouRow(CategorizedTx t) => CategorizedTx(t.tx, t.category, BudgetKind.transfer, iou: true);

/// Spec oracle: net spending (cents, positive = spent) of the live home-currency fixed/flex rows in [span], IOU rows out.
int oracle(List<CategorizedTx> rows, DateRange span, {String currency = 'EUR'}) {
  var s = 0;
  for (final t in rows) {
    if (!t.tx.live || t.tx.currency != currency || t.iou) continue;
    if (t.kind != BudgetKind.fixed && t.kind != BudgetKind.flex) continue;
    if (span.contains(t.date)) s -= t.amount;
  }
  return s;
}

/// A mixed synthetic wallet of about 230 days: spending, refunds, income, transfers, foreign, deleted, IOU, zero rows.
List<CategorizedTx> mixedWallet() {
  final rnd = Random(11);
  const spend = ['Groceries', 'Eating out', 'Shopping', 'Car & transport', 'Rent', 'Bills & subscriptions'];
  final out = <CategorizedTx>[];
  for (var d = 0; d < 230; d++) {
    final day = addDays('2026-03-01', d);
    for (var k = rnd.nextInt(4); k > 0; k--) {
      final c = spend[rnd.nextInt(spend.length)];
      final cents = 100 + rnd.nextInt(9000);
      switch (rnd.nextInt(12)) {
        case 0:
          out.add(row(day, cents, c)); // refund
        case 1:
          out.add(row(day, -cents, c, currency: 'USD'));
        case 2:
          out.add(row(day, -cents, c, deleted: true));
        case 3:
          out.add(iouRow(row(day, -cents, c)));
        case 4:
          out.add(row(day, -cents, 'Internal transfer'));
        case 5:
          out.add(row(day, 0, c));
        default:
          out.add(row(day, -cents, c));
      }
    }
    if (day.endsWith('-10')) out.add(row(day, 180000, 'Salary'));
  }
  return out;
}

void main() {
  const today = '2026-10-20'; // a Tuesday
  const t1 = 't000000000001', t2 = 't000000000002';

  group('bucketsOf alignment', () {
    test('days: one per day, both ends', () {
      final b = bucketsOf(dr('2026-10-29', '2026-11-02'), Bucket.day);
      expect(b.map((e) => e.start).toList(), ['2026-10-29', '2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02']);
      expect([for (final e in b) e.start == e.end], everyElement(isTrue));
    });

    test('weeks are Monday-Sunday and clipped at the window edges', () {
      // Wed 2026-10-07 .. Thu 2026-11-12
      final b = bucketsOf(dr('2026-10-07', '2026-11-12'), Bucket.week);
      expect(b.first, dr('2026-10-07', '2026-10-11'));
      expect(b[1], dr('2026-10-12', '2026-10-18'));
      expect(b.last, dr('2026-11-09', '2026-11-12'));
      expect(b.length, 6);
    });

    test('a window of exactly one aligned week is one unclipped bucket', () {
      expect(bucketsOf(dr('2026-10-19', '2026-10-25'), Bucket.week), [dr('2026-10-19', '2026-10-25')]);
    });

    test('weeks across New Year are not split by the year', () {
      final b = bucketsOf(dr('2026-12-21', '2027-01-10'), Bucket.week);
      expect(b, [dr('2026-12-21', '2026-12-27'), dr('2026-12-28', '2027-01-03'), dr('2027-01-04', '2027-01-10')]);
    });

    test('a window starting mid-week over New Year: first week clipped', () {
      final b = bucketsOf(dr('2026-12-30', '2027-01-10'), Bucket.week);
      expect(b.first, dr('2026-12-30', '2027-01-03'));
      expect(b.length, 2);
    });

    test('the DST change 2026-10-25 neither loses nor doubles a day', () {
      final days = bucketsOf(dr('2026-10-19', '2026-11-01'), Bucket.day);
      expect(days.length, 14);
      expect(days.map((e) => e.start).toSet().length, 14);
      expect(days[6].start, '2026-10-25');
      expect(days[7].start, '2026-10-26');
      expect(bucketsOf(dr('2026-10-19', '2026-11-01'), Bucket.week), [dr('2026-10-19', '2026-10-25'), dr('2026-10-26', '2026-11-01')]);
      // the spring change, 2026-03-29, too
      expect(bucketsOf(dr('2026-03-23', '2026-04-05'), Bucket.day).length, 14);
    });

    test('months are calendar months, clipped; leap day 2028-02-29 stays in February', () {
      final b = bucketsOf(dr('2028-01-15', '2028-03-10'), Bucket.month);
      expect(b, [dr('2028-01-15', '2028-01-31'), dr('2028-02-01', '2028-02-29'), dr('2028-03-01', '2028-03-10')]);
      final days = bucketsOf(dr('2028-02-27', '2028-03-02'), Bucket.day).map((e) => e.start).toList();
      expect(days, ['2028-02-27', '2028-02-28', '2028-02-29', '2028-03-01', '2028-03-02']);
      // 2028-02-28 is a Monday: the leap day is a Tuesday of that week
      final w = bucketsOf(dr('2028-02-21', '2028-03-12'), Bucket.week);
      expect(w.map((e) => e.start).toList(), ['2028-02-21', '2028-02-28', '2028-03-06']);
      expect(w[1].end, '2028-03-05');
    });

    test('quarters are calendar quarters, clipped', () {
      final b = bucketsOf(dr('2026-02-10', '2027-01-20'), Bucket.quarter);
      expect(b, [
        dr('2026-02-10', '2026-03-31'),
        dr('2026-04-01', '2026-06-30'),
        dr('2026-07-01', '2026-09-30'),
        dr('2026-10-01', '2026-12-31'),
        dr('2027-01-01', '2027-01-20'),
      ]);
    });

    test('a one-day window is one bucket whatever the size', () {
      for (final b in Bucket.values) {
        expect(bucketsOf(dr('2026-10-14', '2026-10-14'), b), [dr('2026-10-14', '2026-10-14')], reason: '$b');
      }
    });

    test('the buckets of any window tile it: contiguous, no gap, no overlap', () {
      for (final w in [dr('2026-03-05', '2026-10-20'), dr('2026-12-30', '2027-01-02'), dr('2028-02-01', '2028-03-31')]) {
        for (final b in Bucket.values) {
          final bs = bucketsOf(w, b);
          expect(bs.first.start, w.start, reason: '$b $w');
          expect(bs.last.end, w.end, reason: '$b $w');
          for (var i = 1; i < bs.length; i++) {
            expect(bs[i].start, addDays(bs[i - 1].end, 1), reason: '$b $w #$i');
          }
        }
      }
    });
  });

  group('bucketFor', () {
    test('picks the bar size from the time on screen (spec §1 table)', () {
      expect(bucketFor(dr('2026-10-06', '2026-11-02')), Bucket.day); // 4 weeks
      expect(bucketFor(dr('2026-10-14', '2026-10-20')), Bucket.day); // 7 days, the zoom floor
      expect(bucketFor(dr('2026-05-01', '2026-10-31')), Bucket.week); // 184 days is too many days, 27 weeks fit
      expect(bucketFor(dr('2025-11-01', '2026-10-31')), Bucket.month); // a year
      expect(bucketFor(dr('2024-01-01', '2026-10-31')), Bucket.month); // under 3 years: 34 months
      expect(bucketFor(dr('2021-11-01', '2026-10-31')), Bucket.quarter); // 5 years
    });

    test('never more than maxBars buckets, over every window length up to 5 years', () {
      const start = '2021-11-01';
      for (var len = 1; len <= 1825; len++) {
        final w = dr(start, addDays(start, len - 1));
        final b = bucketFor(w);
        expect(bucketsOf(w, b).length, lessThanOrEqualTo(40), reason: '$len days -> $b');
      }
    });

    test('a smaller maxBars gives a coarser size, still within the cap', () {
      for (var len = 7; len <= 700; len += 3) {
        final w = dr('2025-01-01', addDays('2025-01-01', len - 1));
        final b = bucketFor(w, maxBars: 12);
        expect(bucketsOf(w, b).length, lessThanOrEqualTo(12), reason: '$len days -> $b');
        expect(b.index, greaterThanOrEqualTo(bucketFor(w).index), reason: '$len days: never finer than with 40 bars');
      }
    });

    test('never finer than finest', () {
      for (final finest in Bucket.values) {
        for (final len in [1, 7, 20, 35, 90, 200, 400, 1000, 1825]) {
          final w = dr('2021-11-01', addDays('2021-11-01', len - 1));
          expect(bucketFor(w, finest: finest).index, greaterThanOrEqualTo(finest.index), reason: '$len days, finest $finest');
        }
      }
      // a short window with finest week is weeks, with finest month months
      expect(bucketFor(dr('2026-10-01', '2026-10-10'), finest: Bucket.week), Bucket.week);
      expect(bucketFor(dr('2026-10-01', '2026-10-10'), finest: Bucket.month), Bucket.month);
    });

    test('a longer window never gets a finer size than a shorter one starting at the same day', () {
      var prev = Bucket.day.index;
      for (var len = 1; len <= 1825; len += 7) {
        final b = bucketFor(dr('2021-11-01', addDays('2021-11-01', len - 1))).index;
        expect(b, greaterThanOrEqualTo(prev), reason: '$len days');
        prev = b;
      }
    });
  });

  group('bucketLabel (spec §4)', () {
    test('day, week, month, quarter', () {
      expect(bucketLabel(dr('2026-10-14', '2026-10-14'), Bucket.day), '14');
      expect(bucketLabel(dr('2026-10-30', '2026-10-30'), Bucket.day), '30');
      expect(bucketLabel(dr('2026-10-05', '2026-10-11'), Bucket.week), '5–11 Oct');
      expect(bucketLabel(dr('2026-10-12', '2026-10-18'), Bucket.week), '12–18 Oct');
      expect(bucketLabel(dr('2026-10-01', '2026-10-31'), Bucket.month), 'Oct 26');
      expect(bucketLabel(dr('2027-01-01', '2027-01-31'), Bucket.month), 'Jan 27');
      expect(bucketLabel(dr('2026-10-01', '2026-12-31'), Bucket.quarter), 'Q4 26');
      expect(bucketLabel(dr('2027-01-01', '2027-03-31'), Bucket.quarter), 'Q1 27');
      expect(bucketLabel(dr('2026-07-01', '2026-09-30'), Bucket.quarter), 'Q3 26');
    });

    test('a clipped month or quarter keeps the label of its month or quarter', () {
      expect(bucketLabel(dr('2026-08-15', '2026-08-31'), Bucket.month), 'Aug 26');
      expect(bucketLabel(dr('2026-11-01', '2026-12-31'), Bucket.quarter), 'Q4 26');
    });
  });

  group('DayIndex', () {
    test('first and last are the data extents; null when empty', () {
      final i = ix([row('2026-05-03', -100, 'Groceries'), row('2026-09-09', -200, 'Shopping'), row('2026-07-01', 5000, 'Salary')]);
      expect(i.first, '2026-05-03');
      expect(i.last, '2026-09-09');
      final e = ix(const []);
      expect(e.first, isNull);
      expect(e.last, isNull);
      expect(e.spent(dr('2026-01-01', '2026-12-31')), 0);
    });

    test('spent nets refunds and ignores transfers, IOU, deleted, other currencies', () {
      final rows = [
        row('2026-10-05', -1500, 'Groceries'),
        row('2026-10-06', 300, 'Groceries'), // refund
        row('2026-10-07', -9900, 'Internal transfer'),
        iouRow(row('2026-10-08', -7700, 'Eating out')),
        row('2026-10-09', -6600, 'Shopping', deleted: true),
        row('2026-10-10', -5500, 'Shopping', currency: 'USD'),
        row('2026-10-11', -250, 'Shopping'),
        row('2026-10-12', 200000, 'Salary'),
      ];
      final i = ix(rows);
      expect(i.spent(dr('2026-10-01', '2026-10-31')), 1450); // 1500 - 300 + 250
      expect(i.spent(dr('2026-10-06', '2026-10-06')), -300); // a net refund is below zero
      expect(i.spent(dr('2026-10-05', '2026-10-05')), 1500);
      expect(i.spent(dr('2026-10-07', '2026-10-10')), 0);
      expect(i.income(dr('2026-10-01', '2026-10-31')), 200000);
    });

    test('category, tag and merchant filters; split parts count by their own category and tag, never twice', () {
      final whole = row('2026-10-12', -9000, 'Groceries', desc: 'POS LIDL HRVATSKA ZAGREB');
      final rows = [
        CategorizedTx(whole.tx, 'Groceries', BudgetKind.flex, tags: const [t1], amount: -3000, part: 0, parts: 2),
        CategorizedTx(whole.tx, 'Shopping', BudgetKind.flex, amount: -6000, part: 1, parts: 2),
        withTags(row('2026-10-13', -1000, 'Groceries', desc: 'POS SPAR 0000 ZAGREB'), const [t1, t2]),
        row('2026-10-14', -400, 'Eating out', desc: 'POS MCDONALDS ZAGREB'),
      ];
      final i = ix(rows);
      final w = dr('2026-10-01', '2026-10-31');
      expect(i.spent(w), 10400);
      expect(i.spent(w, category: 'Groceries'), 4000);
      expect(i.spent(w, category: 'Shopping'), 6000);
      expect(i.spent(w, tag: t1), 4000); // the part's tag and the SPAR row
      expect(i.spent(w, tag: t2), 1000);
      expect(i.spent(dr('2026-10-12', '2026-10-12')), 9000);
      expect(i.spent(w, merchantKey: merchantKey(rows[2].tx)), 1000);
      expect(i.spent(w, merchantKey: merchantKey(rows[3].tx)), 400);
    });

    test('range edges are inclusive', () {
      final i = ix([row('2026-10-05', -100, 'Groceries'), row('2026-10-06', -200, 'Groceries'), row('2026-10-07', -400, 'Groceries')]);
      expect(i.spent(dr('2026-10-05', '2026-10-07')), 700);
      expect(i.spent(dr('2026-10-06', '2026-10-06')), 200);
      expect(i.spent(dr('2026-10-04', '2026-10-05')), 100);
      expect(i.spent(dr('2026-10-07', '2026-10-09')), 400);
      expect(i.spent(dr('2026-10-08', '2026-10-09')), 0);
    });

    test('income and extra are separate and exclude transfers', () {
      final i = ix([
        row('2026-10-05', 200000, 'Salary'),
        row('2026-10-06', 5000, 'Extra income'),
        row('2026-10-09', 99999, 'Internal transfer'),
        row('2026-10-10', 7000, 'Salary', currency: 'USD'),
        row('2026-10-11', 7000, 'Salary', deleted: true),
      ]);
      final w = dr('2026-10-01', '2026-10-31');
      expect(i.income(w), 200000);
      expect(i.extra(w), 5000);
      expect(i.spent(w), 0);
    });

    test('a non-EUR home currency counts only that currency', () {
      final i = ix([row('2026-10-05', -1500, 'Groceries'), row('2026-10-05', -700, 'Groceries', currency: 'USD')], currency: 'USD');
      expect(i.spent(dr('2026-10-01', '2026-10-31')), 700);
    });
  });

  group('spendingSeries', () {
    final rows = mixedWallet();
    final index = ix(rows);
    final window = dr('2026-03-05', '2026-10-20');

    test('every bucket equals the sum of its rows (oracle), for every size', () {
      for (final b in Bucket.values) {
        final bars = spendingSeries(index, window, b, today: today);
        expect(bars.map((e) => e.span).toList(), bucketsOf(window, b), reason: '$b spans');
        for (final bar in bars) {
          expect(bar.bucket, b);
          expect(bar.spent, oracle(rows, bar.span), reason: '$b ${bar.span}');
        }
      }
    });

    test('the buckets add up to the window total, for every size; days add up to weeks, weeks to months', () {
      final total = oracle(rows, window);
      expect(total, isNot(0));
      for (final b in Bucket.values) {
        expect(spendingSeries(index, window, b, today: today).fold<int>(0, (s, e) => s + e.spent), total, reason: '$b');
      }
      final days = spendingSeries(index, window, Bucket.day, today: today);
      for (final up in [Bucket.week, Bucket.month, Bucket.quarter]) {
        for (final bar in spendingSeries(index, window, up, today: today)) {
          final inside = days.where((d) => bar.span.contains(d.span.start)).fold<int>(0, (s, e) => s + e.spent);
          expect(inside, bar.spent, reason: '$up ${bar.span}');
        }
      }
    });

    test('every row lands in exactly one bucket', () {
      for (final b in Bucket.values) {
        final spans = bucketsOf(window, b);
        for (final t in rows.where((t) => window.contains(t.date))) {
          expect(spans.where((s) => s.contains(t.date)).length, 1, reason: '$b ${t.date}');
        }
      }
    });

    test('hand-computed cents: a refund, a transfer, an IOU row, a deleted row and a USD row', () {
      final r = [
        row('2026-10-12', -1250, 'Groceries'), // Mon
        row('2026-10-14', -799, 'Eating out'),
        row('2026-10-14', 349, 'Eating out'), // refund
        row('2026-10-15', -50000, 'Internal transfer'), // PBZ -> Revolut top-up
        iouRow(row('2026-10-16', -4000, 'To people')),
        row('2026-10-17', -111, 'Shopping', deleted: true),
        row('2026-10-17', -222, 'Shopping', currency: 'USD'),
        row('2026-10-18', -1, 'Shopping'), // Sun
        row('2026-10-19', -3000, 'Shopping'), // next week
      ];
      final bars = spendingSeries(ix(r), dr('2026-10-12', '2026-10-25'), Bucket.week, today: '2026-12-01');
      expect(bars.map((e) => e.spent).toList(), [1250 + 799 - 349 + 1, 3000]);
      final days = spendingSeries(ix(r), dr('2026-10-12', '2026-10-19'), Bucket.day, today: '2026-12-01');
      expect(days.map((e) => e.spent).toList(), [1250, 0, 450, 0, 0, 0, 1, 3000]);
    });

    test('a net refund bucket is below zero', () {
      final bars =
          spendingSeries(ix([row('2026-10-13', 4200, 'Shopping')]), dr('2026-10-12', '2026-10-18'), Bucket.week, today: '2026-12-01');
      expect(bars.single.spent, -4200);
    });

    test('weeks over New Year: Dec 28 - Jan 3 is one bucket holding both years', () {
      final r = [
        row('2026-12-27', -100, 'Groceries'),
        row('2026-12-31', -2000, 'Groceries'),
        row('2027-01-01', -30, 'Groceries'),
        row('2027-01-03', -4, 'Groceries'),
        row('2027-01-04', -500, 'Groceries'),
      ];
      final bars = spendingSeries(ix(r), dr('2026-12-21', '2027-01-10'), Bucket.week, today: '2027-02-01');
      expect(bars.map((e) => e.spent).toList(), [100, 2034, 500]);
      final months = spendingSeries(ix(r), dr('2026-12-01', '2027-01-31'), Bucket.month, today: '2027-02-01');
      expect(months.map((e) => e.spent).toList(), [2100, 534]);
    });

    test('the DST change 2026-10-25: rows on 24, 25 and 26 Oct land on their own days and weeks', () {
      final r = [row('2026-10-24', -10, 'Groceries'), row('2026-10-25', -200, 'Groceries'), row('2026-10-26', -3000, 'Groceries')];
      final w = dr('2026-10-19', '2026-11-01');
      expect(spendingSeries(ix(r), w, Bucket.day, today: '2026-12-01').map((e) => e.spent).toList().sublist(5, 8), [10, 200, 3000]);
      expect(spendingSeries(ix(r), w, Bucket.week, today: '2026-12-01').map((e) => e.spent).toList(), [210, 3000]);
    });

    test('leap day 2028-02-29 counts in February and in the week of Mon 2028-02-28', () {
      final r = [row('2028-02-28', -1, 'Groceries'), row('2028-02-29', -20, 'Groceries'), row('2028-03-01', -300, 'Groceries')];
      final m = spendingSeries(ix(r), dr('2028-02-01', '2028-03-31'), Bucket.month, today: '2028-06-01');
      expect(m.map((e) => e.spent).toList(), [21, 300]);
      expect(m.first.span.end, '2028-02-29');
      final w = spendingSeries(ix(r), dr('2028-02-21', '2028-03-12'), Bucket.week, today: '2028-06-01');
      expect(w.map((e) => e.spent).toList(), [0, 321, 0]);
      final d = spendingSeries(ix(r), dr('2028-02-28', '2028-03-01'), Bucket.day, today: '2028-06-01');
      expect(d.map((e) => e.spent).toList(), [1, 20, 300]);
    });

    test('quarters: sum of three months', () {
      final r = [
        row('2026-07-01', -100, 'Groceries'),
        row('2026-08-31', -20, 'Groceries'),
        row('2026-09-30', -3, 'Groceries'),
        row('2026-10-01', -9000, 'Groceries'),
      ];
      final q = spendingSeries(ix(r), dr('2026-07-01', '2026-12-31'), Bucket.quarter, today: '2027-02-01');
      expect(q.map((e) => e.spent).toList(), [123, 9000]);
    });

    test('a window without data still returns the right number of zero bars', () {
      final bars = spendingSeries(ix(const []), dr('2026-10-01', '2026-10-31'), Bucket.week, today: today);
      expect(bars.length, 5);
      expect(bars.map((e) => e.spent).toSet(), {0});
    });

    test('category, tag and merchant filters', () {
      final r = [
        row('2026-10-12', -1000, 'Groceries', desc: 'POS LIDL HRVATSKA ZAGREB'),
        withTags(row('2026-10-13', -200, 'Groceries', desc: 'POS SPAR 0000 ZAGREB'), const [t1]),
        withTags(row('2026-10-20', -30, 'Shopping', desc: 'POS ZARA ZAGREB'), const [t1]),
        row('2026-10-21', 5, 'Groceries', desc: 'POS LIDL HRVATSKA ZAGREB'),
      ];
      final w = dr('2026-10-12', '2026-10-25');
      final i = ix(r);
      List<int> weeks({String? category, String? tag, String? merchantKey}) =>
          spendingSeries(i, w, Bucket.week, today: '2026-12-01', category: category, tag: tag, merchantKey: merchantKey)
              .map((e) => e.spent)
              .toList();
      expect(weeks(), [1200, 25]);
      expect(weeks(category: 'Groceries'), [1200, -5]);
      expect(weeks(category: 'Shopping'), [0, 30]);
      expect(weeks(tag: t1), [200, 30]);
      expect(weeks(merchantKey: merchantKey(r[0].tx)), [1000, -5]);
    });

    test('partial: the bucket holding today, and clipped edge buckets; others are whole', () {
      List<bool> partials(DateRange w, Bucket b, String t) => [for (final e in spendingSeries(ix(const []), w, b, today: t)) e.partial];
      // days: only today
      expect(partials(dr('2026-10-17', '2026-10-22'), Bucket.day, today), [false, false, false, true, false, false]);
      // weeks: clipped first and last
      expect(partials(dr('2026-10-07', '2026-11-12'), Bucket.week, '2027-01-01'), [true, false, false, false, false, true]);
      // the week of today (Tue 2026-10-20 -> Mon 19 .. Sun 25) although it is whole
      expect(partials(dr('2026-10-05', '2026-10-25'), Bucket.week, today), [false, false, true]);
      // months: clipped Aug and Oct, whole Sep
      expect(partials(dr('2026-08-15', '2026-10-10'), Bucket.month, '2027-01-01'), [true, false, true]);
      // a whole window, today inside the last month: that month is partial, the others not
      expect(partials(dr('2026-08-01', '2026-10-31'), Bucket.month, today), [false, false, true]);
      // quarters
      expect(partials(dr('2026-01-01', '2026-12-31'), Bucket.quarter, today), [false, false, false, true]);
      expect(partials(dr('2026-02-10', '2026-12-31'), Bucket.quarter, '2027-01-01'), [true, false, false, false]);
    });
  });

  group('equalities with the month functions (whole months)', () {
    final rows = [
      for (final t in mixedWallet()) t.date.compareTo('2026-04-15') > 0 && t.date.compareTo('2026-05-10') < 0 ? withTags(t, const [t1]) : t,
    ];
    final index = ix(rows);
    final w = dr('2026-04-01', '2026-10-31');

    test('spendingSeries month buckets == spendingByMonth (spent and partial)', () {
      final old = spendingByMonth(rows, w, currency: 'EUR', today: today);
      final bars = spendingSeries(index, w, Bucket.month, today: today);
      expect(bars.length, old.length);
      for (var k = 0; k < old.length; k++) {
        expect(bars[k].span.start, '${old[k].month}-01');
        expect(bars[k].spent, old[k].spent, reason: old[k].month);
        expect(bars[k].partial, old[k].partial, reason: old[k].month);
      }
    });

    test('with a tag == tagTrend', () {
      final old = tagTrend(t1, rows, w, today: today, currency: 'EUR');
      final bars = spendingSeries(index, w, Bucket.month, today: today, tag: t1);
      expect(old.fold<int>(0, (s, e) => s + e.spent), isNot(0));
      expect(bars.map((e) => e.spent).toList(), old.map((e) => e.spent).toList());
      expect(bars.map((e) => e.partial).toList(), old.map((e) => e.partial).toList());
    });

    test('with a merchant == merchantTrend', () {
      final lidl = row('2026-06-04', -1234, 'Groceries', desc: 'POS LIDL HRVATSKA ZAGREB');
      final all = [...rows, lidl, row('2026-08-04', -777, 'Groceries', desc: 'POS LIDL HRVATSKA ZAGREB')];
      final key = merchantKey(lidl.tx);
      final old = merchantTrend('Groceries', key, all, w, today: today, currency: 'EUR');
      final bars = spendingSeries(ix(all), w, Bucket.month, today: today, merchantKey: key);
      expect(bars.map((e) => e.spent).toList(), old.map((e) => e.spent).toList());
    });
  });

  group('incomeSeries', () {
    test('income, extra, spent and net per bucket in exact cents', () {
      final r = [
        row('2026-10-05', 200000, 'Salary'), // Mon, week 1
        row('2026-10-06', 5000, 'Extra income'),
        row('2026-10-07', -1500, 'Groceries'),
        row('2026-10-08', 200, 'Groceries'), // refund
        row('2026-10-09', 99999, 'Internal transfer'),
        row('2026-10-13', -400, 'Shopping'), // week 2
        row('2026-10-14', 777, 'Salary', currency: 'USD'),
      ];
      final bars = incomeSeries(ix(r), dr('2026-10-05', '2026-10-18'), Bucket.week, today: '2026-12-01');
      expect(bars.length, 2);
      expect(bars[0].income, 200000);
      expect(bars[0].extra, 5000);
      expect(bars[0].spent, 1300);
      expect(bars[0].net, 200000 + 5000 - 1300);
      expect(bars[1].income, 0);
      expect(bars[1].spent, 400);
      expect(bars[1].net, -400);
      expect(bars.map((e) => e.partial), [false, false]);
    });

    test('buckets add up to the window; partial for today and clipped edges', () {
      final rows = mixedWallet();
      final i = ix(rows);
      final w = dr('2026-04-10', '2026-10-20');
      for (final b in Bucket.values) {
        final bars = incomeSeries(i, w, b, today: today);
        expect(bars.fold<int>(0, (s, e) => s + e.spent), oracle(rows, w), reason: '$b');
        expect(bars.fold<int>(0, (s, e) => s + e.income), i.income(w), reason: '$b');
        expect(bars.first.partial, b != Bucket.day, reason: '$b first (clipped)');
        expect(bars.last.partial, isTrue, reason: '$b holds today');
      }
    });
  });

  group('budgetSeries pro-rating (spec §4, §6 Q2)', () {
    final table = CategoryTable.builtIn;
    final empty = ix(const []);
    List<BudgetBar> series(Map<String, int> budgets, DateRange w, Bucket b, {DayIndex? index, String? category, String t = '2027-06-01'}) =>
        budgetSeries(index ?? empty, w, b, budgets, today: t, table: table, category: category);

    test('1000 cents over 31 days: the first 8 days get 33, the other 23 get 32 (largest remainder, earlier day first)', () {
      final days = series({'Groceries': 1000}, dr('2026-10-01', '2026-10-31'), Bucket.day);
      expect(days.length, 31);
      expect(days.map((e) => e.budgeted).toList(), [...List.filled(8, 33), ...List.filled(23, 32)]);
      expect(days.fold<int>(0, (s, e) => s + e.budgeted), 1000);
      expect(days.every((e) => e.prorated), isTrue);
    });

    test('1 cent over 30 days: the first day gets it, the sum is exactly 1', () {
      final days = series({'Groceries': 1}, dr('2026-11-01', '2026-11-30'), Bucket.day);
      expect(days.map((e) => e.budgeted).toList(), [1, ...List.filled(29, 0)]);
    });

    test('0 budget: every share is 0; a category without a budget adds nothing', () {
      final days = series({'Groceries': 0}, dr('2026-10-01', '2026-10-31'), Bucket.day);
      expect(days.map((e) => e.budgeted).toSet(), {0});
      final none = series({'Groceries': 500}, dr('2026-10-01', '2026-10-31'), Bucket.month, category: 'Shopping');
      expect(none.single.budgeted, 0);
    });

    test('every month adds up exactly, whatever its length (28, 29, 30, 31 days) and budget', () {
      for (final (month, last) in [('2026-02', 28), ('2028-02', 29), ('2026-04', 30), ('2026-10', 31)]) {
        for (final cents in [0, 1, 7, 29, 30, 31, 1000, 99999, 123457]) {
          final days = series({'Groceries': cents}, dr('$month-01', '$month-$last'), Bucket.day);
          expect(days.length, last);
          expect(days.fold<int>(0, (s, e) => s + e.budgeted), cents, reason: '$month $cents');
          final base = cents ~/ last;
          expect(days.every((e) => e.budgeted == base || e.budgeted == base + 1), isTrue, reason: '$month $cents');
          // earlier days never get less than later ones
          for (var k = 1; k < days.length; k++) {
            expect(days[k].budgeted, lessThanOrEqualTo(days[k - 1].budgeted), reason: '$month $cents #$k');
          }
        }
      }
    });

    test('different month lengths give different shares for the same budget (Feb 2028: 29 days)', () {
      final feb = series({'Groceries': 1000}, dr('2028-02-01', '2028-02-29'), Bucket.day);
      expect(feb.map((e) => e.budgeted).toList(), [...List.filled(14, 35), ...List.filled(15, 34)]);
    });

    test('a week inside one month is the sum of its days', () {
      final w = series({'Groceries': 1000}, dr('2026-10-05', '2026-10-11'), Bucket.week);
      // Oct 5..11 are days 5..11: days 5-8 get 33, days 9-11 get 32
      expect(w.single.budgeted, 4 * 33 + 3 * 32);
      expect(w.single.prorated, isTrue);
    });

    test('a week spanning two months takes each month\'s day shares (1000 cents: Oct 32 a day, Nov day 1 gets 34)', () {
      // Mon 2026-10-26 .. Sun 2026-11-01: six October days (days 26..31, 32 each), then 1 Nov (1000 / 30 = 33 rem 10: day 1 gets 34)
      final w = series({'Groceries': 1000}, dr('2026-10-26', '2026-11-01'), Bucket.week);
      expect(w.single.budgeted, 6 * 32 + 34);
      // 1 cent: October's cent sits on 1 Oct, November's on 1 Nov
      final one = series({'Groceries': 1}, dr('2026-10-26', '2026-11-01'), Bucket.week);
      expect(one.single.budgeted, 1);
    });

    test('3100 cents: Oct is 100 a day, Nov is 103 (+1 on days 1-10); weeks across and inside Nov', () {
      final w = series({'Groceries': 3100}, dr('2026-10-26', '2026-11-01'), Bucket.week);
      expect(w.single.budgeted, 6 * 100 + 104);
      final w2 = series({'Groceries': 3100}, dr('2026-11-02', '2026-11-08'), Bucket.week);
      expect(w2.single.budgeted, 7 * 104);
      final w3 = series({'Groceries': 3100}, dr('2026-11-09', '2026-11-15'), Bucket.week);
      expect(w3.single.budgeted, 2 * 104 + 5 * 103); // Nov 9, 10 get 104, Nov 11..15 get 103
    });

    test('the weeks of a window add up to the days of the window', () {
      final b = {'Groceries': 1000, 'Shopping': 777, 'Rent': 45000};
      final w = dr('2026-09-28', '2026-11-01'); // Mon .. Sun, five whole weeks over Sep/Oct
      final weeks = series(b, w, Bucket.week);
      final days = series(b, w, Bucket.day);
      expect(weeks.length, 5);
      expect(weeks.fold<int>(0, (s, e) => s + e.budgeted), days.fold<int>(0, (s, e) => s + e.budgeted));
      for (final wk in weeks) {
        expect(wk.budgeted, days.where((d) => wk.span.contains(d.span.start)).fold<int>(0, (s, e) => s + e.budgeted));
      }
    });

    test('month and quarter buckets equal the plain month budgets and are not prorated', () {
      final b = {'Groceries': 1000, 'Shopping': 777, 'Rent': 45000};
      final months = series(b, dr('2026-07-01', '2026-09-30'), Bucket.month);
      expect(months.map((e) => e.budgeted).toList(), [46777, 46777, 46777]);
      expect(months.every((e) => !e.prorated), isTrue);
      final q = series(b, dr('2026-07-01', '2026-09-30'), Bucket.quarter);
      expect(q.single.budgeted, 3 * 46777);
      expect(q.single.prorated, isFalse);
      expect(q.single.bucket, Bucket.quarter);
    });

    test('prorated is true for day and week, false for month and quarter', () {
      final w = dr('2026-07-01', '2026-09-30');
      expect(series({'Groceries': 9}, w, Bucket.day).every((e) => e.prorated), isTrue);
      expect(series({'Groceries': 9}, w, Bucket.week).every((e) => e.prorated), isTrue);
      expect(series({'Groceries': 9}, w, Bucket.month).any((e) => e.prorated), isFalse);
      expect(series({'Groceries': 9}, w, Bucket.quarter).any((e) => e.prorated), isFalse);
    });

    test('actual and over per bucket: over = max(0, actual - budgeted)', () {
      final r = [
        row('2026-10-05', -5000, 'Groceries'),
        row('2026-10-12', -100, 'Groceries'),
        row('2026-10-13', -9999, 'Shopping'), // not budgeted: never counts
        row('2026-10-14', 20, 'Groceries'), // refund
      ];
      final bars = series({'Groceries': 1000}, dr('2026-10-05', '2026-10-18'), Bucket.week, index: ix(r));
      expect(bars[0].budgeted, 4 * 33 + 3 * 32); // 228
      expect(bars[0].actual, 5000);
      expect(bars[0].over, 5000 - 228);
      expect(bars[1].budgeted, 7 * 32); // Oct 12..18 are all in the 32-cent days
      expect(bars[1].actual, 80);
      expect(bars[1].over, 0);
    });

    test('over is zero when exactly on budget or under', () {
      final r = [row('2026-10-09', -32, 'Groceries')];
      final d = series({'Groceries': 1000}, dr('2026-10-09', '2026-10-10'), Bucket.day, index: ix(r));
      expect(d[0].budgeted, 32);
      expect(d[0].actual, 32);
      expect(d[0].over, 0);
      expect(d[1].over, 0);
    });

    test('the category argument limits actual and budget to that category', () {
      final r = [row('2026-10-09', -40, 'Groceries'), row('2026-10-09', -10, 'Shopping')];
      final b = {'Groceries': 1000, 'Shopping': 3100};
      final g = series(b, dr('2026-10-09', '2026-10-09'), Bucket.day, index: ix(r), category: 'Groceries').single;
      expect(g.budgeted, 32);
      expect(g.actual, 40);
      expect(g.over, 8);
      final s = series(b, dr('2026-10-09', '2026-10-09'), Bucket.day, index: ix(r), category: 'Shopping').single;
      expect(s.budgeted, 100);
      expect(s.actual, 10);
    });

    test('partial: today, clipped edges', () {
      final bars = series({'Groceries': 1000}, dr('2026-10-07', '2026-11-12'), Bucket.week, t: '2027-01-01');
      expect(bars.map((e) => e.partial).toList(), [true, false, false, false, false, true]);
      final cur = series({'Groceries': 1000}, dr('2026-08-01', '2026-10-31'), Bucket.month, t: today);
      expect(cur.map((e) => e.partial).toList(), [false, false, true]);
    });

    test('equals budgetVsActualSeries for whole months (budgeted, actual, over)', () {
      final rows = mixedWallet();
      final b = {'Groceries': 20000, 'Eating out': 8000, 'Shopping': 15000, 'Car & transport': 30000, 'Rent': 45000};
      final w = dr('2026-04-01', '2026-09-30');
      final old = budgetVsActualSeries(rows, w, b, today: '2026-12-15', currency: 'EUR', table: table);
      final bars = budgetSeries(ix(rows), w, Bucket.month, b, today: '2026-12-15', table: table);
      expect(bars.length, old.length);
      for (var k = 0; k < old.length; k++) {
        expect(bars[k].span.start, '${old[k].month}-01');
        expect(bars[k].budgeted, old[k].budgeted, reason: old[k].month);
        expect(bars[k].actual, old[k].actual, reason: old[k].month);
      }
      final one = budgetVsActualSeries(rows, w, {'Groceries': 20000}, today: '2026-12-15', currency: 'EUR', table: table);
      final oneBars = budgetSeries(ix(rows), w, Bucket.month, {'Groceries': 20000}, today: '2026-12-15', table: table);
      expect(oneBars.map((e) => e.over).toList(), one.map((e) => e.over).toList());
    });

    test('the pro-rated days of a month hold the month actual and budget (sum of day bars)', () {
      final rows = mixedWallet();
      final b = {'Groceries': 20000, 'Shopping': 15000};
      final w = dr('2026-06-01', '2026-06-30');
      final month = budgetSeries(ix(rows), w, Bucket.month, b, today: '2026-12-15', table: table).single;
      final days = budgetSeries(ix(rows), w, Bucket.day, b, today: '2026-12-15', table: table);
      expect(days.fold<int>(0, (s, e) => s + e.budgeted), month.budgeted);
      expect(days.fold<int>(0, (s, e) => s + e.actual), month.actual);
    });
  });
}
