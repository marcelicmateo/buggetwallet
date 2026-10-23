// ignore_for_file: missing_whitespace_between_adjacent_strings
// Stage H12 (importer): a header that only looks like PBZ's, "same month, newer template" per bank (ids must not
// change), password-protected workbooks, size and decompression limits, a bill PDF whose amount column is right
// aligned. Written from the Stage H spec (H4) and the formats in docs/context/IMPORT_FORMATS.md; a test of behaviour
// the build does not have yet skips with `BUG: H4`. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/biff.dart';

const _t = Timeout(Duration(seconds: 55));

List<String> _view(ImportBatch b) => [for (final t in b.transactions) '${t.id}|${t.date}|${t.amountMinor}|${t.bankType}|${t.description}'];

const _pbzHeader = ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'];

void main() {
  group('PBZ detection needs the whole header (H4)', () {
    const skipH4 = 'BUG: H4 - PbzProfile.detect accepts any sheet with a DATUM cell or the account label';

    test('the real header tuple on one row is PBZ (and the synthetic fixture still imports)', () {
      final b = parseRows([
        ['', 'TRANSAKCIJSKI RAČUN:', '', '', ''],
        _pbzHeader,
        ['10.01.2026', 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', '-23,40', 'EUR'],
      ]);
      expect(b?.source, 'pbz');
      expect(b!.transactions.single.amountMinor, -2340);
      final fixture = importBankFile(File('test/fixtures/pbz_synthetic.xls').readAsBytesSync());
      expect(fixture.source, 'pbz');
    }, timeout: _t);

    test('another bank\'s sheet with a DATUM column is not PBZ: no rows, no wrong columns', () {
      final other = [
        ['Izvod po računu'],
        ['DATUM', 'OPIS', 'UPLATA', 'ISPLATA', 'SALDO'],
        ['10.01.2026', 'Kupnja SYNTH SHOP', '', '12,30', '100,00'],
        ['11.01.2026', 'Uplata plaće', '1500,00', '', '1600,00'],
      ];
      expect(parseRows(other), isNull, reason: 'it must be refused, not read with PBZ\'s fixed columns');
      expect(() => importBankFile(_csv(other)), throwsA(isA<ImportException>().having((e) => e.message, 'message', unknownLayoutMessage)));
    }, skip: skipH4, timeout: _t);

    test('a header that holds only some of the five names is not PBZ', () {
      for (final partial in [
        ['DATUM'],
        ['DATUM', 'IZNOS'],
        ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS'],
        ['VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
      ]) {
        expect(
            parseRows([
              partial,
              ['10.01.2026', 'x', 'y', '-1,00', 'EUR']
            ]),
            isNull,
            reason: '$partial');
      }
    }, skip: skipH4, timeout: _t);

    test('the names must share one row: a title row with DATUM above a row with the rest is not the tuple', () {
      expect(
          parseRows([
            ['DATUM'],
            ['VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
            ['10.01.2026', 'x', 'y', '-1,00', 'EUR'],
          ]),
          isNull);
    }, skip: skipH4, timeout: _t);

    test('the account label alone does not make a PBZ file', () {
      expect(
          parseRows([
            ['TRANSAKCIJSKI RAČUN:', 'HR0000000000000000000'],
            ['Datum', 'Iznos'],
            ['10.01.2026', '-5,00'],
          ]),
          isNull);
    }, skip: skipH4, timeout: _t);

    test('a Revolut sheet that also has a DATUM cell is still Revolut', () {
      final b = parseRows([
        ['Type', 'Product', 'Started Date', 'Completed Date', 'Description', 'Amount', 'Fee', 'Currency', 'State', 'Balance'],
        ['Card Payment', 'Current', '2026-01-03 12:15:00', '2026-01-04 08:15:00', 'DATUM café', '-14.50', '0', 'EUR', 'COMPLETED', '35.50'],
      ]);
      expect(b?.source, 'revolut');
    }, timeout: _t);
  });

  group('same month, newer template: the same rows keep their ids', () {
    // Older and newer layouts of one month. A bank that moves its header, adds a column or changes how it writes a
    // date must not make a re-import of the same month add every row a second time.
    const rows = [
      ('10.01.2026', 'Plaća/Mirovina', 'Neto plaća za 12/2025', '1.500,00'),
      ('10.01.2026', 'POS plaćanje', 'POS Revolut**0000* Dublin', '-50,00'),
      ('10.01.2026', 'POS plaćanje', 'POS Revolut**0000* Dublin', '-50,00'),
      ('12.01.2026', 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', '-23,40'),
      ('14.01.2026', 'Naplaćene naknade', 'Naknada On-line bankarstvo - kreditni transfer', '-0,33'),
    ];

    test('PBZ: header moved down, a title block, an extra balance column, a totals footer', () {
      final older = parseRows([
        ['', 'TRANSAKCIJSKI RAČUN:', '', '', ''],
        ['', 'HR0000000000000000000', '', '', ''],
        _pbzHeader,
        for (final (d, t, m, a) in rows) [d, t, m, a, ' EUR '],
      ])!;
      final newer = parseRows([
        ['IZVOD PROMETA PO RAČUNU', '', '', '', '', ''],
        ['', 'TRANSAKCIJSKI RAČUN:', '', '', '', ''],
        ['', 'HR0000000000000000000', '', '', '', ''],
        ['Datum ispisa:', '01.02.2026', '', '', '', ''],
        ['', '', '', '', '', ''],
        [..._pbzHeader, 'STANJE'],
        for (final (i, (d, t, m, a)) in rows.indexed) [d, t, m, a, 'EUR', '${1000 + i},00'],
        ['UKUPNO', '', '', '1.426,77', '', ''],
      ])!;
      expect(_view(newer), _view(older));
      expect(older.transactions.length, rows.length);
      expect(older.transactions.where((t) => t.id.endsWith('_1')), hasLength(1), reason: 'the second identical row is occurrence 1');
    }, timeout: _t);

    test('PBZ: dates as serial numbers in one template and as text in the next give the same ids', () {
      List<List<Object>> sheet(Object d1) => [
            ['', 'TRANSAKCIJSKI RAČUN:', '', '', ''],
            _pbzHeader,
            [d1, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', -23.4, 'EUR'],
          ];
      expect(_view(parseRows(sheet('12.01.2026'))!), _view(parseRows(sheet(46034.0833))!)); // 46034 = 2026-01-12
      expect(_view(parseRows(sheet(46034.0833))!).single, contains('|2026-01-12|-2340|'));
    }, timeout: _t);

    final revHead = ['Type', 'Product', 'Started Date', 'Completed Date', 'Description', 'Amount', 'Fee', 'Currency', 'State', 'Balance'];
    const revRows = [
      ['Topup', 'Current', '2026-01-03 10:15:00', '2026-01-03 10:15:00', 'Top-up by *0000', '50.00', '0.00', 'EUR', 'COMPLETED', '50.00'],
      ['Card Payment', 'Current', '2026-01-03 12:15:00', '2026-01-04 08:15:00', 'Wolt', '-14.50', '0.00', 'EUR', 'COMPLETED', '35.50'],
      ['Card Payment', 'Current', '2026-01-07 09:15:00', '2026-01-07 09:15:00', 'Wolt', '-14.50', '0.00', 'EUR', 'COMPLETED', '21.00'],
      ['Card Payment', 'Current', '2026-01-07 09:15:00', '2026-01-07 09:15:00', 'Wolt', '-14.50', '0.00', 'EUR', 'COMPLETED', '6.50'],
      ['Card Payment', 'Current', '2026-01-09 12:00:00', '', 'Example Cafe', '-3.00', '0.00', 'EUR', 'PENDING', '3.50'],
    ];

    test('Revolut: columns reordered, extra columns added, a BOM and CRLF line ends, quoted header', () {
      final older = importBankFile(_csv([revHead, ...revRows]));
      // Newer export: Started Date first, two new columns, Balance dropped.
      final order = [2, 0, 1, 4, 5, 6, 7, 8, 3];
      List<String> reorder(List<String> r) => [for (final i in order) r[i], 'REF-0001', 'Main'];
      final newerText = '\u{FEFF}${[
        reorder(revHead)..[9] = 'Reference',
        for (final r in revRows) reorder(r),
      ].map((r) => r.map((c) => '"$c"').join(',')).join('\r\n')}\r\n';
      final newer = importBankFile(Uint8List.fromList(utf8.encode(newerText)));
      expect(_view(newer), _view(older));
      expect(older.transactions.length, 4, reason: 'the pending row is skipped');
      expect(older.skipped, 1);
    }, timeout: _t);

    test('Revolut: an .xlsx and a .csv of the same rows give the same ids', () {
      final csv = importBankFile(_csv([revHead, ...revRows]));
      final xlsx = importBankFile(_xlsx([revHead, ...revRows]));
      expect(_view(xlsx), _view(csv));
    }, timeout: _t);
  });

  group('password-protected and oversized files (H4)', () {
    test('an .xls with a FILEPASS record says it is password-protected, not damaged', () {
      final cells = [...labelSst(0, 0, 0), ...labelSst(1, 0, 1)];
      final sstRecs = sst(2, [...sstString('TRANSAKCIJSKI RAČUN:', wide: true), ...sstString('DATUM')]);
      final bytes = ole2(workbook([
        cells
      ], sstRecords: [
        ...rec(0x002F, [1, 0, 1, 0, 1, 0]),
        ...sstRecs
      ]));
      expect(
          () => importBankFile(bytes),
          throwsA(isA<ImportException>()
              .having((e) => e.message.toLowerCase(), 'message', allOf(contains('password'), isNot(contains('damaged'))))));
    }, skip: 'BUG: H4 - FILEPASS is not detected: an encrypted .xls is reported as damaged or unknown', timeout: _t);

    test('a file over 20 MiB is refused up front; exactly 20 MiB is not refused for its size', () {
      const cap = 20 * 1024 * 1024;
      Object? message(int n) {
        try {
          importBankFile(Uint8List(n));
        } on ImportException catch (e) {
          return e.message;
        }
        return null;
      }

      final over = message(cap + 1);
      expect(over, isNotNull);
      expect(over, isNot(unknownLayoutMessage));
      expect(over.toString().toLowerCase(), contains('large'), reason: 'a size message, not a layout one');
      expect(message(cap), isNot(over), reason: 'the limit is inclusive');
    }, skip: 'BUG: H4 - importBankFile has no size cap (maxImportBytes = 20 MiB)', timeout: _t);

    test('an .xlsx that inflates to far more than it weighs is refused, quickly', () {
      final bytes = _zipWith({'xl/worksheets/sheet1.xml': _hugeSheet(120 << 20)});
      expect(bytes.length, lessThan(2 << 20), reason: 'a bomb: ~100 KB on disk');
      final sw = Stopwatch()..start();
      expect(
          () => importBankFile(bytes),
          throwsA(isA<ImportException>()
              .having((e) => e.message, 'message', isNot(unknownLayoutMessage))
              .having((e) => e.message.toLowerCase(), 'message', contains('too large'))),
          reason: 'the header is valid Revolut: only the size limit may refuse it, and it says so');
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    }, skip: 'BUG: H4 - XlsxReader has no inflate cap (a 120 MiB sheet is read in full)', timeout: _t);

    test('an .xlsx whose directory lies about the size never yields rows from the 120 MiB it really holds, and fails fast', () {
      final bytes = _zipWith({'xl/worksheets/sheet1.xml': _hugeSheet(120 << 20)}, lieAboutSize: true);
      final sw = Stopwatch()..start();
      expect(() => importBankFile(bytes), throwsA(isA<ImportException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    }, skip: 'BUG: H4 - XlsxReader has no inflate cap', timeout: _t);

    test('an ordinary workbook still opens next to the cap (the fixture and a 3 MiB sheet)', () {
      expect(importBankFile(File('test/fixtures/revolut_synthetic.xlsx').readAsBytesSync()).source, 'revolut');
      final rowsXml = StringBuffer();
      for (var i = 0; i < 20000; i++) {
        rowsXml.write(
            '<row r="${i + 2}"><c r="C${i + 2}" t="inlineStr"><is><t>2026-01-03 10:15:00</t></is></c><c r="E${i + 2}" t="inlineStr"><is><t>Wolt $i</t></is></c>'
            '<c r="F${i + 2}"><v>-1.5</v></c></row>');
      }
      final sheet = '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
          '<row r="1"><c r="C1" t="inlineStr"><is><t>Started Date</t></is></c><c r="E1" t="inlineStr"><is><t>Description</t></is></c>'
          '<c r="F1" t="inlineStr"><is><t>Amount</t></is></c></row>$rowsXml</sheetData></worksheet>';
      final b = importBankFile(_zipWith({'xl/worksheets/sheet1.xml': sheet}));
      expect(b.transactions.length, 20000);
    }, timeout: _t);
  });

  group('bill PDF with a right-aligned amount column', () {
    // Helvetica widths (per 1000 em): digits 556, comma 278, space 278, euro 556.
    double width(String s, double size) => s.codeUnits.fold<double>(0, (w, c) => w + (c == 0x2C || c == 0x20 ? 278 : 556) * size / 1000);

    Uint8List page(List<(double, double, String)> texts) {
      final sb = StringBuffer();
      for (final (x, y, s) in texts) {
        sb.write('BT /F1 11 Tf ${x.toStringAsFixed(2)} ${y.toStringAsFixed(2)} Td ($s) Tj ET\n');
      }
      return _pdf(latin1.encode(sb.toString()));
    }

    // Item rows: name at x=50, quantity at x=250, line total right aligned at x=520 (so every total starts elsewhere).
    List<(double, double, String)> items({bool amountsFirst = false, double jitter = 0}) {
      final rows = [('Cokolada', '2 x 1,50', '3,00'), ('Kava', '1 x 9,34', '9,34'), ('Sok od jabuke', '3 x 12,00', '36,00')];
      final out = <(double, double, String)>[];
      for (final (i, (name, qty, amount)) in rows.indexed) {
        final y = 700.0 - 20 * i;
        final right = (520 - width(amount, 11), y + jitter, amount);
        final left = [(50.0, y, name), (250.0, y, qty)];
        out.addAll(amountsFirst ? [right, ...left] : [...left, right]);
      }
      const total = '48,34';
      out.addAll([(50.0, 620.0, 'Ukupno:'), (520 - width('$total EUR', 11), 620.0, '$total EUR')]);
      return out;
    }

    void expectTotal(Uint8List pdf) {
      final b = billFromText(pdfText(pdf)!, source: BillSource.pdf)!;
      expect(b.total, 4834, reason: pdfText(pdf));
    }

    test('amounts of different widths, each ending on the same right edge, read in the order of the page', () {
      final text = pdfText(page(items()))!;
      expect(text.split('\n').take(3), ['Cokolada 2 x 1,50 3,00', 'Kava 1 x 9,34 9,34', 'Sok od jabuke 3 x 12,00 36,00'], reason: text);
      expectTotal(page(items()));
    }, timeout: _t);

    test('the right column written first in the content stream: the total is still found', () {
      expectTotal(page(items(amountsFirst: true)));
    }, timeout: _t);

    test('a baseline half a point off (smaller type in the amount column): the total is still found', () {
      expectTotal(page(items(jitter: -0.5)));
    }, timeout: _t);

    test('a total line far to the right is not glued to the next row or split from its label', () {
      final text = pdfText(page(items()))!;
      expect(text.split('\n').last, 'Ukupno: 48,34 EUR');
    }, timeout: _t);
  });
}

Uint8List _csv(List<List<String>> rows) =>
    Uint8List.fromList(utf8.encode('${rows.map((r) => r.map((c) => '"$c"').join(',')).join('\n')}\n'));

/// A sheet with a valid Revolut header row first (so only a size limit can refuse it) and [bytes] of padding after it.
String _hugeSheet(int bytes) {
  const head = '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
      '<row r="1"><c r="C1" t="inlineStr"><is><t>Started Date</t></is></c><c r="E1" t="inlineStr"><is><t>Description</t></is></c>'
      '<c r="F1" t="inlineStr"><is><t>Amount</t></is></c></row>'
      '<row r="2"><c r="C2" t="inlineStr"><is><t>2026-01-03 10:15:00</t></is></c><c r="E2" t="inlineStr"><is><t>Wolt</t></is></c>'
      '<c r="F2"><v>-1.5</v></c><c r="K2" t="inlineStr"><is><t xml:space="preserve">';
  return '$head${' ' * bytes}</t></is></c></row></sheetData></worksheet>';
}

/// A minimal xlsx container (content types, workbook, relationships) plus [extra] parts, deflated with the native codec so
/// that a bomb is cheap to build. [lieAboutSize] writes a small uncompressed size into the directory entries.
Uint8List _zipWith(Map<String, String> extra, {bool lieAboutSize = false}) {
  final parts = <String, String>{
    '[Content_Types].xml':
        '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>',
    'xl/workbook.xml':
        '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
    ...extra,
  };
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final MapEntry(key: name, value: text) in parts.entries) {
    final raw = utf8.encode(text);
    final deflated = ZLibCodec(raw: true, level: 9).encode(raw);
    final crc = getCrc32(raw);
    final nameBytes = utf8.encode(name);
    final declared = lieAboutSize ? 1000 : raw.length;
    final offset = out.length;
    List<int> le(int v, int n) => [for (var i = 0; i < n; i++) (v >> (8 * i)) & 0xff];
    out
      ..add([0x50, 0x4b, 0x03, 0x04, ...le(20, 2), ...le(0, 2), ...le(8, 2), ...le(0, 2), ...le(0x21, 2)])
      ..add([...le(crc, 4), ...le(deflated.length, 4), ...le(declared, 4), ...le(nameBytes.length, 2), ...le(0, 2)])
      ..add(nameBytes)
      ..add(deflated);
    central
      ..add([0x50, 0x4b, 0x01, 0x02, ...le(20, 2), ...le(20, 2), ...le(0, 2), ...le(8, 2), ...le(0, 2), ...le(0x21, 2)])
      ..add([...le(crc, 4), ...le(deflated.length, 4), ...le(declared, 4), ...le(nameBytes.length, 2), ...le(0, 2), ...le(0, 2)])
      ..add([...le(0, 2), ...le(0, 2), ...le(0, 4), ...le(offset, 4)])
      ..add(nameBytes);
    count++;
  }
  final dirStart = out.length;
  final dir = central.toBytes();
  out
    ..add(dir)
    ..add([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, count & 0xff, count >> 8, count & 0xff, count >> 8])
    ..add([dir.length & 0xff, (dir.length >> 8) & 0xff, (dir.length >> 16) & 0xff, (dir.length >> 24) & 0xff])
    ..add([dirStart & 0xff, (dirStart >> 8) & 0xff, (dirStart >> 16) & 0xff, (dirStart >> 24) & 0xff, 0, 0]);
  return out.toBytes();
}

/// A small xlsx of inline strings from [rows].
Uint8List _xlsx(List<List<String>> rows) {
  final sb = StringBuffer();
  for (final (r, row) in rows.indexed) {
    sb.write('<row r="${r + 1}">');
    for (final (c, v) in row.indexed) {
      final ref = '${String.fromCharCode(65 + c)}${r + 1}';
      sb.write('<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${const HtmlEscape(HtmlEscapeMode.element).convert(v)}</t></is></c>');
    }
    sb.write('</row>');
  }
  return _zipWith({
    'xl/worksheets/sheet1.xml':
        '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>$sb</sheetData></worksheet>'
  });
}

/// A one-page PDF with [content] as the page stream and Helvetica (WinAnsi) as /F1.
Uint8List _pdf(List<int> content) {
  final objs = <List<int>>[
    latin1.encode('<</Type/Catalog/Pages 2 0 R>>'),
    latin1.encode('<</Type/Pages/Kids[3 0 R]/Count 1>>'),
    latin1.encode('<</Type/Page/Parent 2 0 R/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>'),
    [...latin1.encode('<</Length ${content.length}>>\nstream\n'), ...content, ...latin1.encode('\nendstream')],
    latin1.encode('<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>'),
  ];
  final out = BytesBuilder()..add(latin1.encode('%PDF-1.4\n'));
  final offs = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offs.add(out.length);
    out
      ..add(latin1.encode('${i + 1} 0 obj\n'))
      ..add(objs[i])
      ..add(latin1.encode('\nendobj\n'));
  }
  final x = out.length;
  out.add(latin1.encode('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offs.map((o) => '${'$o'.padLeft(10, '0')} 00000 n \n').join()}'
      'trailer\n<</Size ${objs.length + 1}/Root 1 0 R>>\nstartxref\n$x\n%%EOF\n'));
  return out.toBytes();
}
