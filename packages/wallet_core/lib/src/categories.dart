import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'logs.dart';
import 'models.dart';
import 'rules.dart' show MerchantPattern, merchantPatternId;
import 'search.dart' show foldText;
import 'splits.dart' show SplitPart, splitFits;
import 'tags.dart' show TagContext, TagTable;

final _log = Logger('bw.categories');

/// What a category means to the budget: income, extra (one-offs outside the plan), fixed, flex, or an own transfer.
enum BudgetKind { income, extra, fixed, flex, transfer }

/// Category name -> kind. Same names as the v1 web app.
const Map<String, BudgetKind> categories = {
  'Salary': BudgetKind.income,
  'Extra income': BudgetKind.extra,
  'Rent': BudgetKind.fixed,
  'Loan': BudgetKind.fixed,
  'Bills & subscriptions': BudgetKind.fixed,
  'Groceries': BudgetKind.flex,
  'Food delivery': BudgetKind.flex,
  'Eating out': BudgetKind.flex,
  'Car & transport': BudgetKind.flex,
  'Shopping': BudgetKind.flex,
  'Home & tools': BudgetKind.flex,
  'Sport & fitness': BudgetKind.flex,
  'Health & care': BudgetKind.flex,
  'Games & apps': BudgetKind.flex,
  'Cash': BudgetKind.flex,
  'Bills & one-offs': BudgetKind.flex,
  'To people': BudgetKind.flex,
  'Bank fees': BudgetKind.flex,
  'Internal transfer': BudgetKind.transfer,
  'Loan received': BudgetKind.transfer,
};

List<String> get flexCategories => [
      for (final e in categories.entries)
        if (e.value == BudgetKind.flex) e.key
    ];

/// Categories money goes out through (fixed and flex): the ones a monthly budget can be set for.
List<String> get spendingCategories => [
      for (final e in categories.entries)
        if (e.value == BudgetKind.fixed || e.value == BudgetKind.flex) e.key
    ];

/// Whether [category] is a built-in spending category (see [spendingCategories]).
bool isSpendingCategory(String category) => switch (categories[category]) { BudgetKind.fixed || BudgetKind.flex => true, _ => false };

BudgetKind kindOf(String category) => categories[category] ?? BudgetKind.flex;

/// One row of the synced `category` entity (P1, schema 10; table `categories`). A row whose [id] is a built-in name
/// ([categories]) is an *override* of that built-in: only [name] (the label; empty = the built-in name), [hidden] and
/// [position] count. Any other id (`k` + 12 hex) is a custom category of [kind]. [parent] is read but unused: P1's
/// subcategories were replaced by tags (T1), so every row is top-level and new writes refuse a parent.
class CategoryRow {
  final String id;
  final String name;

  /// Null when the stored kind is empty or unknown (a row whose `kind` field has not arrived yet, or an override):
  /// such a custom row is not live until its kind is known.
  final BudgetKind? kind;
  final String? parent;

  /// Sort order among siblings (≥ 0); null = the default (a built-in's index in [categories], a custom one last).
  final int? position;
  final bool hidden;
  final bool deleted;

  const CategoryRow(
      {required this.id,
      this.name = '',
      this.kind = BudgetKind.flex,
      this.parent,
      this.position,
      this.hidden = false,
      this.deleted = false});

  /// Longest label (characters, after trimming).
  static const maxName = 40;

  /// Most live custom categories a wallet may hold (deleted rows do not count; `undeleteCategory` checks it too).
  static const maxCustom = 200;

  /// Whether this row overrides a built-in category.
  bool get isOverride => categories.containsKey(id);

  /// A custom row that counts: not deleted and with a known [kind].
  bool get isLiveCustom => !isOverride && !deleted && kind != null;

  static CategoryRow fromRow(Map<String, Object?> r) => CategoryRow(
        id: r['id'] as String,
        name: r['name'] is String ? r['name'] as String : '',
        kind: BudgetKind.values.asNameMap()[r['kind']],
        parent: r['parent'] is String && (r['parent'] as String).isNotEmpty ? r['parent'] as String : null,
        position: r['position'] is int ? r['position'] as int : null,
        hidden: r['hidden'] == 1,
        deleted: r['deleted'] == 1,
      );
}

