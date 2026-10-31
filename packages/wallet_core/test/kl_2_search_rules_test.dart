// KL-A item 2: search also finds merchant rules by their pattern text, payee and category (`SearchResult.rules`).
// Synthetic data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

SearchResult find(String q, List<RuleView> rules, {CategoryTable? table}) =>
    searchAll(q, txs: const [], goals: const [], wishlist: const [], bills: const [], rules: rules, table: table ?? CategoryTable.builtIn);

void main() {
  final rules = [
    const RuleView(kind: RuleKind.payee, id: 'payee:synth_bakery', text: 'synth bakery', match: 'payee', category: 'Groceries'),
    const RuleView(kind: RuleKind.pattern, id: 'pattern:0000000000000001', text: 'Čokolada', match: 'contains', category: 'Shopping'),
    const RuleView(
        kind: RuleKind.pattern, id: 'pattern:0000000000000002', text: r'^synth\s+gym', match: 'regex', category: 'Sport & fitness'),
    const RuleView(kind: RuleKind.payeeTags, id: 'payeeTags:tag_only_payee', text: 'tag only payee', match: 'payee'),
  ];

  test('a rule matches by its pattern text, folded (case and accents)', () {
    expect(find('cokol', rules).rules.map((r) => r.id), ['pattern:0000000000000001']);
    expect(find('SYNTH\\S', rules).rules.map((r) => r.id), ['pattern:0000000000000002'], reason: 'a regex by its source');
  });

  test('a payee rule matches by its name or its key', () {
    expect(find('bakery', rules).rules.single.id, 'payee:synth_bakery');
    expect(find('synth_bak', rules).rules.single.id, 'payee:synth_bakery');
    expect(find('only payee', rules).rules.single.kind, RuleKind.payeeTags);
  });

  test('a rule matches by its category id or label', () {
    expect(find('groceries', rules).rules.single.id, 'payee:synth_bakery');
    final t = CategoryTable.from([const CategoryRow(id: 'Sport & fitness', name: 'Synthetic hobbies', kind: BudgetKind.flex)]);
    expect(find('hobbies', rules, table: t).rules.single.id, 'pattern:0000000000000002');
  });

  test('a match makes the result non-empty; no match leaves it empty', () {
    expect(find('bakery', rules).isEmpty, isFalse);
    final none = find('nothing-like-this', rules);
    expect(none.rules, isEmpty);
    expect(none.isEmpty, isTrue);
    expect(find('   ', rules).rules, isEmpty);
  });

  test('input order, at most searchRuleLimit', () {
    final many = [
      for (var i = 0; i < 70; i++)
        RuleView(
            kind: RuleKind.pattern,
            id: 'pattern:${i.toString().padLeft(16, '0')}',
            text: 'synth $i',
            match: 'contains',
            category: 'Sport & fitness')
    ];
    final got = find('synth', many).rules;
    expect(got, hasLength(searchRuleLimit));
    expect(searchRuleLimit, 50);
    expect(got.first.id, many.first.id);
    expect(got.last.id, many[49].id);
  });

  test('with a filter only payments come back (rules stay empty)', () {
    final r = searchAll('bakery',
        txs: const [], goals: const [], wishlist: const [], bills: const [], rules: rules, filter: const SearchFilter(minCents: 1));
    expect(r.rules, isEmpty);
  });

  test('rules from rulesView: a deleted payee rule is not listed, so never found', () {
    final repo = WalletRepo.inMemory();
    addTearDown(repo.close);
    repo.setMerchantRule('synth_florist', 'Shopping');
    repo.setMerchantRule('synth_gone', 'Shopping');
    repo.removeMerchantRule('synth_gone');
    final view = rulesView(repo.settings(), repo.payeeRules(), const {}, TagTable.from(const []), repo.categoryTable());
    expect(find('synth_', view).rules.map((r) => r.id), ['payee:synth_florist']);
  });
}
