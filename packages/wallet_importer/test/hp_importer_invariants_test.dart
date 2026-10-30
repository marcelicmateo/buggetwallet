// HP-T3: invariants found by mutation testing the generic CSV import, the column mapping, the PBZ and Revolut
// profiles and the XLS reader. Boundaries and malformed input. SYNTHETIC data only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/xls_reader.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/biff.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

CsvMapping _m({
  int dateCol = 0,
  int? amountCol = 1,
  int? debitCol,
  int? creditCol,
  List<int> descriptionCols = const [],
  List<String> headers = const ['Date', 'Amount', 'Memo'],
  String name = 'Layout',
  int headerRow = 0,
  int? currencyCol,
  String? currencyCode,
  int? skipIfEmptyCol,
  int? balanceCol,
}) =>
    CsvMapping(
      name: name,
      headerRow: headerRow,
      dateCol: dateCol,
      dateFormat: CsvDateFormat.dmyDot,
      amountCol: amountCol,
      debitCol: debitCol,
      creditCol: creditCol,
      descriptionCols: descriptionCols,
      headers: headers,
      currencyCol: currencyCol,
      currencyCode: currencyCode,
      skipIfEmptyCol: skipIfEmptyCol,
      balanceCol: balanceCol,
    );

Matcher _mismatch() => throwsA(isA<ImportException>().having((e) => e.message, 'message', layoutMismatchMessage));

