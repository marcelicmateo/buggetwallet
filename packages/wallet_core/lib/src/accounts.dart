import 'dart:convert' show utf8;

import 'package:cryptography/cryptography.dart' show Hmac, SecretKey;
import 'package:wallet_importer/wallet_importer.dart' show CsvMapping, ImportBatch, bankProfiles, csvSourcePrefix;

import 'dates.dart';
import 'fx.dart' show homeAmount;
import 'models.dart';
import 'vault.dart' show VaultKey, deriveKey;

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

/// UX-ACC: which live account counts each row (the counting rule of [accountBalances], [checkBankBalance],
/// [balanceTrusted] and `balanceWarnings`). A bank row's account is
/// 1. [Tx.account] when it names a live account of the row's source and currency (of several live accounts with that
///    account's key, the smallest id: the others are sync duplicates);
/// 2. else the **main account** of (source, currency): the live one without a [Account.matchKey] (smallest id), or
///    when every live one has a key, the smallest id.
/// So a row whose account was deleted, or that an older build imported, goes back to the main account and is never
/// lost from the balances. A hand-added row belongs to the cash account of its currency (whether it counts there is
/// [_counts]'s rule). Accounts that count no rows ([Account.countsRows] false) never own one. Pure.
class RowAccounts {
  /// (source or null for cash, currency, match key) -> the counting account's id (smallest).
  final Map<(String?, String, String?), String> _byKey = {};

  /// (source or null for cash, currency) -> the main account's id.
  final Map<(String?, String), String> _main = {};
  final Map<String, Account> _live = {};

  /// From [accounts] (deleted ones are left out).
  RowAccounts(Iterable<Account> accounts) {
    for (final a in accounts) {
      final k = _rowKey(a);
      if (a.deleted || k == null) continue;
      _live[a.id] = a;
      final have = _byKey[k];
      if (have == null || a.id.compareTo(have) < 0) _byKey[k] = a.id;
    }
    final keyed = <(String?, String), String>{};
    for (final MapEntry(key: (src, cur, mk), value: id) in _byKey.entries) {
      if (mk == null) {
        _main[(src, cur)] = id;
        continue;
      }
      final have = keyed[(src, cur)];
      if (have == null || id.compareTo(have) < 0) keyed[(src, cur)] = id;
    }
    for (final MapEntry(:key, :value) in keyed.entries) {
      _main.putIfAbsent(key, () => value);
    }
  }

  /// The id of the live account that counts [row] (null: none does, e.g. no live account of its bank and currency).
  /// Dates, deletion and the cash match rules are not looked at here ([accountBalances] applies them).
  String? accountOf(Tx row) {
    if (row.manual) return _main[(null, row.currency)];
    final named = row.account == null ? null : _live[row.account];
    if (named != null && !named.isCash && named.source == row.source && named.currency == row.currency) {
      return _byKey[_rowKey(named)];
    }
    return _main[(row.source, row.currency)];
  }

  /// The main account of ([source], [currency]) (null = cash), or null when there is no live one.
  String? mainOf(String? source, String currency) => _main[(source, currency)];

  /// The live bank account of [source] and [currency] whose [Account.matchKey] is [matchKey] (smallest id), or null.
  String? keyedOf(String source, String currency, String matchKey) => _byKey[(source, currency, matchKey)];

  /// The id that counts the rows of [a]'s key ([a] itself unless it is a sync duplicate); null for an account that
  /// counts no rows or is not live.
  String? countingOf(Account a) => switch (_rowKey(a)) { final k? when _live.containsKey(a.id) => _byKey[k], _ => null };
}

/// Whether [row] counts for [a]: not deleted, in the account's currency, after its opening date (the opening is the
/// balance at the end of that day), and the account's own ([RowAccounts.accountOf]): a bank account's imported rows
/// (every kind: spending, income, fees, ATM, own transfers, exchanges), or for cash the hand-added rows not matched (or
/// pending a match) to a bank row, which the bank account already counts. ATM withdrawals are not added to cash.
/// An account without a source that is not cash (investment, crypto, other; UX-A) counts no rows: its balance is the
/// opening the owner sets ([WalletRepo.correctBalance]).
bool _counts(Account a, Tx row, RowAccounts owners) {
  if (!a.countsRows || row.deleted || row.currency != a.currency || row.date.compareTo(a.openingDate) <= 0) return false;
  if (a.isCash) return row.manual && row.matchedTo == null && !row.matchPending && owners.accountOf(row) == a.id;
  return !row.manual && row.source == a.source && owners.accountOf(row) == a.id;
}

