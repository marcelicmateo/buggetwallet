// UX-ACC (docs/context/SCHEMA21_SPEC.md, folded into schema 20): payments know their account. `tx.account`,
// `accounts.match_key`, the counting rule (RowAccounts), uniqueness, import + re-import fill, setTxAccount, bank checks
// per export account, logs, backup and two devices. All data is SYNTHETIC (made-up IBAN-shaped strings and amounts).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));
const _now = 1791590400000; // 2026-10-10
final _key = VaultKey(List<int>.generate(32, (i) => i + 3));

// Synthetic export account names (IBAN-shaped, not real accounts).
const _ibanA = 'XX00 1111 2222 3333 4444 5', _ibanB = 'XX00 9999 8888 7777 6666 5';

NormalizedTransaction _row(String date, int cents, String desc, {String? account, int? balance, String source = 'pbz', int occ = 0}) =>
    NormalizedTransaction(
      id: transactionId(date, cents, desc, occ),
      source: source,
      date: date,
      amountMinor: cents,
      currency: 'EUR',
      bankType: 'Card',
      description: desc,
      account: account,
      balanceAfter: balance,
    );

Account _acc(String id, {String? source = 'pbz', String? matchKey, bool deleted = false, int opening = 0, String currency = 'EUR'}) =>
    Account(
        id: id,
        name: id,
        source: source,
        currency: currency,
        opening: opening,
        openingDate: '2026-09-30',
        deleted: deleted,
        matchKey: matchKey);

Tx _tx(String id, int amount, {String? account, String source = 'pbz', String date = '2026-10-02', bool manual = false}) =>
    Tx(id: id, source: source, date: date, amount: amount, account: account, manual: manual);

const _k1 = 'ak:0123456789abcdef', _k2 = 'ak:fedcba9876543210';

