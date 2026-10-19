import 'dates.dart';
import 'hlc.dart';
import 'models.dart';

/// What [planMatches] wants written: `matched_to` per manual entry id (null = unmatch) and the category a bank
/// row takes over from the manual entry it replaces (only when the bank row has none of its own).
class MatchPlan {
  final Map<String, String?> matchedTo;
  final Map<String, String> bankCategory;

  /// New manual → bank pairs (not counting kept ones).
  final int added;
  const MatchPlan(this.matchedTo, this.bankCategory, this.added);
  bool get isEmpty => matchedTo.isEmpty && bankCategory.isEmpty;
}

final _iso = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Matches hand-added expenses to the bank rows that replace them: same amount, at most 3 days apart, one-to-one.
///
/// A pure function of the rows, so every device holding the same rows plans the same writes (sync converges even
/// when the manual entry and the bank row arrive on a device in either order), and applying the plan gives a state
/// whose plan is empty (idempotent):
/// - an existing match is kept (also if its bank row has not arrived yet); when several live manual entries point at
///   the same bank row, the one with the smallest id keeps it and the others are unmatched and matched again below;
/// - every unmatched live manual entry, oldest first (date, then id), takes the free [eligible] bank row with the
///   same amount that is closest in days (then earliest date, then smallest id), among the bank rows first written
///   after the entry ([written]).
///
/// Only a bank row that arrives after the entry replaces it: an expense added by hand while the wallet already holds
/// a same-amount card payment from the days around it is a different expense (cash next to a card payment), not
/// that payment. "After" is by HLC, not by device or wall clock, so it holds when the entry was added offline on one
/// device and the bank row was imported later on another (they then match in whichever order they sync).
///
/// [manual]: live (not deleted) manual entries; [bank]: non-manual rows that are not deleted. [eligible] says which
/// bank rows may replace a manual entry (expenses whose built-in kind is flex or fixed). [written]: the HLC of each
/// row's first write (the clock of its `amount`, written only when the row is created); a row without one is never
/// matched.
MatchPlan planMatches(List<Tx> manual, List<Tx> bank, bool Function(Tx) eligible, Map<String, String> written) {
  final matchedTo = <String, String?>{};
  final bankCategory = <String, String>{};
  final taken = <String>{};
  final open = <Tx>[];
  for (final m in [...manual]..sort((a, b) => a.id.compareTo(b.id))) {
    final to = m.matchedTo;
    if (to == null) {
      open.add(m);
    } else if (!taken.add(to)) {
      matchedTo[m.id] = null; // a second entry on the same bank row
      open.add(m);
    }
  }
  if (open.isEmpty) return MatchPlan(matchedTo, bankCategory, 0);
  final byAmount = <int, List<Tx>>{};
  for (final b in bank) {
    if (b.amount < 0 && !b.manual && !b.deleted && !taken.contains(b.id) && _iso.hasMatch(b.date) && eligible(b)) {
      (byAmount[b.amount] ??= []).add(b);
    }
  }
  open.sort((a, b) {
    final d = a.date.compareTo(b.date);
    return d != 0 ? d : a.id.compareTo(b.id);
  });
  var added = 0;
  for (final m in open) {
    final pool = byAmount[m.amount];
    final since = written[m.id];
    if (pool == null || since == null || !_iso.hasMatch(m.date)) continue;
    Tx? best;
    var bestDays = 0;
    for (final b in pool) {
      if (taken.contains(b.id)) continue;
      final days = daysBetween(m.date, b.date).abs();
      if (days > 3) continue;
      final at = written[b.id];
      if (at == null || Hlc.compareStrings(at, since) <= 0) continue; // in the wallet before the entry: not its row
      if (best == null ||
          days < bestDays ||
          (days == bestDays && (b.date.compareTo(best.date) < 0 || (b.date == best.date && b.id.compareTo(best.id) < 0)))) {
        best = b;
        bestDays = days;
      }
    }
    if (best == null) continue;
    taken.add(best.id);
    matchedTo[m.id] = best.id;
    added++;
    final c = m.category;
    if (best.category == null && c != null) bankCategory[best.id] = c;
  }
  return MatchPlan(matchedTo, bankCategory, added);
}
