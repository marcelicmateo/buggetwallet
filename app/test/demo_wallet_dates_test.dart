// The demo fixture must not depend on the real date: every day of a leap year and of a normal year gives a running pay
// period with days left (payday rule C moved the period end of the old fixed paydayDay 28 onto 26..30 of some months).
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

void main() {
  for (final year in [2027, 2028]) {
    test('demoWallet runs with days left on every day of $year', () {
      final bad = <String>[];
      for (var d = DateTime.utc(year, 1, 1); d.year == year; d = d.add(const Duration(days: 1))) {
        final day = DateTime(d.year, d.month, d.day, 12);
        final wc = demoWallet(clock: () => day);
        final p = wc.period();
        if (p.paydayPassed || p.daysLeft < 1 || wc.settings.periodStart != addDays(isoDate(day), -25)) bad.add(isoDate(day));
        wc.dispose();
      }
      expect(bad, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
