import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.recurring');

/// Days a bill's payment may be from its expected date, and from the monthly interval between two payments.
const recurringDays = 3;

/// The amount band around the expected (median) amount, in percent.
const recurringPercent = 10;

/// Calendar months looked back for candidates (the current one included).
const recurringMonths = 7;

/// Whether [cents] (positive) is within [recurringPercent] of [expected] (positive): `|a − e| × 100 ≤ e × 10`.
bool withinBand(int cents, int expected) => (cents - expected).abs() * 100 <= expected * recurringPercent;

/// The median of positive cents: the middle value, or for an even count the mean of the two middle ones (rounded down).
int medianCents(List<int> xs) {
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) ~/ 2;
}

/// Bills that come back every month, found in bank rows: candidates for the owner to confirm or dismiss.
///
/// A candidate is a payee (`merchantKey`) whose live bank outflows (not transfers, not hand-added rows) in the last
/// [recurringMonths] calendar months up to [today] number at least 3, follow one another 30 ± [recurringDays] days
/// apart (every gap, oldest to newest), and all lie within [recurringPercent] of their median: one extra purchase at
/// the same merchant breaks the chain, so shops never qualify. `nextDue` = the last payment + 30 days,
/// `expectedAmount` = the median, `category` and `label` from the latest row. Ordered by label, then id. A pure
/// function: every device derives the same candidates (and ids, `RecurringBill.idFor`) from the same rows. Nothing
/// here changes a row's category: a bill is information, not a reclassification.
List<RecurringBill> detectRecurring(List<CategorizedTx> txs, {required String today}) {
  final from = '${monthsEnding(monthOf(today), recurringMonths).first}-01';
  final byPayee = <String, List<CategorizedTx>>{};
  for (final t in txs) {
    if (!t.tx.live || t.tx.manual || t.amount >= 0 || t.kind == Kind.transfer) continue;
    if (t.date.compareTo(from) < 0 || t.date.compareTo(today) > 0) continue;
    (byPayee[merchantKey(t.tx)] ??= []).add(t);
  }
  final out = <RecurringBill>[];
  for (final e in byPayee.entries) {
    final rows = e.value;
    if (rows.length < 3) continue;
    rows.sort((a, b) {
      final d = a.date.compareTo(b.date);
      return d != 0 ? d : a.tx.id.compareTo(b.tx.id);
    });
    var monthly = true;
    for (var i = 1; i < rows.length && monthly; i++) {
      final gap = daysBetween(rows[i - 1].date, rows[i].date);
      monthly = (gap - RecurringBill.defaultIntervalDays).abs() <= recurringDays;
    }
    if (!monthly) continue;
    final amounts = [for (final r in rows) -r.amount];
    final median = medianCents(amounts);
    if (median <= 0 || amounts.any((a) => !withinBand(a, median))) continue;
    final last = rows.last;
    out.add(RecurringBill(
      id: RecurringBill.idFor(e.key),
      payee: e.key,
      label: merchantName(last.tx),
      category: last.category,
      expectedAmount: median,
      intervalDays: RecurringBill.defaultIntervalDays,
      nextDue: addDays(last.date, RecurringBill.defaultIntervalDays),
    ));
  }
  out.sort((a, b) {
    final d = a.label.compareTo(b.label);
    return d != 0 ? d : a.id.compareTo(b.id);
  });
  // Counts only: payees are personal.
  logEvent(_log, Level.FINE, 'recurring.detect', {'payees': byPayee.length, 'candidates': out.length});
  return out;
}

/// What [planRecurringPayments] found: per bill id, the bank row that paid its current cycle.
class RecurringPayments {
  final Map<String, Tx> paidBy;
  const RecurringPayments(this.paidBy);
  bool get isEmpty => paidBy.isEmpty;
}

/// Finds the bank row that pays each confirmed bill's current cycle: a live bank row (not hand-added) with the bill's
/// payee key, dated within ± [recurringDays] of its `nextDue`, whose outflow is within [recurringPercent] of
/// `expectedAmount`; the closest to `nextDue` wins (then the earliest date, then the smallest id). The row that paid
/// the previous cycle never pays again. Deterministic, so every device marks the same cycle paid with the same row;
/// the row itself is left as it is (its category is never changed by a bill).
RecurringPayments planRecurringPayments(List<RecurringBill> bills, List<Tx> rows) {
  final byPayee = <String, List<Tx>>{};
  for (final t in rows) {
    if (!t.live || t.manual || t.amount >= 0 || t.date.length != 10) continue;
    (byPayee[merchantKey(t)] ??= []).add(t);
  }
  final paid = <String, Tx>{};
  for (final b in bills) {
    if (!b.confirmed || b.nextDue.length != 10 || b.expectedAmount <= 0) continue;
    Tx? best;
    var bestDays = 0;
    for (final t in byPayee[b.payee] ?? const <Tx>[]) {
      if (t.id == b.lastPaidTx || !withinBand(-t.amount, b.expectedAmount)) continue;
      final days = daysBetween(b.nextDue, t.date).abs();
      if (days > recurringDays) continue;
      if (best == null ||
          days < bestDays ||
          (days == bestDays && (t.date.compareTo(best.date) < 0 || (t.date == best.date && t.id.compareTo(best.id) < 0)))) {
        best = t;
        bestDays = days;
      }
    }
    if (best != null) paid[b.id] = best;
  }
  return RecurringPayments(paid);
}
