// Accounts and plan suggestions in the controller (N2, core API in docs/context/N2_SPEC.md). A `part` of controller.dart so it can
// use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never names, amounts or ids.
part of 'controller.dart';

final _accLog = Logger('bw.accounts');

extension AccountsDb on WalletController {
  /// The live accounts, ordered by name.
  List<Account> accountsAll() => _cached(const MemoKey('accounts'), () => repo.accounts());

  /// A balance per live account (opening + the rows after it), a sync duplicate marked `duplicateOf`. Cached per data version.
  List<AccountBalance> accountBalanceList() =>
      _cached(const MemoKey('accountBalances'), () => accountBalances(accountsAll(), [for (final t in wholeTxs) t.tx]));

  /// What is held, per currency (never mixed; sync duplicates left out). Empty when there are no accounts.
  Map<String, int> heldTotals() => _cached(const MemoKey('heldTotals'), () => balanceTotals(accountBalanceList()));

  /// Adds an account and returns its id. [kind] and [institution] as in core's `addAccount`. A refused value is an [ArgumentError]
  /// with a readable message.
  Future<String> addAccount(
      {required String name,
      String? source,
      required String currency,
      required int opening,
      required String openingDate,
      AccountKind? kind,
      String? institution,
      String? matchKey}) async {
    final id = await repo.addAccount(
        name: name,
        source: source,
        currency: currency,
        opening: opening,
        openingDate: openingDate,
        kind: kind,
        institution: institution,
        matchKey: matchKey);
    logEvent(_accLog, Level.INFO, 'accounts.add', {'cash': source == null, 'kind': (kind ?? AccountKind.cash).name});
    _changed();
    return id;
  }

  /// Changes the given fields of an account (core's `updateAccount`: null = unchanged, a blank [institution] clears it,
  /// [clearSource] drops the import format). An [ArgumentError] carries core's text.
  Future<void> updateAccount(String id,
      {String? name,
      int? opening,
      String? openingDate,
      AccountKind? kind,
      String? institution,
      String? source,
      bool clearSource = false,
      String? matchKey}) async {
    await repo.updateAccount(id,
        matchKey: matchKey,
        name: name,
        opening: opening,
        openingDate: openingDate,
        kind: kind,
        institution: institution,
        source: source,
        clearSource: clearSource);
    logEvent(_accLog, Level.INFO, 'accounts.update', {'kind': kind?.name});
    _changed();
  }

  /// The owner moves bank row [txId] to account [accountId] (UX-ACC; null = back to the main account of its bank and currency).
  /// An [ArgumentError] carries core's text (a hand-added row, another bank or currency).
  void setTxAccount(String txId, String? accountId) {
    repo.setTxAccount(txId, accountId);
    logEvent(_accLog, Level.INFO, 'accounts.moveRow', {'toMain': accountId == null});
    _changed();
  }

  /// The live accounts a bank row of [t] could belong to: same bank and currency, counting rows. Empty for a hand-added row. Only
  /// worth offering when there are two or more.
  List<Account> accountsForRow(Tx t) {
    if (t.manual) return const [];
    return [
      for (final a in accountsAll())
        if (!a.isCash && a.countsRows && a.source == t.source && a.currency == t.currency) a
    ];
  }

  /// UX-ACC: the accounts that could take the rows of the export account [q] asks about: its bank and currency, counting rows, and not
  /// already claiming another export account (a claim would be lost), read now (an earlier answer of the same file counts). The one
  /// without a key (the main account) first. Empty when there is none: the owner makes a new account.
  List<Account> freeAccountsFor(ImportAccountQuestion q) => [
        for (final a in accountsAll())
          if (!a.isCash && a.countsRows && a.source == q.source && a.currency == q.currency && a.matchKey == null) a
      ]..sort((a, b) => a.id.compareTo(b.id));

  /// The account that counts bank row [t] now (core's `RowAccounts`), or null (none).
  Account? accountOfRow(Tx t) {
    final id = RowAccounts(accountsAll()).accountOf(t);
    return id == null ? null : accountsAll().where((a) => a.id == id).firstOrNull;
  }

  /// [b]'s balance in the wallet currency (core's `balanceInHome`: itself when the account is in it, else at the owner's rate), or
  /// null when there is no rate.
  int? accountHomeValue(AccountBalance b) => balanceInHome(b, settings);

  /// Where the rate behind [accountHomeValue] comes from: "your rate" (a hand-set one counts the whole balance) or the newest ECB day
  /// used ("ECB 31 Oct"); null when none is needed or none exists.
  String? accountRateSource(AccountBalance b) {
    final a = b.account;
    final at = Tx(id: '', source: '', date: b.lastRowDate ?? a.openingDate, amount: b.balance, currency: a.currency);
    return fxSourceOf(at);
  }

  // ---------- currencies ----------

  /// The currency codes in use other than the wallet's (payments, accounts, rates), most used first, at most five. Cached per data version.
  List<String> recentCurrencies() => _cached(const MemoKey('recentCurrencies'), () {
        final n = <String, int>{};
        for (final t in wholeTxs) {
          n[t.tx.currency] = (n[t.tx.currency] ?? 0) + 1;
        }
        for (final a in accountsAll()) {
          n[a.currency] = (n[a.currency] ?? 0) + 1;
        }
        for (final c in settings.fxRates.keys) {
          n[c] = (n[c] ?? 0) + 1;
        }
        n.remove(currency);
        final codes = n.keys.toList()..sort((x, y) => n[y]! != n[x]! ? n[y]!.compareTo(n[x]!) : x.compareTo(y));
        return codes.take(5).toList();
      });

