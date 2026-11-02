// ENG §6.1 money as hours of work (hours.dart) + the workHoursPerWeek setting. SYNTHETIC numbers only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  // 5200.00 a month at 40 h a week: 40 × 52 ÷ 12 hours a month → 30.00 an hour, so a tenth of an hour = 300 cents.
  const st = WalletSettings(salary: 520000);

  test('rounded once, half away from zero, at the .05 boundaries; sign ignored', () {
    expect([hoursTenths(149, st), hoursTenths(150, st), hoursTenths(449, st), hoursTenths(450, st)], [0, 1, 1, 2]);
    expect(hoursTenths(-150, st), 1);
    expect(hoursTenths(25200, st), 84); // "8.4 h"
  });

  test('the rate is an exact rational: 37 h a week, a salary that does not divide', () {
    // tenths = 1000 × 37 × 130 / (3 × 333333) = 4810000 / 999999 = 4.81… → 5
    expect(hoursTenths(1000, const WalletSettings(salary: 333333, workHoursPerWeek: 37)), 5);
  });

  test('no salary → null', () {
    expect(hoursTenths(1000, const WalletSettings()), isNull);
    expect(hoursTenths(1000, const WalletSettings(salary: -1)), isNull);
  });

  test('very large amounts: exact, then capped at 2^53 − 1', () {
    expect(hoursTenths(WalletSettings.maxAmount, st), 333333333); // 333333333.33…
    expect(hoursTenths(-9223372036854775807, const WalletSettings(salary: 1)), 9007199254740991);
  });

  test('workHoursPerWeek: default 40, 1..100, bad values fall back, updateSettings refuses them', () {
    expect(const WalletSettings().workHoursPerWeek, 40);
    for (final (v, want) in [(1, 1), (100, 100), (0, 40), (101, 40), ('x', 40), (null, 40)]) {
      expect(WalletSettings.fromMap({'workHoursPerWeek': v}).workHoursPerWeek, want, reason: '$v');
    }
    final r = WalletRepo.inMemory();
    for (final bad in [0, 101, 'x', 40.5]) {
      expect(() => r.updateSettings({'workHoursPerWeek': bad}), throwsArgumentError, reason: '$bad');
    }
    r.updateSettings({'workHoursPerWeek': 35});
    expect(r.settings().workHoursPerWeek, 35);
    r.close();
  });
}
