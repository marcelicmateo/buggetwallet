import 'bills.dart' show occurrenceKey, plannedReserves;
import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';
import 'recurring.dart' show incomeFits, planRecurringPayments, RecurringPayments;

final _log = Logger('bw.budget');

/// In `incomeMode == 'received'`, the first [samePaydayDays] days of a pay period count `max(received, salary)` as
/// income: the employer pays the salary in parts over several days (owner: between the 10th and the 15th), so the
/// period is not shown short before every part has landed, and [PeriodBudget.lowIncome] stays false.
const samePaydayDays = 7;

/// The budget for the current pay period ("month" = salary to salary).
class PeriodBudget {
  final String start, end; // end = expected next payday (exclusive)

  /// [length]: days in the period (at least 1). [daysLeft]: days from today to [end], the real count: 0 once
  /// [paydayPassed], never raised to 1.
  final int length, daysLeft;

  /// Today is on or after [end]: the expected payday came and the period was not moved on yet. [daysLeft] is 0 and
  /// [allowanceToday] 0; nothing divides by the days left.
  final bool paydayPassed;

  /// The income received so far is short of the planned salary: received > 0, below 90 % of `salary`, at least 4
  /// days into the period and past the first [samePaydayDays] days (salary parts still arriving).
  final bool lowIncome;

  /// Only rows in `WalletSettings.currency` count in every sum here. The period's live rows in other currencies
  /// (income, extra, fixed and flex; transfers count nowhere) are left out: their signed sums by currency code.
  /// Empty when there are none.
  final Map<String, int> foreignByCurrency;
  final int received, extras, income, goalMonthly, fixedPlan;

  /// [allowanceToday] is never negative (0 once the flexible money is used up or [paydayPassed]); [safeToday] =
  /// allowanceToday − spentToday is negative when today's spending went over ([overToday]). [planDaily] (flexBudget ÷
  /// length) is 0 or negative when the plan leaves no flexible money ([overBudget]).
  final int flexBudget, spent, spentToday, remaining, allowanceToday, safeToday, planDaily;

  /// Tomorrow's allowance if nothing more is spent today: max(0, round(([flexBudget] − [spent]) ÷ ([daysLeft] − 1))).
  /// Null when the payday is tomorrow ([daysLeft] ≤ 1) or has passed: a new period starts then. Never negative.
  final int? allowanceTomorrow;
  final double elapsed;
  final Map<String, int> fixedPaid;

  /// Σ `reserve` of [dueCycles] not covered by a plan line ([DueCycle.coveredIn]): taken off the flexible money like
  /// the planned fixed costs (owner decision 2026-10-20). A due monthly (or shorter) bill in a fixed category
  /// ([RecurringBill.coveredByPlan]) is already in `fixedPlan`, so it is listed but not added; a long bill never is.
  final int reservedBills;

  /// The distinct bills of [dueCycles], ordered by `nextDue`, then label, then id ([dueBills]).
  final List<RecurringBill> dueBills;

  /// The cycles of confirmed bills this period holds money for ([dueCycles]), by due date.
  final List<DueCycle> dueCycles;

  /// Σ `amount` of [duePlanned] (open planned costs with an amount dated from today to the day before payday) outside
  /// fixed categories, taken off the flexible money with [reservedBills] (§4.3). One in a fixed category
  /// ([PlannedCost.coveredByPlan]) is already in `fixedPlan`: listed, not added. So is a bill's row without a category
  /// ([PlannedCost.needsCategory]) and one a due recurring bill reserves ([computePeriod]). 0 without planned costs.
  final int reservedPlanned;
  final List<PlannedCost> duePlanned;

  /// The rows of [duePlanned] summed into [reservedPlanned] ([plannedReserves]), in the same order: what "Coming up"
  /// counts, so the shown count and total are exactly what is reserved.
  final List<PlannedCost> reservedPlannedRows;

  /// P9: the cycles of confirmed recurring incomes due in `[start, end)` that have not landed yet ([expectedIncomeCycles]).
  /// Shown only: never added to any money here (owner: income counts only once it lands).
  final List<IncomeCycle> expectedIncome;

  /// P9: the money of confirmed recurring incomes that landed this period, at its actual amount, added to [flexBudget]:
  /// the period's live rows in the wallet's currency (dated from [start] to today, or to the day before [end] once
  /// [paydayPassed]) of kind extra whose payee (`merchantKey`) is a confirmed income's: positive ones whose payment fits
  /// that income's band or range ([incomeFits]; a one-off of the same payee stays an extra, for the goals), plus the
  /// negative ones (a refund of it), floored at 0. A split payment counts its extra parts only. 0 without one.
  final int landedIncome;

  const PeriodBudget({
    required this.start,
    required this.end,
    required this.length,
    required this.daysLeft,
    this.paydayPassed = false,
    this.lowIncome = false,
    this.foreignByCurrency = const {},
    required this.received,
    required this.extras,
    required this.income,
    required this.goalMonthly,
    required this.fixedPlan,
    required this.flexBudget,
    required this.spent,
    required this.spentToday,
    required this.remaining,
    required this.allowanceToday,
    required this.safeToday,
    required this.planDaily,
    this.allowanceTomorrow,
    required this.elapsed,
    required this.fixedPaid,
    this.reservedBills = 0,
    this.dueBills = const [],
    this.dueCycles = const [],
    this.reservedPlanned = 0,
    this.duePlanned = const [],
    this.reservedPlannedRows = const [],
    this.expectedIncome = const [],
    this.landedIncome = 0,
  });

  /// The extra income the goals flow offers ("put it into a goal"): [extras] without the rows already counted in
  /// [landedIncome] (those are spending money now), so nothing is counted twice.
  /// Never negative.
  int get extrasForGoals => extras - landedIncome < 0 ? 0 : extras - landedIncome;

  /// Positive = under budget so far, negative = over.
  int get aheadOfPace => (flexBudget * elapsed).round() - spent;

  /// How far the period's spending is over the flexible money: max(0, −[remaining]).
  int get overBy => remaining < 0 ? -remaining : 0;

  /// How far today's spending is over today's allowance: max(0, −[safeToday]).
  int get overToday => safeToday < 0 ? -safeToday : 0;

  /// The plan is over: spending passed the flexible money ([overBy] > 0) or the plan leaves none ([planDaily] ≤ 0).
  /// [affordability] then answers [Verdict.overBudget].
  bool get overBudget => overBy > 0 || planDaily <= 0;
}

/// Below 2^53 (the largest whole number a web number holds exactly): every sum of amounts asserts it in debug builds
/// (Q3; new amounts are capped at ±`maxAmountCents`, so at least 90,000 of them fit; rows synced from builds before Q
/// may reach `legacyRowCapCents`, where at least 9,000 fit).
const _exact = 9007199254740992;

