part of 'repo.dart';

/// Recurring bills made or edited by the owner (P4, `docs/context/P4_SPEC.md` §6): `addRecurring` (a manual bill,
/// confirmed at once, never touched by detection), `updateRecurring` (any bill) and [instalmentsLeft]. Every rule is an
/// [ArgumentError] with an owner-readable message, checked on local writes only (sync never refuses an op). Writes go
/// through `_write` (per-field last-writer-wins across devices). Logs: counts and flags only, never labels, payees,
/// amounts or ids (a detected bill's id holds its payee).
extension WalletRepoRecurring on WalletRepo {
  /// Longest bill name, most instalments of one plan.
  static const maxLabel = 40, maxInstalments = 600;

  /// Adds a bill by hand and returns its id (`rec:m` + 12 random hex). [amount] (cents > 0) is the expected amount;
  /// [minAmount]/[maxAmount] an optional amount range that holds it (the highest is set aside); [intervalDays] 1..400
  /// (`RecurringPeriod.days` for the usual classes); [firstDue] the first due date. [payee] (a `merchantKey`, e.g. from
  /// the payees in history) lets bank rows pay it; without one the bill never matches a payment (never on amount
  /// alone) and the owner marks each cycle paid (`skipRecurring`). [instalments] N ≥ 1 sets `ends_on` =
  /// [RecurringBill.lastDueFor] (calendar months for a monthly interval, else (N − 1) × [intervalDays] days on). A payee another live (not deleted, not dismissed) bill already uses is refused: edit or
  /// confirm that bill instead.
  ///
  /// P9: [direction] `in` adds a recurring **income** (`out`, the default, a bill; anything else is refused): [payee]
  /// is required (it is what matches the landed money, never the amount alone), [category] must be live and of kind
  /// extra (a salary-kind one already counts as salary), no [instalments]. A bill and an income may share a payee; two
  /// live incomes may not.
  String addRecurring({
    required String label,
    required String category,
    required int amount,
    int? minAmount,
    int? maxAmount,
    required int intervalDays,
    required String firstDue,
    String? payee,
    int? instalments,
    String direction = RecurringBill.directionOut,
  }) {
    if (direction != RecurringBill.directionOut && direction != RecurringBill.directionIn) {
      throw ArgumentError('Pick a bill or an income.');
    }
    final income = direction == RecurringBill.directionIn;
    final name = _checkBillLabel(label);
    _checkBillCategory(category, income: income);
    _checkBillAmounts(amount, minAmount, maxAmount);
    _checkInterval(intervalDays);
    if (!isIsoDate(firstDue)) throw ArgumentError('Give the first due date.');
    if (instalments != null && (instalments < 1 || instalments > maxInstalments)) {
      throw ArgumentError('Instalments must be between 1 and $maxInstalments.');
    }
    final key = payee?.trim() ?? '';
    if (income && instalments != null) throw ArgumentError('An income has no instalments.');
    if (income && key.isEmpty) throw ArgumentError('Pick the payee the income comes from.');
    // A bill and an income of one payee may live side by side (P9): only the same direction clashes.
    if (key.isNotEmpty &&
        db.select(
            'SELECT 1 FROM recurring WHERE payee = ? AND deleted = 0 AND status NOT IN (${RecurringBill.dismissedStored}) '
            "AND ${income ? "(direction = 'in' OR status LIKE 'in:%')" : "(COALESCE(direction, '') != 'in' AND status NOT LIKE 'in:%')"}",
            [key]).isNotEmpty) {
      throw ArgumentError(income ? 'Another income already uses this payee.' : 'Another bill already uses this payee.');
    }
    final id = _newRecurringId();
    _write([
      (
        'recurring',
        id,
        {
          'payee': key,
          'label': name,
          'category': category,
          'expected_amount': amount,
          'interval_days': intervalDays,
          'next_due': firstDue,
          'status': RecurringBill.storedStatus('confirmed', income: income),
          'manual': 1,
          'deleted': 0,
          if (minAmount != null) 'min_amount': minAmount,
          if (maxAmount != null) 'max_amount': maxAmount,
          'own_category': 1,
          if (instalments != null) 'ends_on': RecurringBill.lastDueFor(firstDue, intervalDays, instalments),
          if (income) 'direction': RecurringBill.directionIn,
        }
      )
    ]);
    logEvent(_log, Level.INFO, 'recurring.add', {
      'intervalDays': intervalDays,
      'range': minAmount != null,
      'payee': key.isNotEmpty,
      'instalments': instalments ?? 0,
      'income': income,
    });
    return id;
  }

