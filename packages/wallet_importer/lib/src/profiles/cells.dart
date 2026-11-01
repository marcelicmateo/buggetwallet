// Cell helpers shared by the bank profiles: text, dates, numbers and cents the way v1 read them. Every profile
// goes through these so that two banks' rows with the same values give the same amounts and ids.
import 'dart:convert';

import 'package:logging/logging.dart';

import '../currencies.dart';
import '../log.dart';

final _log = Logger('bw.importer');

/// A cell as trimmed text: numbers without a trailing `.0`, `null` as the empty string.
String cellText(Object? v) => v == null ? '' : (v is double ? _num(v) : v.toString()).trim();
String _num(double v) => v.isFinite && v == v.roundToDouble() ? v.toInt().toString() : v.toString();
String _pad(int n) => n.toString().padLeft(2, '0');

/// Excel serial day number to `YYYY-MM-DD` (UTC, 1900 date system).
String excelDate(double serial) {
  final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: (serial * 86400000).round()));
  return '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
}

/// What [cellDate] and [serialDate] return for a cell shaped like a date that is not a real calendar day.
const impossibleDate = '';

/// Largest Excel serial day accepted (9999-12-31).
const _maxSerial = 2958465.0;

/// A real `YYYY-MM-DD` from the parts, or [impossibleDate] (2026-13-45, 31.02.2026, year 0000).
String _ymd(String y, String m, String d) {
  final yi = int.parse(y), mi = int.parse(m), di = int.parse(d);
  final t = DateTime.utc(yi, mi, di);
  if (yi < 1 || t.year != yi || t.month != mi || t.day != di) return impossibleDate;
  return '$y-${m.padLeft(2, '0')}-${d.padLeft(2, '0')}';
}

/// Excel serial day to a date, or [impossibleDate] outside 1900-01-01 .. 9999-12-31 (or not finite).
String serialDate(double v) => v.isFinite && v >= 1 && v <= _maxSerial ? excelDate(v) : impossibleDate;

/// The date in a cell: `null` when the cell is not a date at all (header, footer, empty), [impossibleDate] when it
/// looks like one but is not a real calendar day, else `YYYY-MM-DD`. Accepts Excel serials, `YYYY-MM-DD…` and
/// `d.m.yyyy…`.
String? cellDate(Object v) {
  if (v is double) return serialDate(v);
  final s = v.toString().trim();
  var m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (m != null) return _ymd(m[1]!, m[2]!, m[3]!);
  m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(s);
  if (m != null) return _ymd(m[3]!, m[2]!, m[1]!);
  return null;
}

/// The number in a cell, or `null` when it is not one. Text with a comma decimal (`-1.234,56`) and thousands
/// separators (`1,234.5`) is understood; whitespace is ignored.
double? cellNumber(Object v) {
  if (v is double) return v;
  var s = v.toString().trim().replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return null;
  if (RegExp(r',\d{1,2}$').hasMatch(s)) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else {
    s = s.replaceAll(',', '');
  }
  return double.tryParse(s);
}

/// Largest amount accepted, in cents (10 billion in the account currency). Anything bigger is a damaged cell, and
/// rounding it would saturate at the int64 limit, after which sums overflow.
const maxAmountCents = 1000000000000;

/// Amount in cents, or null when it is not a usable number: NaN, Infinity, beyond double range ("1e400"), or
/// larger than [maxAmountCents].
int? cellCents(double x) {
  final c = x * 100;
  if (!c.isFinite || c.abs() > maxAmountCents) return null;
  return jsRound(c);
}

/// Amount in stored minor units of a currency with [digits] storage digits (`storageDigitsOf`: 2 for every fiat
/// currency, BTC 8). 2 is [cellCents] (v1's rounding, unchanged) unless [strict]: then, as for any other count, a cell
/// with a finer fraction (`1.235` dinar, `0.000000001` BTC) is refused (null), never rounded. Profiles pass [strict] for
/// a currency with more ISO digits than it is stored with (KWD, BHD, …: the third decimal is not supported). Null also
/// for what [cellCents] refuses, and beyond [maxAmountCents] minor units.
int? cellMinor(double x, int digits, {bool strict = false}) {
  if (digits == 2 && !strict) return cellCents(x);
  final c = x * pow10(digits);
  if (!c.isFinite || c.abs() > maxAmountCents) return null;
  final r = c.roundToDouble();
  // Doubles carry ~16 significant digits: only a difference above that noise is a real finer fraction.
  if ((c - r).abs() > (r.abs() * 1e-12 > 1e-6 ? r.abs() * 1e-12 : 1e-6)) return null;
  return r.toInt();
}

/// JavaScript's `Math.round`, which v1 used (`r2(x) = Math.round(x * 100) / 100`): nearest integer, exact halves
/// towards +infinity (-12.5 → -12). Dart's `round()` takes halves away from zero (-12.5 → -13), which gave a
/// different amount and id than v1 for negative exact half cents. `c - floor(c)` is exact for these magnitudes.
int jsRound(double c) {
  final f = c.floorToDouble();
  return (c - f >= 0.5 ? f + 1 : f).toInt();
}

/// Repairs text that was UTF-8 but got decoded as Latin-1 (e.g. "GraÅ¡o" -> "Grašo").
String fixMojibake(String s) {
  final units = s.codeUnits;
  if (units.every((c) => c < 0x80) || units.any((c) => c > 0xFF)) return s;
  try {
    return utf8.decode(units);
  } on FormatException catch (e) {
    // Expected for real Latin-1 text; per row, so FINEST and no text.
    logImporter(_log, Level.FINEST, 'importer.mojibake.keep', {'offset': e.offset});
    return s;
  }
}
