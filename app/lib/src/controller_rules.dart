// Rules in the controller (P7, spec docs/context/P7_SPEC.md): the list Plan › Rules shows, how many payments each rule decided, the
// payees to pick from, and the writes (payee rules, patterns). A `part` of controller.dart so it can use the cache and `_changed`.
//
// Privacy: logs carry kinds, counts and enum words only, never a payee, a pattern, a range or a tag.
part of 'controller.dart';

final _ruleLog = Logger('bw.rules.ui');

/// Shown for a rule that has only an amount range (owner rule: an amount never classifies on its own).
const rangeOnlyMessage = 'Add text to match: rules never use the amount alone.';

/// One payee to pick for a payee rule: its [key] (`merchantKey`) and the label the rules list shows.
class RulePayee {
  final String key, label;
  const RulePayee(this.key, this.label);
}

/// What the Add / Edit rule form holds when it asks for a preview or saves.
class RuleDraft {
  /// The pattern row being edited (`pattern:<hex>`), or null for a new rule.
  final String? editId;

  /// `payee`, `contains` or `regex`.
  final String match;

  /// The payee key for a payee rule.
  final String? payee;

  /// The text of a pattern.
  final String text;
  final int? minCents, maxCents;
  final String category;
  const RuleDraft({this.editId, required this.match, this.payee, this.text = '', this.minCents, this.maxCents, required this.category});

  bool get isPayee => match == 'payee';
  bool get hasRange => minCents != null || maxCents != null;
}

extension RulesDb on WalletController {
  /// The Rules list (own rules, then built-ins), computed once per data version.
  List<RuleView> get rulesList => memo(const MemoKey('rules.view'),
      () => timed('rules.view', () => rulesView(settings, repo.payeeRules(), tagContext.ruleTags, tagTable, categoryTable)));

  /// How many live payments in the wallet's currency each rule decided the main tag of (rule id -> count), once per data version.
  Map<String, int> ruleUseCounts() => memo(
      const MemoKey('rules.hits'),
      () => timed('rules.hits', () => ruleHits([for (final t in wholeTxs) t.tx], categorizer, currency: currency),
          fields: {'tx': wholeTxs.length}, warnMs: 50));

  /// The payees of the most recent payments (newest first, one each), for the payee picker. Once per data version.
  List<RulePayee> recentPayees({int limit = 40}) => memo(MemoKey('rules.payees', limit), () {
        final seen = <String>{};
        final out = <RulePayee>[];
        final rows = [...wholeTxs]..sort((a, b) => b.date.compareTo(a.date));
        for (final c in rows) {
          if (!c.tx.live) continue;
          final k = tagPayee(c.tx);
          if (k == null || !seen.add(k)) continue;
          out.add(RulePayee(k, k.replaceAll('_', ' ')));
          if (out.length >= limit) break;
        }
        return out;
      });

