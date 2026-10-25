// Accounts and plan suggestions in the controller (N2, core API in docs/context/N2_SPEC.md). A `part` of controller.dart so it can
// use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never names, amounts or ids.
part of 'controller.dart';

final _accLog = Logger('bw.accounts');

extension AccountsDb on WalletController {
  /// The live accounts, ordered by name.
  List<Account> accountsAll() => _cached('accounts', () => repo.accounts());

  /// A balance per live account (opening + the rows after it), a sync duplicate marked `duplicateOf`. Cached per data version.
  List<AccountBalance> accountBalanceList() =>
      _cached('accountBalances', () => accountBalances(accountsAll(), [for (final t in wholeTxs) t.tx]));

  /// What is held, per currency (never mixed; sync duplicates left out). Empty when there are no accounts.
  Map<String, int> heldTotals() => _cached('heldTotals', () => balanceTotals(accountBalanceList()));

  /// Adds an account and returns its id. A refused value is an [ArgumentError] with a readable message.
  Future<String> addAccount(
      {required String name, String? source, required String currency, required int opening, required String openingDate}) async {
    final id = await repo.addAccount(name: name, source: source, currency: currency, opening: opening, openingDate: openingDate);
    logEvent(_accLog, Level.INFO, 'accounts.add', {'cash': source == null});
    _changed();
    return id;
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
  PlanSuggestion planSuggestion() => _cached('planSuggestion', () {
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
}
