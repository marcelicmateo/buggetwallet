// Date ranges for the graphs (stage N3, docs/context/N3_SPEC.md §1): pay periods, calendar months, custom spans.
import 'dates.dart';
import 'models.dart';
import 'periods.dart' show detectPaydays;

/// What a graph's range control offers.
enum RangeKind { payPeriod, month, months3, months6, months12, custom }

/// An inclusive span of days, `YYYY-MM-DD` at both ends.
class DateRange {
  final String start;
  final String end;

  /// Throws [ArgumentError] unless both are real `YYYY-MM-DD` dates and `start <= end`.
  DateRange({required this.start, required this.end}) {
    requireIsoDate(start);
    requireIsoDate(end);
    if (start.compareTo(end) > 0) throw ArgumentError('The range starts after it ends.');
  }

  /// Number of days, both ends counted (1 for a single day).
  int get days => daysBetween(start, end) + 1;

  bool contains(String date) => date.compareTo(start) >= 0 && date.compareTo(end) <= 0;

  @override
  bool operator ==(Object other) => other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DateRange($start..$end)';
}

/// How many calendar months a month kind spans; null for pay periods and custom ranges.
int? _monthCount(RangeKind kind) => switch (kind) {
      RangeKind.month => 1,
      RangeKind.months3 => 3,
      RangeKind.months6 => 6,
      RangeKind.months12 => 12,
      RangeKind.payPeriod || RangeKind.custom => null,
    };

/// The longest custom range, in years: a range must end before `from` + this many years.
const _maxCustomYears = 5;

/// The range of [kind] around [today] (see N3_SPEC.md §1 and its clarifications).
/// - [RangeKind.payPeriod]: from the latest of `detectPaydays(txs, st, today)` (no paydays at all: the latest
///   expected `paydayDay` on or before today) to the day before the next expected payday, but never before today
///   (a late salary keeps the running period open).
/// - Month kinds: the N calendar months ending with today's month, whole months (the last one ends after today).
/// - [RangeKind.custom]: [from]..[to], both required; refused ([ArgumentError]) when not dates, `from > to`, ending
///   after today's month or spanning 5 years or more.
DateRange rangeFor(RangeKind kind, String today, WalletSettings st, {List<CategorizedTx> txs = const [], String? from, String? to}) {
  requireIsoDate(today);
  final ym = monthOf(today);
  if (_monthCount(kind) case final n?) return _months(ym, n);
  if (kind == RangeKind.payPeriod) {
    final days = _paydays(txs, st, today);
    return _periodAt(days, days.length - 1, days.length - 1, st.paydayDay, today);
  }
  if (from == null || to == null) throw ArgumentError('A custom range needs both dates.');
  requireIsoDate(from);
  requireIsoDate(to);
  if (from.compareTo(to) > 0) throw ArgumentError('The range starts after it ends.');
  if (to.compareTo(_monthEnd(ym)) > 0) throw ArgumentError('The range ends after this month.');
  if (to.compareTo(_addYears(from, _maxCustomYears)) >= 0) throw ArgumentError('The range is longer than 5 years.');
  return DateRange(start: from, end: to);
}

/// [r] moved by [steps] ranges of [kind] (negative = back). Pay periods walk the real payday list (extended with
/// expected paydays beyond its ends), month kinds move by whole groups of their month count, custom ranges by their
/// own length in days. A result starting after [today]'s month is refused ([ArgumentError]).
DateRange shiftRange(DateRange r, RangeKind kind, int steps, WalletSettings st,
    {List<CategorizedTx> txs = const [], required String today}) {
  requireIsoDate(today);
  final DateRange out;
  if (_monthCount(kind) case final n?) {
    final first = _shiftMonth(monthOf(r.start), n * steps);
    out = _months(_shiftMonth(first, n - 1), n);
  } else if (kind == RangeKind.custom) {
    final by = steps * r.days;
    out = DateRange(start: addDays(r.start, by), end: addDays(r.end, by));
  } else {
    out = _shiftPeriod(r, steps, st, txs, today);
  }
  if (monthOf(out.start).compareTo(monthOf(today)) > 0) throw ArgumentError('The range would start after this month.');
  return out;
}