  /// How many payments would get another main tag if [d] were saved (the rules as they are now against the rules with the draft).
  /// Run on a tap, not per keystroke: it categorizes every row twice. Throws [ArgumentError] for a text that does not compile.
  int previewRuleChange(RuleDraft d) {
    final patterns = [...settings.patternRules];
    final rules = {...categorizer.merchantRules};
    if (d.isPayee) {
      rules[d.payee!] = d.category;
    } else {
      final text = d.match == MerchantPattern.contains ? d.text.trim() : d.text;
      if (text.trim().isEmpty) throw ArgumentError(d.hasRange ? rangeOnlyMessage : 'Enter what to match.');
      if (d.match == MerchantPattern.regex) {
        try {
          RegExp(text, caseSensitive: false);
        } on FormatException {
          throw ArgumentError('pattern does not compile');
        }
      }
      final at = patterns.indexWhere((p) => p.id == (d.editId ?? merchantPatternId(text)));
      final order = at >= 0 ? patterns[at].order : patterns.fold(0, (n, p) => p.order >= n ? p.order + 1 : n);
      final next = MerchantPattern(
          id: merchantPatternId(text),
          category: d.category,
          pattern: text,
          match: d.match,
          minCents: d.minCents,
          maxCents: d.maxCents,
          order: order);
      if (at >= 0) {
        patterns[at] = next;
      } else {
        patterns.add(next);
      }
      patterns.sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.id.compareTo(b.id));
    }
    // The owner's built-in edits too (UX-A): else a built-in turned off would match in `after` and count as a change.
    final after = Categorizer(
        merchantRules: rules,
        patternRules: patterns,
        rentCashThreshold: categorizer.rentCashThreshold,
        table: categoryTable,
        builtInOverrides: settings.builtInRuleOverrides);
    return timed('rules.preview', () {
      var n = 0;
      for (final c in wholeTxs) {
        final t = c.tx;
        if (!t.live || t.currency != currency) continue;
        if (categorizer.categoryOf(t) != after.categoryOf(t)) n++;
      }
      return n;
    }, fields: {'tx': wholeTxs.length}, warnMs: 100);
  }

  /// Saves the rule in [d] (a new one, or the edit of [RuleDraft.editId]); [tags] are the payee's tags (payee rules only).
  /// Throws [ArgumentError] with a readable text (core's, or [rangeOnlyMessage]).
  Future<void> saveRule(RuleDraft d, {Set<String> tags = const {}}) async {
    if (!categoryTable.isLive(d.category)) throw ArgumentError('Pick a main tag.');
    if (d.isPayee) {
      final key = d.payee;
      if (key == null || key.isEmpty) throw ArgumentError('Pick a payee.');
      repo.setMerchantRule(key, d.category);
      await _setPayeeTags(key, tags);
      logEvent(_ruleLog, Level.INFO, 'rules.save', {'kind': 'payee', 'tags': tags.length, 'edit': d.editId != null});
      _changed();
      return;
    }
    if (d.text.trim().isEmpty) throw ArgumentError(d.hasRange ? rangeOnlyMessage : 'Enter what to match.');
    final id = d.editId;
    if (id != null) {
      // clearRange: the form's range is the whole range (an empty field means no bound).
      repo.updateMerchantPattern(id,
          category: d.category, pattern: d.text, match: d.match, minCents: d.minCents, maxCents: d.maxCents, clearRange: true);
    } else {
      repo.setMerchantPattern(d.category, d.text, match: d.match, minCents: d.minCents, maxCents: d.maxCents);
    }
    logEvent(_ruleLog, Level.INFO, 'rules.save', {'kind': 'pattern', 'match': d.match, 'range': d.hasRange, 'edit': id != null});
    _changed();
  }

  /// Saves the tags of a payee that has tags but no main-tag rule: exactly [tags].
  Future<void> savePayeeTags(String key, Set<String> tags) async {
    await _setPayeeTags(key, tags);
    logEvent(_ruleLog, Level.INFO, 'rules.save', {'kind': 'payeeTags', 'tags': tags.length, 'edit': true});
    _changed();
  }

  /// Gives the payee [key] exactly the tags [want] (resolved through duplicates), writing only what differs.
  Future<void> _setPayeeTags(String key, Set<String> want) async {
    final table = repo.tagTable();
    Set<String> resolved(Iterable<String> ids) => {
          for (final id in ids)
            if (table.resolve(id) case final r?) r
        };
    final now = resolved(repo.ruleTags()[key] ?? const <String>{}), next = resolved(want);
    for (final id in next.difference(now)) {
      await repo.setRuleTag(key, id, true);
    }
    for (final id in now.difference(next)) {
      await repo.setRuleTag(key, id, false);
    }
  }

  /// Moves the pattern [id] one place in the match order.
  void moveRule(String id, MoveDirection direction) {
    repo.movePattern(id, direction);
    logEvent(_ruleLog, Level.INFO, 'rules.move', {'dir': direction.name});
    _changed();
  }

  /// Removes the pattern or payee rule [view]; [restoreRule] puts it back.
  void deleteRule(RuleView view) {
    if (view.kind == RuleKind.payee) {
      repo.removeMerchantRule(view.id.substring('payee:'.length));
      logEvent(_ruleLog, Level.INFO, 'rules.delete', {'match': 'payee'});
      _changed();
      return;
    }
    repo.removeMerchantPattern(view.text);
    logEvent(_ruleLog, Level.INFO, 'rules.delete', {'match': view.match});
    _changed();
  }

  /// Undo of [deleteRule]: the same text, main tag, match and range. The place in the order may come back last.
  void restoreRule(RuleView view) {
    if (view.kind == RuleKind.payee) {
      repo.setMerchantRule(view.id.substring('payee:'.length), view.category!);
      logEvent(_ruleLog, Level.INFO, 'rules.undelete', {'match': 'payee'});
      _changed();
      return;
    }
    repo.setMerchantPattern(view.category!, view.text, match: view.match, minCents: view.minCents, maxCents: view.maxCents);
    logEvent(_ruleLog, Level.INFO, 'rules.undelete', {'match': view.match});
    _changed();
  }
}
