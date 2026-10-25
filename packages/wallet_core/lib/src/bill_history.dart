// Recurring bill history (stage N4, docs/context/N4_SPEC.md): one line per month with the bank rows that paid a
// confirmed recurring bill and the stored slips (bills database) of the same payee. Pure and web-safe.
import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'bills.dart';
import 'categories.dart' show BudgetKind, CategoryTable, merchantKey;
import 'dates.dart' show addDays, daysBetween, isIsoDate, monthOf;
import 'logs.dart';
import 'models.dart';
import 'recurring.dart' show partsThreshold, recurringDays;

/// Months after today's month that [billHistory] still shows (only when they hold a slip or payment).
const historyMonthsAhead = 2;

final _log = Logger('bw.recurring');

/// What a [BillMonth] shows: [paid] = a payment landed; [slipOnly] = a slip, no payment; [missing] = neither, in a
/// month before the current one; [paidNearby] = neither, but a neighbouring month holds an extra payment dated within
/// [recurringDays] of this month ([BillMonth.paidIn]; dates only, never amounts); [upcoming] = neither, in the current
/// month with no payment yet.
enum BillMonthState { paid, slipOnly, missing, paidNearby, upcoming }

/// One calendar month of a recurring bill's history ([billHistory]).
class BillMonth {
  /// `YYYY-MM`.
  final String month;

  /// The bank rows that paid the bill this month, by date then id.
  final List<Tx> payments;

  /// The stored slips of the payee for this month, by their date then id.
  final List<Bill> slips;

  /// Σ −amount over [payments], exact cents (0 without a payment).
  final int paid;

  /// Σ of the slips' totals, or null when no slip of this month has a total.
  final int? billed;

  final BillMonthState state;

  /// For [BillMonthState.paidNearby]: the neighbouring month (`YYYY-MM`) whose extra payment covers this one; else null.
  final String? paidIn;

  /// For a bill that is not monthly (P4: one line per cycle): the cycle's due date; [month] is its `YYYY-MM`. Null on
  /// monthly lines.
  final String? due;

  const BillMonth({
    required this.month,
    required this.payments,
    required this.slips,
    required this.paid,
    required this.billed,
    required this.state,
    this.paidIn,
    this.due,
  });

  /// Σ −amount over [payments] (= [paid]): for a cycle paid in parts, the parts so far.
  int get paidCents => paid;

  /// The ids of [payments] (a cycle's parts), in their order.
  List<String> get txIds => [for (final t in payments) t.id];
}

