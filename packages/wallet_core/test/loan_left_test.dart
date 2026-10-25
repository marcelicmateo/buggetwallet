// loanLeft: payments left on the loan from the plan's paydays. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

WalletSettings _st({int loan = 30000, String? end = '2027-03', int day = 15}) => WalletSettings(loan: loan, loanEnd: end, paydayDay: day);

void main() {
  test('counts the months from this month to the end month, inclusive', () {
    final l = loanLeft(_st(), '2026-10-01')!;
    expect(l.payments, 6); // Oct, Nov, Dec, Jan, Feb, Mar
    expect(l.cents, 6 * 30000);
    expect(l.endMonth, '2027-03');
  });

  test('this month counts until its payday has passed', () {
    expect(loanLeft(_st(), '2026-10-14')!.payments, 6);
    expect(loanLeft(_st(), '2026-10-15')!.payments, 6); // payday today
    expect(loanLeft(_st(), '2026-10-16')!.payments, 5);
  });

  test('the month of loanEnd: one payment before its payday, none after', () {
    final st = _st(end: '2026-10');
    expect(loanLeft(st, '2026-10-15')!.payments, 1);
    expect(loanLeft(st, '2026-10-15')!.cents, 30000);
    expect(loanLeft(st, '2026-10-16'), isNull);
  });

  test('a past end, no loan, no end month: null', () {
    expect(loanLeft(_st(end: '2026-09'), '2026-10-01'), isNull);
    expect(loanLeft(_st(loan: 0), '2026-10-01'), isNull);
    expect(loanLeft(_st(end: null), '2026-10-01'), isNull);
  });

  test('payday 28 in February and across a year end', () {
    expect(loanLeft(_st(end: '2027-02', day: 28), '2027-01-29')!.payments, 1);
    expect(loanLeft(_st(end: '2027-02', day: 28), '2027-02-28')!.payments, 1);
    expect(loanLeft(_st(end: '2027-02', day: 28), '2027-03-01'), isNull);
    expect(loanLeft(_st(end: '2027-01', day: 15), '2026-12-20')!.payments, 1);
  });
}
