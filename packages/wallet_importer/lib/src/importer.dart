import 'dart:convert';
import 'dart:typed_data';

import 'csv_reader.dart';
import 'ids.dart';
import 'model.dart';
import 'xls_reader.dart';
import 'xlsx_reader.dart';

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

/// Reads a bank export (PBZ .xls, Revolut .xlsx or .csv) into normalized transactions.
ImportBatch importBankFile(Uint8List bytes) {
  List<List<Object>> rows;
  try {
    if (XlsReader.looksLikeXls(bytes)) {
      rows = XlsReader.firstSheet(bytes);
    } else if (XlsxReader.looksLikeZip(bytes)) {
      rows = XlsxReader.firstSheet(bytes);
    } else {
      rows = readCsv(utf8.decode(bytes, allowMalformed: true));
    }
  } on FormatException catch (e) {
    throw ImportException('Could not read this file: ${e.message}');
  }
  final batch = parseRows(rows);
  if (batch == null) {
    throw const ImportException('This is not a PBZ or Revolut export I recognise.');
  }
  return batch;
}

String _s(Object? v) => v == null ? '' : (v is double ? _num(v) : v.toString()).trim();
String _num(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
String _pad(int n) => n.toString().padLeft(2, '0');

/// Excel serial day number to `YYYY-MM-DD` (UTC, 1900 date system).
String excelDate(double serial) {
  final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: (serial * 86400000).round()));
  return '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
}

String? _anyDate(Object v) {
  if (v is double) return excelDate(v);
  final s = v.toString().trim();
  var m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (m != null) return '${m[1]}-${m[2]}-${m[3]}';
  m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(s);
  if (m != null) return '${m[3]}-${m[2]!.padLeft(2, '0')}-${m[1]!.padLeft(2, '0')}';
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

int _cents(double x) => (x * 100).round();

/// Repairs text that was UTF-8 but got decoded as Latin-1 (e.g. "GraÅ¡o" -> "Grašo").
String fixMojibake(String s) {
  final units = s.codeUnits;
  if (units.every((c) => c < 0x80) || units.any((c) => c > 0xFF)) return s;
  try {
    return utf8.decode(units);
  } on FormatException {
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
    var skipped = 0;
    for (final r in rows.skip(revHdr + 1)) {
      Object at(int c) => c >= 0 && c < r.length ? r[c] : '';
      if (_s(at(cD)).isEmpty) continue;
      if (cS >= 0 && _s(at(cS)) != 'COMPLETED') {
        skipped++;
        continue;
      }
      final d = _anyDate(at(cD));
      final a = _toNum(at(cA));
      if (d == null || a == null) continue;
      final fee = cF >= 0 ? (_toNum(at(cF)) ?? 0) : 0.0;
      final currency = cC >= 0 && _s(at(cC)).isNotEmpty ? _s(at(cC)) : 'EUR';
      out.add(_Row(d, _cents(a) - _cents(fee), _s(at(cT)), fixMojibake(_s(at(cM))), currency));
    }
    return ImportBatch(source: 'revolut', transactions: _withIds('revolut', out), skipped: skipped);
  }

  // PBZ current account report
  final isPbz = head.any((r) => r.any((c) => RegExp(r'TRANSAKCIJSKI RA', caseSensitive: false).hasMatch(c) || c == 'DATUM'));
  if (isPbz) {
    final out = <_Row>[];
    var skipped = 0;
    final dmy = RegExp(r'^\d{1,2}\.\d{1,2}\.\d{4}$');
    for (final r in rows) {
      if (r.length < 4) continue;
      final c0 = r[0];
      String? d;
      if (c0 is double && c0 > 30000) {
        d = excelDate(c0);
      } else if (dmy.hasMatch(_s(c0))) {
        d = _anyDate(c0);
      }
      if (d == null) continue;
      final a = _toNum(r[3]);
      if (a == null) continue;
      final desc = _s(r[2]);
      if (RegExp(r'^REZERVACIJA', caseSensitive: false).hasMatch(desc)) {
        skipped++; // card hold: the final booking arrives in a later export
        continue;
      }
      final currency = r.length > 4 && _s(r[4]).isNotEmpty ? _s(r[4]) : 'EUR';
      out.add(_Row(d, _cents(a), _s(r[1]), desc, currency));
    }
    return ImportBatch(source: 'pbz', transactions: _withIds('pbz', out), skipped: skipped);
  }
  return null;
}
