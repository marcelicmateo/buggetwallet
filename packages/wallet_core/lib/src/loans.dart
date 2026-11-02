// ENG E6 (docs/context/ENG_UI_SPEC.md §5.5, §6.5): loans. Synced entities `loan`, `loanrate`, `loancheck` and the pure
// maths of a loan: its schedule, its state against the matched payments, what-ifs and the payment matcher. Exact
// integer/BigInt maths, each value rounded once, half away from zero. Web-safe.
import 'categories.dart' show merchantKey;
import 'cols.dart';
import 'dates.dart';
import 'goal_plan.dart' show addMonths, annuityPayment;
import 'models.dart';
import 'search.dart' show foldText;

/// The columns of the synced entity `loan` (table `loans`): one row per loan, as the lender wrote it. Unknown values are
/// null (the loan migrated from the old single plan loan knows only its [payment]).
abstract final class LoanCols {
  static const entity = 'loan';
  static const name = TextCol(entity, 'name', label: 'Name', maxLength: 60);
  static const principal = MoneyCol(entity, 'principal', label: 'Borrowed', nullable: true, positive: true);
  static const rateBp = IntCol(entity, 'rate_bp', label: 'Rate', nullable: true, min: 0, max: 10000);
  static const months = IntCol(entity, 'months', label: 'Length', nullable: true, min: 1, max: 600);
  static const firstDue = DateCol(entity, 'first_due', label: 'First payment', nullable: true);
  static const payment = MoneyCol(entity, 'payment', label: 'Monthly payment', nullable: true, positive: true);
  static const accountId = RefCol(entity, 'account_id', label: 'Account', target: 'account', nullable: true);
  static const payeeKey = TextCol(entity, 'payee_key', label: 'Lender', nullable: true, maxLength: 200);
  static const reference =
      TextCol(entity, 'reference', label: 'Reference', nullable: true, minLength: loanReferenceMinLength, maxLength: 60);
  static const goalId = RefCol(entity, 'goal_id', label: 'Goal', target: 'goal', nullable: true);
  static const tagId = RefCol(entity, 'tag_id', label: 'Project tag', target: 'tag', nullable: true);
  static const closedAt = DateCol(entity, 'closed_at', label: 'Closed on', nullable: true, notAfterToday: true);
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[
    name,
    principal,
    rateBp,
    months,
    firstDue,
    payment,
    accountId,
    payeeKey,
    reference,
    goalId,
    tagId,
    closedAt,
    deleted,
  ];
}

/// A rate change (`loanrate`, table `loan_rates`): from [LoanRateCols.from] on the loan runs at `rate_bp` with
/// `payment` (null = recomputed as an annuity over the months left).
abstract final class LoanRateCols {
  static const entity = 'loanrate';
  static const loanId = RefCol(entity, 'loan_id', label: 'Loan', target: 'loan');
  static const from = DateCol(entity, 'from_date', label: 'From');
  static const rateBp = IntCol(entity, 'rate_bp', label: 'Rate', min: 0, max: 10000);
  static const payment = MoneyCol(entity, 'payment', label: 'Monthly payment', nullable: true, positive: true);
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[loanId, from, rateBp, payment, deleted];
}

/// A balance the lender showed on [LoanCheckCols.date], confirmed by the owner (`loancheck`, table `loan_checks`): the
/// schedule goes on from it.
abstract final class LoanCheckCols {
  static const entity = 'loancheck';
  static const loanId = RefCol(entity, 'loan_id', label: 'Loan', target: 'loan');
  static const date = DateCol(entity, 'date', label: 'Date', notAfterToday: true);
  static const balance = MoneyCol(entity, 'balance', label: 'Balance');
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[loanId, date, balance, deleted];
}

/// The owner's answer about one bank row of a loan (`loanpay`, table `loan_pays`, id `<loanId>|<txId>`, like `txtag`):
/// `state` `on` = a loan payment ("Loan payment?" yes, or Undo of an Unlink), `off` = unlinked, never matched again.
/// One row per pair, so two devices answering about different rows never overwrite each other.
abstract final class LoanPayCols {
  static const entity = 'loanpay';
  static const loanId = RefCol(entity, 'loan_id', label: 'Loan', target: 'loan');
  static const tx = RefCol(entity, 'tx', label: 'Payment', target: 'tx');
  static const state = TextCol(entity, 'state', label: 'State');

