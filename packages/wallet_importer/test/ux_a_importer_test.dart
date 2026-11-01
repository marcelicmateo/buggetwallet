// Stage UX-A (docs/context/UX_SPEC.md §1, storage rule of 2026-11-01 and the second review), the builder's own importer
// tests: every fiat amount is stored in hundredths as before, BTC in satoshis; a finer fraction than the storage scale
// is refused per row with its reason in every reader (never rounded); fiat ids stay v1's, crypto ids hash satoshis.
// All data SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/ids.dart' show minorIdText;
import 'package:wallet_importer/src/profiles/cells.dart' show cellMinor, cellCurrency;
import 'package:wallet_importer/wallet_importer.dart';

const _hdr = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance';

ImportBatch _revolut(List<String> rows) => importBankFile(Uint8List.fromList(utf8.encode('$_hdr\n${rows.join('\n')}\n')));

String _row(String amount, String currency, {String fee = '0', String balance = '0'}) =>
    'Card Payment,Current,2026-03-01 10:00:00,2026-03-01 10:00:00,Synthetic shop,$amount,$fee,$currency,COMPLETED,$balance';

const _pbzHeader = ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'];

ImportBatch _pbz(List<List<Object>> rows, {List<String> extra = const []}) => parseRows([
      ['', 'TRANSAKCIJSKI RAČUN:', '', '', ''],
      ['', 'HR0000000000000000000', '', '', ''],
      [..._pbzHeader, ...extra],
      ...rows,
    ])!;

