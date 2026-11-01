// Stage UX-A core (docs/context/UX_SPEC.md), the builder's own tests: the storage rule (lead, 2026-11-01: fiat stored in
// hundredths as always, BTC in satoshis), typed input, CSV export and FX at storage digits, the wallet currency setter,
// account kinds without rows, a crypto account's value, built-in rule ids, and per-bill reminder days. All SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart' show entitySchema;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch, NormalizedBill, NormalizedTransaction, BillSource;

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 00:00 UTC in ms.
const _now = 1791590400000;

NormalizedTransaction _row(String id, int minor, String currency, {String desc = 'Synthetic shop'}) => NormalizedTransaction(
    id: id, source: 'revolut', date: '2026-10-05', amountMinor: minor, currency: currency, bankType: 'Card Payment', description: desc);

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => _now));
  tearDown(() => repo.close());

  group('storage scale', () {
    test('storage digits: 2 for every fiat currency, 8 for BTC; display digits for showing and typing', () {
      expect([
        for (final c in ['EUR', 'JPY', 'KWD', 'BTC', 'ZZZ']) storageDigitsOf(c)
      ], [
        2,
        2,
        2,
        8,
        2
      ]);
      expect([
        for (final c in ['EUR', 'JPY', 'KWD', 'BTC']) displayDigitsOf(c)
      ], [
        2,
        0,
        2,
        8
      ]);
    }, timeout: _t);

    test('a row an older build stored reads unchanged; ops carry no new tx field', () {
      repo.db.execute(
          "INSERT INTO tx(id, source, date, amount, currency, bank_type, description) VALUES('old', 'revolut', '2026-10-04', -100000, 'JPY', 'Card Payment', 'Old shop')");
      expect(repo.transaction('old')!.amount, -100000, reason: '1,000 yen in hundredths, as always');
      repo.importBatch(ImportBatch(source: 'revolut', transactions: [_row('j1', -100000, 'JPY')]));
      final f = [
        for (final (_, op) in repo.pendingOps())
          if (op.entity == 'tx' && op.id == 'j1') op.fields
      ].single;
      expect(f.keys.toSet().difference(entitySchema['tx']!.columnNames.toSet()), isEmpty);
      expect(f.containsKey('digits'), isFalse);
    }, timeout: _t);
  });

  group('typed amounts and the CSV export', () {
    test('parseMoneyCents: digits = the typed decimals, the result in stored units', () {
      expect(parseMoneyCents('12,50'), 1250);
      expect(parseMoneyCents('1000', digits: 0), 100000, reason: 'yen are typed whole and stored in hundredths');
      expect(parseMoneyCents('1,000', digits: 0), 100000, reason: 'a comma then three digits groups thousands');
      expect(parseMoneyCents('10.5', digits: 0), isNull, reason: 'yen are typed without a fraction: refused, never rounded');
      expect(parseMoneyCents('10.00', digits: 0), 1000, reason: 'zeros past the point are no fraction');
      expect(parseMoneyCents('0.01', digits: 8), 1000000);
      expect(parseMoneyCents('0,5', digits: 8), 50000000);
      expect(parseMoneyCents('0.00000001', digits: 8), 1);
      expect(parseMoneyCents('0.000000001', digits: 8), isNull);
    }, timeout: _t);

    test('centsToDecimal with digits', () {
      expect(centsToDecimal(-1234), '-12.34');
      expect(centsToDecimal(-100000), '-1000.00');
      expect(centsToDecimal(1000000, digits: 8), '0.01000000');
      expect(centsToDecimal(-1, digits: 8), '-0.00000001');
    }, timeout: _t);

    test('the transactions CSV writes each row at its storage digits', () {
      const rows = [
        CategorizedTx(Tx(id: 'a', source: 'revolut', date: '2026-10-01', amount: -100000, currency: 'JPY', description: 'A'), 'Shopping',
            BudgetKind.flex),
        CategorizedTx(Tx(id: 'b', source: 'revolut', date: '2026-10-02', amount: -1234, description: 'B'), 'Shopping', BudgetKind.flex),
        CategorizedTx(Tx(id: 'c', source: 'revolut', date: '2026-10-03', amount: 1000000, currency: 'BTC', description: 'C'), 'Shopping',
            BudgetKind.flex),
      ];
      final lines = transactionsCsv(rows).trim().split('\n');
      expect(lines[1], startsWith('2026-10-01,-1000.00,'));
      expect(lines[2], startsWith('2026-10-02,-12.34,'));
      expect(lines[3], startsWith('2026-10-03,0.01000000,'));
    }, timeout: _t);
  });

  group('FX with digits', () {
    test('fiat to fiat is the pre-20 math; BTC scales by 10^6; the function itself takes any digits', () {
      expect(convertMinor(100000, 6500), 650, reason: '1,000 yen (hundredths) at 0.0065 EUR');
      expect(convertMinor(100000, 6500), convertMinor(100000, 6500, fromDigits: 2, toDigits: 2));
      expect(convertMinor(100000000, 50000000000, fromDigits: 8, toDigits: 2), 5000000, reason: '1 BTC at 50,000 EUR');
      expect(convertMinor(1, 50000000000, fromDigits: 8, toDigits: 2), 0);
      expect(convertMinor(-650, 153846154, fromDigits: 2, toDigits: 0), -1000);
      expect(convertMinor(5, 1000000, fromDigits: 3, toDigits: 2), 1, reason: 'half a unit rounds away from zero');
      expect(convertMinor(-5, 1000000, fromDigits: 3, toDigits: 2), -1);
    }, timeout: _t);

    test('a crypto rate may go to maxCryptoRate; a fiat one stays at maxRate', () {
      repo.setFxRate('BTC', 60000000000);
      expect(repo.settings().fxRates['BTC']!.rate, 60000000000);
      expect(() => repo.setFxRate('BTC', FxRate.maxCryptoRate + 1), throwsArgumentError);
      expect(() => repo.setFxRate('USD', FxRate.maxRate + 1), throwsArgumentError);
      expect(homeAmount(const Tx(id: 'c', source: 'x', date: '2026-10-01', amount: 1000000, currency: 'BTC'), repo.settings()), 60000,
          reason: '0.01 BTC at 60,000 EUR = 600 EUR');
    }, timeout: _t);

    test('a rate an older build stored for a code outside the table is read and can be removed, not set', () {
      repo.db.execute(
          "INSERT INTO settings(id, value, deleted) VALUES('fx:XYZ', '{\"rate\":1000000,\"date\":\"2026-10-01\",\"home\":\"EUR\"}', 0)");
      expect(repo.settings().fxRates.keys, contains('XYZ'));
      expect(() => repo.setFxRate('XYZ', 2000000), throwsArgumentError);
      repo.removeFxRate('XYZ');
      expect(repo.settings().fxRates.keys, isNot(contains('XYZ')));
    }, timeout: _t);
  });

  group('rate range in any wallet currency (review item 3)', () {
    test('a JPY wallet sets USD at 150 yen and BTC at 15,000,000 yen, both exact', () {
      repo.setWalletCurrency('JPY');
      repo.setFxRate('USD', 150000000); // 150 yen per dollar
      repo.setFxRate('BTC', 15000000000000); // 15,000,000 yen per coin
      final st = repo.settings();
      expect(homeAmount(const Tx(id: 'u', source: 'x', date: '2026-10-01', amount: -1234, currency: 'USD'), st), -185100,
          reason: '12.34 USD = 1,851 yen, stored in hundredths');
      expect(homeAmount(const Tx(id: 'b', source: 'x', date: '2026-10-01', amount: 1000000, currency: 'BTC'), st), 15000000,
          reason: '0.01 BTC = 150,000 yen = 15,000,000 hundredths');
      expect(() => repo.setFxRate('USD', FxRate.maxRate + 1), throwsArgumentError);
      expect(() => repo.setFxRate('BTC', FxRate.maxCryptoRate + 1), throwsArgumentError);
      repo.setFxRate('EUR', FxRate.maxRate);
      expect(repo.settings().fxRates['EUR']!.rate, FxRate.maxRate, reason: 'the top of the range is accepted');
    }, timeout: _t);

    test('conversion at the top rates stays exact and never past 2^53', () {
      expect(convertMinor(123456789, FxRate.maxRate), 123456789000000);
      expect(convertMinor(WalletSettings.maxAmount, FxRate.maxRate), 9007199254740991);
      expect(convertMinor(100000000, FxRate.maxCryptoRate, fromDigits: 8, toDigits: 2), 100000000000, reason: '1 BTC at 10^9');
    }, timeout: _t);
  });

  group('wallet currency from a synced row (review item 5)', () {
    test('a crypto or unknown code reads as EUR and is logged by key only', () {
      resetInvalidSettingLog();
      for (final c in ['BTC', 'ZZZ', 'eur', 12]) {
        expect(WalletSettings.fromMap({'currency': c}).currency, 'EUR', reason: '$c');
      }
      expect(WalletSettings.fromMap({'currency': 'JPY'}).currency, 'JPY');
      repo.db.execute("INSERT OR REPLACE INTO settings(id, value, deleted) VALUES('currency', '\"BTC\"', 0)");
      expect(repo.settings().currency, 'EUR');
    }, timeout: _t);
  });

  group('setWalletCurrency', () {
    test('a known fiat code is set; rows keep their currency and amounts', () {
      repo.importBatch(ImportBatch(source: 'revolut', transactions: [_row('e1', -1234, 'EUR')]));
      repo.setWalletCurrency('USD');
      expect(repo.settings().currency, 'USD');
      expect((repo.transaction('e1')!.currency, repo.transaction('e1')!.amount), ('EUR', -1234));
      final ops = repo.pendingOps().length;
      repo.setWalletCurrency('USD');
      expect(repo.pendingOps().length, ops, reason: 'already the wallet currency: no write');
    }, timeout: _t);

    test('unknown and crypto codes are refused and write nothing', () {
      final ops = repo.pendingOps().length;
      for (final c in ['ZZZ', 'usd', '', 'BTC']) {
        expect(() => repo.setWalletCurrency(c), throwsArgumentError, reason: c);
      }
      expect(repo.pendingOps().length, ops);
      expect(repo.settings().currency, 'EUR');
    }, timeout: _t);
  });

  group('account kinds without rows', () {
    Future<String> add(String name, AccountKind kind, {String currency = 'EUR', String? source, int opening = 10000}) =>
        repo.addAccount(name: name, source: source, currency: currency, opening: opening, openingDate: '2026-09-30', kind: kind);

    test('investment and other accounts count no rows, never clash with cash or each other', () async {
      final cash = await add('Wallet', AccountKind.cash);
      final inv = await add('Broker', AccountKind.investment);
      final oth = await add('Jar', AccountKind.other);
      final inv2 = await add('Broker 2', AccountKind.investment, opening: 500);
      repo.addTransaction(date: '2026-10-02', amount: 300, category: 'Groceries');
      final b = {for (final x in accountBalances(repo.accounts(), repo.transactions(includeHidden: true))) x.account.id: x};
      expect(b[cash]!.balance, 10000 - 300);
      expect((b[inv]!.balance, b[inv]!.rowsCounted, b[inv]!.duplicateOf), (10000, 0, null));
      expect((b[oth]!.balance, b[inv2]!.balance), (10000, 500));
      expect(balanceTotals(b.values.toList())['EUR'], 9700 + 10000 + 10000 + 500);
      await expectLater(add('Wallet 2', AccountKind.cash), throwsArgumentError, reason: 'one cash account per currency still');
    }, timeout: _t);

    test('a crypto account in satoshis is worth its coins at the hand-set rate; none without a rate', () async {
      final id = await add('Coins', AccountKind.crypto, currency: 'BTC', opening: 25000000);
      final bal = accountBalances(repo.accounts(), const []).firstWhere((x) => x.account.id == id);
      expect(balanceInHome(bal, repo.settings()), isNull);
      repo.setFxRate('BTC', 60000000000);
      expect(balanceInHome(bal, repo.settings()), 1500000, reason: '0.25 BTC at 60,000 EUR = 15,000.00 EUR');
    }, timeout: _t);

    test('an institution is trimmed, blank clears it', () async {
      final id = await add('Main', AccountKind.bank, source: 'pbz');
      await repo.updateAccount(id, institution: '  Synthetic Bank  ');
      expect(repo.accounts().single.institution, 'Synthetic Bank');
      await repo.updateAccount(id, institution: '  ');
      expect(repo.accounts().single.institution, isNull);
    }, timeout: _t);
  });

  group('built-in rule ids', () {
    test('slugs are unique, legacy indexes name a group head, a later index or junk is unknown', () {
      final ids = builtInRules.map((r) => r.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(builtInRuleById('builtIn:0')!.slug, 'wolt');
      expect(builtInRuleById('builtIn:3')!.category, 'Groceries');
      expect(builtInRuleById('builtIn:9')!.slug, 'keks-pay');
      expect(builtInRuleById('builtIn:10'), isNull);
      expect(builtInRuleById('builtIn:03'), isNull);
      expect(builtInRuleById('builtIn:-1'), isNull);
      expect(builtInRuleById('lidl'), isNull);
    }, timeout: _t);

    test('every old grouped rule still puts the same texts in the same categories', () {
      for (final (text, cat) in const [
        ('wolt', 'Food delivery'),
        ('bolt food', 'Food delivery'),
        ('bolt', 'Car & transport'),
        ('google', 'Bills & subscriptions'),
        ('google play', 'Games & apps'),
        ('dm drogerie', 'Health & care'),
        ('keks pay', 'To people'),
      ]) {
        expect(Categorizer().merchantCategory(text), cat, reason: text);
      }
    }, timeout: _t);

    test('an override row a newer build wrote for an unknown rule is ignored; a damaged one is dropped', () {
      repo.db.execute(
          "INSERT INTO settings(id, value, deleted) VALUES('builtInRule:not-a-rule', '{\"off\":true}', 0), ('builtInRule:lidl', '{\"off\":\"x\"}', 0)");
      expect(repo.settings().builtInRuleOverrides.keys, ['builtIn:not-a-rule']);
      expect(repo.categorizer(withTags: false).merchantCategory('Lidl Zagreb'), 'Groceries');
    }, timeout: _t);

    test('an edit equal to the built-in clears that part of the edit', () {
      repo.editBuiltInRule('builtIn:lidl', category: 'Shopping');
      repo.editBuiltInRule('builtIn:lidl', category: 'Groceries');
      expect(repo.settings().builtInRuleOverrides, isEmpty);
    }, timeout: _t);
  });

  group('bill reminder days', () {
    String bill() {
      final (id, _) = repo.importBill(const NormalizedBill(
          source: BillSource.hub3,
          externalId: 'hub3:synthetic',
          date: '2026-10-01',
          dueDate: '2026-10-20',
          total: 4599,
          payee: 'Synthetic'));
      return id;
    }

    test('the bill own days win; null falls back to the wallet setting; clear goes back', () {
      final id = bill();
      final st = repo.settings();
      expect(effectiveReturnReminderDays(repo.bill(id)!, st), st.returnReminderDays);
      expect(effectiveWarrantyReminderDays(repo.bill(id)!, st), st.warrantyReminderDays);
      repo.updateBill(id, returnReminderDays: 0, warrantyReminderDays: 90);
      expect((repo.bill(id)!.returnReminderDays, repo.bill(id)!.warrantyReminderDays), (0, 90));
      expect(effectiveReturnReminderDays(repo.bill(id)!, st), 0);
      expect(effectiveWarrantyReminderDays(repo.bill(id)!, st), 90);
      repo.updateBill(id, clearReturnReminderDays: true);
      expect(repo.bill(id)!.returnReminderDays, isNull);
      expect(effectiveReturnReminderDays(repo.bill(id)!, st), st.returnReminderDays);
      expect(repo.bill(id)!.warrantyReminderDays, 90);
    }, timeout: _t);

    test('out of range is refused and writes nothing', () {
      final id = bill();
      final before = repo.pendingOps().length;
      expect(() => repo.updateBill(id, returnReminderDays: 31), throwsArgumentError);
      expect(() => repo.updateBill(id, returnReminderDays: -1), throwsArgumentError);
      expect(() => repo.updateBill(id, warrantyReminderDays: 91), throwsArgumentError);
      expect(repo.pendingOps().length, before);
      expect(repo.bill(id)!.returnReminderDays, isNull);
    }, timeout: _t);

    test('a damaged stored value reads as none', () {
      final id = bill();
      repo.db.execute('UPDATE bills SET return_reminder_days = 99, warranty_reminder_days = -3 WHERE id = ?', [id]);
      expect((repo.bill(id)!.returnReminderDays, repo.bill(id)!.warrantyReminderDays), (null, null));
    }, timeout: _t);
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => _now);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 3; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-uxa-core-');
      key = VaultKey.generate();
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('a bill reminder day and a bitcoin row reach the other device', () async {
      final a = device('a'), b = device('b');
      final (id, _) = a.repo.importBill(const NormalizedBill(
          source: BillSource.hub3,
          externalId: 'hub3:synthetic-2',
          date: '2026-10-01',
          dueDate: '2026-10-20',
          total: 4599,
          payee: 'Synthetic'));
      a.repo.updateBill(id, returnReminderDays: 7);
      a.repo.importBatch(ImportBatch(source: 'revolut', transactions: [_row('sat', -12345, 'BTC')]));
      await syncAll([a, b]);
      expect(b.repo.bill(id)!.returnReminderDays, 7);
      expect((b.repo.transaction('sat')!.amount, b.repo.transaction('sat')!.currency), (-12345, 'BTC'));
      b.repo.updateBill(id, clearReturnReminderDays: true);
      await syncAll([a, b]);
      expect(a.repo.bill(id)!.returnReminderDays, isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
