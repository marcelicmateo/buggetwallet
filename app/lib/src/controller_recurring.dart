// Recurring bills beyond monthly (P4, docs/context/P4_SPEC.md §7) in the controller: add and edit a bill, what a cycle paid in parts has
// so far, and the Undo of "Mark paid". A `part` of controller.dart so it can use the cache and `_changed`.
//
// Privacy: logs carry period words, flags and counts only: never a name, payee, amount or bill id (a detected bill's id holds its payee).
part of 'controller.dart';

extension RecurringDb on WalletController {
  /// What pays the current cycle of each confirmed bill: the single payments and the parts counted so far (once per data version).
  RecurringPayments recurringPayments() => _cached(
      'recurringPayments',
      () => planRecurringPayments([
            for (final b in expectedBills())
              if (b.confirmed) b
          ], [
            for (final c in wholeTxs) c.tx
          ], currency: currency));

  /// Σ of the parts already paid towards [b]'s open cycle (0 without parts).
  int billPartsPaid(RecurringBill b) => recurringPayments().partsPaid(b.id);

  /// Adds a bill by hand (confirmed at once) and looks for a payment that already paid it. Throws [ArgumentError] with an
  /// owner-readable message when a field is not valid (the sheet shows it).
  String addRecurringBill({
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
    final id = repo.addRecurring(
        label: label,
        category: category,
        amount: amount,
        minAmount: minAmount,
        maxAmount: maxAmount,
        intervalDays: intervalDays,
        firstDue: firstDue,
        payee: payee,
        instalments: instalments,
        direction: direction);
    logEvent(_habits, Level.INFO, 'recurring.added', {
      'income': direction == RecurringBill.directionIn,
      'period': RecurringPeriod.of(intervalDays)?.name ?? 'custom',
      'range': minAmount != null,
      'payee': payee != null && payee.isNotEmpty
    });
    refreshRecurring();
    _changed();
    return id;
  }

  /// The payees of the most recent incoming payments (newest first, one each), for the payee picker of an income. Once per data version.
  List<RulePayee> incomePayees({int limit = 40}) => memo('recurring.incomePayees.$limit', () {
        final seen = <String>{};
        final out = <RulePayee>[];
        final rows = [...wholeTxs]..sort((a, b) => b.date.compareTo(a.date));
        for (final c in rows) {
          if (!c.tx.live || c.amount <= 0) continue;
          final k = tagPayee(c.tx);
          if (k == null || !seen.add(k)) continue;
          out.add(RulePayee(k, k.replaceAll('_', ' ')));
          if (out.length >= limit) break;
        }
        return out;
      });

  /// Edits a bill (any status). Same rules and errors as [addRecurringBill]; only changed fields are written.
  void updateRecurringBill(
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
  }) {
    repo.updateRecurring(id,
        label: label,
        category: category,
        amount: amount,
        minAmount: minAmount,
        maxAmount: maxAmount,
        clearRange: clearRange,
        intervalDays: intervalDays,
        nextDue: nextDue,
        endsOn: endsOn,
        clearEnd: clearEnd);
    logEvent(_habits, Level.INFO, 'recurring.edited', {'range': minAmount != null, 'clearRange': clearRange, 'clearEnd': clearEnd});
    refreshRecurring();
    _changed();
  }

  /// The Undo of removing an income: core has no undelete for a recurring row, so the income is added again with the same fields
  /// (confirmed at once; a new id). A refusal (the payee is used meanwhile) is logged, not thrown.
  void restoreRecurringIncome(RecurringBill b) {
    try {
      addRecurringBill(
          label: b.label,
          category: b.category,
          amount: b.hasRange ? b.maxAmount! : b.expectedAmount,
          minAmount: b.minAmount,
          maxAmount: b.maxAmount,
          intervalDays: b.intervalDays,
          firstDue: b.nextDue,
          payee: b.payee,
          direction: RecurringBill.directionIn);
      logEvent(_habits, Level.INFO, 'recurring.incomeRestored');
    } on ArgumentError catch (e, st) {
      logError(_habits, 'recurring.incomeRestoreFailed', e, st);
    }
  }

  /// Puts a bill's due date back (the Undo of "Mark paid").
  void restoreRecurringDue(String id, String nextDue) {
    try {
      repo.updateRecurring(id, nextDue: nextDue);
      logEvent(_habits, Level.INFO, 'recurring.markPaidUndone');
    } on ClockBehindException catch (e) {
      noticeClockBehind(e);
    } catch (e, st) {
      logError(_habits, 'recurring.undoFailed', e, st);
    }
    _changed();
  }
}
