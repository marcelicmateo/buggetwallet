import 'package:wallet_importer/wallet_importer.dart' show TxKind, csvSourcePrefix;

import 'cols.dart';
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

/// The columns of the synced entity `category` (table `categories`), in table order ([Col]; see `BillCols`).
abstract final class CategoryCols {
  static const entity = 'category';
  static const name = TextCol(entity, 'name', label: 'Name', searchable: true, maxLength: CategoryRow.maxName);
  static const kind = EnumCol(entity, 'kind', label: 'Kind', values: BudgetKind.values); // '' or unknown = not known yet
  static const parent = RefCol(entity, 'parent', label: 'Parent', target: entity, nullable: true); // read, unused (T1)
  static const position = IntCol(entity, 'position', label: 'Position', nullable: true);
  static const hidden = FlagCol(entity, 'hidden', label: 'Hidden');
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');

  static const all = <Col>[name, kind, parent, position, hidden, deleted];
}

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
        name: CategoryCols.name.read(r) ?? '',
        kind: CategoryCols.kind.read(r),
        parent: switch (CategoryCols.parent.read(r)) { final p? when p.isNotEmpty => p, _ => null },
        position: CategoryCols.position.read(r),
        hidden: CategoryCols.hidden.read(r)!,
        deleted: CategoryCols.deleted.read(r)!,
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

/// One built-in merchant rule (UX-A): a well-known chain or brand, [slug] its stable id (`builtIn:<slug>`, [id]: never
/// renamed or reused, because the owner's edits of it are stored under it), the built-in [category] and [pattern] (a
/// regex over the lower-cased, trimmed description). The owner can change both or turn it off
/// (`WalletSettings.builtInRuleOverrides`); an app update that changes a rule does not touch one the owner edited.
class BuiltInRule {
  final String slug;
  final String category;
  final String pattern;
  final RegExp re;
  BuiltInRule(this.slug, this.category, this.pattern) : re = RegExp(pattern);

  String get id => '$builtInRulePrefix$slug';
}

/// The prefix of a built-in rule's id (`builtIn:lidl`).
const builtInRulePrefix = 'builtIn:';