  /// How many live payments are in [code] (for "Your N payments in EUR keep their currency"). Cached per data version.
  int paymentCountIn(String code) =>
      _cached(MemoKey('paymentsIn', code), () => wholeTxs.where((t) => t.tx.live && t.tx.currency == code).length);

  /// Makes [code] the wallet currency (core's `setWalletCurrency`: existing payments keep their own currency). An [ArgumentError]
  /// carries core's text.
  void setWalletCurrency(String code) {
    repo.setWalletCurrency(code);
    logEvent(_accLog, Level.INFO, 'accounts.walletCurrency');
    _changed();
  }

  /// The currency X to offer as the wallet currency ("Most payments are in X."): core's `prevalentCurrency`, unless the owner
  /// already said no to X on this device. Null when there is nothing to offer. Nothing is written here.
  String? walletCurrencyOffer() {
    final x = prevalentCurrency([for (final t in wholeTxs) t.tx], currency);
    if (x == null || repo.localValue('currencyOfferNo') == x) return null;
    return x;
  }

  /// "Not now" to the offer of [code]: it is not offered again (device-local).
  void dismissWalletCurrencyOffer(String code) {
    repo.setLocalValue('currencyOfferNo', code);
    logEvent(_accLog, Level.INFO, 'accounts.currencyOffer.dismissed');
  }

  Future<void> renameAccount(String id, String name) async {
    await repo.updateAccount(id, name: name);
    logEvent(_accLog, Level.INFO, 'accounts.rename');
    _changed();
  }

  /// "The real balance on [date] is [balance]": the account counts rows after [date] from there.
  Future<void> correctAccountBalance(String id, {required int balance, required String date}) async {
    await repo.correctBalance(id, balance: balance, date: date);
    logEvent(_accLog, Level.INFO, 'accounts.correct');
    _changed();
  }

  Future<void> deleteAccount(String id) async {
    await repo.deleteAccount(id);
    logEvent(_accLog, Level.INFO, 'accounts.delete');
    _changed();
  }

  /// Undo of [deleteAccount]; an [ArgumentError] when another live account took its place meanwhile.
  Future<void> undeleteAccount(String id) async {
    await repo.undeleteAccount(id);
    logEvent(_accLog, Level.INFO, 'accounts.undelete');
    _changed();
  }

  // ---------- plan suggestions from the imports ----------
  // Device-local value `planNotNow:<key>` = the suggested value the owner pressed "Not now" on; the proposal stays hidden until the
  // suggestion changes. Nothing is written to the settings without a tap.

  /// Plan values read from the imports and the confirmed bills (home currency only). Cached per data version and day.
  PlanSuggestion planSuggestion() => _cached(const MemoKey('planSuggestion'), () {
        final confirmed = [
          for (final b in expectedBills())
            if (b.confirmed) b
        ];
        return suggestPlan(txs, settings, today(), confirmed: confirmed, table: categoryTable);
      });

  /// The suggestions that differ from the plan and were not put off with "Not now" at their current value.
  List<SettingProposal> planProposalList() => [
        for (final p in planProposals(planSuggestion(), settings))
          if (repo.localValue('planNotNow:${p.key}') != '${p.suggested}') p,
      ];

  /// Accepts the proposals in [only] (by key), or all of them: one `updateSettings` with exactly those keys (a salary also
  /// confirms the salary, as saving the plan does). Returns how many were written.
  int acceptPlanProposals({Set<String>? only}) {
    final changes = <String, Object?>{};
    final lines = <String, int?>{}; // `plan:<id>` proposals go to setPlanLine, updateSettings refuses them
    var n = 0;
    for (final p in planProposalList()) {
      if (only != null && !only.contains(p.key)) continue;
      if (p.key.startsWith(WalletSettings.planPrefix)) {
        lines[p.key.substring(WalletSettings.planPrefix.length)] = p.suggested;
      } else {
        changes[p.key] = p.suggested;
      }
      n++;
      if (p.key == 'salary') changes['salaryConfirmed'] = true;
    }
    if (n == 0) return 0;
    logEvent(_accLog, Level.INFO, 'plan.suggestion.accept', {
      'keys': [...changes.keys.where((k) => k != 'salaryConfirmed'), if (lines.isNotEmpty) 'planLines:${lines.length}'].join(',')
    });
    if (lines.isNotEmpty) savePlanLines(lines);
    if (changes.isNotEmpty) updateSettings(changes);
    return n;
  }

  /// "Not now": hides this proposal until its suggested value changes.
  void putOffPlanProposal(String key) {
    final p = planProposalList().where((x) => x.key == key).firstOrNull;
    if (p == null) return;
    repo.setLocalValue('planNotNow:$key', '${p.suggested}');
    logEvent(_accLog, Level.INFO, 'plan.suggestion.later', {'key': key.startsWith(WalletSettings.planPrefix) ? 'planLine' : key});
    _refreshView();
  }

  // ---------- first import (P13 §4) ----------

  /// True when the "Looks right?" sheet should show after an import: the wallet has proposals and has never been offered them
  /// (device-local `planSuggestShown`), and the setup wizard (step 3 offers the same) is not under way on this device (done and step 3 mark it shown themselves). Nothing is written here.
  bool shouldOfferFirstPlan() => repo.localValue('planSuggestShown') != '1' && !setupWizardOpen && planProposalList().isNotEmpty;

  /// Marks the first-import sheet as shown (once per wallet on this device, whatever the owner answers).
  void markFirstPlanShown() {
    if (repo.localValue('planSuggestShown') == '1') return;
    repo.setLocalValue('planSuggestShown', '1');
    logEvent(_accLog, Level.INFO, 'plan.suggestion.firstShown', {'count': planProposalList().length});
  }
}
