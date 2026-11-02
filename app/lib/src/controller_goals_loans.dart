// Big purchases from saving to a loan to paid off (ENG E6, docs/context/ENG_UI_SPEC.md §5.5): the goal planner's draft, the buy step and
// the loan screen's numbers. Core (`goal_plan.dart`, `loans.dart`, `repo_loans.dart`) does every sum and refuses bad input with a readable
// [ArgumentError]; this reads, caches and logs. A `part` of controller.dart so it can use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never names, lenders or amounts.
part of 'controller.dart';

/// The planner's inputs while the owner moves a slider; written to the goal only on [GoalsLoans.saveGoalDraft].
class GoalDraft {
  int price, monthly, depositPermille, costsPermille;
  int? rateBp, months;
  String? compareId;
  GoalDraft(
      {required this.price,
      required this.monthly,
      required this.depositPermille,
      required this.costsPermille,
      this.rateBp,
      this.months,
      this.compareId});

  /// The draft of [g]: a goal paid in full has 1000 ‰ deposit; a missing loan length starts at 5 years.
  factory GoalDraft.of(Goal g) => GoalDraft(
      price: g.price ?? g.target,
      monthly: g.monthly,
      depositPermille: g.depositPermille ?? 1000,
      costsPermille: g.costsPermille ?? 0,
      rateBp: g.loanRateBp,
      months: g.loanMonths ?? 60,
      compareId: g.compareLineId);

  GoalDraft copy() => GoalDraft(
      price: price,
      monthly: monthly,
      depositPermille: depositPermille,
      costsPermille: costsPermille,
      rateBp: rateBp,
      months: months,
      compareId: compareId);

  /// [g] with this draft's planner fields (for `goalPlan`).
  Goal on(Goal g) => Goal(
      id: g.id,
      name: g.name,
      target: g.target,
      saved: g.saved,
      monthly: monthly,
      sort: g.sort,
      price: price,
      depositPermille: depositPermille,
      costsPermille: costsPermille,
      loanRateBp: rateBp,
      loanMonths: months,
      compareLineId: compareId,
      boughtAt: g.boughtAt,
      loanId: g.loanId);
}

/// One loan with everything the Loan screen shows, all from core: the [schedule], the bank rows that paid it ([payments]) and its
/// [state] against them.
class LoanView {
  final Loan loan;
  final List<LoanRate> rates;
  final List<LoanCheck> checks;
  final List<LoanMonth> schedule;
  final List<LoanPaymentMatch> payments;
  final LoanState state;
  const LoanView(this.loan, this.rates, this.checks, this.schedule, this.payments, this.state);
}

/// One year of a loan's schedule for the chart: what was paid as [principal] and [interest], and the balance at its end.
class LoanYear {
  final int year, principal, interest, endBalance;
  const LoanYear(this.year, this.principal, this.interest, this.endBalance);
}

/// A balance the lender showed against the schedule: [expected] is the schedule's balance on that date, [off] = shown − expected.
class LoanCheckResult {
  final int expected, off;
  const LoanCheckResult(this.expected, this.off);
  bool get matches => off == 0;
}

/// `YYYY-MM` of [ym] plus [n] months (core's `addMonths` is not exported).
String monthPlus(String ym, int n) {
  final k = int.parse(ym.substring(0, 4)) * 12 + int.parse(ym.substring(5, 7)) - 1 + n;
  return '${k ~/ 12}-${(k % 12 + 1).toString().padLeft(2, '0')}';
}

/// The shortest loan reference core matches by (`loanReferenceMinLength`, not exported).
const loanReferenceMin = 4;

extension GoalsLoans on WalletController {
  Goal? goalOf(String id) => goals.where((g) => g.id == id).firstOrNull;

  /// The plan lines a loan payment can be compared with: (id, label, cents), only those with an amount.
  List<(String, String, int)> compareChoices() {
    final s = effectiveSettings;
    return [
      if (s.rent > 0) ('rent', 'Rent', s.rent),
      if (s.loan > 0) ('loan', 'Loan', s.loan),
      if (s.subs > 0) ('subs', 'Bills & subscriptions', s.subs),
      for (final id in categoryTable.planLineIds)
        if ((s.planLines[id] ?? 0) > 0) ('plan:$id', categoryTable.label(id), s.planLines[id]!),
      for (final e in s.loanLines.entries)
        if (e.value > 0) ('loanrow:${e.key}', repo.loans().where((l) => l.id == e.key).firstOrNull?.name ?? 'Loan', e.value),
    ];
  }

