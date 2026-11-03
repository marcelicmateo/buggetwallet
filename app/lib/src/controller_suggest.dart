// Suggestions in the controller (stage Q): main tags and payees offered while a payment is typed (Q1), payee rules offered after
// the owner sets a main tag by hand (Q6), the filtered search (Q7) and the recent changes list (Q9). A `part` of controller.dart so it
// can use the cache and `_changed`. Nothing here writes on its own: every write waits for a tap.
//
// Privacy: logs carry counts and enum words only, never a payee, a label, a typed text or an amount.
part of 'controller.dart';

final _suggestLog = Logger('bw.suggest');

/// What the Add expense sheet's main tag picker offers; the chips under the note offer the same set and nothing else.
const addExpenseKinds = {BudgetKind.flex};
const addExpenseExclude = {'Bank fees'};

/// A payee rule offered after the owner set one payment's main tag ([suggestion], the very tag just picked); [txId] is that payment and
/// [own] its own main tag at that moment (what Make rule clears and Undo puts back, exactly; null = none).
class RuleOffer {
  final RuleSuggestion suggestion;
  final String txId;
  final String? own;
  const RuleOffer(this.suggestion, this.txId, [this.own]);
}

const _fieldWords = <String, String>{
  'kind_hint': 'type',
  'transfer_to': 'transfer',
  'matched_to': 'match',
  'match_off': 'match',
  'seen_bank': 'match',
  'bank_type': 'bank type',
  'expected_amount': 'amount',
  'min_amount': 'amount',
  'max_amount': 'amount',
  'interval_days': 'interval',
  'next_due': 'next date',
  'due_date': 'due date',
  'last_paid_tx': 'paid',
  'own_category': 'category',
  'ends_on': 'end date',
  'opening_date': 'opening date',
  'opening': 'opening balance',
  'goal_id': 'goal',
  'source_ref': 'source',
  'paid_tx': 'paid',
  'linked_tx': 'payment',
  'attached_tx': 'payment',
  'return_by': 'return date',
  'warranty_until': 'warranty',
  'blob': 'file',
  'blob_type': 'file',
  'blob_bytes': 'file',
  'external_id': 'source',
  'state': 'tags',
  'tag': 'tags',
  'tx': 'payment',
  'position': 'order',
  'sort': 'order',
};

/// Owner words for the fields of a change (not column names), each once, in the stored order; more than three are counted. A row
/// written whole (six fields or more) is "added"; the `deleted` flag alone is "restored" (a delete is said by the caller).
String changeFieldsText(List<String> fields) {
  if (fields.length >= 6) return 'added';
  final out = <String>[];
  for (final f in fields) {
    if (f == 'deleted') continue;
    final w = _fieldWords[f] ?? f.replaceAll('_', ' ');
    if (!out.contains(w)) out.add(w);
  }
  if (out.isEmpty) return 'restored';
  if (out.length > 3) return '${out.take(3).join(', ')} +${out.length - 3}';
  return out.join(', ');
}

/// What Settings and Plan call the setting stored under [key], or "Setting" for a key this build has no word for; per-key rows
/// (`budget:<category>`, `pattern:<hash>`, `plan:<id>`, `fx:<code>`, `csvmap:<id>`) get one word without the rest of the key.
String changeSettingWord(String key) {
  for (final (prefix, word) in const [
    ('budget:', 'Budget'),
    ('pattern:', 'Rule'),
    ('plan:', 'Plan line'),
    ('fx:', 'Exchange rate'),
    ('csvmap:', 'File layout'),
  ]) {
    if (key.startsWith(prefix)) return word;
  }
  return switch (key) {
    'salary' || 'salaryConfirmed' => 'Salary',
    'paydayDay' => 'Payday',
    'periodStart' => 'Pay period',
    'rent' || 'rentCashThreshold' => 'Rent',
    'loan' || 'loanEnd' => 'Loan',
    'subs' => 'Subscriptions',
    'impulse' || 'coolHours' => 'Big-buy rule',
    'headsUpCents' || 'headsUpDays' => 'Heads-up',
    'returnReminderDays' || 'warrantyReminderDays' => 'Bill reminders',
    'reviewDay' || 'reviewStreak' || 'lastReview' => 'Weekly review',
    'currency' => 'Currency',
    'savedFor' => 'Saved for',
    _ => 'Setting',
  };
}