/// [s], asserted exact ([_exact]); returned unchanged in release builds.
int _ok(int s) {
  assert(s.abs() < _exact, 'a sum of amounts passed 2^53');
  return s;
}

int _sum(Iterable<CategorizedTx> xs) => xs.fold(0, (s, x) => _ok(s + x.amount));

/// The confirmed bills of [bills] that still need paying out of this period's money: the distinct bills of
/// [dueCycles] (a monthly bill: `nextDue` before [end], the next payday, exclusive, and not paid in this period yet,
/// i.e. no `lastPaidTx` row in [txs] dated on or after [start]; a long bill until paid; a short one per occurrence).
/// Ordered by `nextDue`, then label, then id.
List<RecurringBill> dueBills(List<RecurringBill> bills, List<CategorizedTx> txs, String start, String end) {
  final seen = <String>{};
  return [
    for (final c in dueCycles(bills, txs, start, end, payments: const RecurringPayments({}), currency: ''))
      if (seen.add(c.bill.id)) c.bill
  ];
}

/// One cycle of a confirmed recurring bill that a pay period holds money for ([dueCycles]): [due] its due date,
/// [paid] the cents already paid of it (parts, [RecurringPayments.partsPaid]), [reserve] what is still set aside,
/// `max(0, reserveAmount − paid)`.
class DueCycle {
  final RecurringBill bill;
  final String due;
  final int reserve;
  final int paid;
  const DueCycle({required this.bill, required this.due, required this.reserve, required this.paid});

  /// Covered by a monthly plan line, so listed but not added to `reservedBills`: a monthly (or shorter) bill in a fixed
  /// category of [t] ([RecurringBill.coveredByPlanIn]). A long bill is never covered (owner: the money must be there).
  bool coveredIn(CategoryTable t) => !bill.isLong && bill.coveredByPlanIn(t);
}

/// One cycle of a confirmed recurring income (P9) due in a pay period and not landed yet ([PeriodBudget.expectedIncome]):
/// [due] its date, [amount] what is expected: `expectedAmount`, or the low end of the range ([RecurringBill.hasRange]).
class IncomeCycle {
  final RecurringBill bill;
  final String due;
  final int amount;
  const IncomeCycle({required this.bill, required this.due, required this.amount});
}

/// The cycles of the confirmed incomes of [bills] ([RecurringBill.isIncome]; bills are skipped) due in [start] ..
/// [end] (exclusive) that have not landed: from `nextDue` on by `intervalDays`, those dated from [start] to before
/// [end], except a cycle with a landing payment in [txs]: a live positive payment of the payee in [currency] (not a
/// transfer) whose amount fits ([incomeFits]), dated from `due − intervalDays ~/ 2` to `due + tolerance` (an early
/// landing hides it too). By due date, then label, then id. [txs]: the expanded or whole list (whole payments are used).
List<IncomeCycle> expectedIncomeCycles(List<RecurringBill> bills, List<CategorizedTx> txs, String start, String end,
    {required String currency}) {
  final live = [
    for (final b in bills)
      if (b.isIncome && b.confirmed && isIsoDate(b.nextDue) && b.expectedAmount > 0) b
  ];
  if (live.isEmpty) return const [];
  final payees = {for (final b in live) b.payee};
  final landings = <String, List<String>>{}; // payee -> dates of positive payments (amount checked per income below)
  final amounts = <String, List<int>>{};
  final seen = <String>{}; // one entry per payment (the parts of a split share it)
  for (final t in txs) {
    if (!t.tx.live || t.tx.currency != currency || t.tx.amount <= 0 || t.kind == BudgetKind.transfer) continue;
    final key = merchantKey(t.tx);
    if (!payees.contains(key) || !seen.add(t.tx.id)) continue;
    (landings[key] ??= []).add(t.date);
    (amounts[key] ??= []).add(t.tx.amount);
  }
  final out = <IncomeCycle>[];
  for (final b in live) {
    final amount = b.hasRange ? b.minAmount! : b.expectedAmount;
    final dates = landings[b.payee] ?? const <String>[], cents = amounts[b.payee] ?? const <int>[];
    bool landed(String due) {
      final from = addDays(due, -(b.intervalDays ~/ 2)), to = addDays(due, b.tolerance);
      for (var i = 0; i < dates.length; i++) {
        if (dates[i].compareTo(from) >= 0 && dates[i].compareTo(to) <= 0 && incomeFits(b, cents[i])) return true;
      }
      return false;
    }

    var d = b.nextDue;
    for (var n = 0; n < _maxCycles && d.compareTo(end) < 0; n++) {
      if (d.compareTo(start) >= 0 && !landed(d)) out.add(IncomeCycle(bill: b, due: d, amount: amount));
      d = addDays(d, b.intervalDays);
    }
  }
  out.sort((a, b) {
    var d = a.due.compareTo(b.due);
    if (d == 0) d = a.bill.label.compareTo(b.bill.label);
    if (d == 0) d = a.bill.id.compareTo(b.bill.id);
    return d;
  });
  return out;
}

/// Most cycles of one short bill a period lists (a guard; a pay period holds about five weekly ones).
const _maxCycles = 100;

