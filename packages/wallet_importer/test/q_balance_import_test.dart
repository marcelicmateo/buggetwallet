// Stage Q (docs/context/STAGE_Q_PLAN.md): Q3 the per-row amount cap, Q5 the bank balance a file states
// (`NormalizedTransaction.balanceAfter`, `ImportBatch.bankBalances`). Every input is SYNTHETIC and built inline.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

const _revHdr = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance';
const _revNoBal = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State';

/// A Revolut CSV row; [balance] null leaves the cell empty, [withBalance] false drops the column.
String _r(String date, String desc, String amount,
    {String? balance, String state = 'COMPLETED', String cur = 'EUR', String product = 'Current', bool withBalance = true}) {
  final base = 'Card Payment,$product,$date 10:00:00,$date 10:00:00,$desc,$amount,0.00,$cur,$state';
  return withBalance ? '$base,${balance ?? ''}' : base;
}

ImportBatch _rev(List<String> rows, {String header = _revHdr}) => importBankFile(_b('$header\n${rows.join('\n')}\n'));

const _pbzHeader = ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'];

ImportBatch _pbz(List<List<Object>> rows, {List<String> extra = const []}) => parseRows([
      ['', 'TRANSAKCIJSKI RAČUN:', '', '', ''],
      ['', 'HR0000000000000000000', '', '', ''],
      [..._pbzHeader, ...extra],
      ...rows,
    ])!;

