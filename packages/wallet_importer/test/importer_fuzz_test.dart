// Robustness of importBankFile against damaged, truncated and odd files. Everything here is derived from the
// SYNTHETIC fixtures (tools/make_fixtures.py) or generated. The contract: a valid batch or an ImportException, never
// another exception, never a hang, and no file contents in the logs.
//
// Randomized parts use fixed seeds; BW_FUZZ_ITERATIONS / BW_FUZZ_SEED run them longer or with other seeds.
// Each failure message carries the seed and case number.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fuzz.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

/// One fuzz run over a fixture, in its own isolate so a hang shows up as a timeout instead of a stuck test.
class _Result {
  final List<String> failures;
  final List<String> leaks;
  final int cases, batches;
  _Result(this.failures, this.leaks, this.cases, this.batches);
}

typedef _Mutator = Uint8List Function(Uint8List src, Random r, List<String> note);

Uint8List _truncate(Uint8List src, Random r, List<String> note) {
  final at = r.nextInt(src.length);
  note.add('truncate at $at');
  return Uint8List.sublistView(src, 0, at);
}

Uint8List _flip(Uint8List src, Random r, List<String> note) {
  final out = Uint8List.fromList(src);
  final k = 1 + r.nextInt(8);
  for (var i = 0; i < k; i++) {
    // Half the flips land in the first 4 KiB (container headers, directory, workbook globals), where damage hurts most.
    final p = r.nextBool() ? r.nextInt(min(4096, out.length)) : r.nextInt(out.length);
    final v = r.nextBool() ? (1 << r.nextInt(8)) : r.nextInt(256);
    out[p] ^= v == 0 ? 1 : v;
    note.add('xor @$p ^$v');
  }
  return out;
}

Uint8List _splice(Uint8List src, Random r, List<String> note) {
  final a = r.nextInt(src.length), len = 1 + r.nextInt(min(512, src.length));
  final b = BytesBuilder();
  switch (r.nextInt(3)) {
    case 0: // delete a chunk
      note.add('delete $a+$len');
      b.add(Uint8List.sublistView(src, 0, a));
      b.add(Uint8List.sublistView(src, min(src.length, a + len)));
    case 1: // duplicate a chunk
      note.add('duplicate $a+$len');
      b.add(Uint8List.sublistView(src, 0, min(src.length, a + len)));
      b.add(Uint8List.sublistView(src, a));
    default: // insert random bytes
      note.add('insert $len random at $a');
      b.add(Uint8List.sublistView(src, 0, a));
      b.add([for (var i = 0; i < len; i++) r.nextInt(256)]);
      b.add(Uint8List.sublistView(src, a));
  }
  return b.takeBytes();
}

_Result _fuzz(String name, int seed, int cases) {
  final (lines, stop) = captureLogs();
  final src = fixture(name);
  final failures = <String>[];
  var batches = 0;
  final mutators = <_Mutator>[_truncate, _flip, _splice];
  // Deterministic truncations first: every offset in the first 64 bytes and at every 512-byte boundary.
  final offsets = <int>{for (var i = 0; i < min(64, src.length); i++) i, for (var i = 512; i < src.length; i += 512) i, src.length - 1};
  for (final at in offsets) {
    final f = checkImport(Uint8List.sublistView(src, 0, at));
    if (f != null) failures.add('$name truncate at $at: $f');
  }
  for (var i = 0; i < cases; i++) {
    final r = Random(seed * 100003 + i);
    final note = <String>[];
    final bytes = mutators[r.nextInt(mutators.length)](src, r, note);
    final f = checkImport(bytes);
    if (f != null) {
      failures.add('$name seed=$seed case=$i [${note.join(', ')}]: $f');
    } else {
      try {
        importBankFile(bytes);
        batches++;
      } on ImportException {
        // rejected, fine
      }
    }
  }
  stop();
  return _Result(failures, leaks(lines), offsets.length + cases, batches);
}