/// The word for a changed row's kind ("Payment", "Goal"…).
String changeEntityWord(String entity) => switch (entity) {
      'tx' => 'Payment',
      'goal' => 'Goal',
      'loan' => 'Loan',
      'loanrate' => 'Loan rate',
      'loancheck' => 'Loan balance check',
      'wish' => 'Wish',
      'setting' => 'Setting',
      'rule' => 'Payee rule',
      'goal_contrib' => 'Goal saving',
      'recurring' => 'Recurring bill',
      'planned' => 'Planned cost',
      'bill' => 'Bill',
      'account' => 'Account',
      'category' => 'Main tag',
      'tag' => 'Tag',
      'txtag' => 'Payment tags',
      'ruletag' => 'Payee tags',
      'split' => 'Split',
      'review' => 'Weekly review',
      _ => 'Item',
    };

extension SuggestDb on WalletController {
  // ---------- Q1: while a payment is typed ----------
  /// Up to 3 main tags for the text typed in the Add expense note, only ones its picker offers. Cached per data version and text
  /// (core reads every row). Never applied: a chip waits for a tap.
  List<String> suggestCategoriesFor(String text) {
    final q = text.trim();
    if (q.isEmpty) return const [];
    return memo(
        MemoKey('suggest.cat', q),
        () => timed('suggest.categories',
            () => suggestCategoriesForText(q, wholeTxs, categorizer, kinds: addExpenseKinds, exclude: addExpenseExclude),
            fields: {'tx': wholeTxs.length}, warnMs: 50));
  }

  /// Up to 5 recent payee names or notes holding [prefix], newest first, for the note field's list. Cached per data version.
  List<String> payeesFor(String prefix) {
    final q = prefix.trim();
    if (q.isEmpty) return const [];
    return memo(MemoKey('suggest.payees', q),
        () => timed('suggest.payees', () => recentPayees(wholeTxs, q), fields: {'tx': wholeTxs.length}, warnMs: 50));
  }

  // ---------- Q6: payee rules offered ----------
  /// Payee keys the owner dismissed in Settings › Tags and rules › Recommendations (device-local `ruleSuggestOff`, a JSON list).
  Set<String> get ruleSuggestOff => _localKeys('ruleSuggestOff');

