String _p(int n) => n.toString().padLeft(2, '0');

/// `YYYY-MM-DD` for a local date.
String isoDate(DateTime d) => '${d.year}-${_p(d.month)}-${_p(d.day)}';

/// Whether [s] is a real calendar date written `YYYY-MM-DD` (`2026-02-30` is not). The one check every date a
/// caller passes goes through ([requireIsoDate] for the writes that throw).
bool isIsoDate(String s) => _isoShape.hasMatch(s) && isoDate(parseIso(s)) == s;

final _isoShape = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Throws [ArgumentError] unless [isIsoDate].
void requireIsoDate(String s) {
  if (!isIsoDate(s)) throw ArgumentError('The date is not YYYY-MM-DD.');
}

DateTime parseIso(String iso) {
  final p = iso.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2]);
}

String addDays(String iso, int n) {
  final d = parseIso(iso);
  return isoDate(DateTime.utc(d.year, d.month, d.day + n));
}

int daysBetween(String a, String b) => parseIso(b).difference(parseIso(a)).inDays;

/// How many days from an expected payday (late or early) a period start still belongs to that payday's salary (RX7e
/// rule C; the same 7 days as `samePaydayDays`).
const paydayWindowDays = 7;

/// Salary parts this close to a payday's first payment belong to that payday (`periods.dart` grouping; the
/// received-income window is `samePaydayDays`), and a period start that belongs to no expected payday runs more than
/// this many days ([nextPayday]'s fallback, RX7f).
const salaryGroupDays = 20;

/// [paydayDay] of month `YYYY-MM` [ym], clamped to the month's last day (29..31 in a shorter month = its last day).
String paydayIn(String ym, int paydayDay) => _paydayAt(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)), paydayDay);

/// [paydayDay] of month [m] of [y] (any int month: 0 = December before, 13 = January after), clamped.
String _paydayAt(int y, int m, int paydayDay) {
  final first = DateTime.utc(y, m, 1);
  final last = DateTime.utc(first.year, first.month + 1, 0).day;
  return isoDate(DateTime.utc(first.year, first.month, paydayDay > last ? last : paydayDay));
}

/// The expected payday a period start [date] belongs to, or null (rule C, owner-approved 2026-10-30): the latest
/// expected payday in [date − 7, date] (a salary on time or up to 7 days late, also across a month or year end), else
/// the expected payday in (date, date + 7] (up to 7 days early). Expected paydays are at least 28 days apart, so there
/// is at most one of each and never both.
String? _salaryPayday(String date, int paydayDay) {
  final d = parseIso(date);
  final here = _paydayAt(d.year, d.month, paydayDay);
  if (here.compareTo(date) <= 0) {
    if (daysBetween(here, date) <= paydayWindowDays) return here;
    final next = _paydayAt(d.year, d.month + 1, paydayDay);
    return daysBetween(date, next) <= paydayWindowDays ? next : null;
  }
  final before = _paydayAt(d.year, d.month - 1, paydayDay);
  if (daysBetween(before, date) <= paydayWindowDays) return before;
  return daysBetween(date, here) <= paydayWindowDays ? here : null;
}

/// The expected next payday after a period starting on [periodStart] (rule C, RX7e; fallback RX7f, owner 2026-10-31):
/// a start within 7 days of an expected payday belongs to it (late: the payday in [start − 7, start]; else early: the
/// one in (start, start + 7]) and the period ends on the expected payday after it, so February's salary paid 2 Mar
/// (payday 31) ends on 31 Mar and January's paid 29 Jan (payday 3) on 3 Mar. Any other start (set by hand mid-period,
/// a first run, a salary more than 7 days early or late) ends on the first expected payday more than [salaryGroupDays]
/// (20) days after it: a salary paid 25 Sep with payday 3 runs to 3 Nov, not to 3 Oct (8 days that would hold the
/// whole salary, with "Start new period" on 3 Oct counting it again); 1 Oct and 7 Oct with payday 15 run to 15 Nov; a
/// start 26 Mar with payday 10 runs to 10 May (a start in the last 20 days before a payday runs to the one after,
/// owner-accepted). Every period is 21..51 days.
String nextPayday(String periodStart, int paydayDay) {
  final p = _salaryPayday(periodStart, paydayDay);
  final d = parseIso(p ?? periodStart);
  if (p != null) return _paydayAt(d.year, d.month + 1, paydayDay);
  for (var m = d.month;; m++) {
    final next = _paydayAt(d.year, m, paydayDay);
    if (daysBetween(periodStart, next) > salaryGroupDays) return next; // at most the payday two months on
  }
}

/// Where the period before one starting on [date] starts (rangeFor's steps back before the first known start): the
/// latest expected payday more than 7 days before [date], i.e. the expected payday before the one [date] belongs to
/// (rule C), or for a start that belongs to none, the latest expected payday before it.
String previousPayday(String date, int paydayDay) {
  final cut = addDays(date, -paydayWindowDays - 1);
  final c = parseIso(cut);
  final here = _paydayAt(c.year, c.month, paydayDay);
  return here.compareTo(cut) <= 0 ? here : _paydayAt(c.year, c.month - 1, paydayDay);
}

/// The start of the pay period [today] falls in, from a saved [periodStart]: [periodStart] itself until its
/// [nextPayday], then the latest expected payday on or before [today]. Several missed paydays move on in one step.
String currentPeriodStart(String periodStart, int paydayDay, String today) {
  var start = periodStart;
  for (var next = nextPayday(start, paydayDay); next.compareTo(today) <= 0; next = nextPayday(start, paydayDay)) {
    start = next;
  }
  return start;
}

/// `YYYY-MM` of an ISO date.
String monthOf(String iso) => iso.substring(0, 7);

/// Day of the month (1-31) of an ISO date.
int dayOf(String iso) => int.parse(iso.substring(8, 10));

/// Days in a `YYYY-MM` month (28-31).
int daysInMonth(String ym) => DateTime.utc(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)) + 1, 0).day;

/// The `n` months ending with `ym` (inclusive), oldest first.
List<String> monthsEnding(String ym, int n) {
  var y = int.parse(ym.substring(0, 4)), m = int.parse(ym.substring(5, 7));
  final out = <String>[];
  for (var k = 0; k < n; k++) {
    out.insert(0, '$y-${_p(m)}');
    m--;
    if (m == 0) {
      m = 12;
      y--;
    }
  }
  return out;
}
