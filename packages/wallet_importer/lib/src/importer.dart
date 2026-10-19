import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'csv_reader.dart';
import 'ids.dart';
import 'log.dart';
import 'model.dart';
import 'xls_reader.dart';
import 'xlsx_reader.dart';

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

final _log = Logger('bw.importer');

/// Reads a bank export (PBZ .xls, Revolut .xlsx or .csv) into normalized transactions.
///
/// Logs on `bw.importer`: the detected container format, sizes, row counts and timings. Never cell contents.
ImportBatch importBankFile(Uint8List bytes) {
  final sw = Stopwatch()..start();
  List<List<Object>> rows;
  final format = XlsReader.looksLikeXls(bytes) ? 'xls' : (XlsxReader.looksLikeZip(bytes) ? 'xlsx' : 'csv');
  logImporter(_log, Level.FINE, 'importer.detect', {'format': format, 'bytes': bytes.length});
  try {
    rows = switch (format) {
      'xls' => XlsReader.firstSheet(bytes),
      'xlsx' => XlsxReader.firstSheet(bytes),
      _ => readCsv(utf8.decode(bytes, allowMalformed: true)),
    };
  } on FormatException catch (e, st) {
    // Our readers' messages are fixed texts; the formatter drops FormatException.source.
    _log.warning(() => 'importer.readFailed ${jsonEncode({'format': format, 'bytes': bytes.length})}', e, st);
    throw const ImportException('Could not read this file. It may be damaged or not a bank export.');
  } catch (e, st) {
    // A damaged file can fail anywhere in the readers (RangeError on a truncated .xls, archive errors, …).
    _log.warning(() => 'importer.readFailed ${jsonEncode({'format': format, 'bytes': bytes.length})}', e, st);
    throw const ImportException('Could not read this file. It may be damaged.');
  }
  final readMs = sw.elapsedMilliseconds;
  final batch = parseRows(rows);
  if (batch == null) {
    logImporter(_log, Level.WARNING, 'importer.unknown',
        {'format': format, 'rows': rows.length, 'cols': rows.isEmpty ? 0 : rows.first.length, 'readMs': readMs});
    throw const ImportException('This is not a PBZ or Revolut export I recognise.');
  }
  logImporter(_log, Level.INFO, 'importer.parse', {
    'format': format,
    'source': batch.source,
    'rows': rows.length,
    'txs': batch.transactions.length,
    'skipped': batch.skipped,
    'invalid': batch.invalid,
    'readMs': readMs,
    'ms': sw.elapsedMilliseconds,
  });
  return batch;
}

String _s(Object? v) => v == null ? '' : (v is double ? _num(v) : v.toString()).trim();
String _num(double v) => v.isFinite && v == v.roundToDouble() ? v.toInt().toString() : v.toString();
String _pad(int n) => n.toString().padLeft(2, '0');

/// Excel serial day number to `YYYY-MM-DD` (UTC, 1900 date system).
String excelDate(double serial) {
  final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: (serial * 86400000).round()));
  return '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
}

/// What [_anyDate] returns for a cell shaped like a date that is not a real calendar day.
const _impossible = '';

/// Largest Excel serial day accepted (9999-12-31).
const _maxSerial = 2958465.0;

/// A real `YYYY-MM-DD` from the parts, or [_impossible] (2026-13-45, 31.02.2026, year 0000).
String _ymd(String y, String m, String d) {
  final yi = int.parse(y), mi = int.parse(m), di = int.parse(d);
  final t = DateTime.utc(yi, mi, di);
  if (yi < 1 || t.year != yi || t.month != mi || t.day != di) return _impossible;
  return '$y-${m.padLeft(2, '0')}-${d.padLeft(2, '0')}';
}

/// Excel serial day to a date, or [_impossible] outside 1900-01-01 .. 9999-12-31 (or not finite).
String _serialDate(double v) => v.isFinite && v >= 1 && v <= _maxSerial ? excelDate(v) : _impossible;

/// The date in a cell: `null` when the cell is not a date at all (header, footer, empty), [_impossible] when it
/// looks like one but is not a real calendar day, else `YYYY-MM-DD`.
String? _anyDate(Object v) {
  if (v is double) return _serialDate(v);
  final s = v.toString().trim();
  var m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (m != null) return _ymd(m[1]!, m[2]!, m[3]!);
  m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(s);
  if (m != null) return _ymd(m[3]!, m[2]!, m[1]!);
  return null;
}