DateRange _shiftPeriod(DateRange r, int steps, WalletSettings st, List<CategorizedTx> txs, String today) {
  final pd = st.paydayDay;
  final days = [..._paydays(txs, st, today)];
  var running = days.length - 1;
  while (days.first.compareTo(r.start) > 0) {
    days.insert(0, _prevPayday(days.first, pd));
    running++;
  }
  var target = days.lastIndexWhere((d) => d.compareTo(r.start) <= 0) + steps;
  while (target < 0) {
    days.insert(0, _prevPayday(days.first, pd));
    running++;
    target++;
  }
  while (target >= days.length) {
    // Expected paydays on or before today have not come (the running period stays open), so the next is after today.
    var next = nextPayday(days.last, pd);
    while (next.compareTo(today) <= 0) {
      next = nextPayday(next, pd);
    }
    days.add(next);
  }
  return _periodAt(days, target, running, pd, today);
}

/// The pay period starting at `days[i]`; the [running] one never ends before [today].
DateRange _periodAt(List<String> days, int i, int running, int paydayDay, String today) {
  final start = days[i];
  var end = addDays(i + 1 < days.length ? days[i + 1] : nextPayday(start, paydayDay), -1);
  if (i == running && end.compareTo(today) < 0) end = today;
  return DateRange(start: start, end: end);
}

/// Paydays as `detectPaydays` finds them; never empty (no paydays: the latest expected one on or before [today]).
List<String> _paydays(List<CategorizedTx> txs, WalletSettings st, String today) {
  final days = detectPaydays(txs, st, today);
  if (days.isNotEmpty) return days;
  final here = _paydayIn(monthOf(today), st.paydayDay);
  return [here.compareTo(today) <= 0 ? here : _paydayIn(_shiftMonth(monthOf(today), -1), st.paydayDay)];
}

/// The expected payday in the month before [date]'s month.
String _prevPayday(String date, int paydayDay) => _paydayIn(_shiftMonth(monthOf(date), -1), paydayDay);

/// [paydayDay] of month [ym], clamped to its last day (like `nextPayday`).
String _paydayIn(String ym, int paydayDay) {
  final last = daysInMonth(ym);
  return '$ym-${_p(paydayDay > last ? last : paydayDay)}';
}

/// The [n] whole calendar months ending with [ym].
DateRange _months(String ym, int n) => DateRange(start: '${_shiftMonth(ym, 1 - n)}-01', end: _monthEnd(ym));

/// Last day of month [ym] (`YYYY-MM-DD`).
String _monthEnd(String ym) => '$ym-${_p(daysInMonth(ym))}';

/// `YYYY-MM` [n] months after [ym] (negative = before).
String _shiftMonth(String ym, int n) {
  final d = DateTime.utc(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)) + n);
  return '${d.year.toString().padLeft(4, '0')}-${_p(d.month)}';
}

/// The same day [n] years later (29 Feb → 1 Mar).
String _addYears(String iso, int n) {
  final d = parseIso(iso);
  return isoDate(DateTime.utc(d.year + n, d.month, d.day));
}

String _p(int n) => n.toString().padLeft(2, '0');

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A short neutral label (dates only, for tests and logs): `14 Oct 2026`, `1–31 Oct 2026`, `Aug–Oct 2026`,
/// `14 Oct – 13 Nov 2026`; across years `Nov 2025 – Jan 2026`, `14 Dec 2025 – 13 Jan 2026`.
String rangeLabel(DateRange r) {
  final s = parseIso(r.start), e = parseIso(r.end);
  String mon(DateTime d) => _monthNames[d.month - 1];
  if (r.start == r.end) return '${s.day} ${mon(s)} ${s.year}';
  if (s.year == e.year && s.month == e.month) return '${s.day}–${e.day} ${mon(s)} ${s.year}';
  final wholeMonths = s.day == 1 && r.end == _monthEnd(monthOf(r.end));
  if (wholeMonths) return s.year == e.year ? '${mon(s)}–${mon(e)} ${e.year}' : '${mon(s)} ${s.year} – ${mon(e)} ${e.year}';
  return s.year == e.year
      ? '${s.day} ${mon(s)} – ${e.day} ${mon(e)} ${e.year}'
      : '${s.day} ${mon(s)} ${s.year} – ${e.day} ${mon(e)} ${e.year}';
}
