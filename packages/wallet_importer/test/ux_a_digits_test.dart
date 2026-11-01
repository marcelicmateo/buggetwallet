// Stage UX-A core, point 1 (docs/context/UX_SPEC.md): the importer parses amounts into minor units with the digits of the
// row's currency when it knows it. Written from the spec, not the implementation. All data SYNTHETIC.
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

  test('JPY has no minor digits: 1000 yen is 1000 units, not 100000', () {
    expect(_amounts('05.01.2026;Shop;-1000;JPY'), [-1000]);
    expect(_amounts('05.01.2026;Shop;5;JPY'), [5]);
  });

  test('JPY with a fraction is refused or dropped, never read as cents', () {
    try {
      final got = _amounts('05.01.2026;Shop;-10,5;JPY');
      expect(got, isNot(contains(-1050)));
      expect(got, isNot(contains(-105)));
      expect(got, isNot(contains(-10)), reason: 'a silent rounding is a money bug');
    } on Object {
      // a clear error is the other allowed outcome
    }
  });

  test('KWD has three digits: 2 dinar is 2000 minor units, 0,005 is 5', () {
    expect(_amounts('05.01.2026;Shop;-1,234;KWD'), [-1234]);
    expect(_amounts('05.01.2026;Shop;2;KWD'), [2000]);
    expect(_amounts('05.01.2026;Shop;0,005;KWD'), [5]);
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
    expect(_amounts('05.01.2026;A;-10,00;EUR\n06.01.2026;B;-10;JPY\n07.01.2026;C;-10,000;KWD'), [-1000, -10, -10000]);
  });
}
