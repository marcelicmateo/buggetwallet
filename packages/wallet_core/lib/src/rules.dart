/// Rules (P7, spec `docs/context/P7_SPEC.md`): the stored shape of a merchant pattern, and the pure listing and hit
/// counts the Plan › Rules screen reads. Web-safe, no database.
library;

import 'dart:convert' show utf8;

import 'bills.dart' show sha256Hex;
import 'categories.dart';
import 'models.dart';
import 'search.dart' show foldText;
import 'tags.dart' show TagTable;

/// The settings row id of merchant [pattern] (schema 8): `pattern:` + the first 16 hex characters of the SHA-256 of
/// its UTF-8 bytes. The same pattern added on two devices is one row, and the id does not show the pattern. It is not
/// safe in a log: an unsalted hash of a short pattern is reversed with a word list, so problems with these rows are
/// logged under the key `merchantPatterns` (budget rows under `categoryBudgets`).
String merchantPatternId(String pattern) => '${WalletSettings.patternPrefix}${sha256Hex(utf8.encode(pattern)).substring(0, 16)}';

/// One merchant pattern (a per-key settings row `pattern:<16 hex>`, [WalletSettings.patternRules]). The stored JSON is
/// `{"category", "pattern", "order"}` plus, only when set, `"match": "contains"` and `"minCents"` / `"maxCents"`, so a
/// plain regex pattern is stored exactly as before P7 and a row without `match` reads as a regex.
class MerchantPattern {
  /// [match] values: a case-insensitive regex on the lower-cased, trimmed description (the default), or a case- and
  /// accent-folded substring ([foldText]).
  static const regex = 'regex', contains = 'contains';

  /// Longest `contains` text, after trimming.
  static const maxContainsLength = 60;

  /// The row id ([merchantPatternId] of [pattern]).
  final String id;
  final String category;

  /// The regex, or the (trimmed) text a `contains` pattern looks for.
  final String pattern;
  final String match;

  /// Optional amount range, compared with the absolute amount, inclusive. It only narrows the text match: a pattern
  /// always needs its text to match (owner rule: an amount never classifies on its own).
  final int? minCents, maxCents;

  /// Match order, ascending (ties by [id]).
  final int order;

  const MerchantPattern(
      {required this.id, required this.category, required this.pattern, this.match = regex, this.minCents, this.maxCents, this.order = 0});

  bool get hasRange => minCents != null || maxCents != null;

  /// Whether [amount] (signed cents; its absolute value is compared) is within the range. True without a range.
  bool inRange(int amount) {
    final a = amount.abs();
    return (minCents == null || a >= minCents!) && (maxCents == null || a <= maxCents!);
  }

  /// The stored JSON value of this row.
  Map<String, Object?> toJson() => {
        'category': category,
        'pattern': pattern,
        'order': order,
        if (match != regex) 'match': match,
        if (minCents != null) 'minCents': minCents,
        if (maxCents != null) 'maxCents': maxCents,
      };

  /// Reads a stored row value. Null when it is not a pattern row (missing or wrong-typed category, pattern or order,
  /// a negative order, an unknown `match`). An invalid range (not whole cents in 0..[WalletSettings.maxAmount], or min
  /// above max) drops only the range: `rangeDropped` is then true. Never throws.
  static (MerchantPattern?, bool rangeDropped) read(String id, Object? value) {
    if (value is! Map<Object?, Object?>) return (null, false);
    if (value case {'category': final String c, 'pattern': final String p, 'order': final int o} when o >= 0) {
      final m = value['match'];
      if (m != null && m != regex && m != contains) return (null, false);
      final min = value['minCents'], max = value['maxCents'];
      final lo = _cents(min), hi = _cents(max);
      // A range only narrows a `contains` rule (owner rule, P7 review): on a regex row it is dropped, the rule kept.
      final bad = (min != null && lo == null) ||
          (max != null && hi == null) ||
          (lo != null && hi != null && lo > hi) ||
          (m != contains && (min != null || max != null));
      return (
        MerchantPattern(
            id: id,
            category: c,
            pattern: p,
            match: m == contains ? contains : regex,
            minCents: bad ? null : lo,
            maxCents: bad ? null : hi,
            order: o),
        bad
      );
    }
    return (null, false);
  }