/// The built-in categories plus the owner's own ones and overrides ([CategoryRow]), resolved once. Pure; with no rows
/// ([builtIn]) every answer is the built-in globals' ([categories], [kindOf], [spendingCategories]).
///
/// Every category is top-level (T1: subcategories were replaced by tags): a stored `parent` is ignored, so an old
/// child counts as its own main tag with its own kind. [parentOf] is always null, [topLevel] the id itself and
/// [childrenOf] empty. Of two live categories with the same folded label ([foldText]), one is the original and the
/// other [duplicateOf] it: a built-in first, then the smallest id (the same answer on every device).
class CategoryTable {
  /// The rows it was built from, as given.
  final List<CategoryRow> rows;
  final Map<String, CategoryRow> _custom = {};
  final Map<String, CategoryRow> _override = {};
  final List<String> _top = [];
  final Map<String, String> _dup = {};

  /// Only the built-in categories, unchanged.
  static final CategoryTable builtIn = CategoryTable.from(const []);

  static final List<String> _builtInOrder = categories.keys.toList();
  static const _noPosition = 1 << 30;

  CategoryTable.from(List<CategoryRow> rows) : rows = List.unmodifiable(rows) {
    for (final r in rows) {
      (r.isOverride ? _override : _custom)[r.id] = r;
    }
    int order(String a, String b) {
      var d = position(a).compareTo(position(b));
      if (d == 0) d = foldText(label(a)).compareTo(foldText(label(b)));
      return d != 0 ? d : a.compareTo(b);
    }

    _top.addAll([
      ..._builtInOrder,
      for (final r in _custom.values)
        if (r.isLiveCustom) r.id
    ]);
    _top.sort(order);
    _markDuplicates(_top);
  }

  /// Within one sibling list: each folded label's original is a built-in (lowest index) or else the smallest id.
  void _markDuplicates(List<String> ids) {
    int rank(String a, String b) {
      final ia = _builtInOrder.indexOf(a), ib = _builtInOrder.indexOf(b);
      if (ia >= 0 || ib >= 0) return ia < 0 ? 1 : (ib < 0 ? -1 : ia.compareTo(ib));
      return a.compareTo(b);
    }

    final first = <String, String>{};
    for (final id in [...ids]..sort(rank)) {
      final key = foldText(label(id).trim());
      final have = first[key];
      if (have == null) {
        first[key] = id;
      } else {
        _dup[id] = have;
      }
    }
  }

  /// The label shown for [id]: an override's or custom row's name, else the built-in name; an unknown id itself.
  String label(String id) {
    final n = (_override[id] ?? _custom[id])?.name.trim() ?? '';
    return n.isEmpty ? id : n;
  }

  /// The built-in kind or a custom row's own kind. Unknown: flex.
  BudgetKind kindOf(String id) => categories[id] ?? _custom[id]?.kind ?? BudgetKind.flex;

  /// Always null: every category is top-level (T1).
  String? parentOf(String id) => null;

  /// [id] itself: every category is top-level (T1).
  String topLevel(String id) => id;

  /// Always empty: every category is top-level (T1).
  List<String> childrenOf(String id) => const <String>[];

  /// A built-in, or a custom row that is not deleted.
  bool isLive(String id) => categories.containsKey(id) || (_custom[id]?.isLiveCustom ?? false);

  /// Whether [id]'s stored parent (an old P1 row's `parent`, ignored since T1) is a live category other than itself.
  bool hasLiveStoredParent(String id) {
    final p = _custom[id]?.parent;
    return p != null && p != id && isLive(p);
  }

  /// A custom id that is not live here: deleted, half-arrived, or not synced yet (a `k` + 12 hex id with no row).
  /// Rows, bills and planned costs pointing at one fall back when read; nothing is written for it.
  bool isDeadCustom(String id) => !isLive(id) && (isCustom(id) || _customId.hasMatch(id));
  static final _customId = RegExp(r'^k[0-9a-f]{12}$');

  /// A live top-level custom category of kind fixed: it has a plan line (`WalletSettings.planLines`, `plan:<id>`).
  bool hasPlanLine(String id) => isCustom(id) && isLive(id) && kindOf(id) == BudgetKind.fixed;

  /// The ids with a plan line ([hasPlanLine]), in order.
  List<String> get planLineIds => [
        for (final t in _top)
          if (hasPlanLine(t)) t
      ];

  /// Whether a bill or planned cost in [id] is already in the payday plan: [id] is live and fixed (Rent, Loan, Bills &
  /// subscriptions, or a custom fixed category with its plan line).
  bool coveredByPlan(String id) => isLive(id) && kindOf(id) == BudgetKind.fixed;

