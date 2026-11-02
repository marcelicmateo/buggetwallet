// ENG E6c (ENG_UI_SPEC §5.5 step 4, §6.5 "Matched payments"): a loan's bank rows are found by payee key or reference
// (never amount), the first one asks "Loan payment?", later ones of the same evidence match silently, Unlink is never
// re-matched; a matched row is the fixed "Loan" main tag and counts once, in the plan's loan line. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _payee = 'SYNTH LENDER DD';
const _today = '2026-11-02';
int _clock() => DateTime.utc(2026, 11, 2, 9).millisecondsSinceEpoch;

String _import(WalletRepo r, String date, int cents, String desc) {
  final t = n(date, cents, 'Nalog', desc);
  r.importBatch(ImportBatch(source: 'pbz', transactions: [t]));
  return t.id;
}

String _keyOf(WalletRepo r, String txId) => merchantKey(r.transaction(txId)!);
List<String> _pending(WalletRepo r) => [for (final p in r.pendingLoanPayments()) p.payment.txId];
String _tag(WalletRepo r, String txId) => r.categorizer().categorize(r.transaction(txId)!).category;

void main() {
  group('repo', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: _clock));
    tearDown(() => repo.close());

    String loanByKey() {
      final probe = _import(repo, '2026-08-15', -20000, _payee);
      return repo.addLoan(Loan(id: '', name: 'Car', payment: 20000, payeeKey: _keyOf(repo, probe)));
    }

    test('the first payment asks, later ones of the same payee match silently; another payee with the amount never', () {
      final id = loanByKey();
      final aug = repo.transactions().single.id;
      final sep = _import(repo, '2026-09-15', -20000, _payee);
      final other = _import(repo, '2026-09-16', -20000, 'SYNTH SHOP');
      expect(_pending(repo), [aug, sep]);
      expect(repo.loanMatchedDates(id), isEmpty);
      expect(_tag(repo, aug), 'Bills & one-offs', reason: 'nothing changes before the owner answers');

      final v = repo.dataVersion;
      repo.confirmLoanPayment(id, aug);
      expect(repo.dataVersion, v + 1, reason: 'one write');
      expect(_pending(repo), isEmpty);
      expect(repo.loanMatchedDates(id), ['2026-08-15', '2026-09-15']);
      final cz = repo.categorizer();
      expect([cz.categorize(repo.transaction(sep)!).category, cz.categorize(repo.transaction(sep)!).kind], ['Loan', BudgetKind.fixed]);
      expect(_tag(repo, other), isNot('Loan'));

      final oct = _import(repo, '2026-10-15', -20000, _payee);
      expect([_pending(repo), repo.loanMatchedDates(id).last, _tag(repo, oct)], [isEmpty, '2026-10-15', 'Loan']);
      expect(() => repo.confirmLoanPayment(id, other), throwsArgumentError, reason: 'never by amount');
      expect(
          () =>
              repo.setSplit(oct, const [SplitPart(amount: -10000, category: 'Shopping'), SplitPart(amount: -10000, category: 'Groceries')]),
          throwsArgumentError);
    });

    test('an unlinked row is never matched again, also after a re-import; Undo (confirm) brings it back', () {
      final id = loanByKey();
      final aug = repo.transactions().single.id;
      final sep = _import(repo, '2026-09-15', -20000, _payee);
      repo.confirmLoanPayment(id, aug);
      repo.unlinkLoanPayment(id, sep);
      expect([
        repo.loanMatchedDates(id),
        _pending(repo),
        _tag(repo, sep)
      ], [
        ['2026-08-15'],
        isEmpty,
        'Bills & one-offs'
      ]);
      _import(repo, '2026-09-15', -20000, _payee); // the same file again
      expect([
        repo.loanMatchedDates(id),
        _pending(repo)
      ], [
        ['2026-08-15'],
        isEmpty
      ]);
      repo.confirmLoanPayment(id, sep);
      expect(repo.loanMatchedDates(id), ['2026-08-15', '2026-09-15']);
      expect(() => repo.unlinkLoanPayment('nope', sep), throwsArgumentError);
    });

    test('a reference match with another amount is matched and flagged; a confirmed reference does not vouch for the payee', () {
      final probe = _import(repo, '2026-07-01', -500, 'SYNTH BANK FEE');
      final id = repo.addLoan(Loan(id: '', name: 'Boat', payment: 20000, reference: 'HR99-0001', payeeKey: _keyOf(repo, probe)));
      repo.unlinkLoanPayment(id, probe);
      final a = _import(repo, '2026-08-15', -25000, 'SYNTH TRANSFER HR99-0001');
      final b = _import(repo, '2026-09-15', -26000, 'OTHER TEXT HR99-0001');
      expect(repo.pendingLoanPayments().first.payment.amountChanged, isTrue);
      repo.confirmLoanPayment(id, a);
      final m = repo.loanMatchedPayments(id);
      expect([for (final p in m) (p.txId, p.amount, p.amountChanged)], [(a, 25000, true), (b, 26000, true)]);
      final byKey = _import(repo, '2026-10-01', -500, 'SYNTH BANK FEE');
      expect(_pending(repo), [byKey], reason: 'found by the payee key only: asked, the reference was confirmed');
    });

    test('safe-to-spend with a matched loan row = the plan with the loan line covered, no double count', () {
      repo.updateSettings({'salary': 300000, 'paydayDay': 15, 'periodStart': '2026-10-15'});
      final probe = _import(repo, '2026-08-15', -20000, _payee);
      final id = repo.addLoan(Loan(id: '', name: 'Car', payment: 20000, payeeKey: _keyOf(repo, probe)));
      PeriodBudget period() => computePeriod(repo.categorizer().expandAll(repo.transactions()), repo.settings(), repo.goals(), _today,
          table: repo.categoryTable());

      final plan = period();
      expect(plan.flexBudget, 300000 - 20000, reason: 'the loan line is in the plan');
      final oct = _import(repo, '2026-10-20', -20000, _payee);
      expect(period().remaining, plan.remaining - 20000, reason: 'unconfirmed: still flexible spending (counted twice)');
      repo.confirmLoanPayment(id, oct);
      final after = period();
      expect([after.remaining, after.spent, after.fixedPaid['Loan']], [plan.remaining, 0, 20000]);
      expect(repo.settings().loanPlan, 20000, reason: 'the plan line is not changed by the match');
    });

    test('a deleted row leaves the matches (Undo of the delete brings it back); a deleted row cannot be confirmed', () {
      final id = loanByKey();
      final aug = repo.transactions().single.id;
      final sep = _import(repo, '2026-09-15', -20000, _payee);
      repo.confirmLoanPayment(id, aug);
      repo.deleteTransaction(sep);
      expect([
        repo.loanMatchedDates(id),
        _pending(repo),
        repo.categorizer().loanTx
      ], [
        ['2026-08-15'],
        isEmpty,
        {aug}
      ]);
      expect(() => repo.confirmLoanPayment(id, sep), throwsArgumentError);
      repo.undeleteTransaction(sep);
      expect(repo.loanMatchedDates(id), ['2026-08-15', '2026-09-15']);
      repo.deleteLoan(id);
      expect([repo.categorizer().loanTx, _pending(repo)], [isEmpty, isEmpty], reason: 'a deleted loan matches nothing');
    });

    test('a row confirmed for one loan is not asked or auto-matched for another loan of the same lender', () {
      final aId = loanByKey();
      final aug = repo.transactions().single.id;
      final bId = repo.addLoan(Loan(id: '', name: 'Boat', payment: 30000, payeeKey: _keyOf(repo, aug)));
      repo.confirmLoanPayment(aId, aug);
      expect([
        repo.loanMatchedDates(aId),
        repo.loanMatchedDates(bId),
        _pending(repo)
      ], [
        ['2026-08-15'],
        isEmpty,
        isEmpty
      ]);
    });

    test('two loans at one lender: every row is asked once naming both, never matched silently; each month counts once per loan', () {
      final aId = loanByKey();
      final augA = repo.transactions().single.id;
      final key = _keyOf(repo, augA);
      final bId = repo.addLoan(Loan(id: '', name: 'Boat', payment: 30000, payeeKey: key));
      final augB = _import(repo, '2026-08-16', -30000, _payee);
      final sepA = _import(repo, '2026-09-15', -20000, _payee), sepB = _import(repo, '2026-09-16', -30000, _payee);
      final both = ([aId, bId]..sort());
      expect([
        for (final p in repo.pendingLoanPayments()) [p.payment.txId, for (final l in p.loans) l.id]
      ], [
        for (final t in [augA, augB, sepA, sepB]) [t, ...both]
      ]);
      repo.confirmLoanPayment(aId, augA);
      repo.confirmLoanPayment(bId, augB);
      expect(_pending(repo), [sepA, sepB], reason: 'two loans may take them: asked, never matched silently');
      repo.confirmLoanPayment(bId, sepA); // a wrong pick, then moved
      repo.confirmLoanPayment(aId, sepA);
      repo.confirmLoanPayment(bId, sepB);
      expect([
        repo.loanMatchedDates(aId),
        repo.loanMatchedDates(bId),
        _pending(repo)
      ], [
        ['2026-08-15', '2026-09-15'],
        ['2026-08-16', '2026-09-16'],
        isEmpty
      ]);
      for (final t in [augA, augB, sepA, sepB]) {
        expect(_tag(repo, t), 'Loan');
      }
    });

    test('no hidden payments: a loan without a known payment matches but its row stays spending', () {
      final probe = _import(repo, '2026-08-15', -20000, _payee);
      final id = repo.addLoan(Loan(id: '', name: 'Car', payeeKey: _keyOf(repo, probe)));
      repo.confirmLoanPayment(id, probe);
      expect([
        repo.loanMatchedDates(id),
        repo.categorizer().loanTx,
        _tag(repo, probe)
      ], [
        ['2026-08-15'],
        isEmpty,
        'Bills & one-offs'
      ]);
      repo.patch(LoanCols.entity, id, <Col, Object?>{LoanCols.payment: 20000});
      expect(_tag(repo, probe), 'Loan', reason: 'once the plan has its line');
    });

    test('no hidden payments: the last payment in the period the loan closes counts as spending', () {
      repo.updateSettings({'salary': 300000, 'paydayDay': 15, 'periodStart': '2026-10-15'});
      final probe = _import(repo, '2026-08-15', -20000, _payee);
      final id = repo.addLoan(Loan(id: '', name: 'Car', payment: 20000, payeeKey: _keyOf(repo, probe)));
      final oct = _import(repo, '2026-10-20', -20000, _payee);
      repo.confirmLoanPayment(id, oct);
      PeriodBudget period() => computePeriod(repo.categorizer().expandAll(repo.transactions()), repo.settings(), repo.goals(), _today,
          table: repo.categoryTable());
      expect([period().spent, period().flexBudget], [0, 280000]);
      repo.closeLoan(id, '2026-11-01');
      final p = period();
      expect([p.flexBudget, p.spent, p.remaining], [300000, 20000, 280000], reason: 'the plan line ended: the payment is spending');
      expect([_tag(repo, oct), repo.loanMatchedDates(id).last], ['Bills & one-offs', '2026-10-20'], reason: 'still matched for loanState');
    });

    test('the owner\'s main tag wins: an extra repayment tagged Savings stays Savings until the owner answers yes', () async {
      final id = loanByKey();
      repo.confirmLoanPayment(id, repo.transactions().single.id);
      final savings = await repo.addCategory(name: 'Savings', kind: BudgetKind.flex);
      final extra = _import(repo, '2026-09-20', -50000, _payee);
      repo.setCategory(extra, savings);
      expect([
        _pending(repo),
        _tag(repo, extra)
      ], [
        [extra],
        savings
      ], reason: 'asked, never matched silently');
      repo.confirmLoanPayment(id, extra);
      expect([
        _pending(repo),
        _tag(repo, extra),
        repo.loanMatchedDates(id)
      ], [
        isEmpty,
        'Loan',
        ['2026-08-15', '2026-09-20']
      ]);
    });

    test('a split row is asked; once confirmed it counts whole as Loan and its split shows broken', () {
      final id = loanByKey();
      final aug = repo.transactions().single.id;
      final sep = _import(repo, '2026-09-15', -20000, _payee);
      repo.setSplit(sep, const [SplitPart(amount: -10000, category: 'Shopping'), SplitPart(amount: -10000, category: 'Groceries')]);
      repo.confirmLoanPayment(id, aug);
      expect(_pending(repo), [sep]);
      expect(repo.categorizer().expand(repo.transaction(sep)!), hasLength(2), reason: 'unanswered: the split counts');
      repo.confirmLoanPayment(id, sep);
      final rows = repo.categorizer().expand(repo.transaction(sep)!);
      expect([rows.length, rows.single.category, rows.single.amount, rows.single.splitBroken], [1, 'Loan', -20000, true]);
    });

    test('perf: 20k rows, loan payments worked out once per data version', () {
      const rowCount = 20000;
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (var i = 0; i < rowCount; i++)
          n('2025-${(i % 12 + 1).toString().padLeft(2, '0')}-${(i % 28 + 1).toString().padLeft(2, '0')}', -(100 + i), 'Nalog',
              'SYNTH SHOP ${String.fromCharCode(97 + i % 26)}${String.fromCharCode(97 + i ~/ 26 % 26)} $i'),
        for (var m = 1; m <= 12; m++) n('2025-${m.toString().padLeft(2, '0')}-15', -20000, 'Nalog', _payee),
      ]));
      int ms(void Function() f) {
        final sw = Stopwatch()..start();
        f();
        return sw.elapsedMicroseconds;
      }

      final base = [for (var i = 0; i < 5; i++) ms(() => repo.categorizer())]..sort();
      final probe = repo.transactions().firstWhere((t) => t.description == _payee);
      final id = repo.addLoan(Loan(id: '', name: 'Car', payment: 20000, payeeKey: merchantKey(probe)));
      final cold = ms(() => repo.categorizer());
      repo.confirmLoanPayment(id, probe.id);
      final recompute = ms(() => repo.categorizer());
      final cached = [for (var i = 0; i < 5; i++) ms(() => repo.categorizer())]..sort();
      expect(repo.loanMatchedDates(id), hasLength(12));
      // ignore: avoid_print
      print('loan payments, ${rowCount + 12} rows: categorizer ${base[2]} us without loans, first $cold us, after a data change '
          '$recompute us, cached ${cached[2]} us');
      expect(cached[2] - base[2], lessThan(10000), reason: 'cached per data version: about nothing added');
      expect(recompute - base[2], lessThan(50000), reason: 'loose bound for a shared laptop; about 5 ms here');
    });
  });

  group('two devices', () {
    late Net net;
    late VaultKey key;
    var now = _clock();
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, null, key, () => now, net: net);
      devices.add(d);
      return d;
    }

    setUp(() {
      net = Net();
      key = VaultKey.generate();
      now = _clock();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
    });

    Future<void> both(Device a, Device b) async {
      now += 1000;
      await a.run();
      await b.run();
      await a.run();
    }

    test('a confirm on one device and an unlink on the other both land; the categorizer agrees', () async {
      final a = device('a'), b = device('b');
      final aug = _import(a.repo, '2026-08-15', -20000, _payee);
      final sep = _import(a.repo, '2026-09-15', -20000, _payee);
      final oct = _import(a.repo, '2026-10-15', -20000, _payee);
      final id = a.repo.addLoan(Loan(id: '', name: 'Car', payment: 20000, payeeKey: _keyOf(a.repo, aug)));
      await both(a, b);
      expect(_pending(b.repo), [aug, sep, oct]);
      a.repo.confirmLoanPayment(id, aug);
      b.repo.unlinkLoanPayment(id, oct); // offline at the same time
      await both(a, b);
      for (final d in [a, b]) {
        expect([
          d.repo.loanMatchedDates(id),
          _pending(d.repo),
          _tag(d.repo, sep),
          _tag(d.repo, oct)
        ], [
          ['2026-08-15', '2026-09-15'],
          isEmpty,
          'Loan',
          'Bills & one-offs'
        ], reason: d.name);
      }
    });
  });
}
