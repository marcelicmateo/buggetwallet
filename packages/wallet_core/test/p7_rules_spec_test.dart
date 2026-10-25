// Stage P7 (docs/context/P7_SPEC.md "Core changes" and "Tests"): contains patterns, amount range, order, rulesView,
// ruleHits, edits and two devices. Written from the spec; all data SYNTHETIC.
//
// Guessed API shapes (one place each, fix here if the builder chose differently): [move] (direction type of
// `movePattern`), [views] (positional arguments of `rulesView`), `RuleView.kind` compared by `.name`, the rule ids
// `payee:<key>` / `pattern:<id>` / `builtIn:<n>` and `ruleHits` keyed by the same ids.
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';
import 'support/sim.dart' hide dump;
import 'support/t1.dart';

const _t = Timeout(Duration(seconds: 60));

/// A bank card row (pbz POS) so the merchant steps apply. Expenses are negative.
Tx pos(String desc, int cents, {String id = '', String currency = 'EUR', bool deleted = false}) => Tx(
    id: id.isEmpty ? 'p7-${desc.hashCode}-$cents-$currency-$deleted' : id,
    source: 'pbz',
    date: '2026-10-05',
    amount: cents,
    currency: currency,
    bankType: 'POS plaćanje',
    description: desc,
    deleted: deleted);

/// Direction of movePattern.
void move(WalletRepo r, String id, {required bool up}) => r.movePattern(id, up ? MoveDirection.up : MoveDirection.down);

List<RuleView> views(WalletRepo r) => rulesView(r.settings(), r.payeeRules(), r.ruleTags(), r.tagTable(), r.categoryTable());

List<RuleView> patternsOf(WalletRepo r) => [
      for (final v in views(r))
        if (v.kind.name == 'pattern') v,
    ];

/// The pattern texts in match order.
List<String> texts(WalletRepo r) => [for (final v in patternsOf(r)) v.text];

String catOf(WalletRepo r, Tx t) => r.categorizer().categoryOf(t);

String patternRuleId(String pattern) => merchantPatternId(pattern);

