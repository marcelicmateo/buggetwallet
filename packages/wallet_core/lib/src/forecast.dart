/// Q11 + Q5: the balance forecast to payday and the per-account "going into the red" warnings. Pure, web-safe, exact
/// int cents; never guesses day-to-day spending and never moves money.
library;

import 'accounts.dart';
import 'bills.dart' show occurrenceKey, plannedCoverage;
import 'budget.dart' show DueCycle, IncomeCycle;
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.forecast');

const _exact = 9007199254740992; // 2^53

/// One step of [forecastToPayday]: the balance [cents] after the event on [date]. The first point is the start
/// (today, [cause] null, [delta] 0); every other one is one bill cycle, planned cost or income: [delta] its signed
/// cents, [cause] its label (the bill's label, the planned cost's title; owner text, shown, never logged) and [causeId]
/// the recurring bill's or planned cost's id.
class ForecastPoint {
  final String date;
  final int cents;
  final String? cause;
  final String? causeId;
  final int delta;
  const ForecastPoint(this.date, this.cents, this.cause, {this.causeId, this.delta = 0});

  @override
  bool operator ==(Object other) =>
      other is ForecastPoint &&
      other.date == date &&
      other.cents == cents &&
      other.cause == cause &&
      other.causeId == causeId &&
      other.delta == delta;

  @override
  int get hashCode => Object.hash(date, cents, cause, causeId, delta);

  @override
  String toString() => 'ForecastPoint($date)';
}

/// The bank balance from [today] to the day before [payday] (exclusive, the period end), starting at [startCents]
/// (the home-currency bank total, `balanceTotals(...)[currency]`; foreign currencies are left out, as everywhere).
///
/// - Each unpaid bill cycle of [cycles] (`PeriodBudget.dueCycles`) subtracts its [DueCycle.reserve] (what is still
///   unpaid) on its due date; one already overdue (due before today) on [today]. Cycles covered by a plan line count
///   too: the money still leaves the account. A cycle due on or after [payday] is left out.
/// - Each open planned cost of [planned] with an amount dated [today] .. the day before [payday] subtracts its amount
///   on its date, except a bill slip whose covering recurring cycle ([plannedCoverage] over [bills]: pass every
///   confirmed recurring bill, `WalletRepo.recurringBills()`, so a slip of a cycle just paid or skipped is known) is one
///   of [cycles] or that just-paid cycle (counted once, never twice).
/// - Each expected income of [incomes] (`PeriodBudget.expectedIncome`) dated [today] .. the day before [payday] adds its
///   amount on its date. One overdue (due before today, not landed) is left out: the forecast never counts on late money.
/// - No daily-spending guess: [forecastAfterAllowance] is the separate line with the day-to-day money taken off.
///
/// On one date, money out comes before money in (so a dip that day is shown), then by label, then id. The last point is
/// the balance expected on payday morning before the salary. Always at least the start point.
List<ForecastPoint> forecastToPayday({
  required int startCents,
  required String today,
  required String payday,
  required List<DueCycle> cycles,
  required List<PlannedCost> planned,
  required List<IncomeCycle> incomes,
  required List<RecurringBill> bills,
  Map<String, String> payeeAliases = const {},
}) {
  final events = <({String date, int delta, String cause, String id})>[];
  final counted = <String>{};
  for (final c in cycles) {
    if (c.due.compareTo(payday) >= 0) continue;
    counted.add(occurrenceKey(c.bill.id, c.due));
    if (c.reserve <= 0) continue;
    events.add((date: c.due.compareTo(today) < 0 ? today : c.due, delta: -c.reserve, cause: c.bill.label, id: c.bill.id));
  }
  for (final p in planned) {
    final a = p.amount;
    if (!p.isOpen || a == null || a <= 0 || p.date.compareTo(today) < 0 || p.date.compareTo(payday) >= 0) continue;
    final cov = plannedCoverage(p, bills, payeeAliases: payeeAliases);
    if (cov != null && (cov.occurrence == null || counted.contains(occurrenceKey(cov.bill.id, cov.occurrence!)))) continue;
    events.add((date: p.date, delta: -a, cause: p.title, id: p.id));
  }
  for (final i in incomes) {
    if (i.amount <= 0 || i.due.compareTo(today) < 0 || i.due.compareTo(payday) >= 0) continue;
    events.add((date: i.due, delta: i.amount, cause: i.bill.label, id: i.bill.id));
  }
  events.sort((x, y) {
    var d = x.date.compareTo(y.date);
    if (d == 0) d = (x.delta < 0 ? 0 : 1) - (y.delta < 0 ? 0 : 1);
    if (d == 0) d = x.cause.compareTo(y.cause);
    if (d == 0) d = x.id.compareTo(y.id);
    return d;
  });
  final out = [ForecastPoint(today, startCents, null)];
  var cents = startCents;
  for (final e in events) {
    cents += e.delta;
    assert(cents.abs() < _exact, 'forecast sums stay exact');
    out.add(ForecastPoint(e.date, cents, e.cause, causeId: e.id, delta: e.delta));
  }
  return out;
}

