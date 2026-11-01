/// UX-FX: the ECB euro reference rates per payment date (docs/context/UX_SPEC.md "UX-FX"). Pure and web-safe: the
/// synced entity `fx_day` ([FxDayCols]), the lookup [EcbRates] (the latest ECB day on or before a date, within
/// [ecbMaxGapDays]), exact conversion [ecbConvert], the parser of the ECB's history files [parseEcbRates] (zip, CSV or
/// XML, from bytes), and which (currency, date) pairs a wallet needs ([fxNeeds]). The download itself is the app's
/// (`WalletRepo.ecbFetchPlan` says which file); `WalletRepo.importEcbHistory` stores it.
library;

import 'dart:convert' show utf8;

import 'package:archive/archive.dart' show ArchiveException, ZipDecoder;

import 'cols.dart';
import 'currencies.dart' show currencyInfo;
import 'dates.dart';
import 'models.dart' show FxRate, WalletSettings;

/// The ECB's full history (every business day since 1999, one zipped CSV): the first download.
const ecbHistoryUrl = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.zip';

/// The ECB's last 90 days (XML): the refresh once the history is cached.
const ecbRecentUrl = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml';

/// The first day of the ECB's reference rates: no rate exists before it.
const ecbFirstDay = '1999-01-04';

/// Which ECB file to download (`WalletRepo.ecbFetchPlan`): the full [history] or the [recent] 90 days.
enum EcbFile {
  history(ecbHistoryUrl),
  recent(ecbRecentUrl);

  final String url;
  const EcbFile(this.url);
}

/// What `WalletRepo.importEcbHistory` read and wrote: [days] ECB days of [currencies] currencies from [oldest] to
/// [newest] into the device-local cache, and [written] `fx_day` rows for what the wallet needs.
class EcbImport {
  final int days;
  final int currencies;
  final String oldest;
  final String newest;
  final int written;
  const EcbImport({required this.days, required this.currencies, required this.oldest, required this.newest, required this.written});
}

/// The device-local ECB cache (`WalletRepo.ecbCacheInfo`): [days] ECB days from [oldest] to [newest] (null when
/// empty), the device date of the last good import ([importedOn]) and of the last download attempt ([attemptOn],
/// `WalletRepo.noteEcbAttempt`).
class EcbCacheInfo {
  final int days;
  final String? oldest;
  final String? newest;
  final String? importedOn;
  final String? attemptOn;
  const EcbCacheInfo({required this.days, this.oldest, this.newest, this.importedOn, this.attemptOn});
}

/// The latest ECB day used for a date is at most this many days before it (weekends, holidays); a longer gap is
/// "not counted".
const ecbMaxGapDays = 7;

/// `per_eur` scale: units of a currency per 1 EUR × 1,000,000 (the same scale as [FxRate.scale]).
const ecbScale = 1000000;

/// The columns of the synced entity `fx_day` (table `fx_days`; id `<CUR>:<YYYY-MM-DD>`, [fxDayId]): one ECB reference
/// rate the wallet needs. Same values from the ECB on every device, so two devices writing a row agree.
abstract final class FxDayCols {
  static const entity = 'fx_day';
  static const cur = TextCol(entity, 'cur', label: 'Currency');
  static const date = DateCol(entity, 'date', label: 'Date');
  static const perEur = IntCol(entity, 'per_eur', label: 'Units per euro', min: 1);
  static const source = TextCol(entity, 'source', label: 'Source', defaultValue: 'ecb');
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[cur, date, perEur, source, deleted];
}

/// The id of the `fx_day` row of [cur] on [date].
String fxDayId(String cur, String date) => '$cur:$date';

/// One ECB reference rate: [perEur] units of [cur] per 1 EUR × [ecbScale] on [date].
class FxDay {
  final String cur;
  final String date;
  final int perEur;
  const FxDay(this.cur, this.date, this.perEur);

  @override
  bool operator ==(Object other) => other is FxDay && other.cur == cur && other.date == date && other.perEur == perEur;

  @override
  int get hashCode => Object.hash(cur, date, perEur);

  @override
  String toString() => 'FxDay($cur $date $perEur)';
}

/// The ECB day and the two rates [EcbRates.pairOn] found for a conversion.
class EcbPair {
  /// The ECB date used (the latest one on or before the payment's date within [ecbMaxGapDays]).
  final String day;
  final int perFrom;
  final int perTo;
  const EcbPair(this.day, this.perFrom, this.perTo);
}