/// The cycles of [bills] that the pay period [start] .. [end] (exclusive, the next payday) holds money for, by due
/// date, then label, then id (P4 §4). Confirmed bills only; a [RecurringBill.finished] one has none.
/// - **Monthly** (27..31 days): its `nextDue` cycle when before [end] (overdue included) and not paid in this period
///   (no `lastPaidTx` row in [txs] dated on or after [start]), as before P4.
/// - **Short** ([RecurringBill.isShort]): `nextDue` (overdue included) and every `nextDue + k × intervalDays` (k ≥ 1)
///   from [start] up to before [end], not past `endsBy`: a weekly bill reserves each week in the period. Only the first
///   cycle can hold parts.
/// - **Long** ([RecurringBill.isLong]): the `nextDue` cycle only, whatever its date (also after [end]), until paid or
///   skipped: held in full from confirmation (owner). The paid-in-this-period rule does not apply: once a payment moves
///   `nextDue` on, the next cycle is held at once. A cycle whose paying row is here but not yet recorded
///   ([RecurringPayments.paidBy]) reserves 0.
/// The first cycle's [DueCycle.paid] = [RecurringPayments.partsPaid], but 0 once that cycle's match window closed
/// before [start] (`nextDue + tolerance < start`): parts that never added up do not lower the reserve of later periods
/// (the owner marks the cycle paid or skips it). [payments] defaults to [planRecurringPayments] over [txs] in
/// [currency] (the wallet's, `WalletSettings.currency`; used only then). Recurring incomes (P9,
/// [RecurringBill.isIncome]) never have a cycle here: nothing is reserved for income.
List<DueCycle> dueCycles(List<RecurringBill> bills, List<CategorizedTx> txs, String start, String end,
    {RecurringPayments? payments, required String currency}) {
  final live = [
    for (final b in bills)
      if (!b.isIncome && b.confirmed && isIsoDate(b.nextDue) && !b.finished) b
  ];
  if (live.isEmpty) return const [];
  // Q8: a payment linked to an IOU (money lent or paid back) never pays a bill.
  final pay = payments ??
      planRecurringPayments(
          live,
          wholePayments([
            for (final t in txs)
              if (!t.iou) t
          ]),
          currency: currency);
  final paidOn = <String, String>{for (final t in txs) t.tx.id: t.date};
  final out = <DueCycle>[];
  DueCycle first(RecurringBill b) {
    final paid = addDays(b.nextDue, b.tolerance).compareTo(start) < 0 ? 0 : pay.partsPaid(b.id);
    final r = b.reserveAmount - paid;
    return DueCycle(bill: b, due: b.nextDue, reserve: r < 0 ? 0 : r, paid: paid);
  }

  for (final b in live) {
    if (b.isLong) {
      if (pay.paidBy[b.id] case final Tx row) {
        out.add(DueCycle(bill: b, due: b.nextDue, reserve: 0, paid: -row.amount));
      } else {
        out.add(first(b));
      }
      continue;
    }
    if (b.nextDue.compareTo(end) >= 0) continue;
    if (!b.isShort) {
      if (!(b.lastPaidTx != null && (paidOn[b.lastPaidTx]?.compareTo(start) ?? -1) >= 0)) out.add(first(b));
      continue;
    }
    out.add(first(b));
    // Later occurrences from the first one on or after the period start (k ≥ 1); only the cycles added are capped.
    final i = b.intervalDays;
    final behind = daysBetween(b.nextDue, start);
    final k0 = behind <= 0 ? 1 : (behind + i - 1) ~/ i;
    var d = addDays(b.nextDue, (k0 < 1 ? 1 : k0) * i);
    final last = b.endsBy;
    for (var n = 1; n < _maxCycles && d.compareTo(end) < 0 && (last == null || d.compareTo(last) <= 0); n++) {
      out.add(DueCycle(bill: b, due: d, reserve: b.reserveAmount, paid: 0));
      d = addDays(d, i);
    }
  }
  out.sort((a, b) {
    var d = a.due.compareTo(b.due);
    if (d == 0) d = a.bill.label.compareTo(b.bill.label);
    if (d == 0) d = a.bill.id.compareTo(b.bill.id);
    return d;
  });
  return out;
}

/// The planned costs of [planned] that still reserve money in the period ending at [end] (the next payday,
/// exclusive): open, with an amount, dated from [today] to the day before [end]. A cost dated before today reserves
/// nothing (its day has passed: the real row is in spending); paid, skipped and deleted ones never do. Ordered by date, then
/// title, then id.
List<PlannedCost> duePlanned(List<PlannedCost> planned, String today, String end) => [
      for (final p in planned)
        if (p.isOpen && p.amount != null && p.amount! > 0 && p.date.compareTo(today) >= 0 && p.date.compareTo(end) < 0) p,
    ]..sort(comparePlanned);