  /// The sort position: a stored one, else a built-in's index in [categories]; a custom row without
  /// one sorts last (a large value).
  int position(String id) =>
      categories.containsKey(id) ? (_override[id]?.position ?? _builtInOrder.indexOf(id)) : (_custom[id]?.position ?? _noPosition);

  /// Hidden from pickers (existing rows still show it).
  bool isHidden(String id) => (_override[id] ?? _custom[id])?.hidden ?? false;

  /// Whether [id] is a custom id (deleted or not).
  bool isCustom(String id) => _custom.containsKey(id);

  /// The original of a sync duplicate (same folded label among live categories), or null.
  String? duplicateOf(String id) => _dup[id];

  /// The live top-level ids in order (hidden and duplicate ones included).
  List<String> get topLevelIds => List.unmodifiable(_top);

  /// What a picker offers: live, not hidden, not a duplicate, of one of [kinds] (all when null), in order.
  List<String> pickable({Set<BudgetKind>? kinds}) => [
        for (final t in _top)
          if (!isHidden(t) && !_dup.containsKey(t) && (kinds == null || kinds.contains(kindOf(t)))) t
      ];

  /// The live fixed and flex top-level ids, in order: the categories a budget can be set for and the CSV columns.
  List<String> get spending => [
        for (final t in _top)
          if (_spendingKind(kindOf(t))) t
      ];

  /// A live category money goes out through (fixed or flex).
  bool isSpending(String id) => isLive(id) && _spendingKind(kindOf(id));

  static bool _spendingKind(BudgetKind k) => k == BudgetKind.fixed || k == BudgetKind.flex;
}

/// [byCategory] with each id's sum under [CategoryTable.topLevel]: since T1 every category is top-level, so the result
/// equals the input (kept for callers written for P1's subcategories).
Map<String, int> rollUp(Map<String, int> byCategory, CategoryTable t) {
  final out = <String, int>{};
  for (final MapEntry(:key, :value) in byCategory.entries) {
    final k = t.topLevel(key);
    out[k] = (out[k] ?? 0) + value;
  }
  return out;
}

/// Built-in rules: well-known chains and brands only. Personal merchants live in
/// settings (merchantPatterns) so nobody's habits end up in the code.
final List<(String, RegExp)> builtInMerchantRules = [
  ('Food delivery', RegExp(r'wolt|bolt food|glovo')),
  (
    'Bills & subscriptions',
    RegExp(r'netflix|spotify|1password|anthropic|linkedin|proton|telekom|\ba1\b|hbo|disney|youtube|icloud|openai|chatgpt|^google$')
  ),
  ('Games & apps', RegExp(r'steam|valve|google play|playstation|nintendo|epic games')),
  ('Groceries', RegExp(r'\bspar|lidl|plodine|kaufland|konzum|studenac|tommy|pan-pek|mlinar|eurospin|ribola|pekar')),
  (
    'Car & transport',
    RegExp(r'\bina\b|petrol|tifon|shell|crodux|autocest|e-vinjeta|jadrolinija|getbybus|\bbolt\b|uber|parking|\bhak\b|\bzet\b|flixbus')
  ),
  ('Eating out', RegExp(r'restoran|bistro|bar\b|fast food|mcdonald|pizz|grill|caffe|cafe|kafi|burger|kebab|sushi|konoba|\bpub\b')),
  ('Health & care', RegExp(r'ljekarn|pharm|farmac|dm drog|m.ller|poliklinik|hzzo')),
  ('Sport & fitness', RegExp(r'decathlon|fitness|gymbeam')),
  ('Home & tools', RegExp(r'bauhaus|pevex|vidaxl|jysk|ikea|emmezeta|lesnina|\blinks|chipoteka|instar|\bmall\b|cyberport')),
  ('To people', RegExp(r'keks pay')),
];

/// Default for the `rentCashThreshold` setting (minor units).
const int defaultRentCashThreshold = 50000;

/// Revolut's `Type` wording for a currency conversion between the owner's own balances (`bankType` of such rows). The
/// one bank wording wallet_core keys on besides the importer's hints: the category rule below and
/// `WalletRepo._migrate` (schema 4 rewrites the earlier build's `ownTransfer` hint on these rows to `exchange`).
const revolutExchangeType = 'Exchange';

/// A user pattern ready to match: its regex, or its folded `contains` text.
class _UserPattern {
  final MerchantPattern rule;
  final RegExp? re;
  final String? folded;
  const _UserPattern(this.rule, this.re, this.folded);
}

/// Resolves categories. Built once per settings/rules change.
class Categorizer {
  final Map<String, String> merchantRules; // merchantKey -> category

