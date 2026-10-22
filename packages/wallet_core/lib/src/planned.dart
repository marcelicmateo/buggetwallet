/// Future spending (§4.3): amount suggestions, the Upcoming list, "Paid by this?" candidates and heads-ups. Pure: the
/// caller passes the lists (planned costs from `WalletRepo.plannedCosts(includeClosed: true)`, bills from
/// `WalletRepo.recurringBills()`, calendar events read on this device). Web-safe.
library;

import 'bills.dart';
import 'dates.dart';
import 'ics.dart';
import 'models.dart';
import 'search.dart' show foldText;

/// An amount as written in text: digits with optional thousands separators (`.`, `,`, space, `'`; groups of three)
/// and an optional decimal part (`.` or `,`, one or two digits).
const _num = r"(\d{1,3}(?:[  .,']\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)";

/// A euro amount: `€80`, `EUR 80`, `80 €`, `80 EUR`, `80 eura`. A minus sign directly before the digits is captured
/// (group 1 or 3) so negative amounts are refused.
final _amountRe = RegExp(
  '(?<![\\p{L}\\d])(?:€|eur(?:o|a)?)\\s*(-?)$_num(?![\\d]|[.,]\\d)'
  '|(?<![\\d.,])(-?)$_num\\s*(?:€|eur(?:o|a)?(?!\\p{L}))',
  caseSensitive: false,
  unicode: true,
);

/// Most digits before the decimal point (more is never a planned cost).
const _maxDigits = 12;

/// The cents of one matched number, or null when its separators make no sense (`1.250.00`, `0.250`, too many digits).
int? _parseNum(String s) {
  s = s.replaceAll(' ', ' ');
  var whole = s;
  var frac = '';
  final dec = RegExp(r'[.,](\d{1,2})$').firstMatch(s);
  String? decSep;
  if (dec != null) {
    whole = s.substring(0, dec.start);
    frac = dec.group(1)!;
    decSep = s[dec.start];
  }
  final seps = whole.replaceAll(RegExp(r'\d'), '');
  if (seps.isNotEmpty) {
    final sep = seps[0];
    if (seps.split('').any((c) => c != sep) || sep == decSep) return null; // mixed or same as the decimal separator
    if (whole.startsWith('0')) return null; // `0.250` is no grouping
    whole = whole.replaceAll(sep, '');
  }
  if (whole.isEmpty || whole.length > _maxDigits) return null;
  return int.parse(whole) * 100 + (frac.isEmpty ? 0 : int.parse(frac.padRight(2, '0')));
}

/// The euro amount written in [text] in cents: `80 €`, `€80`, `80 EUR`, `80,00 €`, `1.250,00 €`, `1,250.00 €`,
/// `80.5€` (a single `.`/`,` with three digits after it is a thousands separator: `1.250 €` = 1250 €). Only numbers
/// next to `€`/`EUR` count (`2026`, `14:30` never do). null when there is none, when two different amounts are written
/// (the same one twice is fine), for zero or negative amounts, and for numbers whose separators make no sense.
int? amountFromText(String text) {
  int? found;
  for (final m in _amountRe.allMatches(text)) {
    final minus = m.group(1) ?? m.group(3) ?? '';
    final cents = _parseNum(m.group(2) ?? m.group(4)!);
    if (cents == null) return null; // a malformed amount: ambiguous
    if (minus.isNotEmpty || cents == 0) continue; // never a cost
    if (found != null && found != cents) return null;
    found = cents;
  }
  return found;
}

/// Most cents an amount typed by the owner may be ([parseMoneyCents]): the one cap, the repo's [WalletSettings.maxAmount].
const maxAmountCents = WalletSettings.maxAmount;

final _plainNumber = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$');

