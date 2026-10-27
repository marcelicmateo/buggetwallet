// Bank balance checks (Q5), the payday forecast (Q11) and the bills cost line (Q10) in the controller. Core does every sum
// (`checkBankBalance`, `balanceTrusted`, `forecastToPayday`, `balanceWarnings`, `recurringCost`); this only gathers the inputs, caches
// them per data version and day, and writes the owner's answers. A `part` of controller.dart so it can use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never account names, amounts or balances.
part of 'controller.dart';

final _fcLog = Logger('bw.forecast');

/// What the payday forecast shows (Q11): the steps from today to payday, the balance on payday before day-to-day spending and after it.
class PaydayForecast {
  final List<ForecastPoint> points;

  /// The payday date (the period end): the day after the last day the forecast covers.
  final String payday;

  /// The balance on payday morning, after bills and planned costs and with expected income, before day-to-day spending.
  final int onPayday;

  /// [onPayday] minus the daily allowance for the days left; null when there is no allowance to take off.
  final int? afterSpending;

  /// True when a bank account in the home currency is not confirmed lately (its balance is only worked out).
  final bool someUnchecked;
  const PaydayForecast(this.points, this.payday, this.onPayday, this.afterSpending, this.someUnchecked);
}

extension ForecastDb on WalletController {
  /// The last stored balance check of each account that has one (device-local).
  Map<String, BankCheck> bankChecks() =>
      _cached(const MemoKey('bankChecks'), () => repo.lastBankChecks([for (final a in accountsAll()) a.id]));

  /// The last check of [accountId], or null.
  BankCheck? lastBankCheckOf(String accountId) => bankChecks()[accountId];

  /// "The bank showed [bankCents] on [date]" (the answer to the question after an import, or Settings › Accounts › Check balance):
  /// compares it with what the app counts and stores the check. Never changes a balance. Returns the comparison.
  /// Core's [ArgumentError] text is owner-readable.
  BalanceCheck recordBalanceCheck(String accountId, {required String date, required int bankCents}) {
    final a = accountsAll().firstWhere((x) => x.id == accountId, orElse: () => throw ArgumentError('No such account.'));
    final c = checkBankBalance(a, [for (final t in wholeTxs) t.tx], date: date, bankCents: bankCents);
    repo.recordBankCheck(accountId, date: date, bankCents: bankCents, appCents: c.appCents);
    logEvent(_fcLog, Level.INFO, 'balance.check', {'result': c.matches ? 'match' : 'off', 'rows': c.rowsSince});
    _changed();
    return c;
  }

  /// What the app counts for [accountId] up to and including [date] (the prefill of the bank question).
  int appBalanceOn(String accountId, String date) {
    final a = accountsAll().firstWhere((x) => x.id == accountId);
    return checkBankBalance(a, [for (final t in wholeTxs) t.tx], date: date, bankCents: 0).appCents;
  }

  /// The red lines for Today (Q5): below zero now, goes below zero before payday (and at which bill), or "check your balance".
  /// Empty while the period has ended or there is no bank account.
  List<BalanceWarning> balanceWarningList() => _cached(const MemoKey('balanceWarnings'), () {
        final accounts = accountsAll();
        if (accounts.isEmpty) return const <BalanceWarning>[];
        final p = period();
        return balanceWarnings(
          accounts: accounts,
          balances: accountBalanceList(),
          rows: [for (final t in wholeTxs) t.tx],
          cycles: p.dueCycles,
          planned: plannedOpen(),
          incomes: p.expectedIncome,
          today: today(),
          payday: p.end,
          checks: bankChecks(),
          currency: currency,
        );
      });

  /// The balance forecast to payday (Q11), or null when it cannot be told honestly: no home-currency bank account whose balance is
  /// confirmed (`balanceTrusted`), or the pay period already ended.
  PaydayForecast? paydayForecast() => _cached(const MemoKey('paydayForecast'), () {
        final accounts = accountsAll();
        if (accounts.isEmpty) return null;
        final p = period();
        if (p.paydayPassed) return null;
        final rows = [for (final t in wholeTxs) t.tx];
        final checks = bankChecks();
        final now = today();
        var banks = 0, trusted = 0;
        for (final b in accountBalanceList()) {
          final a = b.account;
          if (a.isCash || b.duplicateOf != null || a.currency != currency) continue;
          banks++;
          if (balanceTrusted(a, today: now, last: checks[a.id], rows: rows)) trusted++;
        }
        if (trusted == 0) return null;
        final start = heldTotals()[currency] ?? 0;
        final points = forecastToPayday(
          startCents: start,
          today: now,
          payday: p.end,
          cycles: p.dueCycles,
          planned: plannedOpen(),
          incomes: p.expectedIncome,
          bills: recurringBills(),
        );
        final after = p.allowanceToday > 0 ? forecastAfterAllowance(points, allowance: p.allowanceToday, daysLeft: p.daysLeft) : null;
        return PaydayForecast(points, p.end, points.last.cents, after, trusted < banks);
      });

  /// "Bills and subscriptions: X a month · Y a year" (Q10): the confirmed bills' cost, or null when there are none.
  ({int monthly, int yearly, bool approximate})? billsCost() => _cached(const MemoKey('billsCost'), () {
        final confirmed = [
          for (final b in expectedBills())
            if (b.confirmed) b
        ];
        if (confirmed.isEmpty) return null;
        final c = recurringCost(confirmed, currency: currency);
        return c.yearly <= 0 ? null : c;
      });
}