/// The budget for the pay period that holds [today]. [bills] (`WalletRepo.recurringBills()`): confirmed recurring
/// bills due before the next payday and not paid yet are listed ([PeriodBudget.dueBills]); those in flex categories are
/// reserved ([PeriodBudget.reservedBills]), taken off the flexible money on the same path as the planned fixed costs, so
/// the daily plan and safe-to-spend drop by them until the bank row that pays each one lands. Bills in fixed categories
/// are already counted in the fixed-cost settings and change nothing ([RecurringBill.coveredByPlan]). [planned]
/// (`WalletRepo.plannedCosts()`): the open ones with an amount dated from today to the day before payday
/// ([duePlanned]) are reserved the same way ([PeriodBudget.reservedPlanned]), except those in fixed categories
/// ([PlannedCost.coveredByPlan], like bills), a bill's row that a confirmed recurring bill in [bills] already plans
/// in this period ([plannedCoverage], BILLS_API.md §3: listed, not added; only when that bill's covering occurrence is the
/// one [dueBills] lists here, the cycle just paid or skipped, or the bill is `coveredByPlan` — a slip due before
/// payday whose recurring cycle falls after it is reserved here) and a bill's row without a category
/// ([PlannedCost.needsCategory]: listed, not added; the owner is asked for the category). The rule is
/// [plannedReserves]; the rows it accepts are [PeriodBudget.reservedPlannedRows]. Without planned costs every number is as before.
/// [table] decides which categories are fixed ([RecurringBill.coveredByPlanIn], [PlannedCost.coveredByPlanIn]); it is
/// required so a custom fixed category is never reserved a second time as flex. [txs] is the expanded list (P6,
/// `Categorizer.expand`: each part of a split payment counts in its own category; recurring bills are matched on the
/// whole payments, [wholePayments]).
///
/// P9: the recurring incomes in [bills] ([RecurringBill.isIncome]) reserve and plan nothing. Their cycles due this
/// period and not landed are listed ([PeriodBudget.expectedIncome], never added); the rows of a confirmed income's
/// payee that landed ([PeriodBudget.landedIncome], kind extra, positive) are added to the flexible money. Without a
/// confirmed income every number is as before.
///
/// P15: [txs] may be the converted list (`inHomeCurrency`); then [matchRows] is the raw expanded list. Bills and incomes
/// are matched on [matchRows] (default [txs]), so a payment in another currency never pays or lands a recurring cycle by
/// its converted amount; the sums use [txs].
PeriodBudget computePeriod(List<CategorizedTx> txs, WalletSettings st, List<Goal> goals, String today,
    {List<RecurringBill> bills = const [],
    List<PlannedCost> planned = const [],
    required CategoryTable table,
    List<CategorizedTx>? matchRows}) {
  final raw = matchRows ?? txs;
  final incomes = [
    for (final b in bills)
      if (b.isIncome) b
  ];
  final outBills = incomes.isEmpty
      ? bills
      : [
          for (final b in bills)
            if (!b.isIncome) b
        ];
  final start = st.periodStart ?? today;
  final end = nextPayday(start, st.paydayDay);
  final length = daysBetween(start, end).clamp(1, 1000);
  final paydayPassed = today.compareTo(end) >= 0;
  final daysLeft = paydayPassed ? 0 : daysBetween(today, end);
  // Once the payday has passed, rows dated on or after it belong to the next period, not to this one.
  final lastDay = paydayPassed ? addDays(end, -1) : today;
  final inPeriod = <CategorizedTx>[];
  final foreign = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || t.date.compareTo(start) < 0 || t.date.compareTo(lastDay) > 0) continue;
    if (t.tx.currency == st.currency) {
      inPeriod.add(t);
    } else if (t.kind != BudgetKind.transfer) {
      foreign[t.tx.currency] = (foreign[t.tx.currency] ?? 0) + t.amount;
    }
  }
  final received = _sum(inPeriod.where((t) => t.kind == BudgetKind.income));
  final extras = _sum(inPeriod.where((t) => t.kind == BudgetKind.extra));
  final age = daysBetween(start, today);
  // Salary parts can still be on their way only while the period runs; an ended period has all it will get.
  final partsArriving = !paydayPassed && age < samePaydayDays;
  final income = st.incomeMode == 'received' && received > 0 ? (partsArriving && st.salary > received ? st.salary : received) : st.salary;
  final lowIncome = received > 0 && received * 10 < st.salary * 9 && age >= 4 && !partsArriving;
  final goalMonthly = goals.fold<int>(0, (s, g) => _ok(s + g.monthly));
  // Plan lines of custom fixed categories (P1) count with rent, loan and subs; only lines the table still allows.
  final fixedPlan =
      st.rent + st.loan + st.subs + st.planLines.entries.fold<int>(0, (s, e) => table.hasPlanLine(e.key) ? _ok(s + e.value) : s);
  final cycles = dueCycles(outBills, raw, start, end, currency: st.currency);
  final seenBills = <String>{};
  final due = [
    for (final c in cycles)
      if (seenBills.add(c.bill.id)) c.bill
  ];
  final reservedBills = cycles.fold<int>(0, (s, c) => _ok(s + (c.coveredIn(table) ? 0 : c.reserve)));
  final duePl = duePlanned(planned, today, end);
  final counted = {for (final c in cycles) occurrenceKey(c.bill.id, c.due)};
  final reservedRows = [
    for (final p in duePl)
      if (plannedReserves(p, outBills, counted, table: table)) p
  ];
  final reservedPlanned = reservedRows.fold<int>(0, (s, p) => _ok(s + p.amount!));
  // P9: only the payees of confirmed incomes; the actual landed amounts (never the expected ones).
  final byPayee = <String, List<RecurringBill>>{};
  for (final b in incomes) {
    if (b.confirmed && b.payee.isNotEmpty) (byPayee[b.payee] ??= []).add(b);
  }
  var landedIncome = 0;
  if (byPayee.isNotEmpty) {
    for (final t in inPeriod) {
      // A converted row (P15) is a payment in another currency: it never matches an income, as on the raw list.
      if (t.kind != BudgetKind.extra || t.amount == 0 || t.originalCurrency != null) continue;
      final mine = byPayee[merchantKey(t.tx)];
      if (mine == null) continue;
      // The payment (whole, not the part) must fit one of the payee's incomes; a refund always counts against it.
      if (t.amount < 0 || mine.any((b) => incomeFits(b, t.tx.amount))) landedIncome += t.amount;
    }
    if (landedIncome < 0) landedIncome = 0;
  }
  final expected = expectedIncomeCycles(incomes, raw, start, end, currency: st.currency);
  final flexBudget = income - fixedPlan - goalMonthly - reservedBills - reservedPlanned + landedIncome;
  final flex = inPeriod.where((t) => t.kind == BudgetKind.flex);
  final spent = -_sum(flex);
  final spentToday = -_sum(flex.where((t) => t.date == today));
  final leftForToday = flexBudget - (spent - spentToday);
  final allowanceToday = paydayPassed || leftForToday <= 0 ? 0 : (leftForToday / daysLeft).round();
  final leftAfterToday = flexBudget - spent;
  final allowanceTomorrow = paydayPassed || daysLeft <= 1 ? null : (leftAfterToday <= 0 ? 0 : (leftAfterToday / (daysLeft - 1)).round());
  final elapsed = ((daysBetween(start, today) + 1) / length).clamp(0.0, 1.0);
  final fixedPaid = <String, int>{};
  for (final t in inPeriod.where((t) => t.kind == BudgetKind.fixed)) {
    final c = table.topLevel(t.category); // a child counts in its plan line
    fixedPaid[c] = (fixedPaid[c] ?? 0) - t.amount;
  }
  // Dates and counts only, never amounts.
  if (_log.isLoggable(Level.FINER)) {
    logEvent(_log, Level.FINER, 'budget.period', {
      'start': start,
      'end': end,
      'saved': st.periodStart != null,
      'days': length,
      'daysLeft': daysLeft,
      'passed': paydayPassed,
      'tx': inPeriod.length,
      'foreignCurrencies': foreign.length,
      'incomeMode': st.incomeMode,
      'goals': goals.length,
      'bills': outBills.length,
      'dueBills': due.length,
      'dueCycles': cycles.length,
      'planned': planned.length,
      'duePlanned': duePl.length,
      'incomes': incomes.length,
      'expectedIncome': expected.length,
    });
  }
  return PeriodBudget(
    start: start,
    end: end,
    length: length,
    daysLeft: daysLeft,
    paydayPassed: paydayPassed,
    lowIncome: lowIncome,
    foreignByCurrency: foreign,
    received: received,
    extras: extras,
    income: income,
    goalMonthly: goalMonthly,
    fixedPlan: fixedPlan,
    flexBudget: flexBudget,
    spent: spent,
    spentToday: spentToday,
    remaining: flexBudget - spent,
    allowanceToday: allowanceToday,
    safeToday: allowanceToday - spentToday,
    planDaily: (flexBudget / length).round(),
    allowanceTomorrow: allowanceTomorrow,
    elapsed: elapsed,
    fixedPaid: fixedPaid,
    reservedBills: reservedBills,
    dueBills: due,
    dueCycles: cycles,
    reservedPlanned: reservedPlanned,
    duePlanned: duePl,
    reservedPlannedRows: reservedRows,
    expectedIncome: expected,
    landedIncome: landedIncome,
  );
}

class MonthSummary {
  final String month;
  final int income, out;
  final Map<String, int> byCategory;

  /// The month's live rows in other currencies than the one summed (income, extra, fixed and flex): signed sums by
  /// currency code, left out of every other field. Empty when there are none.
  final Map<String, int> foreignByCurrency;
  const MonthSummary(this.month, this.income, this.out, this.byCategory, {this.foreignByCurrency = const {}});
  int get net => income - out;
}

/// The one "Where it goes" rule for a row: live, in [currency], in a fixed or flex category (refunds count, negative).
/// Shared by [monthSummary], [averageByCategory]/[suggestBudgets] and the N3 graphs (`insights.dart`).
bool countsAsSpending(CategorizedTx t, String currency) =>
    t.tx.live && t.tx.currency == currency && (t.kind == BudgetKind.fixed || t.kind == BudgetKind.flex);

