// Recurring bill history (stage N4, docs/context/N4_SPEC.md): one line per month with the bank rows that paid a
// confirmed recurring bill and the stored slips (bills database) of the same payee. Pure and web-safe.
import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'bills.dart';
import 'categories.dart' show BudgetKind, categories, merchantKey;
import 'dates.dart' show monthOf;
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.recurring');

/// What a [BillMonth] shows: [paid] = a payment landed; [slipOnly] = a slip, no payment; [missing] = neither, in a
/// month before the current one; [upcoming] = neither, in the current month (or a later one) with no payment yet.
enum BillMonthState { paid, slipOnly, missing, upcoming }

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

  const BillMonth({
    required this.month,
    required this.payments,
    required this.slips,
    required this.paid,
    required this.billed,
    required this.state,
  });
}

/// The months of [bill]'s history, newest first.
///
/// Payments: live bank outflows in [currency] (not hand-added, not an own transfer: `transferTo` set, an
/// `ownTransfer`/`exchange` hint or a transfer category set by the owner) whose `merchantKey` equals `bill.payee`, plus
/// the row `bill.lastPaidTx` under the same conditions; never picked by amount. Slips: live stored bills in [currency]
/// with `billPayeeKey(slip) == bill.payee`; a slip linked (`Bill.linkedTx`) to a listed payment is in that payment's
/// month, any other in the month of its `date` (else `dueDate`; neither = not listed).
///
/// Months: the [months] calendar months ending with the later of today's month and the newest month holding a payment
/// or slip; inside that window, every month from the oldest one holding something (or today's month, if earlier;
/// the window's first month when that is older) up to its end, so empty months show as gaps. Empty months before today's month are [BillMonthState.missing] (the bill
/// stores no confirmation date: the app opens History only for confirmed bills), the others
/// [BillMonthState.upcoming]. [today] is `YYYY-MM-DD`; [months] ≥ 1, else an [ArgumentError].
List<BillMonth> billHistory(
  RecurringBill bill,
  List<Tx> rows,
  List<Bill> slips, {
  required String today,
  int months = 12,
  required String currency,
}) {
  if (months < 1) throw ArgumentError.value(months, 'months', 'must be at least 1');
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(today)) throw ArgumentError.value(today, 'today', 'must be YYYY-MM-DD');

  final payments = <String, Tx>{};
  for (final t in rows) {
    if (!_isPayment(t, currency)) continue;
    if (t.id == bill.lastPaidTx || merchantKey(t) == bill.payee) payments[t.id] = t;
  }

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
  final held = {...payByMonth.keys, ...slipByMonth.keys}.map(_index);
  final end = held.fold(current, (a, b) => b > a ? b : a);
  final oldest = held.fold(current, (a, b) => b < a ? b : a);
  final windowStart = end - months + 1;
  final start = oldest < windowStart ? windowStart : oldest;

  final out = <BillMonth>[];
  for (var m = end; m >= start; m--) {
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
              : m < current
                  ? BillMonthState.missing
                  : BillMonthState.upcoming,
    ));
  }
  // Counts only: payees and amounts are personal.
  logEvent(_log, Level.FINE, 'recurring.history', {'months': out.length, 'payments': payments.length, 'slips': seenSlips.length});
  return out;
}

/// A row that may pay a recurring bill: the rows `planRecurringPayments` accepts, minus own transfers.
bool _isPayment(Tx t, String currency) =>
    t.live &&
    !t.manual &&
    t.amount < 0 &&
    t.date.length == 10 &&
    t.currency == currency &&
    t.transferTo == null &&
    t.kindHint != TxKind.ownTransfer &&
    t.kindHint != TxKind.exchange &&
    categories[t.category] != BudgetKind.transfer;

String? _slipDate(Bill s) => [s.date, s.dueDate].firstWhere((d) => d != null && d.length == 10, orElse: () => null);

/// The date a slip sorts by inside its month: its own date, or its payment's when it has none.
String _slipSortDate(Bill s, Map<String, Tx> payments) => _slipDate(s) ?? payments[s.linkedTx]?.date ?? '';

int _index(String ym) => int.parse(ym.substring(0, 4)) * 12 + int.parse(ym.substring(5, 7)) - 1;

String _month(int i) => '${(i ~/ 12).toString().padLeft(4, '0')}-${(i % 12 + 1).toString().padLeft(2, '0')}';