  static int? _cents(Object? v) {
    final c = switch (v) {
      final int i => i,
      final double d when d.isFinite && d == d.roundToDouble() => d.toInt(),
      _ => null,
    };
    return c != null && c >= 0 && c <= WalletSettings.maxAmount ? c : null;
  }

  /// The [ArgumentError] text for a range on a regex pattern: ranges need a `contains` rule.
  static const rangeNeedsContains = "Amount ranges need a 'description contains' rule.";

  /// Whether regex [re] matches the empty text, so every description (`.*`, `^`, `x*`, an empty group): never a rule.
  static bool matchesEverything(RegExp re) => re.hasMatch('');

  /// Why a range cannot be stored ([ArgumentError] text), or null when it can: each bound whole cents in
  /// 0..[WalletSettings.maxAmount], and min ≤ max.
  static String? rangeError(int? minCents, int? maxCents) {
    for (final v in [minCents, maxCents]) {
      if (v != null && (v < 0 || v > WalletSettings.maxAmount)) return 'amount out of range';
    }
    if (minCents != null && maxCents != null && minCents > maxCents) return 'the lower amount is above the upper one';
    return null;
  }
}

/// A payee rule ("always use this main tag for this payee"): the synced `rule` entity, payee [key] ([merchantKey]) →
/// [category].
class MerchantRule {
  final String key;
  final String category;
  const MerchantRule(this.key, this.category);

  @override
  bool operator ==(Object other) => other is MerchantRule && other.key == key && other.category == category;

  @override
  int get hashCode => Object.hash(key, category);
}

/// What a [RuleView] is: a payee rule (main tag, maybe with tags), a merchant pattern, a built-in rule (read-only), or
/// a payee's tags without a main-tag rule.
enum RuleKind { payee, pattern, builtIn, payeeTags }

/// Which way [WalletRepoSettings.movePattern] moves a pattern in the match order.
enum MoveDirection { up, down }

/// One row of the Rules screen ([rulesView]).
class RuleView {
  final RuleKind kind;

  /// `payee:<key>`, the pattern row id `pattern:<16 hex>`, `builtIn:<index in builtInMerchantRules>`, or
  /// `payeeTags:<key>`. The first three are the ids [Categorizer.ruleFor] and [ruleHits] use.
  final String id;

  /// The payee (its key with `_` as spaces) or the pattern text (a regex's source for built-ins).
  final String text;

  /// `regex` or `contains` for patterns, `regex` for built-ins, `payee` for payee and payee-tag rows.
  final String match;
  final int? minCents, maxCents;

  /// The main tag's id (null for [RuleKind.payeeTags]); [categoryLabel] is its label from the table.
  final String? category;
  final String? categoryLabel;

  /// The payee's live rule tags (resolved, in tag table order); empty for patterns and built-ins.
  final List<String> tags;

  /// The stored order for patterns, the index for built-ins, 0 otherwise.
  final int order;

  /// False only for built-in rules.
  final bool editable;

  const RuleView(
      {required this.kind,
      required this.id,
      required this.text,
      required this.match,
      this.minCents,
      this.maxCents,
      this.category,
      this.categoryLabel,
      this.tags = const [],
      this.order = 0,
      this.editable = true});
}

