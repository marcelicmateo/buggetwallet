// Stage UX-A core, point 1 (docs/context/UX_SPEC.md): the importer parses amounts into minor units with the digits of the
// row's currency when it knows it. Written from the spec, not the implementation. All data SYNTHETIC.
// Updated by core-builder to the lead's storage rule (2026-11-01): every fiat currency is stored in hundredths as before
// (JPY too), a non-zero third decimal (KWD) is refused, BTC is stored in satoshis.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

const _mapping = CsvMapping(
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

List<int> _amounts(String rows) =>
    parseMappedCsv(_b('Datum;Opis;Iznos;Valuta\n$rows\n'), _mapping).transactions.map((t) => t.amountMinor).toList();

void main() {
  test('EUR keeps two digits (control)', () {
    expect(_amounts('05.01.2026;Shop;-12,30;EUR'), [-1230]);
    expect(_amounts('05.01.2026;Shop;12;EUR'), [1200]);
  });

  test('JPY is stored in hundredths like every fiat currency: 1000 yen is 100000', () {
    expect(_amounts('05.01.2026;Shop;-1000;JPY'), [-100000]);
    expect(_amounts('05.01.2026;Shop;5;JPY'), [500]);
  });

  test('JPY with a fraction is kept exactly (hundredths hold it), never rounded', () {
    expect(_amounts('05.01.2026;Shop;-10,5;JPY'), [-1050]);
  });

  test('KWD is stored in hundredths: 2 dinar is 200, 10,000 is 1000; a non-zero third decimal is refused', () {
    expect(_amounts('05.01.2026;Shop;2;KWD'), [200]);
    expect(_amounts('05.01.2026;Shop;-10,000;KWD'), [-1000]);
    expect(_amounts('05.01.2026;Shop;-1,234;KWD'), isEmpty);
    expect(_amounts('05.01.2026;Shop;0,005;KWD'), isEmpty);
    final b = parseMappedCsv(_b('Datum;Opis;Iznos;Valuta\n05.01.2026;Shop;-1,234;KWD\n'), _mapping);
    expect(b.invalid, 1);
  });

  test('BTC has eight digits: 0,01 BTC is 1,000,000 and one satoshi is 1', () {
    expect(_amounts('05.01.2026;Coin;0,01;BTC'), [1000000]);
    expect(_amounts('05.01.2026;Coin;-0,00000001;BTC'), [-1]);
    expect(_amounts('05.01.2026;Coin;2;BTC'), [200000000]);
  });

  test('more fraction digits than the currency has are never rounded silently', () {
    try {
      final got = _amounts('05.01.2026;Shop;-12,345;EUR');
      expect(got, isNot(contains(-1234)));
      expect(got, isNot(contains(-1235)));
    } on Object {
      // refused is fine
    }
  });

  test('rows of different currencies in one file each use their own digits', () {
    expect(_amounts('05.01.2026;A;-10,00;EUR\n06.01.2026;B;-10;JPY\n07.01.2026;C;-10,000;KWD\n08.01.2026;D;-0,5;BTC'),
        [-1000, -1000, -1000, -50000000]);
  });
}
