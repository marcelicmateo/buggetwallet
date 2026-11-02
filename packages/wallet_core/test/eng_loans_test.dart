// ENG E6 (ENG_UI_SPEC §5.5, §6.5): loans (schema 21): schedule, state, what-if, payment matching, the plan's loan lines,
// the old single loan's migration and "I bought it" with its Undo. Literals were computed outside Dart with exact
// fractions (Python Fraction, round half away from zero) by the same rules. All data SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

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
    const byRef = Loan(id: 'l1', principal: 1000000, rateBp: 600, months: 12, firstDue: '2026-01-15', reference: 'hr12-3456');

    test('by payee key; another payee with the same amount, another currency, hand-added or too early: not a payment', () {
      final loan = Loan(id: 'l1', principal: 1000000, rateBp: 600, months: 12, firstDue: '2026-01-15', payeeKey: key);
      final rows = [
        lender,
        row('b', '2026-02-15', -86066, 'SYNTH SHOP'),
        row('c', '2026-02-16', -86066, 'SYNTH BANK LOAN', currency: 'USD'),
        row('d', '2026-02-17', -86066, 'SYNTH BANK LOAN', manual: true),
        row('e', '2025-12-01', -86066, 'SYNTH BANK LOAN'),
      ];
      expect(loanPayments(loan, const [], const [], rows, currency: 'EUR').map((m) => m.txId), ['a']);
    });

    test('matched by reference with a changed amount: still matched, flagged "amount changed"', () {
      final rows = [
        row('a', '2026-01-15', -86066, 'TRANSFER HR12-3456 SYNTH'),
        row('b', '2026-02-15', -88000, 'Transfer hr12-3456'),
      ];
      final m = loanPayments(byRef, const [], const [], rows, currency: 'EUR');
      expect(m.map((x) => (x.txId, x.amount, x.amountChanged)), [('a', 86066, false), ('b', 88000, true)]);
      const r = LoanRate(loanId: 'l1', from: '2026-02-01', rateBp: 700, payment: 88000);
      expect(loanPayments(byRef, const [r], const [], rows, currency: 'EUR').last.amountChanged, isFalse, reason: 'the new payment');
    });

    test('a rate row without a payment changes the expected amount (from the schedule); the last exact rest is not flagged', () {
      const r = LoanRate(loanId: 'l1', from: '2026-07-01', rateBp: 1200);
      final rows = [row('a', '2026-07-15', -87565, 'HR12-3456'), row('z', '2026-12-15', -87567, 'HR12-3456')];
      final m = loanPayments(byRef, const [r], const [], rows, currency: 'EUR');
      expect(m.map((x) => x.amountChanged), [false, false]);
      expect(loanPaymentOn(byRef, const [r], const [], '2026-07-10'), 87565);
      expect(loanPaymentOn(byRef, const [], const [], '2026-07-10'), 86066);
      expect(loanPayments(byRef, const [], const [], [row('y', '2026-12-15', -86070, 'HR12-3456')], currency: 'EUR').single.amountChanged,
          isFalse);
    });

    test('a reference shorter than 4 characters never matches and is refused when stored', () {
      const short = Loan(id: 's', payment: 100, reference: 'ab1');
      expect(loanPayments(short, const [], const [], [row('a', '2026-01-15', -100, 'X AB1 Y')], currency: 'EUR'), isEmpty);
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      expect(() => repo.addLoan(short), throwsArgumentError);
    });
  });

  group('repo: loans in the plan, conversion, bought and its Undo', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch));
    tearDown(() => repo.close());

    test('open loans add their payment in force to the old loan setting; a closed or deleted one leaves it', () {
      repo.updateSettings({'salary': 300000, 'rent': 50000, 'loan': 5000});
      expect(repo.settings().loanPlan, 5000);
      final a = repo.addLoan(const Loan(id: '', name: 'Car', payment: 20000));
      final b = repo.addLoan(const Loan(id: '', name: 'Boat', payment: 10000));
      expect(repo.settings().loanLines, {a: 20000, b: 10000});
      expect(monthlyFlex(repo.settings()), 300000 - 50000 - 5000 - 30000);
      repo.addLoanRate(a, from: '2026-10-01', rateBp: 500, payment: 21000);
      repo.addLoanRate(a, from: '2027-01-01', rateBp: 600, payment: 25000); // not in force yet
      expect(repo.settings().loanPlan, 5000 + 31000);
      expect(() => repo.patch(LoanCols.entity, b, <Col, Object?>{LoanCols.closedAt: '2026-11-01'}), throwsArgumentError,
          reason: 'closed by its own action');
      repo.closeLoan(b, '2026-11-01');
      expect(repo.settings().loanPlan, 5000 + 21000, reason: 'a paid-off loan leaves the plan');
      repo.deleteLoan(a);
      expect(repo.settings().loanPlan, 5000);
      final c = repo.addLoan(_l);
      repo.addLoanRate(c, from: '2026-07-01', rateBp: 1200); // no payment: the schedule's
      expect(repo.settings().loanLines[c], 87565);
      final st = repo.settings();
      expect(WalletSettings.fromMap(st.toMap()).loanPlan, st.loanPlan, reason: 'the app round-trips settings');
    });

    test('refused: a bad value, a rate or check for an unknown loan; nothing written', () {
      final before = repo.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'];
      expect(() => repo.addLoan(const Loan(id: '', months: 0)), throwsArgumentError);
      expect(() => repo.addLoan(const Loan(id: '', payment: -5)), throwsArgumentError);
      expect(() => repo.addLoanRate('nope', from: '2026-01-01', rateBp: 1), throwsArgumentError);
      expect(() => repo.addLoanCheck('nope', date: '2026-01-01', balance: 1), throwsArgumentError);
      final id = repo.addLoan(_l);
      final rate = repo.addLoanRate(id, from: '2026-07-01', rateBp: 700);
      expect(() => repo.patch(LoanRateCols.entity, rate, <Col, Object?>{LoanRateCols.rateBp: 1}), throwsArgumentError,
          reason: 'rate rows and checks are append-only');
      expect(() => repo.patch(LoanCols.entity, id, <Col, Object?>{LoanCols.goalId: 'g'}), throwsArgumentError);
      expect(() => repo.closeLoan(id, '2099-01-01'), throwsArgumentError);
      expect(repo.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'], (before as int) + 2, reason: 'only the loan and its rate');
    });

    test('rates and checks feed the schedule', () {
      final id = repo.addLoan(_l);
      repo.addLoanCheck(id, date: '2026-06-20', balance: 500000);
      final s = loanSchedule(repo.loans().single, repo.loanRates(id), repo.loanChecks(id));
      expect([s[5].balance, s.last.balance, s.last.paid], [500000, 0, 78360]);
    });

    test('convertLegacyLoan: one write, the setting goes to 0 and the row takes its payment; the plan counts it once', () {
      repo.updateSettings({'salary': 300000, 'loan': 40000, 'loanEnd': '2027-03', 'paydayDay': 15});
      expect(loanLeft(repo.settings(), '2026-11-02')?.payments, 5, reason: 'unchanged until converted');
      final flex = monthlyFlex(repo.settings());
      final v = repo.dataVersion;
      expect(repo.convertLegacyLoan(principal: 200000, rateBp: 500, months: 5, firstDue: '2026-11-15'), Loan.legacyId);
      expect(repo.dataVersion, v + 1, reason: 'one write');
      expect([repo.settings().loan, repo.settings().loanPlan, monthlyFlex(repo.settings())], [0, 40000, flex]);
      final l = repo.loans().single;
      expect([l.payment, l.principal, l.months], [40000, 200000, 5]);
      expect(() => repo.convertLegacyLoan(), throwsArgumentError, reason: 'nothing left to move');
      expect(
          planProposals(const PlanSuggestion(loan: Suggested(value: 45000, basis: 'synthetic')), repo.settings())
              .map((p) => (p.key, p.current)),
          [('loan', null)],
          reason: 'the plan suggestion still targets the setting');
    });

    test('opening a schema-20 wallet writes no loan row: the setting keeps counting', () {
      final dir = Directory.systemTemp.createTempSync('bw-eng-loan-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/w.db';
      int now() => DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
      var r = WalletRepo.open(path, now: now);
      r.updateSettings({'loan': 40000, 'loanEnd': '2027-03', 'paydayDay': 15});
      r.db.execute("UPDATE meta SET value = '20' WHERE key = 'schema'");
      r.close();
      r = WalletRepo.open(path, now: now);
      addTearDown(r.close);
      expect([r.loans(), r.settings().loan, r.settings().loanPlan], [<Loan>[], 40000, 40000]);
      expect(
          planProposals(const PlanSuggestion(loan: Suggested(value: 45000, basis: 'synthetic')), r.settings())
              .map((p) => (p.key, p.current)),
          [('loan', 40000)]);
    });

    test('bought: the purchase is paid by the goal\'s saved money, safe-to-spend does not drop by it; Undo restores', () {
      const today = '2026-11-02';
      repo.updateSettings({'salary': 300000, 'paydayDay': 15, 'periodStart': '2026-10-15'});
      final txId = repo.addTransaction(date: '2026-10-20', amount: 500000, category: 'Shopping');
      final gid = repo.saveGoal(name: 'Synth car', target: 1000000, saved: 600000, monthly: 25000);
      repo.patch(GoalCols.entity, gid, <Col, Object?>{GoalCols.price: 2000000, GoalCols.depositPermille: 300});
      PeriodBudget period() {
        final st = repo.settings();
        final txs = repo.categorizer().expandAll(repo.transactions());
        final p0 = computePeriod(txs, st, repo.goals(), today, table: repo.categoryTable());
        return computePeriod(txs, st, repo.goals(), today,
            table: repo.categoryTable(), goalTakenOut: repo.goalTakenOutBetween(p0.start, p0.end));
      }

      final before = period();
      final goalBefore = repo.goals().single;
      final v = repo.dataVersion;
      final loanId = repo.buyGoal(gid,
          date: '2026-11-01', purchaseTxIds: [txId], loan: const Loan(id: '', principal: 1400000, rateBp: 500, months: 60, payment: 26420));
      expect(repo.dataVersion, v + 1, reason: 'one write');
      expect(loanId, 'l:goal:$gid');
      final g = repo.goals().single;
      expect([g.boughtAt, g.loanId, g.monthly, g.saved], ['2026-11-01', loanId, 25000, 100000], reason: 'monthly is kept, skipped');
      final after = period();
      // Before: the 5000.00 purchase row lowered this period's money. After: the goal's saved money pays it (taken out
      // into this period, so it no longer lowers it), the goal's 250.00 a month is no longer set aside, and the loan's
      // 264.20 is a new fixed line.
      expect(after.remaining, before.remaining + 500000 + 25000 - 26420);
      expect(monthlyFlex(repo.settings(), goals: repo.goals()), 300000 - 26420);
      final loan = repo.loans().single;
      expect([loan.name, loan.goalId, loan.payment], ['Synth car', gid, 26420]);
      final tag = repo.tagTable().liveIds.single;
      expect([
        loan.tagId,
        repo.categorizer().categorize(repo.transaction(txId)!).tags
      ], [
        tag,
        [tag]
      ]);
      expect(repo.goalPeriodAmounts('2026-10-15')[gid], 0);
      repo.payGoals(period: '2026-10-15');
      expect(repo.goals().single.saved, 100000, reason: 'a bought goal is not paid');
      expect(() => repo.buyGoal(gid, date: '2026-11-01'), throwsArgumentError);

      repo.undoBuyGoal(gid);
      expect(repo.dataVersion, v + 2, reason: 'one write');
      final back = repo.goals().single;
      expect([back.boughtAt, back.loanId, back.monthly, back.saved], [null, null, goalBefore.monthly, goalBefore.saved]);
      expect(repo.loans(), isEmpty);
      expect(period().remaining, before.remaining);
      expect(repo.tagTable().liveIds, [tag], reason: 'the project tag and its links stay');
      expect(() => repo.undoBuyGoal(gid), throwsArgumentError);
    });

    test('the saved money covers the purchase rows up to the saved total', () {
      final a = repo.addTransaction(date: '2026-10-20', amount: 30000, category: 'Shopping');
      final b = repo.addTransaction(date: '2026-10-21', amount: 50000, category: 'Shopping');
      final gid = repo.saveGoal(name: 'Synth bike', target: 0, saved: 60000, monthly: 0);
      expect(repo.buyGoal(gid, date: '2026-11-01', purchaseTxIds: [a, b]), isNull, reason: 'paid in full: no loan');
      expect(repo.goalTakenOutByDate('2026-10-01', '2026-11-01'), {'2026-10-20': 30000, '2026-10-21': 30000});
      expect(repo.goals().single.saved, 0);
      final income = repo.addTransaction(date: '2026-10-22', amount: -100, category: 'Extra income');
      expect(() => repo.buyGoal(repo.saveGoal(name: 'X', target: 0, saved: 0, monthly: 0), date: '2026-11-01', purchaseTxIds: [income]),
          throwsArgumentError);
    });
  });

  group('two devices', () {
    late Net net;
    late VaultKey key;
    var now = DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    final devices = <Device>[];
    Device device(String name, {Directory? dir, String? dbPath}) {
      final d = Device(name, dir, key, () => now, net: net, dbPath: dbPath);
      devices.add(d);
      return d;
    }

    setUp(() {
      net = Net();
      key = VaultKey.generate();
      now = DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
    });

    test('a loan, its rate row and its check sync', () async {
      final a = device('a'), b = device('b');
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

    test('convertLegacyLoan on one device: both agree, the plan counts it once', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'loan': 40000});
      now += 1000;
      await a.run();
      await b.run();
      a.repo.convertLegacyLoan();
      now += 1000;
      await a.run();
      await b.run();
      for (final d in [a, b]) {
        expect([d.repo.settings().loan, d.repo.loans().single.payment, d.repo.settings().loanPlan], [0, 40000, 40000], reason: d.name);
      }
    });

    test('an older build edits the setting before the conversion: the row takes the newer payment', () async {
      final tmp = Directory.systemTemp.createTempSync('bw-eng-loan-old-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final neu = device('new'), old = device('old', dir: tmp, dbPath: '${tmp.path}/old.db');
      old.repo.db.execute("UPDATE meta SET value = '20' WHERE key = 'schema'");
      Future<SyncReport> oldRun() => SyncEngine(_Schema20Reader(old.relay, key), key).run(old.repo);
      neu.repo.updateSettings({'loan': 40000});
      now += 1000;
      await neu.run();
      await oldRun();
      old.repo.updateSettings({'loan': 45000}); // the older build's own edit
      now += 1000;
      await oldRun();
      await neu.run();
      neu.repo.convertLegacyLoan();
      now += 1000;
      await neu.run();
      await oldRun();
      expect([neu.repo.loans().single.payment, neu.repo.settings().loan, neu.repo.settings().loanPlan], [45000, 0, 45000]);
      expect(old.repo.settings().loan, 0, reason: 'the older build sees the setting moved (it does not know loan rows)');
      expect(old.repo.db.select('SELECT COUNT(*) AS n FROM loans').first['n'], 0);
    });

    test('bought on two devices offline: one loan', () async {
      final a = device('a'), b = device('b');
      final gid = a.repo.saveGoal(name: 'Synth boat', target: 0, saved: 0, monthly: 0);
      now += 1000;
      await a.run();
      await b.run();
      a.repo.buyGoal(gid, date: '2026-11-01', loan: const Loan(id: '', payment: 30000));
      now += 1000;
      b.repo.buyGoal(gid, date: '2026-11-02', loan: const Loan(id: '', payment: 31000));
      now += 1000;
      await a.run();
      await b.run();
      await a.run();
      for (final d in [a, b]) {
        expect(d.repo.loans().map((l) => (l.id, l.payment)), [('l:goal:$gid', 31000)], reason: d.name);
        expect(d.repo.settings().loanPlan, 31000, reason: d.name);
        expect(d.repo.goals().single.boughtAt, '2026-11-02', reason: d.name);
      }
    });
  });
}

