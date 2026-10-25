// Edge cases for the CSV reader, amount/date parsing and format detection. Inputs are built in code (SYNTHETIC).
// Expected values are worked out by hand from the rules in docs/context/IMPORT_FORMATS.md, not from the implementation.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/csv_reader.dart';
import 'package:wallet_importer/wallet_importer.dart';

const _hdr = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// A Revolut row; [amount], [fee] and [date] are written as given.
String _r(String date, String desc, String amount,
        {String fee = '0.00', String state = 'COMPLETED', String cur = 'EUR', String type = 'Card Payment'}) =>
    '$type,Current,"$date","$date",$desc,"$amount","$fee",$cur,$state,0.00';

ImportBatch _imp(String text) => importBankFile(_b(text));
ImportBatch _rev(List<String> rows, {String eol = '\n'}) => _imp('$_hdr$eol${rows.join(eol)}$eol');

/// Amounts of every imported row, in order.
List<int> _amounts(ImportBatch b) => [for (final t in b.transactions) t.amountMinor];

void main() {
  group('readCsv: framing', () {
    test('LF, CRLF, CR and mixed endings give the same rows', () {
      const rows = [
        ['a', 'b'],
        ['c', 'd'],
        ['e', 'f'],
      ];
      expect(readCsv('a,b\nc,d\ne,f'), rows);
      expect(readCsv('a,b\r\nc,d\r\ne,f'), rows);
      expect(readCsv('a,b\rc,d\re,f'), rows);
      expect(readCsv('a,b\nc,d\r\ne,f\r'), rows);
    });

    test('blank lines anywhere (also CRLF-only ones) are skipped, a trailing separator keeps its empty field', () {
      expect(readCsv('\n\r\na,b\n\n\r\nc,\n\n'), [
        ['a', 'b'],
        ['c', ''],
      ]);
      expect(readCsv(''), isEmpty);
      expect(readCsv('\n\n\r\n'), isEmpty);
    });

    test('quoted fields: separator, escaped quote, newline (LF and CRLF) and a lone quoted empty string', () {
      expect(readCsv('"a,b","say ""hi""","x\ny","p\r\nq",""\n'), [
        ['a,b', 'say "hi"', 'x\ny', 'p\r\nq', ''],
      ]);
      // A line that is just "" is a blank line, not a row with one empty cell.
      expect(readCsv('a\n""\nb\n'), [
        ['a'],
        ['b'],
      ]);
    });

    test('a quote after a quoted field closes it and the rest continues unquoted', () {
      expect(readCsv('"ab"cd,e\n'), [
        ['abcd', 'e'],
      ]);
    });

    test('a quote is literal unless it is the first character of the field (as v1 / SheetJS)', () {
      expect(readCsv('a,Pizza 5" wide,b\nc,d\n'), [
        ['a', 'Pizza 5" wide', 'b'],
        ['c', 'd'],
      ]);
      expect(readCsv('x"y"z,"q"\n'), [
        ['x"y"z', 'q'],
      ]);
      expect(readCsv(' "a,b" ,c\n'), [
        [' "a', 'b" ', 'c'],
      ]);
    });

    test('unterminated quote: the rest of the file becomes one field, nothing throws (strict: FormatException)', () {
      expect(() => readCsv('a,b\nc,"d\ne,f\n', strict: true), throwsFormatException);
      final rows = readCsv('a,b\nc,"d\ne,f\ng,h\n');
      expect(rows.first, ['a', 'b']);
      expect(rows.length, 2);
      expect(rows.last.first, 'c');
      expect(rows.last.last, 'd\ne,f\ng,h\n');
    });

    test('separator follows the first line: ; wins only when it outnumbers commas', () {
      expect(readCsv('a;b;c\n1,5;2;3\n'), [
        ['a', 'b', 'c'],
        ['1,5', '2', '3'],
      ]);
      expect(readCsv('a,b,c;d\n1;2;3;4\n'), [
        ['a', 'b', 'c;d'],
        ['1;2;3;4'],
      ]);
      // A tie goes to the comma.
      expect(readCsv('a,b;c\n'), [
        ['a', 'b;c'],
      ]);
    });

    test('a leading BOM is dropped, a header with only a BOM and a newline yields no rows', () {
      expect(readCsv('﻿a,b\n'), [
        ['a', 'b'],
      ]);
      expect(readCsv('﻿\n'), isEmpty);
    });

    test('tabs and spaces are data, not separators', () {
      expect(readCsv('a b\tc,d\n'), [
        ['a b\tc', 'd'],
      ]);
    });
  });

  group('Revolut CSV: columns and layout', () {
    test('double BOM, BOM bytes and CRLF together still find the header', () {
      final bytes = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, ...utf8.encode('$_hdr\r\n${_r('2026-02-01 10:00:00', 'Shop', '-1.00')}\r\n')];
      final b = importBankFile(Uint8List.fromList(bytes));
      expect(_amounts(b), [-100]);
    });

    test('header cells are trimmed and may be quoted, rows may be shorter or longer than the header', () {
      final b = _imp(
        '"Type", Started Date ,"Description",Amount\n'
        'Card Payment,2026-02-01 10:00:00,Shop,-3.50\n'
        'Card Payment,2026-02-02 10:00:00,Shop,-4.00,extra,columns,here\n'
        'Card Payment,2026-02-03 10:00:00,Short\n',
      );
      // The third row has no Amount cell at all: it cannot be an amount of 0, so it must not appear.
      expect(_amounts(b), [-350, -400]);
      expect(b.transactions.first.currency, 'EUR', reason: 'no Currency column: EUR');
      expect(b.transactions.first.bankType, 'Card Payment');
    });

    test('without a State column every row is kept; without Type the bank type is empty', () {
      final b = _imp('Started Date,Description,Amount\n2026-02-01,Shop,-1.00\n2026-02-02,Other,2.00\n');
      expect(_amounts(b), [-100, 200]);
      expect(b.transactions.map((t) => t.bankType), ['', '']);
      expect(b.skipped, 0);
    });

    test('a missing required column (Amount, Description or Started Date) is refused, not guessed', () {
      for (final h in ['Started Date,Description', 'Started Date,Amount', 'Description,Amount']) {
        expect(() => _imp('$h\n2026-02-01,x\n'), throwsA(isA<ImportException>()), reason: h);
      }
    });

    test('headers are matched exactly: lower case or translated headers are not a Revolut export', () {
      expect(() => _imp('type,started date,description,amount\ncard,2026-02-01,Shop,-1\n'), throwsA(isA<ImportException>()));
      // P12: not Revolut, so it asks for a column mapping.
      expect(() => _imp('Vrsta,Datum početka,Opis,Iznos\nKartica,2026-02-01,Shop,-1\n'), throwsA(isA<NeedsMapping>()));
    });

    test('the header may sit up to row 15 (index 14) and not below', () {
      String pad(int n) => List.generate(n, (i) => 'Account statement line $i').join('\n');
      final row = _r('2026-02-01 10:00:00', 'Shop', '-1.00');
      expect(_amounts(_imp('${pad(14)}\n$_hdr\n$row\n')), [-100]);
      expect(() => _imp('${pad(15)}\n$_hdr\n$row\n'), throwsA(isA<ImportException>()));
    });

    test('a header repeated inside the file (two exports pasted together) adds no rows', () {
      final b = _rev([_r('2026-02-01 10:00:00', 'A', '-1.00'), _hdr, _r('2026-02-02 10:00:00', 'B', '-2.00')]);
      expect(_amounts(b), [-100, -200]);
      expect(b.invalid, 0);
    });

    test('header only, or header plus blank lines: an empty Revolut batch, not an error', () {
      for (final t in ['$_hdr\n', _hdr, '$_hdr\r\n\r\n\r\n']) {
        final b = _imp(t);
        expect(b.source, 'revolut');
        expect(b.transactions, isEmpty);
        expect(b.skipped, 0);
        expect(b.invalid, 0);
      }
    });

    test('State: only COMPLETED is imported, everything else counts as skipped, whatever it is', () {
      final b = _rev([
        _r('2026-02-01 10:00:00', 'ok', '-1.00'),
        _r('2026-02-01 10:00:00', 'a', '-1.00', state: 'PENDING'),
        _r('2026-02-01 10:00:00', 'b', '-1.00', state: 'REVERTED'),
        _r('2026-02-01 10:00:00', 'c', '-1.00', state: 'DECLINED'),
        _r('2026-02-01 10:00:00', 'd', '-1.00', state: ''),
      ]);
      expect(_amounts(b), [-100]);
      expect(b.skipped, 4);
    });

    test('rows without a date (footer, blank cells) are ignored and not counted', () {
      final b = _rev([_r('2026-02-01 10:00:00', 'ok', '-1.00'), ',,,,Total,-1.00,,EUR,COMPLETED,', ',,,,,,,,,']);
      expect(_amounts(b), [-100]);
      expect(b.invalid, 0);
      expect(b.skipped, 0);
    });

    test('currency is kept per row; an empty Currency cell defaults to EUR', () {
      final b = _rev([_r('2026-02-01 10:00:00', 'a', '-1.00', cur: 'USD'), _r('2026-02-02 10:00:00', 'b', '-1.00', cur: '')]);
      expect(b.transactions.map((t) => t.currency), ['USD', 'EUR']);
    });
  });

  group('Revolut CSV: amounts', () {
    ImportBatch one(String amount, {String fee = '0.00'}) => _rev([_r('2026-02-01 10:00:00', 'x', amount, fee: fee)]);

    test('decimal and thousands formats become cents', () {
      // (written amount, cents)
      const cases = <(String, int)>[
        ('1,234.56', 123456), // English thousands
        ('1.234,56', 123456), // European thousands
        ('1,5', 150), // comma decimal, one digit
        ('1.234,5', 123450),
        ('12', 1200), // integer
        ('-0.07', -7),
        ('+12.30', 1230),
        ('.5', 50),
        ('1 234,56', 123456), // space as thousands
        ('1 234,56', 123456), // no-break space
        ('1 234,56', 123456), // narrow no-break space (Croatian/French grouping)
        ('  -12.30  ', -1230),
        ('12.3449', 1234), // more than two decimals round to the nearest cent
        ('12.3451', 1235),
        ('-12.3451', -1235),
        ('0.004', 0),
        ('1e2', 10000),
      ];
      for (final (text, cents) in cases) {
        final b = one(text);
        expect(_amounts(b), [cents], reason: 'amount "$text"');
      }
    });

    test('zero and negative zero are real zero-amount rows, with the same id as +0', () {
      final b =
          _rev([_r('2026-02-01 10:00:00', 'z', '0'), _r('2026-02-02 10:00:00', 'z', '-0,00'), _r('2026-02-03 10:00:00', 'z', '-0.00')]);
      expect(_amounts(b), [0, 0, 0]);
      expect(b.transactions.map((t) => t.id).toSet().length, 3, reason: 'different dates stay different');
      // 0.00 and -0.00 on one day are the same amount: they count as identical rows (second gets _1), never the same id.
      final same = _rev([_r('2026-02-01 10:00:00', 'z', '0.00'), _r('2026-02-01 10:00:00', 'z', '-0.00')]);
      expect(same.transactions.map((t) => t.id).toList(), [transactionId('2026-02-01', 0, 'z', 0), transactionId('2026-02-01', 0, 'z', 1)]);
    });

    test('fee is subtracted, a negative fee adds, an empty fee is zero', () {
      expect(_amounts(one('-10.00', fee: '0.50')), [-1050]);
      expect(_amounts(one('-10.00', fee: '-0.50')), [-950]);
      expect(_amounts(one('-10.00', fee: '')), [-1000]);
      expect(_amounts(one('0.00', fee: '1.00')), [-100], reason: 'fee on a zero amount is still a cost');
    });

    test('the limit is 10 billion: at the limit imports, one cent over is counted as invalid', () {
      expect(_amounts(one('10000000000.00')), [1000000000000]);
      expect(_amounts(one('-10000000000.00')), [-1000000000000]);
      final over = one('10000000000.01');
      expect(over.transactions, isEmpty);
      expect(over.invalid, 1);
      final huge = one('99999999999999999999999');
      expect(huge.transactions, isEmpty);
      expect(huge.invalid, 1);
      // fee pushes it over
      expect(one('1.00', fee: '99999999999').invalid, 1);
    });

    test('one bad row does not take the good rows around it with it', () {
      final b = _rev([
        _r('2026-02-01 10:00:00', 'a', '-1.00'),
        _r('2026-02-02 10:00:00', 'b', '1e999'),
        _r('2026-02-03 10:00:00', 'c', '-3.00'),
      ]);
      expect(_amounts(b), [-100, -300]);
      expect(b.invalid, 1);
    });

    test('a row with a real date but an unreadable amount is counted as invalid, not silently dropped', () {
      for (final bad in ['abc', '€ 12', '(12.30)', '−12.30', '12.30-', '1.2.3', '--1']) {
        final b = one(bad);
        expect(b.transactions, isEmpty, reason: bad);
        expect(b.invalid, 1, reason: 'amount "$bad" vanished without being counted');
      }
    });

    test('an empty Amount is not a transaction: ignored without being counted (owner decision)', () {
      for (final empty in ['', '   ']) {
        final b = _rev([_r('2026-02-01 10:00:00', 'a', empty), _r('2026-02-02 10:00:00', 'b', '-2.00')]);
        expect(_amounts(b), [-200], reason: '"$empty"');
        expect(b.invalid, 0, reason: '"$empty"');
      }
      // Also when the date cannot be read: an empty Amount decides first.
      final b = _rev([_r('01/02/2026', 'a', '')]);
      expect((b.transactions.length, b.invalid), (0, 0));
    });

    test('PBZ: a dated row with an unreadable amount is counted, an empty amount is ignored', () {
      final b = _imp('TRANSAKCIJSKI RAČUN;HR00\nDATUM;VRSTA TRANSAKCIJE;OPIS PLAĆANJA;IZNOS;VALUTA\n'
          '15.01.2026;POS;Shop;abc;EUR\n15.01.2026;POS;Shop;;EUR\n15.01.2026;POS;Shop;-1,00;EUR\n');
      expect(_amounts(b), [-100]);
      expect(b.invalid, 1);
    });

    test('a garbage Fee is not silently treated as 0', () {
      final b = one('-10.00', fee: 'abc');
      // Either the row is left out and counted, or the import fails; importing -10.00 hides a fee.
      expect(b.transactions.isEmpty && b.invalid == 1, isTrue, reason: 'amounts: ${_amounts(b)}');
    });
  });

  group('Revolut CSV: dates', () {
    ImportBatch one(String date) => _rev([_r(date, 'x', '-1.00')]);

    test('the written calendar day is kept: no timezone or DST shift around midnight', () {
      const cases = <(String, String)>[
        ('2026-03-31 23:59:59', '2026-03-31'),
        ('2026-04-01 00:00:00', '2026-04-01'),
        ('2026-03-31T23:59:59Z', '2026-03-31'),
        ('2026-03-31T23:59:59.999+02:00', '2026-03-31'),
        ('2026-04-01T00:30:00-05:00', '2026-04-01'),
        ('2026-03-29 02:30:00', '2026-03-29'), // does not exist locally (spring forward)
        ('2026-10-25 02:30:00', '2026-10-25'), // happens twice (fall back)
        ('2026-12-31 24:00:00', '2026-12-31'),
        ('  2026-02-01 10:00:00  ', '2026-02-01'),
        ('2026-02-01', '2026-02-01'),
        ('01.02.2026 10:00', '2026-02-01'),
        ('1.2.2026', '2026-02-01'),
        ('29.02.2028', '2028-02-29'),
      ];
      for (final (written, day) in cases) {
        expect(one(written).transactions.map((t) => t.date), [day], reason: written);
      }
    });

    test('Started Date decides, not Completed Date: a payment started on the 31st and booked on the 1st is the 31st', () {
      final b = _imp('$_hdr\nCard Payment,Current,2026-01-31 23:58:00,2026-02-01 00:02:00,Late shop,-5.00,0.00,EUR,COMPLETED,0\n');
      expect(b.transactions.single.date, '2026-01-31');
      expect(b.transactions.single.id, startsWith('260131'));
    });

    test('dates that are not real days are counted as invalid and leave the rest alone', () {
      final b = _rev([
        _r('2026-02-29 10:00:00', 'a', '-1.00'), // 2026 is not a leap year
        _r('2025-02-29 10:00:00', 'b', '-1.00'),
        _r('2026-04-31 10:00:00', 'c', '-1.00'),
        _r('2026-00-10 10:00:00', 'd', '-1.00'),
        _r('2026-13-01 10:00:00', 'e', '-1.00'),
        _r('0000-01-01 10:00:00', 'f', '-1.00'),
        _r('31.02.2026', 'g', '-1.00'),
        _r('2024-02-29 10:00:00', 'ok', '-2.00'),
      ]);
      expect(b.transactions.map((t) => t.description), ['ok']);
      expect(b.invalid, 7);
    });

    test('a leap day imports with the right id prefix, and so do the first and last days of the year', () {
      final b =
          _rev([_r('2028-02-29 10:00:00', 'a', '-1.00'), _r('2026-01-01 00:00:00', 'b', '-1.00'), _r('2026-12-31 23:59:59', 'c', '-1.00')]);
      expect(b.transactions.map((t) => t.id.substring(0, 6)), ['280229', '260101', '261231']);
    });

    test('a date in a format we do not read (01/02/2026, Feb 1 2026, 2026-2-1) is counted, not silently dropped', () {
      for (final bad in ['01/02/2026 10:00', 'Feb 1, 2026', '2026-2-1', '20260201', '1 February 2026']) {
        final b = one(bad);
        expect(b.transactions, isEmpty, reason: bad);
        expect(b.invalid, 1, reason: 'date "$bad" vanished without being counted');
      }
    });
  });

  group('Revolut CSV: quoting and text', () {
    test('quoted description with comma, escaped quotes and a newline is one transaction', () {
      final b = _imp(
          '$_hdr\nCard Payment,Current,2026-02-01 10:00:00,2026-02-01 10:00:00,"Joe\'s ""Big"" Shop,\nLtd",-9.99,0.00,EUR,COMPLETED,0\n');
      expect(b.transactions.single.description, 'Joe\'s "Big" Shop,\nLtd');
      expect(b.transactions.single.amountMinor, -999);
    });

    test('a stray quote inside an unquoted field is a literal character and does not swallow the rows after it', () {
      final text = '$_hdr\n${_r('2026-02-01 10:00:00', 'ok', '-1.00')}\n'
          'Card Payment,Current,2026-02-02 10:00:00,2026-02-02 10:00:00,Pizza 5" wide,-2.00,0.00,EUR,COMPLETED,0\n'
          '${_r('2026-02-03 10:00:00', 'after1', '-3.00')}\n${_r('2026-02-04 10:00:00', 'after2', '-4.00')}\n';
      // Read leniently like v1 (SheetJS): the quote stays in the description and every row imports.
      final b = _imp(text);
      expect(_amounts(b), [-100, -200, -300, -400]);
      expect(b.transactions[1].description, 'Pizza 5" wide');
      expect(b.transactions[1].id, transactionId('2026-02-02', -200, 'Pizza 5" wide', 0));
      expect(b.invalid, 0);
    });

    test('a quoted field that never closes refuses the file instead of losing the rows after it', () {
      final text = '$_hdr\n${_r('2026-02-01 10:00:00', 'ok', '-1.00')}\n'
          'Card Payment,Current,2026-02-02 10:00:00,2026-02-02 10:00:00,"Pizza wide,-2.00,0.00,EUR,COMPLETED,0\n'
          'Card Payment,Current,2026-02-03 10:00:00,2026-02-03 10:00:00,after1,-3.00,0.00,EUR,COMPLETED,0\n';
      expect(() => _imp(text), throwsA(isA<ImportException>()));
    });

    test('descriptions are trimmed at the ends only and keep inner spacing and case', () {
      final b = _rev([_r('2026-02-01 10:00:00', '"  Lidl   d.o.o.  "', '-1.00')]);
      expect(b.transactions.single.description, 'Lidl   d.o.o.');
    });

    test('empty description is allowed', () {
      final b = _rev([_r('2026-02-01 10:00:00', '', '-1.00')]);
      expect(b.transactions.single.description, '');
    });

    test('mojibake in a quoted description is repaired, real Latin-1 text is left alone', () {
      // UTF-8 "š" (C5 A1) read as Latin-1 is U+00C5 U+00A1.
      final b = _rev([_r('2026-02-01 10:00:00', 'GraÅ¡o', '-1.00')]);
      expect(b.transactions.single.description, 'Grašo');
      final plain = _rev([_r('2026-02-01 10:00:00', 'Café', '-1.00')]);
      expect(plain.transactions.single.description, 'Café');
    });
  });

  group('semicolon exports (PBZ-style CSV)', () {
    String pbz(List<String> rows) => 'TRANSAKCIJSKI RAČUN;HR00\nDATUM;VRSTA TRANSAKCIJE;OPIS PLAĆANJA;IZNOS;VALUTA\n${rows.join('\n')}\n';

    test('d.m.yyyy dates, comma decimals with thousands dots, signed amounts', () {
      final b = _imp(pbz(['15.01.2026;Plaća;Neto plaća;1.500,00;EUR', '3.1.2026;POS plaćanje;Shop;-1.234,56;EUR']));
      expect(b.source, 'pbz');
      expect(_amounts(b), [150000, -123456]);
      expect(b.transactions.map((t) => t.date), ['2026-01-15', '2026-01-03']);
    });

    test('card holds are skipped whatever the case, with or without leading spaces', () {
      final b = _imp(pbz(
          ['15.01.2026;POS;REZERVACIJA SHOP;-1,00;EUR', '15.01.2026;POS;  rezervacija shop;-1,00;EUR', '15.01.2026;POS;Shop;-1,00;EUR']));
      expect(b.skipped, 2);
      expect(_amounts(b), [-100]);
    });

    test('impossible dates are invalid, rows with fewer than four columns are ignored', () {
      final b = _imp(pbz(['31.02.2026;POS;Shop;-1,00;EUR', '15.01.2026;POS;Short', '15.01.2026;POS;Shop;-2,00']));
      expect(_amounts(b), [-200]);
      expect(b.invalid, 1);
      expect(b.transactions.single.currency, 'EUR', reason: 'missing VALUTA defaults to EUR');
    });
  });

  group('format detection and wrong files', () {
    final unknown = throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('I recognise')));
    final damaged = throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('Could not read')));

    test('files of the wrong type are refused with a clear message, never imported as garbage', () {
      final samples = <String, Uint8List>{
        'html table': _b('<html><body><table><tr><td>Started Date</td><td>Amount</td></tr></table></body></html>'),
        'pdf': _b('%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n'),
        'json': _b('{"transactions":[{"amount":-1.0}]}'),
        'plain text': _b('Hello, this is not a bank statement.\nSecond line.\n'),
        'png': Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]),
        'only whitespace': _b('  \n\t\n'),
        'empty': Uint8List(0),
        'one byte': Uint8List.fromList([0x50]),
      };
      for (final e in samples.entries) {
        expect(() => importBankFile(e.value), unknown, reason: e.key);
      }
      // P12: a CSV with another bank's layout is not refused any more: it asks for a column mapping.
      expect(() => importBankFile(_b('Date,Payee,Debit,Credit\n2026-02-01,Shop,1.00,\n')),
          throwsA(isA<NeedsMapping>().having((e) => e.shape.headers, 'headers', ['Date', 'Payee', 'Debit', 'Credit'])));
    });

    test('UTF-16 text (Excel "Unicode text" export) is refused cleanly', () {
      final text = '$_hdr\n${_r('2026-02-01 10:00:00', 'Shop', '-1.00')}\n';
      final le = Uint8List.fromList([
        0xFF,
        0xFE,
        for (final c in text.codeUnits) ...[c & 0xFF, c >> 8]
      ]);
      expect(() => importBankFile(le), unknown);
    });

    test('PK-prefixed bytes that are not a zip, and OLE2 magic with nothing behind it, are "could not read"', () {
      expect(() => importBankFile(Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4, 5, 6])), damaged);
      expect(() => importBankFile(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])), damaged);
      expect(() => importBankFile(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, ...List.filled(600, 0)])), damaged);
    });

    test('an OLE2 magic that is one byte wrong is treated as text and refused as unknown', () {
      expect(() => importBankFile(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE0, ...List.filled(600, 0)])), unknown);
    });

    test('invalid UTF-8 inside a description does not abort the import; the row keeps its amount', () {
      final head = utf8.encode('$_hdr\nCard Payment,Current,2026-02-01 10:00:00,2026-02-01 10:00:00,Caf');
      final tail = utf8.encode(',-4.20,0.00,EUR,COMPLETED,0\n');
      final b = importBankFile(Uint8List.fromList([...head, 0xE9, ...tail]));
      expect(_amounts(b), [-420]);
    });

    test('a very long single line and a very long description import', () {
      final long = 'x' * 200000;
      final b = _rev([_r('2026-02-01 10:00:00', long, '-1.00')]);
      expect(b.transactions.single.description.length, 200000);
      expect(b.transactions.single.id.length, lessThan(30));
    });

    test('many thousands of rows import in one go with unique ids', () {
      final rows = [
        for (var i = 0; i < 5000; i++)
          _r('2026-02-${(i % 28 + 1).toString().padLeft(2, '0')} 10:00:00', 'Shop ${i % 40}', '-${i % 90 + 1}.00')
      ];
      final b = _rev(rows);
      expect(b.transactions.length, 5000);
      expect(b.transactions.map((t) => t.id).toSet().length, 5000);
    });
  });
}
