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
  /// unknown). A loan closed in the running period (closed on or after `periodStart`, as `computePeriod` starts it)
  /// keeps its line, at its payment on the closing date, while a payment matched to it ("Loan") lies in
  /// [periodStart, closed date]: that payment is the line's money, so closing never changes safe-to-spend. From the
  /// next period on, the line is gone.
  Map<String, int> _loanPlanLines() {
    final today = _today();
    String? start;
    bool keeps(Loan l) {
      if (l.open) return true;
      final closed = l.closedAt!;
      if (closed.compareTo(start ??= _readSettings(db).periodStart ?? today) < 0) return false;
      final st = _loanState();
      return (st.decisions.matched[l.id] ?? const [])
          .any((p) => p.date.compareTo(start!) >= 0 && p.date.compareTo(closed) <= 0 && st.loanTx.contains(p.txId));
    }

    return {
      for (final l in loans())
        if (keeps(l)) l.id: loanPaymentOn(l, loanRates(l.id), loanChecks(l.id), l.closedAt ?? today) ?? 0,
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

  /// The loan payment decisions of the wallet as it is ([_LoanCache]): computed once per [dataVersion] (never cached
  /// inside a write, whose rows may still roll back).
  _LoanCache _loanState() {
    if (!db.autocommit) return _computeLoanState();
    if (_loanCache case (final int v, final _LoanCache c) when v == dataVersion) return c;
    final c = _computeLoanState();
    _loanCache = (dataVersion, c);
    return c;
  }

  _LoanCache _computeLoanState() {
    final ls = [
      for (final l in loans())
        if ((l.payeeKey ?? '').isNotEmpty || foldText(l.reference?.trim() ?? '').runes.length >= loanReferenceMinLength) l
    ];
    if (ls.isEmpty) return _LoanCache.none;
    final t = PerfTimer('repo.loanPayments');
    final currency = _readSettings(db).currency;
    final keys = {
      for (final l in ls)
        if ((l.payeeKey ?? '').isNotEmpty) l.payeeKey!
    };
    final refs = {
      for (final l in ls)
        if (foldText(l.reference?.trim() ?? '') case final r when r.runes.length >= loanReferenceMinLength) r
    };
    final hits = [
      for (final MapEntry(key: d, value: key) in _loanDescriptions().entries)
        if (keys.contains(key) || (refs.isNotEmpty && refs.any((_loanFolds[d] ??= foldText(d)).contains))) d
    ];
    final rows = <Tx>[];
    for (var i = 0; i < hits.length; i += 500) {
      final part = hits.sublist(i, i + 500 > hits.length ? hits.length : i + 500);
      rows.addAll([
        for (final r in db.select('${WalletRepo._txSelect} WHERE tx.description IN (${List.filled(part.length, '?').join(', ')})', part))
          Tx.fromRow(r)
      ]);
    }
    final answers = <String, Map<String, bool>>{};
    for (final r in db.select("SELECT loan_id, tx, state FROM loan_pays WHERE state IN ('on', 'off')")) {
      (answers[r['loan_id'] as String] ??= {})[r['tx'] as String] = r['state'] == 'on';
    }
    final table = categoryTable();
    final split = splits();
    final byId = {for (final l in ls) l.id: l};
    final schedules = {for (final l in ls) l.id: (loanRates(l.id), loanChecks(l.id))};
    final d = loanPaymentDecisions(
      {
        for (final l in ls)
          l.id: loanPayments(l, schedules[l.id]!.$1, schedules[l.id]!.$2, rows, currency: currency, keys: _loanKeys, folded: _loanFolds)
      },
      answers,
      askOnly: {
        for (final r in rows)
          if ((r.category != null && table.isLive(r.category!)) || split.containsKey(r.id)) r.id
      },
    );
    // A matched row is "Loan" (fixed) only when its loan had a plan line on the row's date (open then: not closed
    // before it; payment known and above 0): otherwise neither the plan nor spending would count it. Closing a loan
    // later leaves its past payments as they were.
    final loanTx = <String>{};
    for (final MapEntry(key: id, value: list) in d.matched.entries) {
      final l = byId[id]!;
      for (final p in list) {
        if (l.closedAt != null && l.closedAt!.compareTo(p.date) < 0) continue;
        if ((loanPaymentOn(l, schedules[id]!.$1, schedules[id]!.$2, p.date) ?? 0) > 0) loanTx.add(p.txId);
      }
    }
    t.done({'loans': ls.length, 'descriptions': hits.length, 'rows': rows.length, 'matched': loanTx.length, 'asks': d.asks.length});
    return _LoanCache(d, loanTx);
  }

  /// The descriptions of the bank outflows (description → payee key), kept in [_loanKeys] across data versions so a data
  /// change costs only its new rows: rows are found by rowid (a row's description and kind never change once it has a
  /// date; a row made by an op that arrived before its creation op, without a date yet, is looked at again). The set
  /// only grows (a deleted row's description stays): `loanPayments` filters the rows read for it. Inside a write
  /// (which may roll back and hand its rowids out again) the new rows are added to a copy, nothing is kept.
  Map<String, String> _loanDescriptions() {
    final keep = db.autocommit;
    final out = keep ? _loanKeys : {..._loanKeys};
    var last = _loanScanRowid;
    final again = _loanRecheck.toList(), recheck = <int>{};
    for (final r in db.select(
        'SELECT rowid AS r, description, date, manual, amount FROM tx WHERE rowid > ?'
        '${again.isEmpty ? '' : ' OR rowid IN (${again.join(', ')})'}',
        [_loanScanRowid])) {
      final rowid = r['r'] as int;
      if (rowid > last) last = rowid;
      if (r['date'] == '') {
        recheck.add(rowid);
      } else if (r['manual'] == 0 && (r['amount'] as int) < 0) {
        final d = r['description'] as String;
        out[d] ??= merchantKey(Tx(id: '', source: 'bank', date: '', amount: 0, description: d));
      }
    }
    if (keep) {
      _loanScanRowid = last;
      _loanRecheck
        ..clear()
        ..addAll(recheck);
    }
    return out;
  }

  /// The bank rows that count as a loan payment (`Categorizer.loanTx`: main tag "Loan", fixed): matched rows of a loan
  /// that was open on the row's date (closed on or after it) with a payment above 0 then.
  Set<String> loanLinkedTx() => _loanState().loanTx;

  /// The "Loan payment?" asks (§5.5 step 4), oldest first, each row once with every loan that may take it: rows a
  /// loan's payee key or reference finds that the owner has not answered and that are not matched silently (several
  /// loans may take it, the owner set its main tag or split it, or no confirmed row of the same evidence vouches for
  /// it). Yes: [confirmLoanPayment] with the loan picked; no: [unlinkLoanPayment] for each loan.
  List<({LoanPaymentMatch payment, List<Loan> loans})> pendingLoanPayments() {
    final asks = _loanState().decisions.asks;
    if (asks.isEmpty) return const [];
    final byId = {for (final l in loans()) l.id: l};
    return [
      for (final a in asks) (payment: a.payment, loans: [for (final id in a.loanIds) byId[id]!])
    ];
  }

  /// The rows matched to loan [loanId], oldest first ([LoanPaymentMatch.amountChanged] flags a payment that differs
  /// from the schedule), also those without a plan line (they count as spending). Unknown or deleted loan: empty.
  List<LoanPaymentMatch> loanMatchedPayments(String loanId) => _loanState().decisions.matched[loanId] ?? const [];

  /// The dates of [loanMatchedPayments], for `loanState`.
  List<String> loanMatchedDates(String loanId) => [for (final p in loanMatchedPayments(loanId)) p.date];

  /// "Loan payment?" yes, or Undo of [unlinkLoanPayment]: row [txId] pays loan [loanId] (and no other loan: one write
  /// also answers no for a loan it was confirmed for before), and later rows found by the same evidence match silently.
  /// The row must be one the loan's payee key or reference finds (never by amount): else, or for an unknown or deleted
  /// loan, [ArgumentError].
  void confirmLoanPayment(String loanId, String txId) {
    final l = loans().where((l) => l.id == loanId).firstOrNull;
    if (l == null) throw ArgumentError('No such loan.');
    final found = loanPayments(l, loanRates(loanId), loanChecks(loanId), [if (transaction(txId) case final t?) t],
        currency: _readSettings(db).currency);
    if (found.isEmpty) throw ArgumentError('This payment is not from the loan\'s lender or reference.');
    final others = [
      for (final r in db.select("SELECT loan_id FROM loan_pays WHERE tx = ? AND state = 'on' AND loan_id != ?", [txId, loanId]))
        r['loan_id'] as String
    ];
    _write([_loanPay(loanId, txId, true), for (final o in others) _loanPay(o, txId, false)]);
    logEvent(_log, Level.INFO, 'loan.payment', {'on': true, 'moved': others.length});
  }

  /// Unlink (or "Loan payment?" no): row [txId] is not a payment of loan [loanId] and is never matched to it again; its
  /// main tag goes back to what the rules say. Undo: [confirmLoanPayment]. Unknown or deleted loan: [ArgumentError].
  void unlinkLoanPayment(String loanId, String txId) {
    _liveLoan(loanId);
    _write([_loanPay(loanId, txId, false)]);
    logEvent(_log, Level.INFO, 'loan.payment', {'on': false});
  }

  (String, String, Map<String, Object?>) _loanPay(String loanId, String txId, bool on) =>
      (LoanPayCols.entity, '$loanId|$txId', {'loan_id': loanId, 'tx': txId, 'state': on ? 'on' : 'off'});

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

/// One data version's loan payment state ([WalletRepoLoans._loanState]).
class _LoanCache {
  final LoanDecisions decisions;
  final Set<String> loanTx;
  const _LoanCache(this.decisions, this.loanTx);
  static const none = _LoanCache(LoanDecisions.none, {});
}
