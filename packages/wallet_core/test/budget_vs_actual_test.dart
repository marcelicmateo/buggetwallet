// Budget vs actual per category (calendar months) and the categoryBudgets setting. All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

/// Log lines written while [body] runs.
List<String> _logs(void Function() body) {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
  try {
    body();
  } finally {
    sub.cancel();
    Logger.root.level = was;
  }
  return lines;
}

CategoryBudgetLine _line(BudgetVsActual b, String category) => b.lines.singleWhere((l) => l.category == category);

void main() {
  const month = '2026-03';
  const mid = '2026-03-12'; // day 12 of 31
  final march = [
    ct('2026-03-02', -4000, 'Groceries'),
    ct('2026-03-10', -6000, 'Groceries'),
    ct('2026-03-05', -2500, 'Eating out'),
    ct('2026-03-01', -55000, 'Rent'),
    ct('2026-03-15', 150000, 'Salary'),
    ct('2026-03-16', -20000, 'Internal transfer'),
  ];

  group('budgetVsActual', () {
    test('no budgets: one line per category with spend, nothing budgeted, no remaining or pace', () {
      final b = budgetVsActual(march, month, const {}, today: mid);
      expect(b.month, month);
      expect([for (final l in b.lines) l.category], ['Rent', 'Groceries', 'Eating out'], reason: 'actual desc');
      expect([for (final l in b.lines) l.actual], [55000, 10000, 2500]);
      for (final l in b.lines) {
        expect((l.budget, l.remaining, l.pace, l.over), (null, null, null, false), reason: l.category);
      }
      expect((b.budgetTotal, b.actualTotal, b.remainingTotal, b.overCount, b.budgetedCount), (0, 67500, null, 0, 0));
      expect((b.elapsedDays, b.daysInMonth), (12, 31));
    });

    test('income and transfers never appear, deleted and replaced rows do not count', () {
      final txs = [
        ...march,
        ct('2026-03-03', -9000, 'Groceries', deleted: true),
        ct('2026-03-04', -7000, 'Shopping', matchedTo: 'bank-row-here', manual: true),
      ];
      final b = budgetVsActual(txs, month, const {'Salary': 1, 'Internal transfer': 1}, today: mid);
      expect(_line(b, 'Groceries').actual, 10000);
      expect(b.lines.where((l) => l.category == 'Shopping'), isEmpty);
      // A budget on a non-spending category still makes a line (the setting drops such keys before it gets here).
      expect((_line(b, 'Salary').actual, _line(b, 'Internal transfer').actual), (0, 0));
    });

    test('zero budget: budgeted, remaining = -actual, pace null, over when anything was spent', () {
      final b = budgetVsActual(march, month, const {'Groceries': 0, 'Shopping': 0}, today: mid);
      final g = _line(b, 'Groceries'), s = _line(b, 'Shopping');
      expect((g.budget, g.remaining, g.pace, g.over), (0, -10000, null, true));
      expect((s.budget, s.actual, s.remaining, s.pace, s.over), (0, 0, 0, null, false));
      expect((b.budgetTotal, b.remainingTotal, b.overCount, b.budgetedCount), (0, -10000, 1, 2));
    });

    test('budget without spend: a line with actual 0, all of it remaining, pace 0', () {
      final b = budgetVsActual(march, month, const {'Shopping': 12000}, today: mid);
      final s = _line(b, 'Shopping');
      expect((s.actual, s.remaining, s.pace, s.over), (0, 12000, 0.0, false));
      expect(b.lines.last.category, 'Shopping', reason: 'actual 0 sorts after every category with spend');
      expect((b.budgetTotal, b.actualTotal, b.remainingTotal, b.budgetedCount), (12000, 67500, 12000, 1));
    });

    test('spend without budget counts in actualTotal but not in budgetTotal or remainingTotal', () {
      final b = budgetVsActual(march, month, const {'Groceries': 15000}, today: mid);
      expect((b.budgetTotal, b.actualTotal, b.remainingTotal), (15000, 67500, 5000));
      expect(_line(b, 'Rent').remaining, isNull);
    });

    test('a refund larger than the spend makes actual negative: remaining above the budget, pace below 0', () {
      final txs = [ct('2026-03-03', -3000, 'Shopping'), ct('2026-03-20', 8000, 'Shopping')];
      final b = budgetVsActual(txs, month, const {'Shopping': 10000}, today: '2026-03-31');
      final s = _line(b, 'Shopping');
      expect((s.actual, s.remaining, s.over), (-5000, 15000, false));
      expect(s.pace, closeTo(-0.5, 1e-9));
      expect((b.actualTotal, b.remainingTotal), (-5000, 15000));
    });

    test('over: actual above the budget, counted; exactly on the budget is not over', () {
      final b = budgetVsActual(march, month, const {'Groceries': 9999, 'Rent': 55000, 'Eating out': 2501}, today: mid);
      expect([for (final l in b.lines) l.over], [false, true, false]);
      expect((b.overCount, b.budgetedCount, b.remainingTotal), (1, 3, -1 + 0 + 1));
    });

    test('month boundary: the 1st and the last day belong to the month, the days around do not', () {
      final txs = [
        ct('2026-02-28', -100, 'Groceries'),
        ct('2026-03-01', -200, 'Groceries'),
        ct('2026-03-31', -400, 'Groceries'),
        ct('2026-04-01', -800, 'Groceries'),
      ];
      expect(_line(budgetVsActual(txs, '2026-03', const {}, today: '2026-05-01'), 'Groceries').actual, 600);
      expect(_line(budgetVsActual(txs, '2026-02', const {}, today: '2026-05-01'), 'Groceries').actual, 100);
      expect(_line(budgetVsActual(txs, '2026-04', const {}, today: '2026-05-01'), 'Groceries').actual, 800);
    });

    test('pace in the current month uses the day of month: 10000 of 31000 on day 12 is 10000 / 12000', () {
      final b = budgetVsActual(march, month, const {'Groceries': 31000}, today: mid);
      expect(_line(b, 'Groceries').pace, closeTo(10000 / 12000, 1e-9));
    });

    test('pace in a past month uses the whole month: actual / budget', () {
      final b = budgetVsActual(march, month, const {'Groceries': 8000}, today: '2026-04-03');
      expect((b.elapsedDays, b.daysInMonth), (31, 31));
      expect(_line(b, 'Groceries').pace, closeTo(1.25, 1e-9));
      expect(_line(b, 'Groceries').over, isTrue);
    });

    test('on the 1st of the month one day has elapsed: pace = actual * days / budget', () {
      final txs = [ct('2026-02-01', -1000, 'Groceries')];
      final b = budgetVsActual(txs, '2026-02', const {'Groceries': 28000}, today: '2026-02-01');
      expect((b.elapsedDays, b.daysInMonth), (1, 28));
      expect(_line(b, 'Groceries').pace, closeTo(1.0, 1e-9));
    });

    test('a future month has no elapsed days: pace null, the rest as usual', () {
      final b = budgetVsActual(march, '2026-04', const {'Groceries': 10000}, today: mid);
      expect(b.elapsedDays, 0);
      expect((_line(b, 'Groceries').pace, _line(b, 'Groceries').remaining), (null, 10000));
    });

    test('month lengths: 29 days in a leap February, 30 in April', () {
      expect(budgetVsActual(const [], '2028-02', const {}, today: '2028-02-10').daysInMonth, 29);
      expect(budgetVsActual(const [], '2026-04', const {}, today: '2026-04-10').daysInMonth, 30);
      expect(budgetVsActual(const [], '2026-02', const {}, today: '2026-02-10').daysInMonth, 28);
    });

    test('ordering: actual descending, then by name', () {
      final txs = [ct('2026-03-01', -500, 'Shopping'), ct('2026-03-01', -500, 'Cash'), ct('2026-03-01', -700, 'Groceries')];
      final b = budgetVsActual(txs, month, const {'Bank fees': 100, 'Eating out': 100}, today: mid);
      expect([for (final l in b.lines) l.category], ['Groceries', 'Cash', 'Shopping', 'Bank fees', 'Eating out']);
    });

    test('average6 is the mean of the 6 months before, this month and older months left out, divided by 6', () {
      final txs = [
        ct('2025-08-10', -99999, 'Groceries'), // 7 months back: out
        ct('2025-09-10', -12000, 'Groceries'), // 6 months back: in
        ct('2026-02-10', -6000, 'Groceries'),
        ct('2026-02-20', 1000, 'Groceries'), // refund reduces
        ct('2026-03-10', -50000, 'Groceries'), // this month: out
        ct('2026-01-05', -3, 'Cash'),
      ];
      final b = budgetVsActual(txs, month, const {'Cash': 100}, today: mid);
      expect(_line(b, 'Groceries').average6, ((12000 + 6000 - 1000) / 6).round());
      expect(_line(b, 'Cash').average6, 1, reason: '3 / 6 = 0.5 rounds to 1; a line only because of its budget');
      expect(b.lines.map((l) => l.category), isNot(contains('Internal transfer')));
      expect(averageByCategory(txs, month), {'Groceries': 2833, 'Cash': 1});
    });

    test('nothing at all: no lines, totals zero, remaining null', () {
      final b = budgetVsActual(const [], month, const {}, today: mid);
      expect(b.lines, isEmpty);
      expect((b.budgetTotal, b.actualTotal, b.remainingTotal, b.overCount, b.budgetedCount), (0, 0, null, 0, 0));
    });

    test('logs the month and counts only', () {
      final lines = _logs(() => budgetVsActual(march, month, const {'Groceries': 100}, today: mid));
      final l = lines.where((l) => l.contains('budget.vsActual')).single;
      expect(l, endsWith('{"month":"2026-03","lines":3,"budgeted":1,"over":1,"elapsed":12}'));
    });
  });

  group('suggestBudgets', () {
    test('an exact multiple of 10 € stays, anything above rounds up to the next 10 €', () {
      final txs = [
        for (var m = 9; m <= 14; m++)
          ct('${m <= 12 ? 2025 : 2026}-${(m > 12 ? m - 12 : m).toString().padLeft(2, '0')}-05', -10000, 'Groceries'),
        ct('2026-01-07', -6, 'Groceries'), // average 10001 -> 11000
        for (var m = 9; m <= 14; m++) ct('${m <= 12 ? 2025 : 2026}-${(m > 12 ? m - 12 : m).toString().padLeft(2, '0')}-05', -3000, 'Cash'),
        ct('2026-01-01', -1, 'Bank fees'), // average 1/6 cent -> 1000
      ];
      expect(suggestBudgets(txs, month), {'Groceries': 11000, 'Cash': 3000, 'Bank fees': 1000});
    });

    test('zero or negative averages are omitted; the month itself and months older than 6 do not count', () {
      final txs = [
        ct('2026-01-05', -5000, 'Shopping'),
        ct('2026-02-05', 5000, 'Shopping'), // nets to zero
        ct('2025-12-05', -2000, 'Eating out'),
        ct('2026-01-05', 3000, 'Eating out'), // negative
        ct('2026-03-05', -40000, 'Groceries'), // this month
        ct('2025-08-05', -40000, 'Cash'), // 7 months back
        ct('2026-01-05', -100, 'Internal transfer'),
      ];
      expect(suggestBudgets(txs, month), isEmpty);
    });

    test('empty input', () => expect(suggestBudgets(const [], month), isEmpty));
  });

  group('categoryBudgets setting', () {
    setUp(resetInvalidSettingLog);

    test('default is empty and round-trips through toMap', () {
      const s = WalletSettings();
      expect(s.categoryBudgets, isEmpty);
      final m = WalletSettings.fromMap(const {
        'categoryBudgets': {'Groceries': 30000, 'Rent': 55000}
      });
      expect(m.categoryBudgets, {'Groceries': 30000, 'Rent': 55000});
      expect(WalletSettings.fromMap(m.toMap()).categoryBudgets, m.categoryBudgets);
    });

    test('invalid entries are dropped one by one, valid ones kept, logged once with the key only', () {
      late WalletSettings s;
      final lines = _logs(() => s = WalletSettings.fromMap(const {
            'salary': 150000,
            'categoryBudgets': {
              'Groceries': 30000,
              'Unknown thing': 1000, // unknown category
              'Salary': 1000, // not a spending category
              'Internal transfer': 1000,
              'Cash': -1, // negative
              'Shopping': 12.5, // fraction
              'Eating out': '100', // text
              'Home & tools': 1000000000001, // above the limit
              'Bank fees': 1000000000000, // at the limit: kept
              'Car & transport': 2000.0, // whole double: kept
              'Health & care': 0, // zero: kept
            },
          }));
      expect(s.categoryBudgets, {'Groceries': 30000, 'Bank fees': 1000000000000, 'Car & transport': 2000, 'Health & care': 0});
      expect(s.salary, 150000, reason: 'other settings untouched');
      final warn = lines.where((l) => l.contains('settings.invalid')).toList();
      expect(warn, [endsWith(' WARNING bw.settings settings.invalid {"key":"categoryBudgets"}')]);
    });

    test('a value that is not a map falls back to no budgets', () {
      for (final v in [
        'Groceries=1',
        42,
        const ['Groceries', 1],
        true
      ]) {
        resetInvalidSettingLog();
        late WalletSettings s;
        final lines = _logs(() => s = WalletSettings.fromMap({'categoryBudgets': v}));
        expect(s.categoryBudgets, isEmpty, reason: '$v');
        expect(lines.where((l) => l.contains('settings.invalid {"key":"categoryBudgets"}')), hasLength(1));
      }
    });

    test('valid budgets are not logged', () {
      final lines = _logs(() => WalletSettings.fromMap(const {
            'categoryBudgets': {'Groceries': 1}
          }));
      expect(lines.where((l) => l.contains('settings.invalid')), isEmpty);
    });

    test('every spending category is accepted, nothing else', () {
      final all = {for (final c in categories.keys) c: 100};
      final s = WalletSettings.fromMap({'categoryBudgets': all});
      expect(s.categoryBudgets.keys.toSet(), spendingCategories.toSet());
      expect(spendingCategories, isNot(contains('Salary')));
      expect(spendingCategories, contains('Rent'));
      expect(spendingCategories, contains('Groceries'));
    });

    test('updateSettings round-trip; a later write replaces the whole map', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.updateSettings({
        'categoryBudgets': {'Groceries': 30000, 'Eating out': 8000}
      });
      expect(r.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 8000});
      r.updateSettings({
        'categoryBudgets': {'Groceries': 25000}
      });
      expect(r.settings().categoryBudgets, {'Groceries': 25000});
      r.updateSettings({'categoryBudgets': const <String, int>{}});
      expect(r.settings().categoryBudgets, isEmpty);
    });

    test('feeds budgetVsActual straight from settings', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.updateSettings({
        'categoryBudgets': {'Groceries': 12000}
      });
      final b = budgetVsActual(march, month, r.settings().categoryBudgets, today: mid);
      expect((_line(b, 'Groceries').remaining, b.budgetedCount), (2000, 1));
    });
  });

  group('two devices', () {
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

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
        d.upload(net);
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-budgets-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('budgets set on one device arrive on the other; the later edit wins on both', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({
        'categoryBudgets': {'Groceries': 30000, 'Rent': 55000}
      });
      await round();
      await round();
      expect(b.repo.settings().categoryBudgets, {'Groceries': 30000, 'Rent': 55000});

      now += 1000;
      b.repo.updateSettings({
        'categoryBudgets': {'Groceries': 20000}
      });
      await round();
      await round();
      expect(a.repo.settings().categoryBudgets, {'Groceries': 20000});
      expect(b.repo.settings().categoryBudgets, {'Groceries': 20000});
    });

    test('a bad map from a buggy device: the other device keeps the valid entries and its other settings', () async {
      final a = device('a'), b = device('b');
      b.repo.updateSettings({'salary': 150000});
      a.repo.updateSettings({
        'categoryBudgets': {'Groceries': 30000, 'Nope': -5, 'Cash': 'x'}
      });
      await round();
      await round();
      expect(b.repo.settings().categoryBudgets, {'Groceries': 30000});
      expect(b.repo.settings().salary, 150000);
      expect(a.repo.settings().salary, 150000);
    });
  });
}
