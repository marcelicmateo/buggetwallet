import 'package:wallet_core/wallet_core.dart' show FxRate, addDays, displayDigitsOf, parseMoneyCents, storageDigitsOf;

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
      'JPY' => '¥',
      'BTC' => '₿',
      _ => code,
    };

/// The wallet's currency, set by the controller (like [numberStyle]) whenever it notifies. The formatters below use it when
/// they are not given a currency, so fields in the wallet currency need no extra argument.
String walletCurrencyCode = 'EUR';

/// Stored units per whole unit of [currency] (`storageDigitsOf`): 100 for every fiat currency, 10^8 for BTC.
int storageScale([String? currency]) => _pow10(storageDigitsOf(currency ?? walletCurrencyCode));

/// Decimals shown and typed for [currency] (`displayDigitsOf`: JPY 0, EUR 2, BTC 8), never more than it is stored with.
int _shownDigits(String currency) {
  final d = displayDigitsOf(currency), st = storageDigitsOf(currency);
  return d > st ? st : d;
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// A stored amount as a number of whole units, for a chart axis (wallet currency unless [currency] is given).
double chartUnits(num stored, [String? currency]) => stored / storageScale(currency);

/// A whole number with thousands grouping in the current style ("1,500" / "1.500").
String groupInt(int n) => _group(n);

String _group(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(numberStyle.group);
    b.write(s[i]);
  }
  return b.toString();
}

/// Money from stored units, symbol after the amount with a no-break space: "14 €", "−23.40 €", "1,500 ¥", "0.015 ₿".
/// Fiat: whole units at 100+ unless [decimals] is given; a currency without decimals (JPY) shows none unless [decimals]
/// asks. A coin (BTC) shows its digits without trailing zeros (two at least) unless [decimals] is given.
String money(int cents, String currency, {int? decimals, bool signed = false}) {
  final neg = cents < 0;
  final abs = cents.abs();
  final storage = storageDigitsOf(currency), scale = _pow10(storage);
  final String body;
  final bool isZero;
  if (storage > 2) {
    // A coin is never rounded: its fraction without trailing zeros, but at least [decimals] digits (two when not given).
    var f = (abs % scale).toString().padLeft(storage, '0');
    final least = decimals ?? 2;
    while (f.length > least && f.endsWith('0')) {
      f = f.substring(0, f.length - 1);
    }
    body = '${_group(abs ~/ scale)}${f.isEmpty ? '' : numberStyle.decimal}$f';
    isZero = abs == 0;
  } else {
    var d = decimals ?? (_shownDigits(currency) == 0 || abs >= 100 * scale ? 0 : 2);
    // A currency without decimals (JPY) shows none for a whole amount, whatever the caller asks for.
    if (decimals != null && _shownDigits(currency) == 0 && abs % scale == 0) d = 0;
    if (d == 0) {
      final whole = (abs / scale).round();
      body = _group(whole);
      // A negative amount that rounds to zero is shown as zero, not "−0 €".
      isZero = whole == 0;
    } else {
      body = '${_group(abs ~/ scale)}${numberStyle.decimal}${(abs % scale).toString().padLeft(storage, '0')}';
      isZero = abs == 0;
    }
  }
  final sign = neg && !isZero ? '−' : (signed && cents > 0 ? '+' : '');
  return '$sign$body ${currencySymbol(currency)}';
}

/// The decimals [moneyExact] needs: none for a whole amount, else cents (a coin: its own digits, trimmed).
int? _exactDecimals(int cents, String currency) {
  if (cents % storageScale(currency) == 0) return 0;
  return storageDigitsOf(currency) > 2 ? null : 2;
}

/// [money] that never rounds: whole units when the amount is whole ("48 €"), otherwise with cents ("47.50 €", "0.49 €").
String moneyExact(int cents, String currency) => money(cents, currency, decimals: _exactDecimals(cents, currency));

/// [moneyExact] with a plus sign on a positive amount ("+1,234.56 €", "−40 €").
String moneyExactSigned(int cents, String currency) => money(cents, currency, decimals: _exactDecimals(cents, currency), signed: true);

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

/// The hint of an empty money field in the wallet currency: "0.00" or "0,00".
String get amountHint => amountHintFor(walletCurrencyCode);

/// The hint of an empty money field in [currency]: "0.00", "0" (JPY), "0.00000000" (BTC).
String amountHintFor(String currency) {
  final d = _shownDigits(currency);
  return d == 0 ? '0' : '0${numberStyle.decimal}${'0' * d}';
}

/// Whole units of [cents] with thousands grouping and no symbol ("1,500" / "1.500"), for a range like "40–1,500 €".
String unitsText(int cents, [String? currency]) => _group(cents ~/ storageScale(currency));

/// A stored amount as the text of a money field: `1500` -> "15", `1550` -> "15.50", or "15,50" in the comma style (parseMoney
/// reads both back); a coin shows its digits without trailing zeros ("0.015"). With [blankZero] a zero is empty, so the field
/// shows its hint. [currency]: the amount's currency (the wallet's when omitted).
String centsToFieldText(int cents, {bool blankZero = false, String? currency}) {
  if (blankZero && cents == 0) return '';
  final cur = currency ?? walletCurrencyCode;
  final storage = storageDigitsOf(cur), scale = _pow10(storage);
  final a = cents.abs(), sign = cents < 0 ? '-' : '';
  if (a % scale == 0) return '$sign${a ~/ scale}';
  var f = (a % scale).toString().padLeft(storage, '0');
  if (storage > 2) {
    while (f.endsWith('0')) {
      f = f.substring(0, f.length - 1);
    }
  }
  return '$sign${a ~/ scale}${numberStyle.decimal}$f';
}