  /// What the compared line costs now (null: none picked, or it is gone).
  int? compareCents(String? id) => id == null ? null : compareChoices().where((c) => c.$1 == id).firstOrNull?.$3;

  /// The planner numbers of [g] with the draft [d] (core's `goalPlan`).
  GoalPlan planFor(Goal g, GoalDraft d) => goalPlan(d.on(g),
      savedCents: g.saved,
      monthlyCents: d.monthly,
      compareCents: compareCents(d.compareId),
      toSpendPerPeriodCents: period().flexBudget,
      today: today());

  /// The "Get there sooner" chips for [plan] (core's `goalLevers`), cached per plan.
  List<GoalLever> leversFor(String goalId, GoalPlan plan) => _cached(
      MemoKey('goalLevers', '$goalId|${plan.left}|${plan.monthly}|${plan.months}'),
      () => goalLevers(rawExpanded, effectiveSettings, categoryTable, today(), plan: plan, incomes: recurringBills()));

  /// The words for a lever's source: a main tag's name, or the recurring income's label.
  String leverLabel(GoalLever l) => l.kind == GoalLeverKind.tag
      ? categoryTable.label(l.key)
      : recurringBills().where((b) => b.id == l.key).firstOrNull?.label ?? 'Side income';

  /// The plan with the chosen [levers]' cuts added to the monthly amount: months and ready month "if you did these".
  GoalPlan planWithLevers(Goal g, GoalDraft d, Iterable<GoalLever> levers) {
    final e = d.copy()..monthly = d.monthly + levers.fold<int>(0, (a, l) => a + l.cut);
    return planFor(g, e);
  }

  /// The goal is ready: it has a price, nothing is left to save and it is not bought yet.
  bool goalReady(Goal g) {
    if (g.price == null || g.boughtAt != null) return false;
    final p = planFor(g, GoalDraft.of(g));
    return p.need > 0 && p.left == 0;
  }

