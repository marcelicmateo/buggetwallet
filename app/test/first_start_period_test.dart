// First start without a salary row (owner 2026-10-31): the period starts on the latest expected payday on or before
// today, not on today itself. Synthetic dates.
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';

WalletController _wallet(DateTime now, {int paydayDay = 10}) {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => now);
  wc.repo.updateSettings({'salary': 150000, 'paydayDay': paydayDay});
  wc.reload();
  return wc;
}

void main() {
  test('no salary, payday 10, today 6 Mar: start 10 Feb, the period ends 10 Mar', () {
    final wc = _wallet(DateTime(2027, 3, 6, 12));
    expect(wc.settings.periodStart, isNull);
    expect(wc.effectiveSettings.periodStart, '2027-02-10');
    final p = wc.period();
    expect(p.start, '2027-02-10');
    expect(p.end, '2027-03-10');
    expect(p.daysLeft, 4);
  });

  test('today is the payday itself: the period starts today', () {
    final wc = _wallet(DateTime(2027, 3, 10, 9));
    expect(wc.effectiveSettings.periodStart, '2027-03-10');
  });

  test('day after the payday, and a year boundary', () {
    expect(_wallet(DateTime(2027, 3, 11)).effectiveSettings.periodStart, '2027-03-10');
    expect(_wallet(DateTime(2027, 1, 5)).effectiveSettings.periodStart, '2026-12-10');
  });

  test('payday 31 is the last day of a short month', () {
    // Core clamps payday 29..31 to 28.
    expect(_wallet(DateTime(2027, 3, 5), paydayDay: 31).effectiveSettings.periodStart, '2027-02-28');
  });

  test('the latest expected payday is right on every day of a year for every payday day', () {
    final bad = <String>[];
    for (var pd = 1; pd <= 28; pd++) {
      for (var d = DateTime.utc(2027, 1, 1); d.year == 2027; d = d.add(const Duration(days: 1))) {
        final today = isoDate(d);
        final clock = DateTime(d.year, d.month, d.day, 12);
        final w = _wallet(clock, paydayDay: pd);
        // Brute force: walk back day by day to the nearest date with this day of the month.
        var want = today;
        while (dayOf(want) != pd) {
          want = addDays(want, -1);
        }
        if (w.effectiveSettings.periodStart != want) bad.add('$pd $today');
        w.dispose();
      }
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