/// The forecast's payday balance after day-to-day spending: the last point of [forecast] minus [allowance] (the daily
/// allowance, `PeriodBudget.allowanceToday`) × [daysLeft] (`PeriodBudget.daysLeft`, today included). Today's spending
/// is already in the balance, so this takes it off once more: on the safe side. Negative inputs count as 0.
int forecastAfterAllowance(List<ForecastPoint> forecast, {required int allowance, required int daysLeft}) {
  final last = forecast.isEmpty ? 0 : forecast.last.cents;
  return last - (allowance < 0 ? 0 : allowance) * (daysLeft < 0 ? 0 : daysLeft);
}

/// What [balanceWarnings] says about one account.
enum BalanceWarningKind {
  /// The worked-out balance is below zero now ([BalanceWarning.cents]).
  belowNow,

  /// The account's forecast goes below zero on [BalanceWarning.date], at [BalanceWarning.cause].
  goesBelow,

  /// The balance is not confirmed recently ([balanceTrusted]): the app asks for a check and warns nothing else.
  checkBalance,
}

/// A warning for one bank account ([balanceWarnings]). [cents]: the balance now ([BalanceWarningKind.belowNow]) or the
/// forecast after the event that takes it below zero ([BalanceWarningKind.goesBelow]); null for a check. [date],
/// [cause], [causeId]: that event's ([ForecastPoint]).
class BalanceWarning {
  final Account account;
  final BalanceWarningKind kind;
  final int? cents;
  final String? date;
  final String? cause;
  final String? causeId;
  const BalanceWarning({required this.account, required this.kind, this.cents, this.date, this.cause, this.causeId});

  @override
  String toString() => 'BalanceWarning(${kind.name})';
}

/// The red warnings per bank account (Q5), in [balances] order, for the live home-[currency] bank accounts that count
/// their rows (not cash, not a sync duplicate, not another currency):
/// - not [balanceTrusted] (its anchor or matching check in [checks], by account id, is over [bankCheckTrustDays] old):
///   [BalanceWarningKind.checkBalance] only. The app never warns from a balance it does not trust;
/// - trusted and below zero now: [BalanceWarningKind.belowNow];
/// - trusted and its own forecast ([forecastToPayday] from its balance) goes below zero before [payday]:
///   [BalanceWarningKind.goesBelow] at the first such point.
///
/// **Attribution is exact, never guessed** (owner rule): a bill cycle of [cycles] or an income of [incomes] counts
/// against an account only when the row that paid its last cycle (or its last landing), `RecurringBill.lastPaidTx`
/// looked up in [rows], is an imported row of that account's source and currency. A bill or income with no known paying
/// row, and every planned cost ([planned] is accepted for symmetry but never attributed), goes only into the total
/// forecast ([forecastToPayday] over all accounts), never into a per-account warning. So an account can still dip
/// below zero through a payment the app cannot place; the total forecast shows it.
List<BalanceWarning> balanceWarnings({
  required List<Account> accounts,
  required List<AccountBalance> balances,
  required List<Tx> rows,
  required List<DueCycle> cycles,
  List<PlannedCost> planned = const [],
  required List<IncomeCycle> incomes,
  required String today,
  required String payday,
  required Map<String, BankCheck> checks,
  required String currency,
}) {
  final live = {
    for (final a in accounts)
      if (!a.deleted) a.id
  };
  final byId = {for (final r in rows) r.id: r};
  bool paidFrom(RecurringBill b, Account a) {
    final r = b.lastPaidTx == null ? null : byId[b.lastPaidTx];
    return r != null && !r.manual && r.source == a.source && r.currency == a.currency;
  }

  final out = <BalanceWarning>[];
  for (final ab in balances) {
    final a = ab.account;
    if (a.deleted || !live.contains(a.id) || a.isCash || ab.duplicateOf != null || a.currency != currency) continue;
    if (!balanceTrusted(a, today: today, last: checks[a.id], rows: rows)) {
      out.add(BalanceWarning(account: a, kind: BalanceWarningKind.checkBalance));
      continue;
    }
    if (ab.balance < 0) {
      out.add(BalanceWarning(account: a, kind: BalanceWarningKind.belowNow, cents: ab.balance));
      continue;
    }
    final mine = [
      for (final c in cycles)
        if (paidFrom(c.bill, a)) c
    ];
    final forecast = forecastToPayday(
      startCents: ab.balance,
      today: today,
      payday: payday,
      cycles: mine,
      planned: const [],
      bills: const [],
      incomes: [
        for (final i in incomes)
          if (paidFrom(i.bill, a)) i
      ],
    );
    for (final p in forecast) {
      if (p.cents >= 0) continue;
      out.add(
          BalanceWarning(account: a, kind: BalanceWarningKind.goesBelow, cents: p.cents, date: p.date, cause: p.cause, causeId: p.causeId));
      break;
    }
  }
  logEvent(_log, Level.FINE, 'forecast.warnings', {
    'accounts': balances.length,
    'check': out.where((w) => w.kind == BalanceWarningKind.checkBalance).length,
    'belowNow': out.where((w) => w.kind == BalanceWarningKind.belowNow).length,
    'goesBelow': out.where((w) => w.kind == BalanceWarningKind.goesBelow).length,
  });
  return out;
}