void main() {
  group('Q3 per-row cap', () {
    test('the cap is the single typed-input cap, and 90,000 rows at it still sum under 2^53', () {
      expect(maxRowAmountMinor, 100000000000);
      expect(exactRowsAtCap, 90000);
      // The documented bound: exactRowsAtCap × the cap is a whole number a double (a web number) holds exactly.
      const twoTo53 = 9007199254740992;
      expect(exactRowsAtCap * maxRowAmountMinor, lessThan(twoTo53));
      expect(exactRowsAtCap * maxRowAmountMinor, 9000000000000000);
      // And the bound is tight: a few thousand rows more would not be guaranteed.
      expect((exactRowsAtCap + 100) * maxRowAmountMinor, greaterThan(twoTo53));
    });

    test('PBZ: at the cap imports, one cent over is invalid and too large, the other rows still import', () {
      final b = _pbz([
        ['02.01.2026', 'Ostalo', 'Big in', '1.000.000.000,00', 'EUR'],
        ['03.01.2026', 'Ostalo', 'Big out', '-1.000.000.000,00', 'EUR'],
        ['04.01.2026', 'Ostalo', 'Over', '1.000.000.000,01', 'EUR'],
        ['05.01.2026', 'Ostalo', 'Over out', '-1.000.000.000,01', 'EUR'],
        ['06.01.2026', 'Ostalo', 'Small', '-1,00', 'EUR'],
      ]);
      expect([for (final t in b.transactions) t.amountMinor], [100000000000, -100000000000, -100]);
      expect(b.invalid, 2);
      expect(b.tooLarge, 2);
    });

    test('an unreadable amount is invalid but not too large', () {
      final b = _pbz([
        ['02.01.2026', 'Ostalo', 'Bad', 'abc', 'EUR'],
      ]);
      expect(b.invalid, 1);
      expect(b.tooLarge, 0);
    });

    test('mapped CSV: an amount, debit or credit over the cap is a "too large" row, counted with its row number', () {
      const m = CsvMapping(
          name: 'Test',
          headerRow: 0,
          dateCol: 0,
          dateFormat: CsvDateFormat.dmyDot,
          amountCol: 2,
          descriptionCols: [1],
          currencyCode: 'EUR');
      final b = parseMappedCsv(_b('Datum;Opis;Iznos\n01.01.2026;a;1.000.000.000,00\n02.01.2026;b;1.000.000.000,01\n03.01.2026;c;x\n'), m);
      expect(b.transactions.map((t) => t.amountMinor), [100000000000]);
      expect(b.invalid, 2);
      expect(b.invalidRows, [2, 3]);
      expect(b.tooLarge, 1);
      final shape = csvShape(_b('Datum;Opis;Iznos\n02.01.2026;b;-1.000.000.000,01\n'));
      final p = previewMapping(shape, m).single;
      expect(p.tooLarge, isTrue);
      expect(p.problem, contains('too large'));
    });

    test('an empty file has no rows, nothing too large and no balance', () {
      final b = _rev(const []);
      expect(b.transactions, isEmpty);
      expect(b.tooLarge, 0);
      expect(b.bankBalances, isEmpty);
    });
  });

  group('Q5 Revolut Balance column', () {
    test('balanceAfter is read on completed rows; the ids are the same as without the column', () {
      final rows = [
        ('2026-02-01', 'Shop', '-12.30', '87.70'),
        ('2026-02-02', 'Cafe', '-2.00', '85.70'),
      ];
      final withCol = _rev([for (final (d, x, a, bal) in rows) _r(d, x, a, balance: bal)]);
      final without = _rev([for (final (d, x, a, _) in rows) _r(d, x, a, withBalance: false)], header: _revNoBal);
      expect(withCol.transactions.map((t) => t.balanceAfter), [8770, 8570]);
      expect(without.transactions.map((t) => t.balanceAfter), [null, null]);
      expect(withCol.transactions.map((t) => t.id), without.transactions.map((t) => t.id));
      expect(withCol.bankBalances, [const BankBalance(source: 'revolut', currency: 'EUR', date: '2026-02-02', cents: 8570)]);
      expect(without.bankBalances, isEmpty);
    });

    test('toJson writes balanceAfter only when set, so the v1 shape is unchanged without it', () {
      final without = _rev([_r('2026-02-01', 'Shop', '-1.00', withBalance: false)], header: _revNoBal).transactions.single;
      expect(without.toJson().containsKey('balanceAfter'), isFalse);
      final withCol = _rev([_r('2026-02-01', 'Shop', '-1.00', balance: '-5.25')]).transactions.single;
      expect(withCol.toJson()['balanceAfter'], -525);
      expect(withCol.toJson()['id'], without.toJson()['id']);
    });

    test('the balance is the last row of the newest date, in file order', () {
      final b = _rev([
        _r('2026-02-01', 'a', '-1.00', balance: '99.00'),
        _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
        _r('2026-02-03', 'c', '-1.00', balance: '97.00'),
      ]);
      expect(b.bankBalances.single.date, '2026-02-03');
      expect(b.bankBalances.single.cents, 9700);
    });

    test('a file running newest first: the first row of the newest date is the end of that day', () {
      final b = _rev([
        _r('2026-02-03', 'c', '-1.00', balance: '97.00'),
        _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
        _r('2026-02-01', 'a', '-1.00', balance: '99.00'),
      ]);
      expect(b.bankBalances.single, const BankBalance(source: 'revolut', currency: 'EUR', date: '2026-02-03', cents: 9700));
    });

    // Review fix 7: the direction comes from the balance chain, not from the first and last dates.
    test('a newest-first file covering one day: the chain says which row ends the day', () {
      final b = _rev([
        _r('2026-02-03', 'c', '-1.00', balance: '97.00'),
        _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
      ]);
      expect(b.bankBalances.single.cents, 9700);
      final up = _rev([
        _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
        _r('2026-02-03', 'c', '-1.00', balance: '97.00'),
      ]);
      expect(up.bankBalances.single.cents, 9700);
    });

    test('a chain that does not tell the direction gives no balance for a day with several rows', () {
      // Balances that fit neither way.
      expect(
          _rev([
            _r('2026-02-03', 'b', '-1.00', balance: '50.00'),
            _r('2026-02-03', 'c', '-1.00', balance: '10.00'),
          ]).bankBalances,
          isEmpty);
      // Pairs both ways.
      expect(
          _rev([
            _r('2026-02-03', 'a', '-1.00', balance: '99.00'),
            _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
            _r('2026-02-03', 'c', '-5.00', balance: '99.00'),
          ]).bankBalances,
          isEmpty);
      // Missing balances: no telling pair.
      expect(
          _rev([
            _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
            _r('2026-02-03', 'c', '-1.00'),
            _r('2026-02-03', 'd', '-1.00', balance: '96.00'),
          ]).bankBalances,
          isEmpty);
      // One row on the newest day needs no direction.
      expect(_rev([_r('2026-02-03', 'b', '-1.00', balance: '50.00')]).bankBalances.single.cents, 5000);
    });

    test('a balance missing on the last row of the newest day falls back to an older day, never to earlier in that day', () {
      final b = _rev([
        _r('2026-02-01', 'a', '-1.00', balance: '99.00'),
        _r('2026-02-03', 'b', '-1.00', balance: '98.00'),
        _r('2026-02-03', 'c', '-1.00'),
      ]);
      expect(b.transactions.map((t) => t.balanceAfter), [9900, 9800, null]);
      expect(b.bankBalances.single, const BankBalance(source: 'revolut', currency: 'EUR', date: '2026-02-01', cents: 9900));
    });

    test('a negative balance (overdraft) is kept with its sign', () {
      final b = _rev([_r('2026-02-01', 'a', '-150.00', balance: '-50.00')]);
      expect(b.bankBalances.single.cents, -5000);
    });

    test('pending rows are skipped and never give the balance', () {
      final b = _rev([
        _r('2026-02-01', 'a', '-1.00', balance: '10.00'),
        _r('2026-02-02', 'b', '-1.00', balance: '9.00', state: 'PENDING'),
      ]);
      expect(b.skipped, 1);
      expect(b.bankBalances.single, const BankBalance(source: 'revolut', currency: 'EUR', date: '2026-02-01', cents: 1000));
    });

    test('one balance per currency; a currency mixing two products (pockets) has none', () {
      final b = _rev([
        _r('2026-02-01', 'a', '-1.00', balance: '10.00'),
        _r('2026-02-02', 'b', '-1.00', balance: '5.00', cur: 'USD'),
        _r('2026-02-02', 'c', '-1.00', balance: '9.00'),
        _r('2026-02-03', 'd', '-1.00', balance: '300.00', product: 'Savings'),
      ]);
      expect(b.bankBalances, [const BankBalance(source: 'revolut', currency: 'USD', date: '2026-02-02', cents: 500)]);
    });

    test('an unreadable balance cell gives none; the row still imports', () {
      final b = _rev([_r('2026-02-01', 'a', '-1.00', balance: 'n/a')]);
      expect(b.transactions.single.amountMinor, -100);
      expect(b.transactions.single.balanceAfter, isNull);
      expect(b.bankBalances, isEmpty);
    });
  });

  group('Q5 PBZ STANJE / SALDO', () {
    test('a STANJE column gives balanceAfter; ids and detection are as without it', () {
      final rows = [
        ['02.01.2026', 'POS plaćanje', 'Shop', '-10,00', 'EUR'],
        ['03.01.2026', 'POS plaćanje', 'Cafe', '-2,50', 'EUR'],
      ];
      final plain = _pbz(rows);
      final withCol = _pbz([
        [...rows[0], '90,00'],
        [...rows[1], '-1.087,50'],
      ], extra: [
        'STANJE'
      ]);
      expect(plain.source, 'pbz');
      expect(withCol.source, 'pbz');
      expect(withCol.transactions.map((t) => t.id), plain.transactions.map((t) => t.id));
      expect(plain.transactions.map((t) => t.balanceAfter), [null, null]);
      expect(withCol.transactions.map((t) => t.balanceAfter), [9000, -108750]);
      expect(withCol.bankBalances.single, const BankBalance(source: 'pbz', currency: 'EUR', date: '2026-01-03', cents: -108750));
    });

    test('SALDO works the same; another extra column is not a balance', () {
      final row = ['02.01.2026', 'Ostalo', 'x', '-1,00', 'EUR', '5,00'];
      expect(_pbz([row], extra: ['Saldo']).transactions.single.balanceAfter, 500);
      expect(_pbz([row], extra: ['NAPOMENA']).transactions.single.balanceAfter, isNull);
    });

    test('the balance column missing in some rows: those rows have none', () {
      final b = _pbz([
        ['02.01.2026', 'Ostalo', 'x', '-1,00', 'EUR', '5,00'],
        ['03.01.2026', 'Ostalo', 'y', '-1,00', 'EUR'],
      ], extra: [
        'STANJE'
      ]);
      expect(b.transactions.map((t) => t.balanceAfter), [500, null]);
      expect(b.bankBalances.single.date, '2026-01-02');
    });
  });

  group('Q5 mapped CSV balance column', () {
    test('the guess fills balanceCol from the balance header; it is never the amount', () {
      final m = guessMapping(csvShape(_b('Datum;Opis;Iznos;Stanje\n01.01.2026;a;-1,00;5,00\n')))!;
      expect(m.amountCol, 2);
      expect(m.balanceCol, 3);
      expect(guessMapping(csvShape(_b('Datum;Opis;Iznos\n01.01.2026;a;-1,00\n')))!.balanceCol, isNull);
    });

    test('old saved mappings (no balance key) still parse; a new one round-trips', () {
      const m = CsvMapping(name: 'T', headerRow: 0, dateCol: 0, dateFormat: CsvDateFormat.dmyDot, amountCol: 2, descriptionCols: [1]);
      final old = m.toJson();
      expect(old.containsKey('balance'), isFalse);
      expect(CsvMapping.fromJson(jsonDecode(jsonEncode(old))).balanceCol, isNull);
      final withBal = m.copyWith(balanceCol: 3);
      final back = CsvMapping.fromJson(jsonDecode(jsonEncode(withBal.toJson())));
      expect(back.balanceCol, 3);
      expect(back, withBal);
      expect(withBal.copyWith(balanceCol: null).balanceCol, isNull);
    });

    test('a balance column on the amount or date, or outside the file, is a mapping problem', () {
      const m = CsvMapping(name: 'T', headerRow: 0, dateCol: 0, dateFormat: CsvDateFormat.dmyDot, amountCol: 2, descriptionCols: [1]);
      expect(m.copyWith(balanceCol: 2).structureProblems(columns: 4), contains('Pick the balance column again.'));
      expect(m.copyWith(balanceCol: 0).structureProblems(columns: 4), contains('Pick the balance column again.'));
      expect(m.copyWith(balanceCol: 9).structureProblems(columns: 4), contains('Pick the balance column again.'));
      expect(m.copyWith(balanceCol: 3).structureProblems(columns: 4), isEmpty);
    });

    test('parseMappedCsv fills balanceAfter and bankBalances; an unreadable cell gives none', () {
      const m = CsvMapping(
          name: 'T',
          headerRow: 0,
          dateCol: 0,
          dateFormat: CsvDateFormat.dmyDot,
          amountCol: 2,
          descriptionCols: [1],
          currencyCode: 'EUR',
          balanceCol: 3);
      const file = 'Datum;Opis;Iznos;Stanje\n01.01.2026;a;-1,00;6,00\n02.01.2026;b;-1,00;5,00\n02.01.2026;c;-1,00;?\n';
      final b = parseMappedCsv(_b(file), m);
      expect(b.transactions.map((t) => t.balanceAfter), [600, 500, null]);
      // The chain (6,00 then 5,00 after -1,00) says oldest first, so c ends 2 January; it has no balance: 1 January.
      expect(b.bankBalances.single.date, '2026-01-01');
      expect(b.bankBalances.single.cents, 600);
      expect(b.bankBalances.single.source, b.source);
      // Without the role, the same file gives no balances and the same ids.
      final plain = parseMappedCsv(_b(file), m.copyWith(balanceCol: null));
      expect(plain.bankBalances, isEmpty);
      expect(plain.transactions.map((t) => t.id), b.transactions.map((t) => t.id));
    });
  });
}