  /// Edits a bill, detected or manual, with the rules of [addRecurring]: only the fields given (and different from the
  /// stored ones) are written. [clearRange] removes the amount range, [clearEnd] the last due date (they win over
  /// [minAmount]/[maxAmount] and [endsOn]). The range after the edit must hold the amount after the edit. Editing a
  /// candidate does not confirm it (detection keeps a candidate's label, amount, interval and due date at its latest
  /// result). Unknown id: [ArgumentError]. The direction (bill or income, P9) is never changed; an income's category
  /// must stay of kind extra and it takes no last due date ([endsOn]). A thin wrapper over [patch] (F2).
  void updateRecurring(
    String id, {
    String? label,
    String? category,
    int? amount,
    int? minAmount,
    int? maxAmount,
    bool clearRange = false,
    int? intervalDays,
    String? nextDue,
    String? endsOn,
    bool clearEnd = false,
  }) =>
      patch(RecurringCols.entity, id, {
        if (label != null) RecurringCols.label: label,
        if (category != null) RecurringCols.category: category,
        if (amount != null) RecurringCols.expectedAmount: amount,
        if (clearRange) ...{
          RecurringCols.minAmount: clearValue,
          RecurringCols.maxAmount: clearValue
        } else ...{
          if (minAmount != null) RecurringCols.minAmount: minAmount,
          if (maxAmount != null) RecurringCols.maxAmount: maxAmount,
        },
        if (intervalDays != null) RecurringCols.intervalDays: intervalDays,
        if (nextDue != null) RecurringCols.nextDue: nextDue,
        if (clearEnd) RecurringCols.endsOn: clearValue else if (endsOn != null) RecurringCols.endsOn: endsOn,
      });

  static const _recurringEdited = <Col>{
    RecurringCols.label, RecurringCols.category, RecurringCols.expectedAmount, RecurringCols.minAmount, //
    RecurringCols.maxAmount, RecurringCols.intervalDays, RecurringCols.nextDue, RecurringCols.endsOn,
  };

