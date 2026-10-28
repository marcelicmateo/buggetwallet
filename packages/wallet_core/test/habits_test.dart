// M4 Habits, core half: recurring bills (detection, reservation, payment matching) and the weekly review.
// All data is SYNTHETIC: made-up merchants and amounts.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

var _seq = 0;

/// A categorized bank row (pbz card payment) for the pure functions; [desc] decides the payee key.
CategorizedTx row(String date, int cents, String desc,
    {String category = 'Shopping', bool manual = false, bool deleted = false, String? own, String? id}) {
  final tx = Tx(
    id: id ?? 'syn-${_seq++}',
    source: manual ? 'manual' : 'pbz',
    date: date,
    amount: cents,
    bankType: 'POS plaćanje',
    description: desc,
    category: own,
    manual: manual,
    deleted: deleted,
  );
  return CategorizedTx(tx, category, kindOf(category));
}

/// Three monthly payments of [cents] to [desc] ending on 2026-02-08, 30 days apart.
List<CategorizedTx> monthly(String desc, int cents, {String category = 'Shopping'}) => [
      row('2025-12-10', -cents, desc, category: category),
      row('2026-01-09', -cents, desc, category: category),
      row('2026-02-08', -cents, desc, category: category),
    ];

const today = '2026-03-01';

RecurringBill bill(String nextDue, int cents,
        {String status = 'confirmed', String? lastPaidTx, String payee = 'synthetic_gym', String category = 'Sport & fitness'}) =>
    RecurringBill(
      id: RecurringBill.idFor(payee),
      payee: payee,
      label: 'Synthetic Gym',
      category: category,
      expectedAmount: cents,
      nextDue: nextDue,
      status: status,
      lastPaidTx: lastPaidTx,
    );

NormalizedTransaction gym(String date, int cents) => n(date, -cents, 'POS plaćanje', 'Synthetic Gym 2026');