/// The months of [bill]'s history, newest first.
///
/// Payments: live bank outflows in [currency] (not hand-added, not an own transfer: `transferTo` set, an
/// `ownTransfer`/`exchange` hint or a transfer category set by the owner) whose `merchantKey` equals `bill.payee`, plus
/// the row `bill.lastPaidTx` under the same conditions; never picked by amount. Slips: live stored bills in [currency]
/// with `billPayeeKey(slip) == bill.payee`; a slip linked (`Bill.linkedTx`) to a listed payment is in that payment's
/// month, any other in the month of its `date` (else `dueDate`; neither = not listed).
///
/// Months: the [months] calendar months ending with today's month, from the oldest one holding a payment or slip (the
/// window's first month when that is older) up to today's month, so empty months show as gaps; above them the next
/// [historyMonthsAhead] months, each only when it holds something (anything dated later is left out). Empty months
/// before today's month are [BillMonthState.missing] (the bill stores no confirmation date: the app opens History only
/// for confirmed bills) or [BillMonthState.paidNearby]; an empty today's month is [BillMonthState.upcoming]. Dates
/// that are not real `YYYY-MM-DD` values are skipped. [today] is `YYYY-MM-DD`; [months] ≥ 1, else an [ArgumentError].
/// [table] tells which stored categories are own transfers (built-ins when null).
List<BillMonth> billHistory(
  RecurringBill bill,
  List<Tx> rows,
  List<Bill> slips, {
  required String today,
  int months = 12,
  required String currency,
  CategoryTable? table,
}) {
  final cats = table ?? CategoryTable.builtIn;
  if (months < 1) throw ArgumentError.value(months, 'months', 'must be at least 1');
  if (!isIsoDate(today)) throw ArgumentError.value(today, 'today', 'must be YYYY-MM-DD');

  final payments = <String, Tx>{};
  for (final t in rows) {
    if (!_isPayment(t, currency, cats)) continue;
    if (t.id == bill.lastPaidTx || merchantKey(t) == bill.payee) payments[t.id] = t;
  }

  if ((bill.isShort || bill.isLong) && isIsoDate(bill.nextDue)) return _cycleHistory(bill, payments, slips, months, currency);

  final payByMonth = <String, List<Tx>>{};
  for (final t in payments.values) {
    (payByMonth[monthOf(t.date)] ??= []).add(t);
  }
  final slipByMonth = <String, List<Bill>>{};
  final seenSlips = <String>{};
  for (final s in slips) {
    if (s.deleted || s.currency != currency || !seenSlips.add(s.id) || billPayeeKey(s) != bill.payee) continue;
    final linked = payments[s.linkedTx];
    final date = linked?.date ?? _slipDate(s);
    if (date == null) continue;
    (slipByMonth[monthOf(date)] ??= []).add(s);
  }

  final current = _index(monthOf(today));
  final held = {...payByMonth.keys, ...slipByMonth.keys}.map(_index).toSet();
  final oldest = held.fold(current, (a, b) => b < a ? b : a);
  final windowStart = current - months + 1;
  final start = oldest < windowStart ? windowStart : oldest;
  final shown = [
    for (var m = current + historyMonthsAhead; m > current; m--)
      if (held.contains(m)) m,
    for (var m = current; m >= start; m--) m,
  ];
  final nearby = _paidNearby([
    for (final m in shown)
      if (m < current && !held.contains(m)) m
  ], payByMonth);

  final out = <BillMonth>[];
  for (final m in shown) {
    final ym = _month(m);
    final pays = (payByMonth[ym] ?? <Tx>[])
      ..sort((a, b) {
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    final bills = (slipByMonth[ym] ?? <Bill>[])
      ..sort((a, b) {
        final d = _slipSortDate(a, payments).compareTo(_slipSortDate(b, payments));
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    final totals = [
      for (final s in bills)
        if (s.total case final total?) total
    ];
    out.add(BillMonth(
      month: ym,
      payments: List.unmodifiable(pays),
      slips: List.unmodifiable(bills),
      paid: pays.fold(0, (a, t) => a - t.amount),
      billed: totals.isEmpty ? null : totals.fold<int>(0, (a, b) => a + b),
      state: pays.isNotEmpty
          ? BillMonthState.paid
          : bills.isNotEmpty
              ? BillMonthState.slipOnly
              : m >= current
                  ? BillMonthState.upcoming
                  : nearby.containsKey(m)
                      ? BillMonthState.paidNearby
                      : BillMonthState.missing,
      paidIn: nearby[m],
    ));
  }
  // Counts only: payees and amounts are personal.
  logEvent(_log, Level.FINE, 'recurring.history', {'months': out.length, 'payments': payments.length, 'slips': seenSlips.length});
  return out;
}

/// [billHistory] for a bill that is not monthly (P4 §5): one line per cycle, newest first. Cycle k has the due date
/// `nextDue − k × intervalDays`: k = 0 is the open cycle, k = 1 .. [months] − 1 the ones before it (always [months]
/// lines), k = −1 .. −[historyMonthsAhead] only when they hold something. Each payment and slip (by its linked
/// payment's date, else its own date) goes to the cycle whose due date is nearest (dates only, never amounts); anything
/// nearer to a cycle outside that span is left out. States: [BillMonthState.paid] when the cycle's rows reach
/// [partsThreshold], or a past cycle (k ≥ 1) holds one payment (as for months); else [BillMonthState.slipOnly] (no
/// payment, a slip), [BillMonthState.upcoming] (k ≤ 0, parts so far in [BillMonth.paidCents]) or
/// [BillMonthState.missing] (a past cycle with nothing, or with parts that never added up). No `paidNearby` for cycles.
List<BillMonth> _cycleHistory(RecurringBill bill, Map<String, Tx> payments, List<Bill> slips, int months, String currency) {
  final step = bill.intervalDays;
  int? cycleOf(String date) {
    final k = (daysBetween(date, bill.nextDue) / step).round();
    return k < -historyMonthsAhead || k > months - 1 ? null : k;
  }

  final payBy = <int, List<Tx>>{};
  for (final t in payments.values) {
    if (cycleOf(t.date) case final k?) (payBy[k] ??= []).add(t);
  }
  final slipBy = <int, List<Bill>>{};
  final seenSlips = <String>{};
  for (final s in slips) {
    if (s.deleted || s.currency != currency || !seenSlips.add(s.id) || billPayeeKey(s) != bill.payee) continue;
    final date = payments[s.linkedTx]?.date ?? _slipDate(s);
    if (date == null) continue;
    if (cycleOf(date) case final k?) (slipBy[k] ??= []).add(s);
  }
  final held = {...payBy.keys, ...slipBy.keys};
  final shown = [
    for (var k = -historyMonthsAhead; k < 0; k++)
      if (held.contains(k)) k,
    for (var k = 0; k < months; k++) k,
  ];
  final threshold = partsThreshold(bill);
  final out = <BillMonth>[];
  for (final k in shown) {
    final due = addDays(bill.nextDue, -k * step);
    final pays = (payBy[k] ?? <Tx>[])
      ..sort((a, b) {
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    final bills = (slipBy[k] ?? <Bill>[])
      ..sort((a, b) {
        final d = _slipSortDate(a, payments).compareTo(_slipSortDate(b, payments));
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    final totals = [
      for (final s in bills)
        if (s.total case final total?) total
    ];
    final paid = pays.fold(0, (a, t) => a - t.amount);
    out.add(BillMonth(
      month: monthOf(due),
      due: due,
      payments: List.unmodifiable(pays),
      slips: List.unmodifiable(bills),
      paid: paid,
      billed: totals.isEmpty ? null : totals.fold<int>(0, (a, b) => a + b),
      state: pays.isNotEmpty && (paid >= threshold || (k >= 1 && pays.length == 1))
          ? BillMonthState.paid
          : pays.isEmpty && bills.isNotEmpty
              ? BillMonthState.slipOnly
              : k <= 0
                  ? BillMonthState.upcoming
                  : BillMonthState.missing,
    ));
  }
  logEvent(_log, Level.FINE, 'recurring.history',
      {'cycles': out.length, 'intervalDays': step, 'payments': payments.length, 'slips': seenSlips.length});
  return out;
}

/// For the empty past months [empty] (newest first, as shown): which ones a neighbouring month paid, month index →
/// that neighbour's `YYYY-MM`. A neighbour (the month before, else the month after) qualifies when it holds more than
/// one payment and one of them is dated within [recurringDays] of the empty month (before its first day or after its
/// last); each payment beyond the first covers one empty month. By dates only, never by amount. Oldest empty month
/// first, so the result does not depend on the order shown.
Map<int, String> _paidNearby(List<int> empty, Map<String, List<Tx>> payByMonth) {
  final spare = {for (final e in payByMonth.entries) _index(e.key): e.value.length - 1};
  final out = <int, String>{};
  for (final m in empty.reversed) {
    final first = '${_month(m)}-01';
    final last = addDays('${_month(m + 1)}-01', -1);
    for (final (n, near) in [
      (m - 1, (Tx t) => daysBetween(t.date, first) <= recurringDays),
      (m + 1, (Tx t) => daysBetween(last, t.date) <= recurringDays),
    ]) {
      if ((spare[n] ?? 0) < 1 || !(payByMonth[_month(n)] ?? const <Tx>[]).any(near)) continue;
      spare[n] = spare[n]! - 1;
      out[m] = _month(n);
      break;
    }
  }
  return out;
}

/// A row that may pay a recurring bill: the rows `planRecurringPayments` accepts, minus own transfers.
bool _isPayment(Tx t, String currency, CategoryTable cats) =>
    t.live &&
    !t.manual &&
    t.amount < 0 &&
    isIsoDate(t.date) &&
    t.currency == currency &&
    t.transferTo == null &&
    t.kindHint != TxKind.ownTransfer &&
    t.kindHint != TxKind.exchange &&
    (t.category == null || !cats.isLive(t.category!) || cats.kindOf(t.category!) != BudgetKind.transfer);

/// A slip's own date: its issue date, else its due date; a value that is not a real `YYYY-MM-DD` counts as absent.
String? _slipDate(Bill s) => [s.date, s.dueDate].firstWhere((d) => d != null && isIsoDate(d), orElse: () => null);

/// The date a slip sorts by inside its month: its own date, or its payment's when it has none.
String _slipSortDate(Bill s, Map<String, Tx> payments) => _slipDate(s) ?? payments[s.linkedTx]?.date ?? '';

int _index(String ym) => int.parse(ym.substring(0, 4)) * 12 + int.parse(ym.substring(5, 7)) - 1;

String _month(int i) => '${(i ~/ 12).toString().padLeft(4, '0')}-${(i % 12 + 1).toString().padLeft(2, '0')}';
