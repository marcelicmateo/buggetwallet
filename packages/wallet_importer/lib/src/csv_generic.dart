// Import any CSV by a remembered column mapping (P12, docs/context/P12_SPEC.md §1): the file's shape (encoding,
// delimiter, header row, columns), the owner's [CsvMapping] applied to it with exact cents, the problems and guesses
// the app's Map columns sheet shows. Logs carry counts, the encoding and the delimiter only: never headers, cells,
// layout names or file names.
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'csv_mapping.dart';
import 'csv_reader.dart';
import 'currencies.dart';
import 'importer.dart' show ImportException, unknownLayoutMessage;
import 'limits.dart';
import 'log.dart';
import 'model.dart';
import 'profiles/profile.dart';
import 'text_codec.dart';

final _log = Logger('bw.importer');

/// How many rows from the top the delimiter and the header row are judged from.
const _sniffRows = 15;

/// How many rows after the header [CsvShape.samples] holds.
const csvSampleRows = 5;

/// The text of [NeedsMapping]: a CSV no bank profile knows.
const needsMappingMessage = "This file isn't one I know yet. Map its columns once and it's remembered.";

/// A CSV with more than [maxCsvColumns] columns.
const tooManyColumnsMessage = 'This file has more than $maxCsvColumns columns, too many to map.';

/// A saved layout used on a file whose header names differ.
const layoutMismatchMessage = "This file's columns are not the ones this layout was made for.";

/// The `source` prefix of mapped rows: `csv:<shapeId>`.
const csvSourcePrefix = 'csv:';

/// What a source is called in logs: `csv` for a mapped CSV (the shape id is a hash of header names), else the
/// profile id as it is.
String sourceLogKey(String source) => source.startsWith(csvSourcePrefix) ? 'csv' : source;

/// A CSV no bank profile recognises, with its [shape] for the Map columns sheet. A subtype of [ImportException], so a
/// caller that only knows that shows [needsMappingMessage].
class NeedsMapping extends ImportException {
  final CsvShape shape;
  const NeedsMapping(this.shape) : super(needsMappingMessage);
}

/// What a CSV file looks like, for mapping its columns. [headers] and [samples] are for the app's preview only:
/// never logged ([toString] has counts only).
class CsvShape {
  /// `utf-8` or `windows-1250`.
  final String encoding;

  /// `;`, `,` or a tab.
  final String delimiter;

  /// The header row (0-based, into the file's rows; blank lines are not rows).
  final int headerRow;

  /// The header row's cells, trimmed.
  final List<String> headers;

  /// Up to [csvSampleRows] non-empty rows after the header, each padded or cut to [headers]' length.
  final List<List<String>> samples;

  /// The row index (0-based) of each of [samples].
  final List<int> sampleRows;

  /// All rows of the file, the header block included.
  final int rowCount;

  /// The first rows of the file (at most 15) as trimmed text, so the app can offer another header row.
  final List<List<String>> head;

  /// First 16 hex characters of SHA-256 over the folded [headers] joined with `|` ([csvShapeId]).
  final String shapeId;

  const CsvShape({
    required this.encoding,
    required this.delimiter,
    required this.headerRow,
    required this.headers,
    required this.samples,
    required this.sampleRows,
    required this.rowCount,
    required this.head,
    required this.shapeId,
  });

  /// The delimiter as a word for logs and labels: `semicolon`, `comma`, `tab`.
  String get delimiterName => _sepName(delimiter);

  @override
  String toString() => 'CsvShape($encoding, $delimiterName, cols: ${headers.length}, rows: $rowCount)';
}

String _sepName(String sep) => switch (sep) { ';' => 'semicolon', ',' => 'comma', _ => 'tab' };

/// A header name folded for the shape id: trimmed, lower case, inner whitespace collapsed to one space.
String _foldHeader(String h) => h.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// The shape id of a header row: first 16 hex characters of SHA-256 over the folded names joined with `|`.
String csvShapeId(List<String> headers) => sha256Hex(utf8.encode(headers.map(_foldHeader).join('|'))).substring(0, 16);

