import 'package:wallet_core/wallet_core.dart' show addDays, isIsoDate, isoDate, parseIso;

/// The last year a date field takes (the date pickers stop there too).
const _lastYear = 2100;

/// The date [text] after [fromIso]: `<n>d|w|m|y` (`45d`, `2w`, `1m`, `5y`; case and spaces ignored). Months and years keep the
/// day, or the last day of a shorter month (31 Jan + 1m = 28 or 29 Feb; 29 Feb + 1y = 28 Feb). Whole days only.
/// Throws [FormatException] on text that is not a length, a length of 0, or a result past the year 2100.
String addLength(String fromIso, String text) {
  if (!isIsoDate(fromIso)) throw const FormatException('The start date is not YYYY-MM-DD.');
  final m = RegExp(r'^(\d{1,4})\s*([dwmy])$').firstMatch(text.trim().toLowerCase());
  if (m == null) throw const FormatException('Write a length like 45d, 2w, 1m or 5y.');
  final n = int.parse(m[1]!);
  if (n == 0) throw const FormatException('The length must be at least 1.');
  final String out;
  switch (m[2]!) {
    case 'd':
      out = addDays(fromIso, n);
    case 'w':
      out = addDays(fromIso, n * 7);
    default:
      final d = parseIso(fromIso);
      final months = m[2] == 'y' ? n * 12 : n;
      final total = d.year * 12 + (d.month - 1) + months;
      final (y, mo) = (total ~/ 12, total % 12 + 1);
      final last = DateTime.utc(y, mo + 1, 0).day;
      out = isoDate(DateTime.utc(y, mo, d.day > last ? last : d.day));
  }
  if (parseIso(out).year > _lastYear) throw const FormatException('That date is too far ahead.');
  return out;
}
