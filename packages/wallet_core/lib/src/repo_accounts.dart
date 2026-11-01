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
  /// second account with this ([source], [currency]); their rows would count twice. An account that counts no rows
  /// (investment, crypto, other, or a bank account without a source) never clashes.
  void _checkUnique(String? source, String currency, {String? exceptId, AccountKind? kind}) {
    final k = kind ?? (source == null ? AccountKind.cash : AccountKind.bank);
    if (k != AccountKind.cash && source == null) return;
    final clash = accounts().any((a) =>
        a.id != exceptId && a.currency == currency && a.countsRows && (k == AccountKind.cash ? a.isCash : !a.isCash && a.source == source));
    if (clash) {
      throw ArgumentError(k == AccountKind.cash
          ? 'There is already a cash account in $currency.'
          : 'There is already an account for this bank in $currency.');
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
  Future<String> addAccount(
      {required String name,
      String? source,
      required String currency,
      required int opening,
      required String openingDate,
      AccountKind? kind,
      String? institution}) async {
    final n = _checkName(name);
    if (!_currency.hasMatch(currency)) throw ArgumentError('Bad currency (three capital letters, like EUR).');
    final k = kind ?? (source == null ? AccountKind.cash : AccountKind.bank);
    _checkShape(k, source, currency);
    final inst = _checkInstitution(institution);
    _checkAmount(opening);
    _checkDate(openingDate);
    _checkUnique(source, currency, kind: k);
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
  /// write.
  Future<void> updateAccount(String id,
      {String? name,
      int? opening,
      String? openingDate,
      AccountKind? kind,
      String? institution,
      String? source,
      bool clearSource = false}) async {
    final stored = Account.fromRow(_accountRow(id));
    final n = name == null ? null : _checkName(name);
    if (opening != null) _checkAmount(opening);
    if (openingDate != null) _checkDate(openingDate);
    final k = kind ?? stored.kind;
    final src = clearSource ? null : source ?? stored.source;
    final inst = institution == null ? stored.institution : _checkInstitution(institution);
    if (k != stored.kind || src != stored.source) {
      _checkShape(k, src, stored.currency);
      if (!stored.deleted) _checkUnique(src, stored.currency, exceptId: id, kind: k);
    }
    final pair = opening != null || openingDate != null;
    final fields = {
      if (n != null && n != stored.name) 'name': n,
      if (pair) 'opening': opening ?? stored.opening,
      if (pair) 'opening_date': openingDate ?? stored.openingDate,
      // The kind is written whenever the source changes too: a row from before schema 20 derives it from the source.
      if (k != stored.kind || src != stored.source) 'kind': k.name,
      if (src != stored.source) 'source': src,
      if (inst != stored.institution) 'institution': inst,
    };
    if (fields.isEmpty) return;
    _write([('account', id, fields)]);
    logEvent(_log, Level.INFO, 'account.update', {'fields': fields.length});
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
    _checkUnique(a.source, a.currency, exceptId: id, kind: a.kind);
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

  /// After an import (owner's choice: automatic, from the bank file): for each balance the file states
  /// ([ImportBatch.bankBalances]), the live bank account counting its (source, currency) (the smallest id, as in
  /// `accountBalances`) gets a check against its rows ([checkBankBalance]), recorded unless this device already holds a
  /// check of a later date. Returns them by account id. No check (better none than a wrong "off by"):
  /// - for a balance beyond ±[maxAmountCents] or without a real date;
  /// - for a balance dated before the account's opening date (the opening is the anchor);
  /// - when the account's stored rows dated within the file's dates (for that currency) are not all rows of [batch]:
  ///   the app account then also holds another bank account or pocket of the same source and currency (two PBZ
  ///   IBANs, a Revolut Savings pocket in its own file), whose rows the file's balance does not include.
  Map<String, BalanceCheck> _recordBankChecks(ImportBatch batch) {
    final balances = batch.bankBalances;
    if (balances.isEmpty) return const {};
    final live = accounts();
    final out = <String, BalanceCheck>{};
    for (final b in balances) {
      if (!isSafeCents(b.cents) || !isIsoDate(b.date)) continue;
      Account? a;
      for (final x in live) {
        if (x.source == b.source && x.currency == b.currency && (a == null || x.id.compareTo(a.id) < 0)) a = x;
      }
      if (a == null || b.date.compareTo(a.openingDate) < 0) continue;
      final rows = [
        for (final r
            in db.select('SELECT * FROM tx WHERE source = ? AND currency = ? AND manual = 0 AND deleted = 0', [b.source, b.currency]))
          Tx.fromRow(r)
      ];
      final mine = [
        for (final t in batch.transactions)
          if (t.currency == b.currency) t
      ];
      final ids = {for (final t in mine) t.id};
      var from = mine.first.date, to = from;
      for (final t in mine) {
        if (t.date.compareTo(from) < 0) from = t.date;
        if (t.date.compareTo(to) > 0) to = t.date;
      }
      if (rows.any((r) => r.date.compareTo(from) >= 0 && r.date.compareTo(to) <= 0 && !ids.contains(r.id))) {
        logEvent(_log, Level.INFO, 'account.bankCheck.skipped', {'reason': 'otherRows'});
        continue;
      }
      final c = checkBankBalance(a, rows, date: b.date, bankCents: b.cents);
      out[a.id] = c;
      final have = lastBankCheck(a.id);
      if (have != null && have.date.compareTo(c.date) > 0) continue;
      if (isSafeCents(c.appCents)) recordBankCheck(a.id, date: c.date, bankCents: c.bankCents, appCents: c.appCents);
    }
    return out;
  }
}
