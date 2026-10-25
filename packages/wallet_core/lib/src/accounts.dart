import 'models.dart';

/// One account's balance from its opening and the rows after it ([accountBalances]).
class AccountBalance {
  final Account account;

  /// `account.opening` + the counted rows' amounts, in cents of `account.currency`.
  final int balance;
  final int rowsCounted;

  /// The latest counted row's date, or null when no row counts (the UI shows it as "as of last import").
  final String? lastRowDate;

  /// Another live account with the same (source, currency) and a smaller id (two devices added one each before they
  /// synced): that one counts the rows, so this one shows its opening only and is left out of [balanceTotals].
  final String? duplicateOf;

  const AccountBalance({required this.account, required this.balance, required this.rowsCounted, this.lastRowDate, this.duplicateOf});
}

/// Whether [row] counts for [a]: not deleted, in the account's currency, after its opening date (the opening is the
/// balance at the end of that day), and the account's own: a bank account's imported rows from its source (every
/// kind: spending, income, fees, ATM, own transfers, exchanges), or for cash the hand-added rows not matched (or
/// pending a match) to a bank row, which the bank account already counts. ATM withdrawals are not added to cash.
bool _counts(Account a, Tx row) {
  if (row.deleted || row.currency != a.currency || row.date.compareTo(a.openingDate) <= 0) return false;
  if (a.isCash) return row.manual && row.matchedTo == null && !row.matchPending;
  return !row.manual && row.source == a.source;
}

/// The balance of each live account in [accounts] (input order; deleted accounts are skipped) from [rows]: opening +
/// the amounts of the rows that count for it ([_counts]). Exact cents, one currency per account. Each (source,
/// currency) is counted once: of several live accounts with one key (added on two devices before a sync) the
/// smallest id counts the rows; the others get [AccountBalance.duplicateOf], their opening as balance and no rows.
List<AccountBalance> accountBalances(List<Account> accounts, List<Tx> rows) {
  final owner = <(String?, String), String>{}; // (source, currency) -> the counted account's id
  for (final a in accounts) {
    if (a.deleted) continue;
    final k = (a.source, a.currency);
    final have = owner[k];
    if (have == null || a.id.compareTo(have) < 0) owner[k] = a.id;
  }
  final out = <AccountBalance>[];
  for (final a in accounts) {
    if (a.deleted) continue;
    final counted = owner[(a.source, a.currency)]!;
    if (counted != a.id) {
      out.add(AccountBalance(account: a, balance: a.opening, rowsCounted: 0, duplicateOf: counted));
      continue;
    }
    var sum = a.opening, n = 0;
    String? last;
    for (final r in rows) {
      if (!_counts(a, r)) continue;
      sum += r.amount;
      n++;
      if (last == null || r.date.compareTo(last) > 0) last = r.date;
    }
    out.add(AccountBalance(account: a, balance: sum, rowsCounted: n, lastRowDate: last));
  }
  return out;
}

/// The balances summed per currency (never mixed), keys sorted. Duplicates ([AccountBalance.duplicateOf]) are left out.
Map<String, int> balanceTotals(List<AccountBalance> b) {
  final sums = <String, int>{};
  for (final x in b) {
    if (x.duplicateOf != null) continue;
    sums[x.account.currency] = (sums[x.account.currency] ?? 0) + x.balance;
  }
  final keys = sums.keys.toList()..sort();
  return {for (final k in keys) k: sums[k]!};
}
