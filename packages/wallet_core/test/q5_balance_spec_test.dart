// Stage Q5 spec tests (core half): checkBankBalance, balanceTrusted, automatic checks from ImportBatch.bankBalances, and
// the rule that no balance changes without correctBalance. Written from docs/context/STAGE_Q_PLAN.md Q5 only. SYNTHETIC data.
// API: accounts.dart (checkBankBalance, balanceTrusted(a, today:, last:, rows:), BankCheck), ImportBatch.bankBalances (List<BankBalance>),
// ImportSummary.bankChecks (account id -> BalanceCheck). The batch's bankBalances come from the rows' balanceAfter.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/n2.dart';
import 'support/synthetic.dart';

int _rowsSince(BalanceCheck c) => c.rowsSince;
NormalizedTransaction _row(String source, String date, int cents, String desc, {int? balanceAfter}) => NormalizedTransaction(
    id: transactionId(date, cents, desc, 0),
    source: source,
    date: date,
    amountMinor: cents,
    currency: 'EUR',
    bankType: 'Card Payment',
    description: desc,
    balanceAfter: balanceAfter);

final _acc = Account(id: 'a1', name: 'Main', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-01-01');

void main() {
  group('checkBankBalance', () {
    final rows = [n2Tx('2026-01-05', -2000), n2Tx('2026-01-10', -3000), n2Tx('2026-01-12', -1000)];

    test('counts rows up to and including the date; later rows are only "since"', () {
      final c = checkBankBalance(_acc, rows, date: '2026-01-10', bankCents: 95000);
      expect(c.appCents, 95000);
      expect(c.diff, 0);
      expect(_rowsSince(c), 2, reason: 'rows counted from the opening up to and including the date: 01-05 and 01-10');
    });
    test('a row on the day before is in, a row on the day after is out', () {
      expect(checkBankBalance(_acc, rows, date: '2026-01-09', bankCents: 98000).appCents, 98000);
      expect(checkBankBalance(_acc, rows, date: '2026-01-11', bankCents: 95000).appCents, 95000);
    });
    test('a difference is reported with its size, opposite signs for opposite errors', () {
      final low = checkBankBalance(_acc, rows, date: '2026-01-10', bankCents: 94000);
      final high = checkBankBalance(_acc, rows, date: '2026-01-10', bankCents: 96000);
      expect(low.diff.abs(), 1000);
      expect(high.diff.abs(), 1000);
      expect(low.diff, -high.diff);
      expect(checkBankBalance(_acc, rows, date: '2026-01-10', bankCents: 96500).diff.abs(), 1500);
    });
    test('equals accountBalances when the date is on or after the newest row', () {
      final all = accountBalances([_acc], rows).single.balance;
      expect(checkBankBalance(_acc, rows, date: '2026-01-12', bankCents: all).appCents, all);
      final late = checkBankBalance(_acc, rows, date: '2026-06-30', bankCents: all);
      expect(late.appCents, all);
      expect(_rowsSince(late), 3);
    });
    test('same counting as accountBalances: deleted, other source, other currency and opening-day rows stay out', () {
      final mixed = [
        n2Tx('2026-01-05', -2000),
        n2Tx('2026-01-06', -9999, deleted: true),
        n2Tx('2026-01-06', -8888, source: 'revolut'),
        n2Tx('2026-01-06', -7777, currency: 'USD'),
        n2Tx('2026-01-01', -6666), // the opening day: the opening already holds it
      ];
      final c = checkBankBalance(_acc, mixed, date: '2026-01-31', bankCents: 98000);
      expect(c.appCents, 98000);
      expect(c.appCents, accountBalances([_acc], mixed).single.balance);
    });
    test('a date before the opening date gives the opening; a negative bank balance is fine', () {
      expect(checkBankBalance(_acc, rows, date: '2025-12-01', bankCents: 100000).appCents, 100000);
      final c = checkBankBalance(_acc, [n2Tx('2026-01-05', -150000)], date: '2026-01-31', bankCents: -50000);
      expect(c.appCents, -50000);
      expect(c.diff, 0);
    });
    test('is pure: rows and account are unchanged however far off the bank is', () {
      final before = [for (final t in rows) t.amount];
      checkBankBalance(_acc, rows, date: '2026-01-10', bankCents: 1);
      expect([for (final t in rows) t.amount], before);
      expect(_acc.opening, 100000);
    });
  });

  group('balanceTrusted (recomputed from the rows, never from the stored numbers)', () {
    final rows = [n2Tx('2026-01-05', -2000), n2Tx('2026-01-10', -3000), n2Tx('2026-01-12', -1000)];
    const ok = BankCheck(date: '2026-01-10', bankCents: 95000, appCents: 95000);
    bool trusted(String today, {BankCheck? last = ok, List<Tx>? r}) => balanceTrusted(_acc, today: today, last: last, rows: r ?? rows);

    test('a matching check is trusted 35 days after it, not on the 36th', () {
      expect(trusted('2026-02-14'), isTrue); // 35 days
      expect(trusted('2026-02-15'), isFalse); // 36 days
    });
    test('trusted on the day of the check and the day after', () {
      expect(trusted('2026-01-10'), isTrue);
      expect(trusted('2026-01-11'), isTrue);
    });
    test('the 35-day edge holds across a year boundary and a 28-day February', () {
      const dec = BankCheck(date: '2025-12-28', bankCents: 100000, appCents: 100000);
      final acc = Account(id: 'a1', name: 'Main', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2025-06-01');
      expect(balanceTrusted(acc, today: '2026-02-01', last: dec, rows: const []), isTrue); // 35 days
      expect(balanceTrusted(acc, today: '2026-02-02', last: dec, rows: const []), isFalse); // 36 days
      const feb = BankCheck(date: '2026-02-01', bankCents: 100000, appCents: 100000);
      expect(balanceTrusted(acc, today: '2026-03-08', last: feb, rows: const []), isTrue);
      expect(balanceTrusted(acc, today: '2026-03-09', last: feb, rows: const []), isFalse);
    });
    test('a check that does not match the rows is not trusted, however recent', () {
      expect(trusted('2026-02-12', last: const BankCheck(date: '2026-01-10', bankCents: 94000, appCents: 95000)), isFalse);
    });
    test('trust is recomputed: the stored appCents is ignored, and a later edit that breaks the match removes trust', () {
      expect(trusted('2026-02-12', last: const BankCheck(date: '2026-01-10', bankCents: 95000, appCents: 1)), isTrue);
      expect(trusted('2026-02-12', r: [...rows, n2Tx('2026-01-08', -500)]), isFalse, reason: 'a row added before the check date');
      expect(trusted('2026-02-12', r: [...rows, n2Tx('2026-01-20', -500)]), isTrue, reason: 'a row after the check date does not matter');
    });
    test('no check: trusted only while the opening date itself is within 35 days', () {
      expect(trusted('2026-02-05', last: null), isTrue); // opening 2026-01-01, 35 days
      expect(trusted('2026-02-06', last: null), isFalse);
    });
    test('a check older than the account opening is not trusted', () {
      expect(trusted('2026-02-20', last: const BankCheck(date: '2025-12-30', bankCents: 100000, appCents: 100000)), isFalse);
    });
  });

  group('no balance changes without correctBalance', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch));
    tearDown(() => r.close());

    test('importing a file whose bank balance disagrees leaves the account opening and date untouched', () async {
      final id = await r.addAccount(name: 'Main', source: 'revolut', currency: 'EUR', opening: 50000, openingDate: '2026-03-01');
      final summary = r.importBatch(ImportBatch(
          source: 'revolut', transactions: [_row('revolut', '2026-03-10', -1000, 'Synth Cafe', balanceAfter: 1)])); // 1 vs the app's 49000
      final a = r.accounts().singleWhere((x) => x.id == id);
      expect([a.opening, a.openingDate], [50000, '2026-03-01']);
      expect(accountBalances(r.accounts(), r.transactions(includeHidden: true)).single.balance, 49000);
      // The check IS recorded automatically (device-local), and says how far off the app is.
      expect(summary.bankChecks[id]!.diff, 1 - 49000);
      expect(r.lastBankCheck(id)!.bankCents, 1);
    });
    test('a bank balance that matches is recorded as a zero-difference check', () async {
      final id = await r.addAccount(name: 'Main', source: 'revolut', currency: 'EUR', opening: 50000, openingDate: '2026-03-01');
      final summary = r.importBatch(
          ImportBatch(source: 'revolut', transactions: [_row('revolut', '2026-03-10', -1000, 'Synth Cafe', balanceAfter: 49000)]));
      expect(summary.bankChecks[id]!.diff, 0);
      expect(r.lastBankCheck(id)!.diff, 0);
    });
    test('a balance for a source or currency with no account records nothing and breaks nothing', () async {
      final id = await r.addAccount(name: 'Main', source: 'revolut', currency: 'EUR', opening: 50000, openingDate: '2026-03-01');
      final summary =
          r.importBatch(ImportBatch(source: 'pbz', transactions: [_row('pbz', '2026-03-10', -1000, 'Synth Cafe', balanceAfter: 5)]));
      expect(summary.bankChecks, isEmpty);
      expect(r.lastBankCheck(id), isNull);
    });
    test('importing without a balance, and importing the same file twice, changes no account', () async {
      final id = await r.addAccount(name: 'Main', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-01-01');
      r.importBatch(january);
      r.importBatch(january);
      final a = r.accounts().singleWhere((x) => x.id == id);
      expect([a.opening, a.openingDate], [100000, '2026-01-01']);
    });
    test('only correctBalance moves the anchor', () async {
      final id = await r.addAccount(name: 'Main', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-01-01');
      await r.correctBalance(id, balance: 42000, date: '2026-03-01');
      final a = r.accounts().single;
      expect([a.opening, a.openingDate], [42000, '2026-03-01']);
    });
  });
}
