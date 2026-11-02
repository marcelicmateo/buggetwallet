part of 'repo.dart';

/// Loans and the "I bought it" step of a goal (ENG E6, schema 21; `loans.dart` for the entities and the maths). Edits of
/// a loan, a rate row or a check go through `patch` (generic path: the row must exist and be live). Logs carry counts
/// only, never names or amounts.
extension WalletRepoLoans on WalletRepo {
  /// The loans, open and closed (deleted ones only with [includeDeleted]), by id.
  List<Loan> loans({bool includeDeleted = false}) =>
      [for (final r in db.select('SELECT * FROM loans${includeDeleted ? '' : ' WHERE deleted = 0'} ORDER BY id')) Loan.fromRow(r)];

  /// The live rate rows of loan [loanId], by date.
  List<LoanRate> loanRates(String loanId) => [
        for (final r in db.select('SELECT * FROM loan_rates WHERE loan_id = ? AND deleted = 0 ORDER BY from_date, id', [loanId]))
          LoanRate.fromRow(r)
      ];

  /// The live balance checks of loan [loanId], by date.
  List<LoanCheck> loanChecks(String loanId) => [
        for (final r in db.select('SELECT * FROM loan_checks WHERE loan_id = ? AND deleted = 0 ORDER BY date, id', [loanId]))
          LoanCheck.fromRow(r)
      ];

  /// The write map of a new loan from [l] (its id is ignored), checked by [LoanCols]; an empty name takes [fallbackName].
  Map<String, Object?> _loanFields(Loan l, {String fallbackName = 'Loan', String? goalId, String? tagId}) => {
        ..._patchFields(<Col, Object?>{
          LoanCols.name: l.name.trim().isEmpty ? fallbackName : l.name.trim(),
          if (l.principal != null) LoanCols.principal: l.principal,
          if (l.rateBp != null) LoanCols.rateBp: l.rateBp,
          if (l.months != null) LoanCols.months: l.months,
          if (l.firstDue != null) LoanCols.firstDue: l.firstDue,
          if (l.payment != null) LoanCols.payment: l.payment,
          if (l.accountId != null) LoanCols.accountId: l.accountId,
          if (l.payeeKey != null) LoanCols.payeeKey: l.payeeKey,
          if (l.reference != null) LoanCols.reference: l.reference,
          if ((goalId ?? l.goalId) != null) LoanCols.goalId: goalId ?? l.goalId,
          if ((tagId ?? l.tagId) != null) LoanCols.tagId: tagId ?? l.tagId,
        }),
        'deleted': 0,
      };

  /// Adds loan [l] (Plan › "+ Loan": a loan without a goal) and returns its id. A bad value: [ArgumentError].
  String addLoan(Loan l) {
    final id = _newId('l');
    _write([('loan', id, _loanFields(l))]);
    logEvent(_log, Level.INFO, 'loan.add', {'goal': l.goalId != null});
    return id;
  }

  /// Deletes / restores loan [id] (Undo). Unknown id: [ArgumentError].
  void deleteLoan(String id) => _setLoanDeleted(id, true);
  void undeleteLoan(String id) => _setLoanDeleted(id, false);
  void _setLoanDeleted(String id, bool deleted) {
    if (db.select('SELECT 1 FROM loans WHERE id = ?', [id]).isEmpty) throw ArgumentError('No such loan.');
    _write([
      ('loan', id, {'deleted': deleted ? 1 : 0})
    ]);
  }

  String _liveLoan(String loanId) {
    if (db.select('SELECT 1 FROM loans WHERE id = ? AND deleted = 0', [loanId]).isEmpty) throw ArgumentError('No such loan.');
    return loanId;
  }

  /// A rate change of loan [loanId] from [from] (payment null = the annuity over the months left). Returns its id.
  String addLoanRate(String loanId, {required String from, required int rateBp, int? payment}) {
    final id = _newId('lr');
    _write([
      (
        'loanrate',
        id,
        {
          ..._patchFields(<Col, Object?>{
            LoanRateCols.loanId: _liveLoan(loanId),
            LoanRateCols.from: from,
            LoanRateCols.rateBp: rateBp,
            if (payment != null) LoanRateCols.payment: payment,
          }),
          'deleted': 0
        }
      )
    ]);
    return id;
  }

  /// The balance the lender showed on [date], confirmed by the owner: the schedule goes on from it. Returns its id.
  String addLoanCheck(String loanId, {required String date, required int balance}) {
    final id = _newId('lc');
    _write([
      (
        'loancheck',
        id,
        {
          ..._patchFields(
              <Col, Object?>{LoanCheckCols.loanId: _liveLoan(loanId), LoanCheckCols.date: date, LoanCheckCols.balance: balance}),
          'deleted': 0
        }
      )
    ]);
    return id;
  }

  /// For `settings()`: each open live loan's payment in force today ([loanPaymentOn]: its schedule when known; 0 when
  /// unknown).
  Map<String, int> _loanPlanLines() {
    final today = _today();
    return {
      for (final l in loans())
        if (l.open) l.id: loanPaymentOn(l, loanRates(l.id), loanChecks(l.id), today) ?? 0,
    };
  }

