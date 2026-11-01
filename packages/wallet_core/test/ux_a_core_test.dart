// Stage UX-A core (docs/context/UX_SPEC.md), the builder's own tests: stored minor digits (schema 20 `tx.digits`, rows of
// older builds read from cents), digits through typed input, CSV export and FX, account kinds without rows, a crypto
// account's value, built-in rule ids, and per-bill reminder days (owner correction 2026-11-01). All data SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
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

  /// A row as a build before schema 20 stored it: the amount in cents whatever the currency, no `digits`.
  void legacyRow(String id, int cents, String currency) => repo.db.execute(
      "INSERT INTO tx(id, source, date, amount, currency, bank_type, description) VALUES(?, 'revolut', '2026-10-04', ?, ?, 'Card Payment', 'Old shop')",
      [id, cents, currency]);

  group('stored digits (tx.digits)', () {
    test('legacyMinor: cents to the currency own units, both ways, and nothing for 2 digits', () {
      expect(legacyMinor(100000, 'JPY', null), 1000);
      expect(legacyMinor(-100000, 'JPY', null), -1000);
      expect(legacyMinor(150, 'JPY', null), 2, reason: 'half a yen rounds away from zero (never seen in a real export)');
      expect(legacyMinor(123, 'KWD', null), 1230);
      expect(legacyMinor(1, 'BTC', null), 1000000);
      expect(legacyMinor(1234, 'EUR', null), 1234);
      expect(legacyMinor(1000, 'JPY', 0), 1000, reason: 'a schema-20 row is already in yen');
      expect(legacyMinor(1234, 'ZZZ', null), 1234, reason: 'unknown code = 2 digits');
    }, timeout: _t);

    test('a row an older build stored in cents reads in its own units', () {
      legacyRow('old-jpy', -100000, 'JPY');
      legacyRow('old-eur', -1234, 'EUR');
      expect(repo.transaction('old-jpy')!.amount, -1000);
      expect(repo.transaction('old-eur')!.amount, -1234);
    }, timeout: _t);

    test('an import writes digits for a non-2-digit currency only; EUR ops are unchanged', () {
      repo.importBatch(ImportBatch(source: 'revolut', transactions: [_row('j1', -1000, 'JPY'), _row('e1', -1000, 'EUR')]));
      final ops = {
        for (final (_, op) in repo.pendingOps())
          if (op.entity == 'tx') op.id: op.fields
      };
      expect(ops['j1']!['digits'], 0);
      expect(ops['e1']!.containsKey('digits'), isFalse);
      expect(repo.transaction('j1')!.amount, -1000);
      expect(repo.db.select("SELECT amount, digits FROM tx WHERE id = 'j1'").first['digits'], 0);
    }, timeout: _t);

    test('re-importing a row an older build stored in cents is a duplicate, not a collision', () {
      legacyRow('again', -100000, 'JPY');
      final s = repo.importBatch(ImportBatch(source: 'revolut', transactions: [_row('again', -1000, 'JPY', desc: 'Old shop')]));
      expect((s.added, s.duplicates, s.collisions), (0, 1, 0));
    }, timeout: _t);

    test('a hand-added yen expense is stored in yen with its digits', () {
      final id = repo.addTransaction(date: '2026-10-03', amount: 1500, category: 'Shopping', currency: 'JPY');
      final r = repo.db.select('SELECT amount, digits FROM tx WHERE id = ?', [id]).first;
      expect((r['amount'], r['digits']), (-1500, 0));
      expect(repo.transaction(id)!.amount, -1500);
    }, timeout: _t);
  });

  group('typed amounts and the CSV export', () {
    test('parseMoneyCents with digits', () {
      expect(parseMoneyCents('12,50'), 1250);
      expect(parseMoneyCents('1000', digits: 0), 1000);
      expect(parseMoneyCents('1,000', digits: 0), 1000, reason: 'a comma then three digits groups thousands');
      expect(parseMoneyCents('1.000', digits: 0), 1, reason: 'a dot is the decimal point, as for cents');
      expect(parseMoneyCents('10.5', digits: 0), isNull, reason: 'yen have no fraction: refused, never rounded');
      expect(parseMoneyCents('1,234', digits: 3), 1234, reason: 'three digits after a comma: the dinar decimal');
      expect(parseMoneyCents('2', digits: 3), 2000);
      expect(parseMoneyCents('0.01', digits: 8), 1000000);
      expect(parseMoneyCents('0.00000001', digits: 8), 1);
      expect(parseMoneyCents('0.000000001', digits: 8), isNull);
    }, timeout: _t);

    test('centsToDecimal with digits', () {
      expect(centsToDecimal(-1234), '-12.34');
      expect(centsToDecimal(-1000, digits: 0), '-1000');
      expect(centsToDecimal(1234, digits: 3), '1.234');
      expect(centsToDecimal(1000000, digits: 8), '0.01000000');
      expect(centsToDecimal(0, digits: 0), '0');
    }, timeout: _t);

    test('the transactions CSV writes each row with its currency digits', () {
      const rows = [
        CategorizedTx(Tx(id: 'a', source: 'revolut', date: '2026-10-01', amount: -1000, currency: 'JPY', description: 'A'), 'Shopping',
            BudgetKind.flex),
        CategorizedTx(Tx(id: 'b', source: 'revolut', date: '2026-10-02', amount: -1234, description: 'B'), 'Shopping', BudgetKind.flex),
      ];
      final lines = transactionsCsv(rows).trim().split('\n');
      expect(lines[1], startsWith('2026-10-01,-1000,'));
      expect(lines[2], startsWith('2026-10-02,-12.34,'));
    }, timeout: _t);
  });

  group('FX with digits', () {
    test('convertMinor across digits, both directions, and a crypto rate', () {
      expect(convertMinor(1000, 6500, fromDigits: 0, toDigits: 2), 650);
      expect(convertMinor(-650, 153846154, fromDigits: 2, toDigits: 0), -1000, reason: 'EUR cents to yen');
      expect(convertMinor(100000000, 50000000000, fromDigits: 8, toDigits: 2), 5000000, reason: '1 BTC at 50,000 EUR');
      expect(convertMinor(1, 50000000000, fromDigits: 8, toDigits: 2), 0);
      expect(convertMinor(2, 1000000, fromDigits: 3, toDigits: 2), 0, reason: '2 fils = 0.2 cents');
      expect(convertMinor(5, 1000000, fromDigits: 3, toDigits: 2), 1, reason: 'half a cent rounds away from zero');
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

    test('a bill reminder day and a yen row with its digits reach the other device', () async {
      final a = device('a'), b = device('b');
      final (id, _) = a.repo.importBill(const NormalizedBill(
          source: BillSource.hub3,
          externalId: 'hub3:synthetic-2',
          date: '2026-10-01',
          dueDate: '2026-10-20',
          total: 4599,
          payee: 'Synthetic'));
      a.repo.updateBill(id, returnReminderDays: 7);
      a.repo.importBatch(ImportBatch(source: 'revolut', transactions: [_row('yen', -1000, 'JPY')]));
      await syncAll([a, b]);
      expect(b.repo.bill(id)!.returnReminderDays, 7);
      expect(b.repo.transaction('yen')!.amount, -1000);
      b.repo.updateBill(id, clearReturnReminderDays: true);
      await syncAll([a, b]);
      expect(a.repo.bill(id)!.returnReminderDays, isNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