  static const all = <Col>[loanId, tx, state];
}

class Loan {
  final String id, name;
  final int? principal, rateBp, months, payment;
  final String? firstDue, accountId, payeeKey, reference, goalId, tagId, closedAt;
  const Loan(
      {required this.id,
      this.name = '',
      this.principal,
      this.rateBp,
      this.months,
      this.firstDue,
      this.payment,
      this.accountId,
      this.payeeKey,
      this.reference,
      this.goalId,
      this.tagId,
      this.closedAt});

  /// The loan the old single plan loan (`WalletSettings.loan`) became at the schema-21 migration.
  static const legacyId = 'loan:settings';

  bool get open => closedAt == null;

  static Loan fromRow(Map<String, Object?> r) => Loan(
        id: r['id'] as String,
        name: LoanCols.name.read(r) ?? '',
        principal: LoanCols.principal.read(r),
        rateBp: LoanCols.rateBp.read(r),
        months: LoanCols.months.read(r),
        firstDue: LoanCols.firstDue.read(r),
        payment: LoanCols.payment.read(r),
        accountId: LoanCols.accountId.read(r),
        payeeKey: LoanCols.payeeKey.read(r),
        reference: LoanCols.reference.read(r),
        goalId: LoanCols.goalId.read(r),
        tagId: LoanCols.tagId.read(r),
        closedAt: LoanCols.closedAt.read(r),
      );
}

class LoanRate {
  final String id, loanId, from;
  final int rateBp;
  final int? payment;
  const LoanRate({this.id = '', required this.loanId, required this.from, required this.rateBp, this.payment});
  static LoanRate fromRow(Map<String, Object?> r) => LoanRate(
      id: r['id'] as String,
      loanId: LoanRateCols.loanId.read(r) ?? '',
      from: LoanRateCols.from.read(r) ?? '',
      rateBp: LoanRateCols.rateBp.read(r) ?? 0,
      payment: LoanRateCols.payment.read(r));
}

class LoanCheck {
  final String id, loanId, date;
  final int balance;
  const LoanCheck({this.id = '', required this.loanId, required this.date, required this.balance});
  static LoanCheck fromRow(Map<String, Object?> r) => LoanCheck(
      id: r['id'] as String,
      loanId: LoanCheckCols.loanId.read(r) ?? '',
      date: LoanCheckCols.date.read(r) ?? '',
      balance: LoanCheckCols.balance.read(r) ?? 0);
}

/// One month of a loan's schedule: due on [due] at [rateBp]; [paid] = [interest] + [principal]; [balance] after it
/// (after a lender's balance check dated before the next due date, the check's balance).
class LoanMonth {
  final int index;
  final String due;
  final int rateBp, paid, interest, principal, balance;
  const LoanMonth(this.index, this.due, this.rateBp, this.paid, this.interest, this.principal, this.balance);
}

/// [first] (`YYYY-MM-DD`) moved [k] months on, the day clamped to the month's last day.
String _dueDate(String first, int k) {
  final ym = addMonths(monthOf(first), k);
  final d = dayOf(first), last = daysInMonth(ym);
  return '$ym-${(d > last ? last : d).toString().padLeft(2, '0')}';
}

/// round([bal] × [bp] / 120 000), half away from zero (bal ≤ 10^11 cents, bp ≤ 10^4: the product fits 2^53).
int _interest(int bal, int bp) {
  final n = bal * bp;
  return n >= 0 ? (2 * n + 120000) ~/ 240000 : -((-2 * n + 120000) ~/ 240000);
}