/// Parses "12", "12.5", "12,50", "1.234,56" into stored units (cents; satoshis for BTC): core's [parseMoneyCents] with the
/// decimals [currency] is typed with (the wallet's when omitted; JPY refuses "10.5"). Null if not a number, negative, in
/// exponent form, or beyond the maximum. With two decimals, two rules for a separator followed by three or more digits, so an
/// amount is never silently misread: it must be a proper thousands group, else the text is refused (no rounding of a third
/// decimal). In the comma style "1.500" is 1500 (the dot groups thousands) and "1,234" is refused; in the point style
/// "1,234" is 1234 and "1.234" is refused. Full forms such as "1.234,56" and "1,234.56" read the same in both styles.
int? parseMoney(String input, {String? currency}) {
  final digits = _shownDigits(currency ?? walletCurrencyCode);
  final cleaned = input.trim().replaceAll(RegExp(r'[\s€\$£¥₿]'), '');
  final sign = cleaned.startsWith('+') || cleaned.startsWith('-') ? cleaned[0] : '';
  final body = sign.isEmpty ? cleaned : cleaned.substring(1);
  if (digits > 2) return parseMoneyCents(cleaned, digits: digits); // a coin: core reads the separators
  if (!RegExp(r'[.,]\d{3,}').hasMatch(body)) return parseMoneyCents(cleaned, digits: digits);
  final us = RegExp(r'^\d{1,3}(,\d{3})+(\.\d{1,2})?$'); // 1,234 / 1,234.56
  final eu = RegExp(r'^\d{1,3}(\.\d{3})+(,\d{1,2})?$'); // 1.234 / 1.234,56
  final comma = numberStyle == NumberStyle.comma;
  if (us.hasMatch(body)) {
    if (comma && !body.contains('.')) return null; // "1,234" in the comma style is a third decimal
    return parseMoneyCents('$sign$body', digits: digits);
  }
  if (eu.hasMatch(body)) {
    if (!comma && !body.contains(',')) return null; // "1.234" in the point style is a third decimal
    return parseMoneyCents('$sign${body.replaceAll('.', '')}', digits: digits);
  }
  return null;
}

/// An exchange rate (home minor units per 1,000,000 foreign minor units) as text: "0.9240" or "0,9240" in the comma style. At least
/// four decimals, up to six, trailing zeros beyond the fourth dropped.
String rateText(int rate) {
  var frac = (rate % 1000000).toString().padLeft(6, '0');
  while (frac.length > 4 && frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  return '${_group(rate ~/ 1000000)}${numberStyle.decimal}$frac';
}

/// Parses a typed rate into the integer rate `round(value × 1,000,000)`, exactly from the digits (no floating point). The separators
/// are read by [numberStyle] like [parseMoney] does: the style's decimal mark starts the decimals (up to six, nothing is rounded
/// away) and its group mark is allowed only in proper groups of three ("62,000" is 62000 in the point style and 62 in the comma
/// style; "1.234,5678" is 1234.5678 in the comma style). The other mark is read as a decimal only when it stands alone and 1, 2 or 4 to 6 digits follow it
/// ("0,92"); a group that starts with 0 ("0,924"), a misplaced group or any other shape is refused (null), never guessed. Also null
/// when above [FxRate.maxRateOf] [code] (a currency's rate up to 1,000,000, a coin's up to 1,000,000,000). With [code] omitted the
/// range is core's to check.
int? parseFxRate(String input, {String? code}) {
  final t = input.trim().replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty) return null;
  final g = RegExp.escape(numberStyle.group), d = RegExp.escape(numberStyle.decimal);
  String whole, frac;
  final own = RegExp('^(\\d{1,3}(?:$g\\d{3})+|\\d*)(?:$d(\\d{1,6}))?\$').firstMatch(t);
  if (own != null && (own.group(1)!.isNotEmpty || own.group(2) != null)) {
    final w = own.group(1)!;
    if (w.contains(numberStyle.group) && w.startsWith('0')) return null; // "0,924": a group cannot follow a zero
    whole = w.replaceAll(numberStyle.group, '');
    frac = own.group(2) ?? '';
  } else {
    // The other mark as a decimal ("0,92", "0,9240" in the point style); exactly 3 digits after it could be a group: refused.
    final other = RegExp('^(\\d+)$g(\\d{1,6})\$').firstMatch(t);
    if (other == null || other.group(2)!.length == 3) return null;
    whole = other.group(1)!;
    frac = other.group(2)!;
  }
  if (whole.isEmpty) whole = '0';
  if (whole.length > 10) return null;
  final rate = int.parse(whole) * 1000000 + int.parse(frac.padRight(6, '0'));
  if (code != null && rate > FxRate.maxRateOf(code)) return null;
  return rate;
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

/// An amount as a bank app wants it typed: comma decimals, no grouping, no symbol ("12,50"), whatever the look setting says.
String bankAmountText(int cents) {
  final a = cents.abs();
  return '${cents < 0 ? '-' : ''}${a ~/ 100},${(a % 100).toString().padLeft(2, '0')}';
}

/// An IBAN without spaces, upper case.
String plainIban(String iban) => iban.replaceAll(RegExp(r'\s'), '').toUpperCase();

/// An IBAN in groups of four for reading; copy it with [plainIban].
String groupedIban(String iban) {
  final p = plainIban(iban);
  return [for (var i = 0; i < p.length; i += 4) p.substring(i, i + 4 > p.length ? p.length : i + 4)].join(' ');
}
