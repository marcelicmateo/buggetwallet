// P7 (docs/context/P7_SPEC.md): contains patterns, amount ranges that only narrow a text rule, pattern edits and
// moves, the Rules listing and rule hits. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

Tx _card(String id, String desc, int cents, {String currency = 'EUR', String? category, bool deleted = false}) => Tx(
    id: id,
    source: 'revolut',
    date: '2026-03-10',
    amount: cents,
    currency: currency,
    bankType: 'Card Payment',
    description: desc,
    category: category,
    deleted: deleted);

Map<String, Object?>? _value(WalletRepo r, String id) {
  final row = r.db.select('SELECT value, deleted FROM settings WHERE id = ?', [id]).firstOrNull;
  final v = row?['value'];
  return v is String ? (jsonDecode(v) as Map<String, Object?>) : null;
}

int _outbox(WalletRepo r) => r.db.select('SELECT COUNT(*) AS n FROM outbox').first['n'] as int;

void main() {
  group('contains and ranges in the categorizer', () {
    test('contains folds case and accents (č → c)', () {
      final cz = Categorizer(patternRules: [
        MerchantPattern(
            id: merchantPatternId('čajna kuća'), category: 'Eating out', pattern: 'čajna kuća', match: MerchantPattern.contains),
      ]);
      expect(cz.categoryOf(_card('1', 'CAJNA KUCA ZAGREB', -500)), 'Eating out');
      expect(cz.ruleFor(_card('1', 'Cajna Kuca', -500)), merchantPatternId('čajna kuća'));
      expect(cz.categoryOf(_card('2', 'other shop', -500)), 'Shopping');
      expect(cz.ruleFor(_card('2', 'other shop', -500)), isNull);
    });

    test('contains is a substring, never a regex', () {
      final cz = Categorizer(patternRules: [
        MerchantPattern(id: merchantPatternId('a.b'), category: 'Eating out', pattern: 'a.b', match: MerchantPattern.contains),
      ]);
      expect(cz.categoryOf(_card('1', 'axb', -500)), 'Shopping');
      expect(cz.categoryOf(_card('2', 'xa.by', -500)), 'Eating out');
    });

    test('a range is inclusive at both ends and compares the absolute amount', () {
      final id = merchantPatternId('acme');
      final cz = Categorizer(patternRules: [
        MerchantPattern(id: id, category: 'Groceries', pattern: 'acme', match: MerchantPattern.contains, minCents: 1200, maxCents: 3000),
      ]);
      for (final (c, hit) in [(-1199, false), (-1200, true), (-2000, true), (-3000, true), (-3001, false), (1500, true)]) {
        expect(cz.ruleFor(_card('x', 'ACME store', c)) == id, hit, reason: '$c');
      }
      expect(cz.merchantCategory('acme store'), isNull, reason: 'no amount: a ranged pattern never matches');
    });

    test('order: first match wins; a range miss skips to the next pattern; then built-ins', () {
      final a = merchantPatternId('acme'), b = merchantPatternId('acm');
      final cz = Categorizer(patternRules: [
        MerchantPattern(id: a, category: 'Groceries', pattern: 'acme', match: MerchantPattern.contains, maxCents: 1000, order: 0),
        MerchantPattern(id: b, category: 'Home & tools', pattern: 'acm', order: 1),
      ]);
      expect(cz.categoryOf(_card('1', 'acme', -900)), 'Groceries');
      expect(cz.categoryOf(_card('2', 'acme', -1100)), 'Home & tools');
      expect(cz.ruleFor(_card('2', 'acme', -1100)), b);
      expect(cz.ruleFor(_card('3', 'LIDL 123', -100)), 'builtIn:${builtInMerchantRules.indexWhere((r) => r.$1 == 'Groceries')}');
    });

    test('ruleFor: payee rule wins over patterns; an override or hint has no rule', () {
      final cz = Categorizer(
          merchantRules: {'acme': 'Health & care'},
          patternRules: [MerchantPattern(id: merchantPatternId('acme'), category: 'Groceries', pattern: 'acme')]);
      expect(cz.ruleFor(_card('1', 'ACME', -100)), 'payee:acme');
      expect(cz.categoryOf(_card('1', 'ACME', -100)), 'Health & care');
      expect(cz.ruleFor(_card('2', 'ACME', -100, category: 'Shopping')), isNull);
    });

    test('old regex rows read unchanged; a bad stored range drops only the range', () {
      final id = merchantPatternId('acme');
      final st = WalletSettings.fromMap({
        id: {'category': 'Groceries', 'pattern': 'acme', 'order': 0},
        merchantPatternId('x'): {'category': 'Groceries', 'pattern': 'x', 'order': 1, 'minCents': 500, 'maxCents': 100},
        merchantPatternId('y'): {'category': 'Groceries', 'pattern': 'y', 'order': 2, 'minCents': -1},
        merchantPatternId('z'): {'category': 'Groceries', 'pattern': 'z', 'order': 3, 'match': 'glob'},
      });
      expect(st.patternRules.map((p) => (p.pattern, p.match, p.minCents, p.maxCents)),
          [('acme', 'regex', null, null), ('x', 'regex', null, null), ('y', 'regex', null, null)]);
      expect(st.merchantPatterns, [
        ['Groceries', 'acme'],
        ['Groceries', 'x'],
        ['Groceries', 'y']
      ]);
    });

    test('toMap / fromMap keep match and range', () {
      final st = WalletSettings.fromMap({
        merchantPatternId('acme'): {'category': 'Groceries', 'pattern': 'acme', 'order': 0, 'match': 'contains', 'maxCents': 900},
        merchantPatternId('b+'): {'category': 'Shopping', 'pattern': 'b+', 'order': 1},
      });
      final back = WalletSettings.fromMap(st.toMap());
      expect(back.patternRules.map((p) => (p.id, p.category, p.pattern, p.match, p.minCents, p.maxCents)),
          st.patternRules.map((p) => (p.id, p.category, p.pattern, p.match, p.minCents, p.maxCents)));
      expect(st.toMap()['merchantPatterns'], [
        ['Groceries', 'acme', 'contains', null, 900],
        ['Shopping', 'b+']
      ]);
    });
  });

  group('writes', () {
    test('setMerchantPattern: contains is trimmed and 1–60 characters; range checks; a plain regex row is stored as before', () {
      final r = WalletRepo.inMemory();
      r.setMerchantPattern('Groceries', 'acme');
      expect(_value(r, merchantPatternId('acme')), {'category': 'Groceries', 'pattern': 'acme', 'order': 0});
      r.setMerchantPattern('Groceries', '  Bäckerei  ', match: 'contains', minCents: 100, maxCents: 100);
      expect(_value(r, merchantPatternId('Bäckerei')),
          {'category': 'Groceries', 'pattern': 'Bäckerei', 'order': 1, 'match': 'contains', 'minCents': 100, 'maxCents': 100});
      for (final bad in <void Function()>[
        () => r.setMerchantPattern('Groceries', '   ', match: 'contains', minCents: 1),
        () => r.setMerchantPattern('Groceries', '', minCents: 1, maxCents: 2),
        () => r.setMerchantPattern('Groceries', 'x' * 61, match: 'contains'),
        () => r.setMerchantPattern('Groceries', 'x', minCents: 5, maxCents: 4),
        () => r.setMerchantPattern('Groceries', 'x', minCents: -1),
        () => r.setMerchantPattern('Groceries', 'x', maxCents: WalletSettings.maxAmount + 1),
        () => r.setMerchantPattern('Groceries', 'x', match: 'glob'),
        () => r.setMerchantPattern('Groceries', '(', match: 'regex'),
      ]) {
        expect(bad, throwsArgumentError);
      }
      r.setMerchantPattern('Groceries', '(', match: 'contains'); // a contains text never compiles as a regex
      final before = _outbox(r);
      r.setMerchantPattern('Groceries', 'acme');
      expect(_outbox(r), before, reason: 'unchanged: nothing written');
    });

    test('updateMerchantPattern: category or range keeps the id; a text change keeps the order in one write', () {
      final r = WalletRepo.inMemory();
      r.setMerchantPattern('Groceries', 'a');
      r.setMerchantPattern('Groceries', 'b');
      r.setMerchantPattern('Groceries', 'c');
      final b = merchantPatternId('b');
      expect(r.updateMerchantPattern(b, category: 'Shopping', minCents: 100), b);
      expect(_value(r, b), {'category': 'Shopping', 'pattern': 'b', 'order': 1, 'minCents': 100});
      expect(r.updateMerchantPattern(b, maxCents: 500), b);
      expect(r.settings().patternRules[1].maxCents, 500);
      expect(r.settings().patternRules[1].minCents, 100);
      expect(r.updateMerchantPattern(b, clearRange: true), b);
      expect(r.settings().patternRules[1].hasRange, isFalse);
      final ops = _outbox(r);
      final nb = r.updateMerchantPattern(b, pattern: 'bee', match: 'contains');
      expect(nb, merchantPatternId('bee'));
      expect(_outbox(r), ops + 2, reason: 'new row + tombstone');
      expect(r.settings().patternRules.map((p) => p.pattern), ['a', 'bee', 'c']);
      expect(r.settings().patternRules[1].order, 1);
      expect(() => r.updateMerchantPattern(b), throwsArgumentError, reason: 'removed');
      expect(() => r.updateMerchantPattern(nb, pattern: 'a'), throwsArgumentError, reason: 'text taken');
      expect(() => r.updateMerchantPattern(nb, minCents: 9, maxCents: 1), throwsArgumentError);
      final same = _outbox(r);
      r.updateMerchantPattern(nb, category: 'Shopping');
      expect(_outbox(r), same);
    });

    test('updateMerchantPattern edits a legacy-map entry that has no row yet', () {
      final r = WalletRepo.inMemory();
      r.applyRemote([
        Op(
            'setting',
            'merchantPatterns',
            {
              'value': jsonEncode([
                ['Groceries', 'old']
              ]),
              'deleted': 0
            },
            r.clock.tick().toString())
      ]);
      final id = merchantPatternId('old');
      expect(r.settings().patternRules.single.id, id);
      expect(r.updateMerchantPattern(id, category: 'Shopping'), id);
      expect(_value(r, id), {'category': 'Shopping', 'pattern': 'old', 'order': 0}, reason: 'written as its own row');
      expect(r.settings().patternRules.single.category, 'Shopping');
    });

    test('movePattern swaps with the neighbour; nothing at the ends; ties are renumbered', () {
      final r = WalletRepo.inMemory();
      for (final p in ['a', 'b', 'c']) {
        r.setMerchantPattern('Groceries', p);
      }
      List<String> order() => r.settings().patternRules.map((p) => p.pattern).toList();
      r.movePattern(merchantPatternId('c'), MoveDirection.up);
      expect(order(), ['a', 'c', 'b']);
      final ops = _outbox(r);
      r.movePattern(merchantPatternId('a'), MoveDirection.up);
      r.movePattern(merchantPatternId('b'), MoveDirection.down);
      expect(_outbox(r), ops);
      expect(() => r.movePattern('pattern:0000000000000000', MoveDirection.up), throwsArgumentError);
      // Two rows with the same order (two devices adding at once).
      r.applyRemote([
        Op(
            'setting',
            merchantPatternId('d'),
            {
              'value': jsonEncode({'category': 'Shopping', 'pattern': 'd', 'order': 2}),
              'deleted': 0
            },
            r.clock.tick().toString())
      ]);
      final tied = order();
      final last = tied.last;
      r.movePattern(merchantPatternId(last), MoveDirection.up);
      final now = order();
      expect(now.indexOf(last), tied.indexOf(last) - 1);
      expect(r.settings().patternRules.map((p) => p.order).toSet().length, 4, reason: 'distinct orders now');
    });

    test('logs carry no pattern, payee or amount', () {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = was;
      });
      final r = WalletRepo.inMemory();
      r.setMerchantPattern('Groceries', 'zzsecretshop', match: 'contains', minCents: 4321, maxCents: 98765);
      r.updateMerchantPattern(merchantPatternId('zzsecretshop'), pattern: 'zzothershop');
      r.setMerchantPattern('Groceries', 'qqq');
      r.movePattern(merchantPatternId('qqq'), MoveDirection.up);
      r.categorizer();
      final all = lines.join('\n');
      for (final s in ['zzsecretshop', 'zzothershop', 'qqq', '4321', '98765', merchantPatternId('qqq').substring(8)]) {
        expect(all.contains(s), isFalse, reason: s);
      }
      expect(all, contains('settings.pattern'));
    });

    test('two devices edit the same pattern offline: last writer wins on the row', () async {
      var now = 1767225600000;
      final net = Net();
      final key = VaultKey.generate();
      final a = Device('a', null, key, () => now), b = Device('b', null, key, () => now);
      addTearDown(a.close);
      addTearDown(b.close);
      Future<void> round() async {
        for (final d in [a, b]) {
          now += 1000;
          d.deliver(net, Random(1));
          await d.run();
        }
      }

      a.repo.setMerchantPattern('Groceries', 'acme', match: 'contains');
      await round();
      await round();
      final id = merchantPatternId('acme');
      a.repo.updateMerchantPattern(id, minCents: 100);
      now += 10;
      b.repo.updateMerchantPattern(id, category: 'Shopping');
      await round();
      await round();
      for (final d in [a, b]) {
        final p = d.repo.settings().patternRules.single;
        expect((p.category, p.minCents), ('Shopping', null), reason: d.name);
      }
    });
  });

  group('rulesView and ruleHits', () {
    test('sorted payee rules, patterns, payee tags, built-ins; labels through the table', () {
      final tags = TagTable.from(const [TagRow(id: 't000000000001', name: 'Work', position: 0)]);
      final st = WalletSettings.fromMap({
        merchantPatternId('b'): {'category': 'Groceries', 'pattern': 'b', 'order': 1},
        merchantPatternId('a'): {'category': 'Shopping', 'pattern': 'a', 'order': 0, 'match': 'contains', 'minCents': 1, 'maxCents': 2},
      });
      final v = rulesView(
          st,
          const [MerchantRule('zed_shop', 'Groceries'), MerchantRule('acme', 'Rent')],
          {
            'acme': {'t000000000001'},
            'tags_only': {'t000000000001'},
            'dead': {'tgone'}
          },
          tags,
          CategoryTable.builtIn);
      expect(v.map((r) => r.id).take(6),
          ['payee:acme', 'payee:zed_shop', merchantPatternId('a'), merchantPatternId('b'), 'payeeTags:tags_only', 'builtIn:0']);
      expect(v.length, 5 + builtInMerchantRules.length);
      expect((v[0].kind, v[0].text, v[0].category, v[0].categoryLabel, v[0].editable), (RuleKind.payee, 'acme', 'Rent', 'Rent', true));
      expect(v[0].tags, ['t000000000001']);
      expect(v[1].text, 'zed shop');
      expect(v[1].tags, isEmpty);
      expect((v[2].kind, v[2].match, v[2].minCents, v[2].maxCents, v[2].order), (RuleKind.pattern, 'contains', 1, 2, 0));
      expect((v[4].kind, v[4].category), (RuleKind.payeeTags, null));
      expect(v[4].tags, ['t000000000001']);
      expect((v[5].kind, v[5].editable, v[5].category), (RuleKind.builtIn, false, builtInMerchantRules[0].$1));
    });

    test('ruleHits counts live home-currency rows per rule; an edit preview is a second categorizer', () {
      final id = merchantPatternId('acme');
      MerchantPattern rule({int? max}) => MerchantPattern(id: id, category: 'Groceries', pattern: 'acme', maxCents: max);
      final rows = [
        _card('1', 'acme', -500),
        _card('2', 'acme', -1500),
        _card('3', 'acme', -500, currency: 'USD'),
        _card('4', 'acme', -500, deleted: true),
        _card('5', 'acme', -500, category: 'Shopping'),
        _card('6', 'lidl', -500),
        _card('7', 'unknown', -500),
      ];
      final before = ruleHits(rows, Categorizer(patternRules: [rule()]), currency: 'EUR');
      expect(before[id], 2);
      expect(before.values.fold(0, (a, b) => a + b), 3, reason: 'plus the built-in Lidl row');
      final after = ruleHits(rows, Categorizer(patternRules: [rule(max: 1000)]), currency: 'EUR');
      expect(after[id], 1, reason: 'the 15.00 row would leave the rule');
    });

    test('repo: payeeRules and categorizer use the stored rules', () {
      final r = WalletRepo.inMemory();
      r.setMerchantRule('acme', 'Groceries');
      r.setMerchantPattern('Shopping', 'shop', match: 'contains', minCents: 100);
      expect(r.payeeRules(), [const MerchantRule('acme', 'Groceries')]);
      final cz = r.categorizer(withTags: false);
      expect(cz.ruleFor(_card('1', 'Big SHOP', -100)), merchantPatternId('shop'));
      expect(cz.ruleFor(_card('2', 'Big SHOP', -99)), isNull);
    });
  });
}
