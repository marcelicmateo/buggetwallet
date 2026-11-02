// ENG E6 (docs/context/ENG_UI_SPEC.md §6.5): the home goal's planner maths and its "Get there sooner" levers. Pure,
// web-safe, integer cents; the loan payment is an exact BigInt rational rounded once, half away from zero.
import 'budget.dart' show countsAsSpending;
import 'categories.dart' show CategoryTable;
import 'dates.dart';
import 'fx.dart' show inHomeCurrency;
import 'models.dart';
import 'recurring.dart' show recurringCycleCost;

/// A home goal's numbers (`homePlan`), integer cents. [months]: whole months of [monthly] to save [left] (0 when
/// nothing is left, null when [monthly] is 0 or less and something is left); [readyMonth] `YYYY-MM` = today's month +
/// [months]. [payment] is an estimate (rate typed by the owner). Exactly one of [afterPerPeriod] (≥ 0) and [shortBy]
/// (> 0) is set: what the spending money per period would be after paying the loan instead of rent.
class HomePlan {
  final int price, deposit, costs, need, saved, left, monthly;
  final int? months;
  final String? readyMonth;
  final int loan, payment;

  /// [payment] − rent: above zero the loan costs more than rent a month (shown in words, never as a negative).
  final int vsRent;
  final int? afterPerPeriod, shortBy;
  const HomePlan(
      {required this.price,
      required this.deposit,
      required this.costs,
      required this.need,
      required this.saved,
      required this.left,
      required this.monthly,
      required this.months,
      required this.readyMonth,
      required this.loan,
      required this.payment,
      required this.vsRent,
      required this.afterPerPeriod,
      required this.shortBy});
}

/// [a] · [num] / [den] for a ≥ 0, num ≥ 0, den > 0, rounded half away from zero.
int _ratio(int a, int num, int den) =>
    ((BigInt.from(a) * BigInt.from(num) * BigInt.two + BigInt.from(den)) ~/ (BigInt.from(den) * BigInt.two)).toInt();

/// Monthly annuity payment for [loan] cents at [rateBp] a year over [months]: L·r / (1 − (1+r)^−n) with r = bp / 120 000,
/// exact, rounded once half away from zero; rate 0 = loan ÷ months rounded up to the cent.
int annuityPayment(int loan, int rateBp, int months) {
  if (loan <= 0) return 0;
  if (rateBp <= 0) return (loan + months - 1) ~/ months;
  const d = 120000;
  final g = BigInt.from(d + rateBp).pow(months), dn = BigInt.from(d).pow(months);
  final num = BigInt.from(loan) * BigInt.from(rateBp) * g; // L·b·(D+b)^n
  final den = BigInt.from(d) * (g - dn); // D·((D+b)^n − D^n)
  return ((num * BigInt.two + den) ~/ (den * BigInt.two)).toInt();
}

/// `YYYY-MM` of [ym] + [n] months.
String _addMonths(String ym, int n) {
  final k = int.parse(ym.substring(0, 4)) * 12 + int.parse(ym.substring(5, 7)) - 1 + n;
  return '${k ~/ 12}-${(k % 12 + 1).toString().padLeft(2, '0')}';
}

/// The House planner for goal [g] (`Goal.homePrice`, `depositPermille` (null = paid in full), `buyCostPermille`,
/// `loanRateBp` (null = 0), `loanMonths`): deposit and costs are the price's permille, need = deposit + costs, left =
/// need − [savedCents] (never below 0), loan = price − deposit. [today] is `YYYY-MM-DD`.
HomePlan homePlan(Goal g,
    {required int savedCents,
    required int monthlyCents,
    required int rentCents,
    required int toSpendPerPeriodCents,
    required String today}) {
  final price = (g.homePrice ?? 0) < 0 ? 0 : g.homePrice ?? 0;
  final deposit = _ratio(price, g.depositPermille ?? 1000, 1000);
  final costs = _ratio(price, g.buyCostPermille, 1000);
  final need = deposit + costs;
  final left = need - savedCents > 0 ? need - savedCents : 0;
  final months = left == 0 ? 0 : (monthlyCents <= 0 ? null : (left + monthlyCents - 1) ~/ monthlyCents);
  final loan = price - deposit;
  final payment = annuityPayment(loan, g.loanRateBp ?? 0, g.loanMonths);
  final after = toSpendPerPeriodCents - (payment - rentCents);
  return HomePlan(
      price: price,
      deposit: deposit,
      costs: costs,
      need: need,
      saved: savedCents,
      left: left,
      monthly: monthlyCents,
      months: months,
      readyMonth: months == null ? null : _addMonths(monthOf(today), months),
      loan: loan,
      payment: payment,
      vsRent: payment - rentCents,
      afterPerPeriod: after >= 0 ? after : null,
      shortBy: after < 0 ? -after : null);
}