void main() {
  group('CsvMapping.structureProblems boundaries', () {
    test('limits are the documented numbers', () {
      expect(maxCsvColumns, 200);
      expect(maxCsvHeaderChars, 200);
      expect(CsvMapping.maxName, 30);
      expect(CsvMapping.maxDescriptionCols, 5);
    });

    test('name: 30 characters fine, 31 not, blank not', () {
      expect(_m(name: 'a' * 30).structureProblems(), isEmpty);
      expect(_m(name: 'a' * 31).structureProblems(), hasLength(1));
      expect(_m(name: '   ').structureProblems(), hasLength(1));
      // counted in characters, not UTF-16 units
      expect(_m(name: '😀' * 30).structureProblems(), isEmpty);
    });

    test('headers: 200 columns fine, 201 not; a 200-char name fine, 201 not', () {
      expect(_m(headers: [for (var i = 0; i < 200; i++) 'h$i']).structureProblems(), isEmpty);
      expect(_m(headers: [for (var i = 0; i < 201; i++) 'h$i']).structureProblems(), hasLength(1));
      expect(_m(headers: ['Date', 'Amount', 'x' * 200]).structureProblems(), isEmpty);
      expect(_m(headers: ['Date', 'Amount', 'x' * 201]).structureProblems(), hasLength(1));
    });

    test('description columns: 5 fine, 6 not, repeated not', () {
      final h = [for (var i = 0; i < 8; i++) 'h$i'];
      expect(_m(headers: h, descriptionCols: [2, 3, 4, 5, 6]).structureProblems(), isEmpty);
      expect(_m(headers: h, descriptionCols: [2, 3, 4, 5, 6, 7]).structureProblems(), hasLength(1));
      expect(_m(headers: h, descriptionCols: [2, 2]).structureProblems(), hasLength(1));
    });

    test('a column equal to the width is out of range, width-1 is not', () {
      expect(_m(dateCol: 2).structureProblems(), isEmpty);
      expect(_m(dateCol: 3).structureProblems(), isNotEmpty);
      expect(_m(dateCol: -1).structureProblems(), isNotEmpty);
      expect(_m(amountCol: 3).structureProblems(), isNotEmpty);
      expect(_m(descriptionCols: [3]).structureProblems(), isNotEmpty);
      expect(_m(currencyCol: 3).structureProblems(), isNotEmpty);
      expect(_m(skipIfEmptyCol: 3).structureProblems(), isNotEmpty);
      expect(_m(balanceCol: 3).structureProblems(), isNotEmpty);
      expect(_m(balanceCol: 2).structureProblems(), isEmpty);
      expect(_m(balanceCol: 1).structureProblems(), isNotEmpty); // same as the amount column
      // an explicit width wins over the headers
      expect(_m().structureProblems(columns: 2), isEmpty);
      expect(_m(dateCol: 2).structureProblems(columns: 2), isNotEmpty);
    });

    test('split amount: one bad column is enough', () {
      final ok = _m(amountCol: null, debitCol: 1, creditCol: 2);
      expect(ok.splitAmount, isTrue);
      expect(ok.structureProblems(), isEmpty);
      expect(_m(amountCol: null, debitCol: 1, creditCol: 9).structureProblems(), isNotEmpty);
      expect(_m(amountCol: null, debitCol: 9, creditCol: 2).structureProblems(), isNotEmpty);
      expect(_m(amountCol: null, debitCol: 1, creditCol: 1).structureProblems(), isNotEmpty);
      expect(_m(amountCol: null, debitCol: 1).structureProblems(), isNotEmpty);
      expect(_m(amountCol: null).structureProblems(), isNotEmpty);
      expect(_m().splitAmount, isFalse);
      expect(_m(debitCol: 1).structureProblems(), isNotEmpty); // one amount column plus a debit column
    });

    test('header row below -1 and bad currency code', () {
      expect(_m(headerRow: -1).structureProblems(), isEmpty);
      expect(_m(headerRow: -2).structureProblems(), isNotEmpty);
      expect(_m(currencyCode: 'EUR').structureProblems(), isEmpty);
      expect(_m(currencyCode: 'eur').structureProblems(), isNotEmpty);
      expect(_m(currencyCode: 'EURO').structureProblems(), isNotEmpty);
    });
  });

  group('CsvMapping json and equality', () {
    test('round trip keeps every field', () {
      final m = _m(currencyCol: 2, skipIfEmptyCol: 2, balanceCol: 2, descriptionCols: [2]);
      expect(CsvMapping.fromJson(jsonDecode(jsonEncode(m.toJson()))), m);
    });

    test('mappings that differ only in an optional field are not equal', () {
      final base = _m();
      expect(base == _m(), isTrue);
      expect(base == _m(currencyCode: 'EUR'), isFalse);
      expect(base == _m(currencyCol: 2), isFalse);
      expect(base == _m(skipIfEmptyCol: 2), isFalse);
      expect(base == _m(balanceCol: 2), isFalse);
      expect(_m(currencyCode: 'EUR') == _m(currencyCode: 'USD'), isFalse);
      expect(base == _m(headers: ['Date', 'Amount', 'Other']), isFalse);
      expect(base == _m(headers: ['Date', 'Amount']), isFalse);
      expect(base == _m(descriptionCols: [2]), isFalse);
    });

    test('damaged stored values are refused one field at a time', () {
      Map<String, Object?> j() => Map<String, Object?>.from(jsonDecode(jsonEncode(_m(descriptionCols: [2]).toJson())) as Map);
      expect(CsvMapping.fromJson(j()), isA<CsvMapping>());
      for (final bad in <Map<String, Object?>>[
        {'description': 'x'},
        {'description': 5},
        {'headers': 'x'},
        {'headers': 5},
        {
          'headers': [1, 2]
        },
        {'negate': 'yes'},
        {'decimal': 'dot'},
        {'v': 2},
        {'name': 5},
        {'headerRow': '0'},
        {'date': 'x'},
        {'amount': []},
        {'currency': 'EUR'},
        {
          'currency': {'code': 5}
        },
        {
          'description': ['a']
        },
      ]) {
        expect(() => CsvMapping.fromJson({...j(), ...bad}), throwsFormatException, reason: '$bad');
      }
      expect(() => CsvMapping.fromJson(null), throwsFormatException);
      expect(() => CsvMapping.fromJson([]), throwsFormatException);
    });
  });

  group('parseCsvDate and parseCsvCents boundaries', () {
    test('years 1900 and 2199 are accepted, 1899 and 2200 refused', () {
      expect(parseCsvDate('01.01.1900', CsvDateFormat.dmyDot), '1900-01-01');
      expect(parseCsvDate('31.12.2199', CsvDateFormat.dmyDot), '2199-12-31');
      expect(parseCsvDate('31.12.1899', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('01.01.2200', CsvDateFormat.dmyDot), isNull);
    });

    test('day 0, month 0/13 and impossible days are refused', () {
      expect(parseCsvDate('00.01.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('01.00.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('01.13.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('29.02.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('29.02.2028', CsvDateFormat.dmyDot), '2028-02-29');
      expect(parseCsvDate('02/13/2026', CsvDateFormat.mdySlash), '2026-02-13');
      expect(parseCsvDate('2026-02-13', CsvDateFormat.iso), '2026-02-13');
    });

    test('the largest allowed amount is accepted, one cent more is not', () {
      expect(parseCsvCents('1.000.000.000,00', CsvDecimal.comma), maxRowAmountMinor);
      expect(parseCsvCents('1.000.000.000,01', CsvDecimal.comma), isNull);
      expect(parseCsvCents('1,000,000,000.00', CsvDecimal.point), maxRowAmountMinor);
      expect(parseCsvCents('99999999999999999999,00', CsvDecimal.comma), isNull);
      expect(parseCsvCents('-0,05', CsvDecimal.comma), -5);
      expect(parseCsvCents('0,005', CsvDecimal.comma), isNull); // three decimals are refused, never rounded
    });
  });

  group('csvShape header and delimiter detection', () {
    test('a two-field header with one two-field data row is a header, not headerless data', () {
      final s = csvShape(_b('Date;Amount\n01.01.2026;5,00\n'));
      expect(s.headerRow, 0);
      expect(s.headers, ['Date', 'Amount']);
    });

    test('exactly two data rows without a header are accepted, one is not', () {
      expect(csvShape(_b('01.01.2026;5,00\n02.01.2026;6,00\n')).headerRow, csvNoHeader);
      expect(() => csvShape(_b('01.01.2026;5,00\n')), throwsA(isA<ImportException>()));
    });

    test('a header with two filled cells of three counts (width below 4 needs two)', () {
      final s = csvShape(_b('Date;Amount;\n01.01.2026;5,00;x\n02.01.2026;6,00;y\n'));
      expect(s.headerRow, 0);
      expect(s.headers, ['Date', 'Amount']);
    });

    test('width 5 needs three filled cells: a two-cell title line is not the header', () {
      final s = csvShape(_b('Title;x;;;\nDate;Amount;Memo;Ref;Cat\n01.01.2026;5,00;a;b;c\n02.01.2026;6,00;a;b;c\n'));
      expect(s.headerRow, 1);
      expect(s.headers, hasLength(5));
    });

    test('a tie between delimiters goes to the earlier one in the order ; tab ,', () {
      expect(csvShape(_b('a;b,c\nd;e,f\n')).delimiter, ';');
      expect(csvShape(_b('a,b\tc\nd,e\tf\n')).delimiter, '\t');
    });

    test('a header row outside the file is a RangeError', () {
      final b = _b('Date;Amount\n01.01.2026;5,00\n');
      expect(() => csvShape(b, headerRow: 2), throwsRangeError);
      expect(() => csvShape(b, headerRow: -2), throwsRangeError);
      expect(csvShape(b, headerRow: 1).headerRow, 1);
    });
  });

  group('saved layout against another file', () {
    final layout = _m(headers: ['Date', 'Amount', 'Memo']);

    test('a short file with other columns is a layout mismatch, not a crash', () {
      expect(() => parseMappedCsv(_b('Day;Sum\n01.01.2026;5,00\n02.01.2026;6,00\n'), layout), _mismatch());
    });

    test('a header found only after the 15th row is not searched for', () {
      final rows = [for (var i = 0; i < 16; i++) 't$i;u$i', 'Date;Amount;Memo', '01.01.2026;5,00;x'];
      expect(() => parseMappedCsv(_b('${rows.join('\n')}\n'), layout), _mismatch());
    });

    test('a header on the 15th row (index 14) is found', () {
      final rows = [for (var i = 0; i < 14; i++) 't$i;u$i', 'Date;Amount;Memo', '01.01.2026;5,00;x'];
      final b = parseMappedCsv(_b('${rows.join('\n')}\n'), layout);
      expect(b.transactions.map((t) => t.amountMinor), [500]);
    });
  });

  group('preview rows', () {
    test('rows with a problem are not flagged too large; an over-cap amount is', () {
      final shape = csvShape(_b('Date;Amount;Memo\n01.01.2026;5,00;a\n02.01.2026;abc;b\n03.01.2026;2.000.000.000,00;c\n'));
      final rows = previewMapping(shape, _m());
      expect(rows[0].ok, isTrue);
      expect(rows[0].tooLarge, isFalse);
      expect(rows[1].problem, isNotNull);
      expect(rows[1].tooLarge, isFalse);
      expect(rows[2].tooLarge, isTrue);
    });
  });

  group('PBZ profile (rows as the XLS reader gives them)', () {
    const hdr = <Object>['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'];
    const iban = 'HR1200000000000000000';
    List<Object> tx(Object date, Object amount, {String desc = 'Shop A', Object? cur, List<Object> more = const []}) => [
          date,
          'POS plaćanje',
          desc,
          amount,
          ...(cur == null ? const <Object>[] : [cur]),
          ...more
        ];
    ImportBatch parse(List<List<Object>> rows) => parseRows(rows, format: 'xls')!;

    test('no balance column: balanceAfter is null even when the first column is a number', () {
      final b = parse([hdr, tx(46054.0, -12.5, cur: 'EUR'), tx(46055.0, 3.0, cur: 'EUR')]);
      expect(b.source, 'pbz');
      expect(b.transactions.map((t) => t.balanceAfter), [null, null]);
      expect(b.transactions.map((t) => t.date), ['2026-02-01', '2026-02-02']);
    });

    test('the balance column comes from the real header row, not from a look-alike above it', () {
      final decoy = <Object>['X', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA', 'STANJE'];
      final real = <Object>[...hdr, 'Z', 'SALDO'];
      final b = parse([
        decoy,
        real,
        tx('01.02.2026', -12.5, cur: 'EUR', more: ['junk', 100.0])
      ]);
      expect(b.transactions.single.balanceAfter, 10000);
      expect(b.transactions.single.amountMinor, -1250);
    });

    test('a balance header also works lower case and a balance cell that is empty gives none', () {
      final b = parse([
        [...hdr, 'stanje'],
        tx('01.02.2026', -1.0, cur: 'EUR', more: ['']),
        tx('02.02.2026', -2.0, cur: 'EUR', more: [7.25]),
      ]);
      expect(b.transactions.map((t) => t.balanceAfter), [null, 725]);
    });

    test('account: label in the very first cell with the IBAN below', () {
      final b = parse([
        ['TRANSAKCIJSKI RAČUN:'],
        [iban],
        hdr,
        tx('01.02.2026', -1.0),
      ]);
      expect(b.transactions.single.account, iban);
    });

    test('account: IBAN in the last row of the file, label on the row above', () {
      final b = parse([
        hdr,
        tx('01.02.2026', -1.0),
        ['TRANSAKCIJSKI RAČUN:'],
        [iban],
      ]);
      expect(b.transactions.single.account, iban);
    });

    test('account: IBAN right after the label, nothing below; label on the last row of the file', () {
      final b = parse([
        hdr,
        tx('01.02.2026', -1.0),
        ['TRANSAKCIJSKI RAČUN:', iban],
      ]);
      expect(b.transactions.single.account, iban);
    });

    test('account: row below is shorter than the label column', () {
      final b = parse([
        ['a', 'b', 'TRANSAKCIJSKI RAČUN:', iban],
        ['c', 'd'],
        hdr,
        tx('01.02.2026', -1.0),
      ]);
      expect(b.transactions.single.account, iban);
    });

    test('account: the label is found in lower case, and a non-IBAN next to it gives none', () {
      expect(
          parse([
            ['transakcijski račun:', iban],
            hdr,
            tx('01.02.2026', -1.0)
          ]).transactions.single.account,
          iban);
      expect(
          parse([
            ['TRANSAKCIJSKI RAČUN:', 'not an iban'],
            hdr,
            tx('01.02.2026', -1.0)
          ]).transactions.single.account,
          isNull);
    });

    test('Excel serial date cells: 30000 is not a date, 30001 is', () {
      final b = parse([hdr, tx(30000.0, -1.0), tx(30001.0, -2.0)]);
      expect(b.transactions, hasLength(1));
      expect(b.transactions.single.amountMinor, -200);
      expect(b.skipped, 0);
      expect(b.invalid, 0);
    });

    test('currency: a five-cell row reads it from the fifth cell; shorter rows default to EUR', () {
      final b = parse([
        hdr,
        tx('01.02.2026', -1.0, cur: 'USD'),
        tx('02.02.2026', -2.0),
        tx('03.02.2026', -3.0, cur: ''),
      ]);
      expect(b.transactions.map((t) => t.currency), ['USD', 'EUR', 'EUR']);
    });

    test('rows shorter than four cells, a card hold and an unreadable amount', () {
      final b = parse([
        hdr,
        ['01.02.2026', 'POS plaćanje', 'x'],
        tx('02.02.2026', -2.0, desc: 'REZERVACIJA shop'),
        tx('03.02.2026', 'abc'),
        tx('04.02.2026', ''),
        tx('31.02.2026', -1.0),
        tx('05.02.2026', -5.0),
      ]);
      expect(b.transactions.map((t) => t.amountMinor), [-500]);
      expect(b.skipped, 1);
      expect(b.invalid, 2);
    });

    test('a card payment to the own Revolut is an own transfer, others stay card', () {
      final b = parse([
        hdr,
        tx('01.02.2026', -1.0, desc: 'POS Revolut**1234* Dublin'),
        tx('02.02.2026', -1.0, desc: 'POS Shop B'),
      ]);
      expect(b.transactions.map((t) => t.kindHint), [TxKind.ownTransfer, TxKind.card]);
    });

    test('the header must start in the first column: shifted by one cell is not PBZ', () {
      expect(
          parseRows([
            ['', ...hdr],
            tx('01.02.2026', -1.0)
          ], format: 'xls'),
          isNull);
      expect(parseRows([hdr.sublist(0, 4), tx('01.02.2026', -1.0)], format: 'xls'), isNull);
    });
  });

  group('Revolut profile with columns in other orders', () {
    ImportBatch csv(String s) => importBankFile(_b(s), fileName: 'x.csv');

    test('Fee in the first column is subtracted from the amount', () {
      final b = csv('Fee,Started Date,Description,Amount\n1.50,2026-02-01 10:00:00,Shop A,-10.00\n');
      expect(b.transactions.single.amountMinor, -1150);
    });

    test('Currency in the first column is read', () {
      final b = csv('Currency,Started Date,Description,Amount\nUSD,2026-02-01 10:00:00,Shop A,-10.00\n');
      expect(b.transactions.single.currency, 'USD');
    });

    test('Balance in the first column is read', () {
      final b = csv('Balance,Started Date,Description,Amount\n90.00,2026-02-01 10:00:00,Shop A,-10.00\n');
      expect(b.transactions.single.balanceAfter, 9000);
    });

    test('a Fee that is not a number invalidates the row; no Fee column is zero', () {
      final b = csv('Started Date,Description,Amount,Fee\n2026-02-01 10:00:00,Shop A,-10.00,abc\n2026-02-02 10:00:00,Shop B,-5.00,\n');
      expect(b.invalid, 1);
      expect(b.transactions.single.amountMinor, -500);
    });
  });

  group('XLS reader container details', () {
    List<int> book() => workbook([
          [...label(0, 0, 'DATUM'), ...formula(0, 1, null), ...number(0, 2, 1.5), ...formula(1, 0, 2.25)],
        ]);

    test('a string-result formula is an empty cell, never a number', () {
      final rows = XlsReader.firstSheet(ole2(book()));
      expect(rows[0], ['DATUM', '', 1.5]);
      expect(rows[1].first, 2.25);
    });

    test('the stream entry may be the last entry of the directory sector', () {
      final f = Uint8List.fromList(ole2(book()));
      // header 512 + FAT 512 -> the directory sector is at 1024; move entry 1 into entry 3 (the last 128 bytes).
      f.setRange(1024 + 384, 1024 + 512, f.sublist(1024 + 128, 1024 + 256));
      f.fillRange(1024 + 128, 1024 + 256, 0);
      expect(XlsReader.firstSheet(f)[0].first, 'DATUM');
    });

    test('a workbook kept in the mini stream is read through the mini FAT', () {
      final f = ole2(book()); // stream padded to 4096 bytes: sectors 2..9
      final b = BytesBuilder()
        ..add(f)
        ..add(Uint8List(512));
      final out = b.toBytes();
      final bd = ByteData.sublistView(out);
      // sector 10 = the mini FAT: mini sector i -> i + 1, the last one ends the chain.
      const miniFatOff = (10 + 1) * 512;
      for (var i = 0; i < 64; i++) {
        bd.setUint32(miniFatOff + i * 4, i == 63 ? 0xFFFFFFFE : i + 1, Endian.little);
      }
      for (var i = 64; i < 128; i++) {
        bd.setUint32(miniFatOff + i * 4, 0xFFFFFFFF, Endian.little);
      }
      bd.setUint32(512 + 4 * 10, 0xFFFFFFFE, Endian.little); // FAT: sector 10 ends its chain
      bd.setUint32(0x38, 8192, Endian.little); // streams under 8192 bytes are mini streams
      bd.setUint32(0x3C, 10, Endian.little); // first mini FAT sector
      bd.setUint32(1024 + 0x74, 2, Endian.little); // root entry: mini stream container starts at sector 2
      bd.setUint32(1024 + 128 + 0x74, 0, Endian.little); // Workbook: first mini sector 0
      final rows = XlsReader.firstSheet(out);
      expect(rows[0], ['DATUM', '', 1.5]);
      expect(rows[1].first, 2.25);
    });
  });
}
