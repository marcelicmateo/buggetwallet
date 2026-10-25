// Stage N2 (spec §2, §6): accountBalances / balanceTotals. Pure, plus one repo flow for matched cash entries.
// Expected values are worked out by hand from the spec. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/n2.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => n2Now));
  tearDown(() => repo.close());

  Future<String> add(String name, String? source, {String currency = 'EUR', int opening = 100000, String date = '2026-09-30'}) =>
      repo.addAccount(name: name, source: source, currency: currency, opening: opening, openingDate: date);

  AccountBalance of(List<AccountBalance> b, String id) => b.firstWhere((x) => x.account.id == id);

  test('no accounts, no rows', () {
    expect(accountBalances(const [], const []), isEmpty);
    expect(balanceTotals(const []), isEmpty);
  }, timeout: _t);

  test('opening only: the balance is the opening, no rows counted, no last date', () async {
    final id = await add('Bank', 'pbz', opening: 123456);
    final b = of(accountBalances(repo.accounts(), const []), id);
    expect((b.balance, b.rowsCounted, b.lastRowDate), (123456, 0, null));
  }, timeout: _t);

  test('rows on the opening date are excluded, the next day is included; earlier rows are excluded', () async {
    final id = await add('Bank', 'pbz', opening: 100000, date: '2026-09-30');
    final rows = [n2Tx('2026-09-29', -1111), n2Tx('2026-09-30', -2000), n2Tx('2026-10-01', -300), n2Tx('2026-10-04', 5000)];
    final b = of(accountBalances(repo.accounts(), rows), id);
    expect(b.balance, 100000 - 300 + 5000);
    expect((b.rowsCounted, b.lastRowDate), (2, '2026-10-04'));
  }, timeout: _t);

  test('a deleted row is excluded; other sources, manual rows and hand rows do not count for a bank account', () async {
    final id = await add('Bank', 'pbz', opening: 0, date: '2026-09-01');
    final rows = [
      n2Tx('2026-09-10', -500, deleted: true),
      n2Tx('2026-09-10', -700, source: 'revolut'),
      n2Tx('2026-09-10', -900, manual: true),
      n2Tx('2026-09-10', -100),
    ];
    final b = of(accountBalances(repo.accounts(), rows), id);
    expect((b.balance, b.rowsCounted), (-100, 1));
  }, timeout: _t);

  test('every kind counts on a bank account: spending, income, fee, ATM, own transfer, exchange', () async {
    final id = await add('Bank', 'pbz', opening: 0, date: '2026-09-01');
    final rows = [
      n2Tx('2026-09-02', -1000, kindHint: TxKind.card),
      n2Tx('2026-09-03', 150000, kindHint: TxKind.salary),
      n2Tx('2026-09-04', -33, kindHint: TxKind.fee),
      n2Tx('2026-09-05', -20000, kindHint: TxKind.atm),
      n2Tx('2026-09-06', -5000, kindHint: TxKind.ownTransfer),
      n2Tx('2026-09-07', -777, kindHint: TxKind.exchange),
    ];
    expect(of(accountBalances(repo.accounts(), rows), id).balance, -1000 + 150000 - 33 - 20000 - 5000 - 777);
  }, timeout: _t);

  test('a foreign-currency row is excluded from the home account and counted in its own currency account', () async {
    final eur = await add('Revolut EUR', 'revolut', opening: 5000);
    final usd = await add('Revolut USD', 'revolut', currency: 'USD', opening: 2000);
    final rows = [
      n2Tx('2026-10-01', -1500, source: 'revolut'),
      n2Tx('2026-10-02', -400, source: 'revolut', currency: 'USD'),
      n2Tx('2026-10-03', 900, source: 'revolut', currency: 'GBP'),
    ];
    final b = accountBalances(repo.accounts(), rows);
    expect(of(b, eur).balance, 3500);
    expect(of(b, usd).balance, 1600);
    expect(balanceTotals(b), {'EUR': 3500, 'USD': 1600});
  }, timeout: _t);

  test('an own transfer between two accounts leaves the total unchanged', () async {
    final pbz = await add('PBZ', 'pbz', opening: 50000, date: '2026-09-30');
    final rev = await add('Revolut', 'revolut', opening: 1000, date: '2026-09-30');
    final before = balanceTotals(accountBalances(repo.accounts(), const []));
    final rows = [
      n2Tx('2026-10-02', -10000, kindHint: TxKind.ownTransfer),
      n2Tx('2026-10-02', 10000, source: 'revolut', kindHint: TxKind.ownTransfer),
    ];
    final b = accountBalances(repo.accounts(), rows);
    expect((of(b, pbz).balance, of(b, rev).balance), (40000, 11000));
    expect(balanceTotals(b), before);
  }, timeout: _t);

  group('cash', () {
    test('manual rows count; bank rows and ATM rows do not; manual rows on the opening date do not', () async {
      final cash = await add('Cash', null, opening: 20000, date: '2026-10-01');
      final rows = [
        n2Tx('2026-10-01', -999, source: 'manual', manual: true),
        n2Tx('2026-10-02', -1500, source: 'manual', manual: true),
        n2Tx('2026-10-03', 400, source: 'manual', manual: true),
        n2Tx('2026-10-04', -5000), // bank card row
        n2Tx('2026-10-05', -20000, kindHint: TxKind.atm), // withdrawal: spent, not added to cash
      ];
      final b = of(accountBalances(repo.accounts(), rows), cash);
      expect(b.balance, 20000 - 1500 + 400);
      expect((b.rowsCounted, b.lastRowDate), (2, '2026-10-03'));
    }, timeout: _t);

    test('manual rows matched to a bank row, or pending against one, are not counted; deleted ones neither', () async {
      final cash = await add('Cash', null, opening: 10000, date: '2026-09-01');
      final rows = [
        n2Tx('2026-10-02', -100, source: 'manual', manual: true),
        n2Tx('2026-10-02', -200, source: 'manual', manual: true, matchedTo: 'bank-row'),
        n2Tx('2026-10-02', -400, source: 'manual', manual: true, matchPending: true),
        n2Tx('2026-10-02', -800, source: 'manual', manual: true, deleted: true),
      ];
      expect(of(accountBalances(repo.accounts(), rows), cash).balance, 9900);
    }, timeout: _t);

    test('a foreign-currency manual row is not in the home cash account', () async {
      final cash = await add('Cash', null, opening: 1000, date: '2026-09-01');
      final usd = await add('Cash USD', null, currency: 'USD', opening: 0, date: '2026-09-01');
      final rows = [n2Tx('2026-10-02', -250, source: 'manual', manual: true, currency: 'USD')];
      final b = accountBalances(repo.accounts(), rows);
      expect((of(b, cash).balance, of(b, usd).balance), (1000, -250));
    }, timeout: _t);

    test('through the repo: a hand entry replaced by its bank row counts once, in the bank account', () async {
      final bank = await add('Bank', 'pbz', opening: 100000, date: '2026-09-30');
      final cash = await add('Cash', null, opening: 5000, date: '2026-09-30');
      final loose = repo.addTransaction(date: '2026-10-05', amount: 1200, category: 'Groceries');
      final matched = repo.addTransaction(date: '2026-10-05', amount: 2500, category: 'Groceries');
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-10-06', -2500, 'POS plaćanje', 'PBZ POS SYNTHETIC SHOP ZAGREB')]));
      expect(repo.transaction(matched)!.matchedTo, isNotNull, reason: 'setup: the import matched the hand entry');
      expect(repo.transaction(loose)!.matchedTo, isNull);
      final b = accountBalances(repo.accounts(), repo.transactions(includeHidden: true));
      expect(of(b, cash).balance, 5000 - 1200, reason: 'the matched entry is already in the bank row');
      expect(of(b, bank).balance, 100000 - 2500);
    }, timeout: _t);
  });

  test('a deleted account is skipped', () async {
    final a = await add('Gone', 'pbz');
    final keep = await add('Kept', 'revolut');
    await repo.deleteAccount(a);
    final b = accountBalances(repo.accounts(includeDeleted: true), const []);
    expect(b.map((x) => x.account.id), [keep]);
  }, timeout: _t);

  test('after correctBalance the balance equals the corrected value; later rows add on top, earlier ones are ignored', () async {
    final id = await add('Bank', 'pbz', opening: 100000, date: '2026-09-01');
    final rows = [n2Tx('2026-09-10', -4000), n2Tx('2026-10-05', -700), n2Tx('2026-10-08', 250)];
    expect(of(accountBalances(repo.accounts(), rows), id).balance, 100000 - 4000 - 700 + 250);
    await repo.correctBalance(id, balance: 77777, date: '2026-10-08');
    final b = of(accountBalances(repo.accounts(), rows), id);
    expect((b.balance, b.rowsCounted, b.lastRowDate), (77777, 0, null));
    await repo.correctBalance(id, balance: 88888, date: '2026-10-05');
    expect(of(accountBalances(repo.accounts(), rows), id).balance, 88888 + 250);
  }, timeout: _t);

  test('balanceTotals sums per currency, never mixed, keys sorted', () async {
    await add('Z', 'revolut', currency: 'USD', opening: 300);
    await add('A', 'pbz', opening: 1000);
    await add('B', 'revolut', opening: -250);
    await add('C', null, opening: 50);
    final totals = balanceTotals(accountBalances(repo.accounts(), const []));
    expect(totals, {'EUR': 800, 'USD': 300});
    expect(totals.keys.toList(), ['EUR', 'USD']);
  }, timeout: _t);

  test('two live accounts with the same (source, currency): only the smallest id counts, the other is a duplicate', () {
    Account acc(String id, int opening, {String? source = 'pbz', String currency = 'EUR'}) =>
        Account(id: id, name: 'Dup $id', source: source, currency: currency, opening: opening, openingDate: '2026-09-30', deleted: false);
    final rows = [n2Tx('2026-10-02', -1000)];
    final b = accountBalances([acc('a2', 500), acc('a1', 700), acc('a3', 90, source: 'revolut')], rows);
    AccountBalance get(String id) => b.firstWhere((x) => x.account.id == id);
    expect((get('a1').balance, get('a1').rowsCounted, get('a1').duplicateOf), (700 - 1000, 1, null));
    final d = get('a2');
    expect((d.balance, d.rowsCounted, d.lastRowDate, d.duplicateOf), (500, 0, null, 'a1'));
    expect(get('a3').duplicateOf, isNull);
    expect(balanceTotals(b), {'EUR': 700 - 1000 + 90});
    final c = accountBalances([acc('c2', 10, source: null), acc('c1', 20, source: null)], const []);
    expect(c.firstWhere((x) => x.account.id == 'c2').duplicateOf, 'c1');
    expect(balanceTotals(c), {'EUR': 20});
  }, timeout: _t);
}
