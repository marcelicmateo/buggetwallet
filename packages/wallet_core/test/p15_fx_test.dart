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
      for (final MapEntry(:key, :value) in rates.entries) 'fx:$key': {'rate': value, 'date': '2026-03-01'},
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
      expect(convertMinor(1, FxRate.maxRate), 1000);
      expect(convertMinor(-1, FxRate.maxRate), -1000);
    });

    test('the largest amount at the largest rate is exact (no 64-bit or 2^53 overflow)', () {
      const max = WalletSettings.maxAmount;
      expect(convertMinor(max, FxRate.maxRate), _ref(max, FxRate.maxRate));
      expect(convertMinor(-max, FxRate.maxRate), -max * 1000);
      expect(convertMinor(max - 1, FxRate.maxRate - 1), _ref(max - 1, FxRate.maxRate - 1));
    });

    test('random amounts and rates match the BigInt reference', () {
      final r = Random(15);
      for (var i = 0; i < 5000; i++) {
        final a = (r.nextInt(1 << 30) * (1 << 6) + r.nextInt(1 << 6)) % WalletSettings.maxAmount * (r.nextBool() ? 1 : -1);
        final rate = 1 + r.nextInt(FxRate.maxRate);
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
        'fx:EUR': {'rate': 2000000, 'date': '2026-03-01'}
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

    test('a split payment with a bank home amount keeps its parts foreign; its whole row converts', () {
      const t = Tx(id: 'split-3', source: 'revolut', date: '2026-03-05', amount: -300, currency: 'USD', homeAmount: -280);
      final cz = Categorizer(splits: {
        t.id: const [SplitPart(amount: -100, category: 'Groceries'), SplitPart(amount: -200, category: 'Shopping')],
      });
      final st = _withRates(const WalletSettings(), {'USD': 500000});
      final parts = cz.expand(t);
      final out = inHomeCurrency(parts, st);
      expect(out.every((p) => p.tx.currency == 'USD' && p.originalAmount == null), isTrue);
      final whole = inHomeCurrency([cz.categorize(t)], st).single;
      expect((whole.amount, whole.originalAmount), (-280, -300));
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
            'fx:USD': {'rate': 924000, 'date': '2026-03-01'},
            'fx:GBP': {'rate': 1170000.0, 'date': '2026-03-02'},
            'fx:JPY': {'rate': FxRate.maxRate, 'date': '2026-03-02'},
            'fx:CHF': {'rate': 0, 'date': '2026-03-01'},
            'fx:SEK': {'rate': FxRate.maxRate + 1, 'date': '2026-03-01'},
            'fx:NOK': {'rate': 1.5, 'date': '2026-03-01'},
            'fx:DKK': {'rate': 100000},
            'fx:PLN': {'rate': 100000, 'date': '2026-02-30'},
            'fx:usd': {'rate': 100000, 'date': '2026-03-01'},
            'fx:HUF': 'x',
            'salary': 100000,
          }));
      expect(s.fxRates, {
        'USD': const FxRate(924000, '2026-03-01'),
        'GBP': const FxRate(1170000, '2026-03-02'),
        'JPY': const FxRate(FxRate.maxRate, '2026-03-02')
      });
      expect(s.salary, 100000);
      final warn = logs.where((l) => l.contains('settings.invalid')).toList();
      expect(warn, hasLength(1));
      expect(warn.single, contains('fx'));
      for (final l in logs) {
        expect(l, isNot(contains('924000')));
      }
      expect(WalletSettings.fromMap(s.toMap()).fxRates, s.fxRates);
      expect(
          _logs(() => WalletSettings.fromMap({
                'fx:EUR': {'rate': 1000000, 'date': '2026-03-01'}
              })).where((l) => l.contains('settings.invalid')),
          isEmpty);
    });

    test('repo setFxRate / removeFxRate: dated today, refusals, nothing written when unchanged', () {
      final now = DateTime.utc(2026, 3, 25, 12).millisecondsSinceEpoch;
      final r = WalletRepo.inMemory(now: () => now);
      addTearDown(r.close);
      r.setFxRate('USD', 924000);
      expect(r.settings().fxRates, {'USD': const FxRate(924000, '2026-03-25')});
      final ops = r.pendingOps().length;
      r.setFxRate('USD', 924000);
      expect(r.pendingOps().length, ops);
      for (final (code, rate) in const [('EUR', 1000000), ('usd', 1000000), ('US', 1000000), ('USD', 0), ('USD', 1000000001)]) {
        expect(() => r.setFxRate(code, rate), throwsArgumentError, reason: '$code $rate');
      }
      expect(() => r.removeFxRate('EUR'), throwsArgumentError);
      expect(() => r.removeFxRate('x'), throwsArgumentError);
      expect(
          () => r.updateSettings({
                'fx:USD': {'rate': 1, 'date': '2026-03-01'}
              }),
          throwsArgumentError);
      r.setFxRate('GBP', 1170000);
      r.removeFxRate('USD');
      expect(r.settings().fxRates.keys, ['GBP']);
      final after = r.pendingOps().length;
      r.removeFxRate('USD');
      expect(r.pendingOps().length, after);
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
