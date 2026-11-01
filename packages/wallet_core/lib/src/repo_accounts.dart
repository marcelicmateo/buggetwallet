part of 'repo.dart';

/// The owner's accounts (N2): bank and cash accounts with an opening balance (see [Account], `accountBalances`).
extension WalletRepoAccounts on WalletRepo {
  static final _currency = RegExp(r'^[A-Z]{3}$');

  /// The trimmed [name], or an [ArgumentError] when it is empty or longer than [Account.maxName] characters.
  static String _checkName(String name) {
    final n = name.trim();
    if (n.isEmpty) throw ArgumentError('Give the account a name.');
    if (n.runes.length > Account.maxName) throw ArgumentError('The account name is limited to ${Account.maxName} characters.');
    return n;
  }

  static void _checkAmount(int cents) {
    if (cents.abs() > WalletSettings.maxAmount) throw ArgumentError('The balance is over the allowed amount.');
  }

  /// A real `YYYY-MM-DD` date, not after today (this device's local date, from the repo's clock).
  void _checkDate(String date) {
    if (!isIsoDate(date)) throw ArgumentError('Bad date.');
    if (date.compareTo(_today()) > 0) throw ArgumentError('The date cannot be in the future.');
  }

  /// Throws when another live account (not [exceptId]) counts the same rows: a second cash account in [currency], or a
  /// second account with this ([source], [currency], [matchKey]) (UX-ACC: none is one value, so one main account per
  /// bank and currency as before); their rows would count twice. An account that counts no rows (investment, crypto,
  /// other, or a bank account without a source) never clashes.
  void _checkUnique(String? source, String currency, {String? exceptId, AccountKind? kind, String? matchKey}) {
    final k = kind ?? (source == null ? AccountKind.cash : AccountKind.bank);
    if (k != AccountKind.cash && source == null) return;
    final clash = accounts().any((a) =>
        a.id != exceptId &&
        a.currency == currency &&
        a.countsRows &&
        (k == AccountKind.cash ? a.isCash : !a.isCash && a.source == source && a.matchKey == matchKey));
    if (clash) {
      throw ArgumentError(k == AccountKind.cash
          ? 'There is already a cash account in $currency.'
          : matchKey == null
              ? 'There is already an account for this bank in $currency.'
              : 'Another account already counts this bank account.');
    }
  }

  /// UX-ACC: a [matchKey] only in the shape [accountMatchKey] gives, and only on an account that imports a bank's
  /// files (a source); [ArgumentError] otherwise.
  static void _checkMatchKey(String? matchKey, String? source, AccountKind kind) {
    if (matchKey == null) return;
    if (!isAccountMatchKey(matchKey)) throw ArgumentError('Bad bank account key.');
    if (source == null || kind == AccountKind.cash) {
      throw ArgumentError('Only an account that imports bank files can match a bank account.');
    }
  }

  /// The trimmed [institution], null for none or blank; an [ArgumentError] past [Account.maxName] characters.
  static String? _checkInstitution(String? institution) {
    final t = institution?.trim();
    if (t == null || t.isEmpty) return null;
    if (t.runes.length > Account.maxName) throw ArgumentError('The institution is limited to ${Account.maxName} characters.');
    return t;
  }

  /// The shape rules of UX-A: an import [source] only for a bank, card or savings account ([AccountKind.takesSource]), a
  /// known one; a crypto account in a crypto currency ([CurrencyInfo.crypto], BTC).
  void _checkShape(AccountKind kind, String? source, String currency) {
    if (source != null && !kind.takesSource) throw ArgumentError('Only a bank, card or savings account can import bank files.');
    if (source != null && !bankProfiles.any((p) => p.id == source) && !_liveCsvSource(source)) throw ArgumentError('Unknown bank.');
    if (kind == AccountKind.crypto && !(currencyInfo(currency)?.crypto ?? false)) {
      throw ArgumentError('A crypto account holds a crypto currency, like BTC.');
    }
  }

