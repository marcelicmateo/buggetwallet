// H1: only rows in the settings' currency count in the budget sums; the others are reported by currency. SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

var _seq = 0;

/// A row in another currency (an account abroad or a card in USD).
CategorizedTx fx(String date, int cents, String category, String currency, {bool deleted = false}) => CategorizedTx(
      Tx(id: 'fx-${_seq++}', source: 'revolut', date: date, amount: cents, currency: currency, deleted: deleted),
      category,
      kindOf(category),
    );

void main() {
  const st = WalletSettings(salary: 200000, rent: 50000, periodStart: '2026-03-15', paydayDay: 15, currency: 'EUR');
  const today = '2026-03-20';
  final eur = [
    ct('2026-03-15', 200000, 'Salary'),
    ct('2026-03-16', -3000, 'Groceries'),
    ct('2026-03-16', -50000, 'Rent'),
    ct('2026-03-17', 1000, 'Extra income'),
  ];
  // One foreign row of every kind, a foreign transfer and a deleted foreign row.
  final foreign = [
    fx('2026-03-16', 90000, 'Salary', 'USD'),
    fx('2026-03-17', -7000, 'Groceries', 'USD'),
    fx('2026-03-17', -40000, 'Rent', 'USD'),
    fx('2026-03-18', 500, 'Extra income', 'USD'),
    fx('2026-03-18', -1234, 'Eating out', 'CHF'),
    fx('2026-03-18', -99999, 'Internal transfer', 'USD'),
    fx('2026-03-18', -55555, 'Groceries', 'USD', deleted: true),
  ];

  group('computePeriod', () {
    test('foreign rows change no sum; their signed totals are listed by currency', () {
      final only = computePeriod(eur, st, const [], today, table: CategoryTable.builtIn);
      final mixed = computePeriod([...eur, ...foreign], st, const [], today, table: CategoryTable.builtIn);
      for (final (name, get) in <(String, int Function(PeriodBudget))>[
        ('received', (p) => p.received),
        ('extras', (p) => p.extras),
        ('income', (p) => p.income),
        ('spent', (p) => p.spent),
        ('spentToday', (p) => p.spentToday),
        ('remaining', (p) => p.remaining),
        ('allowanceToday', (p) => p.allowanceToday),
        ('safeToday', (p) => p.safeToday),
      ]) {
        expect(get(mixed), get(only), reason: name);
      }
      expect(mixed.fixedPaid, only.fixedPaid);
      expect(only.foreignByCurrency, isEmpty);
      expect(mixed.foreignByCurrency, {'USD': 90000 - 7000 - 40000 + 500, 'CHF': -1234});
    });

    test('received income in another currency does not count as received', () {
      final s = WalletSettings.fromMap({...st.toMap(), 'incomeMode': 'received'});
      final p = computePeriod([fx('2026-03-15', 300000, 'Salary', 'USD')], s, const [], today, table: CategoryTable.builtIn);
      expect((p.received, p.income), (0, s.salary));
    });

    test('a wallet in CHF counts its CHF rows and lists the EUR ones', () {
      final chf = WalletSettings.fromMap({...st.toMap(), 'currency': 'CHF'});
      final p = computePeriod([...eur, ...foreign], chf, const [], today, table: CategoryTable.builtIn);
      expect(p.spent, 1234);
      expect(p.foreignByCurrency['EUR'], 200000 - 3000 - 50000 + 1000);
      expect(p.foreignByCurrency.containsKey('CHF'), isFalse);
    });
  });

  group('monthSummary, periodSummaries, averages, budgets, CSV', () {
    final all = [...eur, ...foreign];

    test('monthSummary', () {
      final m = monthSummary(all, '2026-03', currency: 'EUR');
      final e = monthSummary(eur, '2026-03', currency: 'EUR');
      expect((m.income, m.out), (e.income, e.out));
      expect(m.byCategory, e.byCategory);

      expect(m.foreignByCurrency, {'USD': 43500, 'CHF': -1234});
      expect(e.foreignByCurrency, isEmpty);
    });

    test('periodSummaries: sums and payday detection ignore foreign salary', () {
      // A foreign salary in February would start a period there if it counted.
      final ps = periodSummaries([...all, fx('2026-02-01', 50000, 'Salary', 'USD')], st, today);
      final only = periodSummaries(eur, st, today);
      expect([for (final p in ps) (p.start, p.income, p.out)], [for (final p in only) (p.start, p.income, p.out)]);
      expect(salaryPaydays([fx('2026-02-01', 50000, 'Salary', 'USD')], today, currency: 'EUR'), isEmpty);
      expect(salaryPaydays([fx('2026-02-01', 50000, 'Salary', 'USD')], today, currency: 'USD'), ['2026-02-01']);
    });

    test('averageByCategory, suggestBudgets and budgetVsActual', () {
      final past = [
        ct('2026-01-10', -6000, 'Groceries'),
        fx('2026-01-10', -600000, 'Groceries', 'USD'),
        fx('2026-02-10', -600000, 'Eating out', 'USD'),
      ];
      expect(averageByCategory(past, '2026-03', currency: 'EUR'), {'Groceries': 1000});
      expect(averageByCategory(past, '2026-03', currency: 'USD'), {'Groceries': 100000, 'Eating out': 100000});
      expect(suggestBudgets(past, '2026-03', currency: 'EUR'), {'Groceries': 1000});
      final b = budgetVsActual([...past, ...all], '2026-03', const {'Groceries': 5000}, today: today, currency: 'EUR');
      final g = b.lines.singleWhere((l) => l.category == 'Groceries');
      expect((g.actual, g.average6), (3000, 1000));
      expect(b.lines.map((l) => l.category), isNot(contains('Eating out')));
    });

    test('monthlySummaryCsv sums one currency; transactionsCsv keeps every row', () {
      expect(monthlySummaryCsv(all, currency: 'EUR'), monthlySummaryCsv(eur, currency: 'EUR'));
      final usdOnly = monthlySummaryCsv(all, currency: 'USD');
      expect(usdOnly.split('\n')[1], startsWith('2026-03,'));
      expect(transactionsCsv(all).trim().split('\n'), hasLength(1 + all.where((t) => t.tx.live).length));
    });

    test('reviewState pace uses the settings currency', () {
      final r = reviewState([fx('2026-03-18', -900000, 'Groceries', 'USD')], st, const [], const {'Groceries': 1000}, today: today);
      expect(r.step('pace')!.count, 0);
    });

    test('foreignByCurrency covers the period only: rows before start or after today are not listed', () {
      final p = computePeriod(
          [
            ...eur,
            fx('2026-03-14', -100, 'Groceries', 'USD'), // the day before the period
            fx('2026-03-21', -200, 'Groceries', 'USD'), // the day after today
            fx('2026-03-15', -300, 'Groceries', 'USD'), // first day
            fx(today, -400, 'Groceries', 'USD'), // today
          ],
          st,
          const [],
          today,
          table: CategoryTable.builtIn);
      expect(p.foreignByCurrency, {'USD': -700});
    });

    test('monthSummary lists only the month\'s foreign rows', () {
      final m = monthSummary([...all, fx('2026-02-28', -100, 'Groceries', 'USD'), fx('2026-04-01', -200, 'Groceries', 'CHF')], '2026-03',
          currency: 'EUR');
      expect(m.foreignByCurrency, {'USD': 43500, 'CHF': -1234});
    });
  });

  group('recurring bills in another currency (owner rule: exact money)', () {
    const home = WalletSettings(salary: 200000, periodStart: '2026-03-15', paydayDay: 15);
    final clock = DateTime.utc(2026, 4, 12).millisecondsSinceEpoch;
    NormalizedTransaction row(String date, int cents, String currency, {String desc = 'Synthetic Gym 2026'}) => NormalizedTransaction(
        id: transactionId(date, cents, '$desc $currency', 0),
        source: 'revolut',
        date: date,
        amountMinor: cents,
        currency: currency,
        bankType: 'Card Payment',
        description: desc);
    PeriodBudget period(WalletRepo r) {
      final cz = r.categorizer();
      return computePeriod([for (final t in r.transactions()) cz.categorize(t)], home, const [], '2026-04-12',
          bills: r.recurringBills(), table: CategoryTable.builtIn);
    }

    test('a USD monthly payee is no candidate and reserves nothing', () {
      final r = WalletRepo.inMemory(now: () => clock);
      addTearDown(r.close);
      final usd = [row('2026-01-10', -1500, 'USD'), row('2026-02-09', -1500, 'USD'), row('2026-03-11', -1500, 'USD')];
      r.importBatch(ImportBatch(source: 'revolut', transactions: usd));
      expect(r.recurringBills(), isEmpty);
      final cz = r.categorizer();
      final txs = [for (final t in r.transactions()) cz.categorize(t)];
      expect(detectRecurring(txs, today: '2026-04-12', currency: 'USD'), hasLength(1), reason: 'the rows themselves qualify');
      expect(detectRecurring(txs, today: '2026-04-12', currency: 'EUR'), isEmpty);
      expect(period(r).reservedBills, 0);
      expect(period(r).dueBills, isEmpty);
    });

    test('mixed currencies at one payee: only the home-currency rows make and pay the bill', () {
      final r = WalletRepo.inMemory(now: () => clock);
      addTearDown(r.close);
      r.importBatch(ImportBatch(source: 'revolut', transactions: [
        row('2026-01-10', -2000, 'EUR'),
        row('2026-02-09', -2000, 'EUR'),
        row('2026-02-20', -9000, 'USD'), // would break the chain and the band if it counted
        row('2026-03-11', -2000, 'EUR'),
      ]));
      final bill = r.recurringBills().single;
      expect((bill.expectedAmount, bill.nextDue), (2000, '2026-04-10'));
      r.confirmRecurring(bill.id);
      // A USD row of the same size on the due date does not pay it: it stays reserved from the EUR money.
      r.importBatch(ImportBatch(source: 'revolut', transactions: [row('2026-04-10', -2000, 'USD')]));
      expect(r.recurringBills().single.lastPaidTx, isNull);
      expect(period(r).reservedBills, 2000);
      expect(planRecurringPayments(r.recurringBills(), r.transactions(), currency: 'EUR').isEmpty, isTrue);
      // The EUR payment does.
      r.importBatch(ImportBatch(source: 'revolut', transactions: [row('2026-04-11', -2000, 'EUR')]));
      expect(r.recurringBills().single.nextDue, '2026-05-11');
      expect(period(r).reservedBills, 0);
    });
  });
}
