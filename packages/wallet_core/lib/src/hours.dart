// ENG §6.1: money as hours of work. Display only: never stored, never in a sum. Pure, web-safe, exact.
import 'models.dart' show WalletSettings;

/// |[cents]| as tenths of an hour of work at the planned salary ([WalletSettings.salary], a month) over
/// [WalletSettings.workHoursPerWeek] × 52 ÷ 12 hours a month: `|cents| × hours × 52 × 10 / (12 × salary)`, exact
/// (BigInt), rounded once, half away from zero ("8.4 h" = 84). Null when there is no salary (≤ 0) or no hours.
/// Capped at 2^53 − 1 (exact on the web too).
int? hoursTenths(int cents, WalletSettings st) {
  if (st.salary <= 0 || st.workHoursPerWeek <= 0) return null;
  final n = BigInt.from(cents).abs() * BigInt.from(st.workHoursPerWeek) * BigInt.from(130), d = BigInt.from(st.salary) * BigInt.from(3);
  var q = n ~/ d;
  if ((n % d) * BigInt.two >= d) q += BigInt.one;
  const maxExact = 9007199254740991;
  return q > BigInt.from(maxExact) ? maxExact : q.toInt();
}
