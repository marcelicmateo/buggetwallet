import 'currencies.dart' show pow10;

/// FNV-1a over UTF-16 code units, base-36. Matches the v1 web app so ids carry over.
String fnv1a36(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

/// Cents as a fixed two-decimal string, like JavaScript's `toFixed(2)`.
String formatCents(int cents) {
  final neg = cents < 0;
  final abs = cents.abs();
  final s = '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  return neg ? '-$s' : s;
}

/// [minor] units of a currency with [digits] minor digits as the amount text of an id key: [formatCents] of the amount
/// in hundredths (what every build before Stage UX-A stored for it: 1000 yen → `1000.00`, 2.000 dinar → `2.00`); an
/// amount finer than a hundredth (which those builds refused) as its exact decimal without trailing zeros (`1.234`,
/// `0.00000001`).
String minorIdText(int minor, int digits) {
  if (digits <= 2) return formatCents(minor * pow10(2 - digits));
  final step = pow10(digits - 2);
  if (minor % step == 0) return formatCents(minor ~/ step);
  final a = minor.abs(), p = pow10(digits);
  final frac = (a % p).toString().padLeft(digits, '0').replaceFirst(RegExp(r'0+$'), '');
  return '${minor < 0 ? '-' : ''}${a ~/ p}.$frac';
}

/// `yymmdd` + hash of date|amount|description, plus `_n` for the n-th identical row in one file.
String transactionId(String date, int amountMinor, String description, int occurrence) {
  final key = '$date|${formatCents(amountMinor)}|$description';
  final base = date.replaceAll('-', '').substring(2) + fnv1a36(key);
  return occurrence == 0 ? base : '${base}_$occurrence';
}

/// The id for a row of a bank added after v1: like [transactionId], but [source] (the profile id) is hashed into
/// the key, so two banks' rows with the same date, amount and description never share an id. Not for PBZ and
/// Revolut: their ids must stay the v1 ones ([transactionId]) or re-imports would duplicate.
///
/// [digits] are the minor digits of the row's currency (Stage UX-A): the amount goes into the key as [minorIdText], the
/// same text the 2-digit amounts of earlier builds gave wherever those could read the row, so re-imports never duplicate.
String sourceTransactionId(String source, String date, int amountMinor, String description, int occurrence, {int digits = 2}) {
  final key = '$source|$date|${minorIdText(amountMinor, digits)}|$description';
  final base = date.replaceAll('-', '').substring(2) + fnv1a36(key);
  return occurrence == 0 ? base : '${base}_$occurrence';
}
