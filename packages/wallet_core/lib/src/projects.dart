// ENG §5.4 / §6.4: one extra tag seen as a project. Pure, web-safe, exact integer cents. Read-only: candidates are
// proposals the owner confirms through the tag flow; nothing here tags a row.
import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'budget.dart' show countsAsSpending;
import 'categories.dart' show BudgetKind, CategoryTable;
import 'dates.dart';
import 'hours.dart';
import 'models.dart';
import 'tags.dart' show TagContext, tagPayee;

/// [projectStats]' result. Rows are counted as "Where it goes" ([countsAsSpending]: live, in the home currency, fixed
/// or flex, refunds subtracted; transfers, IOU-linked and deleted rows out), a split part by its own tags, so
/// [total] = Σ [byMainTag] = Σ [byYear] = the last [running] value = `tagShare`'s slice over the same span.
/// Every tagged row counts, future-dated ones too: the span is [[first], [last]] when [ended], else
/// [[first], max([last], today)].
///
/// Not in this cut: "still coming" (planned costs carrying the tag): planned costs have no tags yet.
class ProjectStats {
  /// The first and last date of a counted tagged row; both `today` when there is none ([isEmpty]).
  final String first, last;

  /// No counted tagged row: every figure is 0 or empty. The UI checks this first.
  bool get isEmpty => count == 0;

  /// [last] is more than 90 days before today: the span ends at [last], else at max([last], today).
  final bool ended;

  /// Calendar months in the span (= [running].length); [count] = tagged payments (a split counts once).
  final int months, count;
  final int total;

  /// [total] in thousandths of all spending over the span; 0 when either is ≤ 0 (refunds can exceed spending).
  final int sharePermille;

  /// [total] as tenths of an hour of work (`hoursTenths`), 0 when [total] ≤ 0; null without settings or a salary.
  final int? hoursTenths;

  /// Main tag (top-level category) → cents, amount desc then id.
  final List<(String id, int cents)> byMainTag;

  /// Every year of the span, oldest first (a year with nothing is 0).
  final List<(int year, int cents)> byYear;

  /// Cumulative cents at the end of every month of the span (`YYYY-MM`), oldest first, zero months included.
  final List<(String month, int cents)> running;

  /// Other extra tags on the same payments → payments shared, count desc then id.
  final List<(String id, int count)> overlaps;

  /// "Not tagged yet": whole payments at the tag's payees, newest first. See [projectStats].
  final List<Tx> candidates;

  const ProjectStats(
      {required this.first,
      required this.last,
      required this.ended,
      required this.months,
      required this.count,
      required this.total,
      required this.sharePermille,
      required this.hoursTenths,
      required this.byMainTag,
      required this.byYear,
      required this.running,
      required this.overlaps,
      required this.candidates});
}

/// Days after which a project with no new payment has ended.
const projectEndedDays = 90;

/// Days after the last tagged payment a candidate may still fall.
const _candidateTailDays = 30;

