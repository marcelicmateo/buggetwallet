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

/// `yymmdd` + hash of date|amount|description, plus `_n` for the n-th identical row in one file.
String transactionId(String date, int amountMinor, String description, int occurrence) {
  final key = '$date|${formatCents(amountMinor)}|$description';
  final base = date.replaceAll('-', '').substring(2) + fnv1a36(key);
  return occurrence == 0 ? base : '${base}_$occurrence';
}
