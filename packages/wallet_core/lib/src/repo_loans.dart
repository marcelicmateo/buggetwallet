part of 'repo.dart';

/// Loans and the "I bought it" step of a goal (ENG E6, schema 21; `loans.dart` for the entities and the maths). Edits of
/// a loan go through `patch` except `closed_at` ([closeLoan]), `goal_id` (`buyGoal`) and `deleted`; rate rows and checks
/// are append-only. Logs carry counts only, never names or amounts.
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

  /// Closes loan [id] as paid off on [date] (its plan line ends), or reopens it with null. Unknown or deleted id, or a
  /// date after today: [ArgumentError].
  void closeLoan(String id, String? date) {
    _liveLoan(id);
    _write([
      ('loan', id, _patchFields(<Col, Object?>{LoanCols.closedAt: date}))
    ]);
    logEvent(_log, Level.INFO, 'loan.close', {'closed': date != null});
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

  /// Loan id → its candidate rows (`loanPayments`) split by the owner's answers ([loanMatches], `loan_pays`), for each
  /// live loan with a payee key or reference (closed ones too: their past payments stay matched).
  Map<String, LoanMatches> _loanMatches() {
    final ls = [
      for (final l in loans())
        if ((l.payeeKey ?? '').isNotEmpty || (l.reference ?? '').trim().isNotEmpty) l
    ];
    if (ls.isEmpty) return const {};
    final answers = <String, Map<String, bool>>{}, onFor = <String, Set<String>>{};
    for (final r in db.select("SELECT loan_id, tx, state FROM loan_pays WHERE state IN ('on', 'off')")) {
      final (loan, tx, on) = (r['loan_id'] as String, r['tx'] as String, r['state'] == 'on');
      (answers[loan] ??= {})[tx] = on;
      if (on) (onFor[tx] ??= {}).add(loan);
    }
    final currency = _readSettings(db).currency;
    // shortcut: reads every row and its payee key on each call (categorizer builds too); keep the result per dataVersion
    // if a wallet with loans gets slow.
    final rows = transactions();
    return {
      for (final l in ls)
        l.id: loanMatches(loanPayments(l, loanRates(l.id), loanChecks(l.id), rows, currency: currency), answers[l.id] ?? const {}, taken: {
          for (final MapEntry(key: tx, value: on) in onFor.entries)
            if (on.any((id) => id != l.id)) tx
        }),
    };
  }

  /// The bank rows matched to a loan (`Categorizer.loanTx`: main tag "Loan", fixed).
  Set<String> loanLinkedTx() => {
        for (final m in _loanMatches().values)
          for (final p in m.matched) p.txId
      };

  /// The "Loan payment?" asks (§5.5 step 4): rows found by a loan's payee key or reference that the owner has not
  /// answered and no confirmed row of the same evidence covers, oldest first. Yes: [confirmLoanPayment]; no:
  /// [unlinkLoanPayment].
  List<({Loan loan, LoanPaymentMatch payment})> pendingLoanPayments() {
    final byId = {for (final l in loans()) l.id: l};
    return [
      for (final MapEntry(key: id, value: m) in _loanMatches().entries)
        for (final p in m.pending) (loan: byId[id]!, payment: p)
    ]..sort(
        (a, b) => a.payment.date != b.payment.date ? a.payment.date.compareTo(b.payment.date) : a.payment.txId.compareTo(b.payment.txId));
  }

  /// The rows matched to loan [loanId], oldest first ([LoanPaymentMatch.amountChanged] flags a payment that differs
  /// from the schedule). Unknown or deleted loan: empty.
  List<LoanPaymentMatch> loanMatchedPayments(String loanId) => _loanMatches()[loanId]?.matched ?? const [];

  /// The dates of [loanMatchedPayments], for `loanState`.
  List<String> loanMatchedDates(String loanId) => [for (final p in loanMatchedPayments(loanId)) p.date];

  /// "Loan payment?" yes, or Undo of [unlinkLoanPayment]: row [txId] pays loan [loanId], and later rows found by the same
  /// evidence match silently. The row must be one the loan's payee key or reference finds (never by amount): else, or
  /// for an unknown or deleted loan, [ArgumentError].
  void confirmLoanPayment(String loanId, String txId) {
    final l = loans().where((l) => l.id == loanId).firstOrNull;
    if (l == null) throw ArgumentError('No such loan.');
    final found = loanPayments(l, loanRates(loanId), loanChecks(loanId), [if (transaction(txId) case final t?) t],
        currency: _readSettings(db).currency);
    if (found.isEmpty) throw ArgumentError('This payment is not from the loan\'s lender or reference.');
    _setLoanPay(loanId, txId, true);
  }

  /// Unlink (or "Loan payment?" no): row [txId] is not a payment of loan [loanId] and is never matched to it again; its
  /// main tag goes back to what the rules say. Undo: [confirmLoanPayment]. Unknown or deleted loan: [ArgumentError].
  void unlinkLoanPayment(String loanId, String txId) {
    _liveLoan(loanId);
    _setLoanPay(loanId, txId, false);
  }

  void _setLoanPay(String loanId, String txId, bool on) {
    _write([
      (LoanPayCols.entity, '$loanId|$txId', {'loan_id': loanId, 'tx': txId, 'state': on ? 'on' : 'off'})
    ]);
    logEvent(_log, Level.INFO, 'loan.payment', {'on': on});
  }

  /// The loan a bought goal becomes: one id per goal, so buying on two devices offline makes one loan.
  static String goalLoanId(String goalId) => 'l:goal:$goalId';

  /// The one `out:` contribution of goal [goalId]'s saved money spent on its purchase by [buyGoal] (one per goal, so
  /// two devices buying offline settle by last-writer-wins).
  static String _buyOutId(String goalId) => 'out:buy:$goalId';

  /// "I bought it" (§5.5 step 3), one write. Goal [goalId] gets `bought_at` [date] and `loan_id` (a bought goal saves no
  /// more: its monthly is skipped wherever it is paid or counted). Its saved money pays the purchase rows that lowered
  /// the spending money (`computePeriod`'s flexible spending: live, home currency, kind flex): one `out:buy:<goal>`
  /// contribution of min(saved, Σ those rows), dated on the latest of them, so `goalTakenOutBetween` gives it back and
  /// the purchase does not count twice. Fixed-category, transfer or income rows get none (they never lowered it). A
  /// project tag named like the goal (an existing live tag of that name is reused; none when the name is taken by a main
  /// tag or at the tag limit) goes on every picked row. With [loan], loan [goalLoanId] tied to the goal and the tag (its
  /// payment then counts in the fixed plan). Returns the loan id. The goal must be live and not bought, the rows live
  /// payments out in the wallet currency: else [ArgumentError]. [undoBuyGoal] takes it back.
  String? buyGoal(String goalId, {required String date, List<String> purchaseTxIds = const [], Loan? loan}) {
    final g = goals().where((g) => g.id == goalId).firstOrNull;
    if (g == null) throw ArgumentError('No such goal.');
    if (g.boughtAt != null) throw ArgumentError('This goal is already bought.');
    final goalFields = _patchFields(<Col, Object?>{GoalCols.boughtAt: date});
    final currency = _readSettings(db).currency;
    final cz = categorizer(withTags: false);
    final rows = <Tx>[];
    var flex = 0;
    String? lastFlex;
    for (final id in purchaseTxIds.toSet()) {
      final t = transaction(id);
      if (t == null || !t.live || t.amount >= 0) throw ArgumentError('Pick the payments the purchase was made with.');
      if (t.currency != currency) throw ArgumentError('Pick payments in $currency: the goal is saved in it.');
      rows.add(t);
      if (cz.categorize(t).kind == BudgetKind.flex) {
        flex -= t.amount;
        if (lastFlex == null || t.date.compareTo(lastFlex) > 0) lastFlex = t.date;
      }
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
    final spent = flex < g.saved ? flex : g.saved;
    if (spent > 0) changes.add(_contribution(goalId, -spent, date: lastFlex, id: _buyOutId(goalId)));
    final loanId = loan == null ? null : goalLoanId(goalId);
    if (loan != null) changes.add(('loan', loanId!, _loanFields(loan, fallbackName: g.name, goalId: goalId, tagId: tagId)));
    changes.add(('goal', goalId, {...goalFields, 'loan_id': loanId}));
    _write(changes);
    logEvent(_log, Level.INFO, 'goal.bought', {'loan': loanId != null, 'tag': tagId != null, 'rows': rows.length});
    return loanId;
  }

  /// Undo of [buyGoal], one write, on any device: `bought_at` and `loan_id` cleared (the goal saves again), its loan
  /// deleted (the goal's `loan_id` and [goalLoanId] whenever that row exists: two devices may have bought with and
  /// without a loan; its plan line ends) and its `out:buy` contribution removed (the saved money is back). The project
  /// tag and its links stay (the owner removes them on the Project screen if unwanted). A goal that is not bought:
  /// [ArgumentError].
  void undoBuyGoal(String goalId) {
    final g = goals().where((g) => g.id == goalId).firstOrNull;
    if (g == null) throw ArgumentError('No such goal.');
    if (g.boughtAt == null) throw ArgumentError('This goal is not bought.');
    final own = goalLoanId(goalId);
    final loanIds = {
      if (g.loanId case final l?) l,
      if (db.select('SELECT 1 FROM loans WHERE id = ? AND deleted = 0', [own]).isNotEmpty) own,
    };
    final out = db.select('SELECT 1 FROM goal_contrib WHERE id = ? AND deleted = 0', [_buyOutId(goalId)]).isNotEmpty;
    _write([
      ('goal', goalId, {'bought_at': null, 'loan_id': null}),
      for (final l in loanIds) ('loan', l, {'deleted': 1}),
      if (out) ('goal_contrib', _buyOutId(goalId), {'deleted': 1}),
    ]);
    logEvent(_log, Level.INFO, 'goal.unbought', {'loans': loanIds.length, 'out': out});
  }
}