/// Money in and out of calendar [month] (`YYYY-MM`), counting only rows in [currency] (`WalletSettings.currency`);
/// the others are in [MonthSummary.foreignByCurrency]. Like every money sum here (budgets, averages, the review),
/// [txs] is the expanded list (P6, `Categorizer.expand`).
MonthSummary monthSummary(List<CategorizedTx> txs, String month, {required String currency}) {
  var income = 0, out = 0;
  final byCat = <String, int>{};
  final foreign = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || monthOf(t.date) != month) continue;
    if (t.tx.currency != currency) {
      if (t.kind != BudgetKind.transfer) foreign[t.tx.currency] = (foreign[t.tx.currency] ?? 0) + t.amount;
      continue;
    }
    if (countsAsSpending(t, currency)) {
      out -= t.amount;
      byCat[t.category] = (byCat[t.category] ?? 0) - t.amount;
    } else if (t.kind == BudgetKind.income || t.kind == BudgetKind.extra) {
      income += t.amount;
    }
  }
  return MonthSummary(month, income, out, byCat, foreignByCurrency: foreign);
}

/// Spending (fixed + flex, refunds subtracted, transfers and income left out: the "Where it goes" sums) per
/// category over the live rows of [months] in [currency], in one pass.
Map<String, int> _outByCategory(List<CategorizedTx> txs, Set<String> months, String currency) {
  final out = <String, int>{};
  for (final t in txs) {
    if (countsAsSpending(t, currency) && months.contains(monthOf(t.date))) out[t.category] = (out[t.category] ?? 0) - t.amount;
  }
  return out;
}

/// The [count] months before [month] (exclusive), oldest first.
List<String> _monthsBefore(String month, int count) => monthsEnding(month, count + 1)..removeLast();

/// Average monthly spending per category over the [months] calendar months before [month] (the month itself left
/// out), in cents, rounded to the cent. Always divided by [months]: a month without spend counts as zero. Only
/// categories with any spend in those months appear. Only rows in [currency] count. With [table], children's sums are
/// rolled up into their top-level category ([rollUp]) before dividing.
Map<String, int> averageByCategory(List<CategorizedTx> txs, String month,
    {int months = 6, required String currency, CategoryTable? table}) {
  final sums = rollUp(_outByCategory(txs, _monthsBefore(month, months).toSet(), currency), table ?? CategoryTable.builtIn);
  return {for (final e in sums.entries) e.key: (e.value / months).round()};
}

/// Budgets to propose for [month]: each category's average over the 6 months before it, rounded UP to the nearest
/// 1000 cents (10 €). A category whose average is zero or negative (refunds) is omitted. Only rows in [currency] count.
/// With [table], per top-level category (children rolled up, [rollUp]): budgets are set on top-level categories only.
Map<String, int> suggestBudgets(List<CategorizedTx> txs, String month, {required String currency, CategoryTable? table}) {
  const months = 6, step = 1000;
  final sums = rollUp(_outByCategory(txs, _monthsBefore(month, months).toSet(), currency), table ?? CategoryTable.builtIn);
  return {
    for (final e in sums.entries)
      if (e.value > 0) e.key: (e.value + months * step - 1) ~/ (months * step) * step,
  };
}

/// The ways to fill the month's budgets in one go (BP): the averages of the last 3, 6 or 12 months, 90 % of the 6-month
/// average, the money the payday plan leaves for flexible spending, or 30 % of the salary (50/30/20 "wants").
enum BudgetPresetKind { avg3, avg6, avg12, spendLess, fitPlan, fiftyThirtyTwenty }

/// Budgets proposed by [budgetPreset]: category -> cents, [total] their sum. When [budgets] is empty, [empty] says
/// why in words the owner can read.
class BudgetPreset {
  final Map<String, int> budgets;
  final int total;
  final String? empty;
  const BudgetPreset(this.budgets, this.total, [this.empty]);
  const BudgetPreset.none(String reason)
      : budgets = const {},
        total = 0,
        empty = reason;
}

/// What the payday plan leaves for flexible spending per month: salary minus rent, loan, subs, the plan lines of live
/// custom fixed categories ([CategoryTable.hasPlanLine]) and the monthly part of every goal. Never below 0.
int monthlyFlex(WalletSettings st, {List<Goal> goals = const [], CategoryTable? table}) {
  final t = table ?? CategoryTable.builtIn;
  var left = st.salary - st.rent - st.loan - st.subs;
  for (final e in st.planLines.entries) {
    if (t.hasPlanLine(e.key)) left -= e.value;
  }
  for (final g in goals) {
    left -= g.monthly;
  }
  return left < 0 ? 0 : left;
}

/// Budgets for [month] by [kind] (see [BudgetPresetKind]); home [currency] rows only, per top-level category, from the
/// exact sums of the months before [month]. Amounts are cents. Nothing is written, no single row decides a category.
/// - avg3, avg6, avg12: the average rounded UP to 1000 cents (avg6 equals [suggestBudgets]).
/// - spendLess: 90 % of the exact 6-month average, rounded DOWN to 1000 cents; a category that reaches 0 is dropped.
/// - fitPlan: [monthlyFlex] in whole euros, split over the flex categories by their 6-month spend share.
/// - fiftyThirtyTwenty: 30 % of the salary in whole euros, split the same way.
/// The split uses the largest-remainder method in whole euros, so the parts sum exactly to the total; ties go to the
/// earlier category of the table.
BudgetPreset budgetPreset(BudgetPresetKind kind, List<CategorizedTx> txs, WalletSettings st, String month,
    {required String currency, CategoryTable? table, List<Goal> goals = const []}) {
  final t = table ?? CategoryTable.builtIn;
  const step = 1000;
  BudgetPreset done(Map<String, int> b) => BudgetPreset(Map.unmodifiable(b), b.values.fold(0, (s, v) => s + v));
  Map<String, int> sums(int months) => rollUp(_outByCategory(txs, _monthsBefore(month, months).toSet(), currency), t);
  BudgetPreset average(int months) {
    final s = sums(months);
    final b = {
      for (final e in s.entries)
        if (e.value > 0) e.key: (e.value + months * step - 1) ~/ (months * step) * step,
    };
    return b.isEmpty ? BudgetPreset.none('No spending in the last $months months.') : done(b);
  }

  BudgetPreset split(int cents) {
    final s = sums(6);
    final flex = {
      for (final e in s.entries)
        if (e.value > 0 && t.kindOf(e.key) == BudgetKind.flex) e.key: e.value,
    };
    if (s.values.every((v) => v <= 0)) return const BudgetPreset.none('No spending in the last 6 months.');
    if (flex.isEmpty) return const BudgetPreset.none('No flexible spending in the last 6 months.');
    final euros = cents ~/ 100;
    if (euros <= 0) return const BudgetPreset.none('Nothing is left for flexible spending after your fixed costs and goals.');
    final total = flex.values.fold(0, (a, v) => a + v);
    final order = t.topLevelIds;
    int rank(String id) {
      final i = order.indexOf(id);
      return i < 0 ? order.length : i;
    }

    final ids = flex.keys.toList()
      ..sort((a, b) {
        final d = rank(a).compareTo(rank(b));
        return d != 0 ? d : a.compareTo(b);
      });
    final parts = {for (final id in ids) id: euros * flex[id]! ~/ total};
    var left = euros - parts.values.fold(0, (a, v) => a + v);
    // List.sort is not stable: equal remainders fall back to the table order explicitly (ids is already in that order).
    final pos = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final byRemainder = [...ids]..sort((a, b) {
        final d = (euros * flex[b]! % total).compareTo(euros * flex[a]! % total);
        return d != 0 ? d : pos[a]!.compareTo(pos[b]!);
      });
    for (final id in byRemainder) {
      if (left <= 0) break;
      parts[id] = parts[id]! + 1;
      left--;
    }
    return done({
      for (final id in ids)
        if (parts[id]! > 0) id: parts[id]! * 100,
    });
  }

  switch (kind) {
    case BudgetPresetKind.avg3:
      return average(3);
    case BudgetPresetKind.avg6:
      return average(6);
    case BudgetPresetKind.avg12:
      return average(12);
    case BudgetPresetKind.spendLess:
      final b = {
        for (final e in sums(6).entries)
          if (e.value > 0 && e.value * 9 ~/ (6 * 10 * step) > 0) e.key: e.value * 9 ~/ (6 * 10 * step) * step,
      };
      return b.isEmpty ? const BudgetPreset.none('No spending in the last 6 months.') : done(b);
    case BudgetPresetKind.fitPlan:
      if (st.salary <= 0) return const BudgetPreset.none('Set your salary in the payday plan first.');
      return split(monthlyFlex(st, goals: goals, table: t));
    case BudgetPresetKind.fiftyThirtyTwenty:
      if (st.salary <= 0) return const BudgetPreset.none('Set your salary in the payday plan first.');
      return split(st.salary * 30 ~/ 100);
  }
}