  /// Adds an account and returns its id (`a…`). [kind] (UX-A; default: cash without a [source], bank with one) and
  /// [institution] (free text, optional). [source] is a bank profile id ([bankProfiles]) or `csv:<shapeId>` with a
  /// live saved CSV layout (P12, [WalletSettings.csvMappings]; labelled with its name, [accountSourceLabel]), for a
  /// bank, card or savings account only; [opening] is the balance (signed minor units of [currency]: satoshis for
  /// BTC) at the end of [openingDate]. A bad name, currency, kind and source, date or amount, a crypto account in
  /// another currency, or a second live account counting the same rows ([_checkUnique]), is an [ArgumentError].
  /// UX-ACC: [matchKey] (an [ImportAccountQuestion.accountKey]) makes it count that export account's rows.
  Future<String> addAccount(
      {required String name,
      String? source,
      required String currency,
      required int opening,
      required String openingDate,
      AccountKind? kind,
      String? institution,
      String? matchKey}) async {
    final n = _checkName(name);
    if (!_currency.hasMatch(currency)) throw ArgumentError('Bad currency (three capital letters, like EUR).');
    final k = kind ?? (source == null ? AccountKind.cash : AccountKind.bank);
    _checkShape(k, source, currency);
    _checkMatchKey(matchKey, source, k);
    final inst = _checkInstitution(institution);
    _checkAmount(opening);
    _checkDate(openingDate);
    _checkUnique(source, currency, kind: k, matchKey: matchKey);
    final id = _newId('a');
    _write([
      (
        'account',
        id,
        {
          'name': n,
          'source': source,
          'currency': currency,
          'opening': opening,
          'opening_date': openingDate,
          'deleted': 0,
          'kind': k.name,
          if (inst != null) 'institution': inst,
          if (matchKey != null) 'match_key': matchKey,
        }
      )
    ]);
    logEvent(_log, Level.INFO, 'account.add', {'cash': k == AccountKind.cash, 'kind': k.name});
    return id;
  }

  /// `csv:<shapeId>` whose shape has a live saved layout.
  bool _liveCsvSource(String source) =>
      source.startsWith(csvSourcePrefix) && _storedCsvMapping(source.substring(csvSourcePrefix.length)) != null;

  Map<String, Object?> _accountRow(String id) {
    final rs = db.select('SELECT * FROM accounts WHERE id = ?', [id]);
    if (rs.isEmpty) throw ArgumentError('No such account.');
    return rs.first;
  }

  /// Changes the given fields only (null = unchanged). [opening] and [openingDate] are one pair: when either is given
  /// both are written (the other from the stored row), so they always share one clock and a sync merge never pairs
  /// one device's balance with another device's date. UX-A: [kind], [institution] (blank clears it) and [source]
  /// ([clearSource] drops it), checked like [addAccount] on the result (a cash account with a source, or a crypto one
  /// in a fiat currency, is refused: change the kind and clear the source in one call). The currency never changes:
  /// delete the account and add a new one. Unknown id or a bad value: [ArgumentError], nothing written; no change: no
  /// write. A thin wrapper over [patch] (F1). UX-ACC: [matchKey] (an [ImportAccountQuestion.accountKey], the owner's
  /// answer to "Which account is this?") makes it count that export account's rows; [clearMatchKey] drops it.
  Future<void> updateAccount(String id,
      {String? name,
      int? opening,
      String? openingDate,
      AccountKind? kind,
      String? institution,
      String? source,
      bool clearSource = false,
      String? matchKey,
      bool clearMatchKey = false}) async {
    patch(AccountCols.entity, id, {
      if (name != null) AccountCols.name: name,
      if (opening != null) AccountCols.opening: opening,
      if (openingDate != null) AccountCols.openingDate: openingDate,
      if (kind != null) AccountCols.kind: kind,
      if (institution != null) AccountCols.institution: institution,
      if (clearSource) AccountCols.source: clearValue else if (source != null) AccountCols.source: source,
      if (clearMatchKey) AccountCols.matchKey: clearValue else if (matchKey != null) AccountCols.matchKey: matchKey,
    });
  }

  /// "The real balance is [balance] on [date]": the opening becomes that balance at the end of [date], so only rows
  /// after it are added. Unknown id or a bad value: [ArgumentError].
  Future<void> correctBalance(String id, {required int balance, required String date}) async {
    _accountRow(id);
    _checkAmount(balance);
    _checkDate(date);
    _write([
      ('account', id, {'opening': balance, 'opening_date': date})
    ]);
    logEvent(_log, Level.INFO, 'account.correct');
  }

