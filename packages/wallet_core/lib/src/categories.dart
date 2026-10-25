import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'logs.dart';
import 'models.dart';
import 'search.dart' show foldText;

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
/// [position] count. Any other id (`k` + 12 hex) is a custom category of [kind], a child of [parent] when set.
class CategoryRow {
  final String id;
  final String name;
  final BudgetKind kind;
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

  /// Most custom rows (deleted ones included) a wallet may hold.
  static const maxCustom = 200;

  /// Whether this row overrides a built-in category.
  bool get isOverride => categories.containsKey(id);

  static CategoryRow fromRow(Map<String, Object?> r) => CategoryRow(
        id: r['id'] as String,
        name: r['name'] is String ? r['name'] as String : '',
        kind: BudgetKind.values.asNameMap()[r['kind']] ?? BudgetKind.flex,
        parent: r['parent'] is String && (r['parent'] as String).isNotEmpty ? r['parent'] as String : null,
        position: r['position'] is int ? r['position'] as int : null,
        hidden: r['hidden'] == 1,
        deleted: r['deleted'] == 1,
      );
}

/// The built-in categories plus the owner's own ones and overrides ([CategoryRow]), resolved once. Pure; with no rows
/// ([builtIn]) every answer is the built-in globals' ([categories], [kindOf], [spendingCategories]).
///
/// Subcategories are one level deep: a custom row's parent counts only while it is live, is not the row itself and
/// has no live parent of its own; otherwise the row is top-level with its own kind (an orphan after a sync race
/// stays visible until the owner fixes it). A child's kind is always its parent's. Of two live top-level categories
/// with the same folded label ([foldText]), or two siblings, one is the original and the other [duplicateOf] it: a
/// built-in first, then the smallest id (the same answer on every device).
class CategoryTable {
  /// The rows it was built from, as given.
  final List<CategoryRow> rows;
  final Map<String, CategoryRow> _custom = {};
  final Map<String, CategoryRow> _override = {};
  final Map<String, String> _parent = {};
  final List<String> _top = [];
  final Map<String, List<String>> _children = {};
  final Map<String, String> _dup = {};

  /// Only the built-in categories, unchanged.
  static final CategoryTable builtIn = CategoryTable.from(const []);

  static final List<String> _builtInOrder = categories.keys.toList();
  static const _noPosition = 1 << 30;