/// One row of the budget Suggest diff ([budgetProposals]): [current] is null when the category has no budget (or 0).
class BudgetProposal {
  final String category;
  final int? current;
  final int suggested;
  const BudgetProposal({required this.category, this.current, required this.suggested});
  bool get fillsEmpty => current == null;
}

/// What Suggest would change: each [suggested] category whose [current] budget is missing or 0 (fills an empty field)
/// or differs; equal values are left out. Empty fields first, then by category name. Nothing is written.
List<BudgetProposal> budgetProposals(Map<String, int> current, Map<String, int> suggested) {
  final out = <BudgetProposal>[];
  for (final MapEntry(key: c, value: v) in suggested.entries) {
    final have = current[c];
    if (have == null || have == 0) {
      out.add(BudgetProposal(category: c, suggested: v));
    } else if (have != v) {
      out.add(BudgetProposal(category: c, current: have, suggested: v));
    }
  }
  out.sort((a, b) {
    if (a.fillsEmpty != b.fillsEmpty) return a.fillsEmpty ? -1 : 1;
    return a.category.compareTo(b.category);
  });
  return out;
}

/// One category of [BudgetVsActual]. Cents; [budget] is null when none is set.
class CategoryBudgetLine {
  final String category;
  final int? budget;
  final int actual; // spending this month, refunds subtracted (can be negative)
  final int average6; // average of the 6 months before
  final int elapsedDays, daysInMonth; // see [BudgetVsActual]

  const CategoryBudgetLine({
    required this.category,
    required this.budget,
    required this.actual,
    required this.average6,
    required this.elapsedDays,
    required this.daysInMonth,
  });

  /// budget − actual; null without a budget.
  int? get remaining => budget == null ? null : budget! - actual;

  /// actual ÷ (budget × elapsedDays ÷ daysInMonth): ≤ 1.0 on pace, > 1.0 behind. Null without a budget, with a zero
  /// budget, or before the month starts (elapsedDays 0).
  double? get pace {
    final b = budget;
    if (b == null || b == 0 || elapsedDays == 0) return null;
    return actual * daysInMonth / (b * elapsedDays);
  }

  bool get over => budget != null && actual > budget!;
}

/// Budget vs actual per category for one calendar [month].
class BudgetVsActual {
  final String month; // YYYY-MM
  final List<CategoryBudgetLine> lines; // every category with a budget or any spend; actual desc, then name
  final int budgetTotal; // over budgeted categories
  final int actualTotal; // over all lines
  final int? remainingTotal; // Σ remaining over budgeted categories; null when nothing is budgeted
  final int overCount, budgetedCount;
  final int elapsedDays; // day of month for the current month, the whole month for a past one, 0 for a future one
  final int daysInMonth;

  const BudgetVsActual({
    required this.month,
    required this.lines,
    required this.budgetTotal,
    required this.actualTotal,
    required this.remainingTotal,
    required this.overCount,
    required this.budgetedCount,
    required this.elapsedDays,
    required this.daysInMonth,
  });
}

/// Compares [budgets] (`category -> cents per month`, see `WalletSettings.categoryBudgets`) with what went out in
/// [month] per category, exactly as [monthSummary] counts it (live rows, fixed + flex, refunds subtracted, transfers
/// and income left out; only rows in [currency]). [today] (`YYYY-MM-DD`) decides how much of the month has elapsed
/// for the pace. With [table], children are rolled up into their top-level category ([rollUp]): budgets are set on
/// top-level categories only.
BudgetVsActual budgetVsActual(List<CategorizedTx> txs, String month, Map<String, int> budgets,
    {required String today, required String currency, CategoryTable? table}) {
  final t = table ?? CategoryTable.builtIn;
  final actual = rollUp(monthSummary(txs, month, currency: currency).byCategory, t);
  final average = averageByCategory(txs, month, currency: currency, table: t);
  final current = monthOf(today);
  final days = daysInMonth(month);
  final elapsed = month == current ? dayOf(today) : (month.compareTo(current) < 0 ? days : 0);
  final lines = [
    for (final c in {...budgets.keys, ...actual.keys})
      CategoryBudgetLine(
        category: c,
        budget: budgets[c],
        actual: actual[c] ?? 0,
        average6: average[c] ?? 0,
        elapsedDays: elapsed,
        daysInMonth: days,
      ),
  ]..sort((a, b) {
      final d = b.actual.compareTo(a.actual);
      return d != 0 ? d : a.category.compareTo(b.category);
    });
  var budgetTotal = 0, actualTotal = 0, remainingTotal = 0, overCount = 0, budgetedCount = 0;
  for (final l in lines) {
    actualTotal += l.actual;
    if (l.over) overCount++;
    if (l.budget case final b?) {
      budgetedCount++;
      budgetTotal += b;
      remainingTotal += b - l.actual;
    }
  }
  // Month and counts only, never amounts.
  if (_log.isLoggable(Level.FINER)) {
    logEvent(_log, Level.FINER, 'budget.vsActual',
        {'month': month, 'lines': lines.length, 'budgeted': budgetedCount, 'over': overCount, 'elapsed': elapsed});
  }
  return BudgetVsActual(
    month: month,
    lines: lines,
    budgetTotal: budgetTotal,
    actualTotal: actualTotal,
    remainingTotal: budgetedCount == 0 ? null : remainingTotal,
    overCount: overCount,
    budgetedCount: budgetedCount,
    elapsedDays: elapsed,
    daysInMonth: days,
  );
}

