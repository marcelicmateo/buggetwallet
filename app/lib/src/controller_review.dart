// Weekly review and habits in the controller: the review rows and steps, the streak, and the recurring-bill marks (confirm, skip,
// dismiss, delete). A `part` of controller.dart so it can use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never a payee, an amount or a note.
part of 'controller.dart';

extension ReviewHabits on WalletController {
  // ---------- habits: weekly review, recurring bills, nudges ----------
  /// The day of the week the review is due from (1 = Monday … 7 = Sunday, default Sunday).
  int get reviewDay => settings.reviewDay;

  /// The date of the last finished review, or null.
  String? get lastReview => settings.lastReview;

  /// Spending rows of the last 7 days without a category the owner set: the rows the review's "Confirm categories" step
  /// counts (same rule as core's `reviewState`). "Looks right" and the category sheet pin the category, so the row leaves
  /// the list. Cached per data version and day.
  List<CategorizedTx> reviewRows() => _cached(const MemoKey('reviewRows'), () {
        final to = today(), from = addDays(to, -7);
        return [
          for (final t in wholeTxs)
            if (t.tx.live &&
                t.date.compareTo(from) > 0 &&
                t.date.compareTo(to) <= 0 &&
                (t.kind == BudgetKind.fixed || t.kind == BudgetKind.flex) &&
                (t.tx.category == null || !categoryTable.isLive(t.tx.category!)))
              t
        ];
      });

  /// "Looks right" / after the category sheet: the row keeps the category it has now as the owner's choice, and the bank
  /// merchant learns it (as the category sheet does), so the row leaves the review list.
  void confirmCategory(Tx t) {
    final now = wholeTxs.where((x) => x.tx.id == t.id).firstOrNull ?? categorizer.categorize(t);
    final cat = now.category;
    logEvent(_log, Level.INFO, 'category.confirm', {'category': _logCategory(cat), 'source': t.source}); // never the merchant
    if (t.source != 'manual') repo.setMerchantRule(merchantKey(t), cat);
    repo.setCategory(t.id, cat);
    _changed();
  }

  /// This month's budgeted categories that are over budget or spending faster than the month passes.
  List<CategoryBudgetLine> paceRows() => _cached(
      const MemoKey('paceRows'),
      () => [
            for (final l in this.budgetVsActual(monthOf(today())).lines)
              if (l.over || (l.pace ?? 0) > 1.0) l
          ]);

  /// Wishes that finished the cooling-off wait and wait for buy or skip. Depends on the clock, so it is not cached.
  List<WishItem> readyWishes() {
    final now = _clock().millisecondsSinceEpoch;
    return wish.where((w) => w.status == 'waiting' && w.hoursLeft(settings.coolHours, now) <= 0).toList();
  }

  /// Is the weekly review due, its steps with counts, and the streak. Cached per data version and day.
  ReviewState reviewState() => _cached(
      const MemoKey('reviewState'),
      () => reviewStateOf(txs, settings, wish, categoryBudgets,
          today: today(), nowMillis: _clock().millisecondsSinceEpoch, table: categoryTable));

  /// Finishes this week's review (writes the date; the streak grows by one).
  void markReviewDone() {
    final r = reviewState();
    repo.markReviewDone(today());
    logEvent(_habits, Level.INFO, 'review.done', {
      'categories': r.count('categories'),
      'pace': r.count('pace'),
      'wishlist': r.count('wishlist'),
    }); // counts only
    _changed();
  }

  void setReviewDay(int day) {
    if (day < 1 || day > 7 || day == reviewDay) return;
    repo.updateSettings({'reviewDay': day});
    logEvent(_habits, Level.INFO, 'review.day', {'day': day});
    _changed();
  }

  /// Recurring bills worth showing: candidates and confirmed (dismissed ones stay hidden). Cached per data version.
  /// P9: this list holds the recurring **incomes** too; anything that treats a row as a bill reads [expectedBills] instead.
  List<RecurringBill> recurringBills() => _cached(const MemoKey('recurringBills'), repo.recurringBills);

  /// The recurring bills only (no incomes): candidates and confirmed. Cached per data version.
  List<RecurringBill> expectedBills() => _cached(
      const MemoKey('expectedBills'),
      () => [
            for (final b in recurringBills())
              if (!b.isIncome) b
          ]);

  /// The recurring incomes only (P9): candidates and confirmed. Cached per data version.
  List<RecurringBill> expectedIncomes() => _cached(
      const MemoKey('expectedIncomes'),
      () => [
            for (final b in recurringBills())
              if (b.isIncome) b
          ]);

  /// Looks for bills again in the imported rows (after an import and at start).
  void refreshRecurring() {
    try {
      repo.refreshRecurring(today());
      logEvent(_habits, Level.FINE, 'recurring.refresh', {'bills': repo.recurringBills().length});
    } catch (e, st) {
      logError(_habits, 'recurring.refreshFailed', e, st);
    }
  }

  /// Was the bill's last payment made in the running pay period (the "Paid" mark on Bills)?
  bool billPaidThisPeriod(RecurringBill b) {
    final id = b.lastPaidTx;
    if (id == null) return false;
    // One id -> date map per data version: the Bills tab asks once per bill on every build.
    final dates = memo<Map<String, String>>(const MemoKey('bills.txDates'), () {
      final m = <String, String>{};
      for (final t in wholeTxs) {
        m.putIfAbsent(t.tx.id, () => t.date);
      }
      return m;
    });
    final date = dates[id];
    return date != null && date.compareTo(period().start) >= 0;
  }

  void confirmRecurring(String id) {
    repo.confirmRecurring(id);
    logEvent(_habits, Level.INFO, 'recurring.confirm', {'bills': recurringBills().length}); // never payee or amount
    _changed();
  }

  /// A confirmed bill whose payment did not match: moves its due date on by one cycle, so it stops being reserved.
  Future<void> skipRecurring(String id) async {
    try {
      await repo.skipRecurring(id);
      logEvent(_habits, Level.INFO, 'recurring.skip', {'bills': recurringBills().length});
    } on ClockBehindException catch (e) {
      noticeClockBehind(e);
    } catch (e, st) {
      logError(_habits, 'recurring.skipFailed', e, st);
    }
    _changed();
  }

  void dismissRecurring(String id) {
    repo.dismissRecurring(id);
    logEvent(_habits, Level.INFO, 'recurring.dismiss', {'bills': recurringBills().length});
    _changed();
  }

  void deleteRecurring(String id) {
    repo.deleteRecurring(id);
    logEvent(_habits, Level.INFO, 'recurring.delete', {'bills': recurringBills().length});
    _changed();
  }
}
