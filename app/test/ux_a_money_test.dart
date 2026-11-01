// UX-A: money shown and typed by currency (stored scale: fiat hundredths, BTC satoshis; JPY shown and typed without decimals).
// EUR must read exactly as before. All data is SYNTHETIC.
import 'package:budget_wallet/src/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    numberStyle = NumberStyle.point;
    walletCurrencyCode = 'EUR';
  });

  group('EUR is unchanged', () {
    test('shown', () {
      expect(money(1234, 'EUR'), '12.34 €');
      expect(money(15000, 'EUR'), '150 €');
      expect(money(-2340, 'EUR'), '−23.40 €');
      expect(money(1234, 'EUR', decimals: 0), '12 €');
      expect(money(1500, 'EUR', decimals: 2, signed: true), '+15.00 €');
      expect(moneyExact(4750, 'EUR'), '47.50 €');
      expect(moneyExact(4800, 'EUR'), '48 €');
      expect(moneyExactSigned(-4000, 'EUR'), '−40 €');
      expect(unitsText(150000), '1,500');
      expect(amountHint, '0.00');
      expect(amountHintFor('EUR'), '0.00');
      expect(currencySymbol('EUR'), '€');
      expect(storageScale(), 100);
    });

    test('typed and written back', () {
      expect(parseMoney('12,50'), 1250);
      expect(parseMoney('1.234,56'), 123456);
      expect(parseMoney('1,234'), 123400);
      expect(parseMoney('1.234'), isNull, reason: 'a third decimal is refused, not rounded');
      expect(parseMoney('12', currency: 'EUR'), 1200);
      expect(centsToFieldText(1550), '15.50');
      expect(centsToFieldText(1500), '15');
      expect(centsToFieldText(0, blankZero: true), '');
      expect(chartUnits(250), 2.5);
    });

    test('comma style', () {
      numberStyle = NumberStyle.comma;
      expect(money(123456, 'EUR', decimals: 2), '1.234,56 €');
      expect(centsToFieldText(1550), '15,50');
      expect(amountHint, '0,00');
    });
  });

  group('JPY: no decimals shown or typed, stored in hundredths', () {
    test('shown', () {
      expect(currencySymbol('JPY'), '¥');
      expect(money(100000, 'JPY'), '1,000 ¥');
      expect(money(5000, 'JPY'), '50 ¥', reason: 'under 100 units too: never cents');
      expect(money(-150000, 'JPY', decimals: 2, signed: true), '−1,500 ¥', reason: 'a caller asking for cents still gets none');
      expect(money(250000, 'JPY', decimals: 2, signed: true), '+2,500 ¥');
      expect(moneyExact(100000, 'JPY'), '1,000 ¥');
      expect(moneyExact(150, 'JPY'), '1.50 ¥', reason: 'a fraction that cannot be typed is still shown exactly, never rounded');
      expect(unitsText(150000, 'JPY'), '1,500');
      expect(amountHintFor('JPY'), '0');
      expect(storageScale('JPY'), 100);
    });

    test('typed', () {
      expect(parseMoney('1000', currency: 'JPY'), 100000);
      expect(parseMoney('1,500', currency: 'JPY'), 150000);
      expect(parseMoney('10.5', currency: 'JPY'), isNull, reason: 'a decimal of a yen is refused');
      expect(parseMoney('¥ 300', currency: 'JPY'), 30000);
      expect(centsToFieldText(100000, currency: 'JPY'), '1000');
      expect(centsToFieldText(150, currency: 'JPY'), '1.50');
    });

    test('a JPY wallet uses it without being told', () {
      walletCurrencyCode = 'JPY';
      expect(parseMoney('10.5'), isNull);
      expect(parseMoney('2000'), 200000);
      expect(amountHint, '0');
      expect(unitsText(150000), '1,500');
      expect(centsToFieldText(300000), '3000');
    });
  });

  group('BTC: 8 decimals, stored in satoshis', () {
    test('shown', () {
      expect(currencySymbol('BTC'), '₿');
      expect(money(1500000, 'BTC'), '0.015 ₿');
      expect(money(100000000, 'BTC'), '1.00 ₿');
      expect(money(0, 'BTC'), '0.00 ₿');
      expect(money(12345678, 'BTC'), '0.12345678 ₿');
      expect(moneyExact(200000000, 'BTC'), '2 ₿');
      expect(moneyExact(1, 'BTC'), '0.00000001 ₿', reason: 'one satoshi, never rounded to zero');
      expect(money(-50000000, 'BTC', signed: true), '−0.50 ₿');
      expect(money(1234500000000, 'BTC'), '12,345.00 ₿');
      expect(amountHintFor('BTC'), '0.00000000');
      expect(unitsText(250000000, 'BTC'), '2');
      expect(storageScale('BTC'), 100000000);
      expect(chartUnits(250000000, 'BTC'), 2.5);
    });

    test('typed', () {
      expect(parseMoney('0.015', currency: 'BTC'), 1500000);
      expect(parseMoney('1', currency: 'BTC'), 100000000);
      expect(parseMoney('0.12345678', currency: 'BTC'), 12345678);
      expect(parseMoney('0.123456789', currency: 'BTC'), isNull, reason: 'a ninth decimal is refused');
      expect(parseMoney('abc', currency: 'BTC'), isNull);
      expect(centsToFieldText(1500000, currency: 'BTC'), '0.015');
      expect(centsToFieldText(100000000, currency: 'BTC'), '1');
      expect(centsToFieldText(1, currency: 'BTC'), '0.00000001');
    });
  });

  group('rates', () {
    test('a coin rate may be large, a currency rate may not', () {
      expect(parseFxRate('62000.5', code: 'BTC'), 62000500000);
      expect(parseFxRate('62000,5', code: 'BTC'), 62000500000);
      expect(parseFxRate('1000001', code: 'BTC'), isNull, reason: 'above 1,000,000 per coin');
      expect(parseFxRate('150', code: 'USD'), isNull, reason: 'above 100 per unit');
      expect(parseFxRate('0.9240', code: 'USD'), 924000);
      expect(parseFxRate('150'), 150000000, reason: 'without a code the range is core\'s to check');
      expect(parseFxRate('1.1234567', code: 'USD'), isNull, reason: 'seven decimals are refused');
    });

    test('written with grouping when large', () {
      expect(rateText(924000), '0.9240');
      expect(rateText(62000500000), '62,000.5000');
      numberStyle = NumberStyle.comma;
      expect(rateText(62000500000), '62.000,5000');
    });
  });
}
