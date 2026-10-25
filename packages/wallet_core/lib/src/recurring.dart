import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.recurring');

/// Days a bill's payment may be from its expected date, and from the monthly interval between two payments.
const recurringDays = 3;

/// The amount band around the expected (median) amount, in percent.
const recurringPercent = 10;

/// Calendar months looked back for monthly candidates (the current one included).
const _recurringMonths = 7;

/// Per period class (tried in this order, the first that fits wins): how far back rows count (whole weeks back from
/// today, or calendar months ending with today's month) and the fewest rows that make a candidate.
const _classes = [
  (period: RecurringPeriod.weekly, weeks: 8, months: 0, rows: 4),
  (period: RecurringPeriod.biweekly, weeks: 16, months: 0, rows: 3),
  (period: RecurringPeriod.monthly, weeks: 0, months: _recurringMonths, rows: 3),
  (period: RecurringPeriod.quarterly, weeks: 0, months: 13, rows: 3),
  (period: RecurringPeriod.yearly, weeks: 0, months: 25, rows: 2),
];

String _lookbackStart(String today, int weeks, int months) =>
    weeks > 0 ? addDays(today, -7 * weeks) : '${monthsEnding(monthOf(today), months).first}-01';

/// Whether [cents] (positive) is within [recurringPercent] of [expected] (positive): `|a − e| × 100 ≤ e × 10`.
bool _withinBand(int cents, int expected) => (cents - expected).abs() * 100 <= expected * recurringPercent;

/// The median of positive cents: the middle value, or for an even count the mean of the two middle ones (rounded down).
int medianCents(List<int> xs) {
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) ~/ 2;
}

/// Bills that come back on a fixed period, found in bank rows: candidates for the owner to confirm or dismiss.
///
/// A candidate is a payee (`merchantKey`) whose live bank outflows (not transfers, not hand-added rows) in one period
/// class's lookback up to [today] ([_classes]: weekly 8 weeks / 4 rows, every 2 weeks 16 weeks / 3 rows, monthly
/// [_recurringMonths] calendar months / 3 rows, quarterly 13 months / 3 rows, yearly 25 months / 2 rows; tried in that
/// order, the first that fits wins) number at least that class's rows, follow one another the class's days ±
/// [RecurringBill.toleranceFor] apart (every gap, oldest to newest; monthly: 30 ± [recurringDays], as before P4), and
/// all lie within [recurringPercent] of their median: one extra purchase at the same merchant breaks the chain, so
/// shops never qualify. `intervalDays` = the class's days, `nextDue` = the last payment + those days,
/// `expectedAmount` = the median, `category` and `label` from the latest row. Ordered by label, then id. A pure
/// function: every device derives the same candidates (and ids, `RecurringBill.idFor`) from the same rows. Nothing
/// here changes a row's category: a bill is information, not a reclassification. Only rows in [currency]
/// (`WalletSettings.currency`) count: a bill paid in another currency is never a candidate, so it is never reserved
/// from the flexible money, and a foreign row at the same payee neither breaks nor joins the chain.
List<RecurringBill> detectRecurring(List<CategorizedTx> txs, {required String today, required String currency}) {
  final starts = [for (final c in _classes) _lookbackStart(today, c.weeks, c.months)];
  final from = starts.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
  final byPayee = <String, List<CategorizedTx>>{};
  for (final t in txs) {
    if (!t.tx.live || t.tx.manual || t.amount >= 0 || t.kind == BudgetKind.transfer || t.tx.currency != currency) continue;
    if (t.date.compareTo(from) < 0 || t.date.compareTo(today) > 0) continue;
    (byPayee[merchantKey(t.tx)] ??= []).add(t);
  }
  final out = <RecurringBill>[];
  final perClass = <String, int>{};
  for (final e in byPayee.entries) {
    final all = e.value
      ..sort((a, b) {
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.tx.id.compareTo(b.tx.id);
      });
    for (var c = 0; c < _classes.length; c++) {
      final cls = _classes[c];
      final rows = [
        for (final r in all)
          if (r.date.compareTo(starts[c]) >= 0) r
      ];
      final bill = _fits(e.key, rows, cls.period.days, cls.rows);
      if (bill == null) continue;
      out.add(bill);
      perClass[cls.period.name] = (perClass[cls.period.name] ?? 0) + 1;
      break;
    }
  }
  out.sort((a, b) {
    final d = a.label.compareTo(b.label);
    return d != 0 ? d : a.id.compareTo(b.id);
  });
  // Counts only: payees are personal.
  logEvent(_log, Level.FINE, 'recurring.detect', {'payees': byPayee.length, 'candidates': out.length, ...perClass});
  return out;
}

