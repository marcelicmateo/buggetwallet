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
    expect(dateRange('2026-10-12', '2026-11-01'), '12 Oct – 31 Oct');
  });
  test('percent', () {
    expect(percent(0.144), '14%');
    expect(percent(-0.05), '−5%');
    expect(percent(null), '—');
  });
  group('wishlist time left (bug A: "2d 24h left")', () {
    test('examples', () {
      expect(timeLeft(71.9), '3d left');
      expect(timeLeft(72), '3d left');
      expect(timeLeft(71.0), '2d 23h left');
      expect(timeLeft(70.2), '2d 23h left');
      expect(timeLeft(47.5), '2d left');
      expect(timeLeft(24.01), '1d 1h left');
      expect(timeLeft(24), '1d left');
      expect(timeLeft(23.5), '1d left');
      expect(timeLeft(23), '23h left');
      expect(timeLeft(5.1), '6h left');
      expect(timeLeft(0.01), '1h left');
      expect(timeLeft(0), 'Ready');
      expect(timeLeft(-3), 'Ready');
    });
    test('hours are always 1-23, never 24 or 0, over many durations', () {
      final re = RegExp(r'^(?:(\d+)d(?: (\d+)h)?|(\d+)h) left$');
      for (var minutes = 1; minutes <= 10 * 24 * 60; minutes++) {
        final h = minutes / 60;
        final s = timeLeft(h);
        final m = re.firstMatch(s);
        expect(m, isNotNull, reason: '$h -> $s');
        final days = int.tryParse(m!.group(1) ?? '') ?? 0;
        final hours = int.tryParse(m.group(2) ?? m.group(3) ?? '') ?? 0;
        if (m.group(2) != null || m.group(3) != null) expect(hours, inInclusiveRange(1, 23), reason: '$h -> $s');
        expect(days * 24 + hours, h.ceil(), reason: '$h -> $s: rounded up to the next whole hour');
      }
    });
  });
}