/// [CsvShape.headerRow] / [CsvMapping.headerRow] of a file without a header row: columns are named [csvColumnNames].
const csvNoHeader = -1;

/// The shape id of a file without a header row: from its column count and a fixed tag (never a header row's id).
String csvNoHeaderId(int columns) => sha256Hex(utf8.encode('bw-csv-noheader|$columns')).substring(0, 16);

/// The column names of a file without a header row: `Column 1`, `Column 2`, …
List<String> csvColumnNames(int columns) => [for (var i = 1; i <= columns; i++) 'Column $i'];

/// The shape id a layout belongs to: [csvShapeId] of its headers, or [csvNoHeaderId] for a layout without a header row.
String csvLayoutId(CsvMapping m) => m.headerRow == csvNoHeader ? csvNoHeaderId(m.headers.length) : csvShapeId(m.headers);

/// The header names of row [i] of [rows] without trailing empty cells, or null when fewer than two are left.
List<String>? _headersAt(List<List<String>> rows, int i) {
  final h = List<String>.of(rows[i]);
  while (h.isNotEmpty && h.last.isEmpty) {
    h.removeLast();
  }
  return h.length < 2 ? null : h;
}

/// The widest of the first rows: a file without a header row has this many columns.
int _headWidth(List<List<String>> rows) => rows.take(_sniffRows).fold(0, (w, r) => r.length > w ? r.length : w);

/// The decoded rows of a CSV file, its encoding and delimiter. Refuses a file over [maxImportBytes] and a damaged one.
(List<List<String>> rows, String encoding, String sep) _load(Uint8List bytes) {
  if (bytes.length > maxImportBytes) {
    logImporter(_log, Level.WARNING, 'importer.refused', {'reason': 'tooLarge', 'bytes': bytes.length});
    throw const ImportException(tooLargeMessage);
  }
  // NUL bytes: UTF-16 text, a picture or another binary file, never a CSV to map.
  if (bytes.take(4096).contains(0)) {
    logImporter(_log, Level.INFO, 'importer.shape', {'reason': 'binary', 'bytes': bytes.length});
    throw ImportException(unknownLayoutMessage);
  }
  final (text, encoding) = decodeCsvBytes(bytes);
  final sep = _detectSep(text);
  final List<List<Object>> raw;
  try {
    raw = readCsv(text, strict: true, sep: sep);
  } on FormatException {
    logImporter(_log, Level.WARNING, 'importer.readFailed', {'format': 'csv', 'bytes': bytes.length, 'mapped': true});
    throw const ImportException('Could not read this file. It may be damaged or not a bank export.');
  }
  final rows = [for (final r in raw) r.map((c) => c.toString().trim()).toList()];
  for (final r in rows) {
    if (r.length > maxCsvColumns) {
      logImporter(_log, Level.WARNING, 'importer.refused', {'reason': 'tooManyColumns', 'cols': r.length});
      throw const ImportException(tooManyColumnsMessage);
    }
  }
  return (rows, encoding, sep);
}

/// The most frequent field count of [rows] and how many rows have it (a tie goes to the wider count).
(int width, int count) _mode(List<List<Object>> rows) {
  final freq = <int, int>{};
  for (final r in rows) {
    freq[r.length] = (freq[r.length] ?? 0) + 1;
  }
  var width = 0, count = 0;
  for (final MapEntry(key: w, value: n) in freq.entries) {
    if (n > count || (n == count && w > width)) (width, count) = (w, n);
  }
  return (width, count);
}

/// `;`, tab or `,`: the one giving the most consistent field count (of at least 2) over the first [_sniffRows] rows;
/// a tie goes to the wider rows, then to this order.
String _detectSep(String text) {
  var best = ';';
  var bestScore = -1;
  for (final sep in const [';', '\t', ',']) {
    final (width, count) = _mode(readCsv(text, sep: sep, maxRows: _sniffRows));
    if (width < 2) continue;
    final score = count * 1000 + width;
    if (score > bestScore) (best, bestScore) = (sep, score);
  }
  return best;
}