/// Built-in rules: well-known chains and brands only, one rule each, in match order (the first that matches wins; the
/// category groups keep the order the grouped rules had before UX-A). Personal merchants live in settings
/// (merchantPatterns) so nobody's habits end up in the code.
final List<BuiltInRule> builtInRules = List.unmodifiable([
  BuiltInRule('wolt', 'Food delivery', r'wolt'),
  BuiltInRule('bolt-food', 'Food delivery', r'bolt food'),
  BuiltInRule('glovo', 'Food delivery', r'glovo'),
  BuiltInRule('netflix', 'Bills & subscriptions', r'netflix'),
  BuiltInRule('spotify', 'Bills & subscriptions', r'spotify'),
  BuiltInRule('1password', 'Bills & subscriptions', r'1password'),
  BuiltInRule('anthropic', 'Bills & subscriptions', r'anthropic'),
  BuiltInRule('linkedin', 'Bills & subscriptions', r'linkedin'),
  BuiltInRule('proton', 'Bills & subscriptions', r'proton'),
  BuiltInRule('telekom', 'Bills & subscriptions', r'telekom'),
  BuiltInRule('a1', 'Bills & subscriptions', r'\ba1\b'),
  BuiltInRule('hbo', 'Bills & subscriptions', r'hbo'),
  BuiltInRule('disney', 'Bills & subscriptions', r'disney'),
  BuiltInRule('youtube', 'Bills & subscriptions', r'youtube'),
  BuiltInRule('icloud', 'Bills & subscriptions', r'icloud'),
  BuiltInRule('openai', 'Bills & subscriptions', r'openai'),
  BuiltInRule('chatgpt', 'Bills & subscriptions', r'chatgpt'),
  BuiltInRule('google', 'Bills & subscriptions', r'^google$'),
  BuiltInRule('steam', 'Games & apps', r'steam'),
  BuiltInRule('valve', 'Games & apps', r'valve'),
  BuiltInRule('google-play', 'Games & apps', r'google play'),
  BuiltInRule('playstation', 'Games & apps', r'playstation'),
  BuiltInRule('nintendo', 'Games & apps', r'nintendo'),
  BuiltInRule('epic-games', 'Games & apps', r'epic games'),
  BuiltInRule('spar', 'Groceries', r'\bspar'),
  BuiltInRule('lidl', 'Groceries', r'lidl'),
  BuiltInRule('plodine', 'Groceries', r'plodine'),
  BuiltInRule('kaufland', 'Groceries', r'kaufland'),
  BuiltInRule('konzum', 'Groceries', r'konzum'),
  BuiltInRule('studenac', 'Groceries', r'studenac'),
  BuiltInRule('tommy', 'Groceries', r'tommy'),
  BuiltInRule('pan-pek', 'Groceries', r'pan-pek'),
  BuiltInRule('mlinar', 'Groceries', r'mlinar'),
  BuiltInRule('eurospin', 'Groceries', r'eurospin'),
  BuiltInRule('ribola', 'Groceries', r'ribola'),
  BuiltInRule('pekar', 'Groceries', r'pekar'),
  BuiltInRule('ina', 'Car & transport', r'\bina\b'),
  BuiltInRule('petrol', 'Car & transport', r'petrol'),
  BuiltInRule('tifon', 'Car & transport', r'tifon'),
  BuiltInRule('shell', 'Car & transport', r'shell'),
  BuiltInRule('crodux', 'Car & transport', r'crodux'),
  BuiltInRule('autocest', 'Car & transport', r'autocest'),
  BuiltInRule('e-vinjeta', 'Car & transport', r'e-vinjeta'),
  BuiltInRule('jadrolinija', 'Car & transport', r'jadrolinija'),
  BuiltInRule('getbybus', 'Car & transport', r'getbybus'),
  BuiltInRule('bolt', 'Car & transport', r'\bbolt\b'),
  BuiltInRule('uber', 'Car & transport', r'uber'),
  BuiltInRule('parking', 'Car & transport', r'parking'),
  BuiltInRule('hak', 'Car & transport', r'\bhak\b'),
  BuiltInRule('zet', 'Car & transport', r'\bzet\b'),
  BuiltInRule('flixbus', 'Car & transport', r'flixbus'),
  BuiltInRule('restoran', 'Eating out', r'restoran'),
  BuiltInRule('bistro', 'Eating out', r'bistro'),
  BuiltInRule('bar', 'Eating out', r'bar\b'),
  BuiltInRule('fast-food', 'Eating out', r'fast food'),
  BuiltInRule('mcdonald', 'Eating out', r'mcdonald'),
  BuiltInRule('pizz', 'Eating out', r'pizz'),
  BuiltInRule('grill', 'Eating out', r'grill'),
  BuiltInRule('caffe', 'Eating out', r'caffe'),
  BuiltInRule('cafe', 'Eating out', r'cafe'),
  BuiltInRule('kafi', 'Eating out', r'kafi'),
  BuiltInRule('burger', 'Eating out', r'burger'),
  BuiltInRule('kebab', 'Eating out', r'kebab'),
  BuiltInRule('sushi', 'Eating out', r'sushi'),
  BuiltInRule('konoba', 'Eating out', r'konoba'),
  BuiltInRule('pub', 'Eating out', r'\bpub\b'),
  BuiltInRule('ljekarn', 'Health & care', r'ljekarn'),
  BuiltInRule('pharm', 'Health & care', r'pharm'),
  BuiltInRule('farmac', 'Health & care', r'farmac'),
  BuiltInRule('dm', 'Health & care', r'dm drog'),
  BuiltInRule('muller', 'Health & care', r'm.ller'),
  BuiltInRule('poliklinik', 'Health & care', r'poliklinik'),
  BuiltInRule('hzzo', 'Health & care', r'hzzo'),
  BuiltInRule('decathlon', 'Sport & fitness', r'decathlon'),
  BuiltInRule('fitness', 'Sport & fitness', r'fitness'),
  BuiltInRule('gymbeam', 'Sport & fitness', r'gymbeam'),
  BuiltInRule('bauhaus', 'Home & tools', r'bauhaus'),
  BuiltInRule('pevex', 'Home & tools', r'pevex'),
  BuiltInRule('vidaxl', 'Home & tools', r'vidaxl'),
  BuiltInRule('jysk', 'Home & tools', r'jysk'),
  BuiltInRule('ikea', 'Home & tools', r'ikea'),
  BuiltInRule('emmezeta', 'Home & tools', r'emmezeta'),
  BuiltInRule('lesnina', 'Home & tools', r'lesnina'),
  BuiltInRule('links', 'Home & tools', r'\blinks'),
  BuiltInRule('chipoteka', 'Home & tools', r'chipoteka'),
  BuiltInRule('instar', 'Home & tools', r'instar'),
  BuiltInRule('mall', 'Home & tools', r'\bmall\b'),
  BuiltInRule('cyberport', 'Home & tools', r'cyberport'),
  BuiltInRule('keks-pay', 'To people', r'keks pay'),
]);

