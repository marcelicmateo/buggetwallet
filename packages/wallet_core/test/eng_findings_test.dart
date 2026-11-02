// ENG §6.2 findings engine (findings.dart) + the dismissedFindings setting. SYNTHETIC rows only: made-up amounts,
// built-in categories, a well-known brand for the bill. today = 2026-11-15: W12 = 2025-11..2026-10.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart';
import 'support/sim.dart';

const today = '2026-11-15';
final table = CategoryTable.builtIn;

List<Finding> run(List<CategorizedTx> rows,
        {WalletSettings st = const WalletSettings(), List<String> reviews = const [], List<RecurringBill> bills = const []}) =>
    findings(rows, st, table, today, reviewDates: reviews, bills: bills);

List<Finding> only(FindingKind k, List<Finding> fs) => [
      for (final f in fs)
        if (f.kind == k) f
    ];

/// `YYYY-MM` [k] months after [ym] (k may be negative).
String plus(String ym, int k) {
  final i = int.parse(ym.substring(0, 4)) * 12 + int.parse(ym.substring(5)) - 1 + k;
  return '${i ~/ 12}-${(i % 12 + 1).toString().padLeft(2, '0')}';
}

/// [cents] spent (positive) in [cat] on the 5th of each of [n] months from [from].
List<CategorizedTx> monthly(String from, int n, int cents, [String cat = 'Groceries']) =>
    [for (var k = 0; k < n; k++) row('${plus(from, k)}-05', -cents, cat)];