/// The candidate for [payee] when its [rows] (sorted, oldest first) make a bill repeating every [days]: at least
/// [minRows], every gap within [RecurringBill.toleranceFor] of [days], every amount within the band of the median.
RecurringBill? _fits(String payee, List<CategorizedTx> rows, int days, int minRows) {
  if (rows.length < minRows) return null;
  final tol = RecurringBill.toleranceFor(days);
  for (var i = 1; i < rows.length; i++) {
    if ((daysBetween(rows[i - 1].date, rows[i].date) - days).abs() > tol) return null;
  }
  final amounts = [for (final r in rows) -r.amount];
  final median = medianCents(amounts);
  if (median <= 0 || amounts.any((a) => !_withinBand(a, median))) return null;
  final last = rows.last;
  return RecurringBill(
    id: RecurringBill.idFor(payee),
    payee: payee,
    label: merchantName(last.tx),
    category: last.category,
    expectedAmount: median,
    intervalDays: days,
    nextDue: addDays(last.date, days),
  );
}

/// What [planRecurringPayments] found for the bills' current cycles (due `nextDue`): [paidBy] = per bill id, the bank
/// row that pays the cycle (a single payment, or the row that completes it in parts, see [paidInParts]); [parts] = per
/// bill id, the rows counted towards a cycle that is **not** paid yet (oldest first; absent when none).
class RecurringPayments {
  final Map<String, Tx> paidBy;
  final Map<String, List<Tx>> parts;

  /// Ids in [paidBy] whose cycle was paid by parts adding up (then `nextDue` moves to `nextDue + intervalDays`, not
  /// from the paying row's date).
  final Set<String> paidInParts;

  const RecurringPayments(this.paidBy, {this.parts = const {}, this.paidInParts = const {}});

  /// No cycle is paid ([parts] alone pay nothing).
  bool get isEmpty => paidBy.isEmpty;

  /// Σ |amount| of [parts] for bill [id] (0 without parts): what is already paid of its open cycle.
  int partsPaid(String id) => (parts[id] ?? const <Tx>[]).fold(0, (s, t) => s - t.amount);
}

/// Days before `nextDue` that a part may be dated: `min(14, intervalDays − tolerance − 1)`, so the window never reaches
/// back to the previous cycle's own match window.
int partsDays(RecurringBill b) {
  final d = b.intervalDays - b.tolerance - 1;
  return d < 14 ? (d < 0 ? 0 : d) : 14;
}

/// The cents parts must reach to pay a cycle: the range's low end ([RecurringBill.hasRange]), else the low end of the
/// [recurringPercent] band, `expectedAmount − expectedAmount ~/ 10`.
int partsThreshold(RecurringBill b) => b.hasRange ? b.minAmount! : b.expectedAmount - b.expectedAmount ~/ 10;

/// Whether [cents] (an outflow, positive) is an amount that pays [b] in one go: within the range ([hasRange], inclusive),
/// else within [recurringPercent] of `expectedAmount`.
bool _paysInOne(RecurringBill b, int cents) =>
    b.hasRange ? cents >= b.minAmount! && cents <= b.maxAmount! : _withinBand(cents, b.expectedAmount);

