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

  /// What the start balance leaves out, in words ("PBZ not checked lately, cash and other currencies are not included"), or null when
  /// nothing is left out. Account names are the owner's own words: shown, never logged.
  final String? leftOut;
  const PaydayForecast(this.points, this.payday, this.onPayday, this.afterSpending, this.leftOut);
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
    // An older answer (an older file) never replaces a newer check: the comparison is shown, nothing is stored.
    final last = repo.lastBankCheck(accountId);
    final older = last != null && last.date.compareTo(date) > 0;
    if (!older) repo.recordBankCheck(accountId, date: date, bankCents: bankCents, appCents: c.appCents);
    logEvent(_fcLog, Level.INFO, 'balance.check', {'result': c.matches ? 'match' : 'off', 'rows': c.rowsSince, 'older': older});
    _changed();
    return c;
  }

  /// What the app counts for [accountId] up to and including [date] (the prefill of the bank question).
  int appBalanceOn(String accountId, String date) {
    final a = accountsAll().firstWhere((x) => x.id == accountId);
    return checkBankBalance(a, [for (final t in wholeTxs) t.tx], date: date, bankCents: 0).appCents;
  }

  /// The question to put to the owner now, or null: [q] was built while its file was written, so the app's number is counted again over
  /// every row (another file of the same pick may have added older rows since), and a question not newer than the stored check is dropped.
  BankQuestion? questionNow(BankQuestion q) {
    if (!accountsAll().any((a) => a.id == q.accountId)) return null;
    final last = repo.lastBankCheck(q.accountId);
    if (last != null && last.date.compareTo(q.date) >= 0) return null;
    return BankQuestion(
        accountId: q.accountId, name: q.name, currency: q.currency, date: q.date, appCents: appBalanceOn(q.accountId, q.date));
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
        // The start is the confirmed bank balances in the home currency only: an unchecked account, cash and other currencies are left
        // out (and said so), so a number the app does not trust never moves the headline.
        var trusted = 0, start = 0, cash = false, foreign = false;
        final unchecked = <String>[];
        for (final b in accountBalanceList()) {
          final a = b.account;
          if (b.duplicateOf != null) continue;
          if (a.isCash) {
            cash = true;
          } else if (a.currency != currency) {
            foreign = true;
          } else if (balanceTrusted(a, today: now, last: checks[a.id], rows: rows)) {
            trusted++;
            start += b.balance;
          } else {
            unchecked.add(a.name);
          }
        }
        if (trusted == 0) return null;
        final out = [if (cash) 'cash', if (foreign) 'other currencies'];
        final left = [
          if (unchecked.isNotEmpty) '${unchecked.join(', ')} not checked lately',
          if (out.isNotEmpty) '${out.join(' and ')} ${out.length == 1 ? 'is' : 'are'} not included',
        ];
        final leftOut = left.isEmpty ? null : left.join(', ');
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
        return PaydayForecast(points, p.end, points.last.cents, after, leftOut);
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
