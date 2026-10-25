// P12 (docs/context/P12_SPEC.md §1, §4): import any CSV by a remembered column mapping. Fixtures are SYNTHETIC
// (tools/make_fixtures.py, "generic" section) or built inline.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/src/text_codec.dart' show decodeWindows1250, sha256Hex;
import 'package:wallet_importer/wallet_importer.dart';

Uint8List _fx(String name) => File('test/fixtures/generic/$name').readAsBytesSync();
Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// A one-column-amount mapping for `Datum;Opis;Iznos;Valuta` style files.
CsvMapping _simple({
  int headerRow = 0,
  CsvDateFormat format = CsvDateFormat.dmyDot,
  CsvDecimal decimal = CsvDecimal.comma,
  bool negate = false,
  List<String> headers = const [],
}) =>
    CsvMapping(
        name: 'Test CSV',
        headerRow: headerRow,
        dateCol: 0,
        dateFormat: format,
        amountCol: 2,
        decimal: decimal,
        negate: negate,
        descriptionCols: const [1],
        currencyCol: 3,
        headers: headers);

/// A file with header `Datum;Opis;Iznos;Valuta` and [rows] (each `date;desc;amount`, currency EUR).
Uint8List _file(List<String> rows) => _b('Datum;Opis;Iznos;Valuta\n${rows.map((r) => '$r;EUR').join('\n')}\n');

