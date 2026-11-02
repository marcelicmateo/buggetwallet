// ENG_UI_SPEC §6.1 (money as hours of work), written from the spec, not the implementation. SYNTHETIC amounts only.
// Rate = salary / (hours a week * 52 / 12); tenths of an hour = cents / rate * 10, exact, rounded once half away from zero.
// With salary 520000 and 40 h a week: tenths = cents * 130 * 40 / (3 * 520000) = cents / 300.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  const st = WalletSettings(salary: 520000, workHoursPerWeek: 40);

  test('default is 40 hours a week (owner answer 2026-11-02)', () {
    expect(const WalletSettings().workHoursPerWeek, 40);
  });

  group('rounding at the .05 boundaries', () {
    test('149 cents = 0.497 tenths -> 0, 150 = 0.5 -> 1, 151 -> 1', () {
      expect(hoursTenths(149, st), 0);
      expect(hoursTenths(150, st), 1);
      expect(hoursTenths(151, st), 1);
    });
    test('449 -> 1, 450 (1.5) -> 2, 451 -> 2', () {
      expect(hoursTenths(449, st), 1);
      expect(hoursTenths(450, st), 2);
      expect(hoursTenths(451, st), 2);
    });
    test('an exact multiple is not rounded: 300 cents = 1 tenth, 3000 = 10', () {
      expect(hoursTenths(300, st), 1);
      expect(hoursTenths(3000, st), 10);
    });
    test('zero cents = 0 tenths (not null)', () {
      expect(hoursTenths(0, st), 0);
    });
    test('hours a week matter: 20 h/week doubles the rate (cents / 600); 300 cents = 0.5 -> 1, 299 -> 0', () {
      const half = WalletSettings(salary: 520000, workHoursPerWeek: 20);
      expect(hoursTenths(300, half), 1);
      expect(hoursTenths(299, half), 0);
      expect(hoursTenths(900, half), 2); // 1.5
    });
    test('a non-round rate is rounded once: 12345 cents, salary 333333, 37 h -> 59', () {
      expect(hoursTenths(12345, const WalletSettings(salary: 333333, workHoursPerWeek: 37)), 59);
    });
  });

  test('a negative amount counts by its absolute value (a payment is hours too)', () {
    expect(hoursTenths(-150, st), 1);
    expect(hoursTenths(-449, st), 1);
    expect(hoursTenths(-450, st), 2);
    expect(hoursTenths(-450, st), hoursTenths(450, st));
  });

  test('no salary (zero or negative) -> null, for any amount', () {
    expect(hoursTenths(5000, const WalletSettings(workHoursPerWeek: 40)), isNull);
    expect(hoursTenths(0, const WalletSettings(salary: 0)), isNull);
    expect(hoursTenths(5000, const WalletSettings(salary: -100000)), isNull);
  });

  group('very large amounts stay exact (no double)', () {
    test('10^12 cents', () {
      expect(hoursTenths(1000000000000, st), 3333333333);
      expect(hoursTenths(1000000000000, const WalletSettings(salary: 700001, workHoursPerWeek: 40)), 2476186939);
    });
    test('10^16 cents (past 2^53, and times 5200 past 64 bits)', () {
      expect(hoursTenths(10000000000000000, st), 33333333333333);
    });
  });
}
