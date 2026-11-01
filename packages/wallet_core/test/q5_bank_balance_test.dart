// Q5 bank balance checks (docs/context/STAGE_Q_PLAN.md): checkBankBalance counts like accountBalances up to a date,
// balanceTrusted's 35 days, device-local checks, and the automatic check after an import. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

final _pbz = Account(id: 'a1', name: 'Synthetic bank', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-01-01');

Tx _t(String id, String date, int cents, {String source = 'pbz', String currency = 'EUR', bool deleted = false, bool manual = false}) =>
    Tx(id: id, source: source, date: date, amount: cents, currency: currency, deleted: deleted, manual: manual);

NormalizedTransaction _n(String date, int cents, String desc, {int? balance, String source = 'revolut', String currency = 'EUR'}) =>
    NormalizedTransaction(
      id: transactionId(date, cents, desc, 0),
      source: source,
      date: date,
      amountMinor: cents,
      currency: currency,
      bankType: 'Card Payment',
      description: desc,
      balanceAfter: balance,
    );

void main() {
  group('checkBankBalance', () {
    final rows = [
      _t('o', '2026-01-01', -9999), // on the opening date: in the opening already
      _t('r1', '2026-01-05', -1000),
      _t('r2', '2026-01-10', -500),
      _t('r3', '2026-01-15', 200),
      _t('x1', '2026-01-06', -77, source: 'revolut'),
      _t('x2', '2026-01-07', -88, deleted: true),
      _t('x3', '2026-01-08', -99, currency: 'USD'),
      _t('x4', '2026-01-09', -66, manual: true),
    ];

    test('counts like accountBalances, up to and including the date', () {
      final c = checkBankBalance(_pbz, accounts: [_pbz], rows, date: '2026-01-10', bankCents: 8500);
      expect((c.appCents, c.diff, c.rowsSince, c.since, c.matches), (8500, 0, 2, '2026-01-01', true));
      final all = checkBankBalance(_pbz, accounts: [_pbz], rows, date: '2026-01-31', bankCents: 8000);
      expect(all.appCents, accountBalances([_pbz], rows).single.balance);
      expect((all.diff, all.rowsSince), (-700, 3));
    });

    test('a date before any row, and an empty list: the opening only', () {
      expect(checkBankBalance(_pbz, accounts: [_pbz], rows, date: '2026-01-02', bankCents: 10000).appCents, 10000);
      expect(checkBankBalance(_pbz, accounts: [_pbz], const [], date: '2026-01-31', bankCents: 0).diff, -10000);
    });

    test('a negative balance on both sides', () {
      final od = Account(id: 'a2', name: 'Synthetic', source: 'pbz', currency: 'EUR', opening: -5000, openingDate: '2026-01-01');
      final c = checkBankBalance(od, accounts: [od], [_t('r', '2026-01-02', -1000)], date: '2026-01-02', bankCents: -6000);
      expect((c.appCents, c.diff), (-6000, 0));
    });
  });

  group('balanceTrusted', () {
    final old = Account(id: 'a1', name: 'Synthetic', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2025-06-01');
    const today = '2026-02-05';
    final rows = [_t('r1', '2025-12-20', 5)]; // the app counts 5 from 20 December on

    test('the opening date (a new account or a correction) exactly 35 days old is trusted, 36 is not', () {
      expect(
          balanceTrusted(Account(id: 'a', name: 'S', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-01-01'),
              today: today, rows: const [], accounts: const []),
          isTrue); // 35 days
      expect(
          balanceTrusted(Account(id: 'a', name: 'S', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2025-12-31'),
              today: today, rows: const [], accounts: const []),
          isFalse); // 36 days
    });

    test('a matching check exactly 35 days old is trusted, 36 is not; one that is off never is', () {
      expect(
          balanceTrusted(old,
              accounts: [old], today: today, rows: rows, last: const BankCheck(date: '2026-01-01', bankCents: 5, appCents: 5)),
          isTrue);
      expect(
          balanceTrusted(old,
              accounts: [old], today: today, rows: rows, last: const BankCheck(date: '2025-12-31', bankCents: 5, appCents: 5)),
          isFalse);
      expect(
          balanceTrusted(old,
              accounts: [old], today: today, rows: rows, last: const BankCheck(date: '2026-02-05', bankCents: 6, appCents: 6)),
          isFalse,
          reason: 'off against the rows now, whatever was stored');
      expect(balanceTrusted(old, accounts: [old], today: today, rows: rows), isFalse);
    });

    // Review fix 1: trust is decided from the rows now, never from the stored appCents/diff.
    test('a stored match goes stale when a row up to its date is deleted later', () {
      const check = BankCheck(date: '2026-01-20', bankCents: 5, appCents: 5);
      expect(balanceTrusted(old, accounts: [old], today: today, rows: rows, last: check), isTrue);
      final deleted = [_t('r1', '2025-12-20', 5, deleted: true)];
      expect(balanceTrusted(old, accounts: [old], today: today, rows: deleted, last: check), isFalse);
      // A stored "off" that the rows now match (a missing row arrived by sync) is trusted.
      expect(
          balanceTrusted(old,
              accounts: [old], today: today, rows: rows, last: const BankCheck(date: '2026-01-20', bankCents: 5, appCents: 0)),
          isTrue);
    });

    test('a check that was off, then corrected by the owner (the opening moves to it), is trusted', () {
      final corrected = Account(id: 'a1', name: 'Synthetic', source: 'pbz', currency: 'EUR', opening: 5, openingDate: '2026-02-01');
      expect(
          balanceTrusted(corrected,
              accounts: [corrected], today: today, rows: const [], last: const BankCheck(date: '2026-02-01', bankCents: 5, appCents: 9)),
          isTrue);
    });

    test('a date after today counts as recent; a bad date never', () {
      expect(
          balanceTrusted(old,
              accounts: [old], today: today, rows: rows, last: const BankCheck(date: '2026-02-07', bankCents: 5, appCents: 5)),
          isTrue);
      expect(
          balanceTrusted(Account(id: 'a', name: 'S', source: 'pbz', currency: 'EUR', opening: 0, openingDate: ''),
              today: today, rows: const [], accounts: const []),
          isFalse);
    });
  });

  group('repo checks', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory(now: () => 2000000000000 + 1000000));
    tearDown(() => r.close());

    test('recordBankCheck / lastBankCheck: device-local, never synced, never changes the balance', () async {
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 1000, openingDate: '2026-01-01');
      final ops = r.pendingOps().length;
      expect(r.lastBankCheck(id), isNull);
      r.recordBankCheck(id, date: '2026-01-20', bankCents: 900, appCents: 1000);
      final c = r.lastBankCheck(id)!;
      expect((c.date, c.bankCents, c.appCents, c.diff), ('2026-01-20', 900, 1000, -100));
      expect(r.pendingOps().length, ops, reason: 'no sync op');
      expect(r.accounts().single.opening, 1000);
      expect(r.lastBankChecks([id, 'none']).keys, [id]);
      expect(() => r.recordBankCheck('none', date: '2026-01-20', bankCents: 1, appCents: 1), throwsArgumentError);
      expect(() => r.recordBankCheck(id, date: '2026-13-01', bankCents: 1, appCents: 1), throwsArgumentError);
      expect(() => r.recordBankCheck(id, date: '2026-01-20', bankCents: maxAmountCents + 1, appCents: 1), throwsArgumentError);
      r.setLocalValue('bankCheck:$id', '{"date": 5}');
      expect(r.lastBankCheck(id), isNull, reason: 'a damaged value reads as none');
      r.setLocalValue('bankCheck:$id', 'not json');
      expect(r.lastBankCheck(id), isNull);
    });

    test('an import whose file states a balance records the check automatically (match and off)', () async {
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2026-01-01');
      final cash = await r.addAccount(name: 'Cash', currency: 'EUR', opening: 0, openingDate: '2026-01-01');
      final s = r.importBatch(ImportBatch(source: 'revolut', transactions: [
        _n('2026-01-05', -1000, 'Synthetic a', balance: 9000),
        _n('2026-01-06', -500, 'Synthetic b', balance: 8500),
      ]));
      expect(s.bankChecks.keys, [id]);
      expect(s.bankChecks[id]!.matches, isTrue);
      expect(r.lastBankCheck(id)!.date, '2026-01-06');
      expect(r.lastBankCheck(cash), isNull);
      // The next file says 100 less than the app: off by -100, recorded; the balance is not touched.
      final off = r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-08', -200, 'Synthetic c', balance: 8200)]));
      expect(off.bankChecks[id]!.diff, -100);
      expect(off.bankChecks[id]!.rowsSince, 3);
      expect(r.lastBankCheck(id)!.diff, -100);
      expect(r.accounts().firstWhere((a) => a.id == id).opening, 10000);
    });

    test('an older file never replaces a newer check; no account or no balance: nothing recorded', () async {
      final none = r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-05', -1000, 'Synthetic a', balance: 9000)]));
      expect(none.bankChecks, isEmpty);
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2026-01-01');
      r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-09', -1, 'Synthetic z', balance: 8999)]));
      expect(r.lastBankCheck(id)!.date, '2026-01-09');
      final older = r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-05', -1000, 'Synthetic a', balance: 9000)]));
      expect(older.bankChecks.keys, [id], reason: 'still reported for the import result');
      expect(r.lastBankCheck(id)!.date, '2026-01-09');
      final plain = r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-10', -2, 'Synthetic y')]));
      expect(plain.bankChecks, isEmpty);
      // Another currency of the same source has no account here.
      final usd =
          r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-10', -2, 'Synthetic u', currency: 'USD', balance: 5)]));
      expect(usd.bankChecks, isEmpty);
    });

    // Review fix 3.
    test('a file balance dated before the account opening records no check', () async {
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2026-01-10');
      final s = r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-05', -1000, 'Synthetic a', balance: 9000)]));
      expect(s.bankChecks, isEmpty);
      expect(r.lastBankCheck(id), isNull);
    });

    // Review fix 4.
    test('another bank account or pocket of the same source and currency in the file dates: no check', () async {
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2026-01-01');
      // A Savings pocket's file first (its own rows, its own balance): checked against everything, so far only its rows.
      r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-06', 500, 'Synthetic savings', balance: 10500)]));
      // The Current file covers the same days: the Savings row is stored there but not in this file.
      final s = r.importBatch(ImportBatch(source: 'revolut', transactions: [
        _n('2026-01-05', -1000, 'Synthetic a', balance: 9000),
        _n('2026-01-07', -500, 'Synthetic b', balance: 8500),
      ]));
      expect(s.bankChecks, isEmpty);
      expect(r.lastBankCheck(id)!.date, '2026-01-06', reason: 'the first file\'s check stays; nothing wrong recorded');
      // A later file whose dates hold only its own rows is checked again.
      final later = r.importBatch(ImportBatch(source: 'revolut', transactions: [_n('2026-01-09', -100, 'Synthetic c', balance: 8900)]));
      expect(later.bankChecks.keys, [id]);
    });

    // Review fix 1 at the repo: a match recorded at import goes stale when a row is deleted.
    test('a recorded match stops being trusted once a row it counted is deleted', () async {
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2025-01-01');
      final a = _n('2026-01-05', -1000, 'Synthetic a', balance: 9000);
      r.importBatch(ImportBatch(source: 'revolut', transactions: [a]));
      final acc = r.accounts().single;
      expect(balanceTrusted(acc, accounts: [acc], today: '2026-01-20', last: r.lastBankCheck(id), rows: r.transactions()), isTrue);
      r.deleteTransaction(a.id);
      expect(r.lastBankCheck(id)!.diff, 0, reason: 'the stored numbers are for display only');
      expect(
          balanceTrusted(acc, accounts: [acc], today: '2026-01-20', last: r.lastBankCheck(id), rows: r.transactions(includeHidden: true)),
          isFalse);
    });

    test('the preview records nothing', () async {
      final id = await r.addAccount(name: 'Synthetic', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2026-01-01');
      r.previewImport(ImportBatch(source: 'revolut', transactions: [_n('2026-01-05', -1000, 'Synthetic a', balance: 9000)]));
      expect(r.lastBankCheck(id), isNull);
    });
  });
}
