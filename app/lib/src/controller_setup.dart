// The "Set up my wallet" wizard in the controller (stage X). A `part` of controller.dart so it can use the cache and `_changed`.
// Progress is device-local (`setupWizard`: `pending` | `step:<n>` | `done` | `skipped`; never synced; a joined wallet has none).
// Each step reuses the controller methods of the screen it stands for; nothing here writes without a tap.
//
// Privacy: logs carry the step number and an action word only, never a payee, an account name or an amount.
part of 'controller.dart';

final _setupLog = Logger('bw.setup');

/// Steps of the wizard: import, accounts, payday plan, bills, extra income, payees, budgets, done.
const int setupWizardSteps = 8;

/// The numbers on the last wizard step ("Here's your wallet"): the same hero figure as Today.
class SetupSummary {
  /// The hero's words (as Today shows them) and its figure, never negative.
  final String label;
  final int hero;

  /// The pay period ended / today's spending is over today's money (the hero then reads differently).
  final bool ended, over;

  /// The expected next payday (`YYYY-MM-DD`) and the money held for bills this period.
  final String payday;
  final int billsHeld;

  /// The payments in the wallet and the accounts counted (a sync duplicate is left out).
  final int payments;
  final List<AccountBalance> accounts;
  const SetupSummary(
      {required this.label,
      required this.hero,
      required this.ended,
      required this.over,
      required this.payday,
      required this.billsHeld,
      required this.payments,
      required this.accounts});
}

extension SetupWizardDb on WalletController {
  String? get setupWizardState => repo.localValue('setupWizard');

  /// The wizard was started for this wallet and not finished or declined: Today shows "Finish setting up".
  bool get setupWizardOpen {
    final v = setupWizardState;
    return v == 'pending' || (v != null && v.startsWith('step:'));
  }

  /// Where the wizard resumes: the saved step, else 1.
  int get setupWizardStep {
    final v = setupWizardState;
    final n = v != null && v.startsWith('step:') ? int.tryParse(v.substring(5)) : null;
    return n == null ? 1 : n.clamp(1, setupWizardSteps);
  }

  /// A wallet was just created: the wizard opens after the save-key screen.
  void markSetupWizardPending() => repo.setLocalValue('setupWizard', 'pending');

  /// The step now shown is kept, so closing the wizard resumes there. From step 3 on the plan suggestions were offered, so the
  /// one-off "Looks right?" sheet (P13) is not needed any more.
  void saveSetupStep(int n) {
    repo.setLocalValue('setupWizard', 'step:$n');
    if (n >= 3) markFirstPlanShown();
    _keyBackupChanged();
  }

  void finishSetupWizard() {
    repo.setLocalValue('setupWizard', 'done');
    markFirstPlanShown();
    logEvent(_setupLog, Level.INFO, 'setup.finish');
    _keyBackupChanged();
  }

  /// "No thanks" on Today's line: the wizard is not offered again (Settings still has it).
  void declineSetupWizard() {
    repo.setLocalValue('setupWizard', 'skipped');
    logEvent(_setupLog, Level.INFO, 'setup.decline');
    _keyBackupChanged();
  }

  /// Counts only: the step reached and what was done (`shown`, `back`, `next`, `skip`, `accept`).
  void logSetupStep(int n, String action, {int? count}) =>
      logEvent(_setupLog, Level.INFO, 'setup.step', {'n': n, 'action': action, if (count != null) 'count': count});

  // ---------- step 2: accounts ----------

  bool get hasCashAccount => accountsAll().any((a) => a.isCash);

  /// "What does your bank app show today?" for [a].
  BankQuestion bankQuestionFor(Account a) =>
      BankQuestion(accountId: a.id, name: a.name, currency: a.currency, date: today(), appCents: appBalanceOn(a.id, today()));

  // ---------- step 6: payees without a main tag ----------

  /// The payees with the most rows nothing decides yet (top [limit]), most rows first. Cached per data version.
  List<PayeeCount> uncategorisedPayeeList({int limit = 10}) =>
      _cached(MemoKey('setup.payees', limit), () => uncategorisedPayees(repo.transactions(), categorizer, limit: limit));

  /// The main tags to offer for a payee: the ones an expense can take, most used first.
  List<String> setupMainTagIds() => [
        for (final id in recommendedMainFor(null, kinds: addExpenseKinds))
          if (!addExpenseExclude.contains(id)) id
      ];

  /// "Always put this payee in [category]": a payee rule, the rows keep their own main tag.
  void makePayeeRule(String merchantKey, String category) {
    if (!categoryTable.isLive(category)) return;
    repo.setMerchantRule(merchantKey, category);
    logEvent(_setupLog, Level.INFO, 'setup.payeeRule', {'category': _logCategory(category)});
    _changed();
  }

  /// Undo of [makePayeeRule].
  void undoPayeeRule(String merchantKey) {
    repo.removeMerchantRule(merchantKey);
    logEvent(_setupLog, Level.INFO, 'setup.payeeRule.undo');
    _changed();
  }

  // ---------- step 7: budgets ----------

  /// Current → suggested per category (6-month average of the months before this one); empty fields first.
  List<BudgetProposal> setupBudgetProposals() => budgetProposals(settings.categoryBudgets, suggestedBudgets(monthOf(today())));

  /// Writes the proposals in [only] (by category), or all: one budget row each, nothing else. Returns how many were written.
  int acceptBudgetProposals({Set<String>? only}) {
    final next = {...settings.categoryBudgets};
    var n = 0;
    for (final p in setupBudgetProposals()) {
      if (only != null && !only.contains(p.category)) continue;
      next[p.category] = p.suggested;
      n++;
    }
    if (n > 0) saveCategoryBudgets(next);
    return n;
  }

  // ---------- step 8: the summary ----------

  SetupSummary setupSummary() {
    final p = period();
    final ended = p.paydayPassed, over = p.overToday > 0;
    final hero = ended ? (p.remaining > 0 ? p.remaining : 0) : (over ? p.overToday : p.safeToday);
    final label = ended ? 'Left this pay period' : (over ? 'Over today by' : 'Safe to spend today');
    return SetupSummary(
        label: label,
        hero: hero,
        ended: ended,
        over: over,
        payday: p.end,
        billsHeld: p.reservedBills,
        payments: txs.where((t) => t.tx.live).length,
        accounts: [
          for (final b in accountBalanceList())
            if (b.duplicateOf == null) b
        ]);
  }
}
