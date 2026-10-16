import 'package:budget_wallet/src/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('money formatting', () {
    expect(money(123456, 'EUR'), '€1,235');
    expect(money(-2340, 'EUR', decimals: 2), '−€23.40');
    expect(money(150, 'EUR', signed: true), '+€1.50');
  });
  test('money parsing', () {
    expect(parseMoney('12,50'), 1250);
    expect(parseMoney('1.234,56'), 123456);
    expect(parseMoney('2300'), 230000);
    expect(parseMoney('abc'), isNull);
  });
  test('dates', () {
    expect(shortDate('2026-10-12'), '12 Oct');
    expect(monthLong('2026-10'), 'October 2026');
  });
}
