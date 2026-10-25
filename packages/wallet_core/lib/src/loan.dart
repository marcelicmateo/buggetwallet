import 'dates.dart';
import 'models.dart';

/// What the loan still costs: [payments] more months, [cents] in all at today's rate, ending in [endMonth] (`YYYY-MM`).
class LoanLeft {
  final int payments;
  final int cents;
  final String endMonth;
  const LoanLeft(this.payments, this.cents, this.endMonth);
}

/// The payments left on the loan, or null when there is no loan, no end month, or nothing is left.
///
/// A month counts when its payday (`paydayDay`, a short month's last day) is [today] or later, from the month of
/// [today] to `loanEnd` inclusive: this month's payment is counted until its payday has passed. There is no interest
/// data, so `cents` is `payments × loan`.
LoanLeft? loanLeft(WalletSettings st, String today) {
  final end = st.loanEnd;
  if (st.loan <= 0 || end == null) return null;
  var month = monthOf(today);
  var n = 0;
  while (month.compareTo(end) <= 0) {
    final y = int.parse(month.substring(0, 4));
    final m = int.parse(month.substring(5, 7));
    // `nextPayday` of the month before gives this month's payday (clamped to the month's last day).
    final payday = nextPayday(isoDate(DateTime.utc(y, m - 1, 1)), st.paydayDay);
    if (payday.compareTo(today) >= 0) n++;
    month = monthOf(isoDate(DateTime.utc(y, m + 1, 1)));
  }
  return n == 0 ? null : LoanLeft(n, n * st.loan, end);
}