/// The schedule of [l] (empty while its principal, length or first due date is unknown). Each month: interest =
/// round(balance × r), r = bp / 120 000; it pays the payment in force (the latest [rates] row from on or before its
/// due date, else [Loan.payment], else the annuity of the principal), and the last month ([Loan.months]) — or the
/// first one whose balance + interest fits the payment — pays the exact rest, so the balance ends at exactly 0. A
/// [checks] row dated before the first due date starts from its balance; one dated on or after a due date and before
/// the next replaces the balance after that month. A rate row without a payment recomputes the annuity over the months
/// left.
List<LoanMonth> loanSchedule(Loan l, List<LoanRate> rates, List<LoanCheck> checks) => _schedule(l, rates, checks);

List<LoanMonth> _schedule(Loan l, List<LoanRate> rates, List<LoanCheck> checks,
    {int extraMonthly = 0, int extraOnce = 0, String? extraOnceDate}) {
  final p0 = l.principal, n = l.months, first = l.firstDue;
  if (p0 == null || n == null || first == null) return const [];
  int byDate(String a, String b, String ia, String ib) => a != b ? a.compareTo(b) : ia.compareTo(ib);
  final rs = [...rates]..sort((a, b) => byDate(a.from, b.from, a.id, b.id));
  final cs = [...checks]..sort((a, b) => byDate(a.date, b.date, a.id, b.id));
  LoanCheck? lastCheck(String from, String? to) =>
      cs.where((c) => c.date.compareTo(from) >= 0 && (to == null || c.date.compareTo(to) < 0)).lastOrNull;
  var bal = p0;
  if (lastCheck('', first) case final c?) bal = c.balance;
  final basePayment = l.payment ?? annuityPayment(p0, l.rateBp ?? 0, n);
  LoanRate? applied;
  var payment = basePayment, onceLeft = extraOnce;
  final out = <LoanMonth>[];
  for (var k = 0; k < n && bal > 0; k++) {
    final due = _dueDate(first, k);
    final r = rs.where((r) => r.from.compareTo(due) <= 0).lastOrNull;
    if (r != null && !identical(r, applied)) {
      applied = r;
      payment = r.payment ?? annuityPayment(bal, r.rateBp, n - k);
    }
    final bp = r?.rateBp ?? l.rateBp ?? 0;
    final interest = _interest(bal, bp);
    final total = bal + interest;
    var pay = payment + extraMonthly;
    if (onceLeft > 0 && extraOnceDate != null && due.compareTo(extraOnceDate) >= 0) {
      pay += onceLeft;
      onceLeft = 0;
    }
    if (k == n - 1 || total <= pay) pay = total;
    bal = total - pay;
    if (lastCheck(due, k + 1 < n ? _dueDate(first, k + 1) : null) case final c?) bal = c.balance;
    out.add(LoanMonth(k, due, bp, pay, interest, pay - interest, bal));
  }
  return out;
}

/// Where a loan stands: [paidMonths] months matched, [notSeen] the due dates (`YYYY-MM-DD`) of earlier months without a
/// matched payment more than 3 days after their due date, [owedNow] = the schedule balance after the last matched month
/// (the starting balance before any), [monthsLeft] after it, [payoffMonth] `YYYY-MM` of the last scheduled month,
/// [interestPaid] / [interestToPay] = Σ interest up to / after the last matched month (estimate).
class LoanState {
  final int paidMonths, owedNow, monthsLeft, interestPaid, interestToPay;
  final List<String> notSeen;
  final String? payoffMonth;
  const LoanState(
      {required this.paidMonths,
      required this.notSeen,
      required this.owedNow,
      required this.monthsLeft,
      required this.payoffMonth,
      required this.interestPaid,
      required this.interestToPay});
}

/// The index of the month of [s] whose window holds [date]: from 15 days before its due date to 15 days before the
/// next one (the last month's window has no end); -1 before the first window.
int _monthAt(List<LoanMonth> s, String date) {
  for (var i = s.length - 1; i >= 0; i--) {
    if (date.compareTo(addDays(s[i].due, -15)) >= 0) return i;
  }
  return -1;
}