final _numeric = RegExp(r'^[+\-−]?[\d.,\s]*\d[\d.,\s]*$');
final _dateLike = RegExp(r'^\d{1,4}[./-]\d{1,2}[./-]\d{1,4}');

bool _isText(String c) => !_numeric.hasMatch(c) && !_dateLike.hasMatch(c);

int _filled(List<String> r) => r.where((c) => c.isNotEmpty).length;

/// The first row of the head with at least two (and half the usual number of) filled cells, all of them text (a cell
/// shaped like a date or an amount is data, never a header name), and a later row with two or more filled cells (a
/// line of prose with a comma in it is no header).
int? _findHeader(List<List<String>> rows) {
  final head = rows.take(_sniffRows).toList();
  final (width, _) = _mode(head);
  final need = width < 4 ? 2 : (width + 1) ~/ 2;
  for (var i = 0; i < head.length; i++) {
    final filled = head[i].where((c) => c.isNotEmpty).toList();
    if (filled.length < need || !filled.every(_isText)) continue;
    return rows.skip(i + 1).any((r) => _filled(r) >= 2) ? i : null;
  }
  return null;
}

/// Whether the file reads as rows of data without a header: at least two of the first rows share a field count of
/// two or more.
bool _dataOnly(List<List<String>> rows) {
  final (width, count) = _mode(rows.take(_sniffRows).toList());
  return width >= 2 && count >= 2;
}

CsvShape _shapeOf(List<List<String>> rows, String encoding, String sep, int? headerRow) {
  final h = headerRow ?? _findHeader(rows) ?? (_dataOnly(rows) ? csvNoHeader : null);
  if (h == null) {
    logImporter(
        _log, Level.INFO, 'importer.shape', {'encoding': encoding, 'delimiter': _sepName(sep), 'rows': rows.length, 'header': false});
    throw ImportException(unknownLayoutMessage);
  }
  if (h < csvNoHeader || h >= rows.length) throw RangeError.range(h, csvNoHeader, rows.length - 1, 'headerRow');
  final headers = h == csvNoHeader ? csvColumnNames(_headWidth(rows)) : _headersAt(rows, h);
  if (headers == null || headers.length < 2) throw ImportException(unknownLayoutMessage);
  final samples = <List<String>>[], sampleRows = <int>[];
  for (var i = h + 1; i < rows.length && samples.length < csvSampleRows; i++) {
    if (rows[i].every((c) => c.isEmpty)) continue;
    samples.add([for (var c = 0; c < headers.length; c++) c < rows[i].length ? rows[i][c] : '']);
    sampleRows.add(i);
  }
  return CsvShape(
    encoding: encoding,
    delimiter: sep,
    headerRow: h,
    headers: List.unmodifiable(headers),
    samples: List.unmodifiable(samples),
    sampleRows: List.unmodifiable(sampleRows),
    rowCount: rows.length,
    head: List.unmodifiable(rows.take(_sniffRows).map(List<String>.unmodifiable)),
    shapeId: h == csvNoHeader ? csvNoHeaderId(headers.length) : csvShapeId(headers),
  );
}

/// The shape of a CSV file (§1): encoding (UTF-8, else Windows-1250), delimiter (`;`, `,` or tab, the most consistent
/// field count over the first 15 rows), header row (the first row whose cells are mostly text, or [headerRow] when
/// the owner picked one), headers, up to 5 sample rows and the shape id. Throws [ImportException] for a file over
/// [maxImportBytes], a damaged file, more than [maxCsvColumns] columns, or no header row with two or more columns
/// ([unknownLayoutMessage]); a [RangeError] for a [headerRow] outside the file.
CsvShape csvShape(Uint8List bytes, {int? headerRow}) {
  final (rows, encoding, sep) = _load(bytes);
  final shape = _shapeOf(rows, encoding, sep, headerRow);
  logImporter(_log, Level.FINE, 'importer.shape', {
    'encoding': encoding,
    'delimiter': shape.delimiterName,
    'rows': rows.length,
    'cols': shape.headers.length,
    'headerRow': shape.headerRow,
  });
  return shape;
}

