import 'package:logging/logging.dart';

import 'log.dart';

final _log = Logger('bw.importer.csv');

/// Small RFC 4180 CSV reader. Detects `,` or `;` from the header line, unless [sep] is given (`;`, `,` or a tab).
/// [maxRows] stops after that many rows (for sniffing a file's shape; [strict] then checks only the rows read).
///
/// A `"` opens a quoted field only as the field's first character; anywhere else it is a literal character, so
/// `Pizza 5" wide` stays one field instead of swallowing the rows after it. v1 (SheetJS 0.18.5) reads stray quotes
/// the same way, so descriptions and ids match. Known v1 difference: text after a closing quote (`"Shop"X` → `ShopX`;
/// v1 keeps `"Shop"X`). A quoted field that never closes takes the rest of the text;
/// with [strict] that is a [FormatException] instead, because the rows after it would be lost silently.
List<List<Object>> readCsv(String text, {bool strict = false, String? sep, int? maxRows}) {
  if (text.startsWith('﻿')) text = text.substring(1);
  if (sep == null) {
    final firstLine = text.split('\n').first;
    sep = ';'.allMatches(firstLine).length > ','.allMatches(firstLine).length ? ';' : ',';
  }
  final rows = <List<Object>>[];
  var row = <Object>[];
  final field = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"' && field.isEmpty) {
      inQuotes = true;
    } else if (ch == sep) {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      if (!(row.length == 1 && (row.first as String).isEmpty)) rows.add(row);
      row = <Object>[];
      if (maxRows != null && rows.length >= maxRows) break;
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  logImporter(_log, Level.FINE, 'csv.read',
      {'chars': text.length, 'sep': sep == '\t' ? 'tab' : sep, 'rows': rows.length, 'unclosedQuote': inQuotes});
  if (strict && inQuotes) throw const FormatException('Unclosed quoted field');
  return rows;
}