/// The cents of an amount typed by hand: "12", "12.5", "12,50", "1.234,56", "1,234.56" (a comma followed by one or
/// two digits is the decimal separator; else commas group thousands), currency signs and spaces ignored. Null if not
/// a number, negative, in exponent form, or beyond [maxAmountCents]. The value is `abs() * 100` rounded to the cent
/// (the rule the app's input fields had).
int? parseMoneyCents(String input) {
  var s = input.trim().replaceAll(RegExp(r'[\s€\$£]'), '');
  if (s.isEmpty) return null;
  if (RegExp(r',\d{1,2}$').hasMatch(s)) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^[+-]?0*,\d{3}$').hasMatch(s)) {
    return null; // "0,005": a thousands group cannot follow a zero
  } else {
    s = s.replaceAll(',', '');
  }
  if (!_plainNumber.hasMatch(s)) return null;
  final v = double.tryParse(s);
  if (v == null || !v.isFinite) return null;
  if (s.startsWith('-') && v != 0) return null;
  final cents = v.abs() * 100;
  if (cents > maxAmountCents) return null;
  return cents.round();
}

/// [title] for matching events across months: folded ([foldText]: lower case, accents), amounts ([amountFromText]'s
/// patterns) and every digit removed, any other non-letter turned into a space, single spaces, trimmed. `Zubar ČĆŽ
/// 80 €` → `zubar ccz`; `Dentist 2026` → `dentist`.
String normalizeTitle(String title) =>
    foldText(title).replaceAll(_amountRe, ' ').replaceAll(RegExp(r'[^\p{L}]+', unicode: true), ' ').trim();

/// `bill` = a recurring bill's occurrence; `warranty` / `returnBy` = the last day of a stored bill's warranty or
/// return window (never counted: amount null).
enum UpcomingKind { planned, bill, suggestion, warranty, returnBy }

/// One line of the Upcoming list ([upcoming]).
class UpcomingItem {
  final UpcomingKind kind;

  /// `p:<planned id>`, `b:<bill id>@<date>` (a bill can occur more than once in a range), `e:<event ref>`,
  /// `w:<bill id>` (warranty), `r:<bill id>` (return by).
  final String key;
  final String date;
  final String title;

  /// The counted amount: a planned cost's amount (null = none yet), a confirmed bill's expected amount; null for a
  /// suggestion.
  final int? amount;

  /// Suggestions only: the suggested amount, and where it came from: `title` (the event's title or notes) or
  /// `earlier` (an earlier planned cost with the same [normalizeTitle]).
  final int? suggested;
  final String? suggestedFrom;
  final String? category;
  final PlannedCost? planned;
  final RecurringBill? bill;
  final CalendarEvent? event;

  /// Warranty / return-by items: the stored bill ([Bill], not a [RecurringBill]).
  final Bill? billDb;

  const UpcomingItem({
    required this.kind,
    required this.key,
    required this.date,
    required this.title,
    this.amount,
    this.suggested,
    this.suggestedFrom,
    this.category,
    this.planned,
    this.bill,
    this.event,
    this.billDb,
  });
}

/// Most occurrences of one bill listed or exported.
const _maxOccurrences = 1000;

/// The dates of [b] in [from, to] (inclusive): `nextDue`, then every `intervalDays` after it (an interval below 1
/// gives `nextDue` only). Occurrences before [from] are skipped, so an overdue bill shows from its next date on. No
/// check of `status`: the callers take confirmed bills only.
List<String> billOccurrences(RecurringBill b, String from, String to) {
  if (!isIsoDate(b.nextDue) || !isIsoDate(from) || !isIsoDate(to) || from.compareTo(to) > 0) return const [];
  final step = b.intervalDays;
  var d = b.nextDue;
  if (step < 1) return d.compareTo(from) >= 0 && d.compareTo(to) <= 0 ? [d] : const [];
  if (d.compareTo(from) < 0) d = addDays(d, (daysBetween(d, from) + step - 1) ~/ step * step);
  final out = <String>[];
  while (d.compareTo(to) <= 0 && out.length < _maxOccurrences) {
    out.add(d);
    d = addDays(d, step);
  }
  return out;
}