Future<_Result> _fuzzIsolated(String name, int seed, int cases) => Isolate.run(() => _fuzz(name, seed, cases))
    .timeout(const Duration(seconds: 60), onTimeout: () => throw StateError('hang: $name seed=$seed'));

/// The Revolut CSV fixture as cells, so tests can rewrite it in other shapes.
List<List<String>> _csvCells() => [
      ['Type', 'Product', 'Started Date', 'Completed Date', 'Description', 'Amount', 'Fee', 'Currency', 'State', 'Balance'],
      [
        'Card Payment',
        'Current',
        '2026-02-01 10:00:00',
        '2026-02-02 10:00:00',
        'Shop, with comma',
        '-12.30',
        '0.00',
        'EUR',
        'COMPLETED',
        '100.00'
      ],
      ['Topup', 'Current', '2026-02-01 09:00:00', '2026-02-01 09:00:00', 'Top-up by *0000', '50.00', '0.00', 'EUR', 'COMPLETED', '112.30'],
      ['Card Payment', 'Current', '2026-02-03 10:00:00', '', 'Pending Shop', '-5.00', '0.00', 'EUR', 'PENDING', '107.30'],
    ];

String _toCsv(List<List<String>> rows, {String sep = ',', String eol = '\n', bool quoteAll = false}) => rows
    .map((r) => r.map((c) => quoteAll || c.contains(sep) || c.contains('"') ? '"${c.replaceAll('"', '""')}"' : c).join(sep))
    .map((l) => '$l$eol')
    .join();

/// A comparable view of a batch.
List<String> _view(ImportBatch b) =>
    [for (final t in b.transactions) '${t.id}|${t.source}|${t.date}|${t.amountMinor}|${t.currency}|${t.bankType}|${t.description}'];

Uint8List _xlsx(String sheetXml, {String? sharedStrings}) {
  final a = Archive()..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheetXml));
  if (sharedStrings != null) a.addFile(ArchiveFile.string('xl/sharedStrings.xml', sharedStrings));
  return ZipEncoder().encodeBytes(a);
}

const _sheetHead =
    '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>';
const _sheetTail = '</sheetData></worksheet>';

String _row(int r, List<Object> cells) {
  final sb = StringBuffer('<row r="$r">');
  for (var c = 0; c < cells.length; c++) {
    final ref = '${String.fromCharCode(65 + c)}$r';
    final v = cells[c];
    sb.write(v is num ? '<c r="$ref"><v>$v</v></c>' : '<c r="$ref" t="inlineStr"><is><t>$v</t></is></c>');
  }
  sb.write('</row>');
  return sb.toString();
}

