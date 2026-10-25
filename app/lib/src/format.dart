import 'package:wallet_core/wallet_core.dart' show addDays, maxAmountCents, parseMoneyCents;

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

/// How amounts are written: `point` = 1,234.50 (default), `comma` = 1.234,50. Device-local (Plan › Look); the controller sets
/// [numberStyle] from the stored choice whenever it loads or changes, and the formatters below read it.
enum NumberStyle {
  point(',', '.'),
  comma('.', ',');

  /// Between thousands.
  final String group;

  /// Between units and cents.
  final String decimal;
  const NumberStyle(this.group, this.decimal);

  /// The stored name (`point` or `comma`); anything else reads as the default.
  static NumberStyle fromName(String? name) => name == 'comma' ? comma : point;
}

/// The style every formatter in this file uses. Set by the controller; tests that change it reset it afterwards.
NumberStyle numberStyle = NumberStyle.point;

/// Symbol (or the code itself when there is no symbol). Always written after the amount.
String currencySymbol(String code) => switch (code) {
      'EUR' => '€',
      'USD' => r'$',
      'GBP' => '£',
      'CHF' => 'CHF',
      _ => code,
    };

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(numberStyle.group);
    b.write(s[i]);
  }
  return b.toString();
}

/// Money from minor units, symbol after the amount with a no-break space: "14 €", "−23.40 €".
/// Whole units at 100+ unless [decimals] is given.
String money(int cents, String currency, {int? decimals, bool signed = false}) {
  final neg = cents < 0;
  final abs = cents.abs();
  final d = decimals ?? (abs >= 10000 ? 0 : 2);
  String body;
  if (d == 0) {
    body = _group((abs / 100).round());
  } else {
    body = '${_group(abs ~/ 100)}${numberStyle.decimal}${(abs % 100).toString().padLeft(2, '0')}';
  }
  // A negative amount that rounds to zero is shown as zero, not "−0 €".
  final isZero = d == 0 ? (abs / 100).round() == 0 : abs == 0;
  final sign = neg && !isZero ? '−' : (signed && cents > 0 ? '+' : '');
  return '$sign$body\u00A0${currencySymbol(currency)}';
}

/// [money] that never rounds: whole units when the amount is whole ("48 €"), otherwise with cents ("47.50 €", "0.49 €").
String moneyExact(int cents, String currency) => money(cents, currency, decimals: cents % 100 == 0 ? 0 : 2);

/// [moneyExact] with a plus sign on a positive amount ("+1,234.56 €", "−40 €").
String moneyExactSigned(int cents, String currency) => money(cents, currency, decimals: cents % 100 == 0 ? 0 : 2, signed: true);

/// Wishlist countdown: whole hours rounded up (so "0h" never shows while time is left), then days.
/// 71.9 -> "3d left", 47.2 -> "2d left", 46.5 -> "1d 23h left", 5.1 -> "6h left". Hours are always 1-23.
String timeLeft(double hours) {
  if (hours.isNaN || hours <= 0) return 'Ready';
  final total = hours.isInfinite ? 1 << 30 : (hours - 1e-9).ceil().clamp(1, 1 << 30);
  final d = total ~/ 24, h = total % 24;
  if (d == 0) return '${h}h left';
  return h == 0 ? '${d}d left' : '${d}d ${h}h left';
}

/// The one sentence for an amount that does not parse (sheets, planned costs, budgets, Plan).
String get invalidAmountMessage => 'Enter an amount, like ${amountExample()}.';

/// "12.50" or "12,50": an example amount in the current style, for messages.
String amountExample() => '12${numberStyle.decimal}50';

/// The hint of an empty money field: "0.00" or "0,00".
String get amountHint => '0${numberStyle.decimal}00';

/// Whole units of [cents] with thousands grouping and no symbol ("1,500" / "1.500"), for a range like "40–1,500 €".
String unitsText(int cents) => _group(cents ~/ 100);

/// A cents amount as the text of a money field: `1500` -> "15", `1550` -> "15.50", or "15,50" in the comma style (parseMoney
/// reads both back). With [blankZero] a
/// zero is empty, so the field shows its hint.
String centsToFieldText(int cents, {bool blankZero = false}) {
  if (blankZero && cents == 0) return '';
  final a = cents.abs(), sign = cents < 0 ? '-' : '';
  if (a % 100 == 0) return '$sign${a ~/ 100}';
  return '$sign${a ~/ 100}${numberStyle.decimal}${(a % 100).toString().padLeft(2, '0')}';
}

/// Parses "12", "12.5", "12,50", "1.234,56" into cents: core's [parseMoneyCents] (null if not a number, negative,
/// in exponent form, or beyond [maxAmountCents]), with two rules for a separator followed by three or more digits, so an
/// amount is never silently misread: it must be a proper thousands group, else the text is refused (no rounding of a third
/// decimal). In the comma style "1.500" is 1500 (the dot groups thousands) and "1,234" is refused; in the point style
/// "1,234" is 1234 and "1.234" is refused. Full forms such as "1.234,56" and "1,234.56" read the same in both styles.
int? parseMoney(String input) {
  final cleaned = input.trim().replaceAll(RegExp(r'[\s€\$£]'), '');
  final sign = cleaned.startsWith('+') || cleaned.startsWith('-') ? cleaned[0] : '';
  final body = sign.isEmpty ? cleaned : cleaned.substring(1);
  if (!RegExp(r'[.,]\d{3,}').hasMatch(body)) return parseMoneyCents(input);
  final us = RegExp(r'^\d{1,3}(,\d{3})+(\.\d{1,2})?$'); // 1,234 / 1,234.56
  final eu = RegExp(r'^\d{1,3}(\.\d{3})+(,\d{1,2})?$'); // 1.234 / 1.234,56
  final comma = numberStyle == NumberStyle.comma;
  if (us.hasMatch(body)) {
    if (comma && !body.contains('.')) return null; // "1,234" in the comma style is a third decimal
    return parseMoneyCents('$sign$body');
  }
  if (eu.hasMatch(body)) {
    if (!comma && !body.contains(',')) return null; // "1.234" in the point style is a third decimal
    return parseMoneyCents('$sign${body.replaceAll('.', '')}');
  }
  return null;
}

List<int> _ymd(String iso) => iso.split('-').map(int.parse).toList();

String shortDate(String iso) {
  final p = _ymd(iso);
  return '${p[2]} ${_months[p[1] - 1]}';
}

/// Whether [iso] is a real `YYYY-MM-DD` calendar date.
bool isCalendarDate(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  if (m == null) return false;
  final (y, mo, d) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  final date = DateTime.utc(y, mo, d);
  return date.month == mo && date.day == d;
}

/// [shortDate] / [longDate] for a calendar date, otherwise [iso] as stored, so a bad date synced from elsewhere
/// can't break a screen.
String shortDateOrRaw(String iso) => isCalendarDate(iso) ? shortDate(iso) : iso;
String longDateOrRaw(String iso) => isCalendarDate(iso) ? longDate(iso) : iso;

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