  CategoryTable.from(List<CategoryRow> rows) : rows = List.unmodifiable(rows) {
    for (final r in rows) {
      (r.isOverride ? _override : _custom)[r.id] = r;
    }
    bool live(String id) => categories.containsKey(id) || (_custom[id]?.deleted == false);
    String? rawParent(String id) => _custom[id]?.parent;
    bool hasLiveParent(String id) {
      final p = rawParent(id);
      return p != null && p != id && live(p);
    }

    for (final r in _custom.values) {
      final p = r.parent;
      if (p != null && p != r.id && live(p) && !hasLiveParent(p)) _parent[r.id] = p;
    }
    int order(String a, String b) {
      var d = position(a).compareTo(position(b));
      if (d == 0) d = foldText(label(a)).compareTo(foldText(label(b)));
      return d != 0 ? d : a.compareTo(b);
    }

    _top.addAll([
      ..._builtInOrder,
      for (final r in _custom.values)
        if (!r.deleted && !_parent.containsKey(r.id)) r.id
    ]);
    _top.sort(order);
    for (final r in _custom.values) {
      if (r.deleted) continue;
      if (_parent[r.id] case final p?) (_children[p] ??= []).add(r.id);
    }
    for (final c in _children.values) {
      c.sort(order);
    }
    _markDuplicates(_top);
    for (final c in _children.values) {
      _markDuplicates(c);
    }
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

  /// The built-in kind, a custom top-level row's own kind, or its parent's for a child. Unknown: flex.
  BudgetKind kindOf(String id) {
    if (categories[id] case final k?) return k;
    if (_parent[id] case final p?) return kindOf(p);
    return _custom[id]?.kind ?? BudgetKind.flex;
  }

  /// The parent of a child; null for a top-level, unknown or orphaned id.
  String? parentOf(String id) => _parent[id];

  /// [id]'s parent, or [id] itself when it is top-level.
  String topLevel(String id) => _parent[id] ?? id;

  /// The live children of [id], by position, then label.
  List<String> childrenOf(String id) => List.unmodifiable(_children[id] ?? const <String>[]);

  /// A built-in, or a custom row that is not deleted.
  bool isLive(String id) => categories.containsKey(id) || (_custom[id]?.deleted == false);

  /// The sort position among siblings: a stored one, else a built-in's index in [categories]; a custom row without
  /// one sorts last (a large value).
  int position(String id) =>
      categories.containsKey(id) ? (_override[id]?.position ?? _builtInOrder.indexOf(id)) : (_custom[id]?.position ?? _noPosition);

  /// Hidden from pickers (existing rows still show it).
  bool isHidden(String id) => (_override[id] ?? _custom[id])?.hidden ?? false;

  /// Whether [id] is a custom id (deleted or not).
  bool isCustom(String id) => _custom.containsKey(id);

  /// The original of a sync duplicate (same folded label among live siblings), or null.
  String? duplicateOf(String id) => _dup[id];

  /// The live top-level ids in order (hidden and duplicate ones included).
  List<String> get topLevelIds => List.unmodifiable(_top);

  /// What a picker offers: live, not hidden, not a duplicate, of one of [kinds] (all when null); each top-level id
  /// followed by its children. A hidden parent hides its children too.
  List<String> pickable({Set<BudgetKind>? kinds}) => [
        for (final t in _top)
          if (!isHidden(t) && !_dup.containsKey(t) && (kinds == null || kinds.contains(kindOf(t)))) ...[
            t,
            for (final c in _children[t] ?? const <String>[])
              if (!isHidden(c) && !_dup.containsKey(c)) c,
          ],
      ];

  /// The live fixed and flex top-level ids, in order: the categories a budget can be set for and the CSV columns.
  List<String> get spending => [
        for (final t in _top)
          if (_spendingKind(kindOf(t))) t
      ];

  /// A live category money goes out through (fixed or flex), children included.
  bool isSpending(String id) => isLive(id) && _spendingKind(kindOf(id));

  static bool _spendingKind(BudgetKind k) => k == BudgetKind.fixed || k == BudgetKind.flex;
}

/// [byCategory] with each child's sum added into its top-level category ([CategoryTable.topLevel]); exact cents. Keys
/// keep their first-seen order; with [CategoryTable.builtIn] the result equals the input.
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

/// Resolves categories. Built once per settings/rules change.
class Categorizer {
  final Map<String, String> merchantRules; // merchantKey -> category
  final List<(String, RegExp)> userPatterns;

  /// ATM withdrawals of at least this much (minor units, positive) count as rent (setting `rentCashThreshold`).
  final int rentCashThreshold;

  /// The categories rows resolve against: an override, rule or pattern naming an id that is not live here (a deleted
  /// or unknown custom category) is ignored, so the row falls back as if it had none (P1 §3; nothing is rewritten).
  final CategoryTable table;

  Categorizer(
      {this.merchantRules = const {},
      List<List<String>> patterns = const [],
      this.rentCashThreshold = defaultRentCashThreshold,
      CategoryTable? table})
      : table = table ?? CategoryTable.builtIn,
        userPatterns = [
          for (final p in patterns)
            if ((table ?? CategoryTable.builtIn).isLive(p[0]))
              if (_tryRegex(p[1]) case final re?) (p[0], re),
        ] {
    // Counts only: merchant rules and patterns are personal.
    logEvent(_log, Level.FINE, 'categories.build',
        {'rules': merchantRules.length, 'patterns': patterns.length, 'patternsUsed': userPatterns.length});
  }