/// Finds what pays each confirmed bill's current cycle (due `nextDue`). Never by amount alone: every row must carry the
/// bill's payee key (`merchantKey == payee`; a bill without payee never matches). Rows: live, not hand-added outflows
/// in [currency] with a real date, never the row that paid the previous cycle (`lastPaidTx`).
/// - **Single payment:** a row within ± [RecurringBill.tolerance] of `nextDue` whose outflow pays in one go
///   ([_paysInOne]); the closest to `nextDue` wins (then the earliest date, then the smallest id). A monthly bill
///   without a range matches exactly as before P4 (± [recurringDays], [recurringPercent] band).
/// - **Parts** (when no single payment matches): the rows dated in `[nextDue − partsDays, nextDue + tolerance]`,
///   strictly after the `lastPaidTx` row's date (when that row is in [rows]), each with |amount| ≤ `reserveAmount`,
///   summed oldest first (then by id). At least two rows reaching [partsThreshold] pay the cycle: the row that reaches
///   it is the paying row ([RecurringPayments.paidBy] + `paidInParts`). Otherwise the counted rows are
///   [RecurringPayments.parts]: one row alone never pays a cycle (that is the single-payment rule), but it counts.
/// Finished bills (`endsOn` passed) are left out. Deterministic, so every device marks the same cycle paid with the
/// same row; rows are never changed (a bill never reclassifies).
RecurringPayments planRecurringPayments(List<RecurringBill> bills, List<Tx> rows, {required String currency}) {
  final byPayee = <String, List<Tx>>{};
  final dateOf = <String, String>{};
  for (final t in rows) {
    dateOf[t.id] = t.date;
    if (!t.live || t.manual || t.amount >= 0 || t.date.length != 10 || t.currency != currency) continue;
    (byPayee[merchantKey(t)] ??= []).add(t);
  }
  final paid = <String, Tx>{};
  final parts = <String, List<Tx>>{};
  final inParts = <String>{};
  for (final b in bills) {
    if (!b.confirmed || b.payee.isEmpty || b.nextDue.length != 10 || b.expectedAmount <= 0 || b.finished) continue;
    final mine = byPayee[b.payee];
    if (mine == null) continue;
    final tol = b.tolerance;
    Tx? best;
    var bestDays = 0;
    for (final t in mine) {
      if (t.id == b.lastPaidTx || !_paysInOne(b, -t.amount)) continue;
      final days = daysBetween(b.nextDue, t.date).abs();
      if (days > tol) continue;
      if (best == null ||
          days < bestDays ||
          (days == bestDays && (t.date.compareTo(best.date) < 0 || (t.date == best.date && t.id.compareTo(best.id) < 0)))) {
        best = t;
        bestDays = days;
      }
    }
    if (best != null) {
      paid[b.id] = best;
      continue;
    }
    final from = addDays(b.nextDue, -partsDays(b)), to = addDays(b.nextDue, tol);
    final after = b.lastPaidTx == null ? null : dateOf[b.lastPaidTx];
    final counted = [
      for (final t in mine)
        if (t.id != b.lastPaidTx &&
            -t.amount <= b.reserveAmount &&
            t.date.compareTo(from) >= 0 &&
            t.date.compareTo(to) <= 0 &&
            (after == null || t.date.compareTo(after) > 0))
          t
    ]..sort((x, y) {
        final d = x.date.compareTo(y.date);
        return d != 0 ? d : x.id.compareTo(y.id);
      });
    if (counted.isEmpty) continue;
    final threshold = partsThreshold(b);
    var sum = 0;
    Tx? completing;
    for (var i = 0; i < counted.length; i++) {
      sum -= counted[i].amount;
      if (i >= 1 && sum >= threshold) {
        completing = counted[i];
        break;
      }
    }
    if (completing != null) {
      paid[b.id] = completing;
      inParts.add(b.id);
    } else {
      parts[b.id] = List.unmodifiable(counted);
    }
  }
  return RecurringPayments(paid, parts: parts, paidInParts: inParts);
}