/// The Rules screen's list: payee rules by label, then patterns by order ([WalletSettings.patternRules]), then the
/// payee tag rules of payees without a payee rule (by label), then the built-in rules (read-only). A payee with a rule
/// and tags is one payee row carrying the tags. [ruleTags] = payee key → tag ids ([WalletRepoTags.ruleTags]); tag ids
/// resolve through [tags] (dead ones dropped). Category labels come from [table]. Pure.
List<RuleView> rulesView(
    WalletSettings st, List<MerchantRule> payeeRules, Map<String, Set<String>> ruleTags, TagTable tags, CategoryTable table) {
  List<String> tagsFor(String key) {
    final ids = ruleTags[key];
    if (ids == null || ids.isEmpty) return const [];
    final on = {
      for (final id in ids)
        if (tags.resolve(id) case final r?) r
    };
    if (on.isEmpty) return const [];
    return [
      for (final id in tags.ids)
        if (on.contains(id)) id
    ];
  }

  String label(String key) => key.replaceAll('_', ' ');
  int byLabel(String a, String b) {
    final d = foldText(label(a)).compareTo(foldText(label(b)));
    return d != 0 ? d : a.compareTo(b);
  }

  final payees = {for (final r in payeeRules) r.key: r.category};
  final payeeKeys = payees.keys.toList()..sort(byLabel);
  final tagOnly = [
    for (final k in ruleTags.keys)
      if (!payees.containsKey(k) && tagsFor(k).isNotEmpty) k
  ]..sort(byLabel);
  return [
    for (final k in payeeKeys)
      RuleView(
          kind: RuleKind.payee,
          id: 'payee:$k',
          text: label(k),
          match: 'payee',
          category: payees[k],
          categoryLabel: table.label(payees[k]!),
          tags: tagsFor(k)),
    for (final p in st.patternRules)
      RuleView(
          kind: RuleKind.pattern,
          id: p.id,
          text: p.pattern,
          match: p.match,
          minCents: p.minCents,
          maxCents: p.maxCents,
          category: p.category,
          categoryLabel: table.label(p.category),
          order: p.order),
    for (final k in tagOnly) RuleView(kind: RuleKind.payeeTags, id: 'payeeTags:$k', text: label(k), match: 'payee', tags: tagsFor(k)),
    for (final (i, (c, re)) in builtInMerchantRules.indexed)
      RuleView(
          kind: RuleKind.builtIn,
          id: 'builtIn:$i',
          text: re.pattern,
          match: MerchantPattern.regex,
          category: c,
          categoryLabel: table.label(c),
          order: i,
          editable: false),
  ];
}

/// How many live rows in [currency] each rule decided the main tag of ([Categorizer.ruleFor]): rule id → count. Rows
/// no rule decided (an item override, a hint, a bank rule, the fallback) are not counted. Run it with a categorizer
/// built from an edited rule set to preview an edit. Pure.
Map<String, int> ruleHits(List<Tx> rows, Categorizer cz, {required String currency}) {
  final out = <String, int>{};
  for (final t in rows) {
    if (!t.live || t.currency != currency) continue;
    if (cz.ruleFor(t) case final id?) out[id] = (out[id] ?? 0) + 1;
  }
  return out;
}

/// A payee rule to offer (Q6; never made on its own): the owner put [count] of [merchantKey]'s newest bank rows in
/// [category] by hand. [merchantName] is the newest row's name ([merchantName]), for display.
class RuleSuggestion {
  final String merchantKey;
  final String merchantName;
  final String category;
  final int count;
  const RuleSuggestion(this.merchantKey, this.merchantName, this.category, this.count);

  @override
  bool operator ==(Object other) =>
      other is RuleSuggestion &&
      other.merchantKey == merchantKey &&
      other.merchantName == merchantName &&
      other.category == category &&
      other.count == count;

  @override
  int get hashCode => Object.hash(merchantKey, merchantName, category, count);

  @override
  String toString() => 'RuleSuggestion($count)';
}

/// Bank rows of one payee [ruleSuggestions] looks at: its newest ones.
const _suggestWindow = 5;

/// A bank row a payee rule could decide: live and not hand-added.
bool _bankRow(Tx t) => t.live && !t.manual && t.source != 'manual';