void main() {
  final seed = fuzzSeed(20261016);

  group('fuzz: damaged fixtures give a batch or ImportException, never hang, never log contents', () {
    for (final (name, cases) in [
      ('revolut_synthetic.csv', fuzzIterations(300)),
      ('revolut_synthetic.xlsx', fuzzIterations(300)),
      ('pbz_synthetic.xls', fuzzIterations(250)),
    ]) {
      test(name, () async {
        final r = await _fuzzIsolated(name, seed, cases);
        expect(r.failures, isEmpty, reason: 'seed $seed; ${r.failures.length} of ${r.cases} cases failed');
        expect(r.leaks, isEmpty, reason: 'file contents in the log (seed $seed)');
        expect(r.cases, greaterThan(cases));
      }, timeout: const Timeout(Duration(seconds: 90)));
    }

    test('random binary, random text and magic-number prefixes', () async {
      final failures = await Isolate.run(() {
        final out = <String>[];
        final n = fuzzIterations(300);
        for (var i = 0; i < n; i++) {
          final r = Random(seed + i);
          final len = r.nextInt(2048);
          final body = [for (var k = 0; k < len; k++) r.nextInt(256)];
          final prefix = switch (i % 4) {
            0 => <int>[],
            1 => [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], // OLE2 (.xls)
            2 => [0x50, 0x4B, 0x03, 0x04], // zip (.xlsx)
            _ => utf8.encode('Type,Started Date,Description,Amount\n'), // a Revolut header, then noise
          };
          final f = checkImport(Uint8List.fromList([...prefix, ...body]));
          if (f != null) out.add('seed=$seed case=$i: $f');
        }
        return out;
      }).timeout(const Duration(seconds: 60));
      expect(failures, isEmpty);
    });

    test('generated CSVs (quotes, separators, newlines, odd numbers and dates)', () async {
      final failures = await Isolate.run(() {
        final out = <String>[];
        const pieces = [
          '',
          ' ',
          '"',
          '""',
          ',',
          ';',
          '\n',
          '\r\n',
          '\r',
          'COMPLETED',
          'PENDING',
          '-12.30',
          '1.234,56',
          '0',
          '2026-02-29 10:00',
          '31.12.2026',
          '1.1.2026',
          'DATUM',
          'TRANSAKCIJSKI RAČUN',
          'Started Date',
          'Amount',
          'Fee',
          'Description',
          'State',
          'Type',
          'x',
          'é',
          '🍕',
          'Å¡',
          '\u0000',
          '﻿',
          '-',
          '.',
          'e5',
          '1e3',
          '99999999999'
        ];
        final n = fuzzIterations(400);
        for (var i = 0; i < n; i++) {
          final r = Random(seed ^ (i * 7919));
          final sb = StringBuffer();
          if (r.nextBool()) sb.write('Type,Product,Started Date,Description,Amount,Fee,Currency,State\n');
          final len = r.nextInt(120);
          for (var k = 0; k < len; k++) {
            sb.write(pieces[r.nextInt(pieces.length)]);
          }
          final f = checkImport(_b(sb.toString()));
          if (f != null) out.add('seed=$seed case=$i ${jsonEncode(sb.toString())}: $f');
        }
        return out;
      }).timeout(const Duration(seconds: 60));
      expect(failures, isEmpty);
    });
  });

  group('CSV shapes give the same transactions', () {
    final base = _view(importBankFile(_b(_toCsv(_csvCells()))));

    test('the rebuilt fixture equals the file fixture', () {
      expect(base, _view(importBankFile(fixture('revolut_synthetic.csv'))));
      expect(base.length, 2);
    });

    test('shuffled columns (columns are found by header name)', () {
      final cells = _csvCells();
      for (var s = 0; s < 20; s++) {
        final order = List.generate(cells.first.length, (i) => i)..shuffle(Random(seed + s));
        final shuffled = [
          for (final r in cells) [for (final i in order) r[i]]
        ];
        expect(_view(importBankFile(_b(_toCsv(shuffled)))), base, reason: 'order $order');
      }
    });

    test('CRLF, CR-only, trailing blank lines, quoted fields', () {
      expect(_view(importBankFile(_b(_toCsv(_csvCells(), eol: '\r\n')))), base);
      expect(_view(importBankFile(_b(_toCsv(_csvCells(), eol: '\r')))), base);
      expect(_view(importBankFile(_b('${_toCsv(_csvCells())}\n\n\r\n'))), base);
      expect(_view(importBankFile(_b(_toCsv(_csvCells(), quoteAll: true)))), base);
      final noFinalNewline = _toCsv(_csvCells());
      expect(_view(importBankFile(_b(noFinalNewline.substring(0, noFinalNewline.length - 1)))), base);
    });

    test('UTF-8 byte order mark', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ..._b(_toCsv(_csvCells()))]);
      expect(_view(importBankFile(bytes)), base);
    });

    test('semicolon separator with comma decimals', () {
      final cells = [
        for (final r in _csvCells()) [for (final c in r) RegExp(r'^-?\d+\.\d\d$').hasMatch(c) ? c.replaceAll('.', ',') : c]
      ];
      expect(_view(importBankFile(_b(_toCsv(cells, sep: ';')))), base);
    });

    test('header only: an empty Revolut batch', () {
      final b = importBankFile(_b(_toCsv(_csvCells().take(1).toList())));
      expect(b.source, 'revolut');
      expect(b.transactions, isEmpty);
    });

    test('empty, whitespace and unknown files are rejected with ImportException', () {
      for (final s in ['', ' ', '\n\n', '﻿', 'a,b,c\n1,2,3\n', 'DATE;AMOUNT\n1.1.2026;5\n']) {
        expect(() => importBankFile(_b(s)), throwsA(isA<ImportException>()), reason: jsonEncode(s));
      }
      expect(() => importBankFile(Uint8List(0)), throwsA(isA<ImportException>()));
    });

    test('unicode and mojibake descriptions', () {
      final cells = _csvCells();
      cells[1][4] = 'Pizza 🍕 Šđčćž';
      cells[2][4] = 'GraÅ¡o';
      final b = importBankFile(_b(_toCsv(cells)));
      expect(b.transactions.map((t) => t.description), ['Pizza 🍕 Šđčćž', 'Grašo']);
    });

    test('Latin-1 bytes that are not UTF-8 do not throw', () {
      final text = _toCsv(_csvCells()).replaceAll('Shop, with comma', 'Café à la carte');
      final b = importBankFile(Uint8List.fromList(latin1.encode(text)));
      expect(b.transactions.length, 2);
    });

    test('a PBZ-style CSV (semicolons, d.m.yyyy, comma decimals, card hold)', () {
      const csv = 'TRANSAKCIJSKI RAČUN:;;;;\nDATUM;VRSTA TRANSAKCIJE;OPIS PLAĆANJA;IZNOS;VALUTA\n'
          '15.01.2026;Plaća/Mirovina;Neto plaća;1.500,00;EUR\n'
          '1.2.2026;POS plaćanje;REZERVACIJA example;-10,00;EUR\n'
          '2.2.2026;POS plaćanje;Example shop;-23,40;\n';
      final b = importBankFile(_b(csv));
      expect(b.source, 'pbz');
      expect(b.skipped, 1);
      expect([for (final t in b.transactions) (t.date, t.amountMinor, t.currency)],
          [('2026-01-15', 150000, 'EUR'), ('2026-02-02', -2340, 'EUR')]);
    });
  });

  group('determinism', () {
    for (final name in ['pbz_synthetic.xls', 'revolut_synthetic.xlsx', 'revolut_synthetic.csv']) {
      test('$name: same bytes, same ids (also from a copy of the bytes)', () {
        final a = importBankFile(fixture(name));
        final b = importBankFile(Uint8List.fromList(fixture(name)));
        expect(_view(a), _view(b));
        expect(batchProblems(a), isEmpty);
      });
    }

    test('two identical rows get _1, a third _2; ids do not depend on rows elsewhere in the file', () {
      final cells = _csvCells();
      final dup = [...cells, cells[1], cells[1]];
      final ids = importBankFile(_b(_toCsv(dup))).transactions.map((t) => t.id).toList();
      final first = ids.first;
      expect(ids.where((i) => i.startsWith(first.split('_').first)).toList(), [first, '${first}_1', '${first}_2']);
      // Dropping an unrelated row does not change the other ids.
      final fewer = [cells[0], cells[1]];
      expect(importBankFile(_b(_toCsv(fewer))).transactions.single.id, first);
    });
  });

  group('xlsx edge cases', () {
    test('cells without r attributes, shared strings, rich text, booleans and errors', () {
      final shared = [
        '<sst><si><t>Type</t></si><si><r><t>Started </t></r><r><t>Date</t></r></si><si><t>Description</t></si>',
        '<si><t>Amount</t></si><si><t>State</t></si><si><t>COMPLETED</t></si><si><t>Wolt</t><rPh><t>x</t></rPh></si></sst>',
      ].join();
      final sheet = [
        _sheetHead,
        '<row><c t="s"><v>0</v></c><c t="s"><v>1</v></c><c t="s"><v>2</v></c><c t="s"><v>3</v></c><c t="s"><v>4</v></c></row>',
        '<row><c t="b"><v>1</v></c><c><v>46037.5</v></c><c t="s"><v>6</v></c><c><v>-14.5</v></c><c t="s"><v>5</v></c></row>',
        '<row><c t="e"><v>#N/A</v></c><c t="str"><v>2026-01-16</v></c><c t="s"><v>99</v></c><c><v>-1</v></c><c t="s"><v>5</v></c></row>',
        _sheetTail,
      ].join();
      final b = importBankFile(_xlsx(sheet, sharedStrings: shared));
      expect([for (final t in b.transactions) (t.date, t.amountMinor, t.description, t.bankType)],
          [('2026-01-15', -1450, 'Wolt', 'TRUE'), ('2026-01-16', -100, '', '#N/A')]);
    });

    test('malformed XML inside a valid zip is an ImportException', () {
      expect(() => importBankFile(_xlsx('$_sheetHead<row><c>')), throwsA(isA<ImportException>()));
      expect(() => importBankFile(_xlsx('not xml')), throwsA(isA<ImportException>()));
      final noSheet = ZipEncoder().encodeBytes(Archive()..addFile(ArchiveFile.string('hello.txt', 'hi')));
      expect(() => importBankFile(noSheet), throwsA(isA<ImportException>()));
    });

    test('a cell far away (XFD1048576) does not blow up memory or time', () async {
      final sheet = '$_sheetHead${_row(1, ['Type', 'Started Date', 'Description', 'Amount'])}'
          '${_row(2, ['Card Payment', '2026-01-03', 'Wolt', -14.5])}<row r="1048576"><c r="XFD1048576"><v>1</v></c></row>$_sheetTail';
      final bytes = _xlsx(sheet);
      final f = await Isolate.run(() => checkImport(bytes, maxMs: 3000)).timeout(const Duration(seconds: 20));
      expect(f, isNull);
      // Read sparsely: the real rows still import.
      final b = importBankFile(bytes);
      expect([for (final t in b.transactions) (t.date, t.amountMinor)], [('2026-01-03', -1450)]);
    });

    test('a sheet that would lay out to millions of cells is an ImportException, quickly', () {
      final far = [for (var r = 3; r < 300; r++) '<row r="$r"><c r="XFD$r"><v>1</v></c></row>'].join();
      final sheet = '$_sheetHead${_row(1, ['Type', 'Started Date', 'Description', 'Amount'])}$far$_sheetTail';
      final bytes = _xlsx(sheet);
      final sw = Stopwatch()..start();
      expect(() => importBankFile(bytes), throwsA(isA<ImportException>()));
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });

  group('numbers and dates the importer should not accept', () {
    const h = 'Type,Started Date,Description,Amount,Fee,State\n';

    test('NaN or Infinity amounts: ImportException or row dropped, not UnsupportedError', () {
      for (final a in ['NaN', 'Infinity', '-Infinity', '1e400']) {
        expect(checkImport(_b('${h}Card Payment,2026-01-01,x,$a,0,COMPLETED\n')), isNull, reason: a);
        // Decision: the row is left out and counted; the other rows still import.
        final b = importBankFile(_b('${h}Card Payment,2026-01-01,x,$a,0,COMPLETED\nCard Payment,2026-01-02,y,-1.5,0,COMPLETED\n'));
        expect([for (final t in b.transactions) t.amountMinor], [-150], reason: a);
        expect(b.invalid, 1, reason: a);
        final fee = importBankFile(_b('${h}Card Payment,2026-01-01,x,-1,$a,COMPLETED\n'));
        expect((fee.transactions.length, fee.invalid), (0, 1), reason: 'fee $a');
      }
    });

    test('NaN or Infinity number cells in a PBZ sheet (date or amount) do not throw', () {
      for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
        final b = parseRows([
          ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
          [46037.0, 'POS plaćanje', 'x', v, 'EUR'],
          [v, 'POS plaćanje', 'y', -1.0, 'EUR'],
          [46038.0, v, v, -2.0, v],
        ])!;
        expect([for (final t in b.transactions) t.amountMinor], [-200], reason: '$v');
        expect(b.invalid, 1, reason: '$v');
      }
    });

    test('amounts beyond 64-bit cents are not silently clamped', () {
      for (final a in ['1e22', '99999999999999999999', '-1e30']) {
        try {
          final b = importBankFile(_b('${h}Card Payment,2026-01-01,x,$a,0,COMPLETED\n'));
          for (final t in b.transactions) {
            expect(t.amountMinor.abs(), lessThan(1 << 53), reason: a);
          }
        } on ImportException {
          // rejecting is fine
        }
      }
    });

    test('decision: an amount beyond 10 billion (10^12 cents) leaves the row out and counts it; up to it imports', () {
      for (final (a, cents) in [
        ('10000000000', 1000000000000),
        ('-10000000000', -1000000000000),
        ('10000000000.01', null),
        ('1e22', null)
      ]) {
        final b = importBankFile(_b('${h}Card Payment,2026-01-01,x,$a,0,COMPLETED\n'));
        expect([for (final t in b.transactions) t.amountMinor], [if (cents != null) cents], reason: a);
        expect(b.invalid, cents == null ? 1 : 0, reason: a);
      }
    });

    test('impossible calendar dates are rejected or dropped', () {
      for (final d in ['2026-13-45', '2026-02-30', '2026-00-10']) {
        try {
          final b = importBankFile(_b('${h}Card Payment,$d,x,-1,0,COMPLETED\n'));
          expect(b.transactions, isEmpty, reason: d);
        } on ImportException {
          // fine
        }
      }
      const pbz = 'DATUM;VRSTA TRANSAKCIJE;OPIS PLAĆANJA;IZNOS;VALUTA\n31.02.2026;POS plaćanje;x;-1,00;EUR\n';
      try {
        expect(importBankFile(_b(pbz)).transactions, isEmpty);
      } on ImportException {
        // fine
      }
    });

    test('decision: an impossible date leaves the row out and counts it; real dates (29.02 in a leap year) import', () {
      final rev = importBankFile(_b('${h}Card Payment,2026-13-45,x,-1,0,COMPLETED\nCard Payment,2028-02-29,y,-2,0,COMPLETED\n'
          'Card Payment,2027-02-29,z,-3,0,COMPLETED\n'));
      expect([for (final t in rev.transactions) (t.date, t.amountMinor)], [('2028-02-29', -200)]);
      expect(rev.invalid, 2);
      final pbz = importBankFile(_b('DATUM;VRSTA TRANSAKCIJE;OPIS PLAĆANJA;IZNOS;VALUTA\n31.02.2026;POS plaćanje;x;-1,00;EUR\n'
          '0.1.2026;POS plaćanje;x;-1,00;EUR\n1.2.2026;POS plaćanje;y;-2,00;EUR\n'));
      expect([for (final t in pbz.transactions) (t.date, t.amountMinor)], [('2026-02-01', -200)]);
      expect(pbz.invalid, 2);
      final serial = parseRows([
        ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
        [1e15, 'POS plaćanje', 'x', -1.0, 'EUR'],
        [46037.0, 'POS plaćanje', 'y', -2.0, 'EUR'],
      ])!;
      expect([for (final t in serial.transactions) (t.date, t.amountMinor)], [('2026-01-15', -200)]);
      expect(serial.invalid, 1);
    });

    test('excel serial dates out of range in a PBZ sheet: ImportException, not ArgumentError', () {
      final rows = <List<Object>>[
        ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
        [1e15, 'POS plaćanje', 'x', -1.0, 'EUR'],
      ];
      final sheet = '$_sheetHead${_row(1, rows[0])}${_row(2, rows[1])}$_sheetTail';
      expect(checkImport(_xlsx(sheet)), isNull);
    });
  });
}