/// The first date on or after [from] that falls on weekday [day] (1 = Monday .. 7 = Sunday).
String _nextWeekday(String from, int day) {
  final d = parseIso(from);
  return addDays(from, (day - d.weekday + 7) % 7);
}

/// The weekly review: whether it is due on [today] and what each step holds.
///
/// Due from the first `reviewDay` after the last review (`lastReview` + 1 on) until it is done ([nextReviewDate] is
/// that day; when the review is not due yet, the next one). Never reviewed: due at once ([nextReviewDate] = the last
/// `reviewDay` on or before today), so a new wallet shows the review the first time it is opened. Steps: `import` is
/// 0 (the UI fills it after importing); `categories` = live spending rows (fixed and flex) of the last 7 days whose
/// category is not user-set (the rows a merchant rule can be learnt from); `pace` = categories of the current calendar
/// month behind pace or over budget ([budgetVsActual]); `wishlist` = waiting items whose cooling-off (`coolHours`)
/// has run out by [nowMillis] (default: the end of [today], UTC). The last review is the newest of [reviewDates]
/// (`WalletRepo.reviewDates`, the synced `review` rows) and the legacy `lastReview` setting; [ReviewState.streak] =
/// [reviewStreak] of them.
ReviewState reviewState(List<CategorizedTx> txs, WalletSettings st, List<WishItem> wishes, Map<String, int> budgets,
    {required String today, int? nowMillis, CategoryTable? table, List<String> reviewDates = const []}) {
  final cats = table ?? CategoryTable.builtIn;
  String? last = st.lastReview;
  for (final d in reviewDates) {
    if (isIsoDate(d) && (last == null || d.compareTo(last) > 0)) last = d;
  }
  final streak = reviewStreak(reviewDates, legacyLast: st.lastReview, legacyStreak: st.reviewStreak);
  final String next;
  final bool due;
  if (last == null) {
    final coming = _nextWeekday(today, st.reviewDay);
    next = coming == today ? coming : addDays(coming, -7);
    due = true;
  } else {
    next = _nextWeekday(addDays(last, 1), st.reviewDay);
    due = today.compareTo(next) >= 0;
  }
  final since = addDays(today, -7);
  var automatic = 0;
  for (final t in txs) {
    if (!t.tx.live || t.date.compareTo(since) <= 0 || t.date.compareTo(today) > 0) continue;
    if (t.kind != BudgetKind.fixed && t.kind != BudgetKind.flex) continue;
    if (t.isPart) continue; // the owner gave each part its main tag
    final own = t.tx.category;
    if (own == null || !cats.isLive(own)) automatic++; // no override, or one that is deleted or unknown here
  }
  final pace = budgetVsActual(txs, monthOf(today), budgets, today: today, currency: st.currency, table: cats)
      .lines
      .where((l) => l.over || (l.pace ?? 0) > 1)
      .length;
  final now = nowMillis ?? parseIso(addDays(today, 1)).millisecondsSinceEpoch;
  final waiting = wishes.where((w) => w.status == 'waiting' && w.hoursLeft(st.coolHours, now) <= 0).length;
  final steps = [
    const ReviewStep('import', 0),
    ReviewStep('categories', automatic),
    ReviewStep('pace', pace),
    ReviewStep('wishlist', waiting),
  ];
  // Dates and counts only.
  logEvent(_log, Level.FINER, 'review.state',
      {'due': due, 'next': next, 'streak': streak, 'categories': automatic, 'pace': pace, 'wishlist': waiting});
  return ReviewState(due: due, nextReviewDate: next, streak: streak, steps: steps);
}

/// The weekly-review streak (V3) from the dates reviews were done ([dates], any order, duplicates and non-dates
/// ignored) and the legacy base older builds stored ([legacyLast] = `lastReview`, [legacyStreak] = `reviewStreak`,
/// never written since schema 18). Walks back from the newest date while the gap to the previous one is < 14 days (no
/// weekly review day skipped; the same rule `markReviewDone` used for the counter). When the walk reaches [legacyLast]
/// (< 14 days before the oldest date of the chain, or one of its dates), [legacyStreak] counts that day and every
/// review before it, and the walk stops there. No dates: [legacyStreak] when [legacyLast] is set, else 0. Clamped to
/// 0 .. [WalletSettings.maxStreak].
int reviewStreak(List<String> dates, {String? legacyLast, int legacyStreak = 0}) {
  final legacy = legacyLast != null && isIsoDate(legacyLast) ? legacyLast : null;
  final days = {
    for (final d in dates)
      if (isIsoDate(d)) d,
    if (legacy != null) legacy,
  }.toList()
    ..sort();
  var streak = 0;
  String? newer;
  for (final d in days.reversed) {
    if (newer != null && daysBetween(d, newer) >= 14) break;
    if (d == legacy) {
      streak += legacyStreak;
      break;
    }
    streak++;
    newer = d;
  }
  return streak.clamp(0, WalletSettings.maxStreak);
}

/// [overBudget]: the plan is already over ([PeriodBudget.overBudget]), whatever the price.
enum Verdict { now, tight, later, overBudget }

class Affordability {
  final Verdict verdict;

  /// The daily allowance left after buying it, never negative (0 when it does not fit or the payday passed).
  final int newDaily;
  const Affordability(this.verdict, this.newDaily);
}

/// Whether [price] (cents, in the settings' currency) fits the period [p]. [Verdict.overBudget] whenever the plan is
/// over ([PeriodBudget.overBudget]), never [Verdict.now]; [Verdict.later] once the payday passed (no days left to
/// spread it over) or when it does not fit; [Verdict.now] when the new daily allowance keeps 75 % of the plan's,
/// [Verdict.tight] when it fits with less.
Affordability affordability(int price, PeriodBudget p) {
  if (p.overBudget) return const Affordability(Verdict.overBudget, 0);
  if (p.paydayPassed || p.daysLeft <= 0) return const Affordability(Verdict.later, 0);
  final left = p.flexBudget - p.spent - price;
  if (left <= 0) return const Affordability(Verdict.later, 0);
  final newDaily = (left / p.daysLeft).round();
  if (newDaily >= p.planDaily * 0.75) return Affordability(Verdict.now, newDaily);
  return Affordability(Verdict.tight, newDaily);
}

