// ENG_UI_SPEC §6.2 (findings engine), written from the spec and the lead's decisions, not the implementation.
// SYNTHETIC rows only: made-up amounts, built-in categories. Fixed clock: today = 2026-10-20 (the window ends in 2026-10).
// A main tag = the row's resolved category. Thresholds are integer ratios; r comes from exact integer sums.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';

const today = '2026-10-20';
const st = WalletSettings();
final table = CategoryTable.builtIn;

List<Finding> fin(List<CategorizedTx> rows,
        {WalletSettings s = st, List<String> reviewDates = const [], List<RecurringBill> bills = const []}) =>
    findings(rows, s, table, today, reviewDates: reviewDates, bills: bills);

List<Finding> kindOf_(List<Finding> fs, FindingKind k) => [
      for (final f in fs)
        if (f.kind == k) f
    ];

/// [n] consecutive `YYYY-MM` months from [from].
List<String> months(String from, int n) {
  var y = int.parse(from.substring(0, 4)), m = int.parse(from.substring(5));
  final out = <String>[];
  for (var i = 0; i < n; i++) {
    out.add('$y-${m.toString().padLeft(2, '0')}');
    if (++m == 13) {
      m = 1;
      y++;
    }
  }
  return out;
}

/// One payment of [cents] (positive = money out) in [category] on the 5th of [month].
CategorizedTx pay(String month, int cents, String category, {String desc = '', String currency = 'EUR', bool deleted = false}) =>
    row('$month-05', -cents, category, desc: desc, currency: currency, deleted: deleted);

/// 12 months 2025-10..2026-09 of [usual] cents in Groceries, then this month ([thisMonth] cents, on the 5th).
List<CategorizedTx> usualThen(int usual, int thisMonth, {int history = 12, List<CategorizedTx> extra = const []}) => [
      pay('2026-10', thisMonth, 'Groceries'),
      for (final m in months('2025-10', 12).skip(12 - history)) pay(m, usual, 'Groceries'),
      ...extra,
    ];

// Monthly totals with exactly r = 0.5 and r = 0.7 (found by search; Sxy^2 * 4 = Sxx*Syy and Sxy^2 * 100 = 49 * Sxx*Syy).
const x50 = [1, 5, 6, 6, 6, 3, 1, 4, 1, 3, 5, 3], y50 = [1, 2, 6, 4, 5, 5, 4, 3, 1, 3, 4, 6];
const x70 = [6, 2, 1, 4, 6, 3, 1, 5, 3, 2, 5, 2], y70 = [4, 1, 1, 5, 4, 4, 1, 6, 5, 4, 4, 1];

/// Two categories whose monthly totals (in thousand cents) are [a] and [b], over the months from 2025-10 (12 = up to 2026-09, the last full month).
List<CategorizedTx> pair(List<int> a, List<int> b, {String ca = 'Groceries', String cb = 'Shopping'}) {
  final ms = months('2025-10', a.length);
  return [
    for (var i = 0; i < a.length; i++) ...[pay(ms[i], a[i] * 1000, ca), pay(ms[i], b[i] * 1000, cb)]
  ];
}

List<Finding> moves(List<CategorizedTx> rows) => kindOf_(fin(rows), FindingKind.movesTogether);

/// A daily wallet 2025-10-01..2026-10-20 in Eating out: [peak] cents on Saturdays, [base] on other days.
List<CategorizedTx> daily(int base, int peak) {
  final out = <CategorizedTx>[];
  for (var d = '2025-10-01'; d.compareTo(today) <= 0; d = addDays(d, 1)) {
    out.add(row(d, -(DateTime.parse(d).weekday == DateTime.saturday ? peak : base), 'Eating out'));
  }
  return out;
}

