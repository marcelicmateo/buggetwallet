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

  /// For `settings()`: each open live loan's payment in force today ([loanPaymentOn], 0 when unknown), and whether
  /// the legacy row exists (live or not: once moved, the old `loan` setting never counts again).
  (Map<String, int>, bool) _loanPlanLines() {
    final today = _today();
    final lines = <String, int>{};
    var moved = false;
    for (final r in db.select('SELECT * FROM loans')) {
      final l = Loan.fromRow(r);
      if (l.id == Loan.legacyId) moved = true;
      if (r['deleted'] != 0 || !l.open) continue;
      lines[l.id] = loanPaymentOn(l, loanRates(l.id), today) ?? 0;
    }
    return (lines, moved);
  }

  /// Schema 21: the old single plan loan (`WalletSettings.loan` > 0) becomes loan [Loan.legacyId] with that payment
  /// (principal, rate, length and first due date unknown: `loanLeft` keeps reading `loanEnd` until they are filled in).
  /// Every device migrating the same setting writes the same row. The settings rows stay for older builds.
  int _migrateLegacyLoan() {
    final st = _readSettings(db);
    if (st.loan <= 0 || db.select('SELECT 1 FROM loans WHERE id = ?', [Loan.legacyId]).isNotEmpty) return 0;
    _writeInternal([
      ('loan', Loan.legacyId, {'name': 'Loan', 'payment': st.loan, 'deleted': 0})
    ]);
    return 1;
  }

  static String _undoBuyKey(String goalId) => 'undoBuy.$goalId';

  /// "I bought it" (§5.5 step 3), one write: goal [goalId] gets `bought_at` [date] and `monthly` 0 (its money is spent
  /// on the purchase, it no longer saves); a project tag named like the goal (an existing live tag of that name is
  /// reused; none when the name is taken by a main tag or the tag limit is reached) goes on [purchaseTxIds]; with
  /// [loan], a loan row tied to the goal and the tag (its payment then counts in the fixed plan). Returns the loan id.
  /// The goal must be live and not bought, the rows live: else [ArgumentError]. [undoBuyGoal] takes it back.
  String? buyGoal(String goalId, {required String date, List<String> purchaseTxIds = const [], Loan? loan}) {
    final rs = db.select('SELECT * FROM goals WHERE id = ? AND deleted = 0', [goalId]);
    if (rs.isEmpty) throw ArgumentError('No such goal.');
    final g = Goal.fromRow(rs.first);
    if (g.boughtAt != null) throw ArgumentError('This goal is already bought.');
    final goalFields = _patchFields(<Col, Object?>{GoalCols.boughtAt: date});
    for (final id in purchaseTxIds) {
      if (transaction(id) case final t? when !t.deleted) continue;
      throw ArgumentError('No such transaction.');
    }
    final t = tagTable();
    final key = foldText(g.name.trim());
    String? tagId = t.liveIds.where((id) => foldText(t.label(id).trim()) == key).firstOrNull;
    final changes = <(String, String, Map<String, Object?>)>[];
    var created = false;
    if (tagId == null && t.liveIds.length < TagRow.maxLive) {
      try {
        final name = _checkTagName(g.name, t);
        tagId = _newTagId();
        created = true;
        var next = 0;
        for (final id in t.liveIds) {
          final p = t.position(id);
          if (p < (1 << 30) && p >= next) next = p + 1;
        }
        changes.add(('tag', tagId, {'name': name, 'position': next, 'hidden': 0, 'deleted': 0}));
      } on ArgumentError {
        tagId = null; // a main tag has this name: no project tag
      }
    }
    final links = <String>[];
    if (tagId != null) {
      for (final id in purchaseTxIds.toSet()) {
        final on = db.select("SELECT 1 FROM tx_tags WHERE id = ? AND state = 'on'", ['$id|$tagId']).isNotEmpty;
        if (on) continue;
        links.add(id);
        changes.add(('txtag', '$id|$tagId', {'tx': id, 'tag': tagId, 'state': 'on'}));
      }
    }
    final loanId = loan == null ? null : _newId('l');
    if (loan != null) changes.add(('loan', loanId!, _loanFields(loan, fallbackName: g.name, goalId: goalId, tagId: tagId)));
    changes.add(('goal', goalId, {...goalFields, 'loan_id': loanId, 'monthly': 0}));
    _write(changes);
    setLocalValue(
        _undoBuyKey(goalId), jsonEncode({'monthly': g.monthly, 'tag': tagId, 'tagCreated': created, 'links': links, 'loan': loanId}));
    logEvent(_log, Level.INFO, 'goal.bought', {'loan': loanId != null, 'tag': tagId != null, 'rows': links.length});
    return loanId;
  }

  /// Undo of [buyGoal], one write: the goal is not bought again (its `monthly` back, `loan_id` cleared), its loan is
  /// deleted (so its plan line ends), and the tag links it added are turned off (the tag itself deleted when it made it).
  /// What it added is read from this device's record of the buy; without one (bought on another device) the goal and
  /// its loan are restored and the tag rows stay. A goal that is not bought: [ArgumentError].
  void undoBuyGoal(String goalId) {
    final rs = db.select('SELECT * FROM goals WHERE id = ? AND deleted = 0', [goalId]);
    if (rs.isEmpty) throw ArgumentError('No such goal.');
    final g = Goal.fromRow(rs.first);
    if (g.boughtAt == null) throw ArgumentError('This goal is not bought.');
    final rec = switch (localValue(_undoBuyKey(goalId))) { final String s => jsonDecode(s), _ => null };
    final m = rec is Map<String, Object?> ? rec : const <String, Object?>{};
    final tagId = m['tag'] as String?;
    final changes = <(String, String, Map<String, Object?>)>[
      ('goal', goalId, {'bought_at': null, 'loan_id': null, if (m['monthly'] case final int v) 'monthly': v}),
      if (g.loanId case final l?) ('loan', l, {'deleted': 1}),
      if (tagId != null && m['tagCreated'] == true) ('tag', tagId, {'deleted': 1}),
      if (tagId != null)
        for (final tx in (m['links'] as List? ?? const []).whereType<String>())
          ('txtag', '$tx|$tagId', {'tx': tx, 'tag': tagId, 'state': 'off'}),
    ];
    _write(changes);
    setLocalValue(_undoBuyKey(goalId), null);
    logEvent(_log, Level.INFO, 'goal.unbought', {'record': rec != null});
  }
}