enum HomeLeverKind { tag, income }

/// One "Get there sooner" chip: [cut] cents a month more into the fund ([kind] `tag`: main tag [key] back to its
/// 12-month median; `income`: confirmed recurring income [key]), so the fund is ready in [months] instead of the plan's;
/// [monthsSaved] = the plan's months − [months] (null when the plan has no months: nothing saved a month yet).
class HomeLever {
  final HomeLeverKind kind;
  final String key;
  final int cut, months;
  final int? monthsSaved;
  const HomeLever(this.kind, this.key, this.cut, this.months, this.monthsSaved);
}

/// The levers for [plan] (read-only; empty when nothing is left to save). Main tags (the row's resolved category,
/// [CategoryTable.topLevel]) whose mean over the last 3 of the 12 completed calendar months before [today]'s month
/// exceeds their median over those 12 (a month without spend = 0; "Where it goes" rows in the home currency,
/// [countsAsSpending] after [inHomeCurrency], refunds subtracted): cut = the difference rounded down to whole euros
/// (none under 1 €). Then each confirmed, unfinished recurring income in [incomes] (the caller passes those not yet
/// counted in the plan) at its monthly figure ([recurringCycleCost]). Tags by cut (largest first), then incomes.
List<HomeLever> homeLevers(List<CategorizedTx> expanded, WalletSettings st, CategoryTable table, String today,
    {required HomePlan plan, List<RecurringBill> incomes = const []}) {
  if (plan.left == 0) return const [];
  final months = monthsEnding(monthOf(today), 13)..removeLast();
  final index = {for (var i = 0; i < months.length; i++) months[i]: i};
  final byTag = <String, List<int>>{};
  for (final t in inHomeCurrency(expanded, st)) {
    final i = index[monthOf(t.date)];
    if (i == null || !countsAsSpending(t, st.currency)) continue;
    (byTag[table.topLevel(t.category)] ??= List.filled(12, 0))[i] -= t.amount;
  }
  HomeLever lever(HomeLeverKind kind, String key, int cut) {
    final monthly = plan.monthly > 0 ? plan.monthly + cut : cut;
    final m = (plan.left + monthly - 1) ~/ monthly;
    return HomeLever(kind, key, cut, m, plan.months == null ? null : plan.months! - m);
  }

  final tags = <HomeLever>[];
  for (final e in byTag.entries) {
    final v = e.value;
    final last3 = v[9] + v[10] + v[11];
    final sorted = [...v]..sort();
    final mid2 = sorted[5] + sorted[6]; // 2 × the median
    final over6 = 2 * last3 - 3 * mid2; // 6 × (mean − median)
    final cut = over6 > 0 ? over6 ~/ 600 * 100 : 0;
    if (cut > 0) tags.add(lever(HomeLeverKind.tag, e.key, cut));
  }
  tags.sort((a, b) => b.cut != a.cut ? b.cut.compareTo(a.cut) : a.key.compareTo(b.key));
  final ins = [
    for (final r in incomes)
      if (r.isIncome && r.confirmed && !r.finished)
        if (recurringCycleCost(r) case (monthly: final m, yearly: _) when m > 0) lever(HomeLeverKind.income, r.id, m),
  ]..sort((a, b) => b.cut != a.cut ? b.cut.compareTo(a.cut) : a.key.compareTo(b.key));
  return [...tags, ...ins];
}
