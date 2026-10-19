import 'dart:convert';

import 'dates.dart';
import 'hlc.dart';
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.match');

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

/// Days a bank row may be from the hand-added expense it replaces.
const matchDays = 3;

/// Which bank rows the device that added a manual entry already held at that moment: the entry's `seen_bank` field,
/// written with the entry (`WalletRepo.addManual`) and synced with it, so every device decides the same.
///
/// Per device that imported bank rows (the node of their `amount` clock), the highest such clock the adding device
/// held. A device reads each other device's sync files in order, so holding that device's row written at `h` means
/// holding all its rows written up to `h`; a bank row whose clock is above its node's value, or from a node not listed,
/// was not on the adding device. Entries without the field (added by older builds, or with a damaged value) fall back
/// to the entry's own `amount` clock: only a bank row written after the entry was not seen.
class SeenBank {
  final Hlc _entry;
  final Map<String, Hlc>? _byNode;
  const SeenBank._(this._entry, this._byNode);

  /// [entryWritten]: the entry's `amount` clock; [value]: its `seen_bank` field.
  factory SeenBank.of(String entryWritten, String? value) => SeenBank._(Hlc.parse(entryWritten), value == null ? null : _decode(value));

  /// Whether this entry has a `seen_bank` value (false: the fallback to its own clock).
  bool get recorded => _byNode != null;

  /// Whether the bank row first written at [bankWritten] was not on the adding device when the entry was added, so it
  /// may be the payment that replaces the entry.
  bool unseen(String bankWritten) {
    final b = Hlc.parse(bankWritten);
    final by = _byNode;
    if (by == null) return b.compareTo(_entry) > 0;
    final top = by[b.node];
    return top == null || b.compareTo(top) > 0;
  }

  /// The `seen_bank` value for a device holding bank rows with these `amount` clocks (any number per node).
  static String encode(Iterable<String> bankWritten) {
    final top = <String, (Hlc, String)>{};
    for (final s in bankWritten) {
      final h = Hlc.parse(s);
      final cur = top[h.node];
      if (cur == null || h.compareTo(cur.$1) > 0) top[h.node] = (h, s);
    }
    return jsonEncode([for (final v in top.values) v.$2]..sort());
  }

  static Map<String, Hlc>? _decode(String value) {
    try {
      final out = <String, Hlc>{};
      for (final s in jsonDecode(value) as List) {
        final h = Hlc.parse(s as String);
        final cur = out[h.node];
        if (cur == null || h.compareTo(cur) > 0) out[h.node] = h;
      }
      return out;
    } catch (e, st) {
      // Damaged or from a future format: the entry's own clock decides, the same on every device.
      logError(_log, 'match.seenBank.invalid', e, st, level: Level.FINE);
      return null;
    }
  }
}

/// The manual entries [planMatches] will try to match: unmatched ones, ones whose bank row is in [gone] (deleted, or
/// not a bank row), and every entry but the smallest id on a bank row shared by several. [taken]: the bank rows that
/// keep their entry. A bank row that is not in the wallet yet (its sync file has not arrived, or is damaged) keeps its
/// entry: reopening it there would undo, on every sync, the match that devices holding the row write again.
({List<Tx> open, Set<String> taken}) _split(List<Tx> manual, Set<String> gone) {
  final taken = <String>{};
  final open = <Tx>[];
  for (final m in [...manual]..sort((a, b) => a.id.compareTo(b.id))) {
    final to = m.matchedTo;
    if (to == null || gone.contains(to) || !taken.add(to)) open.add(m);
  }
  return (open: open, taken: taken);
}

/// The manual entries that [planMatches] tries to match, given [gone]: the ids of the rows entries point at that are
/// deleted or are not bank rows (a row not in the wallet at all is not gone). Callers then load only the bank rows
/// that could replace one of them (same amount, within [matchDays], written after it). Empty when every entry keeps
/// its match.
List<Tx> openEntries(List<Tx> manual, Set<String> gone) => _split(manual, gone).open;

/// Matches hand-added expenses to the bank rows that replace them: same amount, at most [matchDays] days apart,
/// one-to-one.
///
/// A pure function of the rows, so every device holding the same rows plans the same writes (sync converges even
/// when the manual entry and the bank row arrive on a device in either order), and applying the plan gives a state
/// whose plan is empty (idempotent):
/// - an existing match is kept unless its bank row is deleted or is not a bank row: then the entry is open again, so
///   it counts as spending instead of vanishing with the row. A bank row this device does not hold yet keeps the match
///   (devices that hold it wrote that match, and reopening it here would only start a rewrite war over sync); when
///   several live manual entries point at the same bank row, the one with the smallest id keeps it and the others are
///   unmatched;
/// - open entries are matched again below (an entry whose row was deleted can take a later bank row);
/// - every unmatched live manual entry, oldest first (date, then id), takes the free [eligible] bank row with the
///   same amount that is closest in days (then earliest date, then smallest id), among the bank rows that were not on
///   the adding device when the entry was added ([SeenBank]).
///
/// Only a bank row that the entry's device did not hold yet replaces it: an expense added by hand while the wallet
/// already holds a same-amount card payment from the days around it is a different expense (cash next to a card
/// payment), not that payment. A bank row imported earlier on another device that had not synced yet does replace
/// it (the owner added by hand what the laptop already imported: one expense). Decided by HLCs and the synced
/// `seen_bank` value, not by wall clocks, so the entry and the bank row match in whichever order they sync.
///
/// [manual]: live (not deleted) manual entries; [bank]: non-manual rows that are not deleted, plus every row that a
/// manual entry points at, deleted or not (a target not in [bank] counts as not arrived yet, and keeps its entry).
/// [eligible] says which bank rows may replace a manual entry (expenses whose built-in kind is flex or fixed).
/// [written]: the HLC of each row's first write (the clock of its `amount`, written only when the row is created); a
/// row without one is never matched. [seenBank]: each manual entry's `seen_bank` field, where it has one.
MatchPlan planMatches(List<Tx> manual, List<Tx> bank, bool Function(Tx) eligible, Map<String, String> written,
    {Map<String, String> seenBank = const {}}) {
  final matchedTo = <String, String?>{};
  final bankCategory = <String, String>{};
  final (:open, :taken) = _split(manual, {
    for (final b in bank)
      if (b.manual || b.deleted) b.id
  });
  for (final m in open) {
    if (m.matchedTo != null) matchedTo[m.id] = null; // its bank row was deleted (or is not one), or taken by another entry
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
    final seen = SeenBank.of(since, seenBank[m.id]);
    Tx? best;
    var bestDays = 0;
    for (final b in pool) {
      if (taken.contains(b.id)) continue;
      final days = daysBetween(m.date, b.date).abs();
      if (days > matchDays) continue;
      final at = written[b.id];
      if (at == null || !seen.unseen(at)) continue; // on the entry's device when it was added: not its row
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
