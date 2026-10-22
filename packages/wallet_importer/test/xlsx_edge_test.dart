// ignore_for_file: missing_whitespace_between_adjacent_strings
// (XML fragments are concatenated on purpose.)
// Edge cases for the .xlsx reader. Every workbook is built in code (SYNTHETIC); expected values are worked out by hand.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/src/xlsx_reader.dart';
import 'package:wallet_importer/wallet_importer.dart';

const _ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"';
const _head = ['Type', 'Product', 'Started Date', 'Completed Date', 'Description', 'Amount', 'Fee', 'Currency', 'State', 'Balance'];

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((name, text) => a.addFile(ArchiveFile.string(name, text)));
  return ZipEncoder().encodeBytes(a);
}

String _sheet(String rows, {String extra = ''}) => '<?xml version="1.0"?><worksheet $_ns><sheetData>$rows</sheetData>$extra</worksheet>';

String _col(int c) => String.fromCharCode(65 + c);

/// A row of inline strings (String), numbers (num) or raw cell XML (_Raw).
class _Raw {
  final String xml;
  const _Raw(this.xml);
}

String _row(int r, List<Object?> cells) {
  final sb = StringBuffer('<row r="$r">');
  for (var c = 0; c < cells.length; c++) {
    final v = cells[c];
    final ref = '${_col(c)}$r';
    if (v == null) continue;
    sb.write(switch (v) {
      _Raw(:final xml) => xml.replaceAll('{ref}', ref),
      num() => '<c r="$ref"><v>$v</v></c>',
      _ => '<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${const HtmlEscape(HtmlEscapeMode.element).convert('$v')}</t></is></c>',
    });
  }
  return '$sb</row>';
}

List<Object?> _tx(Object date, String desc, Object amount, {Object fee = 0, String state = 'COMPLETED'}) =>
    ['Card Payment', 'Current', date, date, desc, amount, fee, 'EUR', state, 0];

Uint8List _book(List<List<Object?>> rows, {Map<String, String> more = const {}}) => _zip({
      'xl/worksheets/sheet1.xml': _sheet([for (var i = 0; i < rows.length; i++) _row(i + 1, rows[i])].join()),
      ...more
    });

ImportBatch _imp(List<List<Object?>> txRows) => importBankFile(_book([_head, ...txRows]));

final _unknown = throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('I recognise')));
final _damaged = throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('Could not read')));