/// The last [ecbMaxGapDays] + 1 dates on or before a date, newest first (memo: the same dates repeat across rows).
final _back = <String, List<String>>{};
List<String> _daysBack(String date) {
  final have = _back[date];
  if (have != null) return have;
  if (_back.length > 4096) _back.clear();
  return _back[date] = [for (var k = 0; k <= ecbMaxGapDays; k++) addDays(date, -k)];
}

/// ECB reference rates by currency and date (the wallet's `fx_day` rows, `WalletRepo.ecbRates`; [WalletSettings.ecb]).
/// EUR is always 1 (× [ecbScale]). Immutable.
class EcbRates {
  final Map<String, Map<String, int>> _r;
  const EcbRates._(this._r);

  /// No rates (a wallet without `fx_day` rows).
  static const none = EcbRates._({});

  /// From [days]; a value that is not a real rate (≤ 0, a bad code or date) is left out.
  factory EcbRates(Iterable<FxDay> days) {
    final r = <String, Map<String, int>>{};
    for (final d in days) {
      if (d.perEur <= 0 || !WalletSettings.currencyCode.hasMatch(d.cur) || !isIsoDate(d.date)) continue;
      (r[d.cur] ??= {})[d.date] = d.perEur;
    }
    return r.isEmpty ? none : EcbRates._(r);
  }

  bool get isEmpty => _r.isEmpty;

  /// How many rates (currency, day) it holds.
  int get length => _r.values.fold(0, (n, m) => n + m.length);

  /// [cur]'s rate on exactly [date] (EUR: [ecbScale]), or null.
  int? perEurOn(String cur, String date) => cur == 'EUR' ? ecbScale : _r[cur]?[date];

  /// [cur]'s rate on the latest ECB day on or before [date] within [ecbMaxGapDays], or null (none, a bad date).
  FxDay? rateOn(String cur, String date) {
    if (!isIsoDate(date)) return null;
    for (final d in _daysBack(date)) {
      if (perEurOn(cur, d) case final p?) return FxDay(cur, d, p);
    }
    return null;
  }

  /// The latest ECB day on or before [date] within [ecbMaxGapDays] that has both [from] and [to] (one day for both:
  /// the ECB publishes all currencies at once), with their rates; null when there is none.
  EcbPair? pairOn(String from, String to, String date) {
    if (_r.isEmpty || !isIsoDate(date)) return null;
    if (from != 'EUR' && !_r.containsKey(from) || to != 'EUR' && !_r.containsKey(to)) return null;
    for (final d in _daysBack(date)) {
      final f = perEurOn(from, d), t = perEurOn(to, d);
      if (f != null && t != null) return EcbPair(d, f, t);
    }
    return null;
  }
}

/// [amount] stored units of a currency worth [perFrom] per EUR in stored units of one worth [perTo] per EUR (both
/// × [ecbScale], one ECB day): `amount × perTo × 10^toDigits / (perFrom × 10^fromDigits)`, exact (BigInt), rounded once
/// at the end, half away from zero. [fromDigits] / [toDigits]: storage digits (`storageDigitsOf`). Capped at 2^53 − 1
/// (exact on the web too; `homeAmount` refuses anything past `WalletSettings.maxAmount`).
int ecbConvert(int amount, {required int perFrom, required int perTo, int fromDigits = 2, int toDigits = 2}) {
  if (perFrom <= 0 || perTo <= 0) throw ArgumentError('A rate is more than zero.');
  final up = BigInt.from(10).pow(toDigits > fromDigits ? toDigits - fromDigits : 0);
  final down = BigInt.from(10).pow(fromDigits > toDigits ? fromDigits - toDigits : 0);
  final n = BigInt.from(amount.abs()) * BigInt.from(perTo) * up, d = BigInt.from(perFrom) * down;
  var q = n ~/ d;
  if ((n % d) * BigInt.two >= d) q += BigInt.one;
  const maxExact = 9007199254740991;
  final whole = q > BigInt.from(maxExact) ? maxExact : q.toInt();
  return amount < 0 ? -whole : whole;
}

// ---------- which rates a wallet needs ----------

/// An amount in [currency] on [date] that is counted in the wallet currency by an ECB rate ([fxNeeds]).
class FxNeed implements Comparable<FxNeed> {
  final String currency;
  final String date;
  const FxNeed(this.currency, this.date);

