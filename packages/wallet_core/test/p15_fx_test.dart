// P15: other currencies in the budget by an owner-set rate (`fx:<CODE>`, `homeAmount`, `inHomeCurrency`). SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

var _seq = 0;

/// A row in [currency] (a card abroad), categorized for pure-function tests.
CategorizedTx fx(String date, int cents, String category, String currency, {bool deleted = false}) => CategorizedTx(
      Tx(id: 'p15-${_seq++}', source: 'revolut', date: date, amount: cents, currency: currency, deleted: deleted),
      category,
      kindOf(category),
    );

/// The exact reference: amount × rate / 10^6, half away from zero, in BigInt.
int _ref(int amount, int rate) {
  final p = BigInt.from(amount.abs()) * BigInt.from(rate);
  final m = BigInt.from(FxRate.scale);
  var q = p ~/ m;
  if ((p % m) * BigInt.two >= m) q += BigInt.one;
  return (amount < 0 ? -q : q).toInt();
}

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

WalletSettings _withRates(WalletSettings st, Map<String, int> rates) => WalletSettings.fromMap({
      ...st.toMap(),
      for (final MapEntry(:key, :value) in rates.entries) 'fx:$key': {'rate': value, 'date': '2026-03-01', 'home': st.currency},
    });

void main() {
  setUp(resetInvalidSettingLog);

  group('convertMinor: one rounding rule', () {
    test('the spec example: 100 USD at 0.9240 is 92.40', () {
      expect(convertMinor(10000, 924000), 9240);
      expect(convertMinor(-10000, 924000), -9240);
    });

    test('half away from zero on both signs', () {
      expect(convertMinor(1, 500000), 1);
      expect(convertMinor(-1, 500000), -1);
      expect(convertMinor(3, 500000), 2);
      expect(convertMinor(-3, 500000), -2);
      expect(convertMinor(1, 499999), 0);
      expect(convertMinor(-1, 499999), 0);
      expect(convertMinor(1, 1500000), 2); // 1.5
      expect(convertMinor(-5, 1100000), -6); // -5.5
      expect(convertMinor(0, 924000), 0);
    });

    test('one minor unit at the smallest and largest rate', () {
      expect(convertMinor(1, FxRate.minRate), 0);
      expect(convertMinor(-1, FxRate.minRate), 0);
      expect(convertMinor(1, FxRate.maxRate), 1000000); // UX-A: up to 1,000,000 home units per foreign unit
      expect(convertMinor(-1, FxRate.maxRate), -1000000);
    });

    test('the largest amount at the largest fast-path rate (10^8) is exact (no 64-bit or 2^53 overflow)', () {
      const max = WalletSettings.maxAmount, fast = 100000000;
      expect(convertMinor(max, fast), _ref(max, fast));
      expect(convertMinor(-max, fast), -max * 100);
      expect(convertMinor(max - 1, fast - 1), _ref(max - 1, fast - 1));
      // UX-A: above it BigInt; a result past 2^53 is capped (homeAmount refuses it anyway).
      expect(convertMinor(1000000000, FxRate.maxRate), _ref(1000000000, FxRate.maxRate));
      expect(convertMinor(max, FxRate.maxRate), 9007199254740991);
    });

    test('random amounts and rates match the BigInt reference', () {
      final r = Random(15);
      for (var i = 0; i < 5000; i++) {
        final a = (r.nextInt(1 << 30) * (1 << 6) + r.nextInt(1 << 6)) % WalletSettings.maxAmount * (r.nextBool() ? 1 : -1);
        final rate = 1 + r.nextInt(100000000);
        expect(convertMinor(a, rate), _ref(a, rate), reason: '$a × $rate');
      }
    });
  });

  group('homeAmount', () {
    final st = _withRates(const WalletSettings(), {'USD': 924000});

    test('own currency as it is, a rate converted, no rate null', () {
      expect(homeAmount(const Tx(id: 'a', source: 'pbz', date: '2026-03-01', amount: -1234), st), -1234);
      expect(homeAmount(const Tx(id: 'b', source: 'revolut', date: '2026-03-01', amount: -10000, currency: 'USD'), st), -9240);
      expect(homeAmount(const Tx(id: 'c', source: 'revolut', date: '2026-03-01', amount: -10000, currency: 'CHF'), st), isNull);
    });

    test('the bank amount hook wins over a rate; the wallet currency never converts', () {
      expect(homeAmount(const Tx(id: 'd', source: 'revolut', date: '2026-03-01', amount: -10000, currency: 'USD', homeAmount: -9300), st),
          -9300);
      expect(homeAmount(const Tx(id: 'e', source: 'pbz', date: '2026-03-01', amount: -500, homeAmount: -1), st), -500);
      final eurRate = WalletSettings.fromMap({
        'fx:EUR': {'rate': 2000000, 'date': '2026-03-01', 'home': 'USD'}
      });
      expect(eurRate.fxRates, isEmpty);
      expect(homeAmount(const Tx(id: 'f', source: 'pbz', date: '2026-03-01', amount: -500), eurRate), -500);
    });
  });

  group('inHomeCurrency', () {
    test('no rates: the very same list; rates but nothing foreign: the same list', () {
      final rows = [ct('2026-03-02', -500, 'Groceries'), fx('2026-03-02', -700, 'Groceries', 'USD')];
      expect(identical(inHomeCurrency(rows, const WalletSettings()), rows), isTrue);
      final eurOnly = [ct('2026-03-02', -500, 'Groceries')];
      expect(identical(inHomeCurrency(eurOnly, _withRates(const WalletSettings(), {'USD': 924000})), eurOnly), isTrue);
    });

    test('a row with a rate becomes a wallet-currency row; same id, original kept; others untouched', () {
      final st = _withRates(const WalletSettings(), {'USD': 924000});
      final eur = ct('2026-03-02', -500, 'Groceries');
      final usd = fx('2026-03-03', -10000, 'Eating out', 'USD');
      final chf = fx('2026-03-04', -1234, 'Groceries', 'CHF');
      final out = inHomeCurrency([eur, usd, chf], st);
      expect(identical(out[0], eur), isTrue);
      expect(identical(out[2], chf), isTrue);
      final c = out[1];
      expect((c.tx.id, c.tx.currency, c.tx.amount, c.amount), (usd.tx.id, 'EUR', -9240, -9240));
      expect((c.originalAmount, c.originalCurrency), (-10000, 'USD'));
      expect((c.category, c.kind, c.date, c.tx.source), (usd.category, usd.kind, usd.date, 'revolut'));
      expect((eur.originalAmount, eur.originalCurrency), (null, null));
      expect(c.withCategory('Groceries').originalAmount, -10000);
    });

    test('split parts are converted one by one and add up to the converted whole (remainder to the last part)', () {
      // 3 parts of 1 cent at 0.5 each round to 1, but the whole (3 cents) is 2: the last part takes 0.
      const t = Tx(id: 'split-1', source: 'revolut', date: '2026-03-05', amount: -3, currency: 'USD');
      final cz = Categorizer(splits: {
        t.id: const [
          SplitPart(amount: -1, category: 'Groceries'),
          SplitPart(amount: -1, category: 'Eating out'),
          SplitPart(amount: -1, category: 'Shopping'),
        ],
      });
      final parts = cz.expand(t);
      expect(parts, hasLength(3));
      final st = _withRates(const WalletSettings(), {'USD': 500000});
      final out = inHomeCurrency(parts, st);
      expect([for (final p in out) p.amount], [-1, -1, 0]);
      expect(out.fold(0, (s, p) => s + p.amount), convertMinor(-3, 500000));
      expect([for (final p in out) p.originalAmount], [-1, -1, -1]);
      expect(out.every((p) => p.tx.currency == 'EUR' && p.tx.amount == -2 && p.isPart), isTrue);
      expect(identical(out[0].whole, out[2].whole), isTrue);
      expect((out[0].whole!.amount, out[0].whole!.originalAmount, out[0].whole!.originalCurrency), (-2, -3, 'USD'));

      // Bigger parts: the sum still equals the converted whole.
      const u = Tx(id: 'split-2', source: 'revolut', date: '2026-03-05', amount: -10001, currency: 'USD');
      final cz2 = Categorizer(splits: {
        u.id: const [
          SplitPart(amount: -3333, category: 'Groceries'),
          SplitPart(amount: -3333, category: 'Eating out'),
          SplitPart(amount: -3335, category: 'Shopping'),
        ],
      });
      final out2 = inHomeCurrency(cz2.expand(u), _withRates(const WalletSettings(), {'USD': 924321}));
      expect(out2.fold(0, (s, p) => s + p.amount), convertMinor(-10001, 924321));
      expect(out2[0].amount, convertMinor(-3333, 924321));
    });

    test('a split payment with a bank home amount shares it across the parts (remainder to the last)', () {
      const t = Tx(id: 'split-3', source: 'revolut', date: '2026-03-05', amount: -300, currency: 'USD', homeAmount: -280);
      final cz = Categorizer(splits: {
        t.id: const [
          SplitPart(amount: -100, category: 'Groceries'),
          SplitPart(amount: -100, category: 'Shopping'),
          SplitPart(amount: -100, category: 'Eating out'),
        ],
      });
      final st = _withRates(const WalletSettings(), {'USD': 500000}); // the bank amount wins over the rate
      final out = inHomeCurrency(cz.expand(t), st);
      expect([for (final p in out) p.amount], [-93, -93, -94]); // -93.33 each, the last takes the rest
      expect(out.every((p) => p.tx.currency == 'EUR' && p.originalAmount == -100), isTrue);
      expect(out.first.whole!.amount, -280);
      // Only the last part in the list: its own share, never the remainder.
      expect(inHomeCurrency([cz.expand(t).last], st).single.amount, -93);
      final whole = inHomeCurrency([cz.categorize(t)], st).single;
      expect((whole.amount, whole.originalAmount), (-280, -300));
    });

    test('a list without the earlier parts converts each part on its own (no remainder from the whole)', () {
      const t = Tx(id: 'split-4', source: 'revolut', date: '2026-03-05', amount: -3, currency: 'USD');
      final parts = Categorizer(splits: {
        t.id: const [
          SplitPart(amount: -1, category: 'Groceries'),
          SplitPart(amount: -1, category: 'Eating out'),
          SplitPart(amount: -1, category: 'Shopping'),
        ],
      }).expand(t);
      final st = _withRates(const WalletSettings(), {'USD': 500000});
      expect(inHomeCurrency([parts.last], st).single.amount, -1);
      expect([
        for (final p in inHomeCurrency([parts[1], parts[2]], st)) p.amount
      ], [
        -1,
        -1
      ]);
      // The same part twice does not count as two earlier parts.
      expect([
        for (final p in inHomeCurrency([parts[0], parts[0], parts[2]], st)) p.amount
      ], [
        -1,
        -1,
        -1
      ]);
      expect([for (final p in inHomeCurrency(parts, st)) p.amount], [-1, -1, 0]);
    });

    test('a converted amount beyond maxAmount leaves the row foreign', () {
      final st = _withRates(const WalletSettings(), {'USD': 2000000});
      const big = Tx(id: 'big', source: 'revolut', date: '2026-03-05', amount: -WalletSettings.maxAmount, currency: 'USD');
      const ok = Tx(id: 'ok', source: 'revolut', date: '2026-03-05', amount: -WalletSettings.maxAmount ~/ 2, currency: 'USD');
      expect(homeAmount(big, st), isNull);
      expect(homeAmount(ok, st), -WalletSettings.maxAmount);
      final row = CategorizedTx(big, 'Groceries', kindOf('Groceries'));
      expect(identical(inHomeCurrency([row], st).single, row), isTrue);
      expect(monthSummary([row], '2026-03', currency: 'EUR').foreignByCurrency, {'USD': -WalletSettings.maxAmount});
    });
  });

  group('money paths on the converted list', () {
    const base = WalletSettings(salary: 200000, rent: 50000, periodStart: '2026-03-15', paydayDay: 15, currency: 'EUR');
    final st = _withRates(base, {'USD': 500000});
    const today = '2026-03-20';
    final eur = [
      ct('2026-03-15', 200000, 'Salary'),
      ct('2026-03-16', -3000, 'Groceries'),
      ct('2026-03-16', -50000, 'Rent'),
    ];
    final usd = [
      fx('2026-03-17', -7000, 'Groceries', 'USD'),
      fx('2026-03-18', 1000, 'Extra income', 'USD'),
      fx('2026-03-18', -99999, 'Internal transfer', 'USD'),
      fx('2026-03-18', -55555, 'Groceries', 'USD', deleted: true),
    ];
    final chf = [fx('2026-03-18', -1234, 'Eating out', 'CHF')];
    // What the USD rows are worth at 0.5, written as EUR rows.
    final asEur = [ct('2026-03-17', -3500, 'Groceries'), ct('2026-03-18', 500, 'Extra income')];
    final mixed = [...eur, ...usd, ...chf];

    test('computePeriod counts a currency with a rate at the converted amount, one without as today', () {
      final p = computePeriod(inHomeCurrency(mixed, st), st, const [], today, table: CategoryTable.builtIn);
      final want = computePeriod([...eur, ...asEur, ...chf], st, const [], today, table: CategoryTable.builtIn);
      expect((
        p.received,
        p.extras,
        p.income,
        p.spent,
        p.remaining,
        p.allowanceToday
      ), (
        want.received,
        want.extras,
        want.income,
        want.spent,
        want.remaining,
        want.allowanceToday,
      ));
      expect(p.spent, 3000 + 3500);
      expect(p.foreignByCurrency, {'CHF': -1234});
      // Without rates nothing changes from today's behaviour.
      final raw = computePeriod(inHomeCurrency(mixed, base), base, const [], today, table: CategoryTable.builtIn);
      final plain = computePeriod(mixed, base, const [], today, table: CategoryTable.builtIn);
      expect((raw.spent, raw.income), (plain.spent, plain.income));
      expect(raw.foreignByCurrency, plain.foreignByCurrency);
      expect(plain.foreignByCurrency, {'USD': -7000 + 1000, 'CHF': -1234});
    });

    test('monthSummary, budgetVsActual, categoryShare and the CSV summary count the converted rows', () {
      final conv = inHomeCurrency(mixed, st);
      final want = [...eur, ...asEur, ...chf];
      final m = monthSummary(conv, '2026-03', currency: 'EUR'), w = monthSummary(want, '2026-03', currency: 'EUR');
      expect((m.income, m.out), (w.income, w.out));
      expect(m.byCategory, w.byCategory);
      expect(m.foreignByCurrency, {'CHF': -1234});
      final b = budgetVsActual(conv, '2026-03', const {'Groceries': 10000}, today: today, currency: 'EUR');
      expect(b.lines.singleWhere((l) => l.category == 'Groceries').actual, 6500);
      final range = DateRange(start: '2026-03-01', end: '2026-03-31');
      final s = categoryShare(conv, range, currency: 'EUR'), sw = categoryShare(want, range, currency: 'EUR');
      expect(s.total, sw.total);
      expect([for (final x in s.slices) (x.category, x.spent)], [for (final x in sw.slices) (x.category, x.spent)]);
      expect(s.foreignByCurrency, {'CHF': -1234});
      expect(monthlySummaryCsv(conv, currency: 'EUR'), monthlySummaryCsv(want, currency: 'EUR'));
    });

    test('a wallet in USD counts its USD rows as they are and converts EUR by its own rate', () {
      final usdWallet = _withRates(WalletSettings.fromMap({...base.toMap(), 'currency': 'USD'}), {'EUR': 2000000});
      final conv = inHomeCurrency([...eur, usd.first], usdWallet);
      expect(identical(conv.last, usd.first), isTrue);
      expect(conv.first.tx.amount, 400000);
      final m = monthSummary(conv, '2026-03', currency: 'USD');
      expect(m.out, 7000 + 6000 + 100000);
    });
  });

  group('settings', () {
    test('fromMap reads valid rows and drops bad ones under the key fx; toMap round trips', () {
      late WalletSettings s;
      final logs = _logs(() => s = WalletSettings.fromMap({
            'fx:USD': {'rate': 924000, 'date': '2026-03-01', 'home': 'EUR'},
            'fx:GBP': {'rate': 1170000.0, 'date': '2026-03-02', 'home': 'EUR'},
            'fx:JPY': {'rate': FxRate.maxRate, 'date': '2026-03-02', 'home': 'EUR'},
            'fx:CHF': {'rate': 0, 'date': '2026-03-01', 'home': 'EUR'},
            'fx:SEK': {'rate': FxRate.maxRate + 1, 'date': '2026-03-01', 'home': 'EUR'},
            'fx:NOK': {'rate': 1.5, 'date': '2026-03-01', 'home': 'EUR'},
            'fx:DKK': {'rate': 100000},
            'fx:PLN': {'rate': 100000, 'date': '2026-02-30', 'home': 'EUR'},
            'fx:usd': {'rate': 100000, 'date': '2026-03-01', 'home': 'EUR'},
            'fx:HUF': 'x',
            'fx:HKD': {'rate': 100000, 'date': '2026-03-01'}, // no home: invalid
            'fx:CZK': {'rate': 100000, 'date': '2026-03-01', 'home': 'CZK'},
            'fx:CAD': {'rate': 680000, 'date': '2026-03-01', 'home': 'CHF'}, // set before a switch CHF -> EUR
            'salary': 100000,
          }));
      expect(s.fxRates, {
        'USD': const FxRate(924000, '2026-03-01', home: 'EUR'),
        'GBP': const FxRate(1170000, '2026-03-02', home: 'EUR'),
        'JPY': const FxRate(FxRate.maxRate, '2026-03-02', home: 'EUR')
      });
      expect(s.salary, 100000);
      final warn = logs.where((l) => l.contains('settings.invalid')).toList();
      expect(warn, hasLength(1));
      expect(warn.single, contains('fx'));
      for (final l in logs) {
        expect(l, isNot(contains('924000')));
      }
      expect(WalletSettings.fromMap(s.toMap()).fxRates, s.fxRates);
      expect(s.fxStale, {'CAD': const FxRate(680000, '2026-03-01', home: 'CHF')});
      expect(WalletSettings.fromMap(s.toMap()).fxStale, s.fxStale);
      expect(
          _logs(() => WalletSettings.fromMap({
                'fx:EUR': {'rate': 1000000, 'date': '2026-03-01', 'home': 'USD'}
              })).where((l) => l.contains('settings.invalid')),
          isEmpty);
    });

    test('repo setFxRate / removeFxRate: dated today, refusals, nothing written when unchanged', () {
      final now = DateTime.utc(2026, 3, 25, 12).millisecondsSinceEpoch;
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      r.setFxRate('USD', 924000);
      expect(r.settings().fxRates, {'USD': const FxRate(924000, '2026-03-25', home: 'EUR')});
      final ops = r.pendingOps().length;
      r.setFxRate('USD', 924000);
      expect(r.pendingOps().length, ops);
      for (final (code, rate) in const [('EUR', 1000000), ('usd', 1000000), ('US', 1000000), ('USD', 0), ('USD', FxRate.maxRate + 1)]) {
        expect(() => r.setFxRate(code, rate), throwsArgumentError, reason: '$code $rate');
      }
      expect(() => r.removeFxRate('EUR'), throwsArgumentError);
      expect(() => r.removeFxRate('x'), throwsArgumentError);
      expect(
          () => r.updateSettings({
                'fx:USD': {'rate': 1, 'date': '2026-03-01'}
              }),
          throwsArgumentError);
      // Undo restores the exact entry: an older date may be given, never one after today.
      r.setFxRate('USD', 910000, date: '2026-03-01');
      expect(r.settings().fxRates['USD'], const FxRate(910000, '2026-03-01', home: 'EUR'));
      for (final d in ['2026-03-26', '2026-02-30', '1 Mar']) {
        expect(() => r.setFxRate('USD', 910000, date: d), throwsArgumentError, reason: d);
      }
      r.setFxRate('USD', 910000, date: '2026-03-25');
      expect(r.settings().fxRates['USD']!.date, '2026-03-25');
      r.setFxRate('GBP', 1170000);
      r.removeFxRate('USD');
      expect(r.settings().fxRates.keys, ['GBP']);
      final after = r.pendingOps().length;
      r.removeFxRate('USD');
      expect(r.pendingOps().length, after);
    });
  });

  group('paydays, plan suggestions and search on the converted list', () {
    final st = _withRates(const WalletSettings(paydayDay: 10), {'USD': 500000});
    const today = '2026-06-20';
    final usdSalary = [
      for (final m in ['01', '02', '03', '04', '05', '06']) fx('2026-$m-10', 400000, 'Salary', 'USD')
    ];

    test('a USD income row with a rate is no payday and suggests no salary or payday', () {
      final conv = inHomeCurrency(usdSalary, st);
      expect(conv.every((t) => t.tx.currency == 'EUR'), isTrue);
      expect(salaryPaydays(conv, today, currency: 'EUR'), isEmpty);
      expect(detectPaydays(conv, st, today), detectPaydays(usdSalary, st, today));
      expect(periodSummaries(conv, st, today).length, periodSummaries(usdSalary, st, today).length);
      final s = suggestPlan(conv, st, today);
      expect((s.salary, s.paydayDay), (null, null));
      // EUR salary rows still find paydays next to the converted ones.
      final eur = [
        for (final m in ['04', '05', '06']) ct('2026-$m-12', 300000, 'Salary')
      ];
      expect(salaryPaydays([...conv, ...eur], today, currency: 'EUR'), ['2026-04-12', '2026-05-12', '2026-06-12']);
    });

    test('an amount query finds a converted row by its converted and by its original amount', () {
      final row = fx('2026-03-03', -10000, 'Eating out', 'USD');
      final conv = inHomeCurrency([row], _withRates(const WalletSettings(), {'USD': 924000}));
      SearchResult find(String q) => searchAll(q, txs: conv, goals: const [], wishlist: const [], bills: const []);
      expect(find('92.40').txs.map((t) => t.tx.id), [row.tx.id]);
      expect(find('100').txs.map((t) => t.tx.id), [row.tx.id]);
      expect(find('99').txs, isEmpty);
    });
  });

  group('a rate belongs to the wallet currency it was set against', () {
    test('after a switch EUR -> CHF a rate set against EUR counts nowhere and is listed as stale', () {
      final now = DateTime.utc(2026, 3, 25, 12).millisecondsSinceEpoch;
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      const usd = Tx(id: 'u', source: 'revolut', date: '2026-03-05', amount: -10000, currency: 'USD');
      r.setFxRate('USD', 924000);
      expect(homeAmount(usd, r.settings()), -9240);
      r.updateSettings({'currency': 'CHF'});
      final chf = r.settings();
      expect(chf.fxRates, isEmpty);
      expect(chf.fxStale, {'USD': const FxRate(924000, '2026-03-25', home: 'EUR')});
      expect(homeAmount(usd, chf), isNull);
      r.setFxRate('USD', 1010000);
      expect(r.settings().fxRates['USD'], const FxRate(1010000, '2026-03-25', home: 'CHF'));
      expect(r.settings().fxStale, isEmpty);
      r.updateSettings({'currency': 'EUR'});
      expect(r.settings().fxRates, isEmpty);
      expect(r.settings().fxStale.keys, ['USD']);
      r.removeFxRate('USD');
      expect(r.settings().fxStale, isEmpty);
    });
  });

  group('computePeriod matches bills on the raw rows', () {
    // Payday on the 1st: the period 2026-10-01 .. 2026-10-31, today 2026-10-28.
    final st = _withRates(const WalletSettings(salary: 100000, paydayDay: 1, periodStart: '2026-10-01'), {'USD': 500000});
    const day = '2026-10-28';
    const paid = Tx(id: 'pw', source: 'revolut', date: '2026-10-28', amount: -6000, currency: 'USD', description: 'SYNTH POWER');
    final bill = RecurringBill(
        id: 'rec:synth_power',
        payee: merchantKey(paid),
        label: 'SYNTH POWER',
        category: 'Bills & one-offs',
        expectedAmount: 3000,
        intervalDays: 365, // a yearly bill: held until a matching row pays it (RecurringPayments.paidBy)
        nextDue: '2026-10-30',
        status: 'confirmed');
    final raw = [CategorizedTx(paid, 'Bills & one-offs', kindOf('Bills & one-offs'))];

    test('a USD row worth the EUR bill after conversion never pays it: reserve as without conversion', () {
      final conv = inHomeCurrency(raw, st);
      expect(conv.single.tx.amount, -3000);
      final before = computePeriod(raw, st, const [], day, bills: [bill], table: CategoryTable.builtIn);
      final after = computePeriod(conv, st, const [], day, bills: [bill], table: CategoryTable.builtIn, matchRows: raw);
      expect(after.reservedBills, before.reservedBills);
      expect(after.dueBills.map((b) => b.id), before.dueBills.map((b) => b.id));
      expect(after.spent, 3000); // the money still counts at the converted amount
      // Matching on the converted list would take the USD row for the EUR bill.
      final wrong = computePeriod(conv, st, const [], day, bills: [bill], table: CategoryTable.builtIn);
      expect(wrong.reservedBills, isNot(before.reservedBills));
    });

    test('a converted income row never lands a confirmed income', () {
      const inc = Tx(id: 'in', source: 'revolut', date: '2026-10-10', amount: 6000, currency: 'USD', description: 'SYNTH CLIENT');
      final income = RecurringBill(
          id: 'rec:synth_client',
          payee: merchantKey(inc),
          label: 'SYNTH CLIENT',
          category: 'Extra income',
          expectedAmount: 3000,
          nextDue: '2026-10-25',
          status: 'confirmed',
          direction: RecurringBill.directionIn);
      final rows = [CategorizedTx(inc, 'Extra income', kindOf('Extra income'))];
      final before = computePeriod(rows, st, const [], day, bills: [income], table: CategoryTable.builtIn);
      final after =
          computePeriod(inHomeCurrency(rows, st), st, const [], day, bills: [income], table: CategoryTable.builtIn, matchRows: rows);
      expect(after.landedIncome, before.landedIncome);
      expect(after.expectedIncome.length, before.expectedIncome.length);
    });
  });

  group('whole-payment paths keep the row\'s own currency and amount', () {
    test('a EUR entry equal to a USD row\'s converted amount is never matched to it; ids and rows unchanged', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.setFxRate('USD', 500000);
      r.addTransaction(date: '2026-03-10', amount: 5000, category: 'Groceries'); // an expense of 50.00
      const desc = 'SYNTH STORE';
      final s = r.importBatch(ImportBatch(source: 'revolut', transactions: [
        NormalizedTransaction(
            id: transactionId('2026-03-10', -10000, desc, 0),
            source: 'revolut',
            date: '2026-03-10',
            amountMinor: -10000,
            currency: 'USD',
            bankType: 'CARD_PAYMENT',
            description: desc),
      ]));
      expect((s.added, s.matched), (1, 0));
      final bank = r.transactions().singleWhere((t) => t.source == 'revolut');
      expect((bank.id, bank.amount, bank.currency), (transactionId('2026-03-10', -10000, desc, 0), -10000, 'USD'));
      final rows = r.categorizer().expandAll(r.transactions());
      final conv = inHomeCurrency(rows, r.settings());
      expect([for (final t in conv) t.tx.id], [for (final t in rows) t.tx.id]);
      // The money list counts both; the raw list (matching, accounts, recurring) still says USD.
      expect(monthSummary(conv, '2026-03', currency: 'EUR').out, 10000);
      expect(wholePayments(rows).map((t) => t.currency).toSet(), {'EUR', 'USD'});
    });

    test('recurring detection, transfers and account balances read raw rows: a rate changes nothing', () {
      final rows = [
        for (final m in ['2026-01', '2026-02', '2026-03']) fx('$m-05', -999, 'Subscriptions', 'USD'),
        for (final m in ['2026-01', '2026-02', '2026-03']) ct('$m-06', -1500, 'Subscriptions'),
      ];
      final before = detectRecurring(rows, today: '2026-03-20', currency: 'EUR');
      expect(before.every((b) => b.expectedAmount == 1500 || b.expectedAmount == -1500), isTrue);
      final raw = [for (final t in rows) t.tx];
      final tp = planTransfers(raw);
      final st = _withRates(const WalletSettings(), {'USD': 500000});
      // The app passes the raw rows: same inputs, same results, whatever the rates.
      expect(st.fxRates, isNotEmpty);
      expect(detectRecurring(rows, today: '2026-03-20', currency: 'EUR').length, before.length);
      expect(planTransfers(raw).paired, tp.paired);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = DateTime.utc(2026, 3, 25, 12).millisecondsSinceEpoch;
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
      tmp = Directory.systemTemp.createTempSync('bw-p15-');
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

    test('different rates set offline: the later write wins per currency; other currencies kept', () async {
      final a = device('a'), b = device('b');
      a.repo.setFxRate('USD', 900000);
      a.repo.setFxRate('GBP', 1170000);
      now += 1000;
      b.repo.setFxRate('USD', 950000);
      await round();
      await round();
      for (final d in [a, b]) {
        expect(d.repo.settings().fxRates.map((k, v) => MapEntry(k, v.rate)), {'USD': 950000, 'GBP': 1170000}, reason: d.name);
      }
      now += 1000;
      a.repo.removeFxRate('USD');
      await round();
      await round();
      expect(b.repo.settings().fxRates.keys, ['GBP']);
    });
  });
}
