import 'package:wallet_importer/wallet_importer.dart' show CsvMapping, bankProfiles, csvSourcePrefix;

import 'dates.dart';
import 'models.dart';

/// What an account or import `source` is called: `Cash` for null, a bank profile's label, a saved CSV layout's name
/// for `csv:<shapeId>` (P12, from [csvMappings] = [WalletSettings.csvMappings]; `CSV file` once the layout is
/// removed), else the source as it is.
String accountSourceLabel(String? source, {Map<String, CsvMapping> csvMappings = const {}}) {
  if (source == null) return 'Cash';
  for (final p in bankProfiles) {
    if (p.id == source) return p.label;
  }
  if (source.startsWith(csvSourcePrefix)) return csvMappings[source.substring(csvSourcePrefix.length)]?.name ?? 'CSV file';
  return source;
}

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

// ---------- bank balance checks (Q5) ----------

/// How long a confirmed balance is trusted for warnings ([balanceTrusted]), in days.
const bankCheckTrustDays = 35;

/// [checkBankBalance]'s result: the bank's [bankCents] at the end of [date] against the app's own count [appCents]
/// for that day; [diff] = bank − app (0 = matches the bank). [rowsSince] = the rows counted from [since] (the account's
/// opening date, its last anchor) up to and including [date]: where a difference would be (the "see rows since" line).
class BalanceCheck {
  final String date;
  final int bankCents;
  final int appCents;
  final int rowsSince;
  final String since;
  const BalanceCheck({required this.date, required this.bankCents, required this.appCents, required this.rowsSince, required this.since});

  int get diff => bankCents - appCents;
  bool get matches => diff == 0;

  /// What is stored on this device (`WalletRepoAccounts.recordBankCheck`).
  BankCheck get stored => BankCheck(date: date, bankCents: bankCents, appCents: appCents);
}

/// The bank's balance [bankCents] at the end of [date] compared with the app's: `a.opening` + the rows that count for
/// [a] (the same rule as [accountBalances]: not deleted, the account's currency, after its opening date, its own
/// source's imported rows, or for cash the unmatched hand-added ones) dated up to and including [date]. Pass the
/// account that counts its (source, currency) (not one with [AccountBalance.duplicateOf]). Exact cents; never writes.
BalanceCheck checkBankBalance(Account a, List<Tx> rows, {required String date, required int bankCents}) {
  var sum = a.opening, n = 0;
  for (final r in rows) {
    if (!_counts(a, r) || r.date.compareTo(date) > 0) continue;
    sum += r.amount;
    n++;
  }
  assert(sum.abs() < _exact, 'balance sums stay exact');
  return BalanceCheck(date: date, bankCents: bankCents, appCents: sum, rowsSince: n, since: a.openingDate);
}

const _exact = 9007199254740992; // 2^53

/// A check as stored on this device (`WalletRepoAccounts.recordBankCheck`, device-local `bankCheck:<accountId>`,
/// never synced): the bank's [bankCents] and the app's [appCents] at the end of [date]. [appCents] and [diff] are what
/// the app counted then, for display only: trust is decided again from the rows ([balanceTrusted]).
class BankCheck {
  final String date;
  final int bankCents;
  final int appCents;
  const BankCheck({required this.date, required this.bankCents, required this.appCents});

  int get diff => bankCents - appCents;

  Map<String, Object?> toJson() => {'date': date, 'bank': bankCents, 'app': appCents};

  /// Reads [toJson]'s shape; null for anything else (a damaged value).
  static BankCheck? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = j['date'], b = j['bank'], a = j['app'];
    if (d is! String || !isIsoDate(d) || b is! int || a is! int) return null;
    return BankCheck(date: d, bankCents: b, appCents: a);
  }
}

/// Whether [a]'s worked-out balance may be warned from on [today] (Q5): its anchor is at most [bankCheckTrustDays]
/// days old. The anchor is the opening date (set when the account was added, or by a correction: `correctBalance`
/// moves it, so a check the owner then corrected counts from the correction) or [last] when the bank's balance still
/// matches the app's: decided now from [rows] ([checkBankBalance] at `last.date` against `last.bankCents`), never from
/// the stored [BankCheck.appCents] (a row deleted later, here or by a sync, makes a stored match stale). A check that is
/// off now, or dated before the opening, never counts. A date after [today] counts as recent.
bool balanceTrusted(Account a, {required String today, BankCheck? last, required List<Tx> rows}) {
  bool recent(String d) => isIsoDate(d) && isIsoDate(today) && daysBetween(d, today) <= bankCheckTrustDays;
  if (recent(a.openingDate)) return true;
  if (last == null || !recent(last.date) || last.date.compareTo(a.openingDate) < 0) return false;
  return checkBankBalance(a, rows, date: last.date, bankCents: last.bankCents).matches;
}