  @override
  bool operator ==(Object other) => other is FxNeed && other.currency == currency && other.date == date;

  @override
  int get hashCode => Object.hash(currency, date);

  @override
  int compareTo(FxNeed o) => currency == o.currency ? date.compareTo(o.date) : currency.compareTo(o.currency);

  @override
  String toString() => 'FxNeed($currency $date)';
}

/// The (currency, date) pairs among [amounts] (the currency and date of foreign payments, bills, IOUs, opening
/// balances: `WalletRepo.walletFxNeeds`) that would be counted in the wallet currency of [st] by an ECB rate: not the
/// wallet currency, a fiat code (a crypto currency is hand-set only, BTC), no hand-set rate for it
/// ([WalletSettings.fxRates] wins), a real date. Unique, sorted by currency, then date. Pure.
List<FxNeed> fxNeeds(Iterable<(String currency, String? date)> amounts, WalletSettings st) {
  final out = <FxNeed>{};
  for (final (cur, date) in amounts) {
    if (date == null || cur == st.currency || !isIsoDate(date) || !WalletSettings.currencyCode.hasMatch(cur)) continue;
    if (currencyInfo(cur)?.crypto ?? false) continue;
    if (st.fxRates.containsKey(cur)) continue;
    out.add(FxNeed(cur, date));
  }
  return out.toList()..sort();
}

// ---------- the ECB's files ----------

/// The rates read from one ECB file ([parseEcbRates]): currency → date → units per EUR × [ecbScale].
class EcbHistory {
  final Map<String, Map<String, int>> rates;
  final int days;
  final String oldest;
  final String newest;
  const EcbHistory(this.rates, {required this.days, required this.oldest, required this.newest});

  /// The currency codes, sorted.
  List<String> get currencies => rates.keys.toList()..sort();

  /// How many rates (currency, day).
  int get length => rates.values.fold(0, (n, m) => n + m.length);
}

/// What [parseEcbRates] refuses with (short, for the owner; never contains file content).
const ecbNotRatesMessage = 'This is not an ECB exchange rates file.';
const ecbDamagedMessage = 'The exchange rates download is damaged or cut off.';
const ecbPrecisionMessage = 'A rate in the file has more decimals than the app keeps.';

/// Largest unpacked file accepted from a zip (the full history is about 2 MB).
const _maxUnpacked = 64 * 1024 * 1024;

/// Reads an ECB reference rate file from [bytes]: the zipped history (`eurofxref-hist.zip`, one CSV inside; the
/// zip's checksums are verified), its CSV (`Date,USD,JPY,…` with `N/A` for a missing value, ISO dates; also the
/// daily file's `04 January 2024` dates), or the XML files (`eurofxref-hist-90d.xml`, `eurofxref-daily.xml`, which must
/// end with `</gesmes:Envelope>`). Values are decimal texts read exactly (at most 6 decimals, more than zero). Every row
/// must be whole: a row with a missing or extra cell, a bad date or value, a currency twice, a date with two values,
/// or no rate at all is a [FormatException] ([ecbNotRatesMessage], [ecbDamagedMessage], [ecbPrecisionMessage]); then
/// nothing may be written. A plain CSV cut exactly at a row's end cannot be told from a shorter file (the zip can).
EcbHistory parseEcbRates(List<int> bytes) {
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 0x03 && bytes[3] == 0x04) {
    return parseEcbRates(_unzip(bytes));
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw const FormatException(ecbNotRatesMessage);
  }
  final t = text.startsWith('﻿') ? text.substring(1) : text;
  final rates = t.trimLeft().startsWith('<') ? _xml(t) : _csv(t);
  var oldest = '', newest = '';
  final dates = <String>{};
  for (final m in rates.values) {
    for (final d in m.keys) {
      dates.add(d);
      if (oldest.isEmpty || d.compareTo(oldest) < 0) oldest = d;
      if (d.compareTo(newest) > 0) newest = d;
    }
  }
  if (dates.isEmpty) throw const FormatException(ecbNotRatesMessage);
  return EcbHistory(rates, days: dates.length, oldest: oldest, newest: newest);
}

List<int> _unzip(List<int> bytes) {
  final files = <List<int>>[];
  try {
    final a = ZipDecoder().decodeBytes(bytes, verify: true);
    for (final f in a.files) {
      if (!f.isFile) continue;
      final name = f.name.toLowerCase();
      if (!name.endsWith('.csv') && !name.endsWith('.xml')) continue;
      if (f.size > _maxUnpacked) throw const FormatException(ecbNotRatesMessage);
      files.add(f.content);
    }
  } on ArchiveException {
    throw const FormatException(ecbDamagedMessage);
  } on RangeError {
    throw const FormatException(ecbDamagedMessage);
  }
  if (files.length != 1) throw const FormatException(ecbNotRatesMessage);
  return files.single;
}

