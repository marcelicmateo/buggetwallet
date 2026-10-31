// Edits of single payments in the controller: add an expense, set a category, delete and undo. A `part` of controller.dart so it can use
// `_changed`.
//
// Privacy: logs carry built-in category names, `custom` or `none`, and flags; never a payee, an amount or a note.
part of 'controller.dart';

extension TxEdits on WalletController {
  // ---------- edits ----------
  /// The category of the last expense added on this device (device-local `lastExpenseCategory`), or null.
  String? get lastExpenseCategory {
    return lastExpensePick;
  }

  void setCategory(Tx t, String category, {required bool always}) {
    // Built-in category names only; never the merchant.
    logEvent(_log, Level.INFO, 'category.change',
        {'from': _logCategory(categorizer.categoryOf(t)), 'to': _logCategory(category), 'always': always, 'source': t.source});
    if (always && t.source != 'manual') {
      repo.setMerchantRule(merchantKey(t), category);
      if (t.category != null) repo.setCategory(t.id, null);
    } else {
      repo.setCategory(t.id, category);
    }
    _changed();
    // Q6: a bank row set by hand only for itself may be the third of its payee: offer a rule (a toast; nothing is made).
    ruleOffer = null;
    if (!always && t.source != 'manual') _offerRule(t.id, category);
  }

  /// The hand-added expense that the bank row [bankId] replaced (hidden from lists), or null.
  Tx? entryMatchedTo(String bankId) {
    for (final t in repo.transactions(includeHidden: true)) {
      if (t.manual && t.matchedTo == bankId && !t.deleted) return t;
    }
    return null;
  }

  /// The bank row [bankId] replaced a hand-added expense (D2 cash match): its list row shows a "Matched" mark. One cheap query per data
  /// version (core's `matchedBankIds`), not a scan of every row per tile.
  bool isMatchedBank(String bankId) => _cached<Set<String>>(const MemoKey('matchedBanks'), () => repo.matchedBankIds()).contains(bankId);

  /// D2 Unlink: hand-added expense [entryId] stops being replaced by bank row [bankId]; the entry counts again. Returns null when it
  /// worked (the pair stays in [lastUnlinked] for the toast's Undo, [relinkCashMatch]) or core's readable refusal.
  String? unlinkCashMatch(String entryId, String bankId) {
    try {
      repo.unlinkMatch(entryId);
    } on ArgumentError catch (e) {
      logEvent(_log, Level.INFO, 'match.unlink', {'ok': false});
      return '${e.message}';
    } on StateError catch (e) {
      logEvent(_log, Level.INFO, 'match.unlink', {'ok': false});
      return e.message;
    }
    lastUnlinked = (entryId, bankId);
    logEvent(_log, Level.INFO, 'match.unlink', {'ok': true});
    _changed();
    return null;
  }

  /// Undo of [unlinkCashMatch]; null when done, else core's readable refusal (the bank row went, or got another expense).
  String? relinkCashMatch(String entryId, String bankId) {
    try {
      repo.relinkMatch(entryId, bankId);
    } on ArgumentError catch (e) {
      logEvent(_log, Level.INFO, 'match.relink', {'ok': false});
      return '${e.message}';
    } on StateError catch (e) {
      logEvent(_log, Level.INFO, 'match.relink', {'ok': false});
      return e.message;
    }
    logEvent(_log, Level.INFO, 'match.relink', {'ok': true});
    _changed();
    return null;
  }

  void deleteTransaction(Tx t) {
    lastDeletedTx = t.id;
    repo.deleteTransaction(t.id);
    logEvent(_log, Level.INFO, 'tx.delete', {'manual': t.manual});
    _changed();
  }

  /// Undo of [deleteTransaction] (the toast's Undo).
  void undeleteTransaction(String id) {
    repo.undeleteTransaction(id);
    logEvent(_log, Level.INFO, 'tx.undelete');
    _changed();
  }

  /// Undo of [deleteGoal].
  void undeleteGoal(String id) {
    repo.undeleteGoal(id);
    logEvent(_log, Level.INFO, 'goal.undelete');
    _changed();
  }
}