void main() {
  group('the counting rule (pure)', () {
    test('two accounts of one bank and currency split the rows by tx.account; balances and totals exact', () {
      final accounts = [_acc('a1', opening: 1000), _acc('a2', matchKey: _k1, opening: 50000)];
      final rows = [_tx('t1', -300), _tx('t2', -7001, account: 'a2'), _tx('t3', 250, account: 'a1'), _tx('t4', 12, account: 'a2')];
      final b = {for (final x in accountBalances(accounts, rows)) x.account.id: x};
      expect((b['a1']!.balance, b['a1']!.rowsCounted, b['a1']!.duplicateOf), (1000 - 300 + 250, 2, null));
      expect((b['a2']!.balance, b['a2']!.rowsCounted, b['a2']!.duplicateOf), (50000 - 7001 + 12, 2, null));
      expect(balanceTotals(b.values.toList()), {'EUR': 1000 - 300 + 250 + 50000 - 7001 + 12});
    });

    test('a missing, deleted or mismatched account sends the row to the main account', () {
      final accounts = [
        _acc('a1'),
        _acc('a2', matchKey: _k1),
        _acc('a3', matchKey: _k2, deleted: true),
        _acc('r1', source: 'revolut'),
        _acc('c1', source: null),
      ];
      final o = RowAccounts(accounts);
      expect(o.accountOf(_tx('x', -1, account: 'gone')), 'a1');
      expect(o.accountOf(_tx('x', -1, account: 'a3')), 'a1', reason: 'deleted account');
      expect(o.accountOf(_tx('x', -1, account: 'a2', source: 'revolut')), 'r1', reason: 'another source');
      expect(o.accountOf(_tx('x', -1, account: 'c1')), 'a1', reason: 'cash never owns a bank row');
      expect(o.accountOf(_tx('x', -1, account: 'a2')), 'a2');
      expect(o.accountOf(_tx('x', -1, manual: true, source: 'manual')), 'c1');
      expect(o.mainOf('pbz', 'EUR'), 'a1');
      expect(o.keyedOf('pbz', 'EUR', _k1), 'a2');
      expect(o.keyedOf('pbz', 'EUR', _k2), isNull);
    });

    test('deleting the keyed account moves its rows back to the main account', () {
      final rows = [_tx('t1', -300), _tx('t2', -700, account: 'a2')];
      final before = accountBalances([_acc('a1'), _acc('a2', matchKey: _k1)], rows);
      expect(before.map((b) => b.balance), [-300, -700]);
      final after = accountBalances([_acc('a1'), _acc('a2', matchKey: _k1, deleted: true)], rows);
      expect(after.single.balance, -1000);
    });

    test('when every live account has a key, the smallest id is the main account', () {
      final o = RowAccounts([_acc('b2', matchKey: _k2), _acc('b1', matchKey: _k1)]);
      expect(o.mainOf('pbz', 'EUR'), 'b1');
      expect(o.accountOf(_tx('x', -1)), 'b1');
    });

    test('duplicates are per (source, currency, key): same key -> the larger id is a duplicate, other keys are not', () {
      final b = accountBalances(
          [_acc('a1', matchKey: _k1), _acc('a2', matchKey: _k1), _acc('a3', matchKey: _k2), _acc('a4')], [_tx('t1', -5, account: 'a2')]);
      expect([for (final x in b) x.duplicateOf], [null, 'a1', null, null]);
      expect(b.first.balance, -5, reason: 'a row naming the duplicate counts for the account that counts its key');
    });

    test('an older build (ignores both columns) sees the keyed account as a duplicate and loses no row', () {
      final accounts = [_acc('a1', opening: 100), _acc('a2', matchKey: _k1, opening: 900)];
      final rows = [_tx('t1', -300), _tx('t2', -700, account: 'a2')];
      // What an older build reads: the same rows without the new columns.
      final old = accountBalances([
        for (final a in accounts) Account.fromRow({...a.row}..remove('match_key'))
      ], [
        for (final r in rows) Tx(id: r.id, source: r.source, date: r.date, amount: r.amount)
      ]);
      expect([for (final x in old) (x.balance, x.duplicateOf)], [(100 - 1000, null), (900, 'a1')]);
      final now = accountBalances(accounts, rows);
      expect(balanceTotals(now)['EUR'], 100 + 900 - 1000);
      expect(balanceTotals(old)['EUR'], 100 - 1000, reason: 'the duplicate shows its opening only there');
    });

    test('checkBankBalance with every account counts only the account\'s own rows; without, the old rule', () {
      final accounts = [_acc('a1'), _acc('a2', matchKey: _k1)];
      final rows = [_tx('t1', -300), _tx('t2', -700, account: 'a2')];
      expect(checkBankBalance(accounts[1], rows, date: '2026-10-05', bankCents: -700, accounts: accounts).matches, isTrue);
      expect(checkBankBalance(accounts[0], rows, date: '2026-10-05', bankCents: -300, accounts: accounts).matches, isTrue);
      expect(checkBankBalance(accounts[1], rows, date: '2026-10-05', bankCents: 0).appCents, -1000);
      expect(balanceTrusted(accounts[1], today: '2026-10-05', rows: rows, accounts: accounts), isTrue);
    });
  });

  group('accountMatchKey', () {
    test('normalizes case, spaces and dashes; ak: + 16 hex; another wallet key gives another key; blank refused', () async {
      final k = await accountMatchKey(_key, _ibanA);
      expect(isAccountMatchKey(k), isTrue);
      expect(await accountMatchKey(_key, _ibanA.toLowerCase().replaceAll(' ', '-')), k);
      expect(await accountMatchKey(_key, _ibanA.replaceAll(' ', '')), k);
      expect(await accountMatchKey(_key, _ibanB), isNot(k));
      expect(await accountMatchKey(VaultKey(List<int>.filled(32, 9)), _ibanA), isNot(k));
      expect(k, isNot(contains('1111')));
      await expectLater(accountMatchKey(_key, ' - '), throwsArgumentError);
    });

    test('withAccountKeys keys every named row once and keeps the batch counts', () async {
      final batch = ImportBatch(
          source: 'pbz',
          transactions: [
            _row('2026-10-01', -100, 'A', account: _ibanA),
            _row('2026-10-02', -200, 'B'),
            _row('2026-10-03', -300, 'C', account: _ibanB)
          ],
          skipped: 2,
          invalid: 1,
          invalidRows: const [7],
          problems: const ['Row 8: x']);
      final keyed = await withAccountKeys(_key, batch);
      expect(keyed.transactions.map((t) => t.accountKey), [await accountMatchKey(_key, _ibanA), null, await accountMatchKey(_key, _ibanB)]);
      expect((keyed.skipped, keyed.invalid), (2, 1));
      expect((keyed.invalidRows, keyed.problems), (batch.invalidRows, batch.problems));
      expect(keyed.transactions.first.toJson().containsKey('accountKey'), isFalse, reason: 'not part of the contract');
      final plain = ImportBatch(source: 'pbz', transactions: [_row('2026-10-02', -1, 'B')]);
      expect(identical(await withAccountKeys(_key, plain), plain), isTrue, reason: 'nothing to key');
    });
  });

  group('repo', () {
    late WalletRepo repo;
    late String k1, k2;
    setUp(() async {
      repo = WalletRepo.inMemory(now: () => _now);
      k1 = await accountMatchKey(_key, _ibanA);
      k2 = await accountMatchKey(_key, _ibanB);
    });
    tearDown(() => repo.close());

    Future<String> add(String name, {String? matchKey, String? source = 'pbz'}) =>
        repo.addAccount(name: name, source: source, currency: 'EUR', opening: 0, openingDate: '2026-09-30', matchKey: matchKey);

    test('uniqueness: one live account per (source, currency, key); bad keys and cash keys refused, nothing written', () async {
      await add('Main');
      await add('Savings', matchKey: k1);
      await add('Other', matchKey: k2);
      await expectLater(add('Again', matchKey: k1), throwsArgumentError);
      await expectLater(add('Main 2'), throwsArgumentError);
      await expectLater(add('Bad', matchKey: 'ak:XYZ'), throwsArgumentError);
      await expectLater(add('Cash', source: null, matchKey: 'ak:1111111111111111'), throwsArgumentError);
      expect(repo.accounts().length, 3);
      final main = repo.accounts().firstWhere((a) => a.name == 'Main');
      await expectLater(repo.updateAccount(main.id, matchKey: k1), throwsArgumentError);
      await repo.updateAccount(main.id, matchKey: 'ak:2222222222222222');
      expect(repo.accounts().firstWhere((a) => a.id == main.id).matchKey, 'ak:2222222222222222');
      await repo.updateAccount(main.id, clearMatchKey: true);
      expect(repo.accounts().firstWhere((a) => a.id == main.id).matchKey, isNull);
    });

    test('import: a matched key goes into the creation op; no match -> none, and the app is told which to ask', () async {
      final main = await add('Main');
      final sav = await add('Savings', matchKey: k2);
      final batch = await withAccountKeys(
          _key,
          ImportBatch(
              source: 'pbz',
              transactions: [_row('2026-10-01', -100, 'A', account: _ibanA), _row('2026-10-02', -200, 'B', account: _ibanB)]));
      final q = repo.unknownImportAccounts(batch);
      expect([for (final x in q) (x.source, x.currency, x.accountKey, x.exportAccount, x.rows)], [('pbz', 'EUR', k1, _ibanA, 1)]);
      expect(q.single.candidates.map((a) => a.id).toSet(), {main, sav});
      final s = repo.importBatch(batch);
      expect(s.accountsAssigned, 1);
      final byId = {for (final t in repo.transactions()) t.description: t};
      expect((byId['A']!.account, byId['B']!.account), (null, sav));
      final creation = repo.pendingOps().map((p) => p.$2).firstWhere((o) => o.entity == 'tx' && o.id == byId['B']!.id);
      expect(creation.fields['account'], sav);
      expect(creation.fields.containsKey('source'), isTrue, reason: 'one op: the row and its account');
      final b = {for (final x in accountBalances(repo.accounts(), repo.transactions())) x.account.id: x.balance};
      expect(b, {main: -100, sav: -200});
    });

    test('re-import fills a null account and never overwrites one', () async {
      final main = await add('Main');
      final file = await withAccountKeys(
          _key,
          ImportBatch(
              source: 'pbz',
              transactions: [_row('2026-10-01', -100, 'A', account: _ibanA), _row('2026-10-02', -200, 'B', account: _ibanA)]));
      repo.importBatch(file);
      expect(repo.transactions().map((t) => t.account), [null, null]);
      expect(repo.unknownImportAccounts(file).single.accountKey, k1);
      // The owner's answer: a new savings account for this export account.
      final sav = await add('Savings', matchKey: k1);
      expect(repo.unknownImportAccounts(file), isEmpty, reason: 'asked once');
      final a = repo.transactions().firstWhere((t) => t.description == 'A');
      repo.setTxAccount(a.id, main); // the owner put A on the main account by hand
      final s = repo.importBatch(file);
      expect((s.added, s.accountsAssigned), (0, 1));
      final got = {for (final t in repo.transactions()) t.description: t.account};
      expect(got, {'A': main, 'B': sav});
      final again = repo.importBatch(file);
      expect(again.accountsAssigned, 0, reason: 'nothing left to fill');
    });

    test('setTxAccount: same source and currency, bank rows only; null goes back to the rule; no change, no write', () async {
      final main = await add('Main');
      final sav = await add('Savings', matchKey: k1);
      final rev = await repo.addAccount(name: 'Rev', source: 'revolut', currency: 'EUR', opening: 0, openingDate: '2026-09-30');
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [_row('2026-10-01', -100, 'A')]));
      final m = repo.addTransaction(date: '2026-10-03', amount: 500, category: 'Groceries');
      final id = repo.transactions().firstWhere((t) => !t.manual).id;
      expect(() => repo.setTxAccount(id, rev), throwsArgumentError);
      expect(() => repo.setTxAccount(m, sav), throwsArgumentError);
      expect(() => repo.setTxAccount('nope', sav), throwsArgumentError);
      expect(() => repo.setTxAccount(id, 'nope'), throwsArgumentError);
      final ops = repo.pendingOps().length;
      repo.setTxAccount(id, null);
      expect(repo.pendingOps().length, ops, reason: 'no change');
      repo.setTxAccount(id, sav);
      expect(repo.pendingOps().length, ops + 1);
      expect(repo.pendingOps().last.$2.fields, {'account': sav});
      expect({for (final x in accountBalances(repo.accounts(), repo.transactions())) x.account.id: x.balance}[sav], -100);
      repo.setTxAccount(id, null);
      expect({for (final x in accountBalances(repo.accounts(), repo.transactions())) x.account.id: x.balance}[main], -100);
    });

    test('bank checks per export account: the keyed account is checked; a main account holding other rows is skipped', () async {
      final main = await add('Main');
      final sav = await add('Savings', matchKey: k1);
      // Main already holds a row of another (unkeyed) export account in the file's dates.
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [_row('2026-10-02', -50, 'Other', account: 'XX00 5555')]));
      final file = await withAccountKeys(
          _key,
          ImportBatch(source: 'pbz', transactions: [
            _row('2026-10-01', -100, 'A', account: _ibanA, balance: 900),
            _row('2026-10-03', -200, 'B', account: _ibanA, balance: 700),
            _row('2026-10-01', -10, 'C', account: _ibanB, balance: 90),
            _row('2026-10-04', -20, 'D', account: _ibanB, balance: 70),
          ]));
      final s = repo.importBatch(file);
      expect(s.bankChecks.keys, [sav], reason: 'main skipped: it also holds the other export account');
      expect((s.bankChecks[sav]!.appCents, s.bankChecks[sav]!.bankCents), (-300, 700));
      expect(repo.lastBankCheck(main), isNull);
    });

    test('logs carry neither the export account nor its key', () async {
      await add('Savings', matchKey: k1);
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      try {
        final file = await withAccountKeys(
            _key, ImportBatch(source: 'pbz', transactions: [_row('2026-10-01', -100, 'A', account: _ibanA, balance: 5)]));
        repo.unknownImportAccounts(file);
        repo.importBatch(file);
        repo.setTxAccount(repo.transactions().single.id, null);
      } finally {
        await sub.cancel();
        Logger.root.level = was;
      }
      final all = lines.join('\n');
      expect(lines, isNotEmpty);
      for (final secret in [k1, k1.substring(3), _ibanA, normalizeExportAccount(_ibanA), '1111']) {
        expect(all, isNot(contains(secret)));
      }
    });

    test('backup round trip keeps tx.account and accounts.match_key', () async {
      final sav = await add('Savings', matchKey: k1);
      repo.importBatch(
          await withAccountKeys(_key, ImportBatch(source: 'pbz', transactions: [_row('2026-10-01', -100, 'A', account: _ibanA)])));
      final fresh = WalletRepo.inMemory(now: () => _now);
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, await backupBytes(repo, _key), _key);
      expect((fresh.accounts().single.matchKey, fresh.transactions().single.account), (k1, sav));
    });
  });

  group('two devices', () {
    late Directory tmp;
    late Net net;
    final devices = <Device>[];
    var now = _now;

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), _key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 3; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
          d.upload(net);
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-uxacc-');
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('the same file imported on both gives the same tx.account (no conflict); a move on one reaches the other', () async {
      final a = device('a'), b = device('b');
      final k1 = await accountMatchKey(_key, _ibanA);
      await a.repo.addAccount(name: 'Main', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-09-30');
      final sav =
          await a.repo.addAccount(name: 'Savings', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-09-30', matchKey: k1);
      await syncAll([a, b]);
      final file =
          ImportBatch(source: 'pbz', transactions: [_row('2026-10-01', -100, 'A', account: _ibanA), _row('2026-10-02', -200, 'B')]);
      a.repo.importBatch(await withAccountKeys(_key, file));
      now += 1000;
      b.repo.importBatch(await withAccountKeys(_key, file));
      await syncAll([a, b]);
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      expect(a.repo.transactions().firstWhere((t) => t.description == 'A').account, sav);
      expect(a.repo.syncConflicts(), isEmpty);
      expect(b.repo.syncConflicts(), isEmpty);
      final rowB = b.repo.transactions().firstWhere((t) => t.description == 'B');
      now += 1000;
      b.repo.setTxAccount(rowB.id, sav);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect({for (final x in accountBalances(d.repo.accounts(), d.repo.transactions())) x.account.name: x.balance},
            {'Main': 0, 'Savings': -300});
      }
      expect(jsonEncode(dump(a.repo, clocks: false)), jsonEncode(dump(b.repo, clocks: false)));
    }, timeout: _t);
  });
}