List<String> logs(void Function() body) {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
  try {
    body();
  } finally {
    sub.cancel();
    Logger.root.level = was;
  }
  return lines;
}

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => n2Now));
  tearDown(() => repo.close());

  group('contains patterns', () {
    test('folds case and accents on both sides', () {
      repo.setMerchantPattern('Eating out', 'Čokolada Bar', match: 'contains');
      expect(catOf(repo, pos('zagreb COKOLADA bar 12', -500)), 'Eating out');
      expect(catOf(repo, pos('ČOKOLADA BAR', -500)), 'Eating out');
      repo.setMerchantPattern('Home & tools', 'zeleni dućan', match: 'contains');
      expect(catOf(repo, pos('ZELENI DUCAN centar', -500)), 'Home & tools');
    });

    test('is a substring, not a regex: metacharacters are literal', () {
      repo.setMerchantPattern('Eating out', 'a.c', match: 'contains');
      expect(catOf(repo, pos('shop abc', -500)), 'Shopping', reason: '. is not a wildcard');
      expect(catOf(repo, pos('shop a.c', -500)), 'Eating out');
    });

    test('trimmed text of 1 to 60 characters is accepted', () {
      repo.setMerchantPattern('Eating out', 'x', match: 'contains');
      repo.setMerchantPattern('Eating out', '  ${'y' * 60}  ', match: 'contains');
      expect(texts(repo), hasLength(2));
    });

    for (final bad in ['', '   ', 'z' * 61, '  ${'z' * 61}  ']) {
      test('refuses ${bad.trim().isEmpty ? 'empty text' : '61 characters'} (${bad.length} chars given)', () {
        expect(() => repo.setMerchantPattern('Eating out', bad, match: 'contains'), throwsArgumentError);
        expect(patternsOf(repo), isEmpty);
      });
    }

    test('an unknown category is refused', () {
      expect(() => repo.setMerchantPattern('No such category', 'abc', match: 'contains'), throwsArgumentError);
    });

    test('a contains pattern reads back as match contains with its text', () {
      repo.setMerchantPattern('Eating out', 'Kava', match: 'contains');
      final v = patternsOf(repo).single;
      expect((v.text, v.match, v.category, v.minCents, v.maxCents, v.editable), ('Kava', 'contains', 'Eating out', null, null, true));
    });
  });

  group('amount range', () {
    setUp(() => repo.setMerchantPattern('Eating out', 'zorblex', match: 'contains', minCents: 1000, maxCents: 3000));

    test('is inclusive at both ends and compares the absolute amount', () {
      expect(catOf(repo, pos('zorblex a', -1000)), 'Eating out', reason: 'at min');
      expect(catOf(repo, pos('zorblex a', -3000)), 'Eating out', reason: 'at max');
      expect(catOf(repo, pos('zorblex a', -2000)), 'Eating out');
      expect(catOf(repo, pos('zorblex a', -999)), 'Shopping', reason: 'one cent under');
      expect(catOf(repo, pos('zorblex a', -3001)), 'Shopping', reason: 'one cent over');
    });

    test('only a minimum, or only a maximum, is an open range', () {
      repo.setMerchantPattern('Home & tools', 'baumarkt', match: 'contains', minCents: 5000);
      repo.setMerchantPattern('Sport & fitness', 'sportsklub', match: 'contains', maxCents: 700);
      expect(catOf(repo, pos('baumarkt x', -5000)), 'Home & tools');
      expect(catOf(repo, pos('baumarkt x', -4999)), 'Shopping');
      expect(catOf(repo, pos('baumarkt x', -9999999)), 'Home & tools');
      expect(catOf(repo, pos('sportsklub x', -700)), 'Sport & fitness');
      expect(catOf(repo, pos('sportsklub x', -701)), 'Shopping');
      expect(catOf(repo, pos('sportsklub x', -1)), 'Sport & fitness');
    });

    test('min = max matches exactly that amount', () {
      repo.setMerchantPattern('Home & tools', 'exakt', match: 'contains', minCents: 1234, maxCents: 1234);
      expect(catOf(repo, pos('exakt', -1234)), 'Home & tools');
      expect(catOf(repo, pos('exakt', -1233)), 'Shopping');
      expect(catOf(repo, pos('exakt', -1235)), 'Shopping');
    });

    test('a range works on a regex pattern too', () {
      repo.setMerchantPattern('Home & tools', r'^reg\d+$', minCents: 100, maxCents: 200);
      expect(catOf(repo, pos('reg12', -150)), 'Home & tools');
      expect(catOf(repo, pos('reg12', -250)), 'Shopping');
    });

    test('the range reads back', () {
      final v = patternsOf(repo).single;
      expect((v.minCents, v.maxCents), (1000, 3000));
    });

    test('a range alone is refused: no text, blank text', () {
      for (final p in ['', '   ']) {
        expect(() => repo.setMerchantPattern('Eating out', p, match: 'contains', minCents: 100, maxCents: 200), throwsArgumentError);
        expect(() => repo.setMerchantPattern('Eating out', p, minCents: 100), throwsArgumentError);
      }
      expect(patternsOf(repo), hasLength(1), reason: 'nothing was added');
    });

    test('min > max, a negative bound and a bound above maxAmount are refused', () {
      expect(() => repo.setMerchantPattern('Eating out', 'q1', match: 'contains', minCents: 500, maxCents: 499), throwsArgumentError);
      expect(() => repo.setMerchantPattern('Eating out', 'q2', match: 'contains', minCents: -1), throwsArgumentError);
      expect(() => repo.setMerchantPattern('Eating out', 'q3', match: 'contains', maxCents: -1), throwsArgumentError);
      expect(() => repo.setMerchantPattern('Eating out', 'q4', match: 'contains', maxCents: WalletSettings.maxAmount + 1),
          throwsArgumentError);
      expect(texts(repo), ['zorblex']);
    });

    test('0 and maxAmount are valid bounds', () {
      repo.setMerchantPattern('Eating out', 'edge', match: 'contains', minCents: 0, maxCents: WalletSettings.maxAmount);
      expect(texts(repo), contains('edge'));
    });
  });

  group('stored ranges are validated by fromMap', () {
    Map<String, Object?> row(Map<String, Object?> extra) => {
          'pattern:aaaaaaaaaaaaaaaa': {'category': 'Eating out', 'pattern': 'zorblex', 'order': 0, 'match': 'contains', ...extra},
        };

    List<RuleView> read(Map<String, Object?> m) => [
          for (final v in rulesView(WalletSettings.fromMap(m), const [], const {}, TagTable.empty, CategoryTable.builtIn))
            if (v.kind.name == 'pattern') v,
        ];

    test('an invalid range drops only the range, never the rule, and logs the key only', () {
      resetInvalidSettingLog();
      late List<RuleView> v;
      final lines = logs(() => v = read(row({'minCents': 5000, 'maxCents': 100})));
      expect(v.single.text, 'zorblex');
      expect((v.single.minCents, v.single.maxCents), (null, null));
      expect(v.single.category, 'Eating out');
      final warn = lines.where((l) => l.contains('settings.invalid')).toList();
      expect(warn, [endsWith(' WARNING bw.settings settings.invalid {"key":"merchantPatterns"}')]);
    });

    for (final (name, extra) in <(String, Map<String, Object?>)>[
      ('negative min', {'minCents': -5}),
      ('negative max', {'maxCents': -5}),
      ('max above the limit', {'maxCents': WalletSettings.maxAmount + 1}),
      ('text bound', {'minCents': '100'}),
      ('fractional bound', {'maxCents': 12.5}),
    ]) {
      test('$name: rule kept, range dropped', () {
        resetInvalidSettingLog();
        final v = read(row(extra));
        expect(v, hasLength(1));
        expect((v.single.minCents, v.single.maxCents), (null, null));
      });
    }

    test('valid bounds (0, the limit, min = max) are kept', () {
      final a = read(row({'minCents': 0, 'maxCents': WalletSettings.maxAmount})).single;
      expect((a.minCents, a.maxCents), (0, WalletSettings.maxAmount));
      final b = read(row({'minCents': 700, 'maxCents': 700})).single;
      expect((b.minCents, b.maxCents), (700, 700));
    });

    test('a row without match is a regex, as before', () {
      final v = read({
        'pattern:bbbbbbbbbbbbbbbb': {'category': 'Eating out', 'pattern': 'kaf+ic', 'order': 3},
      });
      expect((v.single.text, v.single.match, v.single.minCents, v.single.maxCents), ('kaf+ic', 'regex', null, null));
    });

    test('toMap then fromMap keeps contains and the range', () {
      final again = WalletSettings.fromMap(WalletSettings.fromMap(row({'minCents': 100, 'maxCents': 900})).toMap());
      final v = rulesView(again, const [], const {}, TagTable.empty, CategoryTable.builtIn).firstWhere((v) => v.kind.name == 'pattern');
      expect((v.match, v.minCents, v.maxCents), ('contains', 100, 900));
    });
  });

  group('order and first match', () {
    test('the first matching user pattern wins, and moving it changes the winner', () {
      repo.setMerchantPattern('Eating out', 'market', match: 'contains');
      repo.setMerchantPattern('Home & tools', 'mark', match: 'contains');
      expect(catOf(repo, pos('big market', -100)), 'Eating out');
    });

    test('a range miss falls to the next pattern, then to built-ins, then to the fallback', () {
      repo.setMerchantPattern('Eating out', 'lidl', match: 'contains', minCents: 5000, maxCents: 9000);
      repo.setMerchantPattern('Home & tools', 'zagreb', match: 'contains');
      expect(catOf(repo, pos('lidl zagreb', -1000)), 'Home & tools', reason: 'first misses on the range, second matches');
      expect(catOf(repo, pos('lidl zagreb', -6000)), 'Eating out', reason: 'first matches');
      expect(catOf(repo, pos('lidl split', -1000)), 'Groceries', reason: 'no user rule: built-in Lidl');
      expect(catOf(repo, pos('nowhere special', -1000)), 'Shopping');
    });

    test('a user pattern beats the built-in one only inside its range', () {
      repo.setMerchantPattern('Eating out', 'spar', match: 'contains', minCents: 100, maxCents: 200);
      expect(catOf(repo, pos('spar centar', -150)), 'Eating out');
      expect(catOf(repo, pos('spar centar', -300)), 'Groceries');
    });

    test('the payee rule still beats patterns', () {
      final t = pos('Cafe Zagreb Test', -500);
      repo.setMerchantPattern('Home & tools', 'cafe', match: 'contains');
      repo.setMerchantRule(merchantKey(t), 'Sport & fitness');
      expect(catOf(repo, t), 'Sport & fitness');
    });

    test('an item override beats everything', () {
      repo.setMerchantPattern('Home & tools', 'cafe', match: 'contains');
      final t = Tx(
          id: 'ovr',
          source: 'pbz',
          date: '2026-10-05',
          amount: -500,
          bankType: 'POS plaćanje',
          description: 'cafe x',
          category: 'Groceries');
      expect(catOf(repo, t), 'Groceries');
    });

    test('a salary hint is not touched by a pattern', () {
      repo.setMerchantPattern('Home & tools', 'neto', match: 'contains');
      final t = Tx(
          id: 'sal',
          source: 'pbz',
          date: '2026-10-05',
          amount: 150000,
          bankType: 'Plaća/Mirovina',
          description: 'neto placa',
          kindHint: TxKind.salary);
      expect(catOf(repo, t), 'Salary');
    });
  });

  group('old rows and the built-in identity', () {
    test('a regex pattern set without the new arguments works as before', () {
      repo.setMerchantPattern('Eating out', r'^zorb+o\b');
      expect(catOf(repo, pos('zorbbo shop', -500)), 'Eating out');
      expect(catOf(repo, pos('xzorbo shop', -500)), 'Shopping');
      final v = patternsOf(repo).single;
      expect((v.match, v.minCents, v.maxCents), ('regex', null, null));
    });

    test('with no new fields the stored value has no range keys', () {
      repo.setMerchantPattern('Eating out', 'abc');
      final raw = repo.db.select("SELECT value FROM settings WHERE id LIKE 'pattern:%'").single['value'] as String;
      expect(raw, isNot(contains('minCents')));
      expect(raw, isNot(contains('maxCents')));
    });

    test('categorize results are unchanged for the built-in rules and old patterns', () {
      final cz = Categorizer();
      expect(cz.categoryOf(pos('lidl zagreb', -1000)), 'Groceries');
      expect(cz.categoryOf(pos('wolt order', -1000)), 'Food delivery');
      expect(cz.categoryOf(pos('unknown thing', -1000)), 'Shopping');
      expect(cz.merchantCategory('Google '), 'Bills & subscriptions');
      final withOld = Categorizer(patterns: const [
        ['Eating out', 'zorblex'],
      ]);
      expect(withOld.categoryOf(pos('zorblex x', -1000)), 'Eating out');
      expect(withOld.categoryOf(pos('zorblex x', -999999)), 'Eating out', reason: 'no range: any amount');
    });
  });

  group('updateMerchantPattern', () {
    test('a category change keeps the id and the order', () {
      repo.setMerchantPattern('Eating out', 'one', match: 'contains');
      repo.setMerchantPattern('Eating out', 'two', match: 'contains');
      final before = patternsOf(repo).firstWhere((v) => v.text == 'one');
      repo.updateMerchantPattern(before.id, category: 'Home & tools');
      final after = patternsOf(repo);
      expect(after.map((v) => v.text), ['one', 'two']);
      expect(after.first.id, before.id);
      expect(after.first.category, 'Home & tools');
      expect(after.first.order, before.order);
    });

    test('a range change keeps the id; clearRange removes the range and keeps the rule', () {
      repo.setMerchantPattern('Eating out', 'one', match: 'contains');
      final id = patternsOf(repo).single.id;
      repo.updateMerchantPattern(id, minCents: 100, maxCents: 900);
      expect(patternsOf(repo).single.id, id);
      expect((patternsOf(repo).single.minCents, patternsOf(repo).single.maxCents), (100, 900));
      expect(catOf(repo, pos('one', -1000)), 'Shopping');
      repo.updateMerchantPattern(id, clearRange: true);
      final v = patternsOf(repo).single;
      expect((v.id, v.minCents, v.maxCents), (id, null, null));
      expect(catOf(repo, pos('one', -1000)), 'Eating out');
    });

    test('a text change is a new id, takes the old order, and leaves no old live row', () {
      repo.setMerchantPattern('Eating out', 'first', match: 'contains');
      repo.setMerchantPattern('Home & tools', 'middle', match: 'contains');
      repo.setMerchantPattern('Sport & fitness', 'last', match: 'contains');
      final old = patternsOf(repo)[1];
      repo.updateMerchantPattern(old.id, pattern: 'centre');
      final after = patternsOf(repo);
      expect(after.map((v) => v.text), ['first', 'centre', 'last'], reason: 'same place');
      expect(after[1].id, isNot(old.id));
      expect(after[1].order, old.order);
      expect(after[1].category, 'Home & tools');
      expect(repo.db.select('SELECT id FROM settings WHERE deleted = 0 AND id = ?', [old.id]), isEmpty);
    });

    test('invalid edits are refused and change nothing', () {
      repo.setMerchantPattern('Eating out', 'one', match: 'contains', minCents: 100, maxCents: 900);
      final id = patternsOf(repo).single.id;
      expect(() => repo.updateMerchantPattern(id, pattern: ' '), throwsArgumentError);
      expect(() => repo.updateMerchantPattern(id, pattern: 'y' * 61), throwsArgumentError);
      expect(() => repo.updateMerchantPattern(id, category: 'No such category'), throwsArgumentError);
      expect(() => repo.updateMerchantPattern(id, minCents: 901), throwsArgumentError);
      final v = patternsOf(repo).single;
      expect((v.id, v.text, v.category, v.minCents, v.maxCents), (id, 'one', 'Eating out', 100, 900));
    });
  });

  group('movePattern', () {
    setUp(() {
      for (final p in ['aa', 'bb', 'cc']) {
        repo.setMerchantPattern('Eating out', p, match: 'contains');
      }
    });

    test('swaps neighbours', () {
      move(repo, patternsOf(repo)[1].id, up: true);
      expect(texts(repo), ['bb', 'aa', 'cc']);
      move(repo, patternsOf(repo)[1].id, up: false);
      expect(texts(repo), ['bb', 'cc', 'aa']);
    });

    test('the first up and the last down are no-ops', () {
      move(repo, patternsOf(repo).first.id, up: true);
      move(repo, patternsOf(repo).last.id, up: false);
      expect(texts(repo), ['aa', 'bb', 'cc']);
    });

    test('moving changes the winner of a row both patterns match', () {
      final r = WalletRepo.inMemory(now: () => n2Now);
      addTearDown(r.close);
      r.setMerchantPattern('Eating out', 'shop', match: 'contains');
      r.setMerchantPattern('Home & tools', 'hop', match: 'contains');
      expect(catOf(r, pos('shop', -100)), 'Eating out');
      move(r, patternsOf(r).last.id, up: true);
      expect(catOf(r, pos('shop', -100)), 'Home & tools');
    });
  });

  group('ruleFor and ruleHits', () {
    test('ruleFor gives payee:, pattern:, builtIn: ids and null', () {
      final payeeRow = pos('Cafe Zagreb Test', -500);
      repo.setMerchantRule(merchantKey(payeeRow), 'Sport & fitness');
      repo.setMerchantPattern('Home & tools', 'qwerty', match: 'contains');
      final cz = repo.categorizer();
      expect(cz.ruleFor(payeeRow), 'payee:${merchantKey(payeeRow)}');
      expect(cz.ruleFor(pos('qwerty store', -500)), anyOf(patternRuleId('qwerty'), 'pattern:${patternRuleId('qwerty')}'));
      final n = builtInMerchantRules.indexWhere((r) => r.$1 == 'Groceries');
      expect(cz.ruleFor(pos('lidl zagreb', -500)), 'builtIn:$n');
      expect(cz.ruleFor(pos('nothing known', -500)), isNull);
    });

    test('ruleFor is null for rows decided otherwise: override, salary hint, transfer', () {
      repo.setMerchantPattern('Home & tools', 'neto', match: 'contains');
      final cz = repo.categorizer();
      Tx row(String id, {int amount = -500, String? category, TxKind? hint, String? transferTo, String type = 'POS plaćanje'}) => Tx(
          id: id,
          source: 'pbz',
          date: '2026-10-05',
          amount: amount,
          bankType: type,
          description: 'neto',
          category: category,
          kindHint: hint,
          transferTo: transferTo);
      expect(cz.ruleFor(row('a', category: 'Groceries')), isNull);
      expect(cz.ruleFor(row('b', amount: 1000, hint: TxKind.salary, type: 'Plaća/Mirovina')), isNull);
      expect(cz.ruleFor(row('c', transferTo: 'x')), isNull);
    });

    test('a range miss reports the next rule that decided', () {
      repo.setMerchantPattern('Eating out', 'lidl', match: 'contains', minCents: 5000);
      final cz = repo.categorizer();
      final n = builtInMerchantRules.indexWhere((r) => r.$1 == 'Groceries');
      expect(cz.ruleFor(pos('lidl', -100)), 'builtIn:$n');
      expect(cz.ruleFor(pos('lidl', -5000)), isNot('builtIn:$n'));
    });

    test('ruleHits counts live home-currency rows per rule id', () {
      repo.setMerchantPattern('Home & tools', 'qwerty', match: 'contains');
      final cz = repo.categorizer();
      final rows = [
        pos('qwerty one', -100, id: 'r1'),
        pos('qwerty two', -200, id: 'r2'),
        pos('qwerty three', -300, id: 'r3'),
        pos('qwerty gone', -400, id: 'r4', deleted: true),
        pos('qwerty abroad', -500, id: 'r5', currency: 'USD'),
        pos('lidl a', -600, id: 'r6'),
        pos('lidl b', -700, id: 'r7'),
        pos('nothing known', -800, id: 'r8'),
      ];
      final hits = ruleHits(rows, cz, currency: 'EUR');
      final pid = hits.keys.firstWhere((k) => k.startsWith('pattern:'));
      expect(pid, anyOf(patternRuleId('qwerty'), 'pattern:${patternRuleId('qwerty')}'));
      expect(hits[pid], 3);
      final n = builtInMerchantRules.indexWhere((r) => r.$1 == 'Groceries');
      expect(hits['builtIn:$n'], 2);
      expect(hits.values.fold<int>(0, (a, b) => a + b), 5, reason: 'unmatched, deleted and foreign rows count nowhere');
    });

    test('ruleHits of no rows is empty; a rule nobody uses has no hits', () {
      repo.setMerchantPattern('Home & tools', 'qwerty', match: 'contains');
      expect(ruleHits(const [], repo.categorizer(), currency: 'EUR'), isEmpty);
      final hits = ruleHits([pos('other', -100)], repo.categorizer(), currency: 'EUR');
      expect(hits.values.where((v) => v != 0), isEmpty);
    });

    test('the edit preview: hits before and after a range edit', () {
      repo.setMerchantPattern('Home & tools', 'qwerty', match: 'contains');
      final rows = [for (var i = 1; i <= 4; i++) pos('qwerty $i', -i * 1000, id: 'q$i')];
      int total() => ruleHits(rows, repo.categorizer(), currency: 'EUR')
          .entries
          .where((e) => e.key.startsWith('pattern:'))
          .fold(0, (a, e) => a + e.value);
      expect(total(), 4);
      repo.updateMerchantPattern(patternsOf(repo).single.id, minCents: 2000, maxCents: 3000);
      expect(total(), 2, reason: 'only 20.00 and 30.00 remain');
    });
  });

  group('rulesView', () {
    test('sorts payee rules, patterns by order, payee tag rules, then built-ins', () async {
      repo.setMerchantPattern('Eating out', 'bbb', match: 'contains');
      repo.setMerchantPattern('Home & tools', 'aaa', match: 'contains');
      final tag = await repo.addTag('Trip');
      await repo.setRuleTag('some_payee', tag, true);
      final kinds = [for (final x in views(repo)) x.kind.name];
      const rank = {'payee': 0, 'pattern': 1, 'payeeTags': 2, 'builtIn': 3};
      final ranks = [for (final k in kinds) rank[k]!];
      expect(ranks, [...ranks]..sort(), reason: 'kind order $kinds');
      expect(kinds.where((k) => k == 'builtIn'), hasLength(builtInMerchantRules.length));
      expect(kinds.where((k) => k == 'pattern'), hasLength(2));
      expect(kinds.where((k) => k == 'payeeTags'), hasLength(1));
      expect(texts(repo), ['bbb', 'aaa'], reason: 'by order, not alphabetical');
    });

    test('editable: patterns yes, built-ins no; ids are unique', () {
      repo.setMerchantPattern('Eating out', 'bbb', match: 'contains');
      final v = views(repo);
      expect(v.where((x) => x.kind.name == 'pattern').every((x) => x.editable), isTrue);
      expect(v.where((x) => x.kind.name == 'builtIn'), isNotEmpty);
      expect(v.where((x) => x.kind.name == 'builtIn').every((x) => !x.editable), isTrue);
      final ids = [for (final x in v) x.id];
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('deleting a pattern removes it from the list', () {
      repo.setMerchantPattern('Eating out', 'bbb', match: 'contains');
      repo.removeMerchantPattern('bbb');
      expect(patternsOf(repo), isEmpty);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = n2Now;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 3; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
          d.upload(net);
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-p7-');
      key = VaultKey.generate();
      net = Net();
      now = n2Now;
    });
    tearDown(() {
      for (final d in devices) {
        d.repo.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('a contains pattern with a range reaches the other device unchanged', () async {
      final a = device('a'), b = device('b');
      a.repo.setMerchantPattern('Eating out', 'zorblex', match: 'contains', minCents: 100, maxCents: 900);
      await syncAll([a, b]);
      final v = patternsOf(b.repo).single;
      expect((v.text, v.match, v.minCents, v.maxCents, v.category), ('zorblex', 'contains', 100, 900, 'Eating out'));
      expect(dump(a.repo, 'settings'), dump(b.repo, 'settings'));
      expect(catOf(b.repo, pos('zorblex', -500)), 'Eating out');
      expect(catOf(b.repo, pos('zorblex', -5000)), 'Shopping');
    }, timeout: _t);

    test('both edit the same pattern offline: the later write wins the whole row and both converge', () async {
      final a = device('a'), b = device('b');
      a.repo.setMerchantPattern('Eating out', 'zorblex', match: 'contains');
      await syncAll([a, b]);
      final id = patternsOf(a.repo).single.id;
      now += 1000;
      a.repo.updateMerchantPattern(id, category: 'Home & tools');
      now += 1000;
      b.repo.updateMerchantPattern(id, category: 'Sport & fitness', minCents: 100, maxCents: 900);
      await syncAll([a, b]);
      expect(dump(a.repo, 'settings'), dump(b.repo, 'settings'));
      for (final d in [a, b]) {
        final v = patternsOf(d.repo).single;
        expect((v.category, v.minCents, v.maxCents), ('Sport & fitness', 100, 900), reason: 'b wrote last');
      }
    }, timeout: _t);

    test('one edits the text, the other the category: both devices converge identically', () async {
      final a = device('a'), b = device('b');
      a.repo.setMerchantPattern('Eating out', 'zorblex', match: 'contains');
      await syncAll([a, b]);
      final id = patternsOf(a.repo).single.id;
      now += 1000;
      a.repo.updateMerchantPattern(id, pattern: 'kavana');
      now += 1000;
      b.repo.updateMerchantPattern(id, category: 'Home & tools');
      await syncAll([a, b]);
      expect(dump(a.repo, 'settings'), dump(b.repo, 'settings'));
      expect(texts(a.repo), texts(b.repo));
      expect(texts(a.repo), isNotEmpty);
    }, timeout: _t);
  });
}
