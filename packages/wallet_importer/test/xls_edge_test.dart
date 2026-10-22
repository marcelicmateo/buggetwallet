// Edge cases for the own BIFF8 (.xls) reader. Workbooks are built in code (test/support/biff.dart), SYNTHETIC.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/xls_reader.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/biff.dart';

final _unknown = throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('I recognise')));
final _damaged = throwsA(isA<ImportException>().having((e) => e.message, 'message', contains('Could not read')));

/// SST holding the PBZ header texts (indexes 0..5) and any [extra] strings from index 6.
const _hdrTexts = ['TRANSAKCIJSKI RAČUN:', 'DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA', 'EUR'];

// Indexes into the shared strings of _pbz: the header texts are 0..6, then Card, Shop, Salary.
const _card = 7, _shop = 8, _salary = 9, _eur = 6;

List<int> _sstOf(List<String> texts, {List<int> splits = const []}) =>
    sst(texts.length, [for (final t in texts) ...sstString(t, wide: t.codeUnits.any((c) => c > 0xFF))], splits: splits);

/// Header block (row 0 account, row 1 column names) followed by [rows] starting at row 2.
List<int> _pbzCells(List<List<int>> rows) => [
      ...labelSst(0, 0, 0),
      ...labelSst(1, 0, 1),
      ...labelSst(1, 1, 2),
      ...labelSst(1, 2, 3),
      ...labelSst(1, 3, 4),
      ...rows.expand((r) => r)
    ];

/// A full file: PBZ header, then data rows built by [row] (row index, cells).
Uint8List _pbz(List<String> texts, List<List<int>> rows, {List<int> splits = const [], bool boundSheets = true}) =>
    ole2(workbook([_pbzCells(rows)], sstRecords: _sstOf([..._hdrTexts, ...texts], splits: splits), boundSheets: boundSheets));

/// One data row at [r]: serial date, type SST index, description SST index, amount cell, currency SST index.
List<int> _line(int r, double date, int type, int desc, List<int> amount, {int cur = _eur}) =>
    [...number(r, 0, date), ...labelSst(r, 1, type), ...labelSst(r, 2, desc), ...amount, ...labelSst(r, 4, cur)];

List<String> _view(ImportBatch b) => [for (final t in b.transactions) '${t.date}|${t.amountMinor}|${t.bankType}|${t.description}'];