  /// Writes the planner inputs of [id] (and `target` = what is needed, so the Save tab's ring and the period split agree). Returns core's
  /// refusal text, or null when written.
  String? saveGoalDraft(String id, GoalDraft d) {
    final g = goalOf(id);
    if (g == null) return 'No such goal.';
    try {
      repo.patch(GoalCols.entity, id, {
        GoalCols.price: d.price,
        GoalCols.depositPermille: d.depositPermille,
        GoalCols.costsPermille: d.costsPermille,
        GoalCols.loanRateBp: d.rateBp,
        GoalCols.loanMonths: d.months,
        GoalCols.compareLineId: d.compareId,
        GoalCols.monthly: d.monthly,
        GoalCols.target: planFor(g, d).need,
      });
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    logEvent(_log, Level.INFO, 'goal.plan', {'financed': d.depositPermille < 1000});
    _changed();
    return null;
  }

  /// A new big-purchase goal (Plan › Saving › + Goal): [financed] = with a loan; [property] only picks the starting costs (6 %) and loan
  /// length (30 years) over 0 % and 5 years. Returns the id, or null with the refusal in [error].
  String? addBigGoal(
      {required String name, required int price, required bool financed, required bool property, void Function(String)? error}) {
    try {
      final draft = GoalDraft(
          price: price, monthly: 0, depositPermille: financed ? 200 : 1000, costsPermille: property ? 60 : 0, months: property ? 360 : 60);
      final id = repo.saveGoal(
          name: name.trim().isEmpty ? 'Goal' : name.trim(),
          target: planFor(
                  Goal(id: '', name: name, price: price, depositPermille: draft.depositPermille, costsPermille: draft.costsPermille), draft)
              .need,
          saved: 0,
          monthly: 0,
          sort: goals.length + 1);
      repo.patch(GoalCols.entity, id, {
        GoalCols.price: price,
        GoalCols.depositPermille: draft.depositPermille,
        GoalCols.costsPermille: draft.costsPermille,
        GoalCols.loanMonths: draft.months,
      });
      logEvent(_log, Level.INFO, 'goal.addBig', {'financed': financed, 'property': property});
      _changed();
      return id;
    } on ArgumentError catch (e) {
      error?.call('${e.message}');
      return null;
    }
  }

  /// "I bought it" (one write, Undo = [undoBuyGoal]). Returns the loan id (null without a loan). Core's refusal: [ArgumentError].
  String? buyGoal(String id, {required List<String> txIds, Loan? loan, String? date}) {
    final loanId = repo.buyGoal(id, date: date ?? today(), purchaseTxIds: txIds, loan: loan);
    _changed();
    return loanId;
  }

  void undoBuyGoal(String id) {
    repo.undoBuyGoal(id);
    _changed();
  }

  /// Live payments out in the wallet currency, newest first: the rows the owner can pick as what the purchase cost.
  List<Tx> purchaseCandidates() => [
        for (final c in wholeTxs)
          if (c.tx.live && c.tx.amount < 0 && c.tx.currency == currency && c.tx.transferTo == null) c.tx
      ]..sort((a, b) => b.date.compareTo(a.date));

  /// The key core matches a lender's bank rows by, from the name as the bank writes it.
  String payeeKeyOf(String text) => merchantKey(Tx(id: '', source: 'pbz', date: '', amount: 0, description: text));

  // ---------- loans ----------

  /// Open loans first, then closed ones.
  List<Loan> loansAll() => [...repo.loans().where((l) => l.open), ...repo.loans().where((l) => !l.open)];

  Loan? loanOf(String id) => repo.loans().where((l) => l.id == id).firstOrNull;

  /// [id]'s schedule, matched payments and state (null: no such loan). Not cached: the screen is small and reads it once per build.
  LoanView? loanView(String id) {
    final l = loanOf(id);
    if (l == null) return null;
    final rates = repo.loanRates(id), checks = repo.loanChecks(id);
    final schedule = loanSchedule(l, rates, checks);
    // Which rows pay the loan is core's decision (confirmed asks and silent matches), not a text match here.
    return LoanView(l, rates, checks, schedule, repo.loanMatchedPayments(id), loanState(schedule, repo.loanMatchedDates(id), today()));
  }

  /// `YYYY-MM` of the loan's last scheduled payment; null while its amount, length or first payment date is unknown.
  String? loanEndMonth(Loan l) {
    final s = loanSchedule(l, repo.loanRates(l.id), repo.loanChecks(l.id));
    return s.isEmpty ? null : monthOf(s.last.due);
  }

  /// The loan whose matched payments include payment [txId]; null when none.
  Loan? loanOfPayment(String txId) {
    for (final l in repo.loans()) {
      if (repo.loanMatchedPayments(l.id).any((m) => m.txId == txId)) return l;
    }
    return null;
  }

  /// The "Loan payment?" asks that name loan [loanId] (oldest first); each lists every loan the row may belong to.
  List<({LoanPaymentMatch payment, List<Loan> loans})> loanAsks(String loanId) => [
        for (final a in repo.pendingLoanPayments())
          if (a.loans.any((l) => l.id == loanId)) a
      ];

  /// "Loan payment?" yes (or Undo of [unlinkLoanPayment]): row [txId] pays loan [loanId]. Returns core's refusal text or null.
  String? confirmLoanPayment(String loanId, String txId) {
    try {
      repo.confirmLoanPayment(loanId, txId);
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    _changed();
    return null;
  }

  /// "Loan payment?" no, or Unlink: row [txId] is not a payment of the loans [loanIds]. Returns core's refusal text or null.
  String? unlinkLoanPayment(Iterable<String> loanIds, String txId) {
    try {
      for (final id in loanIds) {
        repo.unlinkLoanPayment(id, txId);
      }
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    _changed();
    return null;
  }

  /// The loan a goal became (null: none, or it was deleted).
  Loan? loanOfGoal(Goal g) => g.loanId == null ? null : loanOf(g.loanId!);

  /// The schedule grouped by calendar year, for the chart.
  List<LoanYear> loanYears(List<LoanMonth> schedule) {
    final out = <LoanYear>[];
    for (final m in schedule) {
      final y = int.parse(m.due.substring(0, 4));
      if (out.isEmpty || out.last.year != y) {
        out.add(LoanYear(y, m.principal, m.interest, m.balance));
      } else {
        final p = out.removeLast();
        out.add(LoanYear(y, p.principal + m.principal, p.interest + m.interest, m.balance));
      }
    }
    return out;
  }

  /// The lender's balance [shown] on [date] against the schedule (nothing is written).
  LoanCheckResult? checkLoanBalance(LoanView v, int shown, String date) {
    if (v.schedule.isEmpty) return null;
    final before = v.schedule.where((m) => m.due.compareTo(date) <= 0).lastOrNull;
    final first = v.schedule.first;
    final expected = before?.balance ?? first.balance + first.principal;
    return LoanCheckResult(expected, shown - expected);
  }

  /// The balance the lender showed, confirmed by the owner: the schedule goes on from it. Returns core's refusal text, or null.
  String? addLoanCheck(String loanId, int balance) {
    try {
      repo.addLoanCheck(loanId, date: today(), balance: balance);
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    logEvent(_log, Level.INFO, 'loan.check');
    _changed();
    return null;
  }

  /// Read-only what-if over the loan as it stands.
  LoanWhatIf loanWhatIfFor(LoanView v, {int extraOnce = 0, int extraMonthly = 0, int? newRateBp}) => loanWhatIf(v.loan,
      rates: v.rates,
      checks: v.checks,
      extraOnce: extraOnce,
      extraOnceDate: today(),
      extraMonthly: extraMonthly,
      newRateBp: newRateBp,
      newRateFrom: newRateBp == null ? null : today());

  /// A new rate from today for a variable loan ("Use this" of the what-if); [payment] null = worked out. Returns core's refusal text or null.
  String? addLoanRateNow(String loanId, int rateBp, int? payment) {
    try {
      repo.addLoanRate(loanId, from: today(), rateBp: rateBp, payment: payment);
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    logEvent(_log, Level.INFO, 'loan.rate');
    _changed();
    return null;
  }

  /// Writes the details of loan [id] from [l] (an empty field clears it). Returns core's refusal text or null.
  String? saveLoanDetails(String id, Loan l) {
    try {
      repo.patch(LoanCols.entity, id, {
        LoanCols.name: l.name,
        LoanCols.principal: l.principal,
        LoanCols.rateBp: l.rateBp,
        LoanCols.months: l.months,
        LoanCols.firstDue: l.firstDue,
        LoanCols.payment: l.payment,
        LoanCols.accountId: l.accountId,
        LoanCols.payeeKey: l.payeeKey,
        LoanCols.reference: l.reference,
      });
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    logEvent(_log, Level.INFO, 'loan.details');
    _changed();
    return null;
  }

  /// Closes the loan as paid off today (Undo = [reopenLoan]). Returns core's refusal text, or null.
  String? closeLoanNow(String id) {
    try {
      repo.closeLoan(id, today());
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    _changed();
    return null;
  }

  void reopenLoan(String id) {
    repo.closeLoan(id, null);
    _changed();
  }

  /// "+ Loan" in the payday plan: a loan without a goal. Returns its id or null with the refusal in [error].
  String? addLoan(Loan l, {void Function(String)? error}) {
    try {
      final id = repo.addLoan(l);
      _changed();
      return id;
    } on ArgumentError catch (e) {
      error?.call('${e.message}');
      return null;
    }
  }

  /// Turns the old plan "Loan" setting into a loan row, one write; nothing happens before this call. Returns the refusal text or null.
  String? convertLegacyLoan(
      {String name = 'Loan', int? principal, int? rateBp, int? months, String? firstDue, String? payeeKey, String? reference}) {
    try {
      repo.convertLegacyLoan(
          name: name, principal: principal, rateBp: rateBp, months: months, firstDue: firstDue, payeeKey: payeeKey, reference: reference);
    } on ArgumentError catch (e) {
      return '${e.message}';
    }
    _changed();
    return null;
  }
}
