// Stage N2 (core builder): plan suggestions from imports, plan proposals and the budget Suggest diff. All data is
// SYNTHETIC.
library;

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

/// A categorized row (kind from the category); [currency] defaults to the home currency.
CategorizedTx _r(String date, int cents, String category, {String currency = 'EUR', String? id}) => CategorizedTx(
    Tx(id: id ?? 'syn-${_seq++}', source: 'pbz', date: date, amount: cents, currency: currency, description: 'Synthetic'),
    category,
    kindOf(category));

RecurringBill _bill(String id, int cents, {String status = 'confirmed', String category = 'Bills & subscriptions'}) =>
    RecurringBill(id: id, payee: id, label: id, category: category, expectedAmount: cents, nextDue: '2026-11-01', status: status);

const _st = WalletSettings();
const _today = '2026-10-20';

void main() {
  group('suggestPlan: salary and payday', () {
    test('salary paid in parts is grouped per payday; the median of the complete groups', () {
      final txs = [
        _r('2026-07-01', -1000, 'Groceries'), // the data reaches back before the first payday: its group is whole
        _r('2026-08-10', 100000, 'Salary', id: 'a1'),
        _r('2026-08-14', 50000, 'Salary', id: 'a2'),
        _r('2026-09-11', 100000, 'Salary', id: 'b1'),
        _r('2026-09-13', 60000, 'Salary', id: 'b2'),
        _r('2026-10-10', 150000, 'Salary', id: 'c1'), // running group: not complete
      ];
      final s = suggestPlan(txs, _st, _today);
      expect(s.salary!.value, 155000);
      expect(s.salary!.basis, 'salaryRows');
      expect(s.salary!.evidence, ['a1', 'a2', 'b1', 'b2']);
      expect(s.paydayDay!.value, 10);
      expect(s.paydayDay!.basis, 'paydayDates');
      expect(s.paydayDay!.evidence, ['a1', 'b1', 'c1']);
    });

    test('the last 3 complete groups only; odd count takes the middle one', () {
      final txs = [
        for (final (m, v) in [('05', 900000), ('06', 100000), ('07', 120000), ('08', 110000), ('09', 500000)])
          _r('2026-$m-15', v, 'Salary'),
      ];
      expect(suggestPlan(txs, _st, '2026-09-20').salary!.value, 110000, reason: 'June, July, August');
    });

    test('not enough evidence gives null', () {
      expect(suggestPlan(const [], _st, _today).salary, isNull);
      final one = [_r('2026-08-01', -1000, 'Groceries'), _r('2026-09-15', 100000, 'Salary'), _r('2026-10-15', 100000, 'Salary')];
      final s = suggestPlan(one, _st, _today);
      expect(s.salary, isNull, reason: 'one complete group');
      expect(s.paydayDay, isNotNull, reason: 'two groups are enough for the day');
      expect(suggestPlan([_r('2026-10-15', 100000, 'Salary')], _st, _today).paydayDay, isNull);
    });

    test('foreign-currency salary is ignored', () {
      final txs = [
        for (final m in ['07', '08', '09', '10']) _r('2026-$m-12', 100000, 'Salary', currency: 'USD'),
      ];
      final s = suggestPlan(txs, _st, _today);
      expect((s.salary, s.paydayDay), (null, null));
      expect(suggestPlan(txs, const WalletSettings(currency: 'USD'), _today).salary!.value, 100000);
    });

    test('payday day: a tie goes to the later day; 29–31 read as 28', () {
      final tie = [_r('2026-07-01', -1000, 'Groceries'), _r('2026-08-10', 1000, 'Salary'), _r('2026-09-12', 1000, 'Salary')];
      expect(suggestPlan(tie, _st, _today).paydayDay!.value, 12);
      final late = [_r('2026-07-31', 1000, 'Salary'), _r('2026-08-30', 1000, 'Salary'), _r('2026-10-01', 1000, 'Salary')];
      expect(suggestPlan(late, _st, _today).paydayDay!.value, 28);
    });

    test('rows after today never count', () {
      final txs = [_r('2026-09-15', 1000, 'Salary'), _r('2026-10-15', 1000, 'Salary'), _r('2026-11-15', 1000, 'Salary')];
      expect(suggestPlan(txs, _st, _today).salary, isNull);
    });
  });

  group('suggestPlan: rent, loan and subs', () {
    test('rent: the median monthly sum of the last 3 complete months with Rent rows', () {
      final txs = [
        _r('2026-05-01', -90000, 'Rent'),
        _r('2026-07-01', -50000, 'Rent', id: 'r7'),
        _r('2026-08-01', -30000, 'Rent', id: 'r8a'),
        _r('2026-08-02', -22000, 'Rent', id: 'r8b'),
        _r('2026-09-01', -50000, 'Rent', id: 'r9'),
        _r('2026-10-01', -99999, 'Rent'), // this month: not complete
      ];
      final s = suggestPlan(txs, _st, _today);
      expect(s.rent!.value, 50000);
      expect(s.rent!.basis, 'rentRows');
      expect(s.rent!.evidence, ['r7', 'r8a', 'r8b', 'r9']);
      expect(s.loan, isNull);
    });

    test('loan needs 2 months; one month gives null', () {
      expect(suggestPlan([_r('2026-09-05', -30000, 'Loan')], _st, _today).loan, isNull);
      final s = suggestPlan([_r('2026-08-05', -30000, 'Loan'), _r('2026-09-05', -30000, 'Loan')], _st, _today);
      expect((s.loan!.value, s.loan!.basis), (30000, 'loanRows'));
    });

    test('a big ATM row the categoriser did not make Rent is not rent; foreign Rent rows are ignored', () {
      final txs = [
        _r('2026-08-01', -60000, 'Cash'),
        _r('2026-09-01', -60000, 'Cash'),
        _r('2026-08-01', -60000, 'Rent', currency: 'USD'),
        _r('2026-09-01', -60000, 'Rent', currency: 'USD'),
      ];
      expect(suggestPlan(txs, _st, _today).rent, isNull);
    });

    test('subs: only confirmed bills in Bills & subscriptions; candidates never', () {
      final s = suggestPlan(const [], _st, _today,
          confirmed: [
            _bill('rec:a', 999),
            _bill('rec:b', 1500),
            _bill('rec:c', 5000, status: 'candidate'),
            _bill('rec:d', 7000, status: 'dismissed'),
            _bill('rec:e', 4000, category: 'Groceries'),
          ]);
      expect((s.subs!.value, s.subs!.basis), (2499, 'confirmedBills'));
      expect(s.subs!.evidence, ['rec:a', 'rec:b']);
      expect(suggestPlan(const [], _st, _today, confirmed: [_bill('rec:c', 5000, status: 'candidate')]).subs, isNull);
    });
  });

  group('planProposals', () {
    test('one per non-null suggestion that differs; equal values are skipped; 0 money = no current', () {
      const s = PlanSuggestion(
        salary: Suggested(value: 150000, basis: 'salaryRows', evidence: ['x']),
        paydayDay: Suggested(value: 15, basis: 'paydayDates'),
        rent: Suggested(value: 50000, basis: 'rentRows'),
        subs: Suggested(value: 2499, basis: 'confirmedBills'),
      );
      final p = planProposals(s, const WalletSettings(salary: 150000, rent: 45000));
      expect([
        for (final x in p) (x.key, x.current, x.suggested, x.basis)
      ], [
        ('rent', 45000, 50000, 'rentRows'),
        ('subs', null, 2499, 'confirmedBills'),
      ]);
      expect(planProposals(const PlanSuggestion(), _st), isEmpty);
      final day = planProposals(const PlanSuggestion(paydayDay: Suggested(value: 10, basis: 'paydayDates')), _st).single;
      expect((day.key, day.current, day.suggested), ('paydayDay', 15, 10));
    });
  });

  group('budgetProposals', () {
    test('empty fields first, then by name; equal values left out; 0 counts as empty', () {
      final p = budgetProposals({'Groceries': 30000, 'Shopping': 10000, 'Eating out': 0, 'Health & care': 5000},
          {'Shopping': 12000, 'Groceries': 30000, 'Eating out': 8000, 'Car & transport': 6000, 'Health & care': 4000});
      expect([
        for (final x in p) (x.category, x.current, x.suggested, x.fillsEmpty)
      ], [
        ('Car & transport', null, 6000, true),
        ('Eating out', null, 8000, true),
        ('Health & care', 5000, 4000, false),
        ('Shopping', 10000, 12000, false),
      ]);
      expect(budgetProposals({'Groceries': 1000}, {}), isEmpty);
    });
  });

  group('review fixes: old evidence and a partial first payday', () {
    test('a loan paid off and a salary stopped in March suggest nothing in October (window Apr-Sep)', () {
      final txs = [
        for (final m in ['01', '02', '03']) _r('2026-$m-05', -25000, 'Loan'),
        _r('2025-12-01', -1000, 'Groceries'),
        for (final m in ['01', '02', '03']) _r('2026-$m-15', 100000, 'Salary'),
      ];
      final s = suggestPlan(txs, _st, '2026-10-25');
      expect((s.loan, s.salary, s.paydayDay), (null, null, null));
      // In July the window is Jan-Jun: the same rows count.
      expect(suggestPlan(txs, _st, '2026-07-25').loan!.value, 25000);
    });

    test('rows older than the 6-month window never join the median', () {
      final txs = [
        _r('2026-03-01', -90000, 'Rent'),
        _r('2026-04-01', -50000, 'Rent'),
        _r('2026-05-01', -50000, 'Rent'),
      ];
      final s = suggestPlan(txs, _st, '2026-10-25');
      expect(s.rent!.value, 50000);
      expect(s.rent!.evidence, hasLength(2));
    });

    test('an import that starts inside a payday: the oldest group is not counted for salary or the day', () {
      final txs = [
        _r('2026-07-05', 20000, 'Salary'),
        _r('2026-08-01', 100000, 'Salary'),
        _r('2026-08-05', 20000, 'Salary'),
        _r('2026-09-01', 100000, 'Salary'),
        _r('2026-09-05', 20000, 'Salary'),
      ];
      final s = suggestPlan(txs, _st, '2026-09-20');
      expect(s.salary, isNull, reason: 'only August is a whole, complete group');
      expect(suggestPlan(txs, _st, '2026-08-20').paydayDay, isNull, reason: 'the partial July group is no payday start');
      final whole = [_r('2026-06-10', -500, 'Groceries'), ...txs];
      expect(suggestPlan(whole, _st, '2026-09-20').salary!.value, 70000, reason: 'with data before it, July counts');
      final s2 = suggestPlan([...whole, _r('2026-10-01', 100000, 'Salary'), _r('2026-10-05', 20000, 'Salary')], _st, '2026-10-20');
      expect(s2.salary!.value, 120000);
      expect(s2.paydayDay!.value, 1);
    });
  });
}