/// [builtInRules] as (category, regex) pairs, in the same order.
final List<(String, RegExp)> builtInMerchantRules = List.unmodifiable([for (final r in builtInRules) (r.category, r.re)]);

/// Before UX-A a built-in rule's id was `builtIn:<index>` into a list of 10 grouped rules (one per category); such an
/// id now names that group's first rule ([builtInRuleById]).
const _legacyBuiltInHeads = ['wolt', 'netflix', 'steam', 'spar', 'ina', 'restoran', 'ljekarn', 'decathlon', 'bauhaus', 'keks-pay'];

final Map<String, BuiltInRule> _builtInById = {for (final r in builtInRules) r.id: r};

/// The built-in rule with [id] (`builtIn:<slug>`, or an id from before UX-A, `builtIn:<index>`), or null.
BuiltInRule? builtInRuleById(String id) {
  if (_builtInById[id] case final r?) return r;
  if (!id.startsWith(builtInRulePrefix)) return null;
  final n = id.substring(builtInRulePrefix.length);
  final i = int.tryParse(n);
  if (i == null || i < 0 || i >= _legacyBuiltInHeads.length || '$i' != n) return null;
  return _builtInById['$builtInRulePrefix${_legacyBuiltInHeads[i]}'];
}

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

  /// Ids of the payments the owner linked to an IOU (Q8, `WalletRepoIou.iouLinkedTx`, read once). Such a row keeps its
  /// main tag (shown as before) but counts as [BudgetKind.transfer] in [categorize] and [expand]: money lent or paid
  /// back is neither spending nor income, so every total that leaves transfers out (`computePeriod`, `monthSummary`,
  /// `periodSummaries`, `countsAsSpending`, insights, budget vs actual, recurring detection, reports) leaves it out,
  /// while account balances (raw rows) still count it. A split on such a row is ignored, as on a transfer. Empty: none.
  final Set<String> iouTx;

  /// [patternRules] (P7, [WalletSettings.patternRules]) are the personal patterns with their match kind and range; when
  /// null, [patterns] (`[category, regex]` pairs, [WalletSettings.merchantPatterns]) are used as regex patterns.
  factory Categorizer(
      {Map<String, String> merchantRules = const {},
      List<List<String>> patterns = const [],
      List<MerchantPattern>? patternRules,
      int rentCashThreshold = defaultRentCashThreshold,
      CategoryTable? table,
      TagContext? tagContext,
      Map<String, List<SplitPart>> splits = const {},
      Set<String> iouTx = const {},
      Map<String, BuiltInRuleOverride> builtInOverrides = const {}}) {
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
    return Categorizer._(merchantRules, used, rentCashThreshold, t, tagContext, splits, iouTx, _effectiveBuiltIns(builtInOverrides, t));
  }

  Categorizer._(
      this.merchantRules, this._patterns, this.rentCashThreshold, this.table, this.tagContext, this.splits, this.iouTx, this._builtIns)
      : userPatterns = List.unmodifiable([for (final p in _patterns) (p.rule.category, p.rule)]);

  /// The built-in rules in use, in [builtInRules] order: (id, category, regex) after the owner's overrides.
  final List<(String, String, RegExp)> _builtIns;

  /// [builtInRules] with [overrides] applied (UX-A): an off rule is left out; an edited pattern is matched case-blind like
  /// a personal regex (one that does not compile or matches everything keeps the built-in pattern, logged as
  /// `categories.badPattern`); an edited category that is not live in [t] keeps the built-in category.
  static List<(String, String, RegExp)> _effectiveBuiltIns(Map<String, BuiltInRuleOverride> overrides, CategoryTable t) {
    if (overrides.isEmpty) return [for (final r in builtInRules) (r.id, r.category, r.re)];
    final out = <(String, String, RegExp)>[];
    for (final r in builtInRules) {
      final o = overrides[r.id];
      if (o == null) {
        out.add((r.id, r.category, r.re));
        continue;
      }
      if (o.off) continue;
      var re = r.re;
      if (o.pattern case final p?) {
        try {
          final x = RegExp(p, caseSensitive: false);
          if (MerchantPattern.matchesEverything(x)) {
            logEvent(_log, Level.WARNING, 'categories.badPattern', {'builtIn': true, 'matchesAll': true});
          } else {
            re = x;
          }
        } on FormatException catch (e) {
          logEvent(_log, Level.WARNING, 'categories.badPattern', {'builtIn': true, 'offset': e.offset});
        }
      }
      final c = o.category != null && t.isLive(o.category!) ? o.category! : r.category;
      out.add((r.id, c, re));
    }
    return out;
  }

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

  /// [merchantCategory] with the id of the rule that matched: the pattern row id, or `builtIn:<slug>`.
  (String, String)? _matchText(String description, int? amount) {
    final s = description.toLowerCase().trim();
    String? folded;
    for (final p in _patterns) {
      final r = p.rule;
      if (r.hasRange && (amount == null || !r.inRange(amount))) continue;
      final hit = p.re?.hasMatch(s) ?? (folded ??= foldText(s)).contains(p.folded!);
      if (hit) return (r.category, r.id);
    }
    for (final (id, c, re) in _builtIns) {
      if (re.hasMatch(s)) return (c, id);
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
      case final s when s.startsWith(csvSourcePrefix):
        // A mapped CSV (P12) says nothing about the row's kind: money in is extra income (like PBZ's unknown inflows,
        // never a refund that lowers spending), money out goes by the owner's patterns and the built-in rules.
        if (t.amount > 0) return ('Extra income', null);
        return _matchText(d, t.amount) ?? ('Shopping', null);
      default:
        // Hand-added and unknown-source rows: their stored category if it is a live one, else Shopping.
        final c = t.category;
        return (c != null && table.isLive(c) ? c : 'Shopping', null);
    }
  }

  String categoryOf(Tx t) => _decide(t).$1;

  /// The id of the rule that decided [t]'s main tag ([categoryOf]): `payee:<merchantKey>` for a payee rule, the
  /// pattern row id `pattern:<16 hex>`, `builtIn:<slug>` ([BuiltInRule.id]); null when no rule did (an item
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
    return CategorizedTx(t, c, kindFor(t, c), tags: tagContext?.of(t) ?? const [], iou: iouTx.contains(t.id));
  }

  /// The budget kind of [t] with main tag [category]: [BudgetKind.transfer] when the owner linked it to an IOU
  /// ([iouTx]), else the tag's kind.
  BudgetKind kindFor(Tx t, String category) => iouTx.contains(t.id) ? BudgetKind.transfer : table.kindOf(category);

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
      return [CategorizedTx(t, whole.category, whole.kind, tags: whole.tags, splitBroken: true, iou: whole.iou)];
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
  s = s.replaceFirst(_pbzPos, '').replaceFirst(_pos, '');
  s = s.replaceAll(_spaces2, ' ').trim();
  return s.isEmpty ? '(no description)' : s;
}

// Compiled once: merchantKey runs per row in many passes (findings, projects, recurring).
final _pbzPos = RegExp(r'^PBZ POS PBZ\w', caseSensitive: false);
final _pos = RegExp(r'^POS ', caseSensitive: false);
final _spaces2 = RegExp(r'\s{2,}');
final _digits = RegExp(r'[0-9*#]+');
final _nonLetters = RegExp(r'[^a-zÀ-ɏ ]+');
final _spaces = RegExp(r'\s+');
final _edgeUnderscore = RegExp(r'^_|_$');

/// Stable key for "always use this category for this merchant". Same as v1.
String merchantKey(Tx t) {
  var s = merchantName(t).toLowerCase();
  s = s.replaceAll(_digits, ' ');
  s = s.replaceAll(_nonLetters, ' ');
  s = s.replaceAll(_spaces, '_').replaceAll(_edgeUnderscore, '');
  if (s.length > 40) s = s.substring(0, 40);
  return s.isEmpty ? 'x' : s;
}