/// The key under which [a] counts rows: (null, currency, null) for cash, (source, currency, match key) for an account
/// with a source; null for one that counts none (never a duplicate of another).
(String?, String, String?)? _rowKey(Account a) =>
    !a.countsRows ? null : (a.isCash ? (null, a.currency, null) : (a.source, a.currency, a.matchKey));

/// The balance of each live account in [accounts] (input order; deleted accounts are skipped) from [rows]: opening +
/// the amounts of the rows that count for it ([_counts], [RowAccounts]). Exact cents, one currency per account. Each
/// (source, currency, match key) is counted once: of several live accounts with one key (added on two devices before
/// a sync) the smallest id counts the rows; the others get [AccountBalance.duplicateOf], their opening as balance and
/// no rows.
List<AccountBalance> accountBalances(List<Account> accounts, List<Tx> rows) {
  final owners = RowAccounts(accounts);
  final out = <AccountBalance>[];
  for (final a in accounts) {
    if (a.deleted) continue;
    final counted = owners.countingOf(a) ?? a.id;
    if (counted != a.id) {
      out.add(AccountBalance(account: a, balance: a.opening, rowsCounted: 0, duplicateOf: counted));
      continue;
    }
    var sum = a.opening, n = 0;
    String? last;
    for (final r in rows) {
      if (!_counts(a, r, owners)) continue;
      sum += r.amount;
      n++;
      if (last == null || r.date.compareTo(last) > 0) last = r.date;
    }
    out.add(AccountBalance(account: a, balance: sum, rowsCounted: n, lastRowDate: last));
  }
  return out;
}

/// The attribution [checkBankBalance] and [balanceTrusted] use: every account of [accounts] (or [a] alone), with [a]
/// taken as live (a check on a deleted account still counts its rows).
RowAccounts _ownersFor(Account a, List<Account>? accounts) => RowAccounts([
      for (final x in accounts ?? const <Account>[])
        if (x.id != a.id) x,
      if (a.deleted) Account.fromRow({...a.row, 'deleted': 0}) else a,
    ]);