/// [schedule] (`loanSchedule`) against the dates of the matched payments ([matchedPayments], `YYYY-MM-DD`, e.g. from
/// `loanPayments`). A payment pays the month whose window holds it: from 15 days before its due date to 15 days before
/// the next one (so an early or late payment still counts, and two payments in one window count once).
LoanState loanState(List<LoanMonth> schedule, List<String> matchedPayments, String today) {
  if (schedule.isEmpty) {
    return const LoanState(paidMonths: 0, notSeen: [], owedNow: 0, monthsLeft: 0, payoffMonth: null, interestPaid: 0, interestToPay: 0);
  }
  final paid = List.filled(schedule.length, false);
  for (final d in matchedPayments) {
    if (_monthAt(schedule, d) case final i when i >= 0) paid[i] = true;
  }
  final last = paid.lastIndexOf(true);
  final first = schedule.first;
  var before = 0, after = 0;
  for (final m in schedule) {
    if (m.index <= last) {
      before += m.interest;
    } else {
      after += m.interest;
    }
  }
  return LoanState(
    paidMonths: paid.where((p) => p).length,
    notSeen: [
      for (final m in schedule)
        if (!paid[m.index] && today.compareTo(addDays(m.due, 3)) > 0) m.due
    ],
    owedNow: last >= 0 ? schedule[last].balance : first.balance + first.principal,
    monthsLeft: schedule.length - (last + 1),
    payoffMonth: monthOf(schedule.last.due),
    interestPaid: before,
    interestToPay: after,
  );
}

/// What a change would do ([loanWhatIf]): [monthsSaved] and [interestSaved] against the loan as it is (negative when it
/// costs more), and [newPayment] when a new rate was given (the annuity over the months left from its date).
class LoanWhatIf {
  final int monthsSaved, interestSaved;
  final int? newPayment;
  const LoanWhatIf(this.monthsSaved, this.interestSaved, this.newPayment);
}

/// Read-only: [l]'s schedule with an extra one-off payment [extraOnce] on the first due date on or after
/// [extraOnceDate], [extraMonthly] more every month, and/or a new rate [newRateBp] from [newRateFrom] (payment
/// recomputed over the months left), compared with the schedule as it is.
LoanWhatIf loanWhatIf(Loan l,
    {List<LoanRate> rates = const [],
    List<LoanCheck> checks = const [],
    int extraOnce = 0,
    String? extraOnceDate,
    int extraMonthly = 0,
    int? newRateBp,
    String? newRateFrom}) {
  final base = _schedule(l, rates, checks);
  var rs = rates;
  int? newPayment;
  if (newRateBp != null && newRateFrom != null) {
    final from = base.where((m) => m.due.compareTo(newRateFrom) >= 0).firstOrNull;
    if (from != null) {
      final before = from.index == 0 ? base.first.balance + base.first.principal : base[from.index - 1].balance;
      newPayment = annuityPayment(before, newRateBp, (l.months ?? 0) - from.index);
      rs = [...rates, LoanRate(id: '~whatif', loanId: l.id, from: newRateFrom, rateBp: newRateBp, payment: newPayment)];
    }
  }
  final alt = _schedule(l, rs, checks, extraMonthly: extraMonthly, extraOnce: extraOnce, extraOnceDate: extraOnceDate);
  int interest(List<LoanMonth> s) => s.fold(0, (a, m) => a + m.interest);
  return LoanWhatIf(base.length - alt.length, interest(base) - interest(alt), newPayment);
}

/// The payment in force for [l] on [date]: the scheduled payment of the month whose window holds it ([loanSchedule]
/// with [rates] and [checks]; before the first window the first month's, after the last the last month's). Without a
/// schedule (principal, length or first due date unknown): the latest [rates] row from on or before [date] with a
/// payment, else [Loan.payment] (null when neither is known).
int? loanPaymentOn(Loan l, List<LoanRate> rates, List<LoanCheck> checks, String date) =>
    _paymentOn(l, rates, loanSchedule(l, rates, checks), date).$1;

/// [loanPaymentOn] on a schedule already made, and whether it is the last month's (the exact rest).
(int?, bool) _paymentOn(Loan l, List<LoanRate> rates, List<LoanMonth> s, String date) {
  if (s.isNotEmpty) {
    final i = _monthAt(s, date);
    return (s[i < 0 ? 0 : i].paid, i == s.length - 1);
  }
  LoanRate? best;
  for (final r in rates) {
    if (r.payment != null && r.from.compareTo(date) <= 0 && (best == null || r.from.compareTo(best.from) >= 0)) best = r;
  }
  return (best?.payment ?? l.payment, false);
}

