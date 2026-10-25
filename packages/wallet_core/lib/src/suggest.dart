import 'dart:math' show min;

import 'categories.dart';
import 'dates.dart';
import 'logs.dart';
import 'models.dart';
import 'periods.dart';
import 'recurring.dart';

final _log = Logger('bw.budget');

/// One suggested plan value: [value] (cents, or a day of month for `paydayDay`), the fixed [basis] key it comes from
/// (`salaryRows`, `paydayDates`, `rentRows`, `loanRows`, `confirmedBills`) and its [evidence]: transaction ids, or the
/// recurring bill ids for `subs`.
class Suggested {
  final int value;
  final String basis;
  final List<String> evidence;
  const Suggested({required this.value, required this.basis, this.evidence = const []});
}

/// Payday plan values read from the imports ([suggestPlan]); null = not enough evidence.
class PlanSuggestion {
  final Suggested? salary, paydayDay, rent, loan, subs;
  const PlanSuggestion({this.salary, this.paydayDay, this.rent, this.loan, this.subs});
}

/// A plan setting the owner may accept ([planProposals]): [key] is the `WalletSettings` key; [current] is null when
/// the setting is unset (0 for money).
class SettingProposal {
  final String key;
  final int? current;
  final int suggested;
  final String basis;
  const SettingProposal({required this.key, this.current, required this.suggested, required this.basis});
}

/// Up to this many of the latest complete payday groups (salary) and calendar months (rent, loan) are looked at.
const _lookBack = 3;

/// Groups needed for a salary or payday suggestion, months for rent or loan.
const _minEvidence = 2;

/// Plan values from the owner's own rows, in the home currency (`st.currency`) only:
/// - **salary**: the median total of the last up to 3 complete payday groups ([salaryPaydays]; a group is complete
///   when the next payday has started). Needs 2 complete groups.
/// - **paydayDay**: the most common day of month of the payday groups' starts (29–31 read as 28, like
///   `WalletSettings.paydayDay`); a tie goes to the later day. Needs 2 groups.
/// - **rent** / **loan**: the median monthly outflow of the rows categorised Rent / Loan (the categoriser decides,
///   never the amount) over the last 3 complete calendar months that have such rows. Needs 2 months.
/// - **subs**: the sum of the expected (median) amounts of the [confirmed] recurring bills in Bills & subscriptions;
///   candidates and dismissed bills never count.
PlanSuggestion suggestPlan(List<CategorizedTx> txs, WalletSettings st, String today, {List<RecurringBill> confirmed = const []}) {
  requireIsoDate(today);
  final home = [
    for (final t in txs)
      if (t.tx.live && t.tx.currency == st.currency && t.date.compareTo(today) <= 0) t
  ];
  final s = PlanSuggestion(
    salary: _salary(home, today, st.currency),
    paydayDay: _paydayDay(home, today, st.currency),
    rent: _fixedMonthly(home, today, 'Rent', 'rentRows'),
    loan: _fixedMonthly(home, today, 'Loan', 'loanRows'),
    subs: _subs(confirmed),
  );
  logEvent(_log, Level.FINE, 'budget.suggestPlan', {
    'salary': s.salary != null,
    'paydayDay': s.paydayDay != null,
    'rent': s.rent != null,
    'loan': s.loan != null,
    'subs': s.subs != null,
  });
  return s;
}

int _byDateThenId(CategorizedTx a, CategorizedTx b) {
  final d = a.date.compareTo(b.date);
  return d != 0 ? d : a.tx.id.compareTo(b.tx.id);
}

/// The salary rows (as [salaryPaydays] reads them) grouped by payday, oldest first.
List<List<CategorizedTx>> _salaryGroups(List<CategorizedTx> home, String today, String currency) {
  final starts = salaryPaydays(home, today, currency: currency);
  if (starts.isEmpty) return const [];
  final groups = [for (final _ in starts) <CategorizedTx>[]];
  final rows = [
    for (final t in home)
      if (t.kind == BudgetKind.income && t.amount > 0) t
  ]..sort(_byDateThenId);
  var g = 0;
  for (final t in rows) {
    while (g + 1 < starts.length && t.date.compareTo(starts[g + 1]) >= 0) {
      g++;
    }
    groups[g].add(t);
  }
  return groups;
}