  /// Removes it (`deleted: 1`; the row stays for [undeleteAccount]). Unknown id: [ArgumentError].
  Future<void> deleteAccount(String id) async {
    if (_accountRow(id)['deleted'] == 1) return;
    _write([
      ('account', id, {'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'account.delete');
  }

  /// Undo of [deleteAccount]: writes `deleted: 0` (synced; the later write by HLC wins, like `undeleteGoal`). A live
  /// account: nothing is written. Unknown id, or another live account with the same (source, currency) added in
  /// between: [ArgumentError].
  Future<void> undeleteAccount(String id) async {
    final r = _accountRow(id);
    if (r['deleted'] == 0) return;
    final a = Account.fromRow(r);
    _checkUnique(a.source, a.currency, exceptId: id, kind: a.kind, matchKey: a.matchKey);
    _write([
      ('account', id, {'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'repo.undelete', {'entity': 'account'});
  }

  /// The accounts, ordered by name, then id; deleted ones only with [includeDeleted].
  List<Account> accounts({bool includeDeleted = false}) => [
        for (final r in db.select('SELECT * FROM accounts${includeDeleted ? '' : ' WHERE deleted = 0'} ORDER BY name, id'))
          Account.fromRow(r),
      ];

  // ---------- bank balance checks (Q5) ----------
  static String _checkKey(String accountId) => 'bankCheck:$accountId';

  /// Stores a balance check for [accountId] on this device only (`setLocalValue('bankCheck:<id>')`: never synced, no
  /// schema change), replacing the last one. It never changes the balance: correcting is the owner's tap on
  /// [correctBalance]. Unknown account, a bad date or an amount beyond ±[maxAmountCents]: [ArgumentError].
  void recordBankCheck(String accountId, {required String date, required int bankCents, required int appCents}) {
    _accountRow(accountId);
    if (!isIsoDate(date)) throw ArgumentError('Bad date.');
    if (!isSafeCents(bankCents) || !isSafeCents(appCents)) throw ArgumentError('The balance is over the allowed amount.');
    setLocalValue(_checkKey(accountId), jsonEncode(BankCheck(date: date, bankCents: bankCents, appCents: appCents).toJson()));
    logEvent(_log, Level.INFO, 'account.bankCheck', {'result': bankCents == appCents ? 'match' : 'off'});
  }

  /// The last check stored for [accountId] on this device ([recordBankCheck]), or null (none, or a damaged value).
  BankCheck? lastBankCheck(String accountId) {
    final v = localValue(_checkKey(accountId));
    if (v == null) return null;
    try {
      return BankCheck.fromJson(jsonDecode(v));
    } on FormatException catch (e, st) {
      logError(_log, 'account.bankCheck.invalid', e, st, level: Level.FINE);
      return null;
    }
  }

  /// The last checks of [accountIds] (those with one), for `balanceWarnings`.
  Map<String, BankCheck> lastBankChecks(Iterable<String> accountIds) => {
        for (final id in accountIds)
          if (lastBankCheck(id) case final BankCheck c) id: c
      };

  /// After an import (owner's choice: automatic, from the bank file): for each balance the file states, per export
  /// account (UX-ACC: the batch's rows grouped by `accountKey`, each group's [ImportBatch.bankBalances]), the app
  /// account its rows count for gets a check against its rows ([checkBankBalance]): the live account whose
  /// [Account.matchKey] is that key, else the main account of the (source, currency) ([RowAccounts]). Recorded unless
  /// this device already holds a check of a later date. Returns them by account id. No check (better none than a wrong
  /// "off by"):
  /// - for a balance beyond ±[maxAmountCents] or without a real date;
  /// - for a balance dated before the account's opening date (the opening is the anchor);
  /// - for rows that fall to a main account, when the rows it counts dated within the file's dates (for that currency)
  ///   are not all rows of the group: the main account then also holds another bank account or pocket of the same
  ///   source and currency (two PBZ IBANs, a Revolut Savings pocket in its own file), whose rows the file's balance does
  ///   not include. A keyed account counts only its own export account's rows, so it is never skipped for this.
  Map<String, BalanceCheck> _recordBankChecks(ImportBatch batch) {
    if (!batch.transactions.any((t) => t.balanceAfter != null)) return const {};
    final groups = <String?, List<NormalizedTransaction>>{};
    for (final t in batch.transactions) {
      (groups[t.accountKey] ??= []).add(t);
    }
    final live = accounts();
    final owners = RowAccounts(live);
    final byId = {for (final a in live) a.id: a};
    final out = <String, BalanceCheck>{};
    for (final MapEntry(key: key, value: group) in groups.entries) {
      for (final b in batch.withRows(group).bankBalances) {
        if (!isSafeCents(b.cents) || !isIsoDate(b.date)) continue;
        final keyed = key == null ? null : owners.keyedOf(b.source, b.currency, key);
        final a = byId[keyed ?? owners.mainOf(b.source, b.currency)];
        if (a == null || b.date.compareTo(a.openingDate) < 0) continue;
        final rows = [
          for (final r
              in db.select('SELECT * FROM tx WHERE source = ? AND currency = ? AND manual = 0 AND deleted = 0', [b.source, b.currency]))
            Tx.fromRow(r)
        ];
        if (keyed == null) {
          final mine = [
            for (final t in group)
              if (t.currency == b.currency) t
          ];
          final ids = {for (final t in mine) t.id};
          var from = mine.first.date, to = from;
          for (final t in mine) {
            if (t.date.compareTo(from) < 0) from = t.date;
            if (t.date.compareTo(to) > 0) to = t.date;
          }
          if (rows
              .any((r) => r.date.compareTo(from) >= 0 && r.date.compareTo(to) <= 0 && !ids.contains(r.id) && owners.accountOf(r) == a.id)) {
            logEvent(_log, Level.INFO, 'account.bankCheck.skipped', {'reason': 'otherRows'});
            continue;
          }
        }
        final c = checkBankBalance(a, rows, date: b.date, bankCents: b.cents, accounts: live);
        out[a.id] = c;
        final have = lastBankCheck(a.id);
        if (have != null && have.date.compareTo(c.date) > 0) continue;
        if (isSafeCents(c.appCents)) recordBankCheck(a.id, date: c.date, bankCents: c.bankCents, appCents: c.appCents);
      }
    }
    return out;
  }

  // ---------- export accounts (UX-ACC) ----------

  /// The export accounts of [batch] (rows with an `accountKey`, `withAccountKeys`) that no live account of their
  /// source and currency claims yet ([Account.matchKey]): what the app asks once, "Which account is this?", before (or
  /// after) [importBatch]. The answer is the owner's write: `updateAccount(id, matchKey: q.accountKey)` (an existing
  /// account, e.g. the main one) or `addAccount(..., matchKey: q.accountKey)` (a new one); later files of that export
  /// account then match without a question, and a re-import assigns rows imported before the answer (importBatch fills
  /// a null [Tx.account]). Until answered, its rows count for the main account. Rows without a key are never asked
  /// about. In batch order of first appearance; never writes, never logs the accounts.
  List<ImportAccountQuestion> unknownImportAccounts(ImportBatch batch) {
    final live = accounts();
    final owners = RowAccounts(live);
    final seen = <(String, String, String), (String, int)>{};
    for (final t in batch.transactions) {
      final k = t.accountKey;
      if (k == null || owners.keyedOf(t.source, t.currency, k) != null) continue;
      final have = seen[(t.source, t.currency, k)];
      seen[(t.source, t.currency, k)] = (have?.$1 ?? t.account ?? '', (have?.$2 ?? 0) + 1);
    }
    return [
      for (final MapEntry(key: (source, currency, key), value: (name, n)) in seen.entries)
        ImportAccountQuestion(
          source: source,
          currency: currency,
          accountKey: key,
          exportAccount: name,
          rows: n,
          candidates: [
            for (final a in live)
              if (!a.isCash && a.countsRows && a.source == source && a.currency == currency) a
          ],
        )
    ];
  }

  /// The owner moves bank row [txId] to account [accountId] (UX-ACC, fixing a wrong guess), or back to the rule
  /// (null: the main account of its source and currency). The account must be live, count rows and have the row's
  /// source and currency; a hand-added row, an unknown row or account: [ArgumentError], nothing written. No change: no
  /// write. One synced owner write (`tx.account`).
  void setTxAccount(String txId, String? accountId) {
    final rs = db.select('SELECT * FROM tx WHERE id = ?', [txId]);
    if (rs.isEmpty) throw ArgumentError('No such payment.');
    final t = Tx.fromRow(rs.first);
    if (t.manual) throw ArgumentError('Only a bank row belongs to a bank account.');
    if (accountId != null) {
      final a = Account.fromRow(_accountRow(accountId));
      if (a.deleted || a.isCash || !a.countsRows || a.source != t.source || a.currency != t.currency) {
        throw ArgumentError('That account does not hold rows of this bank in ${t.currency}.');
      }
    }
    if (t.account == accountId) return;
    _write([
      ('tx', txId, {TxCols.account.column: accountId})
    ]);
    logEvent(_log, Level.INFO, 'tx.account', {'set': accountId != null});
  }
}
