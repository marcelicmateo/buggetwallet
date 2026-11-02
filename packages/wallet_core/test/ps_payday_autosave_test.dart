// PS: payday auto-save, written from docs/context/PS_SPEC.md (Core + Tests (money)). All data is SYNTHETIC.
// Setup: salary 2000.00, rent 500.00, loan 200.00, subs 50.00 -> fixed plan 75000, so with no goals the period's
// flexible money is 125000 (the period 2026-01-15 .. 2026-02-15, end exclusive).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _st = WalletSettings(salary: 200000, rent: 50000, loan: 20000, subs: 5000, periodStart: '2026-01-15');
const _p = '2026-01-15';
const _e = '2026-02-15';
const _p2 = '2026-02-15';

int _h = 5000000000000;
int _wall() => _h;

WalletRepo _repo() => WalletRepo.inMemory(now: _wall);

String _goal(WalletRepo r, {int saved = 10000, int monthly = 5000, String name = 'Synthetic goal'}) =>
    r.saveGoal(name: name, target: 100000, saved: saved, monthly: monthly);

int _saved(WalletRepo r, String id) => r.goals().firstWhere((g) => g.id == id).saved;

PeriodBudget _pb(WalletRepo r) => computePeriod(
      const [],
      _st,
      r.goals(),
      '2026-01-20',
      table: CategoryTable.builtIn,
      goalAmounts: r.goalPeriodAmounts(_p),
      goalTakenOut: r.goalTakenOutBetween(_p, _e),
    );

/// Sends everything [from] has not exported to [to] (a one-way sync of the outbox).
void _push(WalletRepo from, WalletRepo to) => to.applyRemote([for (final (_, op) in from.pendingOps()) op]);

List<String> _ids(WalletRepo r) => [for (final (_, op) in r.pendingOps()) op.id];

