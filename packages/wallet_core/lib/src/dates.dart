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

/// The expected next payday: `paydayDay` of the month after the period start.
String nextPayday(String periodStart, int paydayDay) {
  final d = parseIso(periodStart);
  final first = DateTime.utc(d.year, d.month + 1, 1);
  final last = DateTime.utc(first.year, first.month + 1, 0).day;
  return isoDate(DateTime.utc(first.year, first.month, paydayDay > last ? last : paydayDay));
}

/// The start of the pay period [today] falls in, from a saved [periodStart]: the latest expected payday on or before
/// [today] ([periodStart] itself when no payday has passed since). Several missed paydays move on in one step.
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