/// A bill's planned row whose covering recurring occurrence ([plannedCoverage]) is listed in the same range, or is the
/// cycle just paid or skipped: left out of `upcoming` / `plannedIcs`.
bool _shownByBill(PlannedCost p, List<RecurringBill> bills, bool Function(String) inRange) {
  final c = plannedCoverage(p, bills);
  return c != null && (c.occurrence == null || inRange(c.occurrence!));
}

/// The Upcoming list for [from, to] (both inclusive; from after to = empty): open planned costs (not deleted), the
/// occurrences of confirmed recurring bills ([billOccurrences]; `coveredByPlan` ones included: their [UpcomingItem.bill]
/// tells), and calendar events with no planned row of the same ref in [planned] (any status, deleted included: pass
/// `plannedCosts(includeClosed: true)`) as suggestions. A suggestion's amount comes from the event's title, else its
/// notes ([amountFromText], `suggestedFrom: 'title'`), else from the latest planned cost dated before the event with the
/// same non-empty [normalizeTitle], an amount, open or paid and not deleted (`'earlier'`; its category is suggested
/// too). Events with the same ref ([calendarEventRef]: same normalized title and date, from any calendar) are listed
/// once: the one first by calendar id, uid, title, then notes, so every device picks the same whatever the list order.
/// [billsDb] (`WalletRepo.bills()`): the `warrantyUntil` / `returnBy` dates of confirmed, live bills in range
/// (title = payee, else description; amount null; a bill's planned row is already in [planned]). A bill's planned row a
/// confirmed recurring bill already plans ([plannedCoverage]) is left out when that bill's covering occurrence is in
/// [from, to] too (it stands for it) or is the cycle just paid or skipped; otherwise it is listed (BILLS_API.md §3).
/// Sorted by date, then title, then key.
List<UpcomingItem> upcoming({
  required List<PlannedCost> planned,
  required List<RecurringBill> bills,
  required List<CalendarEvent> events,
  required String from,
  required String to,
  List<Bill> billsDb = const [],
}) {
  if (!isIsoDate(from) || !isIsoDate(to) || from.compareTo(to) > 0) return const [];
  bool inRange(String d) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  final out = <UpcomingItem>[];
  for (final p in planned) {
    if (!p.isOpen || !inRange(p.date) || _shownByBill(p, bills, inRange)) continue;
    out.add(UpcomingItem(
        kind: UpcomingKind.planned, key: 'p:${p.id}', date: p.date, title: p.title, amount: p.amount, category: p.category, planned: p));
  }
  for (final b in bills) {
    if (!b.confirmed) continue;
    for (final d in billOccurrences(b, from, to)) {
      out.add(UpcomingItem(
          kind: UpcomingKind.bill, key: 'b:${b.id}@$d', date: d, title: b.label, amount: b.expectedAmount, category: b.category, bill: b));
    }
  }
  for (final b in billsDb) {
    if (b.deleted || !b.confirmed) continue;
    final title = b.payee ?? b.description ?? '';
    if (b.warrantyUntil case final d? when isIsoDate(d) && inRange(d)) {
      out.add(UpcomingItem(kind: UpcomingKind.warranty, key: 'w:${b.id}', date: d, title: title, category: b.category, billDb: b));
    }
    if (b.returnBy case final d? when isIsoDate(d) && inRange(d)) {
      out.add(UpcomingItem(kind: UpcomingKind.returnBy, key: 'r:${b.id}', date: d, title: title, category: b.category, billDb: b));
    }
  }
  final stored = {for (final p in planned) p.sourceRef};
  final seen = <String>{};
  // Earlier confirmed amounts by normalized title, latest date last.
  final earlier = <String, List<PlannedCost>>{};
  for (final p in planned) {
    if (p.deleted || p.amount == null || p.status == PlannedStatus.skipped || !isIsoDate(p.date)) continue;
    final t = normalizeTitle(p.title);
    if (t.isNotEmpty) (earlier[t] ??= []).add(p);
  }
  for (final l in earlier.values) {
    l.sort(comparePlanned);
  }
  int byIdentity(CalendarEvent a, CalendarEvent b) {
    var c = a.calendarId.compareTo(b.calendarId);
    if (c == 0) c = a.uid.compareTo(b.uid);
    if (c == 0) c = a.title.compareTo(b.title);
    return c != 0 ? c : (a.notes ?? '').compareTo(b.notes ?? '');
  }

  for (final e in [...events]..sort(byIdentity)) {
    if (!inRange(e.date)) continue;
    final ref = e.ref;
    if (stored.contains(ref) || !seen.add(ref)) continue;
    int? suggested = amountFromText(e.title);
    if (suggested == null && e.notes != null) suggested = amountFromText(e.notes!);
    String? from0 = suggested != null ? 'title' : null;
    PlannedCost? prior;
    for (final p in earlier[normalizeTitle(e.title)] ?? const <PlannedCost>[]) {
      if (p.date.compareTo(e.date) < 0) prior = p;
    }
    if (suggested == null && prior != null) {
      suggested = prior.amount;
      from0 = 'earlier';
    }
    out.add(UpcomingItem(
        kind: UpcomingKind.suggestion,
        key: 'e:$ref',
        date: e.date,
        title: e.title,
        suggested: suggested,
        suggestedFrom: from0,
        category: prior?.category,
        event: e));
  }
  out.sort((a, b) {
    var c = a.date.compareTo(b.date);
    if (c == 0) c = a.title.compareTo(b.title);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out;
}

/// Days either side of a planned cost's date in which a transaction may have paid it.
const _paidWindowDays = 3;

/// "Paid by this?" candidates for [p]: live expenses (amount < 0; no income, deleted or replaced rows) of exactly
/// [p]'s category dated within its date ± [_paidWindowDays], that are not already the `paidTx` of another planned cost
/// in [all]. Closest date first, then the amount closest to [p]'s amount, then date, then id. Never matched by amount
/// alone (exact money rule): a planned cost without a category has no candidates. Only the owner's pick links one.
List<CategorizedTx> paidCandidates(PlannedCost p, List<CategorizedTx> txs, List<PlannedCost> all) {
  final cat = p.category;
  if (cat == null || cat.isEmpty || !isIsoDate(p.date)) return const [];
  final taken = {
    for (final q in all)
      if (q.id != p.id && q.paidTx != null) q.paidTx
  };
  final out = [
    for (final t in txs)
      if (t.tx.live &&
          t.amount < 0 &&
          t.category == cat &&
          !taken.contains(t.tx.id) &&
          isIsoDate(t.date) &&
          daysBetween(p.date, t.date).abs() <= _paidWindowDays)
        t
  ];
  int dist(CategorizedTx t) => daysBetween(p.date, t.date).abs();
  int off(CategorizedTx t) => p.amount == null ? 0 : (-t.amount - p.amount!).abs();
  out.sort((a, b) {
    var c = dist(a).compareTo(dist(b));
    if (c == 0) c = off(a).compareTo(off(b));
    if (c == 0) c = a.date.compareTo(b.date);
    return c != 0 ? c : a.tx.id.compareTo(b.tx.id);
  });
  return out;
}

/// A heads-up before a big cost: the item and the days until it (0 = today).
class HeadsUp {
  final UpcomingItem item;
  final int daysLeft;
  const HeadsUp({required this.item, required this.daysLeft});
}

/// The planned costs with an amount and the confirmed bills of [items] whose amount is at least [thresholdCents],
/// dated from [today] to [today] + [days] (inclusive). Suggestions never. In the order of [items] (by date).
List<HeadsUp> headsUps(List<UpcomingItem> items, String today, {required int thresholdCents, required int days}) {
  if (!isIsoDate(today) || days < 0) return const [];
  final last = addDays(today, days);
  return [
    for (final i in items)
      if ((i.kind == UpcomingKind.planned || i.kind == UpcomingKind.bill) &&
          i.amount != null &&
          i.amount! >= thresholdCents &&
          i.date.compareTo(today) >= 0 &&
          i.date.compareTo(last) <= 0)
        HeadsUp(item: i, daysLeft: daysBetween(today, i.date)),
  ];
}
