// Q10 core: what the confirmed bills cost a month and a year, each rounding pinned. All amounts SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

RecurringBill _bill(int cents,
        {int days = 30,
        String status = 'confirmed',
        int? min,
        int? max,
        String? endsOn,
        String nextDue = '2026-02-01',
        String? direction}) =>
    RecurringBill(
        id: 'rec:q10-${_seq++}',
        payee: 'synthetic',
        label: 'Synthetic bill',
        category: 'Bills & subscriptions',
        expectedAmount: cents,
        intervalDays: days,
        nextDue: nextDue,
        status: status,
        minAmount: min,
        maxAmount: max,
        endsOn: endsOn,
        direction: direction);

({int monthly, int yearly, bool approximate}) _cost(List<RecurringBill> bills) => recurringCost(bills, currency: 'EUR');

void main() {
  test('nothing → zero, exact', () {
    expect(_cost(const []), (monthly: 0, yearly: 0, approximate: false));
  });

  test('monthly bills (27..31 days) count their amount exactly, × 12 a year', () {
    expect(_cost([_bill(1999)]), (monthly: 1999, yearly: 23988, approximate: false));
    expect(_cost([_bill(1000, days: 27)]), (monthly: 1000, yearly: 12000, approximate: false));
    expect(_cost([_bill(1000, days: 31)]), (monthly: 1000, yearly: 12000, approximate: false));
  });

  test('quarterly × 4 and yearly × 1 a year; monthly = yearly ~/ 12', () {
    expect(_cost([_bill(3000, days: 91)]), (monthly: 1000, yearly: 12000, approximate: false));
    expect(_cost([_bill(3001, days: 91)]), (monthly: 1000, yearly: 12004, approximate: false)); // 12004 ~/ 12 = 1000
    expect(_cost([_bill(3000, days: 88)]), (monthly: 1000, yearly: 12000, approximate: false)); // still quarterly (±7)
    expect(_cost([_bill(12345, days: 365)]), (monthly: 1028, yearly: 12345, approximate: false)); // 12345 ~/ 12 = 1028
  });

  test('other intervals: yearly = amount × 365 ~/ days, monthly = yearly ~/ 12', () {
    // Weekly: 1000 × 365 = 365000; ~/ 7 = 52142 (52142.86 rounded down); ~/ 12 = 4345.
    expect(_cost([_bill(1000, days: 7)]), (monthly: 4345, yearly: 52142, approximate: false));
    // Every 2 weeks: 365000 ~/ 14 = 26071; ~/ 12 = 2172.
    expect(_cost([_bill(1000, days: 14)]), (monthly: 2172, yearly: 26071, approximate: false));
    // A custom 60-day interval (no class): 365000 ~/ 60 = 6083; ~/ 12 = 506.
    expect(_cost([_bill(1000, days: 60)]), (monthly: 506, yearly: 6083, approximate: false));
  });

  test('a ranged bill counts the midpoint (rounded down) and makes the result approximate', () {
    expect(_cost([_bill(1500, min: 1000, max: 2001)]), (monthly: 1500, yearly: 18000, approximate: true));
    // An invalid range (min > max) is no range: the expected amount, exact.
    expect(_cost([_bill(1500, min: 3000, max: 2000)]), (monthly: 1500, yearly: 18000, approximate: false));
  });

  test('only confirmed, outgoing, unfinished bills count', () {
    final counted = _bill(1000);
    final bills = [
      counted,
      _bill(5000, status: 'candidate'),
      _bill(5000, status: 'dismissed'),
      _bill(5000, direction: RecurringBill.directionIn),
      // An instalment plan that is over: next due long after its last date.
      _bill(5000, endsOn: '2025-12-01', nextDue: '2026-02-01'),
    ];
    expect(_cost(bills), (monthly: 1000, yearly: 12000, approximate: false));
    // An instalment plan still running counts.
    expect(_cost([_bill(5000, endsOn: '2026-06-01')]).monthly, 5000);
  });

  test('totals add each bill own figures', () {
    final bills = [_bill(1000), _bill(1000, days: 7), _bill(3000, days: 91), _bill(1500, min: 1000, max: 2000)];
    expect(_cost(bills), (monthly: 1000 + 4345 + 1000 + 1500, yearly: 12000 + 52142 + 12000 + 18000, approximate: true));
  });
}
