// ENG core 2: spec tests for the Explore query (docs/context/ENG_UI_SPEC.md §5.3 acceptance, §6.3), from the spec only.
// SYNTHETIC rows: made-up amounts, well-known chains. Dates are fixed; no real clock.
// Guessed names (spec lists only "addView, patch, deleteView, undeleteView, views()"): `patchView`, `View.name/pinned/id`,
// `QueryRow.bucket` as a DateRange, `HeatCell.month` 1..12.
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';

DateRange dr(String a, String b) => DateRange(start: a, end: b);
const today = '2026-11-02';
DayIndex ix(List<CategorizedTx> rows) => DayIndex(rows, currency: 'EUR');

CategorizedTx withTags(CategorizedTx t, List<String> tags) => CategorizedTx(t.tx, t.category, t.kind, tags: tags);
CategorizedTx iouRow(CategorizedTx t) => CategorizedTx(t.tx, t.category, BudgetKind.transfer, iou: true);

CategorizedTx onAccount(String date, int cents, String category, String account, {String desc = ''}) {
  final t = Tx(id: 'acc-$date-$cents-$account', source: 'pbz', date: date, amount: cents, description: desc, account: account);
  return CategorizedTx(t, category, kindOf(category));
}

String payeeKey(String desc) => merchantKey(Tx(id: 'k', source: 'pbz', date: '2026-01-01', amount: -1, description: desc));

const chains = ['POS LIDL HRVATSKA ZAGREB', 'POS KONZUM 0000 ZAGREB', 'POS SPAR 0000 ZAGREB'];
const cats = ['Groceries', 'Eating out', 'Shopping'];
const tagIds = ['trip', 'gift'];

/// ~230 days of mixed rows: spending with payees and tags, refunds, transfers, IOU, foreign, deleted, zero.
List<CategorizedTx> wallet() {
  final rnd = Random(5);
  final out = <CategorizedTx>[];
  for (var d = 0; d < 230; d++) {
    final day = addDays('2026-03-01', d);
    for (var k = rnd.nextInt(4); k > 0; k--) {
      final c = cats[rnd.nextInt(3)], desc = chains[rnd.nextInt(3)], cents = 100 + rnd.nextInt(9000);
      CategorizedTx r(int amt, {String cur = 'EUR', bool del = false}) =>
          row(day, amt, c, desc: desc, currency: cur, deleted: del);
      switch (rnd.nextInt(12)) {
        case 0:
          out.add(r(cents)); // refund
        case 1:
          out.add(r(-cents, cur: 'USD'));
        case 2:
          out.add(r(-cents, del: true));
        case 3:
          out.add(iouRow(r(-cents)));
        case 4:
          out.add(row(day, -cents, 'Internal transfer', desc: desc));
        default:
          final t = r(-cents);
          out.add(rnd.nextBool() ? withTags(t, [tagIds[rnd.nextInt(2)]]) : t);
      }
    }
  }
  return out;
}

SeriesQuery q(Measure m, List<SeriesKey> keys, Bucket b, DateRange w) => SeriesQuery(measure: m, keys: keys, bucket: b, window: w);