/// Months until a goal is reached at its monthly amount, or null if never.
int? monthsToGoal(Goal g) {
  final left = g.target - g.saved;
  if (left <= 0) return 0;
  if (g.monthly <= 0) return null;
  return (left / g.monthly).ceil();
}

/// The verdict of one day of the pay period on Today's day dots (DD).
enum DayMark { within, over, today, toCome }

/// One day of the pay period ([periodDays]). [spent] and [allowance] (cents) are what Today said that day; both 0 for
/// [DayMark.today] and [DayMark.toCome] (no verdict yet).
class PeriodDay {
  const PeriodDay({required this.date, required this.mark, this.spent = 0, this.allowance = 0});

  final String date; // YYYY-MM-DD
  final DayMark mark;

  /// `computePeriod(..., today: date).spentToday`: that day's net flexible spending (negative = a net refund).
  final int spent;

  /// `computePeriod(..., today: date).allowanceToday`: that day's money.
  final int allowance;

  @override
  bool operator ==(Object other) =>
      other is PeriodDay && other.date == date && other.mark == mark && other.spent == spent && other.allowance == allowance;

  @override
  int get hashCode => Object.hash(date, mark, spent, allowance);

  @override
  String toString() => 'PeriodDay($date, ${mark.name}, $spent/$allowance)';
}

/// One [PeriodDay] per day of the pay period `[start, end)` that [computePeriod] gives for [today] (same arguments),
/// ascending. Each day before [today] (every day once the payday passed) is judged with exactly what
/// `computePeriod(..., today: d)` returns for `spentToday` and `allowanceToday`, with the rows known now:
/// [DayMark.over] when spent > allowance, else [DayMark.within] (equal, nothing spent or a net refund). [today] is
/// [DayMark.today], later days [DayMark.toCome]. Without a saved `periodStart` the period starts today, so no day is
/// judged. One pass over [txs]: the parts that do not depend on the day (bill cycles, fixed plan, goals) are computed
/// once, the rest from per-day sums; only the planned costs are re-checked per day ([duePlanned] depends on it).
List<PeriodDay> periodDays(List<CategorizedTx> txs, WalletSettings st, List<Goal> goals, String today,
    {List<RecurringBill> bills = const [],
    List<PlannedCost> planned = const [],
    required CategoryTable table,
    List<CategorizedTx>? matchRows}) {
  final start = st.periodStart ?? today;
  final end = nextPayday(start, st.paydayDay);
  final dates = <String>[];
  for (var d = start; d.compareTo(end) < 0 && dates.length < 1000; d = addDays(d, 1)) {
    dates.add(d);
  }
  final judged = dates.takeWhile((d) => d.compareTo(today) < 0).length;
  final out = <PeriodDay>[];
  if (judged > 0) {
    final raw = matchRows ?? txs;
    final incomes = [
      for (final b in bills)
        if (b.isIncome) b
    ];
    final outBills = incomes.isEmpty
        ? bills
        : [
            for (final b in bills)
              if (!b.isIncome) b
          ];
    final index = {for (var i = 0; i < judged; i++) dates[i]: i};
    final byPayee = <String, List<RecurringBill>>{};
    for (final b in incomes) {
      if (b.confirmed && b.payee.isNotEmpty) (byPayee[b.payee] ??= []).add(b);
    }
    // Per judged day: income rows, flexible rows, landed recurring income (the same rows computePeriod sums).
    final received = List<int>.filled(judged, 0);
    final flex = List<int>.filled(judged, 0);
    final landed = List<int>.filled(judged, 0);
    for (final t in txs) {
      if (!t.tx.live || t.tx.currency != st.currency) continue;
      final i = index[t.date];
      if (i == null) continue;
      switch (t.kind) {
        case BudgetKind.income:
          received[i] = _ok(received[i] + t.amount);
        case BudgetKind.flex:
          flex[i] = _ok(flex[i] + t.amount);
        case BudgetKind.extra:
          if (byPayee.isEmpty || t.amount == 0 || t.originalCurrency != null) break;
          final mine = byPayee[merchantKey(t.tx)];
          if (mine == null) break;
          if (t.amount < 0 || mine.any((b) => incomeFits(b, t.tx.amount))) landed[i] += t.amount;
        default:
          break;
      }
    }
    final goalMonthly = goals.fold<int>(0, (s, g) => _ok(s + g.monthly));
    final fixedPlan =
        st.rent + st.loan + st.subs + st.planLines.entries.fold<int>(0, (s, e) => table.hasPlanLine(e.key) ? _ok(s + e.value) : s);
    final cycles = dueCycles(outBills, raw, start, end, currency: st.currency);
    final reservedBills = cycles.fold<int>(0, (s, c) => _ok(s + (c.coveredIn(table) ? 0 : c.reserve)));
    final counted = {for (final c in cycles) occurrenceKey(c.bill.id, c.due)};
    var receivedSoFar = 0, flexBefore = 0, landedSoFar = 0;
    for (var i = 0; i < judged; i++) {
      final d = dates[i];
      receivedSoFar = _ok(receivedSoFar + received[i]);
      landedSoFar += landed[i];
      // i = daysBetween(start, d), and d < end: the period still runs on d.
      final partsArriving = i < samePaydayDays;
      final income = st.incomeMode == 'received' && receivedSoFar > 0
          ? (partsArriving && st.salary > receivedSoFar ? st.salary : receivedSoFar)
          : st.salary;
      final reservedPlanned = [
        for (final p in duePlanned(planned, d, end))
          if (plannedReserves(p, outBills, counted, table: table)) p
      ].fold<int>(0, (s, p) => _ok(s + p.amount!));
      final flexBudget = income - fixedPlan - goalMonthly - reservedBills - reservedPlanned + (landedSoFar < 0 ? 0 : landedSoFar);
      final spentToday = -flex[i];
      final leftForToday = flexBudget + flexBefore; // flexBudget − (spent − spentToday)
      final allowance = leftForToday <= 0 ? 0 : (leftForToday / daysBetween(d, end)).round();
      out.add(PeriodDay(date: d, mark: spentToday > allowance ? DayMark.over : DayMark.within, spent: spentToday, allowance: allowance));
      flexBefore = _ok(flexBefore + flex[i]);
    }
  }
  for (var i = judged; i < dates.length; i++) {
    out.add(PeriodDay(date: dates[i], mark: dates[i] == today ? DayMark.today : DayMark.toCome));
  }
  return out;
}
