// ENG E6 (ENG_UI_SPEC §5.5, §6.5): loans (schema 21): schedule, state, what-if, payment matching, the plan's loan lines,
// the old single loan's migration and "I bought it" with its Undo. Literals were computed outside Dart with exact
// fractions (Python Fraction, round half away from zero) by the same rules. All data SYNTHETIC.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

// 10 000.00 at 6 % over 12 months from 15 Jan 2026: 860.66 a month (the textbook example), last month 860.70.
const _l = Loan(id: 'l1', name: 'Car', principal: 1000000, rateBp: 600, months: 12, firstDue: '2026-01-15');

void main() {
  group('loanSchedule', () {
    test('the textbook loan: 860.66 a month, the last pays the exact rest, balance ends at 0', () {
      final s = loanSchedule(_l, const [], const []);
      expect(s.length, 12);
      expect(s.take(11).map((m) => m.paid).toSet(), {86066});
      expect([s.last.paid, s.last.interest, s.last.balance], [86070, 428, 0]);
      expect(s.fold<int>(0, (a, m) => a + m.interest), 32796);
      expect(s.fold<int>(0, (a, m) => a + m.principal), 1000000);
      expect([s.first.due, s[1].due, s.last.due], ['2026-01-15', '2026-02-15', '2026-12-15']);
      expect(s.first.interest, 5000); // round(1 000 000 × 600 / 120 000)
    });

    test('0 %: loan ÷ months rounded up, the last one smaller', () {
      final s = loanSchedule(const Loan(id: 'z', principal: 1000000, rateBp: 0, months: 7, firstDue: '2026-01-31'), const [], const []);
      expect(s.map((m) => m.paid), [...List.filled(6, 142858), 142852]);
      expect(s.map((m) => m.due).take(3), ['2026-01-31', '2026-02-28', '2026-03-31'], reason: 'day clamped to the month');
      expect(s.last.balance, 0);
    });

    test('the lender\'s payment is used as written; unknown principal/length/first due = no schedule', () {
      final s = loanSchedule(
          const Loan(id: 'p', principal: 1000000, rateBp: 600, months: 12, firstDue: '2026-01-15', payment: 100000), const [], const []);
      expect(s.first.paid, 100000);
      expect(s.length, lessThan(12), reason: 'a larger payment ends it early, the last one pays the rest');
      expect(s.last.balance, 0);
      expect(loanSchedule(const Loan(id: 'x', payment: 5000), const [], const []), isEmpty);
    });

    test('a balance check mid-way: the schedule goes on from the lender\'s balance and still ends at 0', () {
      const check = LoanCheck(loanId: 'l1', date: '2026-06-20', balance: 500000);
      final s = loanSchedule(_l, const [], const [check]);
      expect(s[5].balance, 500000);
      expect(s.skip(6).map((m) => (m.paid, m.interest, m.balance)), [
        (86066, 2500, 416434),
        (86066, 2082, 332450),
        (86066, 1662, 248046),
        (86066, 1240, 163220),
        (86066, 816, 77970),
        (78360, 390, 0),
      ]);
      const before = LoanCheck(loanId: 'l1', date: '2026-01-02', balance: 600000);
      expect(loanSchedule(_l, const [], const [before]).first.interest, 3000, reason: 'a check before the first due starts from it');
    });

    test('a rate change mid-way: payment recomputed over the months left (or as the lender wrote it)', () {
      const r = LoanRate(loanId: 'l1', from: '2026-07-01', rateBp: 1200);
      final s = loanSchedule(_l, const [r], const []);
      expect(s.take(6).every((m) => m.rateBp == 600), isTrue);
      expect(s.skip(6).map((m) => (m.rateBp, m.paid)).take(2), [(1200, 87565), (1200, 87565)]);
      expect([s.last.paid, s.last.balance], [87567, 0]);
      expect(s.fold<int>(0, (a, m) => a + m.interest), 41788);
      const given = LoanRate(loanId: 'l1', from: '2026-07-01', rateBp: 1200, payment: 90000);
      expect(loanSchedule(_l, const [given], const [])[6].paid, 90000);
    });
  });

  group('loanWhatIf', () {
    test('extra monthly: 2 months and 58.42 interest saved', () {
      final w = loanWhatIf(_l, extraMonthly: 20000);
      expect([w.monthsSaved, w.interestSaved, w.newPayment], [2, 5842, null]);
    });
    test('extra once from a date: on the first due date on or after it', () {
      final w = loanWhatIf(_l, extraOnce: 300000, extraOnceDate: '2026-04-01');
      expect([w.monthsSaved, w.interestSaved], [3, 10136]);
    });
    test('a new rate from a date gives the new payment; nothing changed = nothing saved', () {
      final w = loanWhatIf(_l, newRateBp: 1200, newRateFrom: '2026-07-01');
      expect([w.newPayment, w.monthsSaved, w.interestSaved], [87565, 0, 32796 - 41788]);
      expect([loanWhatIf(_l).monthsSaved, loanWhatIf(_l).interestSaved], [0, 0]);
    });
  });

  group('loanState', () {
    final s = loanSchedule(_l, const [], const []);
    test('paid months, not seen yet (due + 3 days), owed now, interest paid and to pay', () {
      final st = loanState(s, ['2026-01-01', '2026-02-14', '2026-02-20', '2026-03-17'], '2026-05-01');
      expect(st.paidMonths, 3, reason: 'two payments in one month\'s window count once');
      expect(st.notSeen, ['2026-04-15']);
      expect([st.owedNow, st.monthsLeft, st.payoffMonth, st.interestPaid, st.interestToPay], [755584, 9, '2026-12', 13782, 32796 - 13782]);
    });
    test('the due date + 3 days is not yet "not seen"; nothing paid = the whole loan owed', () {
      final st = loanState(s, const [], '2026-01-18');
      expect([st.paidMonths, st.notSeen, st.owedNow, st.monthsLeft], [0, <String>[], 1000000, 12]);
      expect(loanState(s, const [], '2026-01-19').notSeen, ['2026-01-15']);
    });
  });

  group('loanPayments (never by amount alone)', () {
    Tx row(String id, String date, int amount, String desc, {String currency = 'EUR', bool manual = false}) =>
        Tx(id: id, source: 'pbz', date: date, amount: amount, description: desc, currency: currency, manual: manual);
    final lender = row('a', '2026-01-15', -86066, 'SYNTH BANK LOAN');
    final key = merchantKey(lender);

    test('by payee key or by reference; another payee with the same amount is not a payment', () {
      final loan = Loan(id: 'l1', principal: 1000000, rateBp: 600, months: 12, firstDue: '2026-01-15', payment: 86066, payeeKey: key);
      final rows = [
        lender,
        row('b', '2026-02-15', -86066, 'SYNTH SHOP'), // same amount, other payee
        row('c', '2026-02-16', -86066, 'SYNTH BANK LOAN', currency: 'USD'),
        row('d', '2026-02-17', -86066, 'SYNTH BANK LOAN', manual: true),
        row('e', '2025-12-01', -86066, 'SYNTH BANK LOAN'), // before first due − 15
      ];
      expect(loanPayments(loan, const [], rows, currency: 'EUR').map((m) => m.txId), ['a']);
    });

    test('matched by reference with a changed amount: still matched, flagged "amount changed"', () {
      const loan =
          Loan(id: 'l1', principal: 1000000, rateBp: 600, months: 12, firstDue: '2026-01-15', payment: 86066, reference: 'hr12-3456');
      final rows = [
        row('a', '2026-01-15', -86066, 'TRANSFER HR12-3456 SYNTH'),
        row('b', '2026-02-15', -88000, 'Transfer hr12-3456'),
      ];
      final m = loanPayments(loan, const [], rows, currency: 'EUR');
      expect(m.map((x) => (x.txId, x.amount, x.amountChanged)), [('a', 86066, false), ('b', 88000, true)]);
      const r = LoanRate(loanId: 'l1', from: '2026-02-01', rateBp: 700, payment: 88000);
      expect(loanPayments(loan, const [r], rows, currency: 'EUR').last.amountChanged, isFalse, reason: 'the new payment');
    });
  });

  group('repo: loans in the plan, migration, bought and its Undo', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch));
    tearDown(() => repo.close());

    test('open loans add their payment in force to the fixed plan; a closed or deleted one leaves it', () {
      repo.updateSettings({'salary': 300000, 'rent': 50000});
      expect(repo.settings().loanPlan, 0);
      final a = repo.addLoan(const Loan(id: '', name: 'Car', payment: 20000));
      final b = repo.addLoan(const Loan(id: '', name: 'Boat', payment: 10000));
      expect(repo.settings().loanLines, {a: 20000, b: 10000});
      expect(monthlyFlex(repo.settings()), 300000 - 50000 - 30000);
      repo.addLoanRate(a, from: '2026-10-01', rateBp: 500, payment: 21000);
      repo.addLoanRate(a, from: '2027-01-01', rateBp: 600, payment: 25000); // not in force yet
      expect(repo.settings().loanPlan, 31000);
      repo.patch(LoanCols.entity, b, <Col, Object?>{LoanCols.closedAt: '2026-11-01'});
      expect(repo.settings().loanPlan, 21000, reason: 'a paid-off loan leaves the plan');
      repo.deleteLoan(a);
      expect(repo.settings().loanPlan, 0);
      final st = repo.settings();
      expect(WalletSettings.fromMap(st.toMap()).loanPlan, st.loanPlan, reason: 'the app round-trips settings');
    });

    test('refused: a bad value, a rate or check for an unknown loan; nothing written', () {
      final before = repo.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'];
      expect(() => repo.addLoan(const Loan(id: '', months: 0)), throwsArgumentError);
      expect(() => repo.addLoan(const Loan(id: '', payment: -5)), throwsArgumentError);
      expect(() => repo.addLoanRate('nope', from: '2026-01-01', rateBp: 1), throwsArgumentError);
      expect(() => repo.addLoanCheck('nope', date: '2026-01-01', balance: 1), throwsArgumentError);
      expect(repo.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'], before);
    });

    test('rates and checks feed the schedule', () {
      final id = repo.addLoan(_l);
      repo.addLoanCheck(id, date: '2026-06-20', balance: 500000);
      final s = loanSchedule(repo.loans().single, repo.loanRates(id), repo.loanChecks(id));
      expect([s[5].balance, s.last.balance, s.last.paid], [500000, 0, 78360]);
    });

    test('"I bought it" and its Undo: one write each, Undo restores goal, loan, plan line and tag rows', () async {
      repo.updateSettings({'salary': 300000});
      final txId = repo.addTransaction(date: '2026-10-20', amount: -500000, category: 'Shopping');
      final gid = repo.saveGoal(name: 'Synth car', target: 1000000, saved: 600000, monthly: 25000);
      repo.patch(GoalCols.entity, gid, <Col, Object?>{GoalCols.price: 2000000, GoalCols.depositPermille: 300});
      final goalBefore = repo.goals().single;
      final flexBefore = monthlyFlex(repo.settings(), goals: repo.goals());
      final v = repo.dataVersion;

      final loanId = repo.buyGoal(gid,
          date: '2026-11-01', purchaseTxIds: [txId], loan: const Loan(id: '', principal: 1400000, rateBp: 500, months: 60, payment: 26420));
      expect(repo.dataVersion, v + 1, reason: 'one write');
      final g = repo.goals().single;
      expect([g.boughtAt, g.loanId, g.monthly], ['2026-11-01', loanId, 0]);
      final loan = repo.loans().single;
      expect([loan.name, loan.goalId, loan.payment], ['Synth car', gid, 26420]);
      final tag = repo.tagTable().liveIds.single;
      expect(loan.tagId, tag);
      expect(repo.categorizer().categorize(repo.transaction(txId)!).tags, [tag]);
      expect(repo.settings().loanPlan, 26420);
      expect(() => repo.buyGoal(gid, date: '2026-11-01'), throwsArgumentError);

      repo.undoBuyGoal(gid);
      expect(repo.dataVersion, v + 2, reason: 'one write');
      final back = repo.goals().single;
      expect([back.boughtAt, back.loanId, back.monthly, back.price, back.depositPermille],
          [null, null, goalBefore.monthly, goalBefore.price, goalBefore.depositPermille]);
      expect(repo.loans(), isEmpty);
      expect(repo.settings().loanPlan, 0);
      expect(repo.tagTable().liveIds, isEmpty);
      expect(repo.categorizer().categorize(repo.transaction(txId)!).tags, isEmpty);
      expect(monthlyFlex(repo.settings(), goals: repo.goals()), flexBefore);
      expect(() => repo.undoBuyGoal(gid), throwsArgumentError);
    });

    test('bought with an existing tag of that name: reused, Undo only turns off the links it added', () async {
      final tag = await repo.addTag('Synth car');
      final a = repo.addTransaction(date: '2026-10-20', amount: -100, category: 'Shopping');
      final b = repo.addTransaction(date: '2026-10-21', amount: -200, category: 'Shopping');
      await repo.setTxTag(a, tag, true);
      final gid = repo.saveGoal(name: 'Synth car', target: 0, saved: 0, monthly: 0);
      expect(repo.buyGoal(gid, date: '2026-11-01', purchaseTxIds: [a, b]), isNull, reason: 'paid in full: no loan');
      repo.undoBuyGoal(gid);
      final cz = repo.categorizer();
      expect([
        cz.categorize(repo.transaction(a)!).tags,
        cz.categorize(repo.transaction(b)!).tags
      ], [
        [tag],
        <String>[]
      ]);
      expect(repo.tagTable().isLive(tag), isTrue);
    });
  });

  test('schema 20 → 21: the old single loan becomes one loan row, counted once; loanLeft keeps working', () {
    final dir = Directory.systemTemp.createTempSync('bw-eng-loan-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/w.db';
    int now() => DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    var r = WalletRepo.open(path, now: now);
    r.updateSettings({'salary': 300000, 'loan': 40000, 'loanEnd': '2027-03', 'paydayDay': 15});
    final leftBefore = loanLeft(r.settings(), '2026-11-02');
    final flexBefore = monthlyFlex(r.settings());
    r.db.execute("UPDATE meta SET value = '20' WHERE key = 'schema'");
    r.close();
    r = WalletRepo.open(path, now: now);
    addTearDown(r.close);
    final l = r.loans().single;
    expect([l.id, l.payment, l.principal, l.rateBp, l.months, l.firstDue], [Loan.legacyId, 40000, null, null, null, null]);
    expect(r.settings().loanPlan, 40000, reason: 'the row replaces the setting, never both');
    expect(monthlyFlex(r.settings()), flexBefore);
    expect(loanLeft(r.settings(), '2026-11-02')?.cents, leftBefore?.cents);
    expect(r.pendingOps().where((o) => o.$2.entity == 'loan').length, 1, reason: 'the migration syncs');
    r.patch(LoanCols.entity, Loan.legacyId, <Col, Object?>{LoanCols.closedAt: '2026-11-01'});
    expect(r.settings().loanPlan, 0, reason: 'closed: the old setting does not come back');
  });

  test('two devices: a loan, its rate row and its check sync', () async {
    final net = Net();
    final key = VaultKey.generate();
    var now = DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    final a = Device('a', null, key, () => now, net: net), b = Device('b', null, key, () => now, net: net);
    addTearDown(() {
      a.close();
      b.close();
    });
    final id = a.repo.addLoan(_l);
    a.repo.addLoanRate(id, from: '2026-07-01', rateBp: 1200);
    a.repo.addLoanCheck(id, date: '2026-06-20', balance: 500000);
    now += 1000;
    await a.run();
    await b.run();
    b.repo.patch(LoanCols.entity, id, <Col, Object?>{LoanCols.reference: 'hr12-3456'});
    now += 1000;
    await b.run();
    await a.run();
    for (final d in [a, b]) {
      final s = loanSchedule(d.repo.loans().single, d.repo.loanRates(id), d.repo.loanChecks(id));
      expect([s.length, s.last.balance, d.repo.loans().single.reference], [12, 0, 'hr12-3456'], reason: d.name);
    }
  });
}