void main() {
  group('spent equals spendingSeries to the cent', () {
    final rows = wallet(), index = ix(rows);
    final w = dr('2026-03-01', '2026-10-16');
    for (final b in [Bucket.week, Bucket.month, Bucket.quarter]) {
      test('every key kind, bucket ${b.name}', () {
        final keys = [
          for (final c in cats) SeriesKey(SeriesKind.mainTag, c),
          for (final g in tagIds) SeriesKey(SeriesKind.tag, g),
          for (final c in chains) SeriesKey(SeriesKind.payee, payeeKey(c)),
        ];
        final res = runQuery(index, q(Measure.spent, keys, b, w), today: today);
        final bars = spendingSeries(index, w, b, today: today);
        expect(res.length, bars.length);
        for (final k in keys) {
          final ref = spendingSeries(index, w, b,
              today: today,
              category: k.kind == SeriesKind.mainTag ? k.id : null,
              tag: k.kind == SeriesKind.tag ? k.id : null,
              merchantKey: k.kind == SeriesKind.payee ? k.id : null);
          for (var i = 0; i < ref.length; i++) {
            expect(res[i].cents[k], ref[i].spent, reason: '${k.id} bucket $i');
            expect(res[i].partial, ref[i].partial);
          }
        }
      });
    }

    test('main tags sum to the Insights total of the window', () {
      final keys = [for (final c in cats) SeriesKey(SeriesKind.mainTag, c)];
      final res = runQuery(index, q(Measure.spent, keys, Bucket.month, w), today: today);
      final total = res.fold<int>(0, (s, r) => s + r.cents.values.fold<int>(0, (a, b) => a + b));
      expect(total, index.spent(w));
    });

    test('refunds subtract; transfers, IOU, deleted, USD never count', () {
      final rs = [
        row('2026-05-04', -5000, 'Groceries', desc: chains[0]),
        row('2026-05-05', 1200, 'Groceries', desc: chains[0]), // refund
        row('2026-05-06', -9999, 'Internal transfer'),
        iouRow(row('2026-05-07', -7000, 'Groceries')),
        row('2026-05-08', -4000, 'Groceries', deleted: true),
        row('2026-05-09', -3000, 'Groceries', currency: 'USD'),
      ];
      final k = SeriesKey(SeriesKind.mainTag, 'Groceries');
      final res = runQuery(ix(rs), q(Measure.spent, [k], Bucket.month, dr('2026-05-01', '2026-05-31')), today: today);
      expect(res.single.cents[k], 3800);
    });
  });

  group('long windows', () {
    // One 1000-cent payment on 15 June every year 2015..2026.
    final rows = [for (var y = 2015; y <= 2026; y++) row('$y-06-15', -1000 - y, 'Groceries')];
    final k = SeriesKey(SeriesKind.mainTag, 'Groceries');

    test('year buckets over 12 years: calendar-aligned, last year partial', () {
      final res = runQuery(ix(rows), q(Measure.spent, [k], Bucket.year, dr('2015-01-01', '2026-11-02')), today: today);
      expect(res.length, 12);
      expect([for (final r in res) r.cents[k]], [for (var y = 2015; y <= 2026; y++) 1000 + y]);
      expect(res.first.bucket.start, '2015-01-01');
      expect(res.first.bucket.end, '2015-12-31');
      expect(res.last.bucket.start, '2026-01-01');
      expect(res.last.partial, isTrue);
      expect(res.where((r) => r.partial).length, 1);
    });

    test('a window starting mid-year clips the first year bucket', () {
      final res = runQuery(ix(rows), q(Measure.spent, [k], Bucket.year, dr('2015-07-01', '2026-11-02')), today: today);
      expect(res.length, 12);
      expect(res.first.cents[k], 0); // the 2015 payment is before the window
      expect(res.first.bucket.start, '2015-07-01');
    });

    test('quarter buckets over 7 years are allowed and boundary-aligned', () {
      final rs = [row('2026-03-31', -100, 'Groceries'), row('2026-04-01', -200, 'Groceries')];
      final res = runQuery(ix(rs), q(Measure.spent, [k], Bucket.quarter, dr('2020-01-01', '2026-06-30')), today: today);
      expect(res.length, 26);
      expect(res[res.length - 2].cents[k], 100); // Q1 2026
      expect(res.last.cents[k], 200); // Q2 2026
      expect(res.last.bucket.start, '2026-04-01');
    });

    test('month, week and day buckets over 6 years are refused', () {
      for (final b in [Bucket.day, Bucket.week, Bucket.month]) {
        expect(() => runQuery(ix(rows), q(Measure.spent, [k], b, dr('2020-01-01', '2026-06-30')), today: today),
            throwsArgumentError, reason: b.name);
        expect(() => bucketsOf(dr('2020-01-01', '2026-06-30'), b), throwsArgumentError, reason: b.name);
      }
    });

    test('bucketsOf year over 12 years', () {
      final bs = bucketsOf(dr('2015-01-01', '2026-11-02'), Bucket.year);
      expect(bs.length, 12);
      expect(bs.first.start, '2015-01-01');
      expect(bs.last.end, '2026-11-02');
    });
  });

  group('together', () {
    test('two overlapping tags: a row is counted once', () {
      final a = SeriesKey(SeriesKind.tag, 'trip'), b = SeriesKey(SeriesKind.tag, 'gift');
      final rs = [
        withTags(row('2026-05-04', -1000, 'Shopping'), ['trip', 'gift']),
        withTags(row('2026-05-05', -500, 'Shopping'), ['trip']),
        withTags(row('2026-05-06', -300, 'Shopping'), ['gift']),
        row('2026-05-07', -9000, 'Shopping'),
      ];
      final res = runQuery(ix(rs), q(Measure.spent, [a, b], Bucket.month, dr('2026-05-01', '2026-05-31')), today: today);
      expect(res.single.cents[a], 1500);
      expect(res.single.cents[b], 1300);
      expect(res.single.together, 1800);
    });
  });

  group('other measures and keys', () {
    final acc1 = SeriesKey(SeriesKind.account, 'acc-1'), acc2 = SeriesKey(SeriesKind.account, 'acc-2');
    final rs = [
      onAccount('2026-05-02', 150000, 'Salary', 'acc-1'),
      onAccount('2026-05-03', -4000, 'Groceries', 'acc-1'),
      onAccount('2026-05-04', -6000, 'Groceries', 'acc-2'),
      onAccount('2026-05-05', -1500, 'Shopping', 'acc-1'),
      onAccount('2026-06-02', -2500, 'Groceries', 'acc-2'),
    ];
    final w = dr('2026-05-01', '2026-06-30');

    test('account key: spent per account', () {
      final res = runQuery(ix(rs), q(Measure.spent, [acc1, acc2], Bucket.month, w), today: today);
      expect([for (final r in res) r.cents[acc1]], [5500, 0]);
      expect([for (final r in res) r.cents[acc2]], [6000, 2500]);
    });

    test('cameIn counts income only; kept = cameIn - spent', () {
      final cameIn = runQuery(ix(rs), q(Measure.cameIn, [acc1], Bucket.month, w), today: today);
      expect([for (final r in cameIn) r.cents[acc1]], [150000, 0]);
      final kept = runQuery(ix(rs), q(Measure.kept, [acc1], Bucket.month, w), today: today);
      expect([for (final r in kept) r.cents[acc1]], [150000 - 5500, 0]);
    });

    test('count is the number of spending payments, transfers and deleted excluded', () {
      final k = SeriesKey(SeriesKind.mainTag, 'Groceries');
      final more = [
        ...rs,
        row('2026-05-10', -100, 'Groceries'),
        row('2026-05-11', -100, 'Groceries', deleted: true),
        row('2026-05-12', -100, 'Internal transfer'),
      ];
      final res = runQuery(ix(more), q(Measure.count, [k], Bucket.month, w), today: today);
      expect([for (final r in res) r.cents[k]], [3, 1]);
    });
  });

  group('query JSON', () {
    final query = q(Measure.kept, [SeriesKey(SeriesKind.tag, 'trip'), SeriesKey(SeriesKind.payee, 'lidl')], Bucket.quarter,
        dr('2020-01-01', '2026-06-30'));

    test('round trip', () {
      final back = SeriesQuery.fromJson(jsonDecode(jsonEncode(query.toJson())) as Map<String, dynamic>);
      expect(back.measure, query.measure);
      expect(back.bucket, query.bucket);
      expect(back.window.start, '2020-01-01');
      expect(back.window.end, '2026-06-30');
      expect(back.keys.map((k) => (k.kind, k.id)), query.keys.map((k) => (k.kind, k.id)));
      expect(jsonEncode(back.toJson()), jsonEncode(query.toJson()));
    });

    test('bad JSON is refused', () {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'measure': 'nope', 'keys': [], 'bucket': 'month', 'window': {}},
        {...(query.toJson() as Map<String, dynamic>), 'bucket': 'decade'},
      ]) {
        expect(() => SeriesQuery.fromJson(bad), throwsA(anything), reason: '$bad');
      }
    });
  });

  group('saved views (synced entity view)', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    final json = jsonEncode(q(Measure.spent, [SeriesKey(SeriesKind.mainTag, 'Groceries')], Bucket.month, dr('2026-01-01', '2026-06-30')).toJson());

    test('add, patch, delete, undelete', () {
      final id = r.addView(name: 'Food', query: json);
      expect(r.views().map((v) => v.name), ['Food']);
      r.patchView(id, name: 'Food 2', pinned: true);
      expect(r.views().single.name, 'Food 2');
      expect(r.views().single.pinned, isTrue);
      r.deleteView(id);
      expect(r.views(), isEmpty);
      r.undeleteView(id);
      expect(r.views().single.name, 'Food 2');
    });

    test('a bad query is refused', () {
      expect(() => r.addView(name: 'Bad', query: '{not json'), throwsA(anything));
      expect(() => r.addView(name: 'Bad', query: '{"measure":"x"}'), throwsA(anything));
      expect(r.views(), isEmpty);
    });
  });

  group('heatmap', () {
    final k = SeriesKey(SeriesKind.mainTag, 'Groceries');
    HeatCell cell(List<HeatCell> cs, int y, int m) => cs.firstWhere((c) => c.year == y && c.month == m);

    test('all zero: every cell level 0', () {
      final cs = heatmap(ix([row('2025-03-03', -1000, 'Shopping')]), k, today: today);
      expect(cs.every((c) => c.level == 0 && c.cents == 0), isTrue);
    });

    test('a single nonzero month is the only level above 0', () {
      final cs = heatmap(ix([row('2025-03-03', -1000, 'Groceries'), row('2025-06-03', -5, 'Shopping')]), k, today: today);
      expect(cell(cs, 2025, 3).cents, 1000);
      expect(cell(cs, 2025, 3).level, greaterThan(0));
      expect(cs.where((c) => c.level > 0).length, 1);
    });

    test('quantile edges: levels in 0..4, monotone in cents, top is 4, smallest nonzero is 1', () {
      final rs = [for (var m = 1; m <= 12; m++) row('2025-${m.toString().padLeft(2, '0')}-10', -m * 1000, 'Groceries')];
      final cs = heatmap(ix(rs), k, today: today).where((c) => c.year == 2025).toList()
        ..sort((a, b) => a.cents.compareTo(b.cents));
      expect(cs.every((c) => c.level >= 0 && c.level <= 4), isTrue);
      for (var i = 1; i < cs.length; i++) {
        expect(cs[i].level, greaterThanOrEqualTo(cs[i - 1].level));
      }
      expect(cs.last.level, 4);
      expect(cs.firstWhere((c) => c.cents > 0).level, 1);
      expect({for (final c in cs) c.level}.length, greaterThanOrEqualTo(4));
    });

    test('cents match month spending', () {
      final rs = [row('2025-02-28', -700, 'Groceries'), row('2025-02-01', -300, 'Groceries'), row('2025-03-01', -50, 'Groceries')];
      final cs = heatmap(ix(rs), k, today: today);
      expect(cell(cs, 2025, 2).cents, 1000);
      expect(cell(cs, 2025, 3).cents, 50);
    });
  });

  test('determinism: same rows in any order, repeated runs, equal results', () {
    final rows = wallet();
    final keys = [SeriesKey(SeriesKind.mainTag, 'Groceries'), SeriesKey(SeriesKind.tag, 'trip')];
    final w = dr('2026-03-01', '2026-10-16');
    String run(List<CategorizedTx> rs) => runQuery(ix(rs), q(Measure.spent, keys, Bucket.month, w), today: today)
        .map((r) => '${r.bucket.start}|${r.partial}|${keys.map((k) => r.cents[k]).join(',')}|${r.together}')
        .join(';');
    final a = run(rows);
    expect(run(rows), a);
    expect(run(rows.reversed.toList()), a);
    expect(run((List.of(rows)..shuffle(Random(3)))), a);
  });
}