/// Payee rules to suggest (Q6): per payee key ([merchantKey]) of the live bank rows in [rows] (not hand-added) that has
/// no payee rule ([Categorizer.merchantRules]) and is not in [off] (dismissed keys), the category the owner set by hand
/// ([Tx.category], a live one; a sync duplicate counts for its original) on at least [min] of its newest 5 bank rows
/// (date, then id, descending; the newest row of a tie wins). A payee rule decides only rows whose automatic main tag is
/// a flex or fixed one (`Categorizer.categoryOf`), and making one clears the rows' own choice, so a payee is never offered
/// when one of those agreeing rows is not such a row. The amount is never looked at. Most rows first, then the name
/// (folded), then the key. Pure: nothing is written.
List<RuleSuggestion> ruleSuggestions(List<Tx> rows, Categorizer c, {int min = 3, Set<String> off = const {}}) {
  final byKey = <String, List<Tx>>{};
  for (final t in rows) {
    if (!_bankRow(t)) continue;
    final k = merchantKey(t);
    if (off.contains(k) || c.merchantRules.containsKey(k)) continue;
    byKey.putIfAbsent(k, () => []).add(t);
  }
  final out = [
    for (final MapEntry(key: k, value: list) in byKey.entries)
      if (_suggestionFor(k, list, c, min) case final s?) s
  ]..sort((a, b) {
      var d = b.count.compareTo(a.count);
      if (d == 0) d = foldText(a.merchantName).compareTo(foldText(b.merchantName));
      return d != 0 ? d : a.merchantKey.compareTo(b.merchantKey);
    });
  return out;
}

/// The [ruleSuggestions] entry for [t]'s payee, for the "Always put X in Y?" prompt after the owner sets one row's main
/// tag; null when there is none (a hand-added row, a payee with a rule or in [off], too few agreeing rows). [t] stands
/// in for its own row in [rows] (so the edited row can be passed before the list is read again).
RuleSuggestion? ruleSuggestionFor(Tx t, List<Tx> rows, Categorizer c, {int min = 3, Set<String> off = const {}}) {
  if (!_bankRow(t)) return null;
  final k = merchantKey(t);
  if (off.contains(k) || c.merchantRules.containsKey(k)) return null;
  final list = [
    t,
    for (final r in rows)
      if (r.id != t.id && _bankRow(r) && merchantKey(r) == k) r
  ];
  return _suggestionFor(k, list, c, min);
}

/// [ruleSuggestions]' rule for the bank rows [list] of payee [key] (sorted here).
RuleSuggestion? _suggestionFor(String key, List<Tx> list, Categorizer c, int min) {
  final need = min < 1 ? 1 : min;
  if (list.length < need) return null;
  list.sort((a, b) {
    final d = b.date.compareTo(a.date);
    return d != 0 ? d : b.id.compareTo(a.id);
  });
  final last = list.length > _suggestWindow ? list.sublist(0, _suggestWindow) : list;
  final table = c.table;
  String? own(Tx t) {
    final o = t.category;
    return o == null || !table.isLive(o) ? null : table.duplicateOf(o) ?? o;
  }

  final count = <String, int>{};
  final newest = <String, int>{};
  for (final (i, t) in last.indexed) {
    final id = own(t);
    if (id == null) continue;
    count[id] = (count[id] ?? 0) + 1;
    newest.putIfAbsent(id, () => i);
  }
  String? best;
  for (final id in count.keys) {
    final b = best;
    if (b == null || count[id]! > count[b]! || (count[id] == count[b] && newest[id]! < newest[b]!)) best = id;
  }
  if (best == null || count[best]! < need) return null;
  for (final t in last) {
    if (own(t) != best) continue;
    final k = table.kindOf(c.autoCategory(t));
    if (k != BudgetKind.flex && k != BudgetKind.fixed) return null;
  }
  return RuleSuggestion(key, merchantName(last.first), best, count[best]!);
}
