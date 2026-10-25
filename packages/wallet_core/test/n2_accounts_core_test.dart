// Stage N2 (core builder): accounts (schema 9), balances, sync and backup of accounts. All data is SYNTHETIC.
library;

import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 12:00 UTC: the same local date in any time zone within ±12 h.
const _noon = 1791633600000;

Tx _tx(String id, String date, int cents,
        {String source = 'pbz',
        String currency = 'EUR',
        bool manual = false,
        bool deleted = false,
        String? matchedTo,
        bool pending = false}) =>
    Tx(
        id: id,
        source: source,
        date: date,
        amount: cents,
        currency: currency,
        manual: manual,
        deleted: deleted,
        matchedTo: matchedTo,
        matchPending: pending);

Account _acc(String id, {String? source = 'pbz', String currency = 'EUR', int opening = 0, String openingDate = '2026-09-30'}) =>
    Account(id: id, name: 'Synthetic $id', source: source, currency: currency, opening: opening, openingDate: openingDate);

void main() {
  group('accountBalances', () {
    test('opening only: no rows, balance = opening, no last row date', () {
      final b = accountBalances([_acc('a1', opening: 12345)], const []).single;
      expect((b.balance, b.rowsCounted, b.lastRowDate, b.duplicateOf), (12345, 0, null, null));
    });

    test('rows on the opening date are left out, the next day counts; deleted rows never', () {
      final b = accountBalances([
        _acc('a1', opening: 10000)
      ], [
        _tx('t1', '2026-09-30', -500),
        _tx('t2', '2026-10-01', -700),
        _tx('t3', '2026-10-03', 2000),
        _tx('t4', '2026-10-04', -900, deleted: true),
      ]).single;
      expect((b.balance, b.rowsCounted, b.lastRowDate), (10000 - 700 + 2000, 2, '2026-10-03'));
    });

    test('a foreign-currency row counts only in its own currency account; totals are per currency', () {
      final bs = accountBalances([
        _acc('a1', source: 'revolut', opening: 1000),
        _acc('a2', source: 'revolut', currency: 'USD', opening: 50)
      ], [
        _tx('t1', '2026-10-02', -100, source: 'revolut'),
        _tx('t2', '2026-10-02', -20, source: 'revolut', currency: 'USD'),
      ]);
      expect(bs.map((b) => b.balance), [900, 30]);
      expect(balanceTotals(bs), {'EUR': 900, 'USD': 30});
      expect(balanceTotals(bs).keys, ['EUR', 'USD']);
    });

    test('an own transfer between two bank accounts leaves the total unchanged', () {
      final accounts = [_acc('a1', opening: 50000), _acc('a2', source: 'revolut', opening: 1000)];
      final before = balanceTotals(accountBalances(accounts, const []));
      final after = balanceTotals(accountBalances(accounts, [
        _tx('t1', '2026-10-05', -20000),
        _tx('t2', '2026-10-05', 20000, source: 'revolut'),
      ]));
      expect(after, before);
    });

    test('cash: hand-added rows count; matched and pending ones do not; bank rows (ATM) never', () {
      final b = accountBalances([
        _acc('c', source: null, opening: 3000)
      ], [
        _tx('m1', '2026-10-02', -400, source: 'manual', manual: true),
        _tx('m2', '2026-10-02', -600, source: 'manual', manual: true, matchedTo: 'bank1'),
        _tx('m3', '2026-10-02', -800, source: 'manual', manual: true, matchedTo: 'bank2', pending: true),
        _tx('atm', '2026-10-03', -20000),
      ]).single;
      expect((b.balance, b.rowsCounted), (2600, 1));
    });

    test('bank account: hand-added rows never count, other sources never count', () {
      final b = accountBalances([
        _acc('a1')
      ], [
        _tx('m1', '2026-10-02', -400, source: 'pbz', manual: true),
        _tx('r1', '2026-10-02', -100, source: 'revolut'),
      ]).single;
      expect(b.rowsCounted, 0);
    });

    test('deleted accounts are skipped; a duplicate (source, currency) counts once (smallest id)', () {
      final bs = accountBalances([
        _acc('b2', source: null, opening: 700),
        _acc('b1', source: null, opening: 100),
        const Account(id: 'b0', name: 'gone', currency: 'EUR', opening: 5, openingDate: '2026-09-30', deleted: true),
      ], [
        _tx('m1', '2026-10-02', -50, source: 'manual', manual: true),
      ]);
      expect(bs.map((b) => b.account.id), ['b2', 'b1']);
      expect((bs[0].balance, bs[0].rowsCounted, bs[0].lastRowDate, bs[0].duplicateOf), (700, 0, null, 'b1'));
      expect((bs[1].balance, bs[1].rowsCounted, bs[1].duplicateOf), (50, 1, null));
      expect(balanceTotals(bs), {'EUR': 50});
    });
  });

  group('repo accounts', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => _noon));
    tearDown(() => repo.close());

    test('add, list by name, update, correct, delete and undelete', () async {
      final bank = await repo.addAccount(name: ' Bank 1 ', source: 'pbz', currency: 'EUR', opening: -2500, openingDate: '2026-10-01');
      final cash = await repo.addAccount(name: 'Cash', currency: 'EUR', opening: 4000, openingDate: '2026-10-10');
      expect(bank, startsWith('a'));
      expect(repo.accounts().map((a) => a.name), ['Bank 1', 'Cash']);
      expect(repo.accounts().first.isCash, isFalse);
      await repo.updateAccount(bank, name: 'Bank one', opening: 100);
      expect(repo.accounts().first.opening, 100);
      expect(repo.accounts().first.openingDate, '2026-10-01');
      await repo.correctBalance(cash, balance: 1500, date: '2026-10-09');
      final c = repo.accounts().firstWhere((a) => a.id == cash);
      expect((c.opening, c.openingDate), (1500, '2026-10-09'));
      final rows = [_tx('m1', '2026-10-10', -300, source: 'manual', manual: true)];
      expect(accountBalances([c], rows).single.balance, 1200);
      await repo.deleteAccount(cash);
      expect(repo.accounts().map((a) => a.id), [bank]);
      expect(repo.accounts(includeDeleted: true), hasLength(2));
      await repo.undeleteAccount(cash);
      expect(repo.accounts(), hasLength(2));
      expect(repo.isEmpty, isFalse);
    }, timeout: _t);

    test('unknown ids are refused', () async {
      for (final f in [
        () => repo.updateAccount('nope', name: 'x'),
        () => repo.correctBalance('nope', balance: 1, date: '2026-10-01'),
        () => repo.deleteAccount('nope'),
        () => repo.undeleteAccount('nope'),
      ]) {
        await expectLater(f(), throwsA(isA<ArgumentError>()));
      }
    }, timeout: _t);

    test('validation boundaries: name, amount, date, currency, source', () async {
      Future<String> add({String name = 'Cash', String? source, String currency = 'EUR', int opening = 0, String date = '2026-10-01'}) =>
          repo.addAccount(name: name, source: source, currency: currency, opening: opening, openingDate: date);
      final bad = throwsA(isA<ArgumentError>());
      await expectLater(add(name: ''), bad);
      await expectLater(add(name: '   '), bad);
      await expectLater(add(name: 'x' * 61), bad);
      await expectLater(add(opening: WalletSettings.maxAmount + 1), bad);
      await expectLater(add(opening: -WalletSettings.maxAmount - 1), bad);
      await expectLater(add(date: '2026-10-11'), bad, reason: 'tomorrow');
      await expectLater(add(date: '2026-02-30'), bad);
      await expectLater(add(date: '10/01/2026'), bad);
      await expectLater(add(currency: 'eur'), bad);
      await expectLater(add(currency: 'EURO'), bad);
      await expectLater(add(source: 'manual'), bad);
      expect(repo.accounts(includeDeleted: true), isEmpty);
      await add(name: 'x');
      await add(name: 'y' * 60, source: 'pbz', opening: WalletSettings.maxAmount, date: '2026-10-10');
      await add(name: 'z', source: 'revolut', opening: -WalletSettings.maxAmount);
      expect(repo.accounts(), hasLength(3));
      final id = repo.accounts().first.id;
      await expectLater(repo.updateAccount(id, name: ''), bad);
      await expectLater(repo.correctBalance(id, balance: WalletSettings.maxAmount + 1, date: '2026-10-01'), bad);
      await expectLater(repo.correctBalance(id, balance: 0, date: '2026-10-11'), bad);
    }, timeout: _t);

    test('a second live account with the same (source, currency) is refused, cash included; allowed after a delete', () async {
      final cash = await repo.addAccount(name: 'Cash', currency: 'EUR', opening: 0, openingDate: '2026-10-01');
      await expectLater(
          repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 0, openingDate: '2026-10-01'), throwsA(isA<ArgumentError>()));
      await repo.addAccount(name: 'Cash USD', currency: 'USD', opening: 0, openingDate: '2026-10-01');
      await repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-10-01');
      await expectLater(repo.addAccount(name: 'Bank 2', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-10-01'),
          throwsA(isA<ArgumentError>()));
      await repo.deleteAccount(cash);
      final again = await repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 0, openingDate: '2026-10-01');
      await expectLater(repo.undeleteAccount(cash), throwsA(isA<ArgumentError>()), reason: 'a live account holds the key');
      await repo.deleteAccount(again);
      await repo.undeleteAccount(cash);
      expect(repo.accounts().where((a) => a.isCash && a.currency == 'EUR').single.id, cash);
    }, timeout: _t);

    test('writes are synced ops; logs carry no names or amounts', () async {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(() {
        sub.cancel();
        Logger.root.level = was;
      });
      final before = repo.pendingOps().length;
      final id = await repo.addAccount(name: 'Synthetic Secret', currency: 'EUR', opening: 98765, openingDate: '2026-10-01');
      await repo.correctBalance(id, balance: 43210, date: '2026-10-02');
      expect(repo.pendingOps().length, greaterThan(before));
      expect(repo.pendingOps().map((o) => o.$2.entity).toSet(), contains('account'));
      expect(lines.where((l) => l.contains('account.')), hasLength(2));
      final text = lines.join('\n');
      expect(text, isNot(contains('Synthetic Secret')));
      expect(text, isNot(contains('98765')));
      expect(text, isNot(contains('43210')));
    }, timeout: _t);
  });

  group('two devices and backup', () {
    late VaultKey key;
    late Net net;
    var clock = _noon;
    setUp(() {
      key = VaultKey.generate();
      net = Net();
      clock = _noon;
    });

    Future<void> settle(List<Device> ds) async {
      for (var i = 0; i < 3; i++) {
        for (final d in ds) {
          clock += 1000;
          d.deliver(net, Random(1));
          await d.run();
        }
      }
    }

    test('an account and a correction made on A reach B', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final id = await a.repo.addAccount(name: 'Bank 1', source: 'pbz', currency: 'EUR', opening: 1000, openingDate: '2026-10-01');
      await settle([a, b]);
      expect(b.repo.accounts().single.id, id);
      clock += 1000;
      await b.repo.correctBalance(id, balance: 2500, date: '2026-10-09');
      await settle([a, b]);
      for (final d in [a, b]) {
        final x = d.repo.accounts().single;
        expect((x.opening, x.openingDate), (2500, '2026-10-09'));
      }
      expect(dump(a.repo)['accounts'], dump(b.repo)['accounts']);
    }, timeout: _t);

    test('the same cash account added on both devices offline: both converge and the total counts it once', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      await a.repo.addAccount(name: 'Cash', currency: 'EUR', opening: 1000, openingDate: '2026-10-01');
      await b.repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 3000, openingDate: '2026-10-01');
      a.repo.addTransaction(date: '2026-10-05', amount: 200, category: 'Groceries');
      await settle([a, b]);
      expect(a.repo.accounts(), hasLength(2));
      expect(dump(a.repo)['accounts'], dump(b.repo)['accounts']);
      for (final d in [a, b]) {
        final bs = accountBalances(d.repo.accounts(), d.repo.transactions());
        final counted = bs.where((x) => x.duplicateOf == null).single;
        expect(bs.where((x) => x.duplicateOf == counted.account.id), hasLength(1));
        expect(counted.rowsCounted, 1);
        expect(balanceTotals(bs), {'EUR': counted.account.opening - 200});
      }
    }, timeout: _t);

    test('a backup round trip keeps accounts (deleted ones included)', () async {
      final r = WalletRepo.inMemory(now: () => clock);
      addTearDown(r.close);
      final id = await r.addAccount(name: 'Bank 1', source: 'revolut', currency: 'EUR', opening: -500, openingDate: '2026-10-01');
      final gone = await r.addAccount(name: 'Cash', currency: 'EUR', opening: 0, openingDate: '2026-10-01');
      await r.deleteAccount(gone);
      expect(r.isEmpty, isFalse);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, await backupBytes(r, key), key);
      expect(dump(fresh)['accounts'], dump(r)['accounts']);
      expect(fresh.accounts().single.id, id);
      expect(fresh.accounts(includeDeleted: true), hasLength(2));
    }, timeout: _t);
  });
}
