import 'package:logging/logging.dart';

import 'log.dart';

final _log = Logger('bw.importer.csv');

/// Small RFC 4180 CSV reader. Detects `,` or `;` from the header line.
///
/// A `"` opens a quoted field only at the start of a field (after optional spaces); anywhere else it is a literal
/// character, so `Pizza 5" wide` stays one field instead of swallowing the rows after it. v1 (SheetJS) reads stray
/// quotes the same way, so descriptions and ids match. A quoted field that never closes takes the rest of the text;
/// with [strict] that is a [FormatException] instead, because the rows after it would be lost silently.
List<List<Object>> readCsv(String text, {bool strict = false}) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final firstLine = text.split('\n').first;
  final sep = ';'.allMatches(firstLine).length > ','.allMatches(firstLine).length ? ';' : ',';
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
    } else if (ch == '"' && field.toString().trim().isEmpty) {
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
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  logImporter(_log, Level.FINE, 'csv.read', {'chars': text.length, 'sep': sep, 'rows': rows.length, 'unclosedQuote': inQuotes});
  if (strict && inQuotes) throw const FormatException('Unclosed quoted field');
  return rows;
}
