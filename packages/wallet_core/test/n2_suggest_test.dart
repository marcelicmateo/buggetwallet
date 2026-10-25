// Stage N2 (spec §3, §4, §6): suggestPlan, planProposals, budgetProposals. Pure. Expected values are worked out by hand
// from docs/context/N2_SPEC.md. Rent and loan amounts are read as positive cents (a setting's sign). All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';

const _today = '2026-10-25';
const _st = WalletSettings();

/// Review fix 2 (N2_SPEC Clarifications): the data's oldest payday group counts only when the data reaches 20 days
/// before it, so every fixture gets one early home-currency non-salary row ("the import starts well before").
PlanSuggestion _suggest(List<CategorizedTx> txs, {WalletSettings st = _st}) =>
    suggestPlan([n2Cz('2026-01-02', -100, 'Groceries', currency: st.currency), ...txs], st, _today);

CategorizedTx _sal(String date, int cents, {String id = '', String currency = 'EUR'}) =>
    n2Cz(date, cents, 'Salary', currency: currency, id: id);

void main() {
  group('salary and payday', () {
    test('no rows: everything null', () {
      final s = _suggest(const []);
      expect((s.salary, s.paydayDay, s.rent, s.loan, s.subs), (null, null, null, null, null));
    });

    test('one payday group is not enough for either', () {
      final s = _suggest([_sal('2026-09-15', 120000)]);
      expect((s.salary, s.paydayDay), (null, null));
    });

    test('two groups but one complete: payday day known, salary still null', () {
      final s = _suggest([_sal('2026-09-15', 120000), _sal('2026-10-15', 125000)]);
      expect(s.salary, isNull, reason: 'only September is complete (October has no successor)');
      expect(s.paydayDay!.value, 15);
      expect(s.paydayDay!.basis, 'paydayDates');
    });

    test('median of the last 3 complete groups; parts within a payday are one group; the open group is ignored', () {
      final s = _suggest([
        _sal('2026-06-15', 900000, id: 'old'), // fourth complete group: out of the last three
        _sal('2026-07-15', 100000, id: 'j'),
        _sal('2026-08-15', 70000, id: 'a1'),
        _sal('2026-08-17', 50000, id: 'a2'), // Aug = 120000 in two parts
        _sal('2026-09-15', 110000, id: 's'),
        _sal('2026-10-15', 500000, id: 'open'), // not complete
      ]);
      expect(s.salary!.value, 110000);
      expect(s.salary!.basis, 'salaryRows');
      expect(s.salary!.evidence.toSet(), {'j', 'a1', 'a2', 's'});
    });

    test('exactly two complete groups: the median of two is accepted (needs >= 2)', () {
      final s = _suggest([_sal('2026-07-15', 100000), _sal('2026-08-15', 100000), _sal('2026-09-15', 100000)]);
      expect(s.salary!.value, 100000);
    });

    test('salary parts 20 days apart stay one group, 21 days apart start a new one', () {
      final one = _suggest([_sal('2026-07-01', 60000), _sal('2026-07-21', 40000), _sal('2026-08-25', 100000), _sal('2026-09-25', 100000)]);
      expect(one.salary!.value, 100000, reason: 'July = 100000 in two parts, then Aug, Sep (open)');
      final two = _suggest([_sal('2026-07-01', 60000), _sal('2026-07-22', 40000), _sal('2026-08-25', 100000), _sal('2026-09-25', 100000)]);
      expect(two.salary!.value, 60000, reason: 'complete groups 60000, 40000, 100000 (Sep open): median 60000');
    });

    test('the payday day is the most common start day; a tie goes to the later day', () {
      final common = _suggest([_sal('2026-06-10', 1000), _sal('2026-07-12', 1000), _sal('2026-08-12', 1000), _sal('2026-09-12', 1000)]);
      expect(common.paydayDay!.value, 12);
      final tie = _suggest([_sal('2026-07-10', 1000), _sal('2026-08-20', 1000)]);
      expect(tie.paydayDay!.value, 20);
    });

    test('a payday day above 28 follows WalletSettings.maxPaydayDay', () {
      final s = _suggest([_sal('2026-07-30', 1000), _sal('2026-08-30', 1000)]);
      expect(s.paydayDay!.value, WalletSettings.maxPaydayDay);
    });

    test('foreign-currency salary is ignored', () {
      final onlyUsd = _suggest([
        _sal('2026-07-15', 100000, currency: 'USD'),
        _sal('2026-08-15', 100000, currency: 'USD'),
        _sal('2026-09-15', 1, currency: 'USD')
      ]);
      expect((onlyUsd.salary, onlyUsd.paydayDay), (null, null));
      final mixed = _suggest([
        _sal('2026-07-15', 100000, id: 'e1'),
        _sal('2026-08-15', 100000, id: 'e2'),
        _sal('2026-08-16', 999999, id: 'usd', currency: 'USD'),
        _sal('2026-09-15', 100000, id: 'e3'),
        _sal('2026-09-30', 888888, id: 'usd2', currency: 'USD'),
      ]);
      expect(mixed.salary!.value, 100000);
      expect(mixed.salary!.evidence, isNot(contains('usd')));
      expect(mixed.salary!.evidence, isNot(contains('usd2')));
    });

    test('a non-home settings currency counts that currency only', () {
      final s = _suggest([
        _sal('2026-07-15', 5000, currency: 'USD'),
        _sal('2026-08-15', 5000, currency: 'USD'),
        _sal('2026-09-15', 5000, currency: 'USD'),
        _sal('2026-08-15', 100000),
      ], st: const WalletSettings(currency: 'USD'));
      expect(s.salary!.value, 5000);
    });

    test('non-income rows are not salary, and a deleted salary row does not count', () {
      const gone =
          CategorizedTx(Tx(id: 'del', source: 'pbz', date: '2026-08-15', amount: 100000, deleted: true), 'Salary', BudgetKind.income);
      final s =
          _suggest([_sal('2026-07-15', 100000), gone, n2Cz('2026-09-15', 100000, 'Extra income'), n2Cz('2026-09-16', 100000, 'Shopping')]);
      expect(s.paydayDay, isNull, reason: 'only July is a payday');
    });
  });

  group('rent and loan', () {
    test('median of the monthly sums of the last 3 complete months that have rows; the current month and older months are left out', () {
      final s = _suggest([
        n2Cz('2026-05-03', -999999, 'Rent', id: 'may'),
        n2Cz('2026-06-03', -40000, 'Rent', id: 'jun'),
        n2Cz('2026-08-03', -50000, 'Rent', id: 'aug'),
        n2Cz('2026-09-03', -50000, 'Rent', id: 'sep1'),
        n2Cz('2026-09-20', -10000, 'Rent', id: 'sep2'), // September = 60000
        n2Cz('2026-10-03', -999999, 'Rent', id: 'oct'), // the month is not complete
      ]);
      expect(s.rent!.value, 50000, reason: 'Jun 40000, Aug 50000, Sep 60000 -> median 50000');
      expect(s.rent!.basis, 'rentRows');
      expect(s.rent!.evidence.toSet(), {'jun', 'aug', 'sep1', 'sep2'});
    });

    test('needs two months', () {
      expect(_suggest([n2Cz('2026-09-03', -50000, 'Rent')]).rent, isNull);
      expect(_suggest([n2Cz('2026-09-03', -50000, 'Rent'), n2Cz('2026-10-03', -50000, 'Rent')]).rent, isNull);
      expect(_suggest([n2Cz('2026-08-03', -50000, 'Rent'), n2Cz('2026-09-03', -50000, 'Rent')]).rent!.value, 50000);
    });

    test('loan works the same and is independent of rent', () {
      final s = _suggest([n2Cz('2026-08-18', -25000, 'Loan'), n2Cz('2026-09-18', -25000, 'Loan'), n2Cz('2026-09-02', -1000, 'Groceries')]);
      expect(s.loan!.value, 25000);
      expect(s.loan!.basis, 'loanRows');
      expect(s.rent, isNull);
    });

    test('foreign-currency rent is ignored', () {
      final s = _suggest([
        n2Cz('2026-08-03', -50000, 'Rent', currency: 'USD'),
        n2Cz('2026-09-03', -50000, 'Rent', currency: 'USD'),
        n2Cz('2026-09-04', -50000, 'Rent'),
      ]);
      expect(s.rent, isNull, reason: 'one home-currency month only');
    });

    test('an ATM withdrawal under the rent threshold is Cash, not rent; at the threshold the categoriser says Rent', () {
      final cz = Categorizer(rentCashThreshold: _st.rentCashThreshold);
      Tx atm(String id, String date, int cents) => Tx(
          id: id,
          source: 'pbz',
          date: date,
          amount: cents,
          bankType: 'Isplata ATM',
          description: 'PBZ ATM SYNTHETIC',
          kindHint: TxKind.atm);
      final under = [
        cz.categorize(atm('u1', '2026-08-05', -(_st.rentCashThreshold - 1))),
        cz.categorize(atm('u2', '2026-09-05', -(_st.rentCashThreshold - 1))),
      ];
      expect(under.map((t) => t.category), ['Cash', 'Cash']);
      expect(_suggest(under).rent, isNull, reason: 'the amount never chooses the category');
      final atThreshold = [
        cz.categorize(atm('r1', '2026-08-05', -_st.rentCashThreshold)),
        cz.categorize(atm('r2', '2026-09-05', -_st.rentCashThreshold)),
      ];
      expect(atThreshold.map((t) => t.category), ['Rent', 'Rent']);
      expect(_suggest(atThreshold).rent!.value, _st.rentCashThreshold);
    });

    test('a big flexible row (Shopping) is never rent whatever its amount', () {
      final s = _suggest([n2Cz('2026-08-05', -90000, 'Shopping'), n2Cz('2026-09-05', -90000, 'Shopping')]);
      expect(s.rent, isNull);
    });

    test('an owner category override to Rent counts', () {
      final cz = Categorizer();
      Tx row(String id, String date) =>
          Tx(id: id, source: 'pbz', date: date, amount: -30000, category: 'Rent', description: 'SYNTHETIC LANDLORD');
      final s = _suggest([cz.categorize(row('x1', '2026-08-01')), cz.categorize(row('x2', '2026-09-01'))]);
      expect(s.rent!.value, 30000);
    });
  });

  group('planProposals', () {
    Suggested sg(int v, String basis) => Suggested(value: v, basis: basis, evidence: const []);

    test('one proposal per non-null suggestion that differs; equal values and nulls are skipped', () {
      final s = PlanSuggestion(salary: sg(110000, 'salaryRows'), rent: sg(50000, 'rentRows'), loan: sg(25000, 'loanRows'));
      final p = planProposals(s, const WalletSettings(salary: 100000, rent: 50000));
      expect(p.map((x) => x.key).toSet(), {'salary', 'loan'});
      final salary = p.firstWhere((x) => x.key == 'salary');
      expect((salary.current, salary.suggested, salary.basis), (100000, 110000, 'salaryRows'));
      final loan = p.firstWhere((x) => x.key == 'loan');
      expect((loan.current, loan.suggested), (null, 25000), reason: '0 for money = unset = null');
    });

    test('everything equal gives no proposals; an empty suggestion gives none', () {
      expect(planProposals(const PlanSuggestion(), const WalletSettings()), isEmpty);
      final s = PlanSuggestion(salary: sg(100, 'salaryRows'));
      expect(planProposals(s, const WalletSettings(salary: 100)), isEmpty);
    });

    test('paydayDay: current is always the setting (the default 15 cannot be told from unset)', () {
      final s = PlanSuggestion(paydayDay: sg(10, 'paydayDates'));
      final p = planProposals(s, const WalletSettings()).single;
      expect((p.key, p.current, p.suggested, p.basis), ('paydayDay', 15, 10, 'paydayDates'));
      expect(planProposals(PlanSuggestion(paydayDay: sg(15, 'paydayDates')), const WalletSettings()), isEmpty);
    });

    test('nothing is written: planProposals takes only values', () {
      final s = PlanSuggestion(subs: sg(1500, 'confirmedBills'));
      const st = WalletSettings(subs: 900);
      final p = planProposals(s, st).single;
      expect((p.key, p.current, p.suggested), ('subs', 900, 1500));
      expect(st.subs, 900);
    });
  });

  group('budgetProposals', () {
    test('empty and zero fields first (by name), then changed ones (by name); equal values left out', () {
      final p = budgetProposals(
        {'Groceries': 30000, 'Eating out': 0, 'Shopping': 12000, 'Sport & fitness': 5000, 'Health & care': 700},
        {
          'Groceries': 30000,
          'Eating out': 15000,
          'Shopping': 20000,
          'Car & transport': 8000,
          'Games & apps': 1000,
          'Sport & fitness': 4000
        },
      );
      expect(p.map((x) => x.category), ['Car & transport', 'Eating out', 'Games & apps', 'Shopping', 'Sport & fitness']);
      expect(p.map((x) => x.fillsEmpty), [true, true, true, false, false]);
      expect(p.map((x) => x.current), [null, null, null, 12000, 5000]);
      expect(p.map((x) => x.suggested), [8000, 15000, 1000, 20000, 4000]);
    });

    test('a current category without a suggestion is ignored; empty maps give nothing', () {
      expect(budgetProposals({'Groceries': 100}, const {}), isEmpty);
      expect(budgetProposals(const {}, const {}), isEmpty);
      expect(budgetProposals({'Groceries': 100}, {'Groceries': 100}), isEmpty);
    });

    test('a lowered suggestion is still a proposal (differs), not an empty fill', () {
      final p = budgetProposals({'Groceries': 50000}, {'Groceries': 30000}).single;
      expect((p.current, p.suggested, p.fillsEmpty), (50000, 30000, false));
    });
  });
}
