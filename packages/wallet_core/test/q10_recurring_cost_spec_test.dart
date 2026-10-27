// Stage Q10 spec tests: recurringCost(bills, currency:) -> (monthly, yearly) over confirmed, live, outgoing bills.
// Monthly (calendar) bills count exactly; day-interval bills: yearly = amount * 365 ~/ intervalDays, monthly = yearly ~/ 12;
// ranged bills use the midpoint. Written from docs/context/STAGE_Q_PLAN.md Q10 only. SYNTHETIC data.
// API: ({int monthly, int yearly, bool approximate}) recurringCost(List<RecurringBill>, {required String currency}).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _n = 0;
RecurringBill _bill(int amount,
        {int interval = 30, String status = 'confirmed', String? direction, int? min, int? max, String payee = ''}) =>
    RecurringBill(
      id: 'rec-${_n++}',
      payee: payee.isEmpty ? 'synthpayee$_n' : payee,
      label: 'Synth bill',
      category: 'Bills & subscriptions',
      expectedAmount: amount,
      intervalDays: interval,
      nextDue: '2026-04-01',
      status: status,
      direction: direction,
      minAmount: min,
      maxAmount: max,
    );

({int monthly, int yearly, bool approximate}) _cost(List<RecurringBill> b, {String currency = 'EUR'}) =>
    recurringCost(b, currency: currency);

void main() {
  test('no bills: zero', () {
    expect(_cost([]), (monthly: 0, yearly: 0, approximate: false));
  });
  test('a monthly bill counts its amount exactly: yearly is twelve of it', () {
    expect(_cost([_bill(1299)]), (monthly: 1299, yearly: 15588, approximate: false));
  });
  test('weekly: yearly = amount * 365 ~/ 7, monthly = yearly ~/ 12, integer rounding as written', () {
    expect(_cost([_bill(700, interval: 7)]), (monthly: 3041, yearly: 36500, approximate: false));
    expect(
        _cost([_bill(1000, interval: 7)]), (monthly: 4345, yearly: 52142, approximate: false)); // 365000 ~/ 7 = 52142, 52142 ~/ 12 = 4345
  });
  test('biweekly: 2000 every 14 days', () {
    expect(_cost([_bill(2000, interval: 14)]), (monthly: 4345, yearly: 52142, approximate: false));
  });
  test('quarterly: 9100 every 91 days is four payments a year, 36400', () {
    expect(_cost([_bill(9100, interval: 91)]), (monthly: 3033, yearly: 36400, approximate: false));
  });
  test('yearly: 12000 every 365 days is 12000 a year and 1000 a month', () {
    expect(_cost([_bill(12000, interval: 365)]), (monthly: 1000, yearly: 12000, approximate: false));
  });
  test('yearly amount not divisible by twelve rounds the monthly down', () {
    expect(_cost([_bill(12005, interval: 365)]), (monthly: 1000, yearly: 12005, approximate: false));
  });
  test('a ranged bill uses the midpoint of its range', () {
    expect(_cost([_bill(3000, min: 2000, max: 3000)]), (monthly: 2500, yearly: 30000, approximate: true));
    expect(_cost([_bill(800, interval: 7, min: 600, max: 800)]), (monthly: 3041, yearly: 36500, approximate: true)); // midpoint 700 weekly
  });
  test('bills add up; monthly and yearly of the sum use each bill\'s own exact figure', () {
    final c = _cost([_bill(1299), _bill(9100, interval: 91), _bill(12000, interval: 365)]);
    expect(c.yearly, 15588 + 36400 + 12000);
    expect(c.monthly, 1299 + 3033 + 1000);
  });
  test('candidates and dismissed bills are not counted', () {
    expect(_cost([_bill(1299, status: 'candidate'), _bill(1299, status: 'dismissed')]), (monthly: 0, yearly: 0, approximate: false));
    expect(_cost([_bill(1299), _bill(500, status: 'dismissed')]), (monthly: 1299, yearly: 15588, approximate: false));
  });
  test('income is excluded', () {
    expect(_cost([_bill(150000, direction: 'in')]), (monthly: 0, yearly: 0, approximate: false));
    expect(_cost([_bill(1299), _bill(30000, direction: 'in', status: 'in:confirmed')]), (monthly: 1299, yearly: 15588, approximate: false));
  });
  test('approximate is false without a range and true as soon as one ranged bill is in the sum', () {
    expect(_cost([_bill(1299), _bill(500)]).approximate, isFalse);
    expect(_cost([_bill(1299), _bill(3000, min: 2000, max: 3000)]).approximate, isTrue);
  });
  test('an instalment bill whose last due date has passed is not counted', () {
    const done = RecurringBill(
        id: 'rec-done',
        payee: 'synthloan',
        label: 'Synth loan',
        category: 'Loan',
        expectedAmount: 5000,
        nextDue: '2026-06-01',
        status: 'confirmed',
        endsOn: '2026-01-01');
    expect(done.finished, isTrue);
    expect(_cost([done]), (monthly: 0, yearly: 0, approximate: false));
  });
  // "Other currency excluded" cannot be tested: bills carry no currency (they are detected only from wallet-currency rows or
  // entered by hand in it), so recurringCost's `currency` only names the result's currency.
}