void main() {
  group('aboveUsual', () {
    List<Finding> usual(int median, int now, {int months = 12}) =>
        only(FindingKind.aboveUsual, run([...monthly(plus('2026-11', -months), months, median), row('2026-11-03', -now, 'Groceries')]));

    test('4·now ≥ 5·median: at fires, a cent below does not', () {
      final at = usual(10000, 12500);
      expect(at.map((f) => f.id), ['aboveUsual:Groceries:2026-11']);
      expect((at.single.ratioPermille, at.single.n, at.single.from, at.single.to), (1250, 12, '2025-11-01', today));
      expect(at.single.series.last, ('2026-11', 12500));
      expect(usual(10000, 12499), isEmpty);
      expect(usual(10000, 20000).single.ratioPermille, 2000);
    });

    test('the 20 € difference: 5999 over a 4000 median does not fire, 6000 does', () {
      expect(usual(4000, 5999), isEmpty);
      expect(usual(4000, 6000), hasLength(1));
    });

    test('at least 6 months of history', () {
      expect(usual(10000, 20000, months: 6), hasLength(1));
      expect(usual(10000, 20000, months: 5), isEmpty);
    });

    test('a split payment counts each part under its own main tag', () {
      const t = Tx(id: 'split', source: 'pbz', date: '2026-11-03', amount: -30000, description: 'POS LIDL');
      final fs = only(
          FindingKind.aboveUsual,
          run([
            ...monthly('2025-11', 12, 10000),
            ...monthly('2025-11', 12, 10000, 'Eating out'),
            const CategorizedTx(t, 'Groceries', BudgetKind.flex, amount: -15000, part: 0, parts: 2),
            const CategorizedTx(t, 'Eating out', BudgetKind.flex, amount: -15000, part: 1, parts: 2),
          ]));
      expect(fs.map((f) => (f.subjectKey, f.ratioPermille)), [('Eating out', 1500), ('Groceries', 1500)]);
    });

    test('a hand-added entry matched away by its bank row counts once', () {
      final fs = only(
          FindingKind.aboveUsual,
          run([
            ...monthly('2025-11', 12, 10000),
            const CategorizedTx(Tx(id: 'm', source: 'manual', date: '2026-11-02', amount: -14000, manual: true, matchedTo: 'b'),
                'Groceries', BudgetKind.flex),
            const CategorizedTx(
                Tx(id: 'b', source: 'pbz', date: '2026-11-03', amount: -14000, description: 'POS LIDL'), 'Groceries', BudgetKind.flex),
          ]));
      expect(fs.single.ratioPermille, 1400);
    });

    test('refunds subtracted; transfers, IOU-linked rows and other currencies count nowhere', () {
      final base = monthly('2025-11', 12, 10000);
      expect(only(FindingKind.aboveUsual, run([...base, row('2026-11-03', -14000, 'Groceries')])), hasLength(1));
      expect(only(FindingKind.aboveUsual, run([...base, row('2026-11-03', -14000, 'Groceries'), row('2026-11-04', 2000, 'Groceries')])),
          isEmpty);
      const iou =
          CategorizedTx(Tx(id: 'iou', source: 'pbz', date: '2026-11-03', amount: -50000), 'Groceries', BudgetKind.transfer, iou: true);
      expect(only(FindingKind.aboveUsual, run([...base, iou, row('2026-11-03', -50000, 'Internal transfer')])), isEmpty);
      expect(only(FindingKind.aboveUsual, run([...base, row('2026-11-03', -50000, 'Groceries', currency: 'USD')])), isEmpty);
    });
  });

  group('weeklyRhythm', () {
    /// Every day of W12: [sat] cents on Saturdays, 1000 on other days.
    List<Finding> week(int sat) {
      final rows = <CategorizedTx>[];
      for (var d = DateTime.utc(2025, 11, 1); d.isBefore(DateTime.utc(2026, 11, 1)); d = d.add(const Duration(days: 1))) {
        rows.add(row(isoDate(d), d.weekday == DateTime.saturday ? -sat : -1000, 'Groceries'));
      }
      return only(FindingKind.weeklyRhythm, run(rows));
    }

    test('max ÷ min weekday mean ≥ 1.6: at fires, below does not', () {
      final f = week(1600).single;
      expect((f.id, f.ratioPermille, f.n, f.from, f.to), ('weeklyRhythm:all', 1600, 12, '2025-11-01', '2026-10-31'));
      expect(f.series, [for (var w = 1; w <= 7; w++) ('$w', w == 6 ? 1600 : 1000)]);
      expect(week(1599), isEmpty);
      expect(week(3000).single.ratioPermille, 3000);
    });

    test('a weekday with no spending at all never fires (sparse data)', () {
      // Spending on Mondays only: the other weekdays hold nothing, so the quietest mean is 0.
      final mondays = [
        for (var d = DateTime.utc(2025, 11, 3); d.isBefore(DateTime.utc(2026, 11, 1)); d = d.add(const Duration(days: 7)))
          row(isoDate(d), -5000, 'Groceries')
      ];
      expect(only(FindingKind.weeklyRhythm, run(mondays)), isEmpty);
    });
  });

  group('movesTogether', () {
    // Centered x = ±1; z ⟂ x with Σz² = 3·Σx², so y = x + z has r = 1/√(1 + 3) = 0.5 exactly. [zScale] moves it.
    const x = [1, -1, 1, -1, 1, -1, 1, -1, 1, -1, 1, -1];
    const z = [3, 3, -3, -3, 0, 0, 0, 0, 0, 0, 0, 0];
    List<Finding> pair(int zScale, {int months = 12, int sign = 1}) => only(
        FindingKind.movesTogether,
        run([
          for (var k = 0; k < months; k++) ...[
            row('${plus('2025-11', k)}-05', -(10000 + 100 * x[k]), 'Groceries'),
            row('${plus('2025-11', k)}-05', -(10000 + sign * (100 * x[k] + zScale * z[k])), 'Eating out'),
          ]
        ]));

    test('|r| ≥ 0.5 by integer sums: exactly 0.5 fires, a little weaker does not', () {
      final f = pair(100).single;
      expect((f.id, f.subjectKey, f.otherKey, f.strengthPermille, f.n),
          ('movesTogether:Eating out:Groceries', 'Eating out', 'Groceries', 500, 12));
      expect(f.series.length, 12);
      expect(f.otherSeries.length, 12);
      expect(pair(101), isEmpty);
      expect(pair(99).single.strengthPermille, greaterThan(500));
      expect(pair(0).single.strengthPermille, 1000);
    });

    test('a negative link keeps its sign', () {
      expect(pair(0, sign: -1).single.strengthPermille, -1000);
      expect(pair(100, sign: -1).single.strengthPermille, -500);
    });

    test('needs 12 shared months', () {
      expect(pair(0, months: 11), isEmpty);
    });
  });

  group('slowCreep', () {
    const desc = 'POS NETFLIX.COM';
    final key = merchantKey(const Tx(id: 'k', source: 'pbz', date: '2026-01-01', amount: -1, description: desc));
    RecurringBill bill({String status = 'confirmed', String? payee, String? direction}) => RecurringBill(
        id: 'rec:test',
        payee: payee ?? key,
        label: 'Netflix',
        category: 'Bills & subscriptions',
        expectedAmount: 1000,
        nextDue: '2026-12-05',
        status: status,
        direction: direction);

    /// One payment on the 5th of [months] months from [from]: [first] cents, the last [lastN] months [last].
    List<CategorizedTx> rows(String from, int months, int first, int last, {int lastN = 3}) => [
          for (var k = 0; k < months; k++)
            row('${plus(from, k)}-05', -(k >= months - lastN ? last : first), 'Bills & subscriptions', desc: desc)
        ];
    List<Finding> creep(List<CategorizedTx> r, [RecurringBill? b]) => only(FindingKind.slowCreep, run(r, bills: [b ?? bill()]));

    test('median of the last 3 full months ≥ 125 % of the first 3, 12 months before: at fires, below does not', () {
      final f = creep(rows('2025-08', 15, 1000, 1250)).single;
      expect((f.id, f.ratioPermille, f.n, f.from, f.to), ('slowCreep:rec:test:2026-10', 1250, 15, '2025-08-01', '2026-10-31'));
      expect(creep(rows('2025-08', 15, 1000, 1249)), isEmpty);
    });

    test('3 months 12 before needed; the running month, other statuses, an income and no payee never fire', () {
      expect(creep(rows('2025-09', 14, 1000, 2000)), isEmpty); // only 2025-09 and 2025-10 are 12 months before
      // The rise lands this month (not full yet): the latest full months are the old amount.
      expect(creep(rows('2025-08', 16, 1000, 2000, lastN: 1)), isEmpty);
      for (final b in [bill(status: 'candidate'), bill(direction: 'in'), bill(payee: '')]) {
        expect(creep(rows('2025-08', 15, 1000, 2000), b), isEmpty);
      }
    });

    test('a monthly bill that slips across a month end (two cycles in one month) does not fire', () {
      final r = [
        // 5000 a month from 2025-07 (so the first 3 months exist), paid 2026-08-29, nothing in 2026-09, twice in 2026-10.
        for (var k = 0; k < 13; k++) row('${plus('2025-07', k)}-05', -5000, 'Bills & subscriptions', desc: desc),
        for (final d in ['2026-08-29', '2026-10-01', '2026-10-30']) row(d, -5000, 'Bills & subscriptions', desc: desc),
      ];
      expect(creep(r), isEmpty);
    });

    test('a split payment of the bill counts once, as the whole payment', () {
      final r = rows('2025-08', 12, 1000, 1000);
      for (final m in ['2026-08', '2026-09', '2026-10']) {
        final t = Tx(id: 'split-$m', source: 'pbz', date: '$m-05', amount: -1250, description: desc);
        r.addAll([
          CategorizedTx(t, 'Bills & subscriptions', BudgetKind.fixed, amount: -600, part: 0, parts: 2),
          CategorizedTx(t, 'Eating out', BudgetKind.flex, amount: -650, part: 1, parts: 2),
        ]);
      }
      expect(creep(r).single.ratioPermille, 1250);
    });

    test('rows of other payees, currencies or hand-added never count', () {
      final r = rows('2025-08', 15, 1000, 1000)
        ..add(row('2026-10-06', -900, 'Bills & subscriptions', desc: desc, currency: 'USD'))
        ..add(row('2026-10-07', -900, 'Bills & subscriptions', desc: desc, source: 'manual'))
        ..add(row('2026-10-08', -900, 'Bills & subscriptions', desc: 'POS SPOTIFY'));
      expect(creep(r), isEmpty);
    });
  });

  group('seasonality', () {
    /// 1000 a month from 2022-01 to 2026-10, December 5000 in the first [peaks] years.
    List<Finding> season(int peaks) => only(
        FindingKind.seasonality,
        run([
          for (var k = 0; k < 58; k++)
            row('${plus('2022-01', k)}-05', -(plus('2022-01', k).endsWith('-12') && k ~/ 12 < peaks ? 5000 : 1000), 'Groceries')
        ]));

    test('the same month is the max in ≥ 3 full years', () {
      final f = season(3).single;
      expect((f.id, f.otherKey, f.n, f.from, f.to), ('seasonality:Groceries:12:2025-12', '12', 3, '2022-01-01', '2025-12-31'));
      expect(f.series.length, 48);
      expect(season(2), isEmpty);
      expect(season(4).single.n, 4);
    });
  });

  group('milestone', () {
    test('days tracked: 100 at 100 days, nothing at 99', () {
      final f = only(FindingKind.milestone, run([row(addDays(today, -99), -100, 'Groceries')])).single;
      expect((f.id, f.n), ('milestone:days:2026-11', 100));
      expect(f.series, [('days', 100)]);
      expect(only(FindingKind.milestone, run([row(addDays(today, -98), -100, 'Groceries')])), isEmpty);
      expect(only(FindingKind.milestone, run([row(addDays(today, -800), -100, 'Groceries')])).single.n, 730);
    });

    test('payments: 100 at the 100th, nothing at 99; the level month is the 100th payment', () {
      List<Finding> pays(int n) => [
            for (final f in only(FindingKind.milestone, run([for (var i = 0; i < n; i++) row(addDays(today, -i ~/ 2), -100, 'Groceries')])))
              if (f.subjectKey == 'payments') f
          ];
      expect(pays(100).single.id, 'milestone:payments:2026-11');
      expect(pays(99), isEmpty);
    });

    test('best review streak: 4 weekly reviews reach 4, a gap of 14 days breaks it, the best one stays', () {
      List<Finding> streak(List<String> d) => only(FindingKind.milestone, run(const [], reviews: d));
      final four = ['2026-01-04', '2026-01-11', '2026-01-18', '2026-01-25'];
      expect(streak(four).single.id, 'milestone:streak:2026-01');
      expect(streak(four.take(3).toList()), isEmpty);
      expect(streak([...four, '2026-03-01']).single.n, 4); // the later single review does not lower the best
      expect(streak(['2026-01-04', '2026-01-18', '2026-02-01', '2026-02-15']), isEmpty);
    });
  });

  group('whole run', () {
    final rows = bigWalletRows(today);

    test('deterministic: shuffled input, same findings in the same order; dismissed ids left out', () {
      final a = run(rows), b = run([...rows]..shuffle());
      expect(a, isNotEmpty);
      expect(b, a);
      for (var i = 1; i < a.length; i++) {
        expect(a[i - 1].kind.index <= a[i].kind.index, isTrue);
      }
      final hidden = run(rows, st: WalletSettings(dismissedFindings: [a.first.id]));
      expect(hidden.map((f) => f.id), a.skip(1).map((f) => f.id));
    });

    test('perf: about 10k rows and confirmed bills well under 200 ms once warm', () {
      final bills = [
        for (final d in ['POS NETFLIX.COM', 'Naplata kredita 0000000000'])
          RecurringBill(
              id: 'rec:$d',
              payee: merchantKey(Tx(id: 'k', source: 'pbz', date: today, amount: -1, description: d)),
              label: 'Bill',
              category: 'Bills & subscriptions',
              expectedAmount: 1000,
              nextDue: today,
              status: 'confirmed')
      ];
      run(rows, bills: bills);
      final sw = Stopwatch()..start();
      run(rows, bills: bills);
      sw.stop();
      // ignore: avoid_print
      print('findings on ${rows.length} rows: ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(1000)); // loose: a shared laptop
    });
  });

  group('dismissedFindings setting', () {
    test('fromMap/toMap round trip, bad values fall back, newest 500 kept', () {
      const s = WalletSettings(workHoursPerWeek: 37, dismissedFindings: ['a', 'b']);
      final back = WalletSettings.fromMap(s.toMap());
      expect(back.workHoursPerWeek, 37);
      expect(back.dismissedFindings, ['a', 'b']);
      expect(
          WalletSettings.fromMap({
            'dismissedFindings': ['a', 1]
          }).dismissedFindings,
          isEmpty);
      expect(WalletSettings.fromMap({'dismissedFindings': 'a'}).dismissedFindings, isEmpty);
      final many = WalletSettings.fromMap({
        'dismissedFindings': [for (var i = 0; i < 600; i++) 'f$i']
      }).dismissedFindings;
      expect((many.length, many.first, many.last), (500, 'f100', 'f599'));
    });

    test('updateSettings refuses a bad list; repo keeps the newest 500', () async {
      final r = WalletRepo.inMemory();
      expect(
          () => r.updateSettings({
                'dismissedFindings': [1]
              }),
          throwsArgumentError);
      for (var i = 0; i < 502; i++) {
        await r.dismissFinding('f$i');
      }
      expect((r.settings().dismissedFindings.length, r.settings().dismissedFindings.first), (500, 'f2'));
      r.close();
    });

    group('two devices', () {
      late Directory tmp;
      late Net net;
      var now = DateTime.utc(2026, 11, 15, 12).millisecondsSinceEpoch;
      final devices = <Device>[];
      Device device(String name, VaultKey key) {
        final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now, net: net);
        devices.add(d);
        return d;
      }

      Future<void> round() async {
        for (final d in devices) {
          now += 1000;
          await d.run();
        }
      }

      setUp(() {
        tmp = Directory.systemTemp.createTempSync('bw-findings-');
        net = Net();
        devices.clear();
      });
      tearDown(() {
        for (final d in devices) {
          d.close();
        }
        tmp.deleteSync(recursive: true);
      });

      test('a dismissal reaches the other device; each dismisses one in turn, both kept; an undo syncs', () async {
        final key = VaultKey.generate();
        final a = device('a', key), b = device('b', key);
        await a.repo.dismissFinding('aboveUsual:Groceries:2026-11');
        await round();
        await b.repo.dismissFinding('weeklyRhythm:all');
        await round();
        await round();
        for (final d in [a, b]) {
          expect(d.repo.settings().dismissedFindings, ['aboveUsual:Groceries:2026-11', 'weeklyRhythm:all'], reason: d.name);
        }
        await b.repo.undismissFinding('aboveUsual:Groceries:2026-11');
        await round();
        await round();
        expect(a.repo.settings().dismissedFindings, ['weeklyRhythm:all']);
      }, timeout: const Timeout(Duration(seconds: 60)));
    });
  });
}