double? _toNum(Object v) {
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
int? _cents(double x) {
  final c = x * 100;
  if (!c.isFinite || c.abs() > maxAmountCents) return null;
  return jsRound(c);
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

List<NormalizedTransaction> _withIds(String source, List<_Row> rows) {
  final seen = <String, int>{};
  return [
    for (final r in rows)
      () {
        final key = '${r.date}|${formatCents(r.cents)}|${r.desc}';
        final n = seen[key] ?? 0;
        seen[key] = n + 1;
        return NormalizedTransaction(
          id: transactionId(r.date, r.cents, r.desc, n),
          source: source,
          date: r.date,
          amountMinor: r.cents,
          currency: r.currency,
          bankType: r.type,
          description: r.desc,
        );
      }(),
  ];
}

class _Row {
  final String date, type, desc, currency;
  final int cents;
  _Row(this.date, this.cents, this.type, this.desc, this.currency);
}

/// Turns the rows of a sheet into a batch, or `null` when the layout is unknown.
ImportBatch? parseRows(List<List<Object>> rows) {
  final head = rows.take(15).map((r) => r.map(_s).toList()).toList();

  // Revolut account statement
  final revHdr = head.indexWhere((r) => r.contains('Started Date') && r.contains('Description') && r.contains('Amount'));
  if (revHdr >= 0) {
    final h = head[revHdr];
    int col(String n) => h.indexOf(n);
    final cT = col('Type'), cD = col('Started Date'), cM = col('Description'), cA = col('Amount');
    final cF = col('Fee'), cS = col('State'), cC = col('Currency');
    final out = <_Row>[];
    var skipped = 0, invalid = 0;
    for (final r in rows.skip(revHdr + 1)) {
      Object at(int c) => c >= 0 && c < r.length ? r[c] : '';
      if (_s(at(cD)).isEmpty) continue;
      if (cS >= 0 && _s(at(cS)) != 'COMPLETED') {
        skipped++;
        continue;
      }
      // An empty Amount is not a transaction (owner decision): ignored without a count.
      if (_s(at(cA)).isEmpty) continue;
      // From here the row has a Started Date and an Amount: if any of it cannot be read, it is counted.
      final d = _anyDate(at(cD));
      final a = _toNum(at(cA));
      // An empty Fee is 0; a Fee that is there but not a number would silently change the amount.
      final fee = cF >= 0 && _s(at(cF)).isNotEmpty ? _toNum(at(cF)) : 0.0;
      if (d == null || d == _impossible || a == null || fee == null) {
        invalid++;
        continue;
      }
      final amount = _cents(a), feeCents = _cents(fee);
      if (amount == null || feeCents == null) {
        invalid++;
        continue;
      }
      final currency = cC >= 0 && _s(at(cC)).isNotEmpty ? _s(at(cC)) : 'EUR';
      out.add(_Row(d, amount - feeCents, _s(at(cT)), fixMojibake(_s(at(cM))), currency));
    }
    return ImportBatch(source: 'revolut', transactions: _withIds('revolut', out), skipped: skipped, invalid: invalid);
  }

  // PBZ current account report
  final isPbz = head.any((r) => r.any((c) => RegExp(r'TRANSAKCIJSKI RA', caseSensitive: false).hasMatch(c) || c == 'DATUM'));
  if (isPbz) {
    final out = <_Row>[];
    var skipped = 0, invalid = 0;
    final dmy = RegExp(r'^\d{1,2}\.\d{1,2}\.\d{4}$');
    for (final r in rows) {
      if (r.length < 4) continue;
      final c0 = r[0];
      String? d;
      if (c0 is double && c0.isFinite && c0 > 30000) {
        d = _serialDate(c0);
      } else if (dmy.hasMatch(_s(c0))) {
        d = _anyDate(c0);
      }
      if (d == null) continue;
      // An empty amount is not a transaction; a dated row with an amount we cannot read is counted.
      if (_s(r[3]).isEmpty) continue;
      final a = _toNum(r[3]);
      if (a == null || d == _impossible) {
        invalid++;
        continue;
      }
      final desc = _s(r[2]);
      if (RegExp(r'^REZERVACIJA', caseSensitive: false).hasMatch(desc)) {
        skipped++; // card hold: the final booking arrives in a later export
        continue;
      }
      final amount = _cents(a);
      if (amount == null) {
        invalid++;
        continue;
      }
      final currency = r.length > 4 && _s(r[4]).isNotEmpty ? _s(r[4]) : 'EUR';
      out.add(_Row(d, amount, _s(r[1]), desc, currency));
    }
    return ImportBatch(source: 'pbz', transactions: _withIds('pbz', out), skipped: skipped, invalid: invalid);
  }
  return null;
}
