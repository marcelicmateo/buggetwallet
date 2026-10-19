// Edge cases for lib/src/format.dart: parsing odd amounts, formatting extremes, dates at month/year ends.
// Expected values are worked out by hand from the documented behaviour. All data is SYNTHETIC.
import 'package:budget_wallet/src/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseMoney: empty and junk', () {
    for (final s in [
      '',
      ' ',
      '   ',
      '\t',
      '\n',
      '€',
      r'$',
      '£',
      '€ €',
      '.',
      ',',
      '..',
      ',,',
      '-',
      '+',
      'abc',
      '12abc',
      'abc12',
      '1O0',
      '12 EUR',
      '--5',
      '1..2'
    ]) {
      test('"${s.replaceAll('\n', r'\n').replaceAll('\t', r'\t')}" is not a number', () => expect(parseMoney(s), isNull));
    }
    test('NaN is not a number', () => expect(parseMoney('NaN'), isNull));
    test('two decimal points are rejected, not guessed', () {
      expect(parseMoney('12.5.5'), isNull);
      expect(parseMoney('1.2.3'), isNull);
    });
  });

  group('parseMoney: zero and sign', () {
    test('zero in several spellings is 0 (the sheets reject it, the parser does not)', () {
      expect(parseMoney('0'), 0);
      expect(parseMoney('0.00'), 0);
      expect(parseMoney('0,00'), 0);
      expect(parseMoney('-0'), 0);
      expect(parseMoney('00012'), 1200);
    });
    test('negative is null', () {
      expect(parseMoney('-1'), isNull);
      expect(parseMoney('-0,01'), isNull);
      expect(parseMoney('-€5'), isNull);
      expect(parseMoney('€-5'), isNull);
    });
    test('a leading plus is accepted', () => expect(parseMoney('+5'), 500));
  });

  group('parseMoney: separators', () {
    test('decimal comma and decimal point', () {
      expect(parseMoney('12,5'), 1250);
      expect(parseMoney('12,50'), 1250);
      expect(parseMoney('12.5'), 1250);
      expect(parseMoney('12.50'), 1250);
      expect(parseMoney('0,01'), 1);
      expect(parseMoney('0.01'), 1);
    });
    test('European and US grouping give the same cents', () {
      expect(parseMoney('1.234,56'), 123456);
      expect(parseMoney('1,234.56'), 123456);
      expect(parseMoney('12.345,67'), 1234567);
      expect(parseMoney('12,345.67'), 1234567);
      expect(parseMoney('1.234.567,89'), 123456789);
      expect(parseMoney('1,234,567.89'), 123456789);
    });
    test('grouping without decimals: comma groups thousands', () {
      expect(parseMoney('1,234'), 123400);
      expect(parseMoney('1,234,567'), 123456700);
    });
    test('a trailing or leading separator', () {
      expect(parseMoney('12,'), 1200);
      expect(parseMoney('12.'), 1200);
      expect(parseMoney(',5'), 50);
      expect(parseMoney('.5'), 50);
      expect(parseMoney(',50'), 50);
    });
    test('spaces anywhere are ignored', () {
      expect(parseMoney('1 234,56'), 123456);
      expect(parseMoney(' 12 , 50 '), 1250);
    });
    test('currency symbols before or after', () {
      expect(parseMoney('€12'), 1200);
      expect(parseMoney('12 €'), 1200);
      expect(parseMoney('12€'), 1200);
      expect(parseMoney(r'$12.50'), 1250);
      expect(parseMoney('£1,200.00'), 120000);
    });
    test('"0,005" is not five euros (a leading-zero group is no thousands group)', () {
      expect(parseMoney('0,005'), isNot(500));
    });
  });

  group('parseMoney: rounding', () {
    test('values that are not exact in binary still round to the typed cents', () {
      expect(parseMoney('0.29'), 29);
      expect(parseMoney('1.15'), 115);
      expect(parseMoney('4.35'), 435);
      expect(parseMoney('19.99'), 1999);
      expect(parseMoney('0.07'), 7);
      expect(parseMoney('8.2'), 820);
    });
    test('more than two decimals round to the nearest cent, never throw', () {
      expect(parseMoney('1.004'), 100);
      expect(parseMoney('1.006'), 101);
      expect(parseMoney('0.001'), 0);
    });
    test('every cent value 0..20000 survives a print-and-parse round trip', () {
      for (var c = 0; c <= 20000; c++) {
        final s = '${c ~/ 100}.${(c % 100).toString().padLeft(2, '0')}';
        expect(parseMoney(s), c, reason: s);
        expect(parseMoney(s.replaceAll('.', ',')), c, reason: s);
      }
    });
  });

  group('parseMoney: huge and odd numbers never throw', () {
    test('a big but sane amount is exact', () {
      expect(parseMoney('1000000'), 100000000);
      expect(parseMoney('1.000.000,00'), 100000000);
    });
    test('"Infinity" is not a number and does not throw', () {
      expect(() => parseMoney('Infinity'), returnsNormally);
      expect(parseMoney('Infinity'), isNull);
    });
    test('exponent overflow does not throw', () {
      expect(() => parseMoney('1e400'), returnsNormally);
      expect(parseMoney('1e400'), isNull);
    });
    test('an absurdly long number is rejected rather than saved as a wrong amount', () {
      final v = parseMoney('99999999999999999999');
      expect(v, isNull, reason: 'got $v');
    });
    test('scientific notation is not an amount', () {
      expect(parseMoney('1e3'), isNull);
    });
    test('the cap is 10 billion, inclusive', () {
      expect(parseMoney('10000000000'), 1000000000000);
      expect(parseMoney('10000000000.01'), isNull);
      expect(parseMoney('10,000,000,001'), isNull);
    });
    test('hex is not an amount', () {
      expect(parseMoney('0x10'), isNull);
    });
    test('very long text is just null or the number', () {
      expect(parseMoney('a' * 100000), isNull);
      expect(parseMoney('9' * 3 + ' ' * 100000), 99900);
    });
    test('emoji and right-to-left digits are null', () {
      expect(parseMoney('💶12'), isNull);
      expect(parseMoney('١٢'), isNull);
      expect(parseMoney('\u202E12'), isNull);
    });
  });

  group('money: extremes', () {
    test('zero, one cent, negative one cent', () {
      expect(money(0, 'EUR'), '€0.00');
      expect(money(1, 'EUR'), '€0.01');
      expect(money(-1, 'EUR'), '−€0.01');
      expect(money(9, 'EUR'), '€0.09');
      expect(money(10, 'EUR'), '€0.10');
    });
    test('the switch to whole units is at exactly 100.00', () {
      expect(money(9999, 'EUR'), '€99.99');
      expect(money(10000, 'EUR'), '€100');
      expect(money(-9999, 'EUR'), '−€99.99');
      expect(money(-10000, 'EUR'), '−€100');
    });
    test('whole units round half away from zero, with thousands separators', () {
      expect(money(10049, 'EUR'), '€100');
      expect(money(10050, 'EUR'), '€101');
      expect(money(99950, 'EUR'), '€1,000');
      expect(money(123456, 'EUR'), '€1,235');
      expect(money(-123450, 'EUR'), '−€1,235');
      expect(money(100000000, 'EUR'), '€1,000,000');
    });
    test('decimals: 2 keeps cents at any size', () {
      expect(money(123456789, 'EUR', decimals: 2), '€1,234,567.89');
      expect(money(100000, 'EUR', decimals: 2), '€1,000.00');
      expect(money(100, 'EUR', decimals: 2), '€1.00');
    });
    test('decimals: 0 on small amounts', () {
      expect(money(0, 'EUR', decimals: 0), '€0');
      expect(money(49, 'EUR', decimals: 0), '€0');
      expect(money(50, 'EUR', decimals: 0), '€1');
    });
    test('a negative amount that rounds to zero is not shown as minus zero', () {
      expect(money(-49, 'EUR', decimals: 0), '€0');
    });
    test('signed: plus only for positive, nothing for zero', () {
      expect(money(0, 'EUR', signed: true), '€0.00');
      expect(money(1, 'EUR', signed: true), '+€0.01');
      expect(money(-1, 'EUR', signed: true), '−€0.01');
    });
    test('the minus is the real minus sign, not a hyphen', () {
      expect(money(-500, 'EUR').codeUnitAt(0), 0x2212);
    });
    test('max int does not throw', () {
      const max = 9223372036854775807;
      expect(money(max, 'EUR', decimals: 2), '€92,233,720,368,547,758.07');
      expect(() => money(max, 'EUR'), returnsNormally);
      expect(() => money(-max, 'EUR'), returnsNormally);
      expect(money(-max, 'EUR', decimals: 2), '−€92,233,720,368,547,758.07');
    });
    test('currencies: known symbols, unknown code is spelled out', () {
      expect(money(1250, 'USD'), r'$12.50');
      expect(money(1250, 'GBP'), '£12.50');
      expect(money(1250, 'CHF'), 'CHF 12.50');
      expect(money(-1250, 'CHF'), '−CHF 12.50');
    });
    test('no formatted amount contains NaN, Infinity or null, over a sweep', () {
      for (final c in [0, 1, -1, 99, 100, 101, 9999, 10000, 12345, -12345, 999999, 1000000, -100000000]) {
        for (final d in [null, 0, 2]) {
          final s = money(c, 'EUR', decimals: d, signed: true);
          expect(s, matches(RegExp(r'^[+−]?€[0-9,]+(\.[0-9]{2})?$')), reason: '$c/$d -> $s');
        }
      }
    });
  });

  group('timeLeft: odd input', () {
    test('tiny positive time still shows 1h, never 0h', () {
      expect(timeLeft(1e-12), '1h left');
      expect(timeLeft(1e-6), '1h left');
    });
    test('exact hour and day boundaries', () {
      expect(timeLeft(1), '1h left');
      expect(timeLeft(1.0000001), '2h left');
      expect(timeLeft(23.999), '1d left');
      expect(timeLeft(48), '2d left');
      expect(timeLeft(72 * 10), '30d left');
    });
    test('a very long wait', () {
      expect(timeLeft(24.0 * 365), '365d left');
      expect(() => timeLeft(1e12), returnsNormally);
    });
    test('negative zero and large negatives are Ready', () {
      expect(timeLeft(-0.0), 'Ready');
      expect(timeLeft(-1e9), 'Ready');
    });
    test('NaN does not throw', () {
      expect(() => timeLeft(double.nan), returnsNormally);
    });
  });

  group('percent', () {
    test('rounding and sign', () {
      expect(percent(0), '0%');
      expect(percent(0.004), '0%');
      expect(percent(0.005), '1%');
      expect(percent(-0.004), '0%');
      expect(percent(-0.006), '−1%');
      expect(percent(1), '100%');
      expect(percent(1.5), '150%');
      expect(percent(-1), '−100%');
      expect(percent(123.456), '12346%');
    });
    test('NaN and infinity (0/0 shares) do not throw', () {
      expect(() => percent(double.nan), returnsNormally);
      expect(() => percent(double.infinity), returnsNormally);
    });
  });

  group('dates', () {
    test('first and last day of every month', () {
      const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      const last = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
      for (var m = 1; m <= 12; m++) {
        final mm = m.toString().padLeft(2, '0');
        expect(shortDate('2027-$mm-01'), '1 ${names[m - 1]}');
        expect(shortDate('2027-$mm-${last[m - 1]}'), '${last[m - 1]} ${names[m - 1]}');
        expect(monthShort('2027-$mm'), names[m - 1]);
      }
    });
    test('leap day', () {
      expect(shortDate('2028-02-29'), '29 Feb');
      expect(longDate('2028-02-29'), 'Tuesday, 29 February 2028');
      expect(longDate('2024-02-29'), 'Thursday, 29 February 2024');
    });
    test('long date weekdays at year ends', () {
      expect(longDate('2026-12-31'), 'Thursday, 31 December 2026');
      expect(longDate('2027-01-01'), 'Friday, 1 January 2027');
      expect(longDate('2000-01-01'), 'Saturday, 1 January 2000');
    });
    test('zero-padded and unpadded days both print without padding', () {
      expect(shortDate('2026-10-05'), '5 Oct');
      expect(shortDate('2026-10-5'), '5 Oct');
    });
    test('month names', () {
      expect(monthLong('2026-01'), 'January 2026');
      expect(monthLong('2026-12'), 'December 2026');
      expect(monthLong('2026-10-17'), 'October 2026', reason: 'a full date is accepted');
      expect(monthYear(2027, 2), 'February 2027');
      expect(monthYear(2026, 12), 'December 2026');
    });
    test('invalid strings throw (they never return a made-up date)', () {
      for (final bad in ['', 'x', '2026', '2026-13-01', '2026-00-10', 'ab-cd-ef']) {
        expect(() => shortDate(bad), throwsA(anything), reason: bad);
      }
      expect(() => monthShort('2026-13'), throwsA(anything));
      expect(() => monthLong('2026-00'), throwsA(anything));
      expect(() => monthYear(2026, 13), throwsA(anything));
      expect(() => monthYear(2026, 0), throwsA(anything));
    });
    test('a day that does not exist is not given a weekday', () {
      expect(() => longDate('2026-02-30'), throwsA(anything));
    });
    test('shortDateOrRaw / longDateOrRaw: a real date is formatted, anything else is shown as stored', () {
      expect(shortDateOrRaw('2026-10-10'), '10 Oct');
      expect(longDateOrRaw('2026-10-10'), 'Saturday, 10 October 2026');
      for (final bad in ['2026-02-30', '2026-13-01', '2026-00-10', '', 'x', '2026', '2026-2-1', '2026-10-10T00:00']) {
        expect(shortDateOrRaw(bad), bad, reason: bad);
        expect(longDateOrRaw(bad), bad, reason: bad);
      }
    });
  });

  group('dateRange (exclusive end)', () {
    test('plain month', () => expect(dateRange('2026-10-12', '2026-11-12'), '12 Oct – 11 Nov'));
    test('across a year end', () => expect(dateRange('2026-12-15', '2027-01-14'), '15 Dec – 13 Jan'));
    test('end on the 1st shows the last day of the previous month', () {
      expect(dateRange('2026-10-12', '2026-11-01'), '12 Oct – 31 Oct');
      expect(dateRange('2026-01-10', '2026-03-01'), '10 Jan – 28 Feb');
      expect(dateRange('2028-01-10', '2028-03-01'), '10 Jan – 29 Feb');
      expect(dateRange('2027-12-20', '2028-01-01'), '20 Dec – 31 Dec');
    });
    test('one-day period', () => expect(dateRange('2026-10-12', '2026-10-13'), '12 Oct – 12 Oct'));
  });
}
