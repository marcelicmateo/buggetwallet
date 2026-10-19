// Categorizer edge cases: odd merchant text, overlapping and broken rules, unknown categories, merchant keys.
// Expected values are worked out by hand from the rule list in categories.dart. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

Tx _tx(String source, String type, String desc, int amount, {String? category, String? note, bool manual = false}) => Tx(
    id: 't',
    source: source,
    date: '2026-01-10',
    amount: amount,
    bankType: type,
    description: desc,
    category: category,
    note: note,
    manual: manual);

void main() {
  final cz = Categorizer();

  group('built-in merchant text', () {
    test('empty, blank and control-character text matches nothing', () {
      for (final s in ['', ' ', '   ', '\n', '\t\r\n', '\u0000', '🙂', '-', '***']) {
        expect(cz.merchantCategory(s), isNull, reason: _show(s));
      }
    });

    test('case variants and non-ASCII capitals match like lower case', () {
      expect(cz.merchantCategory('LIDL'), 'Groceries');
      expect(cz.merchantCategory('LiDl Zagreb'), 'Groceries');
      expect(cz.merchantCategory('KONZUM ČAKOVEC'), 'Groceries');
      expect(cz.merchantCategory('LJEKARNA ŠIBENIK'), 'Health & care');
      expect(cz.merchantCategory('MÜLLER'), 'Health & care');
      expect(cz.merchantCategory('Müller'), 'Health & care');
      expect(cz.merchantCategory('WOLT'), 'Food delivery');
    });

    test('text around the merchant (newlines, emoji, long digit runs) does not hide it', () {
      expect(cz.merchantCategory('LIDL 🛒\n'), 'Groceries');
      expect(cz.merchantCategory('0000 1234567890123456789 lidl 0000'), 'Groceries');
      expect(cz.merchantCategory(' lidl '), 'Groceries');
    });

    test('word boundaries: short names only match as whole words', () {
      expect(cz.merchantCategory('a1 hrvatska'), 'Bills & subscriptions');
      expect(cz.merchantCategory('a1b'), isNull);
      expect(cz.merchantCategory('ina 123'), 'Car & transport');
      expect(cz.merchantCategory('marina'), isNull);
      expect(cz.merchantCategory('esparto'), isNull); // "spar" only at the start of a word
      expect(cz.merchantCategory('spar'), 'Groceries');
      expect(cz.merchantCategory('barcelona'), isNull); // "bar" only at the end of a word
      expect(cz.merchantCategory('cocktail bar'), 'Eating out');
      expect(cz.merchantCategory('zet tram'), 'Car & transport');
      expect(cz.merchantCategory('zeta'), isNull);
      expect(cz.merchantCategory('smallville'), isNull);
      expect(cz.merchantCategory('example mall'), 'Home & tools');
    });

    test('"google" alone is a subscription, other Google text is not guessed', () {
      expect(cz.merchantCategory('google'), 'Bills & subscriptions');
      expect(cz.merchantCategory('google play'), 'Games & apps');
      expect(cz.merchantCategory('google ads'), isNull);
    });

    test('overlapping built-in rules: the first rule in the list wins, in both word orders', () {
      expect(cz.merchantCategory('wolt lidl'), 'Food delivery');
      expect(cz.merchantCategory('lidl wolt'), 'Food delivery');
      expect(cz.merchantCategory('lidl uber'), 'Groceries');
      expect(cz.merchantCategory('uber lidl'), 'Groceries');
      expect(cz.merchantCategory('steam ljekarna'), 'Games & apps');
      expect(cz.merchantCategory('netflix bar'), 'Bills & subscriptions');
      expect(cz.merchantCategory('bolt food'), 'Food delivery');
      expect(cz.merchantCategory('bolt ride'), 'Car & transport');
    });

    test('a 1 MB description is handled quickly, with and without a match at the end', () {
      final sw = Stopwatch()..start();
      final filler = 'x' * 1000000;
      expect(cz.merchantCategory(filler), isNull);
      expect(cz.merchantCategory('$filler lidl'), 'Groceries');
      expect(cz.merchantCategory('lidl ' * 100000), 'Groceries');
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('rule table is consistent: known categories, spending kinds only, no capitals that could never match', () {
      for (final (cat, re) in builtInMerchantRules) {
        expect(categories.containsKey(cat), isTrue, reason: cat);
        expect([Kind.flex, Kind.fixed], contains(kindOf(cat)), reason: '$cat must not turn spending into income or a transfer');
        final literal = re.pattern.replaceAll(RegExp(r'\\.'), ''); // drop \b, \d ...
        expect(RegExp('[A-Z]').hasMatch(literal), isFalse, reason: '${re.pattern} can never match lower-cased text');
      }
    });
  });

  group('personal patterns', () {
    test('case-insensitive, unicode and special characters', () {
      final c = Categorizer(patterns: [
        ['Shopping', 'LIDL'],
        ['Eating out', 'ČAJ'],
        ['Cash', r'a\+b'],
        ['Sport & fitness', r'\d{3}-\d{3}'],
        ['Games & apps', r'^exact$'],
      ]);
      expect(c.merchantCategory('Lidl Zagreb'), 'Shopping');
      expect(c.merchantCategory('Čajanka Centar'), 'Eating out');
      expect(c.merchantCategory('ČAJANKA'), 'Eating out');
      expect(c.merchantCategory('x a+b y'), 'Cash');
      expect(c.merchantCategory('a b'), isNull);
      expect(c.merchantCategory('gym 123-456'), 'Sport & fitness');
      expect(c.merchantCategory('EXACT'), 'Games & apps');
      expect(c.merchantCategory('not exact'), isNull);
    });

    test('overlapping personal patterns: list order decides; they beat built-in rules', () {
      final c = Categorizer(patterns: [
        ['Eating out', 'corner'],
        ['Groceries', 'corner'],
        ['Cash', 'lidl'],
      ]);
      expect(c.merchantCategory('example corner'), 'Eating out');
      expect(c.merchantCategory('lidl corner'), 'Eating out');
      expect(c.merchantCategory('lidl'), 'Cash'); // built-in says Groceries
      expect(
          Categorizer(patterns: [
            ['Groceries', 'corner'],
            ['Eating out', 'corner'],
          ]).merchantCategory('corner'),
          'Groceries');
    });

    test('broken patterns are skipped one by one: the others and the built-ins keep working', () {
      final broken = ['(', '[', '*x', '+', '?', 'c++', 'a{2,1}', r'\', '(?<n>a)(?<n>b)', '(?i)x', '[z-a]', ')'];
      for (final b in broken) {
        final c = Categorizer(patterns: [
          ['Cash', b],
          ['Shopping', 'good'],
        ]);
        expect(c.merchantCategory('a good place'), 'Shopping', reason: 'pattern "$b"');
        expect(c.merchantCategory('lidl'), 'Groceries', reason: 'pattern "$b"');
      }
    });

    test('patterns for a category that does not exist (wrong case, spaces, empty) are skipped', () {
      final c = Categorizer(patterns: [
        ['groceries', 'zzz'],
        ['Groceries ', 'zzz'],
        ['', 'zzz'],
        ['Internal  transfer', 'zzz'],
        ['GROCERIES', 'zzz'],
      ]);
      expect(c.merchantCategory('zzz'), isNull);
    });

    test('a pattern that can match transfers or income categories only labels merchant text, never changes a PBZ transfer', () {
      final c = Categorizer(patterns: [
        ['Shopping', 'revolut']
      ]);
      expect(c.categoryOf(_tx('pbz', 'POS plaćanje', 'POS Revolut**0000* Dublin', -5000)), 'Internal transfer');
      expect(c.categoryOf(_tx('revolut', 'Topup', 'revolut top-up', 5000)), 'Internal transfer');
    });

    test('the pattern list is copied: changing it afterwards does not change the categorizer', () {
      final list = [
        ['Cash', 'abc']
      ];
      final c = Categorizer(patterns: list);
      list.clear();
      expect(c.merchantCategory('abc'), 'Cash');
    });
  });

  group('category of one transaction', () {
    test('an override that is not a known category is ignored (unknown name, empty, other case, spaces)', () {
      for (final bad in ['Nonexistent', '', ' ', 'groceries', 'GROCERIES', 'Groceries ', 'Food']) {
        expect(cz.categoryOf(_tx('revolut', 'Card Payment', 'Lidl', -100, category: bad)), 'Groceries', reason: '"$bad"');
        expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'PBZ POS PBZ7LIDL', -100, category: bad)), 'Groceries', reason: '"$bad"');
        expect(cz.categoryOf(_tx('pbz', 'Plaća/Mirovina', 'Neto plaća', 150000, category: bad)), 'Salary', reason: '"$bad"');
      }
    });

    test('a known override always wins, also over a transfer', () {
      expect(cz.categoryOf(_tx('revolut', 'Topup', 'Top-up', 5000, category: 'Groceries')), 'Groceries');
      expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'POS Revolut**0000*', -5000, category: 'Shopping')), 'Shopping');
      expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'Lidl', -100, category: 'Internal transfer')), 'Internal transfer');
      expect(cz.categorize(_tx('pbz', 'POS plaćanje', 'Lidl', -100, category: 'Internal transfer')).kind, Kind.transfer);
    });

    test('hand-added entries with an unknown stored category still get a known category', () {
      // A damaged op or a device with a different category list can leave such a value behind.
      for (final bad in ['Nonexistent', '', 'groceries']) {
        final c = cz.categoryOf(_tx('manual', '', '', -500, category: bad, manual: true));
        expect(categories.containsKey(c), isTrue, reason: 'category "$bad" came out as "$c"');
      }
    });

    test('hand-added entries without a category are Shopping; an unknown source falls back the same way', () {
      expect(cz.categoryOf(_tx('manual', '', '', -500, manual: true)), 'Shopping');
      expect(cz.categoryOf(_tx('', '', '', -500)), 'Shopping');
      expect(cz.categoryOf(_tx('someotherbank', 'x', 'Lidl', -500)), 'Shopping', reason: 'unknown source: no guessing from the text');
      expect(cz.categoryOf(_tx('manual', '', '', -500, category: 'Rent', manual: true)), 'Rent');
    });

    test('merchant rules: unknown or wrong-case categories are ignored; rules do not apply to transfers, salary or manual rows', () {
      final lidl = _tx('pbz', 'POS plaćanje', 'PBZ POS PBZ7LIDL', -100);
      for (final bad in ['Nonexistent', '', 'groceries']) {
        expect(Categorizer(merchantRules: {merchantKey(lidl): bad}).categoryOf(lidl), 'Groceries', reason: '"$bad"');
      }
      final rules = {merchantKey(lidl): 'Shopping', 'x': 'Shopping', 'revolut_dublin': 'Shopping'};
      final c = Categorizer(merchantRules: rules);
      expect(c.categoryOf(lidl), 'Shopping');
      expect(c.categoryOf(_tx('revolut', 'Topup', 'x', 5000)), 'Internal transfer');
      expect(c.categoryOf(_tx('pbz', 'Plaća/Mirovina', '', 150000)), 'Salary');
      expect(c.categoryOf(_tx('manual', '', '', -500, category: 'Cash', manual: true)), 'Cash');
      expect(c.categoryOf(_tx('pbz', 'Isplata kredita', 'Isplata kredita 0000', 1000000)), 'Loan received');
    });

    test('rule keys are exact: another case or a key with spaces does not match', () {
      final t = _tx('pbz', 'POS plaćanje', 'PBZ POS PBZ7LIDL', -100);
      expect(Categorizer(merchantRules: {'LIDL': 'Shopping'}).categoryOf(t), 'Groceries');
      expect(Categorizer(merchantRules: {' lidl': 'Shopping'}).categoryOf(t), 'Groceries');
      expect(Categorizer(merchantRules: {'lidl': 'Shopping'}).categoryOf(t), 'Shopping');
    });

    test('empty or odd PBZ and Revolut rows get a spending category, never a crash', () {
      expect(cz.categoryOf(_tx('pbz', '', '', 0)), 'Bills & one-offs');
      expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', '', 0)), 'Shopping');
      expect(cz.categoryOf(_tx('revolut', '', '', 0)), 'Shopping');
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'x' * 100000, -1)), 'Bills & one-offs');
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'Uplata 🙂', 100)), 'Extra income');
    });

    test('ATM rent threshold: exactly at the limit is rent, one cent less is cash, a refund is never rent, 0 turns it off', () {
      final at = _tx('pbz', 'Isplata ATM', 'ATM', -50000);
      expect(cz.categoryOf(at), 'Rent');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', -49999)), 'Cash');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', 50000)), 'Cash');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', 0)), 'Cash');
      expect(Categorizer(rentCashThreshold: 0).categoryOf(at), 'Cash');
      expect(Categorizer(rentCashThreshold: 1).categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', -1)), 'Rent');
      expect(
          Categorizer(rentCashThreshold: 9223372036854775807).categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', -9223372036854775807)), 'Rent');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', -9223372036854775807 - 1)), 'Rent');
    });

    test('kindOf: unknown names are flexible spending; the income and transfer names are exact', () {
      for (final s in ['', 'Nonexistent', 'groceries', 'salary', 'Internal Transfer']) {
        expect(kindOf(s), Kind.flex, reason: '"$s"');
      }
      expect(kindOf('Salary'), Kind.income);
      expect(kindOf('Extra income'), Kind.extra);
      expect(kindOf('Rent'), Kind.fixed);
      expect(kindOf('Loan received'), Kind.transfer);
      expect(flexCategories, isNot(contains('Salary')));
      expect(flexCategories, isNot(contains('Internal transfer')));
      expect(flexCategories, containsAll(['Groceries', 'Cash', 'To people']));
    });
  });

  group('merchant name and key', () {
    test('bank prefixes are removed, any case; empty names get a placeholder', () {
      expect(merchantName(_tx('pbz', 'POS plaćanje', 'PBZ POS PBZ7LIDL ZAGREB', -1)), 'LIDL ZAGREB');
      expect(merchantName(_tx('pbz', 'POS plaćanje', 'pbz pos pbz7lidl', -1)), 'lidl');
      expect(merchantName(_tx('pbz', 'POS plaćanje', 'POS Revolut**0000* Dublin', -1)), 'Revolut**0000* Dublin');
      expect(merchantName(_tx('pbz', '', 'a    b \n  c', -1)), 'a b c');
      for (final s in ['', ' ', '   ', 'POS ', 'PBZ POS PBZ7', '\n']) {
        expect(merchantName(_tx('pbz', '', s, -1)), '(no description)', reason: _show(s));
      }
    });

    test('hand-added entries are named by note, then category, then "Expense"', () {
      expect(merchantName(_tx('manual', '', 'ignored', -1, note: 'Coffee', category: 'Eating out', manual: true)), 'Coffee');
      expect(merchantName(_tx('manual', '', '', -1, note: '', category: 'Eating out', manual: true)), 'Eating out');
      expect(merchantName(_tx('manual', '', '', -1, manual: true)), 'Expense');
    });

    test('key ignores case, digits, punctuation and extra spaces; the same merchant has one key', () {
      final keys = {
        for (final d in [
          'PBZ POS PBZ7EXAMPLE BISTRO 0012 ZAGREB',
          'pbz pos pbz7example bistro 0047 zagreb',
          'POS Example   Bistro #5  Zagreb',
          '  EXAMPLE BISTRO * ZAGREB  ',
          'Example-Bistro, Zagreb!',
        ])
          merchantKey(_tx('pbz', 'POS plaćanje', d, -1))
      };
      expect(keys, {'example_bistro_zagreb'});
      expect(merchantKey(_tx('pbz', '', 'ČAKOVEC Šop', -1)), merchantKey(_tx('pbz', '', 'čakovec šop', -1)));
    });

    test('nothing usable left: the key is "x"', () {
      for (final d in ['12345', '***', '#', '🙂🙂', '0000 0000']) {
        expect(merchantKey(_tx('pbz', '', d, -1)), 'x', reason: d);
      }
    });

    test('keys are at most 40 characters; a long text only keeps its start', () {
      final k = merchantKey(_tx('pbz', '', 'a' * 500, -1));
      expect(k, 'a' * 40);
      expect(merchantKey(_tx('pbz', '', '${'b' * 40}-one', -1)), merchantKey(_tx('pbz', '', '${'b' * 40}-two', -1)));
    });

    test('random text always gives a short, plain key (property)', () {
      final r = Random(4);
      const pool = ['a', 'B', 'č', 'Š', '0', '9', ' ', '\n', '\t', '-', '*', '#', '🙂', 'ß', 'İ', 'ж', '_', '/', '.', ' ', 'é'];
      final ok = RegExp(r'^[a-zÀ-ɏ_]+$');
      for (var i = 0; i < 1500; i++) {
        final s = [for (var j = r.nextInt(80); j > 0; j--) pool[r.nextInt(pool.length)]].join();
        final k = merchantKey(_tx('pbz', 'POS plaćanje', s, -1));
        expect(k.isNotEmpty && k.length <= 40, isTrue, reason: 'key "$k" for ${_show(s)}');
        expect(ok.hasMatch(k) || k == 'x', isTrue, reason: 'key "$k" for ${_show(s)}');
        expect(merchantKey(_tx('pbz', 'POS plaćanje', s.toUpperCase(), -1)).length, lessThanOrEqualTo(40));
      }
    });
  });
}

/// A readable form of text with control characters, for failure messages.
String _show(String s) => s.codeUnits.map((c) => c < 32 || c > 126 ? '\\u${c.toRadixString(16)}' : String.fromCharCode(c)).join();