void main() {
  group('workbook structure', () {
    test('no sharedStrings.xml: t="s" cells read as empty, inline strings still work', () {
      final b = _zip({
        'xl/worksheets/sheet1.xml': _sheet(
            '${_row(1, _head)}<row r="2"><c r="A2" t="s"><v>0</v></c><c r="C2" t="inlineStr"><is><t>2026-02-01</t></is></c>'
            '<c r="E2" t="inlineStr"><is><t>Shop</t></is></c><c r="F2"><v>-2.5</v></c><c r="I2" t="inlineStr"><is><t>COMPLETED</t></is></c></row>'),
      });
      final batch = importBankFile(b);
      expect(batch.transactions.single.amountMinor, -250);
      expect(batch.transactions.single.bankType, '', reason: 'the t="s" cell has no table to read from');
    });

    test('shared strings: out-of-range or non-numeric indexes give empty cells, rich text runs are joined, phonetic text is dropped', () {
      const sst = '<sst $_ns><si><t>Started Date</t></si><si><t>Description</t></si><si><t>Amount</t></si>'
          '<si><r><t>Sh</t></r><r><t>op</t></r><rPh><t>PHONETIC</t></rPh></si><si><t>2026-02-01</t></si></sst>';
      final sheet = _sheet('<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>'
          '<row r="2"><c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>3</v></c><c r="C2"><v>-1.25</v></c></row>'
          '<row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" t="s"><v>99</v></c><c r="C3"><v>-2</v></c></row>'
          '<row r="4"><c r="A4" t="s"><v>4</v></c><c r="B4" t="s"><v>abc</v></c><c r="C4"><v>-3</v></c></row>');
      final b = importBankFile(_zip({'xl/worksheets/sheet1.xml': sheet, 'xl/sharedStrings.xml': sst}));
      expect(b.transactions.map((t) => t.description), ['Shop', '', '']);
      expect(b.transactions.map((t) => t.amountMinor), [-125, -200, -300]);
    });

    test('entities, CDATA and surrounding spaces in strings', () {
      final b = _imp([
        _tx('2026-02-01', 'A & B <ltd> "q"', -1),
        _tx('2026-02-02', '  padded  ', -2),
      ]);
      expect(b.transactions.map((t) => t.description), ['A & B <ltd> "q"', 'padded']);
      final cdata = _zip({
        'xl/worksheets/sheet1.xml': _sheet('${_row(1, ['Started Date', 'Description', 'Amount'])}'
            '<row r="2"><c r="A2" t="inlineStr"><is><t>2026-02-01</t></is></c><c r="B2" t="inlineStr"><is><t><![CDATA[x < y & z]]></t></is></c>'
            '<c r="C2"><v>-1</v></c></row>'),
      });
      expect(importBankFile(cdata).transactions.single.description, 'x < y & z');
    });

    test('empty sheet, sheet with only a header, and sheet with only blank rows', () {
      expect(() => importBankFile(_zip({'xl/worksheets/sheet1.xml': _sheet('')})), _unknown);
      expect(() => importBankFile(_zip({'xl/worksheets/sheet1.xml': '<worksheet $_ns/>'})), _unknown);
      expect(() => importBankFile(_zip({'xl/worksheets/sheet1.xml': _sheet('<row r="1"/><row r="2"/>')})), _unknown);
      final headerOnly = importBankFile(_book([_head]));
      expect(headerOnly.source, 'revolut');
      expect(headerOnly.transactions, isEmpty);
    });

    test('a zip without any worksheet, or a different kind of zip, is refused', () {
      expect(() => importBankFile(_zip({'readme.txt': 'hi'})), _damaged);
      expect(() => importBankFile(_zip({'word/document.xml': '<w:document/>', '[Content_Types].xml': '<Types/>'})), _damaged);
      expect(() => importBankFile(_zip({})), _damaged);
    });

    test('corrupted zips: truncated, garbage in the middle, wrong signature after PK', () {
      final good = _book([_head, _tx('2026-02-01', 'Shop', -1)]);
      expect(() => importBankFile(Uint8List.sublistView(good, 0, good.length ~/ 2)), throwsA(isA<ImportException>()));
      expect(() => importBankFile(Uint8List.sublistView(good, 0, 30)), throwsA(isA<ImportException>()));
      final flipped = Uint8List.fromList(good);
      for (var i = 40; i < flipped.length - 40; i += 3) {
        flipped[i] ^= 0xFF;
      }
      expect(() => importBankFile(flipped), throwsA(isA<ImportException>()));
      expect(() => importBankFile(Uint8List.fromList([0x50, 0x4B, 0x09, 0x09, ...List.filled(200, 7)])), _damaged);
    });

    test('the first sheet listed in workbook.xml is used, wherever its file is; relative and absolute targets both work', () {
      String sheetWith(String desc) => _sheet(_row(1, ['Started Date', 'Description', 'Amount']) + _row(2, ['2026-02-01', desc, -1]));
      const wb = '<workbook $_ns xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          '<sheet name="B" sheetId="2" r:id="rId9"/><sheet name="A" sheetId="1" r:id="rId1"/></sheets></workbook>';
      for (final target in ['worksheets/sheet2.xml', '/xl/worksheets/sheet2.xml']) {
        final rels =
            '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId9" Target="$target"/></Relationships>';
        final b = importBankFile(_zip({
          'xl/workbook.xml': wb,
          'xl/_rels/workbook.xml.rels': rels,
          'xl/worksheets/sheet1.xml': sheetWith('first file, second tab'),
          'xl/worksheets/sheet2.xml': sheetWith('first tab'),
        }));
        expect(b.transactions.single.description, 'first tab', reason: target);
      }
    });

    test('a relationship pointing to a file that is not there falls back to sheet1.xml', () {
      const wb = '<workbook $_ns xmlns:r="x"><sheets><sheet name="A" sheetId="1" r:id="rId1"/></sheets></workbook>';
      final b = importBankFile(_zip({
        'xl/workbook.xml': wb,
        'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="rId1" Target="worksheets/gone.xml"/></Relationships>',
        'xl/worksheets/sheet1.xml': _sheet(_row(1, ['Started Date', 'Description', 'Amount']) + _row(2, ['2026-02-01', 'x', -1])),
      }));
      expect(b.transactions.single.amountMinor, -100);
    });

    test('a damaged workbook.xml or sharedStrings.xml is an ImportException', () {
      final sheet = _sheet('');
      expect(
          () => importBankFile(
              _zip({'xl/workbook.xml': '<workbook><sheets>', 'xl/_rels/workbook.xml.rels': '<R/>', 'xl/worksheets/sheet1.xml': sheet})),
          _damaged);
      expect(() => importBankFile(_zip({'xl/sharedStrings.xml': '<sst><si><t>', 'xl/worksheets/sheet1.xml': sheet})), _damaged);
      expect(() => importBankFile(_zip({'xl/worksheets/sheet1.xml': '<?xml version="1.0"?><worksheet><sheetData><row'})), _damaged);
    });
  });

  group('cells', () {
    test('rows and cells out of order, gaps, and columns past Z', () {
      final sheet = _sheet(
          '<row r="3"><c r="C3" t="inlineStr"><is><t>Shop</t></is></c><c r="A3" t="inlineStr"><is><t>2026-02-01</t></is></c><c r="E3"><v>-4</v></c></row>'
          '<row r="1"><c r="AA1" t="inlineStr"><is><t>far</t></is></c><c r="A1" t="inlineStr"><is><t>Started Date</t></is></c>'
          '<c r="C1" t="inlineStr"><is><t>Description</t></is></c><c r="E1" t="inlineStr"><is><t>Amount</t></is></c></row>');
      final rows = XlsxReader.firstSheet(_zip({'xl/worksheets/sheet1.xml': sheet}));
      expect(rows.length, 3);
      expect(rows[0].length, 27);
      expect(rows[0][26], 'far');
      expect(rows[1], isEmpty);
      expect(rows[2], ['2026-02-01', '', 'Shop', '', -4.0]);
      final b = importBankFile(_zip({'xl/worksheets/sheet1.xml': sheet}));
      expect(b.transactions.single.amountMinor, -400);
    });

    test('merged cells: only the top-left cell has a value, the merge element is ignored', () {
      final sheet = _sheet(
          _row(1, ['Started Date', 'Description', 'Amount']) + _row(2, ['2026-02-01', 'Shop', -1]) + _row(3, ['2026-02-02', 'Other', -2]),
          extra: '<mergeCells count="1"><mergeCell ref="B2:B3"/></mergeCells>');
      final b = importBankFile(_zip({'xl/worksheets/sheet1.xml': sheet}));
      expect(b.transactions.map((t) => t.description), ['Shop', 'Other']);
    });

    test('numbers: exponent, negative, padded and comma-decimal text', () {
      final b = _imp([
        _tx('2026-02-01', 'a', const _Raw('<c r="{ref}"><v>-1.5E-1</v></c>')),
        _tx('2026-02-02', 'b', const _Raw('<c r="{ref}"><v> -2.25 </v></c>')),
        _tx('2026-02-03', 'c', const _Raw('<c r="{ref}" t="inlineStr"><is><t>-3,10</t></is></c>')),
        _tx('2026-02-04', 'd', const _Raw('<c r="{ref}" t="str"><v>1.234,56</v></c>')),
      ]);
      expect(b.transactions.map((t) => t.amountMinor), [-15, -225, -310, 123456]);
    });

    test('formula cells use their cached value; a formula without one leaves the row out', () {
      final b = _imp([
        _tx('2026-02-01', 'a', const _Raw('<c r="{ref}"><f>1+1</f><v>-2</v></c>')),
        _tx('2026-02-02', 'b', const _Raw('<c r="{ref}"><f>1+1</f></c>')),
      ]);
      expect(b.transactions.map((t) => t.description), ['a']);
    });

    test('error, boolean and empty-value cells never become amounts', () {
      final b = _imp([
        _tx('2026-02-01', 'err', const _Raw('<c r="{ref}" t="e"><v>#DIV/0!</v></c>')),
        _tx('2026-02-02', 'bool', const _Raw('<c r="{ref}" t="b"><v>1</v></c>')),
        _tx('2026-02-03', 'none', const _Raw('<c r="{ref}"/>')),
        _tx('2026-02-04', 'ok', -5),
      ]);
      expect(b.transactions.map((t) => t.description), ['ok']);
    });

    test('cell references in lower case and rows without r attributes are placed in order', () {
      final sheet = _sheet(
          '<row><c t="inlineStr"><is><t>Started Date</t></is></c><c t="inlineStr"><is><t>Description</t></is></c><c t="inlineStr"><is><t>Amount</t></is></c></row>'
          '<row><c t="inlineStr"><is><t>2026-02-01</t></is></c><c t="inlineStr"><is><t>x</t></is></c><c><v>-9</v></c></row>');
      expect(importBankFile(_zip({'xl/worksheets/sheet1.xml': sheet})).transactions.single.amountMinor, -900);
      final lower = _sheet(
          '<row r="1"><c r="a1" t="inlineStr"><is><t>Started Date</t></is></c><c r="b1" t="inlineStr"><is><t>Description</t></is></c>'
          '<c r="c1" t="inlineStr"><is><t>Amount</t></is></c></row><row r="2"><c r="a2" t="inlineStr"><is><t>2026-02-01</t></is></c>'
          '<c r="b2" t="inlineStr"><is><t>x</t></is></c><c r="c2"><v>-9</v></c></row>');
      expect(importBankFile(_zip({'xl/worksheets/sheet1.xml': lower})).transactions.single.amountMinor, -900);
    });
  });

  group('dates', () {
    // Excel serials: 46037 = 2026-01-15 (the existing fixture test), so 46054 = 2026-02-01, 45292 = 2024-01-01,
    // 44927 = 2023-01-01, 45351 = 2024-02-29 (31 + 28 days after Jan 1, 2024: 45292 + 59), 45352 = 2024-03-01.
    test('serial numbers with a time part keep the day: 00:00, noon and 23:59:59', () {
      final b = _imp([
        _tx(46054.0, 'a', -1),
        _tx(46054.5, 'b', -1),
        _tx(46054 + 86399 / 86400, 'c', -1),
        _tx(46055.0, 'd', -1),
      ]);
      expect(b.transactions.map((t) => t.date), ['2026-02-01', '2026-02-01', '2026-02-01', '2026-02-02']);
    });

    test('month ends and the 2024 leap day', () {
      final b = _imp([_tx(45292, 'a', -1), _tx(45351, 'b', -1), _tx(45352, 'c', -1), _tx(44927, 'd', -1)]);
      expect(b.transactions.map((t) => t.date), ['2024-01-01', '2024-02-29', '2024-03-01', '2023-01-01']);
    });

    test('serials 1 to 60 sit before the 1900 leap-year bug and are not bank dates; 61 onwards is the real calendar from 1900-03-01', () {
      // Excel counts a day 1900-02-29 that never existed, so serial 61 is 1900-03-01 and serial 60 has no real date.
      final b = _imp([_tx(61, 'a', -1)]);
      expect(b.transactions.single.date, '1900-03-01');
    });

    test('out-of-range serials leave the row out and count it: 0, negative, beyond 9999-12-31', () {
      final b = _imp([_tx(0, 'a', -1), _tx(-5, 'b', -1), _tx(2958466, 'c', -1), _tx(1e12, 'd', -1), _tx(2958465, 'ok', -1)]);
      expect(b.transactions.map((t) => t.description), ['ok']);
      expect(b.transactions.single.date, '9999-12-31');
      expect(b.invalid, 4);
    });

    test('ISO date cells (t="d") and ISO text with time or zone read as the written day', () {
      final b = _imp([
        _tx(const _Raw('<c r="{ref}" t="d"><v>2026-02-01T23:59:59Z</v></c>'), 'a', -1),
        _tx('2026-03-31T23:30:00+02:00', 'b', -1),
        _tx('1.2.2026', 'c', -1),
      ]);
      expect(b.transactions.map((t) => t.date), ['2026-02-01', '2026-03-31', '2026-02-01']);
    });

    test('the 1904 date system is not detected: a serial is read in the 1900 system (documents the limit)', () {
      // workbookPr date1904="1" shifts every date by 1462 days. Bank exports never use it; the importer ignores it.
      const wb = '<workbook $_ns><workbookPr date1904="1"/><sheets/></workbook>';
      final b = importBankFile(_book([_head, _tx(46054, 'a', -1)], more: {'xl/workbook.xml': wb}));
      expect(b.transactions.single.date, '2026-02-01');
    });
  });

  group('PBZ-style sheet in xlsx', () {
    test('Excel serial dates in column A, header block and card holds', () {
      final rows = [
        ['PBZ'],
        ['TRANSAKCIJSKI RAČUN:', 'HR00'],
        ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
        [46037, 'Plaća/Mirovina', 'Neto plaća', 1500, 'EUR'],
        [46038, 'POS plaćanje', 'REZERVACIJA SHOP', -3, 'EUR'],
        [46038, 'POS plaćanje', 'Shop', -3.333, 'EUR'],
        [29999, 'Old', 'before the serial threshold', -1, 'EUR'],
      ];
      final b = importBankFile(_book(rows));
      expect(b.source, 'pbz');
      expect(b.skipped, 1);
      expect(b.transactions.map((t) => (t.date, t.amountMinor)), [('2026-01-15', 150000), ('2026-01-16', -333)]);
    });
  });
}
