import 'package:budget_wallet/src/date_length.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('addLength', () {
    test('days and weeks', () {
      expect(addLength('2026-10-18', '4d'), '2026-10-22');
      expect(addLength('2026-10-18', '45d'), '2026-12-02');
      expect(addLength('2026-12-30', '3d'), '2027-01-02');
      expect(addLength('2026-10-18', '2w'), '2026-11-01');
    });

    test('months keep the day or clamp to the month end', () {
      expect(addLength('2026-10-18', '1m'), '2026-11-18');
      expect(addLength('2026-01-31', '1m'), '2026-02-28');
      expect(addLength('2028-01-31', '1m'), '2028-02-29');
      expect(addLength('2026-03-31', '1m'), '2026-04-30');
      expect(addLength('2026-11-30', '3m'), '2027-02-28');
      expect(addLength('2026-12-15', '14m'), '2028-02-15');
    });

    test('years, with 29 Feb', () {
      expect(addLength('2026-10-18', '5y'), '2031-10-18');
      expect(addLength('2028-02-29', '1y'), '2029-02-28');
      expect(addLength('2028-02-29', '4y'), '2032-02-29');
    });

    test('case and spaces do not matter', () {
      expect(addLength('2026-10-18', ' 14 D '), '2026-11-01');
      expect(addLength('2026-10-18', '1Y'), '2027-10-18');
    });

    test('bad text throws FormatException', () {
      for (final t in ['', 'd', '5', '5x', '1.5y', '-3d', '0d', '1 2d', '10000d', '5 years']) {
        expect(() => addLength('2026-10-18', t), throwsFormatException, reason: t);
      }
    });

    test('a bad start date or a result past 2100 throws', () {
      expect(() => addLength('2026-02-30', '1d'), throwsFormatException);
      expect(() => addLength('x', '1d'), throwsFormatException);
      expect(() => addLength('2099-06-01', '5y'), throwsFormatException);
      expect(addLength('2099-06-01', '1y'), '2100-06-01');
    });
  });
}