void main() {
  late WalletRepo r;
  setUp(() => r = _repo());
  tearDown(() => r.close());

  group('payGoals', () {
    test('writes monthly once per period: calling twice does not pay twice', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      expect(_saved(r, g), 15000);
      r.payGoals(period: _p);
      expect(_saved(r, g), 15000);
      r.payGoals(period: _p2);
      expect(_saved(r, g), 20000, reason: 'a new period pays again');
    });

    test('goal with monthly 0 gets no row', () {
      final g = _goal(r, monthly: 0);
      final before = r.pendingOps().length;
      r.payGoals(period: _p);
      expect(_saved(r, g), 10000);
      expect(r.pendingOps().length, before);
      expect(r.goalPeriodAmounts(_p)[g], 0);
    });

    test('new goal mid-period is paid once; the goal already paid is not paid again', () {
      final a = _goal(r, name: 'First');
      r.payGoals(period: _p);
      final b = _goal(r, saved: 0, monthly: 3000, name: 'Second');
      r.payGoals(period: _p);
      r.payGoals(period: _p);
      expect(_saved(r, a), 15000);
      expect(_saved(r, b), 3000);
    });

    test('pay row id is pay:<goalId>:<period>', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      expect(_ids(r), contains('pay:$g:$_p'));
    });

    test('a pay row keeps the amount even if monthly changes later in the period', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.saveGoal(id: g, name: 'Synthetic goal', target: 100000, saved: 15000, monthly: 9000);
      r.payGoals(period: _p);
      expect(_saved(r, g), 15000);
      expect(r.goalPeriodAmounts(_p)[g], 5000);
    });

    test('a deleted goal is not paid', () {
      final g = _goal(r);
      r.deleteGoal(g);
      r.payGoals(period: _p);
      expect(r.goals(), isEmpty);
      expect(_ids(r).where((i) => i.startsWith('pay:$g')), isEmpty);
    });
  });

  group('two devices', () {
    test('both auto-pay the same period: counted once after sync, in either direction', () {
      final a = r;
      final b = _repo();
      final g = _goal(a);
      _push(a, b);
      a.payGoals(period: _p);
      b.payGoals(period: _p);
      _push(a, b);
      _push(b, a);
      expect(_saved(a, g), 15000);
      expect(_saved(b, g), 15000);
      expect(a.goalPeriodAmounts(_p)[g], 5000);
      expect(b.goalPeriodAmounts(_p)[g], 5000);
      b.close();
    });

    test('skip on one device after auto-pay on both: converge on the skip', () {
      final a = r;
      final b = _repo();
      final g = _goal(a);
      _push(a, b);
      a.payGoals(period: _p);
      b.payGoals(period: _p);
      a.setGoalPeriodAmount(g, _p, 0);
      _push(a, b);
      _push(b, a);
      expect(_saved(a, g), 10000);
      expect(_saved(b, g), 10000);
      expect(b.goalPeriodAmounts(_p)[g], 0);
      b.close();
    });

    test('take out to spending on one device shows on the other: total down, taken-out sum equal', () {
      final a = r;
      final b = _repo();
      final g = _goal(a);
      _push(a, b);
      a.takeOutOfGoal(g, 4000, date: '2026-01-20');
      _push(a, b);
      expect(_saved(b, g), 6000);
      expect(b.goalTakenOutBetween(_p, _e), 4000);
      b.close();
    });

    test('a move arrives whole: both goals change on the other device', () {
      final a = r;
      final b = _repo();
      final g1 = _goal(a);
      final g2 = _goal(a, saved: 0, monthly: 0, name: 'Other');
      _push(a, b);
      a.takeOutOfGoal(g1, 3000, date: '2026-01-20', toGoalId: g2);
      _push(a, b);
      expect(_saved(b, g1), 7000);
      expect(_saved(b, g2), 3000);
      b.close();
    });
  });

  group('setGoalPeriodAmount', () {
    test('skip: total and spending money move by exactly the amount', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      expect(_saved(r, g), 15000);
      expect(_pb(r).flexBudget, 120000);
      r.setGoalPeriodAmount(g, _p, 0);
      expect(_saved(r, g), 10000);
      expect(r.goalPeriodAmounts(_p)[g], 0);
      expect(_pb(r).goalMonthly, 0);
      expect(_pb(r).flexBudget, 125000);
    });

    test('lower: 5000 -> 2000 moves total by -3000 and spending money by +3000', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(g, _p, 2000);
      expect(_saved(r, g), 12000);
      expect(r.goalPeriodAmounts(_p)[g], 2000);
      expect(_pb(r).flexBudget, 123000);
    });

    test('lower twice: the last call wins (adj overwritten, not summed)', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(g, _p, 2000);
      r.setGoalPeriodAmount(g, _p, 3500);
      expect(_saved(r, g), 13500);
      expect(r.goalPeriodAmounts(_p)[g], 3500);
      r.setGoalPeriodAmount(g, _p, 0);
      expect(_saved(r, g), 10000);
    });

    test('raising above the pay amount works (adj positive)', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(g, _p, 8000);
      expect(_saved(r, g), 18000);
      expect(_pb(r).flexBudget, 117000);
    });

    test('setting the pay amount again leaves the total unchanged', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(g, _p, 1000);
      r.setGoalPeriodAmount(g, _p, 5000);
      expect(_saved(r, g), 15000);
      expect(r.goalPeriodAmounts(_p)[g], 5000);
    });

    test('writes the pay row first when it is missing, then the adj; payGoals afterwards adds nothing', () {
      final g = _goal(r);
      r.setGoalPeriodAmount(g, _p, 1000);
      expect(_saved(r, g), 11000);
      r.payGoals(period: _p);
      expect(_saved(r, g), 11000);
      expect(_ids(r), containsAll(['pay:$g:$_p', 'adj:$g:$_p']));
    });

    test('only that period changes: the next period is paid in full', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(g, _p, 0);
      r.payGoals(period: _p2);
      expect(_saved(r, g), 15000);
    });

    test('negative amount is refused with ArgumentError and changes nothing', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      expect(() => r.setGoalPeriodAmount(g, _p, -1), throwsArgumentError);
      expect(_saved(r, g), 15000);
      expect(r.goalPeriodAmounts(_p)[g], 5000);
    });

    test('over Goal.maxContribution is refused', () {
      final g = _goal(r, saved: 0);
      r.payGoals(period: _p);
      expect(() => r.setGoalPeriodAmount(g, _p, Goal.maxContribution + 1), throwsArgumentError);
      expect(_saved(r, g), 5000);
    });

    test('unknown goal and deleted goal are refused', () {
      expect(() => r.setGoalPeriodAmount('nope', _p, 100), throwsArgumentError);
      final g = _goal(r);
      r.deleteGoal(g);
      expect(() => r.setGoalPeriodAmount(g, _p, 100), throwsArgumentError);
    });

    test('lowering is refused when the saved total would go below 0', () {
      final g = _goal(r, saved: 0, monthly: 5000);
      r.payGoals(period: _p); // total 5000
      r.takeOutOfGoal(g, 5000, date: '2026-01-20'); // total 0
      expect(_saved(r, g), 0);
      expect(() => r.setGoalPeriodAmount(g, _p, 0), throwsArgumentError, reason: 'would make the total -5000');
      expect(_saved(r, g), 0);
      expect(r.goalPeriodAmounts(_p)[g], 5000);
    });
  });

  group('goalPeriodAmounts', () {
    test('without a pay row: monthly; with: pay + adj', () {
      final g = _goal(r);
      final z = _goal(r, monthly: 0, name: 'Zero');
      expect(r.goalPeriodAmounts(_p), {g: 5000, z: 0});
      r.payGoals(period: _p);
      expect(r.goalPeriodAmounts(_p), {g: 5000, z: 0});
      r.setGoalPeriodAmount(g, _p, 1200);
      expect(r.goalPeriodAmounts(_p), {g: 1200, z: 0});
    });

    test('lists live goals only', () {
      final g = _goal(r);
      final d = _goal(r, name: 'Gone');
      r.deleteGoal(d);
      expect(r.goalPeriodAmounts(_p).keys, [g]);
    });

    test('periods are independent', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(g, _p, 0);
      expect(r.goalPeriodAmounts(_p)[g], 0);
      expect(r.goalPeriodAmounts(_p2)[g], 5000);
    });
  });

  group('takeOutOfGoal', () {
    test('to spending: this period\'s spending money +X, saved total -X', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      expect(_pb(r).flexBudget, 120000);
      r.takeOutOfGoal(g, 4000, date: '2026-01-20');
      expect(_saved(r, g), 11000);
      expect(r.goalTakenOutBetween(_p, _e), 4000);
      final pb = _pb(r);
      expect(pb.goalTakenOut, 4000);
      expect(pb.flexBudget, 124000);
    });

    test('a take-out dated in the next period does not change this one', () {
      final g = _goal(r);
      r.payGoals(period: _p);
      r.takeOutOfGoal(g, 4000, date: '2026-02-16');
      expect(_pb(r).flexBudget, 120000);
      expect(_saved(r, g), 11000);
    });

    test('move to another goal: totals shift, spending money unchanged', () {
      final a = _goal(r);
      final b = _goal(r, saved: 2000, monthly: 0, name: 'Other');
      r.payGoals(period: _p);
      final before = _pb(r).flexBudget;
      r.takeOutOfGoal(a, 3000, date: '2026-01-20', toGoalId: b);
      expect(_saved(r, a), 12000);
      expect(_saved(r, b), 5000);
      expect(_pb(r).flexBudget, before);
      expect(r.goalTakenOutBetween(_p, _e), 0);
    });

    test('more than saved is refused and changes nothing', () {
      final g = _goal(r, saved: 1000, monthly: 0);
      expect(() => r.takeOutOfGoal(g, 1001, date: '2026-01-20'), throwsArgumentError);
      expect(_saved(r, g), 1000);
      expect(r.goalTakenOutBetween(_p, _e), 0);
      final h = _goal(r, saved: 0, monthly: 0, name: 'Other');
      expect(() => r.takeOutOfGoal(g, 1001, date: '2026-01-20', toGoalId: h), throwsArgumentError);
      expect(_saved(r, h), 0);
      expect(_saved(r, g), 1000);
    });

    test('exactly the saved total is allowed and leaves 0', () {
      final g = _goal(r, saved: 1000, monthly: 0);
      r.takeOutOfGoal(g, 1000, date: '2026-01-20');
      expect(_saved(r, g), 0);
    });

    test('0 and negative amounts are refused', () {
      final g = _goal(r);
      expect(() => r.takeOutOfGoal(g, 0, date: '2026-01-20'), throwsArgumentError);
      expect(() => r.takeOutOfGoal(g, -5, date: '2026-01-20'), throwsArgumentError);
      expect(_saved(r, g), 10000);
    });

    test('moving to the same goal is refused', () {
      final g = _goal(r);
      expect(() => r.takeOutOfGoal(g, 100, date: '2026-01-20', toGoalId: g), throwsArgumentError);
      expect(_saved(r, g), 10000);
    });
  });

  group('goalTakenOutBetween', () {
    test('start date included, end date excluded; sums several rows as a positive number', () {
      final g = _goal(r, saved: 50000, monthly: 0);
      r.takeOutOfGoal(g, 100, date: '2026-01-14');
      r.takeOutOfGoal(g, 200, date: '2026-01-15');
      r.takeOutOfGoal(g, 400, date: '2026-02-14');
      r.takeOutOfGoal(g, 800, date: '2026-02-15');
      expect(r.goalTakenOutBetween(_p, _e), 600);
      expect(r.goalTakenOutBetween(_e, '2026-03-15'), 800);
    });

    test('moves, pay and adj rows are not counted; empty range is 0', () {
      final a = _goal(r);
      final b = _goal(r, name: 'Other');
      r.payGoals(period: _p);
      r.setGoalPeriodAmount(a, _p, 0);
      r.takeOutOfGoal(a, 500, date: '2026-01-20', toGoalId: b);
      expect(r.goalTakenOutBetween(_p, _e), 0);
      expect(r.goalTakenOutBetween(_p, _p), 0);
    });
  });

  group('computePeriod with goalAmounts / goalTakenOut', () {
    const goals = [
      Goal(id: 'a', name: 'A', target: 100000, saved: 0, monthly: 5000),
      Goal(id: 'b', name: 'B', target: 100000, saved: 0, monthly: 3000),
    ];
    PeriodBudget pb({Map<String, int>? amounts, int? out}) => computePeriod(const [], _st, goals, '2026-01-20',
        table: CategoryTable.builtIn, goalAmounts: amounts ?? const {'a': 5000, 'b': 3000}, goalTakenOut: out ?? 0);

    test('defaults (no goalAmounts / goalTakenOut): monthly of every goal, taken out 0', () {
      final p = computePeriod(const [], _st, goals, '2026-01-20', table: CategoryTable.builtIn);
      expect(p.goalMonthly, 8000);
      expect(p.goalTakenOut, 0);
      expect(p.flexBudget, 125000 - 8000);
      expect(p.planSplit.saved, 8000);
    });

    test('goalMonthly is the sum of goalAmounts; taken out is added to flexBudget', () {
      final p = pb(amounts: {'a': 1000, 'b': 0}, out: 2500);
      expect(p.goalMonthly, 1000);
      expect(p.goalTakenOut, 2500);
      expect(p.flexBudget, 125000 - 1000 + 2500);
      expect(p.planSplit.saved, 1000);
    });

    test('flexBudget formula holds term by term', () {
      final p = pb(amounts: {'a': 4000, 'b': 3000}, out: 700);
      expect(p.flexBudget, p.income - p.fixedPlan - p.goalMonthly - p.reservedBills - p.reservedPlanned + p.landedIncome + p.goalTakenOut);
    });

    test('all goals skipped and money taken out: spending money is 125000 + taken out', () {
      expect(pb(amounts: {'a': 0, 'b': 0}, out: 1500).flexBudget, 126500);
    });
  });
}