final _code = RegExp(r'^[A-Z]{3}$');
final _value = RegExp(r'^(\d{1,9})(?:\.(\d+))?$');
const _months = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];

/// A value text as units per EUR × [ecbScale], exactly; null when it is not a positive decimal.
int? _perEur(String v) {
  final m = _value.firstMatch(v);
  if (m == null) return null;
  final frac = m.group(2) ?? '';
  if (frac.length > 6) {
    if (frac.substring(6).replaceAll('0', '').isNotEmpty) throw const FormatException(ecbPrecisionMessage);
  }
  final six = (frac.length > 6 ? frac.substring(0, 6) : frac).padRight(6, '0');
  final p = int.parse(m.group(1)!) * ecbScale + int.parse(six);
  return p > 0 ? p : null;
}

/// An ISO date or the daily CSV's `4 January 2024`; null otherwise.
String? _ecbDate(String s) {
  if (isIsoDate(s)) return s;
  final p = s.split(RegExp(r'\s+'));
  if (p.length != 3) return null;
  final d = int.tryParse(p[0]), m = _months.indexOf(p[1].toLowerCase()) + 1, y = int.tryParse(p[2]);
  if (d == null || m == 0 || y == null || p[2].length != 4) return null;
  final iso = '${p[2]}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
  return isIsoDate(iso) ? iso : null;
}

void _put(Map<String, Map<String, int>> out, String cur, String date, int per) {
  final m = out[cur] ??= {};
  final have = m[date];
  if (have != null && have != per) throw const FormatException(ecbDamagedMessage);
  m[date] = per;
}

Map<String, Map<String, int>> _csv(String text) {
  final lines = [for (final l in text.split('\n')) l.endsWith('\r') ? l.substring(0, l.length - 1) : l];
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) throw const FormatException(ecbNotRatesMessage);
  final header = [for (final c in lines.first.split(',')) c.trim()];
  if (header.first != 'Date' || header.length < 2) throw const FormatException(ecbNotRatesMessage);
  final trailing = header.last.isEmpty;
  final codes = header.sublist(1, trailing ? header.length - 1 : header.length);
  if (codes.isEmpty || codes.any((c) => !_code.hasMatch(c)) || codes.toSet().length != codes.length) {
    throw const FormatException(ecbNotRatesMessage);
  }
  final out = <String, Map<String, int>>{};
  for (final line in lines.skip(1)) {
    final cells = [for (final c in line.split(',')) c.trim()];
    if (cells.length != header.length || (trailing && cells.last.isNotEmpty)) throw const FormatException(ecbDamagedMessage);
    final date = _ecbDate(cells.first) ?? (throw const FormatException(ecbDamagedMessage));
    for (var i = 0; i < codes.length; i++) {
      final v = cells[i + 1];
      if (v.isEmpty || v == 'N/A') continue;
      _put(out, codes[i], date, _perEur(v) ?? (throw const FormatException(ecbDamagedMessage)));
    }
  }
  return out;
}

final _cube = RegExp(r'<Cube\b([^>]*)>');
final _attr = RegExp(r'''(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');

Map<String, Map<String, int>> _xml(String text) {
  if (!text.contains('<gesmes:Envelope')) throw const FormatException(ecbNotRatesMessage);
  if (!text.trimRight().endsWith('</gesmes:Envelope>')) throw const FormatException(ecbDamagedMessage);
  final out = <String, Map<String, int>>{};
  String? day;
  for (final m in _cube.allMatches(text)) {
    final a = {for (final x in _attr.allMatches(m.group(1)!)) x.group(1)!: x.group(2) ?? x.group(3)!};
    if (a['time'] case final t?) {
      day = isIsoDate(t) ? t : (throw const FormatException(ecbDamagedMessage));
    } else if ((a['currency'], a['rate']) case (final c?, final r?)) {
      if (day == null || !_code.hasMatch(c)) throw const FormatException(ecbDamagedMessage);
      _put(out, c, day, _perEur(r) ?? (throw const FormatException(ecbDamagedMessage)));
    }
  }
  return out;
}
