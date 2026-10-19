import 'package:wallet_core/wallet_core.dart' show addDays;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December'
];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String currencySymbol(String code) => switch (code) {
      'EUR' => '€',
      'USD' => r'$',
      'GBP' => '£',
      _ => '$code ',
    };

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Money from minor units. Whole units at 100+ unless [decimals] is given.
String money(int cents, String currency, {int? decimals, bool signed = false}) {
  final neg = cents < 0;
  final abs = cents.abs();
  final d = decimals ?? (abs >= 10000 ? 0 : 2);
  String body;
  if (d == 0) {
    body = _group((abs / 100).round());
  } else {
    body = '${_group(abs ~/ 100)}.${(abs % 100).toString().padLeft(2, '0')}';
  }
  // A negative amount that rounds to zero is shown as zero, not "−€0".
  final isZero = d == 0 ? (abs / 100).round() == 0 : abs == 0;
  final sign = neg && !isZero ? '−' : (signed && cents > 0 ? '+' : '');
  return '$sign${currencySymbol(currency)}$body';
}

/// Wishlist countdown: whole hours rounded up (so "0h" never shows while time is left), then days.
/// 71.9 -> "3d left", 47.2 -> "2d left", 46.5 -> "1d 23h left", 5.1 -> "6h left". Hours are always 1-23.
String timeLeft(double hours) {
  if (hours.isNaN || hours <= 0) return 'Ready';
  final total = hours.isInfinite ? 1 << 30 : (hours - 1e-9).ceil().clamp(1, 1 << 30);
  final d = total ~/ 24, h = total % 24;
  if (d == 0) return '${h}h left';
  return h == 0 ? '${d}d left' : '${d}d ${h}h left';
}

/// Largest amount the app accepts: 10 billion in major units, in cents (same cap as the importer).
const maxAmountCents = 1000000000000;

final _plainNumber = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$');

/// Parses "12", "12.5", "12,50", "1.234,56" into cents. Null if not a number, negative,
/// in exponent form, or beyond [maxAmountCents].
int? parseMoney(String input) {
  var s = input.trim().replaceAll(RegExp(r'[\s€$£]'), '');
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

List<int> _ymd(String iso) => iso.split('-').map(int.parse).toList();

String shortDate(String iso) {
  final p = _ymd(iso);
  return '${p[2]} ${_months[p[1] - 1]}';
}

/// [longDate] for a calendar date, otherwise [iso] as stored, so a bad date synced from elsewhere can't break a sheet.
String longDateOrRaw(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  if (m == null) return iso;
  final (y, mo, d) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  final date = DateTime.utc(y, mo, d);
  return date.month == mo && date.day == d ? longDate(iso) : iso;
}

String longDate(String iso) {
  final p = _ymd(iso);
  final date = DateTime.utc(p[0], p[1], p[2]);
  if (date.month != p[1] || date.day != p[2]) throw FormatException('Not a calendar date', iso);
  final wd = date.weekday;
  return '${_weekdays[wd - 1]}, ${p[2]} ${_monthsLong[p[1] - 1]} ${p[0]}';
}

String monthShort(String ym) => _months[int.parse(ym.substring(5, 7)) - 1];
String monthLong(String ym) => '${_monthsLong[int.parse(ym.substring(5, 7)) - 1]} ${ym.substring(0, 4)}';
String monthYear(int year, int month) => '${_monthsLong[month - 1]} $year';

/// A share as a whole percent ("14%", "−5%"), or "—" when there is none.
String percent(double? share) {
  if (share == null || !share.isFinite) return '—';
  final v = (share * 100).round();
  return v < 0 ? '−${-v}%' : '$v%';
}

/// "12 Oct – 11 Nov" for a period with an exclusive end date.
String dateRange(String start, String endExclusive) => '${shortDate(start)} – ${shortDate(addDays(endExclusive, -1))}';