  Set<String> _localKeys(String name) {
    final raw = repo.localValue(name);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final v = jsonDecode(raw);
      return v is List
          ? {
              for (final k in v)
                if (k is String) k
            }
          : const {};
    } on FormatException {
      return const {};
    }
  }

  /// Payees with no main tag that keep coming back (at least [_recurring] payments), minus the ones dismissed on this device. Cached.
  List<PayeeCount> payeeRecommendations({int limit = 5}) {
    final off = _localKeys('payeeRecOff');
    return [
      for (final p in uncategorisedPayeeList(limit: 50))
        if (p.count >= _recurring && !off.contains(p.merchantKey)) p
    ].take(limit).toList();
  }

  static const _recurring = 2;

  /// Hides the "no main tag" recommendation for payee [key] on this device (never synced); nothing else changes.
  void dismissPayeeRecommendation(String key) {
    final off = {..._localKeys('payeeRecOff'), key};
    repo.setLocalValue('payeeRecOff', jsonEncode(off.toList()..sort()));
    logEvent(_suggestLog, Level.INFO, 'payeeRec.dismiss', {'dismissed': off.length});
    notifyListeners();
  }

  /// The payee rules to offer in Rules › Suggested. Cached per data version and dismissal list.
  List<RuleSuggestion> get ruleSuggestionList {
    final off = ruleSuggestOff;
    return memo(
        MemoKey('rules.suggest', (off.toList()..sort()).join('|')),
        () => timed('rules.suggest', () => ruleSuggestions([for (final t in wholeTxs) t.tx], categorizer, off: off),
            fields: {'tx': wholeTxs.length}, warnMs: 50));
  }

  /// Hides the suggestion for [key] on this device (never synced); nothing else changes.
  void dismissRuleSuggestion(String key) {
    final off = {...ruleSuggestOff, key};
    repo.setLocalValue('ruleSuggestOff', jsonEncode(off.toList()..sort()));
    logEvent(_suggestLog, Level.INFO, 'ruleSuggest.dismiss', {'dismissed': off.length});
    notifyListeners();
  }

  /// Makes the payee rule [s] (a tap on Make rule in Rules › Suggested). The payments keep their own main tag.
  void makeSuggestedRule(RuleSuggestion s) {
    repo.setMerchantRule(s.merchantKey, s.category);
    logEvent(_suggestLog, Level.INFO, 'ruleSuggest.make', {'from': 'panel', 'category': _logCategory(s.category)});
    _changed();
  }

  /// Takes back [makeSuggestedRule].
  void undoSuggestedRule(RuleSuggestion s) {
    repo.removeMerchantRule(s.merchantKey);
    logEvent(_suggestLog, Level.INFO, 'ruleSuggest.undo', {'from': 'panel'});
    _changed();
  }

  /// The offer made after the last hand-set main tag, once (null when none); the toast after the sheet reads it.
  RuleOffer? takeRuleOffer() {
    final o = ruleOffer;
    ruleOffer = null;
    return o;
  }

  /// Remembers the offer for the payment [txId] as just saved with main tag [picked], when its payee has enough agreeing rows, no
  /// rule, and they agree on the tag just picked (a payee whose usual tag is another one is not offered: the toast must not
  /// propose what the owner just moved away from).
  void _offerRule(String txId, String picked) {
    final t = repo.transaction(txId);
    if (t == null) return;
    var s = ruleSuggestionFor(t, [for (final c in wholeTxs) c.tx], categorizer, off: ruleSuggestOff);
    final table = categoryTable;
    if (s != null && (table.duplicateOf(s.category) ?? s.category) != (table.duplicateOf(picked) ?? picked)) s = null;
    ruleOffer = s == null ? null : RuleOffer(s, txId, t.category);
    if (s != null) logEvent(_suggestLog, Level.FINE, 'ruleSuggest.offer', {'count': s.count});
  }

  /// Make rule on the toast: the existing "always" path for the payment, which also clears its own main tag.
  void makeOfferedRule(RuleOffer o) {
    final t = repo.transaction(o.txId);
    if (t == null) return;
    logEvent(_suggestLog, Level.INFO, 'ruleSuggest.make', {'from': 'toast', 'category': _logCategory(o.suggestion.category)});
    setCategory(t, o.suggestion.category, always: true);
  }

  /// Undo of [makeOfferedRule]: the rule goes and the payment gets its own main tag back.
  void undoOfferedRule(RuleOffer o) {
    repo.removeMerchantRule(o.suggestion.merchantKey);
    repo.setCategory(o.txId, o.own);
    logEvent(_suggestLog, Level.INFO, 'ruleSuggest.undo', {'from': 'toast'});
    _changed();
  }

  // ---------- Q7: search with filters ----------
  /// [WalletController.search] narrowed by [filter] (payments only when it is set). Cached per data version, query and filter.
  SearchResult searchFiltered(String query, SearchFilter? filter) {
    if (filter == null || filter.isEmpty) return search(query);
    final key = (
      query,
      filter.minCents,
      filter.maxCents,
      filter.from,
      filter.to,
      (filter.categories.toList()..sort()).join('|'),
      filter.hasAttachment,
      filter.split,
      filter.uncategorised
    );
    return memo(MemoKey('search.filtered', key), () {
      final r = searchAll(query,
          txs: txs,
          goals: const [],
          wishlist: const [],
          bills: const [],
          table: categoryTable,
          tags: tagTable,
          filter: filter,
          attachedTx: repo.attachedTxIds());
      logEvent(_searchLog, Level.FINE, 'search.filtered', {'chars': query.length, 'tx': r.txs.length});
      return r;
    });
  }

  // ---------- Q9: recent changes ----------
  /// The newest [limit] changed rows on this device (what arrived from other devices too), cached per data version.
  List<ChangeEntry> recentChangesList({int limit = 30}) =>
      memo(MemoKey('changes.recent', limit), () => timed('changes.recent', () => repo.recentChanges(limit: limit), warnMs: 100));
}