  /// The personal patterns in use (live category, valid text), in match order: (category, rule).
  final List<(String, MerchantPattern)> userPatterns;
  final List<_UserPattern> _patterns;

  /// ATM withdrawals of at least this much (minor units, positive) count as rent (setting `rentCashThreshold`).
  final int rentCashThreshold;

  /// The categories rows resolve against: an override, rule or pattern naming an id that is not live here (a deleted
  /// or unknown custom category) is ignored, so the row falls back as if it had none (P1 §3; nothing is rewritten).
  final CategoryTable table;

  /// The tag tables [categorize] fills [CategorizedTx.tags] from (T1; `WalletRepo.tagContext`, read once). Null: no tags.
  final TagContext? tagContext;

  /// Tx id → its live split's parts (P6, `WalletRepoSplits.splits`, read once), for [expand]. Empty: no splits.
  final Map<String, List<SplitPart>> splits;

  /// [patternRules] (P7, [WalletSettings.patternRules]) are the personal patterns with their match kind and range; when
  /// null, [patterns] (`[category, regex]` pairs, [WalletSettings.merchantPatterns]) are used as regex patterns.
  factory Categorizer(
      {Map<String, String> merchantRules = const {},
      List<List<String>> patterns = const [],
      List<MerchantPattern>? patternRules,
      int rentCashThreshold = defaultRentCashThreshold,
      CategoryTable? table,
      TagContext? tagContext,
      Map<String, List<SplitPart>> splits = const {}}) {
    final t = table ?? CategoryTable.builtIn;
    final rules = patternRules ??
        [
          for (final (i, p) in patterns.indexed) MerchantPattern(id: merchantPatternId(p[1]), category: p[0], pattern: p[1], order: i),
        ];
    final used = <_UserPattern>[
      for (final r in rules)
        if (t.isLive(r.category))
          if (_compile(r) case final u?) u,
    ];
    // Counts only: merchant rules and patterns are personal.
    logEvent(_log, Level.FINE, 'categories.build', {'rules': merchantRules.length, 'patterns': rules.length, 'patternsUsed': used.length});
    return Categorizer._(merchantRules, used, rentCashThreshold, t, tagContext, splits);
  }

  Categorizer._(this.merchantRules, this._patterns, this.rentCashThreshold, this.table, this.tagContext, this.splits)
      : userPatterns = List.unmodifiable([for (final p in _patterns) (p.rule.category, p.rule)]);

  /// A pattern ready to match, or null (logged as `categories.badPattern`) when its text is empty (only spaces
  /// included: an empty pattern would match every merchant), a regex does not compile or matches the empty text
  /// ([MerchantPattern.matchesEverything]), or `contains` is too long. A range on a regex is dropped.
  static _UserPattern? _compile(MerchantPattern r) {
    final s = r.pattern;
    if (s.trim().isEmpty) {
      logEvent(_log, Level.WARNING, 'categories.badPattern', {'empty': true, 'length': s.length});
      return null;
    }
    if (r.match == MerchantPattern.contains) {
      final f = foldText(s.trim());
      if (f.isEmpty || s.trim().length > MerchantPattern.maxContainsLength) {
        logEvent(_log, Level.WARNING, 'categories.badPattern', {'match': r.match, 'length': s.length});
        return null;
      }
      return _UserPattern(r, null, f);
    }
    try {
      final re = RegExp(s, caseSensitive: false);
      if (MerchantPattern.matchesEverything(re)) {
        logEvent(_log, Level.WARNING, 'categories.badPattern', {'matchesAll': true, 'length': s.length});
        return null;
      }
      if (r.hasRange) {
        // A range only narrows a `contains` rule: on a regex it is dropped, the rule kept.
        logInvalidSetting('merchantPatterns', 'range');
        return _UserPattern(MerchantPattern(id: r.id, category: r.category, pattern: s, order: r.order), re, null);
      }
      return _UserPattern(r, re, null);
    } on FormatException catch (e) {
      // Not the error text: a RegExp error can quote the pattern, which names personal merchants.
      logEvent(_log, Level.WARNING, 'categories.badPattern', {'offset': e.offset, 'length': s.length});
      return null;
    }
  }

  /// The category for merchant text, from personal patterns then built-in rules; null if none matches. The text is
  /// lower-cased and trimmed first, so `'Google '` matches `^google$`; a `contains` pattern looks in the folded text
  /// ([foldText]). A pattern with an amount range matches only when [amount] is given and in range.
  String? merchantCategory(String description, {int? amount}) => _matchText(description, amount)?.$1;