/// [b]'s balance in the wallet currency of [st] (UX-A): itself when the account is in it, else at the owner's rate
/// (`homeAmount`: each currency's own minor digits; a crypto account's coins at the hand-set rate), else (UX-FX) at the
/// ECB rate of the balance's date (its last counted row, or the opening date: dates `fxNeeds` asks for); null without
/// a rate.
int? balanceInHome(AccountBalance b, WalletSettings st) =>
    homeAmount(Tx(id: '', source: '', date: b.lastRowDate ?? b.account.openingDate, amount: b.balance, currency: b.account.currency), st);

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
/// account that counts its (source, currency) (not one with [AccountBalance.duplicateOf]). UX-ACC: pass every account
/// as [accounts] (`WalletRepo.accounts()`), so rows another account of the same bank claims ([RowAccounts]) are left
/// out; without it [a] counts every row of its source and currency (the rule before UX-ACC). Exact cents; never writes.
BalanceCheck checkBankBalance(Account a, List<Tx> rows, {required String date, required int bankCents, List<Account>? accounts}) {
  final owners = _ownersFor(a, accounts);
  var sum = a.opening, n = 0;
  for (final r in rows) {
    if (!_counts(a, r, owners) || r.date.compareTo(date) > 0) continue;
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
/// off now, or dated before the opening, never counts. A date after [today] counts as recent. [accounts]: as in
/// [checkBankBalance].
bool balanceTrusted(Account a, {required String today, BankCheck? last, required List<Tx> rows, List<Account>? accounts}) {
  bool recent(String d) => isIsoDate(d) && isIsoDate(today) && daysBetween(d, today) <= bankCheckTrustDays;
  if (recent(a.openingDate)) return true;
  if (last == null || !recent(last.date) || last.date.compareTo(a.openingDate) < 0) return false;
  return checkBankBalance(a, rows, date: last.date, bankCents: last.bankCents, accounts: accounts).matches;
}

// ---------- export accounts (UX-ACC) ----------

/// The HKDF info of the key [accountMatchKey] uses (`deriveKey`).
const accountMatchKeyInfo = 'bw-account-match-v1';

final _matchKeyShape = RegExp(r'^ak:[0-9a-f]{16}$');

/// Whether [s] has the shape of an [accountMatchKey] result (`ak:` + 16 lower-case hex).
bool isAccountMatchKey(String s) => _matchKeyShape.hasMatch(s);

/// [exportAccount] (an IBAN or product name as the export names it) in the form [accountMatchKey] hashes: upper case,
/// spaces and dashes removed.
String normalizeExportAccount(String exportAccount) => exportAccount.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

/// The keyed fingerprint of the export account [exportAccount] ([Account.matchKey], the `accountKey` of an import
/// batch's rows): `ak:` + the first 16 hex of HMAC-SHA256 of [normalizeExportAccount] with
/// `deriveKey(key, accountMatchKeyInfo)`. Keyed by the wallet key, so a database or backup without the key does not
/// reveal the IBAN through a word list. Never logged; the IBAN itself is never stored. A blank account: [ArgumentError].
Future<String> accountMatchKey(VaultKey key, String exportAccount) async =>
    _matchKeyWith(await deriveKey(key, accountMatchKeyInfo), exportAccount);

Future<String> _matchKeyWith(List<int> k, String exportAccount) async {
  final n = normalizeExportAccount(exportAccount);
  if (n.isEmpty) throw ArgumentError('No account name.');
  final mac = await Hmac.sha256().calculateMac(utf8.encode(n), secretKey: SecretKey(k));
  return 'ak:${mac.bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// [batch] with every row that names its account (`NormalizedTransaction.account`) given its
/// `NormalizedTransaction.accountKey` ([accountMatchKey], the key derived once). What the app passes to
/// `WalletRepo.unknownImportAccounts` and `importBatch`. Rows without an account are kept as they are.
Future<ImportBatch> withAccountKeys(VaultKey key, ImportBatch batch) async {
  if (!batch.transactions.any((t) => t.account != null && normalizeExportAccount(t.account!).isNotEmpty)) return batch;
  final k = await deriveKey(key, accountMatchKeyInfo);
  final keys = <String, String>{};
  for (final t in batch.transactions) {
    final a = t.account;
    if (a == null || keys.containsKey(a) || normalizeExportAccount(a).isEmpty) continue;
    keys[a] = await _matchKeyWith(k, a);
  }
  return batch.withRows([
    for (final t in batch.transactions)
      if (keys[t.account] case final ak?) t.withAccountKey(ak) else t
  ]);
}

/// An export account of an import batch that no live account of its bank and currency claims yet
/// (`WalletRepo.unknownImportAccounts`): the app asks once "Which account is this?" and then sets [accountKey] as the
/// chosen account's [Account.matchKey] (`updateAccount(matchKey:)`) or adds a new account with it
/// (`addAccount(matchKey:)`). Until then its rows count for the main account ([RowAccounts]).
class ImportAccountQuestion {
  final String source;
  final String currency;
  final String accountKey;

  /// The account as the file names it (an IBAN or product name), for the question only: in memory, never stored or
  /// logged. The first spelling met in the file.
  final String exportAccount;

  /// How many of the batch's rows name it.
  final int rows;

  /// The live accounts of [source] and [currency] that count rows (by name, then id): where its rows could go. Empty
  /// when the wallet has no account for that bank and currency yet.
  final List<Account> candidates;

  const ImportAccountQuestion(
      {required this.source,
      required this.currency,
      required this.accountKey,
      required this.exportAccount,
      required this.rows,
      required this.candidates});
}
