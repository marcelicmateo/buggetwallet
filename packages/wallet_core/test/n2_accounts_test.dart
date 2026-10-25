// Stage N2 (spec §1, §5, §6): accounts as a synced entity. Validation boundaries, the one-live-account-per-(source,
// currency) rule, correctBalance, delete/undelete, ordering. Written from docs/context/N2_SPEC.md. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart' show entitySchema;
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';

const _t = Timeout(Duration(seconds: 30));

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => n2Now));
  tearDown(() => repo.close());

  Future<String> add(
          {String name = 'Bank 1', String? source = 'pbz', String currency = 'EUR', int opening = 10000, String date = '2026-09-01'}) =>
      repo.addAccount(name: name, source: source, currency: currency, opening: opening, openingDate: date);

  test('schema 9 with an accounts entity', () {
    expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(9));
    expect(entitySchema.containsKey('account'), isTrue);
    expect(repo.accounts(), isEmpty);
    expect(repo.db.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'accounts'"), hasLength(1));
  }, timeout: _t);

  group('add and read', () {
    test('a bank account and a cash account are stored as given', () async {
      final b = await add(name: 'Bank 1', source: 'pbz', opening: 123456, date: '2026-09-30');
      final c = await add(name: 'Cash', source: null, opening: -500, date: '2026-10-10');
      final list = repo.accounts();
      expect(list, hasLength(2));
      final bank = list.firstWhere((a) => a.id == b);
      expect((bank.name, bank.source, bank.currency, bank.opening, bank.openingDate, bank.deleted, bank.isCash),
          ('Bank 1', 'pbz', 'EUR', 123456, '2026-09-30', false, false));
      final cash = list.firstWhere((a) => a.id == c);
      expect((cash.source, cash.isCash, cash.opening), (null, true, -500));
      expect(b, isNot(c));
    }, timeout: _t);

    test('the name is trimmed', () async {
      await add(name: '  Savings  ');
      expect(repo.accounts().single.name, 'Savings');
    }, timeout: _t);

    test('ordered by name, then id', () async {
      await add(name: 'Zeta', source: 'revolut');
      await add(name: 'Alpha', source: null);
      await add(name: 'Mid', source: 'pbz');
      expect(repo.accounts().map((a) => a.name), ['Alpha', 'Mid', 'Zeta']);
      await add(name: 'Mid', source: 'pbz', currency: 'USD');
      final mids = repo.accounts().where((a) => a.name == 'Mid').map((a) => a.id).toList();
      expect(mids, hasLength(2));
      expect(mids, [...mids]..sort(), reason: 'same name: the id decides');
    }, timeout: _t);

    test('each write is a pending sync op of the account entity', () async {
      final before = repo.pendingOps().length;
      final id = await add();
      final ops = repo.pendingOps().skip(before).map((e) => e.$2).where((o) => o.entity == 'account').toList();
      expect(ops, isNotEmpty);
      expect(ops.every((o) => o.id == id), isTrue);
      expect(ops.any((o) => o.fields['name'] == 'Bank 1'), isTrue);
    }, timeout: _t);
  });

  group('validation: name', () {
    test('0 characters (and only spaces) refused; 1 and 60 accepted; 61 refused', () async {
      await expectLater(add(name: ''), throwsArgumentError);
      await expectLater(add(name: '   '), throwsArgumentError);
      await add(name: 'x', source: 'pbz');
      await add(name: 'y' * 60, source: 'revolut');
      await expectLater(add(name: 'z' * 61, source: null), throwsArgumentError);
      expect(repo.accounts(), hasLength(2), reason: 'a refused add writes nothing');
    }, timeout: _t);

    test('60 characters plus padding is fine (trimmed first); the refusal has a readable message', () async {
      await add(name: '  ${'q' * 60}  ');
      await expectLater(add(name: '', source: null),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}'.trim().isNotEmpty, 'has a message', isTrue)));
    }, timeout: _t);
  });

  group('validation: amount', () {
    test('the cap is accepted, cap + 1 refused, both signs', () async {
      await add(opening: WalletSettings.maxAmount, source: 'pbz');
      await add(opening: -WalletSettings.maxAmount, source: 'revolut');
      await expectLater(add(opening: WalletSettings.maxAmount + 1, source: null), throwsArgumentError);
      await expectLater(add(opening: -WalletSettings.maxAmount - 1, source: null), throwsArgumentError);
      expect(repo.accounts(), hasLength(2));
    }, timeout: _t);

    test('zero opening is fine', () async {
      await add(opening: 0);
      expect(repo.accounts().single.opening, 0);
    }, timeout: _t);
  });

  group('validation: dates', () {
    test('today accepted; tomorrow refused', () async {
      await add(date: n2Today);
      await expectLater(add(date: '2026-10-11', source: 'revolut'), throwsArgumentError);
    }, timeout: _t);

    test('invalid or unparseable dates refused', () async {
      for (final bad in ['2026-02-30', '2026-13-01', '2026-00-10', '', 'yesterday', '2026-1-5', '10.10.2026']) {
        await expectLater(add(date: bad), throwsArgumentError, reason: bad);
      }
      expect(repo.accounts(), isEmpty);
    }, timeout: _t);

    test('a leap day is a real date, a non-leap 29 February is not', () async {
      await add(date: '2024-02-29');
      await expectLater(add(date: '2025-02-29', source: 'revolut'), throwsArgumentError);
    }, timeout: _t);
  });

  group('validation: currency and source', () {
    test('eur and EURO and short, empty or padded codes refused; EUR accepted', () async {
      for (final bad in ['eur', 'EURO', 'EU', '', 'E1R', ' EUR', 'EUR ']) {
        await expectLater(add(currency: bad), throwsArgumentError, reason: '"$bad"');
      }
      await add(currency: 'EUR');
      expect(repo.accounts(), hasLength(1));
    }, timeout: _t);

    test('an unknown source is refused; pbz, revolut and null are accepted', () async {
      for (final bad in ['PBZ', 'bank', 'manual', '', 'n26']) {
        await expectLater(add(source: bad), throwsArgumentError, reason: '"$bad"');
      }
      await add(source: 'pbz');
      await add(source: 'revolut');
      await add(source: null);
      expect(repo.accounts(), hasLength(3));
    }, timeout: _t);
  });

  group('one live account per (source, currency)', () {
    test('a second bank account of the same source and currency is refused', () async {
      await add(name: 'One');
      await expectLater(add(name: 'Two'), throwsArgumentError);
      expect(repo.accounts(), hasLength(1));
    }, timeout: _t);

    test('the same source in another currency, and another source in the same currency, are allowed', () async {
      await add(source: 'revolut', currency: 'EUR');
      await add(source: 'revolut', currency: 'USD');
      await add(source: 'pbz', currency: 'EUR');
      expect(repo.accounts(), hasLength(3));
    }, timeout: _t);

    test('a second cash account in the same currency is refused; another currency is allowed', () async {
      await add(name: 'Cash', source: null);
      await expectLater(add(name: 'Wallet', source: null), throwsArgumentError);
      await add(name: 'Cash USD', source: null, currency: 'USD');
      expect(repo.accounts(), hasLength(2));
    }, timeout: _t);

    test('allowed again after the first is deleted (cash and bank)', () async {
      final c = await add(name: 'Cash', source: null);
      final b = await add(name: 'Bank', source: 'pbz');
      await repo.deleteAccount(c);
      await repo.deleteAccount(b);
      await add(name: 'Cash 2', source: null);
      await add(name: 'Bank 2', source: 'pbz');
      expect(repo.accounts().map((a) => a.name), ['Bank 2', 'Cash 2']);
      expect(repo.accounts(includeDeleted: true), hasLength(4));
    }, timeout: _t);

    test('undeleting while a live account holds the slot is refused; it works once the slot is free', () async {
      final first = await add(name: 'First');
      await repo.deleteAccount(first);
      final second = await add(name: 'Second');
      await expectLater(repo.undeleteAccount(first), throwsArgumentError);
      expect(repo.accounts().single.id, second);
      await repo.deleteAccount(second);
      await repo.undeleteAccount(first);
      expect(repo.accounts().single.id, first);
    }, timeout: _t);

    test('a rename or correction of the live account never trips the duplicate rule', () async {
      final id = await add(name: 'One');
      await repo.updateAccount(id, name: 'Renamed');
      await repo.correctBalance(id, balance: 5, date: '2026-10-01');
      expect(repo.accounts().single.name, 'Renamed');
    }, timeout: _t);
  });

  group('updateAccount', () {
    test('changes only the named fields; source and currency stay', () async {
      final id = await add(name: 'Bank', opening: 1000, date: '2026-09-01');
      await repo.updateAccount(id, opening: 2500);
      var a = repo.accounts().single;
      expect((a.name, a.opening, a.openingDate, a.source, a.currency), ('Bank', 2500, '2026-09-01', 'pbz', 'EUR'));
      await repo.updateAccount(id, name: 'Main', openingDate: '2026-09-15');
      a = repo.accounts().single;
      expect((a.name, a.opening, a.openingDate), ('Main', 2500, '2026-09-15'));
    }, timeout: _t);

    test('unknown id: ArgumentError "No such account."', () async {
      await expectLater(
          repo.updateAccount('a-nope', name: 'x'), throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'No such account.')));
    }, timeout: _t);

    test('the same validation applies and a refused update changes nothing', () async {
      final id = await add(name: 'Bank', opening: 1000, date: '2026-09-01');
      await expectLater(repo.updateAccount(id, name: ''), throwsArgumentError);
      await expectLater(repo.updateAccount(id, name: 'n' * 61), throwsArgumentError);
      await expectLater(repo.updateAccount(id, opening: WalletSettings.maxAmount + 1), throwsArgumentError);
      await expectLater(repo.updateAccount(id, openingDate: '2026-10-11'), throwsArgumentError);
      await expectLater(repo.updateAccount(id, openingDate: '2026-02-30'), throwsArgumentError);
      var a = repo.accounts().single;
      expect((a.name, a.opening, a.openingDate), ('Bank', 1000, '2026-09-01'));
      await repo.updateAccount(id, name: 'n' * 60, opening: WalletSettings.maxAmount);
      a = repo.accounts().single;
      expect((a.name.length, a.opening), (60, WalletSettings.maxAmount));
    }, timeout: _t);
  });

  group('correctBalance', () {
    test('writes opening = balance and openingDate = date', () async {
      final id = await add(opening: 1000, date: '2026-09-01');
      await repo.correctBalance(id, balance: -4321, date: '2026-10-05');
      final a = repo.accounts().single;
      expect((a.opening, a.openingDate), (-4321, '2026-10-05'));
    }, timeout: _t);

    test('refuses an unknown id, a future date, a bad date and an amount over the cap', () async {
      final id = await add();
      await expectLater(repo.correctBalance('a-nope', balance: 1, date: '2026-10-01'), throwsArgumentError);
      await expectLater(repo.correctBalance(id, balance: 1, date: '2026-10-11'), throwsArgumentError);
      await expectLater(repo.correctBalance(id, balance: 1, date: 'x'), throwsArgumentError);
      await expectLater(repo.correctBalance(id, balance: WalletSettings.maxAmount + 1, date: '2026-10-01'), throwsArgumentError);
      await repo.correctBalance(id, balance: WalletSettings.maxAmount, date: n2Today);
      expect(repo.accounts().single.opening, WalletSettings.maxAmount);
    }, timeout: _t);
  });

  group('delete and undelete', () {
    test('deleteAccount hides the account; includeDeleted shows it flagged; undelete brings it back as it was', () async {
      final id = await add(name: 'Bank', opening: 7777, date: '2026-09-09');
      await repo.deleteAccount(id);
      expect(repo.accounts(), isEmpty);
      final hidden = repo.accounts(includeDeleted: true).single;
      expect((hidden.id, hidden.deleted), (id, true));
      await repo.undeleteAccount(id);
      final back = repo.accounts().single;
      expect((back.name, back.opening, back.openingDate, back.deleted), ('Bank', 7777, '2026-09-09', false));
    }, timeout: _t);

    test('deleting twice is harmless; the restore is a pending op with deleted 0', () async {
      final id = await add();
      await repo.deleteAccount(id);
      await repo.deleteAccount(id);
      final before = repo.pendingOps().length;
      await repo.undeleteAccount(id);
      final op = repo.pendingOps().last.$2;
      expect(repo.pendingOps().length, greaterThan(before));
      expect((op.entity, op.id, op.fields['deleted']), ('account', id, 0));
    }, timeout: _t);
  });
}