  /// [merchantCategory] with the id of the rule that matched: the pattern row id, or `builtIn:<index>`.
  (String, String)? _matchText(String description, int? amount) {
    final s = description.toLowerCase().trim();
    String? folded;
    for (final p in _patterns) {
      final r = p.rule;
      if (r.hasRange && (amount == null || !r.inRange(amount))) continue;
      final hit = p.re?.hasMatch(s) ?? (folded ??= foldText(s)).contains(p.folded!);
      if (hit) return (r.category, r.id);
    }
    for (final (i, (c, re)) in builtInMerchantRules.indexed) {
      if (re.hasMatch(s)) return (c, 'builtIn:$i');
    }
    return null;
  }

  /// The built-in category of a bank row, before the user's per-merchant rules ([categoryOf]).
  ///
  /// A row paired with its other side ([Tx.transferTo]) is an `Internal transfer`. Then the importer's [Tx.kindHint]
  /// decides where it can: `salary` → Salary (every employer payment), `atm` → Rent when the withdrawal is at least
  /// [rentCashThreshold], else Cash, `fee` → Bank fees, `ownTransfer` and `exchange` → Internal transfer. `standingOrder` says how the
  /// bank paid, not what for, and `card`, `other` and no hint fall through to the per-source rules below (built-in
  /// merchant patterns and the `merchantPatterns` setting through [merchantCategory]).
  String autoCategory(Tx t) => _auto(t).$1;

  /// [autoCategory] with the id of the pattern or built-in rule that decided it, if one did.
  (String, String?) _auto(Tx t) {
    if (t.transferTo != null) return ('Internal transfer', null);
    switch (t.kindHint) {
      case TxKind.salary:
        return ('Salary', null);
      case TxKind.atm:
        return (rentCashThreshold > 0 && t.amount <= -rentCashThreshold ? 'Rent' : 'Cash', null);
      case TxKind.fee:
        return ('Bank fees', null);
      case TxKind.ownTransfer || TxKind.exchange:
        return ('Internal transfer', null);
      case TxKind.standingOrder || TxKind.card || TxKind.other || null:
        break;
    }
    final d = t.description.toLowerCase();
    final type = t.bankType;
    switch (t.source) {
      case 'revolut':
        if (type == 'Topup' || type == revolutExchangeType) return ('Internal transfer', null);
        if (type == 'Transfer') return ('To people', null);
        return _matchText(d, t.amount) ?? ('Shopping', null);
      case 'pbz':
        if (d.contains('revolut')) return ('Internal transfer', null);
        if (d.contains('isplata kredita')) return ('Loan received', null);
        if (type == 'Isplata u poslovnici') return ('Cash', null);
        if (type == 'Isplata ATM') return (rentCashThreshold > 0 && t.amount <= -rentCashThreshold ? 'Rent' : 'Cash', null);
        if (type == 'Naplaćene naknade' ||
            type == 'Povrat naknade' ||
            type == 'Pripisane kamate' ||
            d.contains('naknad') ||
            d.contains('članarin')) {
          return ('Bank fees', null);
        }
        if (type == 'Trajni nalog' || RegExp(r'naplata kredita|rate kredita|kreditni račun').hasMatch(d)) return ('Loan', null);
        if (type == 'Plaća/Mirovina' || d.contains('krive uplate')) return ('Salary', null);
        if (t.amount > 0) return ('Extra income', null);
        if (type == 'POS plaćanje') return _matchText(d, t.amount) ?? ('Shopping', null);
        return ('Bills & one-offs', null);
      default:
        // Hand-added and unknown-source rows: their stored category if it is a live one, else Shopping.
        final c = t.category;
        return (c != null && table.isLive(c) ? c : 'Shopping', null);
    }
  }

  String categoryOf(Tx t) => _decide(t).$1;

  /// The id of the rule that decided [t]'s main tag ([categoryOf]): `payee:<merchantKey>` for a payee rule, the
  /// pattern row id `pattern:<16 hex>`, `builtIn:<index in builtInMerchantRules>`; null when no rule did (an item
  /// override, a transfer or kind hint, a bank rule, a hand-added row's own category, the fallback).
  String? ruleFor(Tx t) => _decide(t).$2;

  (String, String?) _decide(Tx t) {
    final o = t.category;
    if (o != null && table.isLive(o)) return (o, null);
    final auto = _auto(t);
    final k = table.kindOf(auto.$1);
    if (t.source != 'manual' && (k == BudgetKind.flex || k == BudgetKind.fixed)) {
      final key = merchantKey(t);
      final r = merchantRules[key];
      if (r != null && table.isLive(r)) return (r, 'payee:$key');
    }
    return auto;
  }