Suggested? _salary(List<CategorizedTx> home, String today, String currency) {
  final groups = _salaryGroups(home, today, currency);
  if (groups.length - 1 < _minEvidence) return null; // the last group is still running
  final complete = groups.sublist(0, groups.length - 1);
  final used = complete.sublist(complete.length > _lookBack ? complete.length - _lookBack : 0);
  final total = medianCents([for (final g in used) g.fold<int>(0, (s, t) => s + t.amount)]);
  if (total <= 0 || total > WalletSettings.maxAmount) return null;
  return Suggested(value: total, basis: 'salaryRows', evidence: [
    for (final g in used)
      for (final t in g) t.tx.id
  ]);
}

Suggested? _paydayDay(List<CategorizedTx> home, String today, String currency) {
  final groups = _salaryGroups(home, today, currency);
  if (groups.length < _minEvidence) return null;
  final counts = <int, int>{};
  for (final g in groups) {
    final d = min(dayOf(g.first.date), WalletSettings.maxPaydayDay);
    counts[d] = (counts[d] ?? 0) + 1;
  }
  var best = 0, bestCount = 0;
  for (final MapEntry(key: d, value: n) in counts.entries) {
    if (n > bestCount || n == bestCount && d > best) (best, bestCount) = (d, n);
  }
  return Suggested(value: best, basis: 'paydayDates', evidence: [for (final g in groups) g.first.tx.id]);
}

Suggested? _fixedMonthly(List<CategorizedTx> home, String today, String category, String basis) {
  final thisMonth = monthOf(today);
  final byMonth = <String, List<CategorizedTx>>{};
  for (final t in home) {
    final m = monthOf(t.date);
    if (t.category == category && m.compareTo(thisMonth) < 0) (byMonth[m] ??= []).add(t);
  }
  final months = byMonth.keys.toList()..sort();
  final used = months.sublist(months.length > _lookBack ? months.length - _lookBack : 0);
  if (used.length < _minEvidence) return null;
  final value = medianCents([for (final m in used) byMonth[m]!.fold<int>(0, (s, t) => s - t.amount)]);
  if (value <= 0 || value > WalletSettings.maxAmount) return null;
  return Suggested(value: value, basis: basis, evidence: [
    for (final m in used)
      for (final t in byMonth[m]!..sort(_byDateThenId)) t.tx.id
  ]);
}

/// The fixed category subscriptions are planned in.
const _subsCategory = 'Bills & subscriptions';

Suggested? _subs(List<RecurringBill> bills) {
  final seen = <String>{};
  final used = [
    for (final b in bills)
      if (b.confirmed && b.category == _subsCategory && b.expectedAmount > 0 && seen.add(b.id)) b
  ];
  if (used.isEmpty) return null;
  final total = used.fold<int>(0, (s, b) => s + b.expectedAmount);
  if (total > WalletSettings.maxAmount) return null;
  return Suggested(value: total, basis: 'confirmedBills', evidence: [for (final b in used) b.id]);
}

/// The suggestions in [s] that differ from the current settings, in the order salary, paydayDay, rent, loan, subs.
/// `current` is null for a money setting that is 0 (unset); `paydayDay` always has one (`WalletSettings` cannot tell
/// unset from its default). Nothing is written: the app applies the accepted ones through `updateSettings`.
List<SettingProposal> planProposals(PlanSuggestion s, WalletSettings st) {
  SettingProposal? one(String key, Suggested? x, int current, {bool money = true}) {
    if (x == null || x.value == current) return null;
    return SettingProposal(key: key, current: money && current == 0 ? null : current, suggested: x.value, basis: x.basis);
  }

  return [
    one('salary', s.salary, st.salary),
    one('paydayDay', s.paydayDay, st.paydayDay, money: false),
    one('rent', s.rent, st.rent),
    one('loan', s.loan, st.loan),
    one('subs', s.subs, st.subs),
  ].whereType<SettingProposal>().toList();
}