/// A bank row that pays [Loan] (`loanPayments`); [amountChanged]: its amount is not the scheduled payment in force on
/// its date ([loanPaymentOn]; the exact-rest last payment is never flagged): still matched, flagged for the owner.
/// [byKey] / [byRef]: the evidence that found it (its payee key is [Loan.payeeKey] / its text holds [Loan.reference]).
class LoanPaymentMatch {
  final String txId, date;
  final int amount;
  final bool amountChanged, byKey, byRef;
  const LoanPaymentMatch(this.txId, this.date, this.amount, this.amountChanged, {this.byKey = false, this.byRef = false});
}

/// One loan's candidate rows split by the owner's answers ([loanMatches]): [matched] pay the loan (main tag "Loan"),
/// [pending] ask "Loan payment?". Both oldest first.
class LoanMatches {
  final List<LoanPaymentMatch> matched, pending;
  const LoanMatches(this.matched, this.pending);
}

/// [candidates] of one loan (`loanPayments`) against the owner's [answers] (tx id → true = `on`, false = `off`,
/// [LoanPayCols]). A row answered on is matched; off is never matched again. An unanswered row is matched silently
/// when a row answered on was found by the same evidence (payee key or reference, never the amount), else it is asked.
/// Unanswered rows in [taken] (answered on for another loan) are left out.
LoanMatches loanMatches(List<LoanPaymentMatch> candidates, Map<String, bool> answers, {Set<String> taken = const {}}) {
  var key = false, ref = false;
  for (final c in candidates) {
    if (answers[c.txId] != true) continue;
    key |= c.byKey;
    ref |= c.byRef;
  }
  final matched = <LoanPaymentMatch>[], pending = <LoanPaymentMatch>[];
  for (final c in candidates) {
    final a = answers[c.txId];
    if (a == false || (a == null && taken.contains(c.txId))) continue;
    (a == true || (key && c.byKey) || (ref && c.byRef) ? matched : pending).add(c);
  }
  return LoanMatches(matched, pending);
}

/// The minimum length of [Loan.reference] (shorter text would match unrelated rows).
const loanReferenceMinLength = 4;

/// The rows that pay [l], oldest first: live bank outflows (not hand-added, no own transfer) in [currency], from 15
/// days before the first due date (when known) up to the closing date, whose payee key is [Loan.payeeKey] or whose
/// description holds [Loan.reference] (at least [loanReferenceMinLength] characters; case and accents ignored). Never
/// by amount: a row of another payee with the loan's amount is not a payment.
List<LoanPaymentMatch> loanPayments(Loan l, List<LoanRate> rates, List<LoanCheck> checks, Iterable<Tx> rows, {required String currency}) {
  final key = l.payeeKey ?? '';
  final rawRef = foldText(l.reference?.trim() ?? '');
  final ref = rawRef.runes.length >= loanReferenceMinLength ? rawRef : '';
  if (key.isEmpty && ref.isEmpty) return const [];
  final from = l.firstDue == null ? null : addDays(l.firstDue!, -15);
  final schedule = loanSchedule(l, rates, checks);
  final out = <LoanPaymentMatch>[];
  for (final t in rows) {
    if (!t.live || t.manual || t.amount >= 0 || t.currency != currency || t.transferTo != null) continue;
    if ((from != null && t.date.compareTo(from) < 0) || (l.closedAt != null && t.date.compareTo(l.closedAt!) > 0)) continue;
    final byKey = key.isNotEmpty && merchantKey(t) == key, byRef = ref.isNotEmpty && foldText(t.description).contains(ref);
    if (!byKey && !byRef) continue;
    final (expected, last) = _paymentOn(l, rates, schedule, t.date);
    out.add(LoanPaymentMatch(t.id, t.date, -t.amount, !last && expected != null && -t.amount != expected, byKey: byKey, byRef: byRef));
  }
  return out..sort((a, b) => a.date != b.date ? a.date.compareTo(b.date) : a.txId.compareTo(b.txId));
}