/// A saved layout that fits a file ([matchCsvLayout]): its key and the row of this file its header names are on.
class CsvLayoutMatch {
  final String shapeId;

  /// The header row in this file (0-based, or [csvNoHeader]); it can differ from the layout's own `headerRow` (an
  /// extra title line, or the owner moved it): import with `m.copyWith(headerRow: headerRow)`.
  final int headerRow;
  const CsvLayoutMatch(this.shapeId, this.headerRow);

  @override
  String toString() => 'CsvLayoutMatch(headerRow: $headerRow)';
}

/// The saved layout (in [saved]: shape id → layout) that fits the file [shape] was read from, or null: [shape]'s own
/// id first, then any of its first 15 rows as the header row (a title line more or less, a header row the owner
/// moved), then the file read without a header row. [bytes] is the file (kept for callers; the rows come from
/// [CsvShape.head]).
CsvLayoutMatch? matchCsvLayout(Uint8List bytes, CsvShape shape, Map<String, CsvMapping> saved) {
  if (saved.containsKey(shape.shapeId)) return CsvLayoutMatch(shape.shapeId, shape.headerRow);
  for (var i = 0; i < shape.head.length; i++) {
    final h = _headersAt(shape.head, i);
    if (h == null) continue;
    final id = csvShapeId(h);
    if (saved.containsKey(id)) return CsvLayoutMatch(id, i);
  }
  final none = csvNoHeaderId(_headWidth(shape.head));
  return saved[none]?.headerRow == csvNoHeader ? CsvLayoutMatch(none, csvNoHeader) : null;
}

/// The key of [matchCsvLayout]'s match, or null.
String? matchCsvMapping(Uint8List bytes, CsvShape shape, Map<String, CsvMapping> saved) => matchCsvLayout(bytes, shape, saved)?.shapeId;

/// One row as a mapping reads it ([previewMapping]).
class CsvPreviewRow {
  /// The row's index in the file (0-based); problems say `Row ${row + 1}`.
  final int row;

  /// The row is left out on purpose (its [CsvMapping.skipIfEmptyCol] cell is empty).
  final bool skipped;
  final String? date;
  final int? amountMinor;
  final String? currency;
  final String description;

  /// What is wrong with the row (owner-readable, may quote the cell), or null when it imports.
  final String? problem;

  /// The [problem] is an amount beyond `maxRowAmountMinor` (counted in `ImportBatch.tooLarge`).
  final bool tooLarge;

  /// The balance column's amount ([CsvMapping.balanceCol]), or null when there is none or it is not an amount.
  final int? balanceAfter;

  const CsvPreviewRow(
      {required this.row,
      this.skipped = false,
      this.date,
      this.amountMinor,
      this.currency,
      this.description = '',
      this.problem,
      this.tooLarge = false,
      this.balanceAfter});

  bool get ok => problem == null && !skipped;

  @override
  String toString() => 'CsvPreviewRow(row: $row, ok: $ok)';
}

/// A cell quoted in a problem text, cut to 24 characters.
String _q(String s) => s.length > 24 ? '${s.substring(0, 23)}…' : s;

final _dateRes = {
  CsvDateFormat.dmyDot: RegExp(r'^(\d{2})\.(\d{2})\.(\d{4})\.?(?:[\sT].*)?$'),
  CsvDateFormat.dmyDotShort: RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})\.?(?:[\sT].*)?$'),
  CsvDateFormat.iso: RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:[\sT].*)?$'),
  CsvDateFormat.dmySlash: RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:[\sT].*)?$'),
  CsvDateFormat.mdySlash: RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:[\sT].*)?$'),
  CsvDateFormat.dmyDash: RegExp(r'^(\d{2})-(\d{2})-(\d{4})(?:[\sT].*)?$'),
};