/// Project stats for extra tag [tagId] over [expanded] (`Categorizer.expand`, rows' [CategorizedTx.tags] = `tagsOf`).
/// [candidates]: live fixed or flex outflows in [currency], never transfers or IOU-linked, never a payment already carrying the tag
/// (any part) or whose link turns it off, whose payee (`tagPayee`) is a payee of a counted tagged row, dated within
/// [first, last + 30 days]. Never chosen by amount.
ProjectStats projectStats(String tagId, List<CategorizedTx> expanded,
    {required TagContext tags, required CategoryTable table, required String currency, required String today, WalletSettings? st}) {
  final tag = tags.tags.resolve(tagId) ?? tagId;
  final byMonth = <String, int>{};
  final byMain = <String, int>{};
  final payments = <String>{};
  final carrying = <String>{}; // tx ids with the tag on any row, counted or not
  final shared = <String, Set<String>>{};
  final payees = <String>{};
  final keyOf = <String, String?>{}; // description -> payee (a bank row's key depends on its description only)
  String? payeeOf(Tx tx) => tx.source == 'manual' ? tagPayee(tx) : keyOf.putIfAbsent(tx.description, () => tagPayee(tx));
  String? first, last;
  var total = 0;
  for (final t in expanded) {
    if (!t.tags.contains(tag)) continue;
    carrying.add(t.tx.id);
    if (!countsAsSpending(t, currency)) continue;
    final d = t.date;
    if (first == null || d.compareTo(first) < 0) first = d;
    if (last == null || d.compareTo(last) > 0) last = d;
    total -= t.amount;
    byMonth[monthOf(d)] = (byMonth[monthOf(d)] ?? 0) - t.amount;
    final main = table.topLevel(t.category);
    byMain[main] = (byMain[main] ?? 0) - t.amount;
    payments.add(t.tx.id);
    for (final o in t.tags) {
      if (o != tag) (shared[o] ??= {}).add(t.tx.id);
    }
    if (payeeOf(t.tx) case final p?) payees.add(p);
  }
  first ??= today;
  last ??= today;
  final ended = payments.isNotEmpty && daysBetween(last, today) > projectEndedDays;
  final end = ended || last.compareTo(today) > 0 ? last : today;
  final tailEnd = addDays(last, _candidateTailDays);

  var all = 0;
  final candidates = <String, Tx>{};
  for (final t in expanded) {
    final d = t.date;
    if (d.compareTo(first) < 0) continue;
    if (d.compareTo(end) <= 0 && countsAsSpending(t, currency)) all -= t.amount;
    final tx = t.tx;
    if (payees.isEmpty ||
        d.compareTo(tailEnd) > 0 ||
        !tx.live ||
        tx.currency != currency ||
        tx.amount >= 0 ||
        (t.kind != BudgetKind.fixed && t.kind != BudgetKind.flex) ||
        t.iou ||
        (t.whole ?? t).kind == BudgetKind.transfer ||
        tx.transferTo != null ||
        tx.kindHint == TxKind.ownTransfer ||
        tx.kindHint == TxKind.exchange ||
        carrying.contains(tx.id) ||
        candidates.containsKey(tx.id) ||
        !payees.contains(payeeOf(tx)) ||
        tags.offTags(tx).any((o) => (tags.tags.resolve(o) ?? o) == tag)) {
      continue;
    }
    candidates[tx.id] = tx;
  }

  final running = <(String, int)>[];
  final years = <int, int>{};
  var sum = 0;
  for (var m = monthOf(first); m.compareTo(monthOf(end)) <= 0; m = _nextMonth(m)) {
    final c = byMonth[m] ?? 0;
    sum += c;
    running.add((m, sum));
    final y = int.parse(m.substring(0, 4));
    years[y] = (years[y] ?? 0) + c;
  }
  int byAmount((String, int) a, (String, int) b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1);
  return ProjectStats(
    first: first,
    last: last,
    ended: ended,
    months: running.length,
    count: payments.length,
    total: total,
    sharePermille: total > 0 && all > 0 ? roundDiv(BigInt.from(total) * BigInt.from(1000), BigInt.from(all)).toInt() : 0,
    hoursTenths: st == null ? null : hoursTenths(total > 0 ? total : 0, st),
    byMainTag: [for (final e in byMain.entries) (e.key, e.value)]..sort(byAmount),
    byYear: [for (final e in years.entries) (e.key, e.value)],
    running: running,
    overlaps: [for (final e in shared.entries) (e.key, e.value.length)]..sort(byAmount),
    candidates: candidates.values.toList()
      ..sort((a, b) {
        final c = b.date.compareTo(a.date);
        return c != 0 ? c : b.id.compareTo(a.id);
      }),
  );
}

String _nextMonth(String ym) {
  final y = int.parse(ym.substring(0, 4)), m = int.parse(ym.substring(5, 7));
  return m == 12 ? '${y + 1}-01' : '$y-${(m + 1).toString().padLeft(2, '0')}';
}
