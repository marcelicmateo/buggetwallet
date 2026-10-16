import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.categories');

enum Kind { income, extra, fixed, flex, transfer }

/// Category name -> kind. Same names as the v1 web app.
const Map<String, Kind> categories = {
  'Salary': Kind.income,
  'Extra income': Kind.extra,
  'Rent': Kind.fixed,
  'Loan': Kind.fixed,
  'Bills & subscriptions': Kind.fixed,
  'Groceries': Kind.flex,
  'Food delivery': Kind.flex,
  'Eating out': Kind.flex,
  'Car & transport': Kind.flex,
  'Shopping': Kind.flex,
  'Home & tools': Kind.flex,
  'Sport & fitness': Kind.flex,
  'Health & care': Kind.flex,
  'Games & apps': Kind.flex,
  'Cash': Kind.flex,
  'Bills & one-offs': Kind.flex,
  'To people': Kind.flex,
  'Bank fees': Kind.flex,
  'Internal transfer': Kind.transfer,
  'Loan received': Kind.transfer,
};

List<String> get flexCategories => [
      for (final e in categories.entries)
        if (e.value == Kind.flex) e.key
    ];

Kind kindOf(String category) => categories[category] ?? Kind.flex;

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

/// Resolves categories. Built once per settings/rules change.
class Categorizer {
  final Map<String, String> merchantRules; // merchantKey -> category
  final List<(String, RegExp)> userPatterns;

  Categorizer({this.merchantRules = const {}, List<List<String>> patterns = const []})
      : userPatterns = [
          for (final p in patterns)
            if (categories.containsKey(p[0]))
              if (_tryRegex(p[1]) case final re?) (p[0], re),
        ] {
    // Counts only: merchant rules and patterns are personal.
    logEvent(_log, Level.FINE, 'categories.build',
        {'rules': merchantRules.length, 'patterns': patterns.length, 'patternsUsed': userPatterns.length});
  }

  static RegExp? _tryRegex(String s) {
    try {
      return RegExp(s, caseSensitive: false);
    } on FormatException catch (e) {
      // Not the error text: a RegExp error can quote the pattern, which names personal merchants.
      logEvent(_log, Level.WARNING, 'categories.badPattern', {'offset': e.offset, 'length': s.length});
      return null;
    }
  }

  String? merchantCategory(String description) {
    final s = description.toLowerCase();
    for (final (c, re) in userPatterns) {
      if (re.hasMatch(s)) return c;
    }
    for (final (c, re) in builtInMerchantRules) {
      if (re.hasMatch(s)) return c;
    }
    return null;
  }

  String autoCategory(Tx t) {
    final d = t.description.toLowerCase();
    final type = t.bankType;
    switch (t.source) {
      case 'revolut':
        if (type == 'Topup' || type == 'Exchange') return 'Internal transfer';
        if (type == 'Transfer') return 'To people';
        return merchantCategory(d) ?? 'Shopping';
      case 'pbz':
        if (d.contains('revolut')) return 'Internal transfer';
        if (d.contains('isplata kredita')) return 'Loan received';
        if (type == 'Isplata u poslovnici') return 'Cash';
        if (type == 'Isplata ATM') return t.amount <= -50000 ? 'Rent' : 'Cash';
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
        return t.category ?? 'Shopping';
    }
  }

  String categoryOf(Tx t) {
    final o = t.category;
    if (o != null && categories.containsKey(o)) return o;
    final auto = autoCategory(t);
    final k = kindOf(auto);
    if (t.source != 'manual' && (k == Kind.flex || k == Kind.fixed)) {
      final r = merchantRules[merchantKey(t)];
      if (r != null && categories.containsKey(r)) return r;
    }
    return auto;
  }

  CategorizedTx categorize(Tx t) {
    final c = categoryOf(t);
    return CategorizedTx(t, c, kindOf(c));
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