void main() {
  test('every id is <kind>:<subjectKey>[:<otherKey>]:<YYYY-MM>', () {
    final fs = fin(usualThen(10000, 12500));
    expect(fs, isNotEmpty);
    for (final f in fs) {
      // weeklyRhythm and movesTogether end in the last full month (pinned rule); the others here in this month.
      final end = f.kind == FindingKind.weeklyRhythm || f.kind == FindingKind.movesTogether ? '2026-09' : '2026-10';
      final parts = [f.kind.name, f.subjectKey, if (f.otherKey != null) f.otherKey, end];
      expect(f.id, parts.join(':'));
    }
  });

  group('aboveUsual: 1.25 x the 12-month median, >= 6 months of history, >= 2000 cents more', () {
    List<Finding> above(List<CategorizedTx> r) => kindOf_(fin(r), FindingKind.aboveUsual);

    test('exactly 1.25 x fires, with the ratio in permille', () {
      final fs = above(usualThen(10000, 12500));
      expect(fs, hasLength(1));
      expect(fs.single.subjectKey, 'Groceries');
      expect(fs.single.id, 'aboveUsual:Groceries:2026-10');
      expect(fs.single.ratioPermille, 1250);
    });
    test('1 cent below 1.25 x does not fire; 1 cent above does', () {
      expect(above(usualThen(10000, 12499)), isEmpty);
      expect(above(usualThen(10000, 12501)), hasLength(1));
    });
    test('the difference must be >= 2000 cents: ratio 1.4 but only 1500 more is quiet', () {
      expect(above(usualThen(5000, 7000)), hasLength(1)); // exactly 2000 more, 1.4 x
      expect(above(usualThen(5000, 6999)), isEmpty); // 1999 more
      expect(above(usualThen(6000, 7500)), isEmpty); // 1.25 x but 1500 more
    });
    test('needs 6 months of history: 6 fire, 4 do not', () {
      expect(above(usualThen(10000, 15000, history: 6)), hasLength(1));
      expect(above(usualThen(10000, 15000, history: 4)), isEmpty);
    });
    test('the median, not the mean: one huge month in the history does not hide a spike', () {
      final r = usualThen(10000, 12500)..add(pay('2026-01', 500000, 'Groceries'));
      expect(above(r), hasLength(1));
    });
    test('refunds are subtracted: 15000 spent, 3000 refunded = 12000 (quiet); 15500 - 3000 = 12500 fires', () {
      final refund = row('2026-10-12', 3000, 'Groceries');
      expect(above(usualThen(10000, 15000, extra: [refund])), isEmpty);
      expect(above(usualThen(10000, 15500, extra: [refund])), hasLength(1));
    });
    test('own transfers, IOU-linked rows, deleted rows and other currencies never count', () {
      final iou = row('2026-10-07', -5000, 'Groceries');
      final extras = [
        row('2026-10-06', -5000, 'Internal transfer'),
        CategorizedTx(iou.tx, 'Groceries', BudgetKind.transfer, iou: true),
        pay('2026-10', 5000, 'Groceries', deleted: true),
        pay('2026-10', 5000, 'Groceries', currency: 'USD'),
      ];
      expect(above(usualThen(10000, 12499, extra: extras)), isEmpty);
    });
    test('the same extras in the history do not move the median either', () {
      final extras = [for (final m in months('2025-10', 12)) pay(m, 90000, 'Groceries', currency: 'USD')];
      expect(above(usualThen(10000, 12500, extra: extras)), hasLength(1));
      expect(above(usualThen(10000, 12499, extra: extras)), isEmpty);
    });
  });

  group('weeklyRhythm: busiest weekday mean >= 1.6 x the quietest', () {
    List<Finding> rhythm(List<CategorizedTx> r) => kindOf_(fin(r), FindingKind.weeklyRhythm);
    test('exactly 1.6 fires (ratio 1600 permille)', () {
      final fs = rhythm(daily(1000, 1600));
      expect(fs, hasLength(1));
      expect(fs.single.subjectKey, 'all');
      expect(fs.single.id, 'weeklyRhythm:all:2026-09'); // ends in the last full month
      expect(fs.single.ratioPermille, 1600);
      expect(fs.single.series.map((e) => e.$1).toList(), ['1', '2', '3', '4', '5', '6', '7']);
    });
    test('fewer than 6 tracked months in the window: quiet', () {
      final r = [
        for (final f in daily(1000, 3000))
          if (f.date.compareTo('2026-05-01') >= 0) f
      ];
      expect(rhythm(r), isEmpty);
    });
    test('a quiet weekday with no spending at all fires with no ratio (null)', () {
      final r = [
        for (final f in daily(1000, 3000))
          if (DateTime.parse(f.date).weekday == DateTime.saturday) f
      ];
      final fs = rhythm(r);
      expect(fs, hasLength(1));
      expect(fs.single.ratioPermille, isNull);
    });
    test('1599 / 1000 does not fire, 1601 / 1000 does', () {
      expect(rhythm(daily(1000, 1599)), isEmpty);
      expect(rhythm(daily(1000, 1601)), isNotEmpty);
    });
    test('an even week is quiet', () => expect(rhythm(daily(1000, 1000)), isEmpty));
    test('refunds and other currencies do not make a rhythm', () {
      final r = daily(1000, 1000);
      for (var d = '2026-01-01'; d.compareTo('2026-03-31') <= 0; d = addDays(d, 1)) {
        if (DateTime.parse(d).weekday == DateTime.sunday) r.add(row(d, -5000, 'Eating out', currency: 'USD'));
      }
      expect(rhythm(r), isEmpty);
    });
  });

  group('movesTogether: |r| >= 0.5 over >= 12 shared months', () {
    test('r = 0.5 exactly fires, "strength" 500 permille', () {
      final fs = moves(pair(x50, y50));
      expect(fs, hasLength(1));
      expect(fs.single.strengthPermille!.abs(), 500);
      expect(fs.single.subjectKey, 'Groceries'); // alphabetical: subject < other
      expect(fs.single.otherKey, 'Shopping');
      expect(fs.single.series.length, fs.single.otherSeries.length);
      expect(fs.single.n, 12);
    });
    test('r just below 0.5 (0.485) is quiet, just above (0.501) fires', () {
      final below = [...y50]..[9] += 1, above = [...y50]..[9] -= 1;
      expect(moves(pair(x50, below)), isEmpty);
      expect(moves(pair(x50, above)), hasLength(1));
    });
    test('r = 0.7 exactly is strong (700), 0.698 is not', () {
      final fs = moves(pair(x70, y70));
      expect(fs.single.strengthPermille!.abs(), 700);
      final just = [...y70]..[7] -= 1; // r = 0.6979
      final fs2 = moves(pair(x70, just));
      expect(fs2, hasLength(1));
      expect(fs2.single.strengthPermille!.abs(), lessThan(700));
      expect(fs2.single.strengthPermille!.abs(), greaterThanOrEqualTo(500));
    });
    test('negative r (7 - y) fires with a negative strength', () {
      final fs = moves(pair(x50, [for (final v in y50) 7 - v]));
      expect(fs, hasLength(1));
      expect(fs.single.strengthPermille, -500);
    });
    test('11 shared months are not enough, even with r = 1', () {
      expect(moves(pair(x50.take(11).toList(), x50.take(11).toList())), isEmpty);
      expect(moves(pair(x50, x50)), hasLength(1));
    });
    test('months where only one of the two paid do not count as shared', () {
      final r = pair(x50, x50)..removeWhere((t) => t.category == 'Shopping' && t.date.startsWith('2026-09'));
      expect(moves(r), isEmpty); // Shopping misses 2026-09 only: 11 shared
    });
    test('a flat series has no correlation (no division by zero)', () {
      expect(moves(pair(x50, List.filled(12, 3))), isEmpty);
    });
    test('only the top 8 main tags by spend are paired: 9 tags that all move together give 28 pairs, none with the 9th', () {
      const cats = [
        'Groceries', 'Food delivery', 'Eating out', 'Car & transport', 'Shopping', //
        'Home & tools', 'Sport & fitness', 'Health & care', 'Games & apps', // the smallest spender
      ];
      final ms = months('2025-10', 12);
      final rows = [
        for (var j = 0; j < cats.length; j++)
          for (var i = 0; i < 12; i++) pay(ms[i], x50[i] * 1000 * (10 - j), cats[j]),
      ];
      final fs = moves(rows);
      expect(fs, hasLength(28));
      for (final f in fs) {
        expect(f.subjectKey, isNot('Games & apps'));
        expect(f.otherKey, isNot('Games & apps'));
        expect(f.strengthPermille, 1000);
      }
    });
    test('refunds are subtracted from a month, transfers and foreign rows are ignored', () {
      final base = pair(x50, y50);
      // A foreign-currency and a transfer row on every month change nothing.
      final noisy = [
        ...base,
        for (final m in months('2025-10', 12)) ...[
          pay(m, 777000, 'Groceries', currency: 'USD'),
          row('$m-06', -333000, 'Internal transfer'),
          pay(m, 999000, 'Shopping', deleted: true),
        ],
      ];
      expect(moves(noisy).single.strengthPermille!.abs(), 500);
      // A refund of 1000 cents in Groceries in 2025-11 (x = 5000 there) changes that month's total: the series changes.
      final refunded = [...base, row('2025-11-20', 1000, 'Groceries')];
      expect(moves(refunded).single.strengthPermille!.abs(), isNot(500));
    });
    test('this month (not a full month) is left out', () {
      final r = [...pair(x50, y50), pay('2026-10', 1000000, 'Groceries'), pay('2026-10', 1000, 'Shopping')];
      expect(moves(r).single.strengthPermille!.abs(), 500);
    });
  });

  group('slowCreep: a confirmed bill whose monthly amount rose >= 25 % over >= 12 months', () {
    RecurringBill bill(CategorizedTx sample, {String status = 'confirmed', String? payee, String? direction}) => RecurringBill(
          id: 'bill-1',
          payee: payee ?? merchantKey(sample.tx),
          label: 'Streaming',
          category: 'Bills & subscriptions',
          expectedAmount: 1000,
          nextDue: '2026-11-05',
          status: status,
          direction: direction,
        );
    CategorizedTx sub(String month, int cents) => pay(month, cents, 'Bills & subscriptions', desc: 'POS NETFLIX.COM');
    // Earliest month 2025-09 at 1000; the latest full month with a payment is 2026-09 (12 months later); this month is quiet.
    List<CategorizedTx> rows(int latest, {String first = '2025-09'}) => [sub(first, 1000), sub('2026-09', latest), sub('2026-10', 1000)];
    List<Finding> creep(List<CategorizedTx> r, {RecurringBill? b}) => kindOf_(fin(r, bills: [b ?? bill(r.first)]), FindingKind.slowCreep);

    test('exactly +25 % fires; subjectKey is the bill id', () {
      final fs = creep(rows(1250));
      expect(fs, hasLength(1));
      expect(fs.single.subjectKey, 'bill-1');
      expect(fs.single.id, startsWith('slowCreep:bill-1:'));
    });
    test('1249 does not fire, 1251 and 2000 do', () {
      expect(creep(rows(1249)), isEmpty);
      expect(creep(rows(1251)), hasLength(1));
      expect(creep(rows(2000)), hasLength(1));
    });
    test('11 months apart is not enough (needs >= 12)', () {
      expect(creep(rows(2000, first: '2025-10')), isEmpty);
    });
    test('this month (partial) is not the latest figure', () {
      final r = [sub('2025-09', 1000), sub('2026-09', 1249), sub('2026-10', 5000)];
      expect(creep(r), isEmpty);
    });
    test('a candidate or dismissed bill, an income and a bill with no payee never fire', () {
      final r = rows(2000);
      expect(creep(r, b: bill(r.first, status: 'candidate')), isEmpty);
      expect(creep(r, b: bill(r.first, status: 'dismissed')), isEmpty);
      expect(creep(r, b: bill(r.first, direction: 'in')), isEmpty);
      expect(creep(r, b: bill(r.first, payee: '')), isEmpty);
    });
    test('rows of another payee do not feed the bill', () {
      final r = rows(1249)..add(pay('2026-09', 9000, 'Bills & subscriptions', desc: 'POS SPOTIFY'));
      expect(creep(r, b: bill(r.first)), isEmpty);
    });
    test('IOU-linked rows, transfers, deleted rows and other currencies of the payee are not counted', () {
      final iou = sub('2026-09', 5000);
      final r = rows(1249)
        ..add(CategorizedTx(iou.tx, 'Bills & subscriptions', BudgetKind.transfer, iou: true))
        ..add(row('2026-09-07', -5000, 'Internal transfer', desc: 'POS NETFLIX.COM'))
        ..add(pay('2026-09', 5000, 'Bills & subscriptions', desc: 'POS NETFLIX.COM', deleted: true))
        ..add(pay('2026-09', 5000, 'Bills & subscriptions', desc: 'POS NETFLIX.COM', currency: 'USD'));
      expect(creep(r, b: bill(r.first)), isEmpty);
    });
    test('a month is the sum of its rows (700 + 550 = 1250 fires, 700 + 549 does not)', () {
      final r = [sub('2025-09', 1000), sub('2026-09', 700), sub('2026-09', 550), sub('2026-10', 1000)];
      expect(creep(r, b: bill(r.first)), hasLength(1));
      final q = [sub('2025-09', 1000), sub('2026-09', 700), sub('2026-09', 549), sub('2026-10', 1000)];
      expect(creep(q, b: bill(q.first)), isEmpty);
    });
    test('no bills given: no slowCreep', () => expect(kindOf_(fin(rows(2000)), FindingKind.slowCreep), isEmpty));
  });

  group('seasonality: the same calendar month is the max of a main tag in >= 3 years', () {
    List<CategorizedTx> years(Map<int, String> peakMonthOf) => [
          for (final e in peakMonthOf.entries)
            for (final m in months('${e.key}-01', 12)) pay(m, m.endsWith(e.value) ? 5000 : 1000, 'Shopping'),
        ];
    List<Finding> season(List<CategorizedTx> r) => kindOf_(fin(r), FindingKind.seasonality);

    test('December is the peak in 3 years: fires for Shopping', () {
      final fs = season(years({2023: '-12', 2024: '-12', 2025: '-12'}));
      expect(fs, hasLength(1));
      expect(fs.single.subjectKey, 'Shopping');
      expect(fs.single.otherKey, '12');
      expect(fs.single.n, 3);
      expect(fs.single.id, 'seasonality:Shopping:12:2025-12'); // ends in December of the last such year
    });
    test('a year that was not fully tracked (first row in February 2023) does not count', () {
      final r = years({2023: '-12', 2024: '-12', 2025: '-12'})..removeWhere((t) => t.date.startsWith('2023-01'));
      expect(season(r), isEmpty);
    });
    test('only 2 years is quiet', () => expect(season(years({2024: '-12', 2025: '-12'})), isEmpty));
    test('3 years with a different peak month in one is quiet', () {
      expect(season(years({2023: '-12', 2024: '-12', 2025: '-11'})), isEmpty);
    });
    test('foreign-currency and deleted spikes do not make a season', () {
      final r = years({2024: '-12', 2025: '-12'})
        ..add(pay('2023-12', 90000, 'Shopping', currency: 'USD'))
        ..add(pay('2023-12', 90000, 'Shopping', deleted: true));
      expect(season(r), isEmpty);
    });
  });

  group('milestone: subjects days, payments, streak; the highest level reached fires', () {
    Finding? sub(List<CategorizedTx> r, String subject, {List<String> dates = const []}) {
      final fs = kindOf_(fin(r, reviewDates: dates), FindingKind.milestone).where((f) => f.subjectKey == subject).toList();
      expect(fs.length, lessThanOrEqualTo(1), reason: 'one finding per subject');
      return fs.isEmpty ? null : fs.single;
    }

    CategorizedTx one(String d) => row(d, -100, 'Groceries');
    List<CategorizedTx> many(int k, {int dup = 0}) =>
        [for (var i = 0; i < k; i++) row('2026-10-01', -100, 'Groceries', id: 'p-${i < dup ? 0 : i}')];

    test('days: first live row to today, inclusive. 99 days none, 100 -> 100, 364 -> 100, 365 -> 365, 730 -> 730', () {
      expect(sub([one(addDays(today, -98))], 'days'), isNull);
      expect(sub([one(addDays(today, -99))], 'days')!.n, 100);
      expect(sub([one(addDays(today, -363))], 'days')!.n, 100);
      expect(sub([one(addDays(today, -364))], 'days')!.n, 365);
      expect(sub([one(addDays(today, -728))], 'days')!.n, 365);
      expect(sub([one(addDays(today, -729))], 'days')!.n, 730);
    });
    test('days: a deleted older row does not extend the tracked days', () {
      final r = [one(addDays(today, -98)), row(addDays(today, -500), -100, 'Groceries', deleted: true)];
      expect(sub(r, 'days'), isNull);
    });
    test('payments: 99 none, 100 -> 100, 499 -> 100, 500 -> 500, 1000 -> 1000', () {
      expect(sub(many(99), 'payments'), isNull);
      expect(sub(many(100), 'payments')!.n, 100);
      expect(sub(many(499), 'payments')!.n, 100);
      expect(sub(many(500), 'payments')!.n, 500);
      expect(sub(many(1000), 'payments')!.n, 1000);
    });
    test('payments count distinct live ids: a repeated id and deleted rows do not add up', () {
      expect(sub(many(100, dup: 2), 'payments'), isNull); // 99 distinct ids
      expect(sub([...many(99), row('2026-10-02', -100, 'Groceries', deleted: true)], 'payments'), isNull);
    });
    test('streak: best review streak. 3 weekly reviews none, 4 -> 4, 11 -> 4, 12 -> 12, 52 -> 52', () {
      List<String> weekly(int k) => [for (var i = 0; i < k; i++) addDays('2025-10-24', 7 * i)];
      expect(sub([], 'streak', dates: weekly(3)), isNull);
      expect(sub([], 'streak', dates: weekly(4))!.n, 4);
      expect(sub([], 'streak', dates: weekly(11))!.n, 4);
      expect(sub([], 'streak', dates: weekly(12))!.n, 12);
      expect(sub([], 'streak', dates: weekly(52))!.n, 52);
    });
    test('streak: a gap of 14 days or more ends it (best of the runs counts)', () {
      final dates = [for (var i = 0; i < 4; i++) addDays('2025-10-24', 7 * i), for (var i = 0; i < 12; i++) addDays('2026-03-06', 7 * i)];
      expect(sub([], 'streak', dates: dates)!.n, 12);
    });
    test('no data and no reviews: no milestone', () => expect(kindOf_(fin([]), FindingKind.milestone), isEmpty));
  });

  group('dismissed findings are left out', () {
    test('a dismissed id disappears, the others stay', () {
      final all = fin(usualThen(10000, 12500));
      expect(all.map((f) => f.id), contains('aboveUsual:Groceries:2026-10'));
      final left = fin(usualThen(10000, 12500), s: const WalletSettings(dismissedFindings: ['aboveUsual:Groceries:2026-10']));
      expect(left.map((f) => f.id), isNot(contains('aboveUsual:Groceries:2026-10')));
      expect(left.length, all.length - 1);
    });
    test('an id of another month stays dismissed only for its own month', () {
      final left = fin(usualThen(10000, 12500), s: const WalletSettings(dismissedFindings: ['aboveUsual:Groceries:2026-09']));
      expect(left.map((f) => f.id), contains('aboveUsual:Groceries:2026-10'));
    });
    test('repo.dismissFinding / undismissFinding round-trip and keep the newest 500', () async {
      final repo = WalletRepo.inMemory();
      await repo.dismissFinding('aboveUsual:Groceries:2026-10');
      expect(repo.settings().dismissedFindings, ['aboveUsual:Groceries:2026-10']);
      await repo.dismissFinding('aboveUsual:Groceries:2026-10'); // twice is once
      expect(repo.settings().dismissedFindings, hasLength(1));
      await repo.undismissFinding('aboveUsual:Groceries:2026-10');
      expect(repo.settings().dismissedFindings, isEmpty);
      await repo.undismissFinding('never-there'); // no error
      for (var i = 0; i < 505; i++) {
        await repo.dismissFinding('f$i');
      }
      final d = repo.settings().dismissedFindings;
      expect(d, hasLength(500));
      expect(d, contains('f504'));
      expect(d, isNot(contains('f0')));
    });
  });

  group('determinism', () {
    List<CategorizedTx> rich() => [
          ...pair(x70, y70),
          ...usualThen(10000, 15000, extra: [pay('2026-10', 4000, 'Eating out')]),
          ...daily(1000, 1700),
        ];
    test('the same input twice gives the same ids in the same order', () {
      final a = fin(rich()), b = fin(rich());
      expect(a, isNotEmpty);
      expect(a.map((f) => f.id).toList(), b.map((f) => f.id).toList());
    });
    test('order: kind enum order, then |strength| / ratio / n descending, then id', () {
      final fs = fin(rich());
      int key(Finding f) => f.strengthPermille?.abs() ?? f.ratioPermille ?? f.n;
      for (var i = 1; i < fs.length; i++) {
        final p = fs[i - 1], q = fs[i];
        expect(p.kind.index, lessThanOrEqualTo(q.kind.index), reason: '${p.id} before ${q.id}');
        if (p.kind == q.kind) {
          expect(key(p), greaterThanOrEqualTo(key(q)), reason: '${p.id} before ${q.id}');
          if (key(p) == key(q)) expect(p.id.compareTo(q.id), lessThan(0));
        }
      }
    });
    test('evidence: from/to are dates, the series labels are YYYY-MM', () {
      for (final f in fin(rich()).where((f) => f.kind == FindingKind.aboveUsual || f.kind == FindingKind.movesTogether)) {
        expect(f.from, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(f.to, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(f.from.compareTo(f.to), lessThan(0));
        expect(f.series, isNotEmpty);
        for (final e in f.series) {
          expect(e.$1, matches(RegExp(r'^\d{4}-\d{2}$')));
        }
      }
    });
    test('ids are unique', () {
      final ids = fin(rich()).map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
    });
    test('the order of the input rows (sync order) changes neither ids, order nor numbers', () {
      final a = fin(rich()), b = fin(rich().reversed.toList());
      expect(b.map((f) => f.id).toList(), a.map((f) => f.id).toList());
      expect(b.map((f) => f.strengthPermille).toList(), a.map((f) => f.strengthPermille).toList());
      expect(b.map((f) => f.ratioPermille).toList(), a.map((f) => f.ratioPermille).toList());
    });
  });

  test('no rows: no findings', () => expect(fin([]), isEmpty));
}
