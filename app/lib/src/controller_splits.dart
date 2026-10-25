// Split payments in the controller (stage P6, spec docs/context/P6_SPEC.md). A `part` of controller.dart so it can use `_changed`.
// The core checks every rule (parts add up exactly, 2..20 parts, no transfers) and throws an `ArgumentError` with the text to show.
//
// Privacy: logs carry counts only, never amounts, tags or notes.
part of 'controller.dart';

extension SplitsDb on WalletController {
  /// How many parts payment [txId] is split into now (0 when it is not split, or its split no longer adds up).
  int splitCount(String txId) => splitParts[txId]?.length ?? 0;

  /// The payment's stored split no longer adds up (it counts whole).
  bool splitIsBroken(String txId) => splitBrokenIds.contains(txId);

  /// The stored split of [txId] (valid or not), or null.
  List<SplitPart>? storedSplit(String txId) => repo.splitOf(txId);

  /// The part rows of [txId] for a list under its tile (stored order); empty when it counts whole.
  List<CategorizedTx> partsOf(String txId) => splitParts[txId] ?? const [];

  /// Splits [t] into [parts]. Throws `ArgumentError` (owner-readable text) when core refuses; nothing is written then.
  void saveSplit(Tx t, List<SplitPart> parts) {
    try {
      repo.setSplit(t.id, parts);
    } on ArgumentError {
      logEvent(_log, Level.INFO, 'split.refused', {'parts': parts.length}); // counts only; the caller shows core's text
      rethrow;
    }
    logEvent(_log, Level.INFO, 'split.save', {'parts': parts.length});
    _changed();
  }

  /// Removes the split of [t]; returns the parts it had (for Undo), or null when it had none.
  List<SplitPart>? removeSplitOf(Tx t) {
    final old = repo.splitOf(t.id);
    if (old == null) return null;
    repo.removeSplit(t.id);
    lastRemovedSplit = (t, old);
    logEvent(_log, Level.INFO, 'split.remove', {'parts': old.length});
    _changed();
    return old;
  }

  /// Undo of [removeSplitOf]: puts [parts] back. False when core no longer accepts them (the amount changed meanwhile).
  bool restoreSplitOf(Tx t, List<SplitPart> parts) {
    try {
      repo.setSplit(t.id, parts);
    } on ArgumentError {
      logEvent(_log, Level.INFO, 'split.restoreRefused', {'parts': parts.length});
      return false;
    }
    logEvent(_log, Level.INFO, 'split.restore', {'parts': parts.length});
    _changed();
    return true;
  }
}