  /// Moves the old single plan loan (`WalletSettings.loan`, with `loanEnd`) to loan row [Loan.legacyId], in ONE owner
  /// write: the row with payment = that setting and the given details, and the `loan` setting set to 0, so the plan
  /// counts it once and every device agrees by last-writer-wins. Returns the id. No old loan (0) or a live row
  /// already: [ArgumentError]. A build without loan rows that sets `loan` again later counts on top (known limit).
  String convertLegacyLoan(
      {String name = 'Loan',
      int? principal,
      int? rateBp,
      int? months,
      String? firstDue,
      String? accountId,
      String? payeeKey,
      String? reference}) {
    final payment = _readSettings(db).loan;
    if (payment <= 0) throw ArgumentError('There is no plan loan to move.');
    if (db.select('SELECT 1 FROM loans WHERE id = ? AND deleted = 0', [Loan.legacyId]).isNotEmpty) {
      throw ArgumentError('The plan loan is already a loan.');
    }
    final l = Loan(
        id: Loan.legacyId,
        name: name,
        principal: principal,
        rateBp: rateBp,
        months: months,
        firstDue: firstDue,
        payment: payment,
        accountId: accountId,
        payeeKey: payeeKey,
        reference: reference);
    _write([
      ..._settingChanges({'loan': 0}),
      ('loan', Loan.legacyId, _loanFields(l))
    ]);
    logEvent(_log, Level.INFO, 'loan.convertLegacy', {'principal': principal != null, 'schedule': months != null && firstDue != null});
    return Loan.legacyId;
  }

  /// The loan a bought goal becomes: one id per goal, so buying on two devices offline makes one loan.
  static String goalLoanId(String goalId) => 'l:goal:$goalId';

  /// The `out:` contribution of goal [goalId]'s saved money spent on purchase row [txId] by [buyGoal].
  static String _buyOutId(String goalId, String txId) => 'out:buy:$goalId:$txId';

  /// "I bought it" (§5.5 step 3), one write. Goal [goalId] gets `bought_at` [date] and `loan_id` (a bought goal saves no
  /// more: its monthly is skipped wherever it is paid or counted). Its saved money is spent on [purchaseTxIds]: per row
  /// (in the given order) an `out:` contribution of the row's amount, together at most the saved total, dated on the
  /// row, so `goalTakenOutBetween` gives it back to that period and the purchase does not count twice. A project tag
  /// named like the goal (an existing live tag of that name is reused; none when the name is taken by a main tag or at
  /// the tag limit) goes on the purchase rows. With [loan], loan [goalLoanId] tied to the goal and the tag (its payment
  /// then counts in the fixed plan). Returns the loan id. The goal must be live and not bought, the rows live and
  /// spending (amount below 0): else [ArgumentError]. [undoBuyGoal] takes it back.
  String? buyGoal(String goalId, {required String date, List<String> purchaseTxIds = const [], Loan? loan}) {
    final g = goals().where((g) => g.id == goalId).firstOrNull;
    if (g == null) throw ArgumentError('No such goal.');
    if (g.boughtAt != null) throw ArgumentError('This goal is already bought.');
    final goalFields = _patchFields(<Col, Object?>{GoalCols.boughtAt: date});
    final rows = <Tx>[];
    for (final id in purchaseTxIds.toSet()) {
      final t = transaction(id);
      if (t == null || t.deleted || t.amount >= 0) throw ArgumentError('Pick the payments the purchase was made with.');
      rows.add(t);
    }
    final changes = <(String, String, Map<String, Object?>)>[];
    final t = tagTable();
    final key = foldText(g.name.trim());
    var tagId = t.liveIds.where((id) => foldText(t.label(id).trim()) == key).firstOrNull;
    if (tagId == null) {
      try {
        final row = _newTagRow(g.name, t);
        tagId = row.$2;
        changes.add(row);
      } on ArgumentError {
        tagId = null; // a main tag has this name, or the tag limit: no project tag
      }
    }
    for (final r in rows) {
      if (tagId != null) changes.add(('txtag', '${r.id}|$tagId', {'tx': r.id, 'tag': tagId, 'state': 'on'}));
    }
    var left = g.saved;
    for (final r in rows) {
      final spent = -r.amount < left ? -r.amount : left;
      if (spent <= 0) break;
      left -= spent;
      changes.add(_contribution(goalId, -spent, date: r.date, id: _buyOutId(goalId, r.id)));
    }
    final loanId = loan == null ? null : goalLoanId(goalId);
    if (loan != null) changes.add(('loan', loanId!, _loanFields(loan, fallbackName: g.name, goalId: goalId, tagId: tagId)));
    changes.add(('goal', goalId, {...goalFields, 'loan_id': loanId}));
    _write(changes);
    logEvent(_log, Level.INFO, 'goal.bought', {'loan': loanId != null, 'tag': tagId != null, 'rows': rows.length});
    return loanId;
  }

  /// Undo of [buyGoal], one write, on any device: `bought_at` and `loan_id` cleared (the goal saves again), its loan
  /// deleted (its plan line ends) and its `out:` contributions removed (the saved money is back). The project tag and
  /// its links stay (the owner removes them on the Project screen if unwanted). A goal that is not bought: [ArgumentError].
  void undoBuyGoal(String goalId) {
    final g = goals().where((g) => g.id == goalId).firstOrNull;
    if (g == null) throw ArgumentError('No such goal.');
    if (g.boughtAt == null) throw ArgumentError('This goal is not bought.');
    final outs = db.select("SELECT id FROM goal_contrib WHERE goal_id = ? AND id LIKE ? AND deleted = 0", [goalId, _buyOutId(goalId, '%')]);
    _write([
      ('goal', goalId, {'bought_at': null, 'loan_id': null}),
      if (g.loanId case final l?) ('loan', l, {'deleted': 1}),
      for (final r in outs) ('goal_contrib', r['id'] as String, {'deleted': 1}),
    ]);
    logEvent(_log, Level.INFO, 'goal.unbought', {'outs': outs.length});
  }
}