void main() {
  group('text codecs', () {
    test('SHA-256 matches the FIPS test vectors', () {
      expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(sha256Hex(const []), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256Hex(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      expect(sha256Hex(List.filled(1000, 0x61)).length, 64);
    });

    test('Windows-1250 decodes the Croatian letters', () {
      expect(decodeWindows1250([0xE8, 0xE6, 0x9A, 0x9E, 0xF0, 0xC8, 0xC6, 0x8A, 0x8E, 0xD0]), 'čćšžđČĆŠŽĐ');
      expect(decodeWindows1250('plain'.codeUnits), 'plain');
      expect(decodeWindows1250([0x80, 0x81]), '€�');
    });
  });

  group('csvShape', () {
    test('UTF-8 with a BOM, `;`, header on the first row, quoted delimiter', () {
      final s = csvShape(_fx('bom_semicolon.csv'));
      expect(s.encoding, 'utf-8');
      expect(s.delimiter, ';');
      expect(s.delimiterName, 'semicolon');
      expect(s.headerRow, 0);
      expect(s.headers, ['Datum', 'Opis', 'Iznos', 'Valuta']);
      expect(s.samples.first, ['05.01.2026', 'Kupnja; SYNTH DUCAN', '-12,30', 'EUR']);
      expect(s.samples, hasLength(4));
      expect(s.sampleRows, [1, 2, 3, 4]);
      expect(s.shapeId, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('Windows-1250, title lines above the header (row 3), Croatian letters', () {
      final s = csvShape(_fx('hr_cp1250.csv'));
      expect(s.encoding, 'windows-1250');
      expect(s.delimiter, ';');
      expect(s.headerRow, 2);
      expect(s.headers, ['Datum knjiženja', 'Opis plaćanja', 'Primatelj', 'Duguje', 'Potražuje', 'Valuta']);
      expect(s.samples.first[2], 'SYNTH ĆEVAPI ŠĐŽ d.o.o.');
      expect(s.samples.last, ['13.01.2026.', 'Kupnja', '', '', '', ''], reason: 'a ragged row is padded');
      expect(s.head, hasLength(s.rowCount));
    });

    test('`,` with quoted commas, and tab', () {
      final c = csvShape(_fx('en_comma.csv'));
      expect(c.delimiter, ',');
      expect(c.headers, ['Date', 'Description', 'Amount', 'Currency']);
      expect(c.samples.last[2], '2,500.00');
      final t = csvShape(_fx('positive_tab.csv'));
      expect(t.delimiter, '\t');
      expect(t.delimiterName, 'tab');
      expect(t.headers, hasLength(5));
    });

    test('the shape id folds case and spaces, and differs for other headers', () {
      final a = csvShape(_b('Datum;Opis;Iznos\n01.01.2026;x;1,00\n')).shapeId;
      final b = csvShape(_b(' DATUM ;opis;  IZNOS\n02.01.2026;y;2,00\n')).shapeId;
      final c = csvShape(_b('Datum;Opis;Iznos;Valuta\n01.01.2026;x;1,00;EUR\n')).shapeId;
      expect(a, b);
      expect(a, isNot(c));
      expect(a, csvShapeId(['datum', 'opis', 'iznos']));
      expect(a, sha256Hex(utf8.encode('datum|opis|iznos')).substring(0, 16));
    });

    test('the owner can pick another header row', () {
      final bytes = _fx('hr_cp1250.csv');
      final s = csvShape(bytes, headerRow: 3);
      expect(s.headerRow, 3);
      expect(s.headers.first, '10.01.2026.');
      expect(s.samples, hasLength(3));
      expect(() => csvShape(bytes, headerRow: 1), throwsA(isA<ImportException>()), reason: 'one filled cell: nothing to map');
      expect(() => csvShape(bytes, headerRow: 99), throwsRangeError);
    });

    test('refused: too large, too many columns, no header, binary', () {
      expect(() => csvShape(Uint8List(maxImportBytes + 1)), throwsA(isA<ImportException>().having((e) => e.message, 'm', tooLargeMessage)));
      final wide = List.generate(maxCsvColumns + 1, (i) => 'Col$i').join(';');
      expect(() => csvShape(_b('$wide\n$wide\n')), throwsA(isA<ImportException>().having((e) => e.message, 'm', tooManyColumnsMessage)));
      final ok = List.generate(maxCsvColumns, (i) => 'Col$i').join(';');
      expect(csvShape(_b('$ok\n$ok\n')).headers, hasLength(maxCsvColumns));
      for (final bad in ['', 'just one line\n', '1;2;3\n4;5;6\n', 'Hello, prose.\nMore prose.\n']) {
        expect(() => csvShape(_b(bad)), throwsA(isA<ImportException>().having((e) => e.message, 'm', unknownLayoutMessage)), reason: bad);
      }
      expect(() => csvShape(Uint8List.fromList([0xFF, 0xFE, 0x44, 0, 0x3B, 0])), throwsA(isA<ImportException>()));
      expect(() => csvShape(_b('Datum;Opis\n"01.01.2026;open quote\n')), throwsA(isA<ImportException>()));
    });

    test('toString carries counts only', () {
      final s = csvShape(_fx('bom_semicolon.csv'));
      expect(s.toString(), isNot(contains('Datum')));
      expect(s.toString(), isNot(contains('SYNTH')));
    });
  });

  group('importBankFile', () {
    test('an unknown CSV throws NeedsMapping with its shape (an ImportException)', () {
      for (final f in ['bom_semicolon.csv', 'hr_cp1250.csv', 'en_comma.csv', 'positive_tab.csv']) {
        try {
          importBankFile(_fx(f));
          fail('$f imported');
        } on NeedsMapping catch (e) {
          expect(e, isA<ImportException>());
          expect(e.message, needsMappingMessage);
          expect(e.message, "This file isn't one I know yet. Map its columns once and it's remembered.");
          expect(e.shape.shapeId, csvShape(_fx(f)).shapeId);
        }
      }
    });

    test('PBZ and Revolut files still import as before', () {
      final csv = importBankFile(File('test/fixtures/revolut_synthetic.csv').readAsBytesSync());
      expect(csv.source, 'revolut');
    });
  });

  group('parseMappedCsv: amounts', () {
    test('one signed column, decimal comma, thousands dots, quoted delimiter', () {
      final bytes = _fx('bom_semicolon.csv');
      final shape = csvShape(bytes);
      final b = parseMappedCsv(bytes, _simple(headers: shape.headers));
      expect(b.source, 'csv:${shape.shapeId}');
      expect(b.transactions.map((t) => t.amountMinor), [-1230, 123456, -350, -350]);
      expect(b.transactions.first.description, 'Kupnja; SYNTH DUCAN');
      expect(b.transactions.first.date, '2026-01-05');
      expect(b.transactions.first.currency, 'EUR');
      expect(b.transactions.first.source, b.source);
      expect(b.invalid, 0);
    });

    test('debit and credit columns, Windows-1250 descriptions joined, ragged row invalid with its number', () {
      final bytes = _fx('hr_cp1250.csv');
      const m = CsvMapping(
          name: 'Synth bank',
          headerRow: 2,
          dateCol: 0,
          dateFormat: CsvDateFormat.dmyDot,
          debitCol: 3,
          creditCol: 4,
          descriptionCols: [1, 2],
          currencyCol: 5);
      expect(mappingProblems(csvShape(bytes), m), ['Row 7: no amount']);
      final b = parseMappedCsv(bytes, m);
      expect(b.transactions.map((t) => t.amountMinor), [-1230, 150000, -33]);
      expect(b.transactions.first.description, 'Kupnja čokolade · SYNTH ĆEVAPI ŠĐŽ d.o.o.');
      expect(b.transactions[2].description, 'Naknada', reason: 'empty parts are left out');
      expect(b.transactions.first.date, '2026-01-10', reason: 'a trailing dot after the year is fine');
      expect(b.invalid, 1);
      expect(b.invalidRows, [6]);
    });

    test('debit/credit: both filled is invalid, a signed debit is still money out, both empty is invalid', () {
      final bytes = _b('Datum;Opis;Duguje;Potražuje\n'
          '01.01.2026;a;1,00;2,00\n'
          '02.01.2026;b;-4,00;\n'
          '03.01.2026;c;;\n'
          '04.01.2026;d;0,00;5,00\n');
      const m = CsvMapping(name: 'x', headerRow: 0, dateCol: 0, dateFormat: CsvDateFormat.dmyDot, debitCol: 2, creditCol: 3);
      final b = parseMappedCsv(bytes, m);
      expect(b.transactions.map((t) => t.amountMinor), [-400, 500]);
      expect(b.invalidRows, [1, 3]);
      expect(mappingProblems(csvShape(bytes), m), ['Row 2: both a debit and a credit', 'Row 4: no amount']);
    });

    test('negate, point style with thousands commas, skip column, dd/mm/yyyy, tab', () {
      final bytes = _fx('positive_tab.csv');
      const m = CsvMapping(
          name: 'Positive',
          headerRow: 0,
          dateCol: 0,
          dateFormat: CsvDateFormat.dmySlash,
          amountCol: 3,
          decimal: CsvDecimal.point,
          negate: true,
          descriptionCols: [1, 2],
          skipIfEmptyCol: 4,
          currencyCode: 'USD');
      final b = parseMappedCsv(bytes, m);
      expect(b.transactions.map((t) => t.amountMinor), [-123456, 2000]);
      expect(b.transactions.map((t) => t.date), ['2026-03-03', '2026-03-04']);
      expect(b.transactions.map((t) => t.currency).toSet(), {'USD'});
      expect(b.skipped, 1);
      expect(b.invalid, 0);
    });

    test('a third decimal and an empty cell are invalid, never rounded or guessed', () {
      final bytes = _file(['01.01.2026;a;12,345', '02.01.2026;b;', '03.01.2026;c;12,3', '04.01.2026;d;abc', '05.01.2026;e;1.23,4']);
      final b = parseMappedCsv(bytes, _simple());
      expect(b.transactions.map((t) => t.amountMinor), [1230]);
      expect(b.invalidRows, [1, 2, 4, 5]);
      expect(
          mappingProblems(csvShape(bytes), _simple()),
          [
            'Row 2: the amount 12,345 has more than 2 decimals',
            'Row 3: no amount',
            'Row 5: the amount abc is not an amount',
            'Row 6: the amount 1.23,4 is not an amount',
          ],
          reason: 'the problems come from the 5 preview rows');
    });

    test('exact cents in both styles, signs, spaces and limits', () {
      expect(parseCsvCents('1.234,56', CsvDecimal.comma), 123456);
      expect(parseCsvCents('-1 234,5', CsvDecimal.comma), -123450);
      expect(parseCsvCents('+0,07', CsvDecimal.comma), 7);
      expect(parseCsvCents('−3,10', CsvDecimal.comma), -310);
      expect(parseCsvCents('1.234', CsvDecimal.comma), 123400);
      expect(parseCsvCents('12.30', CsvDecimal.comma), isNull, reason: 'a point is no decimal mark in comma style');
      expect(parseCsvCents('1,234.56', CsvDecimal.point), 123456);
      expect(parseCsvCents('0.1', CsvDecimal.point), 10);
      expect(parseCsvCents('12,30', CsvDecimal.point), isNull);
      expect(parseCsvCents('1.234', CsvDecimal.point), isNull, reason: 'three decimals');
      expect(parseCsvCents('19999999999.99', CsvDecimal.point), isNull, reason: 'over maxAmountCents');
      expect(parseCsvCents('9999999999.99', CsvDecimal.point), 999999999999);
      expect(parseCsvCents('1e3', CsvDecimal.point), isNull);
      expect(parseCsvCents('NaN', CsvDecimal.point), isNull);
      expect(parseCsvCents('', CsvDecimal.point), isNull);
      expect(parseCsvCents('0.29', CsvDecimal.point), 29, reason: 'no double rounding (0.29 * 100 = 28.999…)');
      expect(parseCsvCents('1.005', CsvDecimal.point), isNull);
    });
  });

  group('parseMappedCsv: dates', () {
    test('each format, with a trailing time', () {
      const cases = {
        CsvDateFormat.dmyDot: ['05.01.2026', '05.01.2026 14:22', '05.01.2026.'],
        CsvDateFormat.dmyDotShort: ['5.1.2026', '05.01.2026', '5.1.2026 08:00:00'],
        CsvDateFormat.iso: ['2026-01-05', '2026-01-05T10:00:00Z', '2026-01-05 10:00'],
        CsvDateFormat.dmySlash: ['05/01/2026', '5/1/2026 10:00'],
        CsvDateFormat.mdySlash: ['01/05/2026', '1/5/2026 10:00 PM'],
        CsvDateFormat.dmyDash: ['05-01-2026', '05-01-2026 10:00'],
      };
      for (final MapEntry(key: f, value: inputs) in cases.entries) {
        for (final s in inputs) {
          expect(parseCsvDate(s, f), '2026-01-05', reason: '${f.pattern} $s');
        }
      }
    });

    test('invalid dates and other formats are refused', () {
      expect(parseCsvDate('31.02.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('29.02.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('29.02.2028', CsvDateFormat.dmyDot), '2028-02-29');
      expect(parseCsvDate('5.1.2026', CsvDateFormat.dmyDot), isNull, reason: 'dd.mm.yyyy needs two digits');
      expect(parseCsvDate('2026-13-01', CsvDateFormat.iso), isNull);
      expect(parseCsvDate('13/13/2026', CsvDateFormat.mdySlash), isNull);
      expect(parseCsvDate('05.01.2026', CsvDateFormat.iso), isNull);
      expect(parseCsvDate('05.01.26', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('00.01.2026', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('05.01.1899', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('05.01.2026x', CsvDateFormat.dmyDot), isNull);
      expect(parseCsvDate('', CsvDateFormat.dmyDot), isNull);
      final bytes = _file(['31.02.2026;a;1,00', ';b;1,00', 'Ukupno;;5,00']);
      final b = parseMappedCsv(bytes, _simple());
      expect(b.transactions, isEmpty);
      expect(b.invalidRows, [1, 2, 3]);
      expect(mappingProblems(csvShape(bytes), _simple()),
          ['Row 2: the date 31.02.2026 is not a date', 'Row 3: no date', 'Row 4: the date Ukupno is not a date']);
    });

    test('ISO dates with a time and point decimals (en_comma.csv)', () {
      final bytes = _fx('en_comma.csv');
      final m = _simple(format: CsvDateFormat.iso, decimal: CsvDecimal.point);
      final b = parseMappedCsv(bytes, m);
      expect(b.transactions.map((t) => t.date), ['2026-02-01', '2026-02-01', '2026-02-01', '2026-02-02']);
      expect(b.transactions.map((t) => t.amountMinor), [-1230, -250, -250, 250000]);
      expect(b.transactions.first.description, 'Shop, with comma');
    });
  });

  group('ids', () {
    test('stable across two imports, twin rows get the occurrence counter', () {
      final bytes = _fx('en_comma.csv');
      final m = _simple(format: CsvDateFormat.iso, decimal: CsvDecimal.point);
      final a = parseMappedCsv(bytes, m), b = parseMappedCsv(Uint8List.fromList(bytes), m);
      expect(a.transactions.map((t) => t.id), b.transactions.map((t) => t.id));
      final twins = a.transactions.where((t) => t.description == 'Synth Coffee').toList();
      expect(twins[1].id, '${twins[0].id}_1');
      expect(a.transactions.map((t) => t.id).toSet(), hasLength(4));
      expect(twins[0].id, sourceTransactionId(a.source, '2026-02-01', -250, 'Synth Coffee', 0));
    });

    test('different from PBZ/Revolut (v1) ids for the same values, and per shape', () {
      final a = parseMappedCsv(_fx('bom_semicolon.csv'), _simple()).transactions.first;
      expect(a.id, isNot(transactionId(a.date, a.amountMinor, a.description, 0)));
      // Another shape with the same row: another source, another id.
      final other = _b('Datum;Opis;Iznos;Valuta;Extra\n05.01.2026;"Kupnja; SYNTH DUCAN";-12,30;EUR;x\n');
      final o = parseMappedCsv(other, _simple()).transactions.single;
      expect(o.source, isNot(a.source));
      expect(o.id, isNot(a.id));
    });

    test('two files of one shape: the same row gives the same id, other rows never collide', () {
      final f1 = _file(['01.01.2026;Shop A;-1,00', '02.01.2026;Shop B;-2,00']);
      final f2 = _file(['02.01.2026;Shop B;-2,00', '03.01.2026;Shop C;-3,00']);
      final a = parseMappedCsv(f1, _simple()), b = parseMappedCsv(f2, _simple());
      expect(a.source, b.source);
      expect(a.transactions[1].id, b.transactions[0].id);
      expect(a.transactions.map((t) => t.id).toSet().intersection(b.transactions.map((t) => t.id).toSet()), {a.transactions[1].id});
    });
  });

  group('mapping', () {
    test('JSON round trip, both amount modes', () {
      final m = _simple(negate: true, headers: ['Datum', 'Opis', 'Iznos', 'Valuta']).copyWith(skipIfEmptyCol: 1);
      final back = CsvMapping.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(back, m);
      expect(back.toJson(), m.toJson());
      const split = CsvMapping(
          name: 'S', headerRow: 2, dateCol: 0, dateFormat: CsvDateFormat.mdySlash, debitCol: 3, creditCol: 4, currencyCode: 'GBP');
      expect(CsvMapping.fromJson(jsonDecode(jsonEncode(split.toJson()))), split);
      expect(split.toJson()['amount'], {'debit': 3, 'credit': 4});
      expect(split.toJson()['currency'], {'code': 'GBP'});
      expect(split.toJson()['date'], {'col': 0, 'format': 'mm/dd/yyyy'});
      expect(m.copyWith(currencyCol: null).currencyCol, isNull);
    });

    test('a damaged JSON value is a FormatException', () {
      final good = _simple().toJson();
      for (final bad in <Object?>[
        null,
        'x',
        {...good, 'date': null},
        {
          ...good,
          'date': {'col': 0, 'format': 'dd.mm.yy'}
        },
        {...good, 'decimal': 'dot'},
        {...good, 'name': 3},
        {
          ...good,
          'amount': {'col': '2'}
        },
        {...good, 'negate': 'yes'},
        {
          ...good,
          'headers': [1]
        },
      ]) {
        expect(() => CsvMapping.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('structure problems', () {
      final shape = csvShape(_fx('bom_semicolon.csv'));
      expect(mappingProblems(shape, _simple()), isEmpty);
      expect(mappingProblems(shape, _simple().copyWith(name: ' ')), ['Give the layout a name.']);
      expect(mappingProblems(shape, _simple().copyWith(name: 'x' * 31)), ['The name is limited to 30 characters.']);
      expect(mappingProblems(shape, _simple().copyWith(amountCol: 9)), ['Pick the amount column.']);
      expect(mappingProblems(shape, _simple().copyWith(amountCol: null)), ['Pick the amount column.']);
      expect(mappingProblems(shape, _simple().copyWith(amountCol: null, debitCol: 2)), ['Pick both the debit and the credit column.']);
      expect(mappingProblems(shape, _simple().copyWith(amountCol: null, debitCol: 2, creditCol: 2)),
          ['Debit and credit must be different columns.']);
      expect(mappingProblems(shape, _simple().copyWith(currencyCol: null, currencyCode: 'eur')),
          ['The currency is three capital letters, like EUR.']);
      expect(mappingProblems(shape, _simple().copyWith(headerRow: 1)), hasLength(1));
      expect(mappingProblems(shape, _simple(headers: ['A', 'B', 'C', 'D'])), [layoutMismatchMessage]);
      expect(() => parseMappedCsv(_fx('bom_semicolon.csv'), _simple(headers: ['A', 'B', 'C', 'D'])),
          throwsA(isA<ImportException>().having((e) => e.message, 'm', layoutMismatchMessage)));
      expect(() => parseMappedCsv(_fx('bom_semicolon.csv'), _simple().copyWith(name: '')), throwsA(isA<ImportException>()));
    });

    test('currency column: codes, the euro sign, bad and empty cells', () {
      final bytes = _b('Datum;Opis;Iznos;Valuta\n01.01.2026;a;1,00;usd\n02.01.2026;b;1,00;€\n03.01.2026;c;1,00;Euro\n04.01.2026;d;1,00;\n');
      final b = parseMappedCsv(bytes, _simple());
      expect(b.transactions.map((t) => t.currency), ['USD', 'EUR']);
      expect(mappingProblems(csvShape(bytes), _simple()), ['Row 4: the currency Euro is not a currency code', 'Row 5: no currency']);
      // No currency column: the fixed code, else the wallet's.
      final noCol = _simple().copyWith(currencyCol: null);
      expect(parseMappedCsv(bytes, noCol, walletCurrency: 'CHF').transactions.map((t) => t.currency).toSet(), {'CHF'});
      expect(parseMappedCsv(bytes, noCol.copyWith(currencyCode: 'GBP'), walletCurrency: 'CHF').transactions.first.currency, 'GBP');
    });

    test('the preview reads the sample rows', () {
      final shape = csvShape(_fx('hr_cp1250.csv'));
      final m = guessMapping(shape)!;
      final rows = previewMapping(shape, m);
      expect(rows.map((r) => r.row), [3, 4, 5, 6]);
      expect(rows.first.amountMinor, -1230);
      expect(rows.first.date, '2026-01-10');
      expect(rows.last.ok, isFalse);
      expect(rows.last.problem, 'Row 7: no amount');
    });

    test('a layout made from another header row is found again', () {
      final bytes = _b('Title line;Account x;\nDatum;Opis;Iznos\n01.01.2026;a;1,00\n');
      final auto = csvShape(bytes);
      expect(auto.headerRow, 0, reason: 'the title row has text in it, so it is taken first');
      final moved = csvShape(bytes, headerRow: 1);
      final saved = {moved.shapeId: guessMapping(moved)!};
      expect(matchCsvMapping(bytes, auto, saved), moved.shapeId);
      expect(matchCsvMapping(bytes, moved, saved), moved.shapeId);
      expect(matchCsvMapping(_fx('en_comma.csv'), csvShape(_fx('en_comma.csv')), saved), isNull);
    });
  });

  group('guessMapping', () {
    test('Croatian headers: Datum, Duguje/Potražuje, Opis, Primatelj, Valuta', () {
      final shape = csvShape(_fx('hr_cp1250.csv'));
      final m = guessMapping(shape)!;
      expect(m.dateCol, 0);
      expect(m.dateFormat, CsvDateFormat.dmyDot);
      expect((m.amountCol, m.debitCol, m.creditCol), (null, 3, 4));
      expect(m.descriptionCols, [1, 2]);
      expect(m.currencyCol, 5);
      expect(m.decimal, CsvDecimal.comma);
      expect(m.headerRow, 2);
      expect(m.headers, shape.headers);
      expect(m.name, isNotEmpty);
      expect(m.structureProblems(), isEmpty);
    });

    test('Croatian single amount: Datum, Opis, Iznos, Valuta', () {
      final m = guessMapping(csvShape(_fx('bom_semicolon.csv')))!;
      expect((m.dateCol, m.amountCol, m.currencyCol, m.decimal), (0, 2, 3, CsvDecimal.comma));
      expect(m.descriptionCols, [1]);
    });

    test('English headers, ISO dates with time, point decimals', () {
      final m = guessMapping(csvShape(_fx('en_comma.csv')))!;
      expect((m.dateCol, m.amountCol, m.currencyCol), (0, 2, 3));
      expect(m.descriptionCols, [1]);
      expect(m.dateFormat, CsvDateFormat.iso);
      expect(m.decimal, CsvDecimal.point);
      expect(mappingProblems(csvShape(_fx('en_comma.csv')), m), isEmpty);
    });

    test('English debit/credit, dd/mm vs mm/dd from the samples', () {
      final dm = csvShape(_b('Date,Payee,Debit,Credit\n25/01/2026,Shop,1.00,\n'));
      final g = guessMapping(dm)!;
      expect((g.debitCol, g.creditCol), (2, 3));
      expect(g.descriptionCols, [1]);
      expect(g.dateFormat, CsvDateFormat.dmySlash);
      expect(g.decimal, CsvDecimal.point);
      final md = csvShape(_b('Date,Payee,Amount\n01/25/2026,Shop,-1.00\n'));
      expect(guessMapping(md)!.dateFormat, CsvDateFormat.mdySlash);
    });

    test('a balance column is never the amount; no date or amount = no guess', () {
      final m = guessMapping(csvShape(_b('Datum;Opis;Saldo iznos;Iznos\n01.01.2026;a;5,00;1,00\n')))!;
      expect(m.amountCol, 3);
      expect(guessMapping(csvShape(_b('Opis;Iznos\na;1,00\n'))), isNull);
      expect(guessMapping(csvShape(_b('Datum;Opis\n01.01.2026;a\n'))), isNull);
    });
  });

  group('logs', () {
    test('counts, encoding and delimiter only: never headers, cells, names or file names', () async {
      final lines = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add('${r.loggerName} ${r.message} ${r.error ?? ''}'));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = Level.INFO;
      });
      final bytes = _fx('hr_cp1250.csv');
      expect(() => importBankFile(bytes, fileName: 'secret-name.csv'), throwsA(isA<NeedsMapping>()));
      final shape = csvShape(bytes);
      final m = guessMapping(shape)!.copyWith(name: 'Owner Label');
      mappingProblems(shape, m);
      parseMappedCsv(bytes, m, fileName: 'secret-name.csv');
      final text = lines.join('\n');
      expect(text, contains('"mapped":true'));
      expect(text, contains('"encoding":"windows-1250"'));
      expect(text, contains('"delimiter":"semicolon"'));
      for (final p in ['Datum', 'Opis', 'Primatelj', 'SYNTH', 'Kupnja', 'Owner Label', 'secret-name', '12,30', '1.500', shape.shapeId]) {
        expect(text, isNot(contains(p)), reason: p);
      }
    });
  });
}
