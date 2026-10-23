import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

import 'grid.dart';
import 'limits.dart';
import 'log.dart';

final _log = Logger('bw.importer.xlsx');

/// Reads the first worksheet of an .xlsx file into rows of cell values.
/// Numbers come back as `double`, everything else as `String`.
class XlsxReader {
  static bool looksLikeZip(Uint8List b) => b.length > 4 && b[0] == 0x50 && b[1] == 0x4B;

  /// Throws [FileRefused] ([tooLargeMessage]) when the entries' stated sizes add up to more than
  /// [maxXlsxUnpackedBytes], before anything is inflated (the decoder never inflates an entry past its stated size).
  static List<List<Object>> firstSheet(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    var unpacked = 0;
    for (final f in archive.files) {
      unpacked += f.size < 0 ? 0 : f.size;
    }
    if (unpacked > maxXlsxUnpackedBytes) {
      logImporter(_log, Level.WARNING, 'xlsx.tooLarge', {'bytes': bytes.length, 'entries': archive.files.length, 'unpacked': unpacked});
      throw const FileRefused(tooLargeMessage, 'unpackedTooLarge');
    }

    String? text(String name) {
      final f = archive.findFile(name);
      if (f == null) return null;
      final List<int> content = f.content as List<int>;
      return utf8.decode(content, allowMalformed: true);
    }

    final shared = <String>[];
    final sst = text('xl/sharedStrings.xml');
    if (sst != null) {
      final doc = XmlDocument.parse(sst);
      for (final si in doc.findAllElements('si')) {
        // Plain <t> or rich text runs <r><t>; skip phonetic <rPh>.
        final buf = StringBuffer();
        for (final t in si.findAllElements('t')) {
          if (t.parentElement?.name.local == 'rPh') continue;
          buf.write(t.innerText);
        }
        shared.add(buf.toString());
      }
    }

    final sheetPath = _firstSheetPath(text) ?? 'xl/worksheets/sheet1.xml';
    final sheetXml = text(sheetPath) ?? text('xl/worksheets/sheet1.xml');
    if (sheetXml == null) throw const FormatException('No worksheet found in .xlsx');
    final doc = XmlDocument.parse(sheetXml);

    final rows = <int, Map<int, Object>>{};
    var maxCol = -1;
    var autoRow = 0;
    for (final rowEl in doc.findAllElements('row')) {
      final rAttr = int.tryParse(rowEl.getAttribute('r') ?? '');
      final r = (rAttr ?? (autoRow + 1)) - 1;
      autoRow = r + 1;
      var autoCol = 0;
      for (final c in rowEl.findElements('c')) {
        final ref = c.getAttribute('r');
        final col = ref != null ? _colIndex(ref) : autoCol;
        autoCol = col + 1;
        final type = c.getAttribute('t');
        final v = c.getElement('v')?.innerText;
        Object value;
        switch (type) {
          case 's':
            final i = int.tryParse(v ?? '') ?? -1;
            value = i >= 0 && i < shared.length ? shared[i] : '';
          case 'inlineStr':
            value = c.findAllElements('t').map((t) => t.innerText).join();
          case 'str':
          case 'd':
          case 'e':
            value = v ?? '';
          case 'b':
            value = v == '1' ? 'TRUE' : 'FALSE';
          default:
            value = v == null ? '' : (double.tryParse(v) ?? v);
        }
        (rows[r] ??= {})[col] = value;
        if (col > maxCol) maxCol = col;
      }
    }
    // Counts only: cell contents are bank data.
    logImporter(_log, Level.FINE, 'xlsx.sheet',
        {'zipFiles': archive.length, 'strings': shared.length, 'sheetBytes': sheetXml.length, 'rows': rows.length, 'cols': maxCol + 1});
    return sparseRows(rows);
  }

  static String? _firstSheetPath(String? Function(String) text) {
    final wb = text('xl/workbook.xml');
    final rels = text('xl/_rels/workbook.xml.rels');
    if (wb == null || rels == null) return null;
    final sheet = XmlDocument.parse(wb).findAllElements('sheet').firstOrNull;
    if (sheet == null) return null;
    String? rid;
    for (final a in sheet.attributes) {
      if (a.name.local == 'id') rid = a.value;
    }
    if (rid == null) return null;
    for (final rel in XmlDocument.parse(rels).findAllElements('Relationship')) {
      if (rel.getAttribute('Id') == rid) {
        final target = rel.getAttribute('Target') ?? '';
        if (target.startsWith('/')) return target.substring(1);
        return 'xl/$target';
      }
    }
    return null;
  }

  static int _colIndex(String ref) {
    var n = 0;
    for (final ch in ref.codeUnits) {
      if (ch >= 65 && ch <= 90) {
        n = n * 26 + (ch - 64);
      } else if (ch >= 97 && ch <= 122) {
        n = n * 26 + (ch - 96);
      } else {
        break;
      }
    }
    return n - 1;
  }
}