void main() {
  test('storage and display digits', () {
    expect([
      for (final c in ['EUR', 'JPY', 'KWD', 'BTC', 'ZZZ']) storageDigitsOf(c)
    ], [
      2,
      2,
      2,
      8,
      2
    ]);
    expect([
      for (final c in ['EUR', 'JPY', 'KWD', 'BTC', 'ZZZ']) displayDigitsOf(c)
    ], [
      2,
      0,
      2,
      8,
      2
    ]);
  });

  test('cellMinor refuses any finer fraction (never rounds); exact values are what v1 gave', () {
    expect(cellMinor(-12.345, 2), isNull);
    expect(cellMinor(-12.34, 2), -1234);
    expect(cellMinor(1.235, 2), isNull);
    expect(cellMinor(10.000, 2), 1000);
    expect(cellMinor(0.1 + 0.2, 2), 30, reason: 'double noise is not a fraction');
    expect(cellMinor(0.00000001, 8), 1);
    expect(cellMinor(0.000000015, 8), isNull);
    expect(cellMinor(double.nan, 8), isNull);
    expect((cellCurrency(' kwd '), cellCurrency('€'), cellCurrency('')), ('KWD', 'EUR', 'EUR'));
  });

  test('minorIdText: the hundredths text of earlier builds where they could read the row, else the exact decimal', () {
    expect(minorIdText(-100000, 2), '-1000.00');
    expect(minorIdText(1000000, 8), '0.01');
    expect(minorIdText(100000, 8), '0.001');
    expect(minorIdText(-1, 8), '-0.00000001');
  });

  group('Revolut', () {
    test('a yen row is stored in hundredths, its id is the v1 one', () {
      final yen = _revolut([_row('-1000', 'JPY', fee: '10', balance: '5000')]).transactions.single;
      expect((yen.amountMinor, yen.currency, yen.balanceAfter), (-101000, 'JPY', 500000));
      expect(yen.id, transactionId('2026-03-01', -101000, 'Synthetic shop', 0));
    });

    test('EUR with three decimals is refused with its reason, not rounded; the other rows import', () {
      final b = _revolut([_row('-12.345', 'EUR'), _row('-12.34', 'EUR')]);
      expect(b.invalid, 1);
      expect(b.invalidRows, [1]);
      expect(b.problems.single, 'Row 2: the amount -12.345 has more than 2 decimals');
      expect(b.transactions.single.amountMinor, -1234);
      expect(b.transactions.single.id, transactionId('2026-03-01', -1234, 'Synthetic shop', 0), reason: 'fiat ids unchanged (K4)');
    });

    test('a lower-case currency is upper-cased first, so a dinar third decimal is refused; a zero one imports', () {
      final b = _revolut([_row('-1.235', 'kwd'), _row('-1.230', 'kwd')]);
      expect(b.invalid, 1);
      expect(b.problems.single, contains('the third decimal of KWD is not supported'));
      expect((b.transactions.single.amountMinor, b.transactions.single.currency), (-123, 'KWD'));
    });

    test('a fee or balance with a finer fraction refuses the row with its reason (no silent null balance)', () {
      final b = _revolut([_row('-10.00', 'EUR', fee: '0.005'), _row('-10.00', 'EUR', balance: '100.001'), _row('-10.00', 'EUR')]);
      expect(b.invalid, 2);
      expect(b.problems[0], contains('the fee 0.005'));
      expect(b.problems[1], contains('the balance 100.001'));
      expect(b.transactions.single.balanceAfter, 0);
    });

    test('bitcoin keeps its satoshis and amounts below a cent get different ids', () {
      final b = _revolut([_row('-0.001', 'BTC'), _row('-0.002', 'BTC'), _row('-0.000000015', 'BTC')]);
      expect([for (final t in b.transactions) t.amountMinor], [-100000, -200000]);
      expect(b.transactions[0].id, isNot(b.transactions[1].id));
      expect(b.transactions[0].id, transactionId('2026-03-01', -100000, 'Synthetic shop', 0, digits: 8));
      expect(b.problems.single, contains('more than 8 decimals'));
    });
  });

  group('PBZ', () {
    test('EUR with three decimals is refused with its reason; exact rows keep v1 ids', () {
      final b = _pbz([
        ['02.01.2026', 'Ostalo', 'Synthetic a', -12.345, 'EUR'],
        ['03.01.2026', 'Ostalo', 'Synthetic b', -12.34, 'eur'],
      ]);
      expect(b.invalid, 1);
      expect(b.problems.single, contains('the amount -12.345 has more than 2 decimals'));
      final t = b.transactions.single;
      expect((t.amountMinor, t.currency, t.id), (-1234, 'EUR', transactionId('2026-01-03', -1234, 'Synthetic b', 0)));
    });

    test('a balance with a finer fraction refuses the row', () {
      final b = _pbz([
        ['02.01.2026', 'Ostalo', 'Synthetic a', -10.0, 'EUR', 100.005],
        ['03.01.2026', 'Ostalo', 'Synthetic b', -10.0, 'EUR', 90.0],
      ], extra: [
        'STANJE'
      ]);
      expect(b.invalid, 1);
      expect(b.problems.single, contains('the balance'));
      expect(b.transactions.single.balanceAfter, 9000);
    });
  });

  test('mapped CSV: a yen row keeps the id an earlier build gave it; problems are listed', () {
    const m = CsvMapping(
        name: 'Test CSV',
        headerRow: 0,
        dateCol: 0,
        dateFormat: CsvDateFormat.dmyDot,
        amountCol: 2,
        decimal: CsvDecimal.comma,
        negate: false,
        descriptionCols: [1],
        currencyCol: 3,
        headers: ['Datum', 'Opis', 'Iznos', 'Valuta']);
    final b = parseMappedCsv(
        Uint8List.fromList(utf8.encode('Datum;Opis;Iznos;Valuta\n05.01.2026;Shop;-1000;JPY\n05.01.2026;Shop;-1,235;KWD\n')), m);
    final t = b.transactions.single;
    expect(t.amountMinor, -100000);
    expect(t.id, sourceTransactionId(t.source, '2026-01-05', -100000, 'Shop', 0));
    expect(b.problems.single, 'Row 3: the amount -1,235 has more than 2 decimals (the third decimal of KWD is not supported)');
  });

  test('e-invoice amounts use the stored scale: 1500 yen is 150000', () {
    final xml = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"',
      ' xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"',
      ' xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2">',
      '<cbc:ID>INV-1</cbc:ID><cbc:IssueDate>2026-03-01</cbc:IssueDate><cbc:DocumentCurrencyCode>JPY</cbc:DocumentCurrencyCode>',
      '<cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="JPY">1500</cbc:PayableAmount></cac:LegalMonetaryTotal>',
      '</Invoice>',
    ].join();
    final bill = readEInvoice(xml);
    expect((bill?.total, bill?.currency), (150000, 'JPY'));
  });
}