/// What a schema-20 build reads from the relay: the `loan` entity renamed to one it does not know either (skipped, no
/// clock), as the Q8/V3 old-build tests do.
class _Schema20Reader implements SyncTransport {
  final SyncTransport inner;
  final VaultKey key;
  _Schema20Reader(this.inner, this.key);

  Future<List<int>> _rewrite(List<int> bytes, List<int> aad) async {
    final j = jsonDecode(utf8.decode(await unseal(bytes, key, aad: aad)));
    final ops = (j is Map ? j['ops'] : j) as List;
    final out = [
      for (final o in ops.cast<Map<String, Object?>>())
        if ((o['e'] as String).startsWith('loan')) {...o, 'e': '${o['e']}~v21'} else o
    ];
    return seal(utf8.encode(jsonEncode(j is Map ? {...j, 'ops': out} : out)), key, aad: aad);
  }

  @override
  Future<List<int>> get(String device, int seq) async => _rewrite(await inner.get(device, seq), aadSyncFile(device, seq));
  @override
  Future<List<int>> getSnapshot(String id) async => _rewrite(await inner.getSnapshot(id), aadSnapshot(id));
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) => inner.put(device, seq, bytes);
  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) => inner.putSnapshot(id, covers, bytes);
  @override
  Future<void> putBlob(String hash, List<int> bytes) => inner.putBlob(hash, bytes);
  @override
  Future<List<int>?> getBlob(String hash) => inner.getBlob(hash);
  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) => inner.putSnapshotBlobs(id, hashes);
}
