String _p(int n) => n.toString().padLeft(2, '0');

/// `YYYY-MM-DD` for a local date.
String isoDate(DateTime d) => '${d.year}-${_p(d.month)}-${_p(d.day)}';

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

/// `YYYY-MM` of an ISO date.
String monthOf(String iso) => iso.substring(0, 7);

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