  /// [patch] of a recurring bill or income: [updateRecurring]'s rules (an amount range is written as one pair).
  int _patchRecurring(String id, Map<Col, Object?> v) {
    WalletRepoPatch._needValues(v);
    final rows = db.select('SELECT * FROM recurring WHERE id = ?', [id]);
    if (rows.isEmpty) throw ArgumentError('No such bill.');
    final r = rows.first;
    final b = RecurringBill.fromRow(r);
    final has = v.containsKey;
    final label = v[RecurringCols.label] as String?, category = v[RecurringCols.category] as String?;
    final intervalDays = v[RecurringCols.intervalDays] as int?, nextDue = v[RecurringCols.nextDue] as String?;
    final endsOn = v[RecurringCols.endsOn] as String?;
    final fields = <String, Object?>{};
    if (label != null) {
      final name = _checkBillLabel(label);
      if (name != b.label) fields['label'] = name;
    }
    if (category != null) {
      _checkBillCategory(category, income: b.isIncome);
      if (category != r['category']) fields['category'] = category;
      // The owner's choice: refresh no longer moves it with the payee's rows.
      if (!b.ownCategory) fields['own_category'] = 1;
    }
    if (intervalDays != null) {
      _checkInterval(intervalDays);
      if (intervalDays != r['interval_days']) fields['interval_days'] = intervalDays;
    }
    if (nextDue != null) {
      if (!isIsoDate(nextDue)) throw ArgumentError('Give the next due date.');
      if (nextDue != b.nextDue) fields['next_due'] = nextDue;
    }
    if (has(RecurringCols.endsOn) && endsOn == null) {
      if (b.endsOn != null) fields['ends_on'] = null;
    } else if (endsOn != null) {
      if (b.isIncome) throw ArgumentError('An income has no instalments.');
      if (!isIsoDate(endsOn)) throw ArgumentError('Give the last due date.');
      if (endsOn != b.endsOn) fields['ends_on'] = endsOn;
    }
    if (has(RecurringCols.expectedAmount) || has(RecurringCols.minAmount) || has(RecurringCols.maxAmount)) {
      final a = v[RecurringCols.expectedAmount] as int? ?? b.expectedAmount;
      final lo = has(RecurringCols.minAmount) ? v[RecurringCols.minAmount] as int? : b.minAmount;
      final hi = has(RecurringCols.maxAmount) ? v[RecurringCols.maxAmount] as int? : b.maxAmount;
      _checkBillAmounts(a, lo, hi);
      if (a != b.expectedAmount) fields['expected_amount'] = a;
      // Both ends together, so two devices editing the range never merge into a pair neither made.
      if (lo != b.minAmount || hi != b.maxAmount) {
        fields['min_amount'] = lo;
        fields['max_amount'] = hi;
      }
    }
    fields.addAll(_patchRest(v, _recurringEdited));
    if (fields.isEmpty) return 0;
    _write([('recurring', id, fields)]);
    logEvent(_log, Level.INFO, 'recurring.update', {'fields': fields.length, 'manual': b.manual});
    return fields.length;
  }

  /// Cycles left of [b]'s instalment plan, from `nextDue` to `endsOn` inclusive ([RecurringBill.instalmentsLeft]); null
  /// without `endsOn`.
  int? instalmentsLeft(RecurringBill b) => b.instalmentsLeft;

  static String _checkBillLabel(String label) {
    final n = label.trim();
    if (n.isEmpty) throw ArgumentError('Give the bill a name.');
    if (n.runes.length > maxLabel) throw ArgumentError('The bill name is limited to $maxLabel characters.');
    return n;
  }

  /// A live category; for an income (P9) one of kind extra, never a salary-kind one.
  void _checkBillCategory(String category, {bool income = false}) {
    final t = categoryTable();
    if (!t.isLive(category)) throw ArgumentError(income ? 'Pick a main tag for the income.' : 'Pick a main tag for the bill.');
    if (!income) return;
    final kind = t.kindOf(category);
    if (kind == BudgetKind.income) throw ArgumentError('This tag already counts as salary.');
    if (kind != BudgetKind.extra) throw ArgumentError('Pick an extra income tag for the income.');
  }

  static void _checkInterval(int days) {
    if (days < RecurringBill.minIntervalDays || days > RecurringBill.maxIntervalDays) {
      throw ArgumentError('A bill repeats every ${RecurringBill.minIntervalDays} to ${RecurringBill.maxIntervalDays} days.');
    }
  }

  /// [amount] 1..`maxAmount`; a range needs both ends, `0 < min ≤ max ≤ maxAmount`, and must hold [amount].
  static void _checkBillAmounts(int amount, int? lo, int? hi) {
    if (amount <= 0 || amount > WalletSettings.maxAmount) throw ArgumentError('The amount is not valid.');
    if (lo == null && hi == null) return;
    if (lo == null || hi == null) throw ArgumentError('Give both ends of the amount range.');
    if (!RecurringBill.validRange(lo, hi)) throw ArgumentError('The amount range is not valid.');
    if (amount < lo || amount > hi) throw ArgumentError('The amount must be within the range.');
  }

  /// `rec:m` + 12 random hex characters.
  String _newRecurringId() {
    final r = Random.secure();
    final sb = StringBuffer('rec:m');
    for (var i = 0; i < 12; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }
}