void main() {
  group('detectRecurring', () {
    test('three monthly payments make a candidate: id from the payee key, median amount, next due 30 days on', () {
      final c = detectRecurring(monthly('Synthetic Gym 2026', 2999), today: today, currency: 'EUR');
      expect(c, hasLength(1));
      final b = c.single;
      expect(b.id, 'rec:synthetic_gym');
      expect(b.payee, 'synthetic_gym');
      expect(b.label, 'Synthetic Gym 2026');
      expect(b.category, 'Shopping');
      expect(b.expectedAmount, 2999);
      expect(b.intervalDays, 30);
      expect(b.nextDue, '2026-03-10');
      expect(b.status, 'candidate');
      expect(b.confirmed, isFalse);
      expect(b.lastPaidTx, isNull);
    });

    test('two occurrences are not enough, three are', () {
      final two = monthly('Synthetic Gym', 2999).sublist(1);
      expect(detectRecurring(two, today: today, currency: 'EUR'), isEmpty);
      expect(detectRecurring(monthly('Synthetic Gym', 2999), today: today, currency: 'EUR'), hasLength(1));
    });

    test('gaps of 27 and 33 days pass, 26 and 34 do not', () {
      List<CategorizedTx> gaps(int a, int b) => [
            row('2025-12-10', -1000, 'Synthetic Gym'),
            row(addDays('2025-12-10', a), -1000, 'Synthetic Gym'),
            row(addDays(addDays('2025-12-10', a), b), -1000, 'Synthetic Gym'),
          ];
      expect(detectRecurring(gaps(27, 33), today: today, currency: 'EUR'), hasLength(1));
      expect(detectRecurring(gaps(33, 27), today: today, currency: 'EUR'), hasLength(1));
      expect(detectRecurring(gaps(26, 30), today: today, currency: 'EUR'), isEmpty);
      expect(detectRecurring(gaps(30, 34), today: today, currency: 'EUR'), isEmpty);
    });

    test('amounts within 10 % of the median pass (inclusive), one outside breaks the candidate', () {
      List<CategorizedTx> amounts(int a, int b, int c) => [
            row('2025-12-10', -a, 'Synthetic Gym'),
            row('2026-01-09', -b, 'Synthetic Gym'),
            row('2026-02-08', -c, 'Synthetic Gym'),
          ];
      expect(detectRecurring(amounts(9000, 10000, 11000), today: today, currency: 'EUR').single.expectedAmount, 10000);
      expect(detectRecurring(amounts(10000, 10000, 11001), today: today, currency: 'EUR'), isEmpty);
      expect(detectRecurring(amounts(8999, 10000, 10000), today: today, currency: 'EUR'), isEmpty);
    });

    test('the median of an even count is the mean of the two middle values', () {
      expect(medianCents([1000, 1200, 1300, 1100]), 1150);
      expect(medianCents([1000, 1001]), 1000);
      expect(medianCents([5, 1, 3]), 3);
    });

    test('an extra purchase at the same payee breaks the monthly chain (shops are not bills)', () {
      final txs = [...monthly('Synthetic Gym', 2999), row('2026-01-20', -500, 'Synthetic Gym')];
      expect(detectRecurring(txs, today: today, currency: 'EUR'), isEmpty);
    });

    test('inflows, transfers, hand-added, deleted and future rows never count', () {
      final inflow = [for (final t in monthly('Synthetic Refund', 2999)) row(t.date, 2999, 'Synthetic Refund')];
      expect(detectRecurring(inflow, today: today, currency: 'EUR'), isEmpty);
      expect(detectRecurring(monthly('Synthetic Top Up', 2999, category: 'Internal transfer'), today: today, currency: 'EUR'), isEmpty);
      final manual = [for (final t in monthly('Synthetic Gym', 2999)) row(t.date, -2999, 'Synthetic Gym', manual: true)];
      expect(detectRecurring(manual, today: today, currency: 'EUR'), isEmpty);
      final deleted = monthly('Synthetic Gym', 2999)..[1] = row('2026-01-09', -2999, 'Synthetic Gym', deleted: true);
      expect(detectRecurring(deleted, today: today, currency: 'EUR'), isEmpty);
      // The last payment lies after today: not here yet.
      expect(detectRecurring(monthly('Synthetic Gym', 2999), today: '2026-02-07', currency: 'EUR'), isEmpty);
    });

    test('only the last 7 calendar months count', () {
      final txs = monthly('Synthetic Gym', 2999); // Dec, Jan, Feb
      expect(detectRecurring(txs, today: '2026-06-30', currency: 'EUR'), hasLength(1), reason: 'Dec 2025 is within Dec..Jun');
      expect(detectRecurring(txs, today: '2026-07-01', currency: 'EUR'), isEmpty, reason: 'Dec 2025 falls out of Jan..Jul');
    });

    test('a fixed-category bill is a candidate too (rent by standing order)', () {
      final c = detectRecurring(monthly('Synthetic Landlord', 55000, category: 'Rent'), today: today, currency: 'EUR').single;
      expect(c.category, 'Rent');
      expect(c.expectedAmount, 55000);
    });

    test('candidates are ordered by label and derived the same from a shuffled list', () {
      final txs = [...monthly('Synthetic Zeta Club', 1000), ...monthly('Synthetic Alpha Net', 2000)];
      final a = detectRecurring(txs, today: today, currency: 'EUR');
      final b = detectRecurring(txs.reversed.toList(), today: today, currency: 'EUR');
      expect([for (final x in a) x.label], ['Synthetic Alpha Net', 'Synthetic Zeta Club']);
      expect([for (final x in b) (x.id, x.expectedAmount, x.nextDue)], [for (final x in a) (x.id, x.expectedAmount, x.nextDue)]);
    });
  });

  group('computePeriod reservation', () {
    final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
    final txs = [row('2026-02-20', -3000, 'Synthetic Market', category: 'Groceries')];

    test('a confirmed bill due before payday is reserved exactly like a fixed cost', () {
      final b = bill('2026-03-05', 5000);
      final p = computePeriod(txs, st, const [], today, bills: [b], table: CategoryTable.builtIn);
      final fixed =
          computePeriod(txs, WalletSettings.fromMap({...st.toMap(), 'subs': 5000}), const [], today, table: CategoryTable.builtIn);
      expect(p.reservedBills, 5000);
      expect(p.dueBills.single.id, b.id);
      expect(p.flexBudget, 195000);
      expect(p.fixedPlan, 0, reason: 'the reservation is its own line, not a fixed cost');
      expect((p.flexBudget, p.remaining, p.allowanceToday, p.safeToday, p.planDaily),
          (fixed.flexBudget, fixed.remaining, fixed.allowanceToday, fixed.safeToday, fixed.planDaily));
      final none = computePeriod(txs, st, const [], today, table: CategoryTable.builtIn);
      expect(none.reservedBills, 0);
      expect(none.dueBills, isEmpty);
      expect(none.safeToday - p.safeToday, (5000 / p.daysLeft).round(), reason: 'spread over the days left');
    });

    test('a bill due on or after payday is not reserved; a candidate or dismissed bill never is', () {
      expect(computePeriod(txs, st, const [], today, bills: [bill('2026-03-15', 5000)], table: CategoryTable.builtIn).reservedBills, 0,
          reason: 'due on payday');
      expect(computePeriod(txs, st, const [], today, bills: [bill('2026-03-16', 5000)], table: CategoryTable.builtIn).reservedBills, 0);
      expect(computePeriod(txs, st, const [], today, bills: [bill('2026-03-14', 5000)], table: CategoryTable.builtIn).reservedBills, 5000,
          reason: 'the day before');
      expect(
          computePeriod(txs, st, const [], today, bills: [bill('2026-03-05', 5000, status: 'candidate')], table: CategoryTable.builtIn)
              .reservedBills,
          0);
      expect(
          computePeriod(txs, st, const [], today, bills: [bill('2026-03-05', 5000, status: 'dismissed')], table: CategoryTable.builtIn)
              .reservedBills,
          0);
    });

    test('an overdue bill (due before the period) stays reserved until paid', () {
      expect(computePeriod(txs, st, const [], today, bills: [bill('2026-02-10', 5000)], table: CategoryTable.builtIn).reservedBills, 5000);
    });

    test('a bill paid early is released: its next due date lies past payday', () {
      // Paid on 2026-02-20 for a cycle due 2026-02-22: nextDue moved to 2026-03-24.
      final paid = bill('2026-03-24', 5000, lastPaidTx: 'pay1');
      final rows = [...txs, row('2026-02-20', -5000, 'Synthetic Gym', id: 'pay1', category: 'Sport & fitness')];
      final p = computePeriod(rows, st, const [], today, bills: [paid], table: CategoryTable.builtIn);
      expect(p.reservedBills, 0);
      expect(p.spent, 8000, reason: 'the payment counts as spending like any flex row');
    });

    test('a bill paid in this period is not reserved again even when its next due date falls before payday', () {
      // A 31-day period (2026-01-15..2026-02-15): a bill paid on day 1 is due again on the last day.
      final long = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-01-15', 'paydayDay': 15});
      final rows = [row('2026-01-15', -5000, 'Synthetic Gym', id: 'pay1', category: 'Sport & fitness')];
      final b = bill('2026-02-14', 5000, lastPaidTx: 'pay1');
      expect(computePeriod(rows, long, const [], '2026-01-20', bills: [b], table: CategoryTable.builtIn).reservedBills, 0);
      // The same bill whose payment row is from before the period: due again, reserved.
      final earlier = [row('2026-01-14', -5000, 'Synthetic Gym', id: 'pay1', category: 'Sport & fitness')];
      expect(computePeriod(earlier, long, const [], '2026-01-20', bills: [b], table: CategoryTable.builtIn).reservedBills, 5000);
    });

    test('a confirmed bill in a fixed category is due but covered by the plan: nothing changes, a flex one reserves', () {
      final rent = bill('2026-03-05', 55000, payee: 'synthetic_landlord', category: 'Rent');
      final loan = bill('2026-03-06', 20000, payee: 'synthetic_bank', category: 'Loan');
      final subs = bill('2026-03-07', 999, payee: 'synthetic_stream', category: 'Bills & subscriptions');
      final gym = bill('2026-03-08', 5000);
      expect((rent.coveredByPlan, loan.coveredByPlan, subs.coveredByPlan, gym.coveredByPlan), (true, true, true, false));
      final none = computePeriod(txs, st, const [], today, table: CategoryTable.builtIn);
      final fixedOnly = computePeriod(txs, st, const [], today, bills: [rent, loan, subs], table: CategoryTable.builtIn);
      expect(fixedOnly.reservedBills, 0);
      expect((fixedOnly.safeToday, fixedOnly.planDaily, fixedOnly.flexBudget), (none.safeToday, none.planDaily, none.flexBudget));
      expect([for (final b in fixedOnly.dueBills) b.id], [rent.id, loan.id, subs.id], reason: 'listed, so the UI can show them');
      final mixed = computePeriod(txs, st, const [], today, bills: [gym, rent], table: CategoryTable.builtIn);
      expect(mixed.reservedBills, 5000, reason: 'only the flex bill');
      expect([for (final b in mixed.dueBills) (b.id, b.coveredByPlan)], [(rent.id, true), (gym.id, false)]);
      expect(mixed.safeToday, computePeriod(txs, st, const [], today, bills: [gym], table: CategoryTable.builtIn).safeToday);
    });

    test('several bills add up; dueBills is ordered by due date then label', () {
      final a = bill('2026-03-10', 1000, payee: 'synthetic_b');
      final b = bill('2026-03-05', 2000, payee: 'synthetic_a');
      final p = computePeriod(txs, st, const [], today, bills: [a, b], table: CategoryTable.builtIn);
      expect(p.reservedBills, 3000);
      expect([for (final x in p.dueBills) x.id], [b.id, a.id]);
    });
  });

  group('planRecurringPayments', () {
    Tx bank(String date, int cents, {String desc = 'Synthetic Gym', String? id, bool manual = false, bool deleted = false}) => Tx(
        id: id ?? 'b-${_seq++}',
        source: manual ? 'manual' : 'pbz',
        date: date,
        amount: -cents,
        bankType: 'POS plaćanje',
        description: desc,
        manual: manual,
        deleted: deleted);

    test('a row within ± 3 days of the due date and within 10 % pays the cycle; 4 days or 10 % + 1 cent do not', () {
      final b = bill('2026-03-10', 5000);
      expect(planRecurringPayments([b], [bank('2026-03-13', 5000, id: 'x')], currency: 'EUR').paidBy[b.id]?.id, 'x');
      expect(planRecurringPayments([b], [bank('2026-03-07', 5000, id: 'x')], currency: 'EUR').paidBy[b.id]?.id, 'x');
      expect(planRecurringPayments([b], [bank('2026-03-14', 5000)], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([b], [bank('2026-03-06', 5000)], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([b], [bank('2026-03-10', 5500, id: 'x')], currency: 'EUR').paidBy[b.id]?.id, 'x');
      expect(planRecurringPayments([b], [bank('2026-03-10', 4500, id: 'x')], currency: 'EUR').paidBy[b.id]?.id, 'x');
      expect(planRecurringPayments([b], [bank('2026-03-10', 5501)], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([b], [bank('2026-03-10', 4499)], currency: 'EUR').isEmpty, isTrue);
    });

    test('the closest row wins, then the earliest, then the smallest id; another payee, a refund, a deleted or hand-added row never pay',
        () {
      final b = bill('2026-03-10', 5000);
      final rows = [bank('2026-03-12', 5000, id: 'far'), bank('2026-03-09', 5000, id: 'near')];
      expect(planRecurringPayments([b], rows, currency: 'EUR').paidBy[b.id]?.id, 'near');
      final tie = [bank('2026-03-11', 5000, id: 'later'), bank('2026-03-09', 5000, id: 'earlier')];
      expect(planRecurringPayments([b], tie, currency: 'EUR').paidBy[b.id]?.id, 'earlier');
      final same = [bank('2026-03-10', 5000, id: 'z'), bank('2026-03-10', 5000, id: 'a')];
      expect(planRecurringPayments([b], same, currency: 'EUR').paidBy[b.id]?.id, 'a');
      expect(planRecurringPayments([b], [bank('2026-03-10', 5000, desc: 'Synthetic Other')], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([b], [bank('2026-03-10', -5000)], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([b], [bank('2026-03-10', 5000, deleted: true)], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([b], [bank('2026-03-10', 5000, manual: true)], currency: 'EUR').isEmpty, isTrue);
    });

    test('only confirmed bills are paid, and the row that paid the last cycle never pays again', () {
      expect(planRecurringPayments([bill('2026-03-10', 5000, status: 'candidate')], [bank('2026-03-10', 5000)], currency: 'EUR').isEmpty,
          isTrue);
      final b = bill('2026-03-10', 5000, lastPaidTx: 'x');
      expect(planRecurringPayments([b], [bank('2026-03-10', 5000, id: 'x')], currency: 'EUR').isEmpty, isTrue);
    });
  });

  group('reviewState', () {
    final st0 = WalletSettings.fromMap({});
    // 2026-03-01 is a Sunday.
    test('never reviewed: due at once, dated the last review day on or before today', () {
      final s = reviewState(const [], st0, const [], const {}, today: '2026-03-04');
      expect(s.due, isTrue);
      expect(s.nextReviewDate, '2026-03-01');
      expect(s.streak, 0);
      expect(reviewState(const [], st0, const [], const {}, today: '2026-03-01').nextReviewDate, '2026-03-01');
      expect([for (final x in s.steps) x.id], ['import', 'categories', 'pace', 'wishlist']);
      expect(s.step('import')!.count, 0);
    });

    test('reviewed on Sunday: not due Monday to Saturday, due again from the next Sunday until done', () {
      final st = WalletSettings.fromMap({'lastReview': '2026-03-01', 'reviewStreak': 3});
      for (var d = 1; d <= 6; d++) {
        final s = reviewState(const [], st, const [], const {}, today: addDays('2026-03-01', d));
        expect(s.due, isFalse, reason: 'day +$d');
        expect(s.nextReviewDate, '2026-03-08');
        expect(s.streak, 3);
      }
      expect(reviewState(const [], st, const [], const {}, today: '2026-03-08').due, isTrue);
      final late = reviewState(const [], st, const [], const {}, today: '2026-03-20');
      expect(late.due, isTrue);
      expect(late.nextReviewDate, '2026-03-08', reason: 'the review that has been waiting');
    });

    test('a review done on a weekday is due again on the next review day, not a week after it', () {
      final st = WalletSettings.fromMap({'lastReview': '2026-03-04'}); // Wednesday
      expect(reviewState(const [], st, const [], const {}, today: '2026-03-07').due, isFalse);
      final s = reviewState(const [], st, const [], const {}, today: '2026-03-08');
      expect(s.due, isTrue);
      expect(s.nextReviewDate, '2026-03-08');
    });

    test('changing the review day moves the next review', () {
      final st = WalletSettings.fromMap({'lastReview': '2026-03-01', 'reviewDay': DateTime.wednesday});
      expect(reviewState(const [], st, const [], const {}, today: '2026-03-03').due, isFalse);
      final s = reviewState(const [], st, const [], const {}, today: '2026-03-04');
      expect(s.due, isTrue);
      expect(s.nextReviewDate, '2026-03-04');
      // Reviewed on the review day itself: the next one is a week on.
      final same = WalletSettings.fromMap({'lastReview': '2026-03-04', 'reviewDay': DateTime.wednesday});
      expect(reviewState(const [], same, const [], const {}, today: '2026-03-04').nextReviewDate, '2026-03-11');
    });

    test('categories step counts spending rows of the last 7 days without a user-set category', () {
      final txs = [
        row('2026-03-01', -1000, 'Synthetic A'), // automatic, today
        row('2026-02-23', -1000, 'Synthetic B'), // automatic, 6 days ago
        row('2026-02-22', -1000, 'Synthetic C'), // 7 days ago: outside
        row('2026-02-28', -1000, 'Synthetic D', own: 'Groceries', category: 'Groceries'), // user-set
        row('2026-02-28', -1000, 'Synthetic E', own: 'Nope'), // an override this build does not know: automatic
        row('2026-02-28', 150000, 'Synthetic Pay', category: 'Salary'), // income: nothing to confirm
        row('2026-02-28', -1000, 'Synthetic Up', category: 'Internal transfer'),
        row('2026-02-28', -1000, 'Synthetic F', deleted: true),
        row('2026-03-02', -1000, 'Synthetic G'), // tomorrow
      ];
      expect(reviewState(txs, st0, const [], const {}, today: today).step('categories')!.count, 3);
    });

    test('pace step counts categories behind pace or over budget this month', () {
      final txs = [
        row('2026-03-01', -4000, 'Synthetic Market', category: 'Groceries'), // 4000 of 30000 on day 1 of 31: behind
        row('2026-03-01', -100, 'Synthetic Cafe', category: 'Eating out'), // 100 of 10000: on pace
        row('2026-03-01', -6000, 'Synthetic Shop', category: 'Shopping'), // over a 5000 budget
      ];
      final budgets = {'Groceries': 30000, 'Eating out': 10000, 'Shopping': 5000, 'Cash': 1000};
      expect(reviewState(txs, st0, const [], budgets, today: today).step('pace')!.count, 2);
      expect(reviewState(txs, st0, const [], const {}, today: today).step('pace')!.count, 0);
    });

    test('wishlist step counts waiting items past their cooling-off', () {
      const hour = 3600000;
      final endOfToday = parseIso('2026-03-02').millisecondsSinceEpoch;
      final wishes = [
        WishItem(id: 'a', name: 'Synthetic', price: 100, added: endOfToday - 72 * hour), // just past
        WishItem(id: 'b', name: 'Synthetic', price: 100, added: endOfToday - 71 * hour), // still cooling
        WishItem(id: 'c', name: 'Synthetic', price: 100, added: endOfToday - 100 * hour, status: 'bought'),
        WishItem(id: 'd', name: 'Synthetic', price: 100, added: endOfToday - 100 * hour, status: 'skipped'),
        WishItem(id: 'e', name: 'Synthetic', price: 100, added: endOfToday - 200 * hour),
      ];
      expect(reviewState(const [], st0, wishes, const {}, today: today).step('wishlist')!.count, 2);
      expect(reviewState(const [], st0, wishes, const {}, today: today, nowMillis: endOfToday - 80 * hour).step('wishlist')!.count, 1);
      final short = WalletSettings.fromMap({'coolHours': 24});
      expect(reviewState(const [], short, wishes, const {}, today: today).step('wishlist')!.count, 3);
    });
  });

  group('review settings', () {
    test('defaults: Sunday, never reviewed, streak 0; values round-trip', () {
      final d = WalletSettings.fromMap({});
      expect((d.reviewDay, d.lastReview, d.reviewStreak), (7, null, 0));
      final s = WalletSettings.fromMap({'reviewDay': 3, 'lastReview': '2026-03-04', 'reviewStreak': 12});
      expect(WalletSettings.fromMap(s.toMap()).toMap(), s.toMap());
      expect((s.reviewDay, s.lastReview, s.reviewStreak), (3, '2026-03-04', 12));
    });

    test('bad values fall back to the default, logged with the key only', () {
      resetInvalidSettingLog();
      final s = WalletSettings.fromMap({'reviewDay': 0, 'lastReview': '2026-02-30', 'reviewStreak': -1});
      expect((s.reviewDay, s.lastReview, s.reviewStreak), (7, null, 0));
      expect(WalletSettings.fromMap({'reviewDay': 8}).reviewDay, 7);
      expect(WalletSettings.fromMap({'reviewDay': 'sunday'}).reviewDay, 7);
      expect(WalletSettings.fromMap({'reviewStreak': WalletSettings.maxStreak + 1}).reviewStreak, 0);
      expect(WalletSettings.fromMap({'reviewStreak': WalletSettings.maxStreak}).reviewStreak, WalletSettings.maxStreak);
    });
  });

  group('WalletRepo', () {
    late WalletRepo r;
    var now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    setUp(() {
      now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
      r = WalletRepo.inMemory(now: () => now);
    });
    tearDown(() => r.close());

    ImportBatch batch(List<NormalizedTransaction> rows) => ImportBatch(source: 'pbz', transactions: rows);
    final three = [gym('2025-12-10', 2999), gym('2026-01-09', 2999), gym('2026-02-08', 3099)];

    test('an import detects candidates; an entity row syncs with the column names', () {
      r.importBatch(batch(three));
      final c = r.recurringBills().single;
      expect(c.id, 'rec:synthetic_gym');
      expect(c.status, 'candidate');
      expect(c.expectedAmount, 2999);
      expect(c.nextDue, '2026-03-10');
      final op = r.pendingOps().last.$2;
      expect(op.entity, 'recurring');
      expect(op.fields.keys, unorderedEquals(['payee', 'label', 'category', 'expected_amount', 'interval_days', 'next_due']),
          reason: 'no status or deleted: a late detection must not undo a dismiss or delete elsewhere');
    });

    test('confirm, dismiss, delete; dismissed bills are listed only on request; unknown ids are refused', () {
      r.importBatch(batch(three));
      final id = r.recurringBills().single.id;
      r.confirmRecurring(id);
      expect(r.recurringBills().single.confirmed, isTrue);
      r.dismissRecurring(id);
      expect(r.recurringBills(), isEmpty);
      expect(r.recurringBills(includeDismissed: true).single.status, 'dismissed');
      r.deleteRecurring(id);
      expect(r.recurringBills(includeDismissed: true), isEmpty);
      expect(() => r.confirmRecurring('rec:nope'), throwsArgumentError);
      expect(() => r.refreshRecurring('tomorrow'), throwsArgumentError);
    });

    test('a dismissed or deleted payee is never added again, even by a later import', () {
      r.importBatch(batch(three));
      r.dismissRecurring('rec:synthetic_gym');
      now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
      r.importBatch(batch([gym('2026-03-10', 2999)]));
      expect(r.recurringBills(), isEmpty);
      expect(r.recurringBills(includeDismissed: true).single.status, 'dismissed');
      r.deleteRecurring('rec:synthetic_gym');
      now = DateTime.utc(2026, 4, 15, 12).millisecondsSinceEpoch;
      r.importBatch(batch([gym('2026-04-09', 2999)]));
      expect(r.recurringBills(includeDismissed: true), isEmpty);
    });

    test('a candidate follows the latest detection; a confirmed bill is not rewritten by detection', () {
      r.importBatch(batch(three));
      now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
      r.importBatch(batch([gym('2026-03-10', 3099)]));
      final c = r.recurringBills().single;
      expect(c.nextDue, '2026-04-09');
      expect(c.expectedAmount, 3049, reason: 'median of 2999, 2999, 3099, 3099');
      r.confirmRecurring(c.id);
      now = DateTime.utc(2026, 4, 15, 12).millisecondsSinceEpoch;
      r.importBatch(batch([gym('2026-04-09', 3199)]));
      final b = r.recurringBills().single;
      expect(b.expectedAmount, 3049, reason: 'expectedAmount stays once confirmed');
      expect(b.lastPaidTx, gym('2026-04-09', 3199).id);
      expect(b.nextDue, '2026-05-09');
    });

    test('a bank row within the window pays the cycle: lastPaidTx, nextDue = paying date + 30, the row keeps its category', () {
      r.importBatch(batch(three));
      r.confirmRecurring('rec:synthetic_gym');
      final pay = gym('2026-03-12', 3100); // due 2026-03-10, +2 days, within 10 % of 2999
      r.importBatch(batch([pay]));
      final b = r.recurringBills().single;
      expect(b.lastPaidTx, pay.id);
      expect(b.nextDue, '2026-04-11', reason: 'from the payment date, not the expected one, so the match never drifts');
      expect(b.expectedAmount, 2999);
      final tx = r.transaction(pay.id)!;
      expect(tx.category, isNull, reason: 'nothing is reclassified');
      expect(r.categorizer().categoryOf(tx), 'Shopping');
      // Refreshing again changes nothing (idempotent) and writes no op.
      final ops = r.pendingOps().length;
      r.refreshRecurring('2026-03-15');
      expect(r.pendingOps().length, ops);
    });

    test('a row 4 days off or 11 % off leaves the cycle open; it is reserved in the period', () {
      r.importBatch(batch(three));
      r.confirmRecurring('rec:synthetic_gym');
      r.importBatch(batch([gym('2026-03-14', 2999), gym('2026-03-10', 3400)]));
      final b = r.recurringBills().single;
      expect(b.lastPaidTx, isNull);
      expect(b.nextDue, '2026-03-10');
      final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      final cz = r.categorizer();
      final p = computePeriod([for (final t in r.transactions()) cz.categorize(t)], st, const [], '2026-03-01',
          bills: r.recurringBills(), table: CategoryTable.builtIn);
      expect(p.reservedBills, 2999);
    });

    test('a history import with several cycles catches up one cycle per payment', () {
      r.importBatch(batch(three));
      r.confirmRecurring('rec:synthetic_gym');
      r.importBatch(batch([gym('2026-03-10', 2999), gym('2026-04-09', 2999), gym('2026-05-09', 2999)]));
      final b = r.recurringBills().single;
      expect(b.lastPaidTx, gym('2026-05-09', 2999).id);
      expect(b.nextDue, '2026-06-08');
    });

    int streak() => reviewStreak(r.reviewDates(), legacyLast: r.settings().lastReview, legacyStreak: r.settings().reviewStreak);

    test('markReviewDone: first review starts the streak at 1, within 14 days +1, a longer gap restarts, same day is a no-op', () {
      r.markReviewDone('2026-03-01');
      expect(r.reviewDates(), ['2026-03-01']);
      expect(streak(), 1);
      final ops = r.pendingOps().length;
      r.markReviewDone('2026-03-01');
      expect(r.pendingOps(), hasLength(ops), reason: 'same day twice: no new op');
      expect(streak(), 1);
      r.markReviewDone('2026-03-08');
      expect(streak(), 2);
      r.markReviewDone('2026-03-21'); // 13 days: still a streak
      expect(streak(), 3);
      r.markReviewDone('2026-04-04'); // 14 days: a review day (03-28) was skipped, starts again
      expect((r.reviewDates().last, streak()), ('2026-04-04', 1));
      r.markReviewDone('2026-04-05');
      expect(streak(), 2);
      r.markReviewDone('2026-04-20'); // 15 days: starts again
      expect((r.reviewDates().last, streak()), ('2026-04-20', 1));
      expect(() => r.markReviewDone('06.04.2026'), throwsArgumentError);
      // No counter is written (V3): the legacy settings stay unset.
      expect((r.settings().lastReview, r.settings().reviewStreak), (null, 0));
      // The review day setting syncs like any other.
      r.updateSettings({'reviewDay': DateTime.wednesday});
      expect(r.settings().reviewDay, 3);
    });

    test('markReviewDone: a skipped week resets the streak (done, skipped, done = 1, not 2)', () {
      r.markReviewDone('2026-10-04'); // Sunday
      r.markReviewDone('2026-10-18'); // the Sunday after next: 2026-10-11 was skipped
      expect(streak(), 1);
      r.markReviewDone('2026-10-25');
      expect(streak(), 2);
    });

    test('a bill paid on the 15th for a year (real calendar) stays matched: nextDue follows the paying row, never reserved while paid', () {
      // 2025-03-15 .. 2026-02-15: gaps of 28 to 31 days. Advancing from the expected date instead would drift a day
      // or so a month until the match window (± 3 days) is missed and the bill stays overdue while the rows count.
      final dates = [for (var m = 3; m <= 14; m++) '${m <= 12 ? 2025 : 2026}-${(m > 12 ? m - 12 : m).toString().padLeft(2, '0')}-15'];
      now = DateTime.utc(2025, 6, 1, 12).millisecondsSinceEpoch;
      r.importBatch(batch([for (final d in dates.take(3)) gym(d, 2999)]));
      r.confirmRecurring('rec:synthetic_gym');
      expect(r.recurringBills().single.nextDue, '2025-06-14');
      for (final d in dates.skip(3)) {
        final pay = gym(d, 2999);
        now = parseIso(d).add(const Duration(days: 1, hours: 12)).millisecondsSinceEpoch;
        r.importBatch(batch([pay]));
        final b = r.recurringBills().single;
        expect(b.lastPaidTx, pay.id, reason: d);
        expect(b.nextDue, addDays(d, 30), reason: d);
        // The pay period that holds the payment (payday on the 1st): paid, so neither due nor reserved.
        final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '${monthOf(d)}-01', 'paydayDay': 1});
        final cz = r.categorizer();
        final p = computePeriod([for (final t in r.transactions()) cz.categorize(t)], st, const [], d,
            bills: r.recurringBills(), table: CategoryTable.builtIn);
        expect(p.dueBills, isEmpty, reason: d);
        expect(p.reservedBills, 0, reason: d);
      }
      expect(r.recurringBills().single.nextDue, '2026-03-17');
    });

    test('a confirmed bill follows the payee\'s current category: a rule into a fixed category makes it covered by the plan', () {
      r.importBatch(batch(three));
      r.confirmRecurring('rec:synthetic_gym');
      final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      PeriodBudget period() {
        final cz = r.categorizer();
        return computePeriod([for (final t in r.transactions()) cz.categorize(t)], st, const [], '2026-03-01',
            bills: r.recurringBills(), table: CategoryTable.builtIn);
      }

      var b = r.recurringBills().single;
      expect((b.category, b.coveredByPlan), ('Shopping', false));
      expect(period().reservedBills, 2999);
      r.setMerchantRule('synthetic_gym', 'Bills & subscriptions');
      r.refreshRecurring('2026-03-01');
      b = r.recurringBills().single;
      expect((b.category, b.coveredByPlan, b.nextDue, b.expectedAmount), ('Bills & subscriptions', true, '2026-03-10', 2999));
      expect(period().reservedBills, 0, reason: 'planned through the subs setting, never reserved as well');
      expect(period().dueBills.single.id, b.id, reason: 'still listed as due');
      final op = r.pendingOps().last.$2;
      expect((op.entity, op.id), ('recurring', b.id));
      expect(op.fields, {'category': 'Bills & subscriptions'}, reason: 'one synced op, the category only');
      // Back to a flexible category: reserved again. An unchanged category writes nothing.
      r.setMerchantRule('synthetic_gym', 'Sport & fitness');
      r.refreshRecurring('2026-03-01');
      expect((r.recurringBills().single.category, period().reservedBills), ('Sport & fitness', 2999));
      final ops = r.pendingOps().length;
      r.refreshRecurring('2026-03-02');
      expect(r.pendingOps().length, ops);
    });

    test('a confirm that arrives before the bill\'s creation op is filled in by the next refresh and then paid', () {
      final h = Hlc(DateTime.utc(2026, 2, 28, 12).millisecondsSinceEpoch, 0, 'peer').toString();
      r.applyRemote([
        Op('recurring', 'rec:synthetic_gym', {'status': 'confirmed'}, h)
      ]);
      var b = r.recurringBills().single;
      expect((b.payee, b.nextDue, b.expectedAmount, b.confirmed), ('', '', 0, true));
      r.importBatch(batch(three));
      b = r.recurringBills().single;
      expect((b.payee, b.expectedAmount, b.nextDue, b.category, b.confirmed), ('synthetic_gym', 2999, '2026-03-10', 'Shopping', true));
      expect(b.label, isNotEmpty);
      final pay = gym('2026-03-10', 2999);
      now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
      r.importBatch(batch([pay]));
      b = r.recurringBills().single;
      expect((b.lastPaidTx, b.nextDue, b.confirmed), (pay.id, '2026-04-09', true));
    });

    test('skipRecurring: an unpaid bill is reserved; skipped, it leaves this period\'s dueBills and nextDue moves one interval', () async {
      r.importBatch(batch(three));
      r.confirmRecurring('rec:synthetic_gym');
      PeriodBudget period(String start, String today) {
        final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': start, 'paydayDay': 15});
        final cz = r.categorizer();
        return computePeriod([for (final t in r.transactions()) cz.categorize(t)], st, const [], today,
            bills: r.recurringBills(), table: CategoryTable.builtIn);
      }

      expect((period('2026-02-15', '2026-03-01').reservedBills, period('2026-02-15', '2026-03-01').dueBills.length), (2999, 1));
      await r.skipRecurring('rec:synthetic_gym');
      final b = r.recurringBills().single;
      expect((b.nextDue, b.lastPaidTx, b.expectedAmount, b.confirmed), ('2026-04-09', null, 2999, true));
      expect(period('2026-02-15', '2026-03-01').reservedBills, 0);
      expect(period('2026-02-15', '2026-03-01').dueBills, isEmpty);
      // Next period it is due again; the skip is one synced op with the new date only.
      expect(period('2026-03-15', '2026-03-20').dueBills.single.nextDue, '2026-04-09');
      final op = r.pendingOps().last.$2;
      expect((op.entity, op.id), ('recurring', b.id));
      expect(op.fields, {'next_due': '2026-04-09'});
      expect(r.skipRecurring('rec:nope'), throwsArgumentError);
      // A late row for the skipped cycle does not pay the next one (a month off); the next cycle's row does.
      now = DateTime.utc(2026, 4, 15, 12).millisecondsSinceEpoch;
      r.importBatch(batch([gym('2026-03-11', 2999), gym('2026-04-10', 2999)]));
      final after = r.recurringBills().single;
      expect((after.lastPaidTx, after.nextDue), (gym('2026-04-10', 2999).id, '2026-05-10'));
    });

    test('an existing database is upgraded to schema 5 with the recurring table and replays the relay once', () {
      final tmp = Directory.systemTemp.createTempSync('bw-habits-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/w.db';
      final old = WalletRepo.open(path);
      old.importBatch(january);
      old.setSyncCursor('dev', 3);
      old.db.execute("UPDATE meta SET value = '4' WHERE key = 'schema'");
      old.db.execute('DROP TABLE recurring');
      old.close();
      final up = WalletRepo.open(path);
      expect(up.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      expect(up.syncCursors(), isEmpty);
      expect(up.recurringBills(), isEmpty);
      up.close();
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    final devices = <Device>[];
    final three = [gym('2025-12-10', 2999), gym('2026-01-09', 2999), gym('2026-02-08', 2999)];
    ImportBatch batch(List<NormalizedTransaction> rows) => ImportBatch(source: 'pbz', transactions: rows);

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
        d.upload(net);
      }
    }

    List<Map<String, Object?>> table(Device d) => dump(d.repo, clocks: false)['recurring']!;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-habits-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
      now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('a candidate detected on one device arrives on the other; confirm there is seen by both', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(batch(three));
      await round();
      await round();
      expect(b.repo.recurringBills().single.id, 'rec:synthetic_gym');
      now += 1000;
      b.repo.confirmRecurring('rec:synthetic_gym');
      await round();
      await round();
      expect(a.repo.recurringBills().single.confirmed, isTrue);
      expect(table(a), table(b));
    });

    test('dismissed on one device, detected late on the other (import before sync): stays dismissed on both', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(batch(three));
      now += 1000;
      a.repo.dismissRecurring('rec:synthetic_gym');
      a.upload(net);
      now += 1000;
      b.repo.importBatch(batch(three)); // b detects the same candidate with a newer clock
      expect(b.repo.recurringBills().single.status, 'candidate');
      await round();
      await round();
      expect(a.repo.recurringBills(), isEmpty);
      expect(b.repo.recurringBills(), isEmpty);
      expect(b.repo.recurringBills(includeDismissed: true).single.status, 'dismissed');
      expect(table(a), table(b));
    });

    test('deleted on one device survives a late detection on the other', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(batch(three));
      now += 1000;
      a.repo.deleteRecurring('rec:synthetic_gym');
      a.upload(net);
      now += 1000;
      b.repo.importBatch(batch(three));
      await round();
      await round();
      expect(a.repo.recurringBills(includeDismissed: true), isEmpty);
      expect(b.repo.recurringBills(includeDismissed: true), isEmpty);
      expect(table(a), table(b));
    });

    test('the payment lands on both devices before they sync: both mark the same cycle paid and converge', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(batch(three));
      a.repo.confirmRecurring('rec:synthetic_gym');
      await round();
      await round();
      final pay = gym('2026-03-11', 2999);
      now += 1000;
      a.repo.importBatch(batch([pay]));
      now += 1000;
      b.repo.importBatch(batch([pay]));
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.lastPaidTx, x.nextDue), (pay.id, '2026-04-10'), reason: d.name);
      }
      await round();
      await round();
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.lastPaidTx, x.nextDue, x.expectedAmount), (pay.id, '2026-04-10', 2999), reason: d.name);
      }
      expect(table(a), table(b));
      expect(lwwDiff(a.repo, lastWriterWins(await opsInNet(net, key))), isEmpty);
    });

    test('a confirmed Rent bill is covered by the plan on both devices: same dueBills, nothing reserved', () async {
      final a = device('a'), b = device('b');
      final rent = [
        for (final d in ['2025-12-01', '2025-12-31', '2026-01-30']) n(d, -55000, 'Trajni nalog', 'Synthetic Landlord 1')
      ];
      a.repo.importBatch(batch(rent));
      a.repo.confirmRecurring('rec:synthetic_landlord');
      await round();
      await round();
      final st = WalletSettings.fromMap({'salary': 200000, 'rent': 55000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      for (final d in [a, b]) {
        final bill = d.repo.recurringBills().single;
        expect((bill.category, bill.coveredByPlan, bill.nextDue), ('Loan', true, '2026-03-01'), reason: d.name);
        final cz = d.repo.categorizer();
        final p = computePeriod([for (final t in d.repo.transactions()) cz.categorize(t)], st, const [], '2026-02-20',
            bills: [bill], table: CategoryTable.builtIn);
        expect(p.reservedBills, 0, reason: d.name);
        expect(p.dueBills.single.id, bill.id);
        expect(p.flexBudget, 145000, reason: 'salary minus the planned rent only');
      }
      expect(table(a), table(b));
    });

    test('a skip on one device moves the due date on the other', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(batch(three));
      a.repo.confirmRecurring('rec:synthetic_gym');
      await round();
      await round();
      now += 1000;
      await b.repo.skipRecurring('rec:synthetic_gym');
      await round();
      await round();
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.nextDue, x.lastPaidTx, x.confirmed), ('2026-04-09', null, true), reason: d.name);
      }
      expect(table(a), table(b));
    });

    test('the payment is imported on one device only: the sync marks it paid on the other (once, via runPendingMatch)', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(batch(three));
      a.repo.confirmRecurring('rec:synthetic_gym');
      await round();
      await round();
      // b holds the confirmed bill; a imports the payment, which reaches b only through sync.
      final pay = gym('2026-03-11', 2999);
      now += 1000;
      a.repo.importBatch(batch([pay]));
      await round();
      await round();
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.lastPaidTx, x.nextDue), (pay.id, '2026-04-10'), reason: d.name);
      }
      expect(table(a), table(b));
    });
  });
}
