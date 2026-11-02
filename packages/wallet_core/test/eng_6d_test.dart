// ENG E6d (ENG_UI_SPEC §5.5, §6.5): the helpers the loan/goal screens use so the app does no money maths (balance on a
// date, years, balance check, levers, one-write goal), the loan-end finding and suggestion, and Project "Skip". The
// textbook loan's literals are those of eng_loans_test.dart. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/t1.dart' show tagged;

const _today = '2026-11-02';

// 10 000.00 at 6 % over 12 months: 860.66 a month, the first month 50.00 interest.
Loan _loan({String id = 'l1', String first = '2026-01-15', String? closedAt}) =>
    Loan(id: id, name: 'Car', principal: 1000000, rateBp: 600, months: 12, firstDue: first, closedAt: closedAt);

int _sum(Iterable<int> xs) => xs.fold(0, (a, b) => a + b);

void main() {
  group('exports', () {
    test('addMonths and the reference rule', () {
      expect([addMonths('2026-11', 2), addMonths('2026-01', -1)], ['2027-01', '2025-12']);
      expect(loanReferenceMinLength, 4);
      expect([loanReferenceUsable(null), loanReferenceUsable('  abc  '), loanReferenceUsable(' AbČd '), loanReferenceUsable('ŠĐ12')],
          [false, false, true, true]);
    });
  });

  group('loanBalanceOn', () {
    final s = loanSchedule(_loan(), const [], const []);
    test('before, on, between and after the due dates', () {
      expect(loanBalanceOn(s, '2026-01-14'), 1000000, reason: 'before the first: the principal');
      expect(loanBalanceOn(s, '2026-01-15'), 918934, reason: 'on the due date: after it (1 000 000 + 5 000 − 86 066)');
      expect(loanBalanceOn(s, '2026-02-14'), 918934);
      expect(loanBalanceOn(s, '2026-02-15'), s[1].balance);
      expect(loanBalanceOn(s, '2026-12-15'), 0);
      expect(loanBalanceOn(s, '2030-01-01'), 0);
      expect(loanBalanceOn(const [], _today), 0);
    });

    test('after a balance check the schedule goes on from it', () {
      final c = loanSchedule(_loan(), const [], const [LoanCheck(loanId: 'l1', date: '2026-06-20', balance: 500000)]);
      expect(loanBalanceOn(c, '2026-06-20'), 500000);
      expect(loanBalanceOn(c, '2026-07-15'), 416434, reason: '500 000 + 2 500 interest − 86 066');
      expect(loanBalanceOn(c, '2026-06-14'), s[4].balance, reason: 'before the check: the schedule as it was');
    });

    test('a check before the first due date is the opening balance; one in the first month leaves it', () {
      final pre = loanSchedule(_loan(), const [], const [LoanCheck(loanId: 'l1', date: '2026-01-10', balance: 900000)]);
      expect(loanBalanceOn(pre, '2026-01-01'), 900000);
      final first = loanSchedule(_loan(), const [], const [LoanCheck(loanId: 'l1', date: '2026-01-20', balance: 950000)]);
      expect([loanBalanceOn(first, '2026-01-14'), loanBalanceOn(first, '2026-01-20')], [1000000, 950000]);
    });
  });

  test('loanState and loanWhatIf start from the opening balance when a check falls in the first month', () {
    final checks = [const LoanCheck(loanId: 'l1', date: '2026-01-20', balance: 950000)];
    final s = loanSchedule(_loan(), const [], checks);
    expect(loanState(s, const [], '2026-01-01').owedNow, 1000000, reason: 'not the check + the first principal');
    final w = loanWhatIf(_loan(), checks: checks, newRateBp: 600, newRateFrom: '2026-01-01');
    expect(w.newPayment, 86066, reason: 'the same loan at the same rate: the same payment');
  });

  group('loanYears', () {
    test('per calendar year; Σ principal = principal borrowed − the final balance', () {
      final s = loanSchedule(_loan(first: '2026-07-15'), const [], const []);
      final y = loanYears(s);
      expect(y.map((e) => e.year), [2026, 2027]);
      expect(y.first.endBalance, s[5].balance);
      expect(y.last.endBalance, 0);
      expect(_sum(y.map((e) => e.principal)), 1000000);
      expect(_sum(y.map((e) => e.interest)), 32796);
      final part = loanYears(s.take(8).toList());
      expect(_sum(part.map((e) => e.principal)), 1000000 - part.last.endBalance);
      expect(loanYears(const []), isEmpty);
    });
  });

  group('loanCheckView', () {
    test('matches, more owed (+), less owed (−), no schedule', () {
      final at = loanBalanceOn(loanSchedule(_loan(), const [], const []), '2026-03-01');
      LoanCheckView v(int shown) => loanCheckView(_loan(), const [], const [], date: '2026-03-01', shownBalance: shown);
      expect([v(at).expected, v(at).diff, v(at).matches], [at, 0, true]);
      expect([v(at + 125).diff, v(at + 125).matches], [125, false]);
      expect([v(at - 1).diff, v(at - 1).matches], [-1, false]);
      final none = loanCheckView(const Loan(id: 'x', payment: 40000), const [], const [], date: _today, shownBalance: 100);
      expect([none.expected, none.diff, none.matches], [null, null, false]);
    });
  });

  group('goalPlan with levers', () {
    const g = Goal(id: 'g', name: 'Boat', price: 1000000, depositPermille: 200, costsPermille: 0);
    GoalPlan plan(int monthly, [List<GoalLever> applied = const []]) =>
        goalPlan(g, savedCents: 0, monthlyCents: monthly, toSpendPerPeriodCents: 0, today: _today, applied: applied);
    const a = GoalLever(GoalLeverKind.tag, 'Eating out', 5000, 0, null), b = GoalLever(GoalLeverKind.income, 'r1', 2500, 0, null);
    test('cuts add to the monthly amount', () {
      expect([plan(10000).months, plan(10000).monthly], [20, 10000]);
      final p = plan(10000, [a, b]);
      expect([p.monthly, p.months, p.readyMonth], [17500, 12, '2027-11'], reason: 'ceil(200 000 / 17 500)');
      expect([
        plan(0, [a]).monthly,
        plan(0, [a]).months
      ], [
        5000,
        40
      ]);
      expect(plan(-300, [a]).monthly, 5000, reason: 'a negative monthly counts as 0 under levers');
    });
  });

  group('findings: loanEnding', () {
    List<Finding> run(List<Loan> ls, {WalletSettings st = const WalletSettings()}) =>
        findings(const [], st, CategoryTable.builtIn, _today, loans: [for (final l in ls) (l, loanSchedule(l, const [], const []))]);
    test('payoff 6 months away fires, 7 does not; closed loans never', () {
      final six = run([_loan(first: '2026-06-15')]); // last due 2027-05-15
      expect(six.map((f) => (f.id, f.kind, f.subjectKey, f.n, f.to)),
          [('loanEnding:l1:2027-05', FindingKind.loanEnding, 'l1', 6, '2027-05-15')]);
      expect(six.single.series, [('payment', 86066)]);
      expect(run([_loan(first: '2026-07-15')]), isEmpty);
      expect(run([_loan(first: '2026-01-15')]).single.n, 1);
      expect(run([_loan(first: '2025-12-15')]).single.n, 0, reason: 'ends this month');
      expect(run([_loan(first: '2025-11-15')]), isEmpty, reason: 'the payoff month is past');
      expect(run([_loan(first: '2026-06-15', closedAt: '2026-10-01')]), isEmpty);
      expect(run([_loan(first: '2026-06-15')], st: const WalletSettings(dismissedFindings: ['loanEnding:l1:2027-05'])), isEmpty);
    });
  });

  group('loanEndedProposals', () {
    List<LoanEnded> run(String closed, {WalletSettings st = const WalletSettings()}) {
      final l = _loan(first: '2026-01-15', closedAt: closed);
      return loanEndedProposals([(l, loanSchedule(l, const [], const []))], st, _today);
    }

    test('within 60 days of closing, its line gone: the freed payment', () {
      expect(run('2026-09-03').map((e) => (e.id, e.loanId, e.closedAt, e.payment)), [('loanEnded:l1', 'l1', '2026-09-03', 86066)]);
      expect(run(_today).single.payment, 86066);
      expect(run('2026-09-02'), isEmpty, reason: '61 days');
      expect(run('2026-11-03'), isEmpty, reason: 'closed after today');
      expect(run('2026-10-01', st: const WalletSettings(loanLines: {'l1': 86066})), isEmpty, reason: 'its line still runs');
      expect(run('2026-10-01', st: const WalletSettings(dismissedFindings: ['loanEnded:l1'])), isEmpty);
      final open = _loan();
      expect(loanEndedProposals([(open, loanSchedule(open, const [], const []))], const WalletSettings(), _today), isEmpty);
    });

    test('a loan without a schedule frees its written payment', () {
      const l = Loan(id: 'legacy', payment: 40000, closedAt: '2026-10-15');
      expect(loanEndedProposals([(l, const <LoanMonth>[])], const WalletSettings(), _today).single.payment, 40000);
    });
  });

  group('two devices', () {
    late Net net;
    late VaultKey key;
    final now = DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, null, key, () => now, net: net);
      devices.add(d);
      return d;
    }

    setUp(() {
      net = Net();
      key = VaultKey.generate();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
    });

    test('addGoal: one write with every big-purchase field; the other device reads the same', () async {
      final a = device('a'), b = device('b');
      final ops = a.repo.pendingOps().length, v = a.repo.dataVersion;
      final id = a.repo
          .addGoal(name: 'Boat', price: 1000000, depositPermille: 200, costsPermille: 60, loanRateBp: 450, loanMonths: 60, monthly: 20000);
      expect([a.repo.pendingOps().length - ops, a.repo.dataVersion - v], [1, 1]);
      await a.run();
      await b.run();
      for (final d in [a, b]) {
        final g = d.repo.goals().single;
        expect([
          g.id,
          g.target,
          g.monthly,
          g.price,
          g.depositPermille,
          g.costsPermille,
          g.loanRateBp,
          g.loanMonths,
          g.compareLineId
        ], [
          id,
          260000,
          20000,
          1000000,
          200,
          60,
          450,
          60,
          null
        ], reason: '${d.name}: target = deposit + costs');
      }
      expect(() => a.repo.addGoal(name: 'X', depositPermille: 1001), throwsArgumentError);
      expect(a.repo.addGoal(name: 'Plain', target: 5000), isNotEmpty);
      expect([a.repo.goals().length, a.repo.goals().last.price, a.repo.goals().last.target], [2, null, 5000]);
    });

    test('Skip on an untagged Project candidate holds for good, on both devices', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Trip');
      final t1 = a.repo.addTransaction(date: '2026-10-05', amount: 1000, category: 'Groceries', note: 'Corner shop');
      final t2 = a.repo.addTransaction(date: '2026-10-06', amount: 1200, category: 'Groceries', note: 'Corner shop');
      await a.repo.setTxTag(t1, tag, true);
      List<String> candidates(WalletRepo r) {
        final ctx = r.tagContext();
        final rows = [
          for (final t in r.transactions()) tagged(t, 'Groceries', tagsOf(t, tags: ctx.tags, ruleTags: ctx.ruleTags, links: ctx.links))
        ];
        return projectStats(tag, rows, tags: ctx, table: CategoryTable.builtIn, currency: 'EUR', today: _today)
            .candidates
            .map((t) => t.id)
            .toList();
      }

      expect(candidates(a.repo), [t2]);
      final ops = a.repo.pendingOps().length;
      await a.repo.setTxTag(t2, tag, false); // "Skip": the row never had the tag
      expect(a.repo.pendingOps().length - ops, 1, reason: 'an off link is written');
      await a.repo.setTxTag(t2, tag, false);
      expect(a.repo.pendingOps().length - ops, 1, reason: 'already off: nothing more');
      await a.run();
      await b.run();
      for (final d in [a, b]) {
        expect(d.repo.tagLinks()[t2], {tag: false}, reason: d.name);
        expect(candidates(d.repo), isEmpty, reason: d.name);
      }
    });
  });
}