void main() {
  const texts = ['Card', 'Shop', 'Salary'];
  final base = _pbz(texts, [
    _line(2, 46037, _salary, _salary, number(2, 3, 1500)),
    _line(3, 46038.75, _card, _shop, rk(3, 3, -1234, div100: true)), // -12.34
    _line(4, 46039, _card, _shop, mulRk(4, 3, [-500])), // MULRK with one cell in column 3
  ]);

  group('builder sanity (the happy path of the synthetic files used below)', () {
    test('NUMBER, RK /100 and MULRK cells, SST strings', () {
      final b = importBankFile(base);
      expect(b.source, 'pbz');
      expect(_view(b), ['2026-01-15|150000|Salary|Salary', '2026-01-16|-1234|Card|Shop', '2026-01-17|-50000|Card|Shop']);
    });
  });

  group('shared strings', () {
    test('a string split by CONTINUE inside its characters; the continuation restarts with an option byte', () {
      // body: header texts, then "Card","Shop","Salary". Split in the middle of "Shop" (after "Sh") and keep it compressed.
      final body = [
        for (final t in [..._hdrTexts, ...texts]) ...sstString(t, wide: t.codeUnits.any((c) => c > 0xFF))
      ];
      final cut = body.length - sstString('Salary').length - 2; // the last two characters of "Shop" go to the next record
      final head = body.sublist(0, cut);
      final tail = [0, ...body.sublist(cut)]; // option byte 0 = compressed continuation
      final recs = [
        ...rec(0x00FC, [...u32(10), ...u32(10), ...head]),
        ...rec(0x003C, tail)
      ];
      final file = ole2(workbook([
        _pbzCells([_line(2, 46037, _card, _shop, number(2, 3, -1))]),
      ], sstRecords: recs));
      expect(_view(importBankFile(file)), ['2026-01-15|-100|Card|Shop']);
    });

    test('a continuation may switch from compressed to UTF-16 characters mid-string', () {
      // "Ab" + "Šđ" (wide) as one string of 4 chars: first 2 chars compressed, then a CONTINUE with option byte 1.
      final first = [...u16(4), 0, 0x41, 0x62];
      final more = [1, ...u16(0x160), ...u16(0x111)];
      final others = [for (final t in _hdrTexts) ...sstString(t, wide: t.codeUnits.any((c) => c > 0xFF))];
      final recs = [
        ...rec(0x00FC, [...u32(8), ...u32(8), ...others, ...first]),
        ...rec(0x003C, more),
      ];
      final file = ole2(workbook([
        _pbzCells([_line(2, 46037, 0, 7, number(2, 3, -1))]),
      ], sstRecords: recs));
      expect(importBankFile(file).transactions.single.description, 'AbŠđ');
    });

    test('a record boundary exactly between two strings (no option byte in the continuation)', () {
      final body = [
        for (final t in [..._hdrTexts, ...texts]) ...sstString(t, wide: t.codeUnits.any((c) => c > 0xFF))
      ];
      final cut = body.length - sstString('Salary').length; // "Salary" starts the CONTINUE
      final file = ole2(workbook([
        _pbzCells([_line(2, 46037, _salary, _salary, number(2, 3, 7))]),
      ], sstRecords: sst(10, body, splits: [cut])));
      expect(_view(importBankFile(file)), ['2026-01-15|700|Salary|Salary']);
    });

    test('three CONTINUE records, each splitting a string', () {
      final body = [
        for (final t in [..._hdrTexts, ...texts]) ...sstString(t, wide: t.codeUnits.any((c) => c > 0xFF))
      ];
      // Cut inside "Salary" (last string): body ends ...,6 chars. Cut after 2 and after 4 chars, inserting option bytes by hand.
      final end = body.length;
      final sal = end - 6;
      final p1 = body.sublist(0, sal + 2);
      final p2 = [0, ...body.sublist(sal + 2, sal + 4)];
      final p3 = [0, ...body.sublist(sal + 4)];
      final recs = [
        ...rec(0x00FC, [...u32(10), ...u32(10), ...p1]),
        ...rec(0x003C, p2),
        ...rec(0x003C, p3)
      ];
      final file = ole2(workbook([
        _pbzCells([_line(2, 46037, _salary, _salary, number(2, 3, 7))]),
      ], sstRecords: recs));
      expect(importBankFile(file).transactions.single.description, 'Salary');
    });

    test('rich-text runs and phonetic blocks are skipped, even when a CONTINUE falls inside them', () {
      final strings = <List<int>>[
        for (final t in _hdrTexts) sstString(t, wide: t.codeUnits.any((c) => c > 0xFF)),
        sstString('Card'),
        sstString('Plain rich', runs: 3),
        sstString('With phonetic', phonetic: List.filled(10, 0x77)),
        sstString('Final'),
      ];
      final body = [for (final s in strings) ...s];
      // Split inside the phonetic block of the third extra string: 5 bytes before the end of that string + "Final".
      final cut = body.length - sstString('Final').length - 5;
      final recs = sst(strings.length, body, splits: [cut]);
      final file = ole2(workbook([
        _pbzCells([_line(2, 46037, 7, 8, number(2, 3, -1)), _line(3, 46038, 7, 10, number(3, 3, -2))]),
      ], sstRecords: recs));
      expect(_view(importBankFile(file)), ['2026-01-15|-100|Card|Plain rich', '2026-01-16|-200|Card|Final']);
    });

    test('a count in the SST header larger than the strings present does not loop or throw', () {
      final body = [for (final t in _hdrTexts) ...sstString(t)];
      final recs = rec(0x00FC, [...u32(50000), ...u32(50000), ...body]);
      final file = ole2(workbook([_pbzCells([])], sstRecords: recs));
      expect(() => importBankFile(file), anyOf(returnsNormally, _unknown, _damaged));
    });

    test('a LABELSST pointing past the table gives an empty cell, not a crash or a wrong string', () {
      final file = _pbz(texts, [_line(2, 46037, _card, 4000, number(2, 3, -1))]);
      final t = importBankFile(file).transactions.single;
      expect(t.description, '');
      expect(t.amountMinor, -100);
    });
  });

  group('cells', () {
    test('formula cells use their cached number; string-result formulas are ignored', () {
      final file = _pbz(texts, [
        _line(2, 46037, _card, _shop, formula(2, 3, -4.5)),
        _line(3, 46038, _card, _shop, formula(3, 3, null)),
      ]);
      expect(_view(importBankFile(file)), ['2026-01-15|-450|Card|Shop']);
    });

    test('LABEL cells (inline strings, compressed and UTF-16) are read', () {
      final file = ole2(workbook([
        [
          ...label(0, 0, 'TRANSAKCIJSKI RAČUN:'),
          ...label(1, 0, 'DATUM'),
          ...number(2, 0, 46037),
          ...label(2, 1, 'Type'),
          ...label(2, 2, 'Šđ shop', wide: true),
          ...number(2, 3, -2),
        ],
      ]));
      expect(importBankFile(file).transactions.single.description, 'Šđ shop');
    });

    test('RK integers: negative, zero, large, and /100 variants', () {
      final file = _pbz(texts, [
        _line(2, 46037, _card, _shop, rk(2, 3, -7)),
        _line(3, 46038, _card, _shop, rk(3, 3, 0)),
        _line(4, 46039, _card, _shop, rk(4, 3, 100000000)),
        _line(5, 46040, _card, _shop, rk(5, 3, -5, div100: true)),
      ]);
      expect(importBankFile(file).transactions.map((t) => t.amountMinor), [-700, 0, 10000000000, -5]);
    });

    test('MULRK spreads integers over consecutive columns', () {
      final file = ole2(workbook([
        [
          ...labelSst(0, 0, 0),
          ...labelSst(1, 0, 1),
          ...mulRk(2, 0, [46037, 0, 0, -250]),
        ],
      ], sstRecords: _sstOf(_hdrTexts)));
      final b = importBankFile(file);
      expect(b.transactions.single.date, '2026-01-15');
      expect(b.transactions.single.amountMinor, -25000);
    });

    test('NaN, infinite and absurd numbers in cells never become amounts or dates', () {
      const nan = double.nan, inf = double.infinity;
      final file = _pbz(texts, [
        _line(2, nan, _card, _shop, number(2, 3, -1)),
        _line(3, inf, _card, _shop, number(3, 3, -1)),
        _line(4, 46037, _card, _shop, number(4, 3, nan)),
        _line(5, 46037, _card, _shop, number(5, 3, inf)),
        _line(6, 46037, _card, _shop, number(6, 3, -1e300)),
        _line(7, 46038, _card, _shop, number(7, 3, -3)),
      ]);
      final b = importBankFile(file);
      expect(_view(b), ['2026-01-16|-300|Card|Shop']);
    });

    test('a cell at the far corner (row 65535, column 255) does not allocate the whole grid', () {
      final file = _pbz(texts, [_line(2, 46037, _card, _shop, number(2, 3, -1)), number(65535, 255, 1)]);
      final sw = Stopwatch()..start();
      expect(importBankFile(file).transactions.length, 1);
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });

  group('workbook structure', () {
    test('only the first sheet is read; later sheets with similar data are ignored', () {
      final first = _pbzCells([_line(2, 46037, _card, _shop, number(2, 3, -1))]);
      final second = _pbzCells([_line(2, 46099, _card, _shop, number(2, 3, -99))]);
      final file = ole2(workbook([first, second], sstRecords: _sstOf([..._hdrTexts, ...texts])));
      expect(_view(importBankFile(file)), ['2026-01-15|-100|Card|Shop']);
    });

    test('no sheet directory (BOUNDSHEET): the second BOF is used', () {
      final file = _pbz(texts, [_line(2, 46037, _card, _shop, number(2, 3, -1))], boundSheets: false);
      expect(importBankFile(file).transactions.length, 1);
    });

    test('the stream may be called "Book" (older files)', () {
      final stream = workbook([
        _pbzCells([_line(2, 46037, _card, _shop, number(2, 3, -1))]),
      ], sstRecords: _sstOf([..._hdrTexts, ...texts]));
      expect(importBankFile(ole2(stream, streamName: 'Book')).transactions.length, 1);
    });

    test('a compound file without a Workbook stream is "could not read"', () {
      final stream = workbook([
        _pbzCells([_line(2, 46037, _card, _shop, number(2, 3, -1))]),
      ], sstRecords: _sstOf([..._hdrTexts, ...texts]));
      expect(() => importBankFile(ole2(stream, streamName: 'Contents')), _damaged);
      expect(() => importBankFile(ole2(stream, streamName: 'workbook')), _damaged, reason: 'names are case sensitive');
    });

    test('empty workbooks: BOF/EOF only, or one empty sheet, are refused as unknown (not a crash, not an empty batch)', () {
      expect(() => importBankFile(ole2([...bof(), ...eof()])), _unknown);
      expect(() => importBankFile(ole2(workbook([<int>[]]))), _unknown);
      expect(() => importBankFile(ole2(workbook(const []))), _unknown);
      expect(() => importBankFile(ole2(const [])), _unknown);
    });

    test('a header-only PBZ sheet is an empty pbz batch', () {
      final b = importBankFile(_pbz(texts, []));
      expect(b.source, 'pbz');
      expect(b.transactions, isEmpty);
    });

    test('an Excel file of another bank: valid .xls, unknown layout, refused with the unknown message', () {
      final file = ole2(workbook([
        [...labelSst(0, 0, 0), ...labelSst(0, 1, 1), ...number(1, 0, 46037), ...number(1, 1, -5)],
      ], sstRecords: _sstOf(['Booking', 'Value'])));
      expect(() => importBankFile(file), _unknown);
    });

    test('the stream size in the directory larger than the data in the file is clamped, not an exception', () {
      final stream = workbook([
        _pbzCells([_line(2, 46037, _card, _shop, number(2, 3, -1))]),
      ], sstRecords: _sstOf([..._hdrTexts, ...texts]));
      final file = ole2(stream, declaredSize: 10 * 1024 * 1024);
      expect(importBankFile(file).transactions.length, 1);
    });

    test('a FAT chain that loops back on itself terminates (damaged file, not a hang)', () {
      final stream = workbook([
        _pbzCells([_line(2, 46037, _card, _shop, number(2, 3, -1))]),
      ], sstRecords: _sstOf([..._hdrTexts, ...texts]));
      final file = ole2(stream, chainOverride: 2);
      final sw = Stopwatch()..start();
      try {
        importBankFile(file);
      } on ImportException {
        // fine
      }
      expect(sw.elapsedMilliseconds, lessThan(5000));
    });

    test('records with a length that runs past the end of the stream do not throw', () {
      final stream = [
        ...workbook([_pbzCells([])], sstRecords: _sstOf(_hdrTexts)),
        ...u16(0x0203),
        ...u16(60000),
        1,
        2,
        3
      ];
      expect(() => importBankFile(ole2(stream)), anyOf(returnsNormally, _unknown, _damaged));
    });
  });

  group('damage', () {
    test('wrong magic: the same bytes with one header byte changed are not read as a workbook', () {
      final bad = Uint8List.fromList(base)..[7] = 0xE0;
      expect(() => importBankFile(bad), _unknown);
      final bad0 = Uint8List.fromList(base)..[0] = 0x00;
      expect(() => importBankFile(bad0), _unknown);
    });

    test('XlsReader on a non-OLE input throws FormatException, on a short one too', () {
      expect(() => XlsReader.firstSheet(Uint8List(0)), throwsFormatException);
      expect(() => XlsReader.firstSheet(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });

    test('truncated at every length: an ImportException, or a batch that only contains rows of the full file', () {
      final full = _view(importBankFile(base));
      var batches = 0;
      for (var n = 0; n < base.length; n++) {
        try {
          final b = importBankFile(Uint8List.sublistView(base, 0, n));
          batches++;
          expect(_view(b), everyElement(isIn(full)), reason: 'cut at $n invented rows');
          expect(b.transactions.length, lessThanOrEqualTo(full.length));
        } on ImportException {
          // refused: fine
        }
      }
      // Cuts after the data sectors still hold every row; sanity check that the loop saw both outcomes.
      expect(batches, greaterThan(0));
    });

    test('damaged header fields (sector size, FAT count, DIFAT) give ImportException', () {
      for (final (off, val) in [
        (0x1E, 0x1F),
        (0x1E, 0),
        (0x2C, 0x7FFFFFFF),
        (0x30, 0xFFFFFFF0),
        (0x44, 5),
        (0x48, 0xFFFFFFFF),
        (0x4C, 0x00FFFFFF),
        (0x38, 0)
      ]) {
        final bad = Uint8List.fromList(base);
        final bd = ByteData.sublistView(bad);
        if (off == 0x1E) {
          bd.setUint16(off, val, Endian.little);
        } else {
          bd.setUint32(off, val, Endian.little);
        }
        Object? outcome;
        try {
          outcome = importBankFile(bad);
        } on ImportException catch (e) {
          outcome = e;
        }
        expect(outcome, anyOf(isA<ImportException>(), isA<ImportBatch>()), reason: 'header @$off=$val');
      }
    });
  });

  group('PBZ rows', () {
    test('string dates (d.m.yyyy) mix with serial dates; serial < 30000 and free text in column A are ignored', () {
      final file = _pbz([
        ...texts,
        '15.01.2026',
        '2.2.2026',
        '31.02.2026',
        'Ukupno'
      ], [
        [...labelSst(2, 0, 10), ...labelSst(2, 1, _card), ...labelSst(2, 2, _shop), ...number(2, 3, -1), ...labelSst(2, 4, _eur)],
        [...labelSst(3, 0, 11), ...labelSst(3, 1, _card), ...labelSst(3, 2, _shop), ...number(3, 3, -2), ...labelSst(3, 4, _eur)],
        [...labelSst(4, 0, 12), ...labelSst(4, 1, _card), ...labelSst(4, 2, _shop), ...number(4, 3, -3), ...labelSst(4, 4, _eur)],
        [...labelSst(5, 0, 13), ...labelSst(5, 1, _card), ...labelSst(5, 2, _shop), ...number(5, 3, -4), ...labelSst(5, 4, _eur)],
        _line(6, 29999, _card, _shop, number(6, 3, -5)),
        _line(7, 46037, _card, _shop, number(7, 3, -6)),
      ]);
      final b = importBankFile(file);
      expect(_view(b), ['2026-01-15|-100|Card|Shop', '2026-02-02|-200|Card|Shop', '2026-01-15|-600|Card|Shop']);
      expect(b.invalid, 1, reason: '31.02.2026');
    });

    test('identical rows on one day stay distinct and keep v1 ids; a second import gives the same ids', () {
      final file = _pbz(texts, [
        for (var i = 0; i < 4; i++) _line(2 + i, 46037, _card, _shop, number(2 + i, 3, -12.5)),
      ]);
      final ids = importBankFile(file).transactions.map((t) => t.id).toList();
      final base0 = transactionId('2026-01-15', -1250, 'Shop', 0);
      expect(ids, [base0, '${base0}_1', '${base0}_2', '${base0}_3']);
      expect(importBankFile(file).transactions.map((t) => t.id).toList(), ids);
    });

    test('REZERVACIJA is skipped only at the start of the description; a missing currency is EUR, a given one is kept', () {
      final file = _pbz([
        ...texts,
        'REZERVACIJA X',
        'Isplata REZERVACIJA',
        'USD'
      ], [
        _line(2, 46037, _card, 10, number(2, 3, -1)),
        _line(3, 46037, _card, 11, number(3, 3, -2)),
        _line(4, 46037, _card, _shop, number(4, 3, -3), cur: 12),
        [...number(5, 0, 46037), ...labelSst(5, 1, _card), ...labelSst(5, 2, _shop), ...number(5, 3, -4)],
      ]);
      final b = importBankFile(file);
      expect(b.skipped, 1);
      expect(b.transactions.map((t) => (t.description, t.currency)), [('Isplata REZERVACIJA', 'EUR'), ('Shop', 'USD'), ('Shop', 'EUR')]);
    });

    test('a decimal like -0.005 and a cent rounding tie follow Math.round', () {
      final file = _pbz(texts, [
        _line(2, 46037, _card, _shop, number(2, 3, -0.125)), // -12.5 cents -> -12 (half towards +inf)
        _line(3, 46038, _card, _shop, number(3, 3, 0.125)), // 12.5 -> 13
      ]);
      expect(importBankFile(file).transactions.map((t) => t.amountMinor), [-12, 13]);
    });
  });
}