  /// A pattern as a case-insensitive RegExp, or null (logged as `categories.badPattern`) if it does not compile or is
  /// empty (only spaces included): an empty pattern would match every merchant.
  static RegExp? _tryRegex(String s) {
    if (s.trim().isEmpty) {
      logEvent(_log, Level.WARNING, 'categories.badPattern', {'empty': true, 'length': s.length});
      return null;
    }
    try {
      return RegExp(s, caseSensitive: false);
    } on FormatException catch (e) {
      // Not the error text: a RegExp error can quote the pattern, which names personal merchants.
      logEvent(_log, Level.WARNING, 'categories.badPattern', {'offset': e.offset, 'length': s.length});
      return null;
    }
  }

  /// The category for merchant text, from personal patterns then built-in rules; null if none matches. The text is
  /// lower-cased and trimmed first, so `'Google '` matches `^google$`.
  String? merchantCategory(String description) {
    final s = description.toLowerCase().trim();
    for (final (c, re) in userPatterns) {
      if (re.hasMatch(s)) return c;
    }
    for (final (c, re) in builtInMerchantRules) {
      if (re.hasMatch(s)) return c;
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
  String autoCategory(Tx t) {
    if (t.transferTo != null) return 'Internal transfer';
    switch (t.kindHint) {
      case TxKind.salary:
        return 'Salary';
      case TxKind.atm:
        return rentCashThreshold > 0 && t.amount <= -rentCashThreshold ? 'Rent' : 'Cash';
      case TxKind.fee:
        return 'Bank fees';
      case TxKind.ownTransfer || TxKind.exchange:
        return 'Internal transfer';
      case TxKind.standingOrder || TxKind.card || TxKind.other || null:
        break;
    }
    final d = t.description.toLowerCase();
    final type = t.bankType;
    switch (t.source) {
      case 'revolut':
        if (type == 'Topup' || type == revolutExchangeType) return 'Internal transfer';
        if (type == 'Transfer') return 'To people';
        return merchantCategory(d) ?? 'Shopping';
      case 'pbz':
        if (d.contains('revolut')) return 'Internal transfer';
        if (d.contains('isplata kredita')) return 'Loan received';
        if (type == 'Isplata u poslovnici') return 'Cash';
        if (type == 'Isplata ATM') return rentCashThreshold > 0 && t.amount <= -rentCashThreshold ? 'Rent' : 'Cash';
        if (type == 'Naplaćene naknade' ||
            type == 'Povrat naknade' ||
            type == 'Pripisane kamate' ||
            d.contains('naknad') ||
            d.contains('članarin')) {
          return 'Bank fees';
        }
        if (type == 'Trajni nalog' || RegExp(r'naplata kredita|rate kredita|kreditni račun').hasMatch(d)) return 'Loan';
        if (type == 'Plaća/Mirovina' || d.contains('krive uplate')) return 'Salary';
        if (t.amount > 0) return 'Extra income';
        if (type == 'POS plaćanje') return merchantCategory(d) ?? 'Shopping';
        return 'Bills & one-offs';
      default:
        // Hand-added and unknown-source rows: their stored category if it is a live one, else Shopping.
        final c = t.category;
        return c != null && table.isLive(c) ? c : 'Shopping';
    }
  }

  String categoryOf(Tx t) {
    final o = t.category;
    if (o != null && table.isLive(o)) return o;
    final auto = autoCategory(t);
    final k = table.kindOf(auto);
    if (t.source != 'manual' && (k == BudgetKind.flex || k == BudgetKind.fixed)) {
      final r = merchantRules[merchantKey(t)];
      if (r != null && table.isLive(r)) return r;
    }
    return auto;
  }

  CategorizedTx categorize(Tx t) {
    final c = categoryOf(t);
    return CategorizedTx(t, c, table.kindOf(c));
  }
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
