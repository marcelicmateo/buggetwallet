// Stage UX-A (docs/context/UX_SPEC.md §1), the builder's own importer tests: bank files read amounts with the row's
// currency digits while ids stay the ones every earlier build gave (v1 for Revolut/PBZ). All data SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/src/ids.dart' show minorIdText;
import 'package:wallet_importer/src/profiles/cells.dart' show cellMinor;
import 'package:wallet_importer/wallet_importer.dart';

const _hdr = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance';

ImportBatch _revolut(List<String> rows) => importBankFile(Uint8List.fromList(utf8.encode('$_hdr\n${rows.join('\n')}\n')));

String _row(String amount, String currency, {String fee = '0', String balance = '0'}) =>
    'Card Payment,Current,2026-03-01 10:00:00,2026-03-01 10:00:00,Synthetic shop,$amount,$fee,$currency,COMPLETED,$balance';

void main() {
  test('cellMinor: 2 digits is v1 rounding; other digits refuse a finer fraction', () {
    expect(cellMinor(-12.345, 2), -1234, reason: "v1's Math.round: halves towards +infinity");
    expect(cellMinor(-1000, 0), -1000);
    expect(cellMinor(10.5, 0), isNull);
    expect(cellMinor(1.234, 3), 1234);
    expect(cellMinor(1.2345, 3), isNull);
    expect(cellMinor(0.00000001, 8), 1);
    expect(cellMinor(0.1 + 0.2, 8), 30000000, reason: 'double noise is not a fraction');
    expect(cellMinor(double.nan, 0), isNull);
  });

  test('minorIdText: the hundredths text of earlier builds where they could read the row, else the exact decimal', () {
    expect(minorIdText(-1000, 0), '-1000.00');
    expect(minorIdText(-1234, 2), '-12.34');
    expect(minorIdText(2000, 3), '2.00');
    expect(minorIdText(1234, 3), '1.234');
    expect(minorIdText(1000000, 8), '0.01');
    expect(minorIdText(-1, 8), '-0.00000001');
  });

  test('Revolut: a yen row is read in yen, its id is the v1 one (from cents)', () {
    final yen = _revolut([_row('-1000', 'JPY', fee: '10', balance: '5000')]).transactions.single;
    final eur = _revolut([_row('-10.10', 'EUR')]).transactions.single;
    expect((yen.amountMinor, yen.currency, yen.balanceAfter), (-1010, 'JPY', 5000));
    expect(yen.id, transactionId('2026-03-01', -101000, 'Synthetic shop', 0), reason: 'v1 hashed -1010.00');
    expect(eur.amountMinor, -1010);
    expect(eur.id, transactionId('2026-03-01', -1010, 'Synthetic shop', 0));
  });

  test('Revolut: a yen amount with a fraction is invalid, never rounded; bitcoin keeps its satoshis', () {
    final b = _revolut([_row('-10.5', 'JPY'), _row('0.00012345', 'BTC')]);
    expect(b.invalid, 1);
    expect(b.transactions.single.amountMinor, 12345);
  });

  test('mapped CSV ids: a yen row keeps the id an earlier build gave it (amount text 1000.00)', () {
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
    final b = parseMappedCsv(Uint8List.fromList(utf8.encode('Datum;Opis;Iznos;Valuta\n05.01.2026;Shop;-1000;JPY\n')), m);
    final t = b.transactions.single;
    expect(t.amountMinor, -1000);
    expect(t.id, sourceTransactionId(t.source, '2026-01-05', -100000, 'Shop', 0));
  });

  test('e-invoice amounts use the invoice currency digits', () {
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
    expect((bill?.total, bill?.currency), (1500, 'JPY'));
  });
}