/// The `YYYY-MM-DD` of [s] in format [f], or null when it is not one or not a real calendar day (years 1900–2199).
String? parseCsvDate(String s, CsvDateFormat f) {
  final m = _dateRes[f]!.firstMatch(s.trim());
  if (m == null) return null;
  final a = int.parse(m[1]!), b = int.parse(m[2]!), c = int.parse(m[3]!);
  final (y, mo, d) = switch (f) {
    CsvDateFormat.iso => (a, b, c),
    CsvDateFormat.mdySlash => (c, a, b),
    _ => (c, b, a),
  };
  if (y < 1900 || y > 2199 || mo < 1 || mo > 12 || d < 1) return null;
  final t = DateTime.utc(y, mo, d);
  if (t.month != mo || t.day != d) return null;
  return '${y.toString().padLeft(4, '0')}-${mo.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}

/// Why an amount cell is not usable.
enum _AmountError { empty, notAmount, decimals, tooBig }

final _space = RegExp(r'[\s  ]');
final _amountRes = {
  CsvDecimal.comma: RegExp(r'^(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d+))?$'),
  CsvDecimal.point: RegExp(r'^(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?$'),
};

/// Exact minor units of an amount cell in [decimal] style (thousands marks of the other kind, spaces allowed; a leading
/// `+`, `-` or `−`) for a currency with [digits] minor digits (`minorDigitsOf`; 2 = cents). No doubles: at most [digits]
/// decimals (a finer fraction is refused, never rounded), up to [maxRowAmountMinor].
(int?, _AmountError?) _cents(String raw, CsvDecimal decimal, [int digits = 2]) {
  var s = raw.replaceAll(_space, '');
  if (s.isEmpty) return (null, _AmountError.empty);
  var neg = false;
  if (s.startsWith('-') || s.startsWith('−') || s.startsWith('+')) {
    neg = !s.startsWith('+');
    s = s.substring(1);
  }
  final m = _amountRes[decimal]!.firstMatch(s);
  if (m == null) return (null, _AmountError.notAmount);
  final frac = m[2] ?? '';
  // For a currency with fewer digits than cents, zeros past them change nothing (`10,00` yen is 10 yen); any other
  // digit there is refused.
  final kept = digits < 2 && frac.length > digits && RegExp(r'^0*$').hasMatch(frac.substring(digits)) ? frac.substring(0, digits) : frac;
  if (kept.length > digits) return (null, _AmountError.decimals);
  final whole = m[1]!.replaceAll(decimal == CsvDecimal.comma ? '.' : ',', '').replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (whole.length > 15 - digits) return (null, _AmountError.tooBig);
  final cents = int.parse(whole) * pow10(digits) + (digits == 0 ? 0 : int.parse(kept.padRight(digits, '0')));
  if (cents > maxRowAmountMinor) return (null, _AmountError.tooBig);
  return (neg ? -cents : cents, null);
}

/// Exact cents of an amount text in [decimal] style, or null when it is not one (see the Map columns rules). [digits]:
/// the minor digits of the amount's currency (2 = cents).
int? parseCsvCents(String s, CsvDecimal decimal, {int digits = 2}) => _cents(s, decimal, digits).$1;

String _amountProblem(int row, String what, String cell, _AmountError e, int digits) => switch (e) {
      _AmountError.empty => 'Row ${row + 1}: no $what',
      _AmountError.notAmount => 'Row ${row + 1}: the $what ${_q(cell)} is not an amount',
      _AmountError.decimals => digits == 0
          ? 'Row ${row + 1}: the $what ${_q(cell)} has decimals, and its currency has none'
          : 'Row ${row + 1}: the $what ${_q(cell)} has more than $digits decimals',
      _AmountError.tooBig => 'Row ${row + 1}: the $what ${_q(cell)} is too large',
    };

final _code = RegExp(r'^[A-Z]{3}$');

/// Reads one row with [m]. [row] is the row's index in the file.
CsvPreviewRow _mapRow(List<String> cells, int row, CsvMapping m, String walletCurrency) {
  String cell(int? c) => c == null || c >= cells.length ? '' : cells[c].trim();
  if (m.skipIfEmptyCol != null && cell(m.skipIfEmptyCol).isEmpty) return CsvPreviewRow(row: row, skipped: true);
  final description = [for (final c in m.descriptionCols) cell(c)].where((s) => s.isNotEmpty).join(' · ');
  CsvPreviewRow bad(String p, {bool tooLarge = false}) => CsvPreviewRow(row: row, description: description, problem: p, tooLarge: tooLarge);
  final dateCell = cell(m.dateCol);
  final date = parseCsvDate(dateCell, m.dateFormat);
  if (date == null) return bad(dateCell.isEmpty ? 'Row ${row + 1}: no date' : 'Row ${row + 1}: the date ${_q(dateCell)} is not a date');
  // The currency first: the amount is read with its minor digits (JPY 0, KWD 3, BTC 8). Its problem is reported after
  // the amount's, as before.
  var currency = m.currencyCode ?? walletCurrency;
  String? currencyProblem;
  if (m.currencyCol != null) {
    final raw = cell(m.currencyCol);
    final up = raw == '€' ? 'EUR' : raw.toUpperCase();
    if (raw.isEmpty) {
      currencyProblem = 'Row ${row + 1}: no currency';
    } else if (!_code.hasMatch(up)) {
      currencyProblem = 'Row ${row + 1}: the currency ${_q(raw)} is not a currency code';
    } else {
      currency = up;
    }
  }
  final digits = minorDigitsOf(currency);
  int cents;
  if (m.amountCol != null) {
    final (c, e) = _cents(cell(m.amountCol), m.decimal, digits);
    if (e != null) return bad(_amountProblem(row, 'amount', cell(m.amountCol), e, digits), tooLarge: e == _AmountError.tooBig);
    cents = c!;
  } else {
    final debitCell = cell(m.debitCol), creditCell = cell(m.creditCol);
    if (debitCell.replaceAll(_space, '').isEmpty && creditCell.replaceAll(_space, '').isEmpty) return bad('Row ${row + 1}: no amount');
    final (d, de) = debitCell.isEmpty ? (0, null) : _cents(debitCell, m.decimal, digits);
    if (de != null) return bad(_amountProblem(row, 'debit', debitCell, de, digits), tooLarge: de == _AmountError.tooBig);
    final (c, ce) = creditCell.isEmpty ? (0, null) : _cents(creditCell, m.decimal, digits);
    if (ce != null) return bad(_amountProblem(row, 'credit', creditCell, ce, digits), tooLarge: ce == _AmountError.tooBig);
    if (d != 0 && c != 0) return bad('Row ${row + 1}: both debit and credit');
    // Exactly as written: credit − debit (a debit of −12,30 is a reversal, money in; a credit of −50,00 is money out).
    cents = c! - d!;
  }
  if (currencyProblem != null) return bad(currencyProblem);
  if (m.negate) cents = -cents;
  final balance = m.balanceCol == null ? null : _cents(cell(m.balanceCol), m.decimal, digits).$1;
  return CsvPreviewRow(row: row, date: date, amountMinor: cents, currency: currency, description: description, balanceAfter: balance);
}

/// The sample rows of [shape] read with [m], for the preview (date, description, signed amount, or the problem).
List<CsvPreviewRow> previewMapping(CsvShape shape, CsvMapping m, {String walletCurrency = 'EUR'}) => [
      for (var i = 0; i < shape.samples.length; i++) _mapRow(shape.samples[i], shape.sampleRows[i], m, walletCurrency),
    ];

/// Owner-readable problems of [m] on [shape]: the mapping's own ([CsvMapping.structureProblems]) and those of the
/// sample rows ("Row 4: the date 31.02.2026 is not a date", "Row 7: no amount"). Empty = Save & import may go on.
List<String> mappingProblems(CsvShape shape, CsvMapping m) {
  if (m.headerRow != shape.headerRow) return const ['The header row changed. Read the file again from that row.'];
  final own = m.structureProblems(columns: shape.headers.length);
  if (own.isNotEmpty) return own;
  if (m.headers.isNotEmpty && csvLayoutId(m) != shape.shapeId) return const [layoutMismatchMessage];
  return [
    for (final r in previewMapping(shape, m))
      if (r.problem != null) r.problem!
  ];
}

/// Reads a CSV with the owner's mapping [m]. The batch's source is `csv:<shapeId>` (the shape at [m]'s header row; when
/// [m] carries its header names and they are on another of the first 15 rows of this file, e.g. one title line more,
/// that row is the header row); ids are [sourceTransactionId]s with the occurrence counter, so the same file gives the same ids. A row that fails
/// is counted in [ImportBatch.invalid] and its index in [ImportBatch.invalidRows], never guessed; an empty
/// [CsvMapping.skipIfEmptyCol] cell counts as skipped; a blank row is not counted. [walletCurrency] is the currency
/// when [m] names none. [fileName] is never logged or stored. Throws [ImportException] for everything [csvShape]
/// refuses, a mapping with a problem of its own, or another file's columns ([layoutMismatchMessage]).
ImportBatch parseMappedCsv(Uint8List bytes, CsvMapping layout, {String? fileName, String walletCurrency = 'EUR'}) {
  final sw = Stopwatch()..start();
  final (rows, encoding, sep) = _load(bytes);
  var m = layout;
  if (m.headers.isNotEmpty && m.headerRow != csvNoHeader) {
    // The layout's header names on another row of this file (a title line more or less): read from there.
    final want = csvLayoutId(m);
    bool at(int i) {
      if (i < 0 || i >= rows.length) return false;
      final h = _headersAt(rows, i);
      return h != null && csvShapeId(h) == want;
    }

    if (!at(m.headerRow)) {
      for (var i = 0; i < rows.length && i < _sniffRows; i++) {
        if (at(i)) {
          m = m.copyWith(headerRow: i);
          break;
        }
      }
    }
  }
  if (m.headerRow < csvNoHeader || m.headerRow >= rows.length) throw const ImportException(layoutMismatchMessage);
  final shape = _shapeOf(rows, encoding, sep, m.headerRow);
  final own = m.structureProblems(columns: shape.headers.length);
  if (own.isNotEmpty) throw ImportException(own.first);
  if (m.headers.isNotEmpty && csvLayoutId(m) != shape.shapeId) throw const ImportException(layoutMismatchMessage);
  final source = '$csvSourcePrefix${shape.shapeId}';
  final ctx = ImportContext(head: const [], format: 'csv', fileName: fileName);
  final out = <NormalizedTransaction>[];
  final invalidRows = <int>[];
  var skipped = 0, tooLarge = 0;
  for (var i = m.headerRow + 1; i < rows.length; i++) {
    if (rows[i].every((c) => c.isEmpty)) continue;
    final r = _mapRow(rows[i], i, m, walletCurrency);
    if (r.skipped) {
      skipped++;
    } else if (r.problem != null) {
      invalidRows.add(i);
      if (r.tooLarge) tooLarge++;
    } else {
      out.add(NormalizedTransaction(
        id: ctx.sourceId(source, r.date!, r.amountMinor!, r.description, digits: minorDigitsOf(r.currency!)),
        source: source,
        date: r.date!,
        amountMinor: r.amountMinor!,
        currency: r.currency!,
        bankType: '',
        description: r.description,
        balanceAfter: r.balanceAfter,
      ));
    }
  }
  logImporter(_log, Level.INFO, 'importer.parse', {
    'format': 'csv',
    'mapped': true,
    'encoding': encoding,
    'delimiter': shape.delimiterName,
    'rows': rows.length,
    'txs': out.length,
    'skipped': skipped,
    'invalid': invalidRows.length,
    'ms': sw.elapsedMilliseconds,
  });
  return ImportBatch(
      source: source, transactions: out, skipped: skipped, invalid: invalidRows.length, invalidRows: invalidRows, tooLarge: tooLarge);
}

/// Header text folded for guessing: lower case, Croatian letters without marks, trimmed.
String _foldGuess(String h) {
  const from = 'čćšžđ', to = 'ccszd';
  final b = StringBuffer();
  for (final ch in h.toLowerCase().trim().split('')) {
    final i = from.indexOf(ch);
    b.write(i < 0 ? ch : to[i]);
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ');
}

/// A starting mapping from [shape]'s header names (Croatian and English: Datum/Date, Iznos/Amount, Duguje/Potražuje,
/// Debit/Credit, Isplata/Uplata, Opis/Description/Primatelj, Valuta/Currency, Saldo/Stanje/Balance as the balance
/// column), the date format and decimal style
/// from the samples. Null when no date or no amount column is found. Only a suggestion: the app shows every field
/// and the owner accepts it.
CsvMapping? guessMapping(CsvShape shape) {
  final h = shape.headers.map(_foldGuess).toList();
  int? find(bool Function(String) ok, {Set<int> not = const {}}) {
    for (var i = 0; i < h.length; i++) {
      if (!not.contains(i) && ok(h[i])) return i;
    }
    return null;
  }

  bool has(String s, List<String> words) => words.any(s.contains);
  bool balance(String s) => has(s, const ['saldo', 'balance', 'stanje']);
  final date = find((s) => has(s, const ['datum', 'date']));
  if (date == null) return null;
  final used = {date};
  final amount = find((s) => has(s, const ['iznos', 'amount', 'betrag']) && !balance(s), not: used);
  int? debit, credit;
  if (amount == null) {
    debit =
        find((s) => has(s, const ['duguje', 'debit', 'isplat', 'terecenj', 'paid out', 'money out', 'withdraw']) && !balance(s), not: used);
    credit = find((s) => has(s, const ['potrazuje', 'credit', 'uplat', 'odobrenj', 'paid in', 'money in', 'deposit']) && !balance(s),
        not: {...used, if (debit != null) debit});
    if (debit == null || credit == null) return null;
  }
  used.addAll([amount, debit, credit].whereType<int>());
  final currency = find((s) => s == 'valuta' || s.startsWith('valuta ') || s.contains('currency') || s == 'ccy', not: used);
  if (currency != null) used.add(currency);
  final balanceCol = find(balance, not: used);
  if (balanceCol != null) used.add(balanceCol);
  final description = <int>[];
  for (var i = 0; i < h.length && description.length < 3; i++) {
    if (!used.contains(i) &&
        has(h[i], const ['opis', 'description', 'primatelj', 'platitelj', 'svrha', 'payee', 'merchant', 'details', 'naziv', 'reference'])) {
      description.add(i);
    }
  }
  String cell(List<String> r, int? c) => c == null || c >= r.length ? '' : r[c].trim();
  final dates = [for (final r in shape.samples) cell(r, date)].where((s) => s.isNotEmpty).toList();
  final format = CsvDateFormat.values
      .firstWhere((f) => dates.isNotEmpty && dates.every((d) => parseCsvDate(d, f) != null), orElse: () => CsvDateFormat.dmyDot);
  final amounts = [
    for (final r in shape.samples)
      for (final c in [amount, debit, credit]) cell(r, c)
  ].where((s) => s.isNotEmpty);
  final point = amounts.any((s) => RegExp(r'\.\d{1,2}$').hasMatch(s)) && !amounts.any((s) => RegExp(r',\d{1,2}$').hasMatch(s));
  return CsvMapping(
    name: 'CSV file',
    headerRow: shape.headerRow,
    dateCol: date,
    dateFormat: format,
    amountCol: amount,
    debitCol: debit,
    creditCol: credit,
    decimal: point ? CsvDecimal.point : CsvDecimal.comma,
    descriptionCols: description,
    currencyCol: currency,
    balanceCol: balanceCol,
    headers: shape.headers,
  );
}
