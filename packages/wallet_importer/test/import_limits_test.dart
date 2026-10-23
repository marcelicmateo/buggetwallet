// H4: PBZ detection by the whole header row, password-protected files, size and inflate caps. Files are built in code
// (test/support/biff.dart, archive), SYNTHETIC.
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/biff.dart';

final _unknown = throwsA(isA<ImportException>().having((e) => e.message, 'message', unknownLayoutMessage));
Matcher _refused(String message) => throwsA(isA<ImportException>().having((e) => e.message, 'message', message));

const _header = ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'];

/// A PBZ-like .xls: the account label on row 0, [header] cells on row 1 (each a LABEL), one card row on row 2.
Uint8List _xls(List<List<(int, int, String)>> labels, {List<int> globals = const []}) => ole2(workbook([
      [
        for (final (r, c, s) in labels.expand((l) => l)) ...label(r, c, s),
        ...number(9, 0, 46037),
        ...label(9, 1, 'POS plaćanje'),
        ...label(9, 2, 'Synthetic shop'),
        ...number(9, 3, -2),
        ...label(9, 4, 'EUR'),
      ],
    ], sstRecords: globals));

List<(int, int, String)> _row(int r, List<String> cells) => [for (var c = 0; c < cells.length; c++) (r, c, cells[c])];

Uint8List _zip(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, bytes) => a.addFile(ArchiveFile.bytes(name, bytes)));
  return ZipEncoder().encodeBytes(a);
}

void main() {
  group('PbzProfile.detect needs the whole header on one row', () {
    test('the full header row imports', () {
      final b = importBankFile(_xls([
        _row(0, ['TRANSAKCIJSKI RAČUN:']),
        _row(1, _header),
      ]));
      expect((b.source, b.transactions.length), ('pbz', 1));
    });

    test('lower case, padding and a mis-decoded Ć still match', () {
      final b = parseRows([
        [' datum ', 'Vrsta transakcije', 'OPIS PLAÄ\u0086ANJA', 'iznos', 'Valuta'],
        [46037.0, 'POS plaćanje', 'x', -1.0, 'EUR'],
      ]);
      expect(b?.source, 'pbz');
    });

    test('the header split across two rows is not PBZ', () {
      expect(
          () => importBankFile(_xls([
                _row(0, ['TRANSAKCIJSKI RAČUN:']),
                _row(1, _header.sublist(0, 2)),
                [for (var c = 2; c < _header.length; c++) (2, c, _header[c])],
              ])),
          _unknown);
    });

    test('a header from another bank (the account label and a DATUM column, other columns) is not PBZ', () {
      expect(
          () => importBankFile(_xls([
                _row(0, ['TRANSAKCIJSKI RAČUN:']),
                _row(1, ['DATUM', 'OPIS', 'IZNOS', 'STANJE', 'VALUTA']),
              ])),
          _unknown);
      expect(
          parseRows([
            ['DATUM'],
            [46037.0, 'POS plaćanje', 'x', -1.0, 'EUR'],
          ]),
          isNull);
    });

    test('the header shifted one column right is not PBZ (the columns are read by position)', () {
      expect(
          parseRows([
            ['', ..._header],
            [46037.0, 'POS plaćanje', 'x', -1.0, 'EUR'],
          ]),
          isNull);
    });

    test('the header below the first 15 rows is not seen', () {
      expect(
          parseRows([
            for (var i = 0; i < headRows; i++) ['x'],
            _header,
            [46037.0, 'POS plaćanje', 'x', -1.0, 'EUR'],
          ]),
          isNull);
      expect(
          parseRows([
            for (var i = 0; i < headRows - 1; i++) ['x'],
            _header,
            [46037.0, 'POS plaćanje', 'x', -1.0, 'EUR'],
          ])?.source,
          'pbz');
    });
  });

  group('password-protected files', () {
    final filepass = rec(0x002F, [...u16(1), ...u16(1), ...u16(1), ...List.filled(48, 0)]);

    test('an .xls with a FILEPASS record says password-protected, not damaged', () {
      expect(
          () => importBankFile(_xls([
                _row(0, ['TRANSAKCIJSKI RAČUN:']),
                _row(1, _header)
              ], globals: filepass)),
          _refused(passwordProtectedMessage));
      expect(passwordProtectedMessage, contains('password-protected'));
    });

    test('a FILEPASS record inside a sheet (after the globals) is not the workbook password', () {
      final file = ole2(workbook([
        [
          ..._row(1, _header).expand((l) => label(l.$1, l.$2, l.$3)),
          ...filepass,
          ...number(2, 0, 46037),
          ...label(2, 1, 'T'),
          ...number(2, 3, -1)
        ],
      ]));
      expect(importBankFile(file).source, 'pbz');
    });

    test('an Office file encrypted as a whole (EncryptedPackage stream) says password-protected', () {
      expect(() => importBankFile(ole2(List.filled(600, 7), streamName: 'EncryptedPackage')), _refused(passwordProtectedMessage));
    });
  });

  group('size caps', () {
    test('a file of exactly maxImportBytes is read; one byte more is refused before reading', () {
      expect(maxImportBytes, 20 * 1024 * 1024);
      expect(() => importBankFile(Uint8List(maxImportBytes)),
          throwsA(isA<ImportException>().having((e) => e.message, 'message', isNot(tooLargeMessage))));
      expect(() => importBankFile(Uint8List(maxImportBytes + 1)), _refused(tooLargeMessage));
    });

    test('an .xlsx bomb (a small file unpacking past maxXlsxUnpackedBytes) is refused, not inflated', () {
      expect(maxXlsxUnpackedBytes, greaterThanOrEqualTo(64 * 1024 * 1024));
      final bomb = _zip({'xl/worksheets/sheet1.xml': Uint8List(maxXlsxUnpackedBytes + 1)});
      expect(bomb.length, lessThan(maxImportBytes));
      expect(() => importBankFile(bomb), _refused(tooLargeMessage));
    });

    test('entries are summed: several parts each under the cap but together over it are refused', () {
      final part = Uint8List(maxXlsxUnpackedBytes ~/ 3 + 1);
      final bomb = _zip({'xl/worksheets/sheet1.xml': part, 'xl/sharedStrings.xml': part, 'xl/styles.xml': part});
      expect(() => importBankFile(bomb), _refused(tooLargeMessage));
    });

    test('refusals log the reason and sizes only', () {
      final lines = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add('${r.loggerName} ${r.message}'));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = Level.INFO;
      });
      expect(() => importBankFile(Uint8List(maxImportBytes + 1)), throwsA(isA<ImportException>()));
      expect(() => importBankFile(_xls([_row(1, _header)], globals: rec(0x002F, List.filled(54, 0)))), throwsA(isA<ImportException>()));
      final text = lines.join('\n');
      expect(text, contains('importer.refused {"reason":"tooLarge","bytes":${maxImportBytes + 1}}'));
      expect(text, contains('importer.refused {"format":"xls","reason":"filepass","bytes":'));
      expect(text, isNot(contains('Synthetic shop')));
    });
  });
}
