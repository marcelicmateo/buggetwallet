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