  /// The category a bill, planned cost or recurring bill uses now for its stored [category] (P1 owner decision):
  /// itself, unless it is a deleted or unknown custom id ([CategoryTable.isDeadCustom]); then the automatic one: the
  /// per-merchant rule for [key] (a `merchantKey`), else the personal patterns and built-in rules on [text]
  /// ([merchantCategory]), else [orElse]. Resolved when read; nothing is written, so an undelete brings it back.
  String? resolveStored(String? category, {String? key, String text = '', String? orElse}) {
    if (category == null || !table.isDeadCustom(category)) return category;
    final r = key == null ? null : merchantRules[key];
    if (r != null && table.isLive(r)) return r;
    return merchantCategory(text) ?? orElse;
  }

  /// [t] as one row: the whole payment, whatever its split. For pickers and detection (matching, transfers, bills,
  /// recurring, paydays, balances, rule hits, tag suggestions); money by category, tag or kind uses [expand].
  CategorizedTx categorize(Tx t) {
    final c = categoryOf(t);
    return CategorizedTx(t, c, table.kindOf(c), tags: tagContext?.of(t) ?? const []);
  }

  /// The rows [t] counts as (P6): [categorize] when it has no live split in [splits] or is not live itself (a deleted
  /// row, an entry replaced by its bank row: it counts nothing, so it stays one row); else one row per part, in stored
  /// order ([CategorizedTx.part], [CategorizedTx.parts], the part's amount, main tag, tags and note). A split that no
  /// longer fits the payment ([splitFits]: its amount was edited, a synced split arrived for a changed row, or it is
  /// unreadable) is ignored: the payment counts whole and is marked [CategorizedTx.splitBroken]. A split on a payment
  /// that is now a transfer (paired as an own transfer, or its main tag is a transfer) is ignored without the mark:
  /// a transfer is never split. A part whose main tag is not live falls back to the payment's own main tag
  /// ([categoryOf], its override included: never a transfer here, P1 §3); if that is not live or is a transfer, the
  /// split is ignored as broken. Dead tags are dropped ([TagTable.resolveAll]; no [tagContext]: no tags). Each part
  /// holds the whole payment's row ([CategorizedTx.whole]). Pure: nothing is written.
  List<CategorizedTx> expand(Tx t) {
    final stored = splits[t.id];
    if (stored == null || !t.live) return [categorize(t)];
    final whole = categorize(t);
    if (t.transferTo != null || whole.kind == BudgetKind.transfer) return [whole];
    final fallbackOk = table.isLive(whole.category) && whole.kind != BudgetKind.transfer;
    if (!splitFits(t.amount, stored) || (!fallbackOk && stored.any((p) => !table.isLive(p.category)))) {
      return [CategorizedTx(t, whole.category, whole.kind, tags: whole.tags, splitBroken: true)];
    }
    final tags = tagContext?.tags;
    return [
      for (final (i, p) in stored.indexed)
        if (table.isLive(p.category) ? p.category : whole.category case final c)
          CategorizedTx(t, c, table.kindOf(c),
              tags: tags == null ? const [] : tags.resolveAll(p.tags),
              amount: p.amount,
              part: i,
              parts: stored.length,
              partNote: p.note,
              whole: whole),
    ];
  }

  /// [expand] over [txs], in order.
  List<CategorizedTx> expandAll(Iterable<Tx> txs) => [for (final t in txs) ...expand(t)];
}

/// Display name for a merchant, with bank prefixes removed.
String merchantName(Tx t) {
  if (t.source == 'manual') return t.note?.isNotEmpty == true ? t.note! : (t.category ?? 'Expense');
  var s = t.description;
  s = s.replaceFirst(RegExp(r'^PBZ POS PBZ\w', caseSensitive: false), '').replaceFirst(RegExp(r'^POS ', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return s.isEmpty ? '(no description)' : s;
}

/// Stable key for "always use this category for this merchant". Same as v1.
String merchantKey(Tx t) {
  var s = merchantName(t).toLowerCase();
  s = s.replaceAll(RegExp(r'[0-9*#]+'), ' ');
  s = s.replaceAll(RegExp(r'[^a-zÀ-ɏ ]+'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  if (s.length > 40) s = s.substring(0, 40);
  return s.isEmpty ? 'x' : s;
}
