// Q1 core: category suggestions while typing a hand-added payment, and recent payee completion. All data SYNTHETIC
// (well-known chains, made-up amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

CategorizedTx _row(String date, String category,
    {String desc = '', String? note, String source = 'pbz', bool deleted = false, String? id, int cents = -1000}) {
  final t = Tx(
      id: id ?? 'q1-${(_seq++).toString().padLeft(4, '0')}',
      source: source,
      date: date,
      amount: cents,
      description: desc,
      note: note,
      category: source == 'manual' ? category : null,
      manual: source == 'manual',
      deleted: deleted);
  return CategorizedTx(t, category, kindOf(category));
}

void main() {
  group('suggestCategoriesForText', () {
    final cz = Categorizer();

    test('a built-in rule comes first, then history by count', () {
      final history = [
        _row('2026-01-02', 'Eating out', desc: 'POS KONZUM CAFE ZAGREB'),
        _row('2026-01-03', 'Eating out', desc: 'POS KONZUM CAFE ZAGREB'),
        _row('2026-01-04', 'Shopping', desc: 'POS KONZUM ONLINE'),
      ];
      expect(suggestCategoriesForText('Konzum', history, cz), ['Groceries', 'Eating out', 'Shopping']);
    });

    test('history ranks by count, then the newest row, then the id', () {
      final history = [
        _row('2026-01-01', 'Shopping', desc: 'POS CINESTAR ZAGREB'),
        _row('2026-01-05', 'Sport & fitness', desc: 'POS CINESTAR ZAGREB'),
        _row('2026-01-02', 'Home & tools', desc: 'POS CINESTAR ZAGREB'),
        _row('2026-01-03', 'Home & tools', desc: 'POS CINESTAR ZAGREB'),
        // Same count and date as each other: the id order decides.
        _row('2026-01-04', 'Health & care', desc: 'POS CINESTAR ZAGREB'),
        _row('2026-01-04', 'Cash', desc: 'POS CINESTAR ZAGREB'),
      ];
      expect(suggestCategoriesForText('cinestar', history, cz, limit: 6),
          ['Home & tools', 'Sport & fitness', 'Cash', 'Health & care', 'Shopping']);
    });

    test('notes match too, accents folded both ways', () {
      final history = [
        _row('2026-01-02', 'Eating out', source: 'manual', note: 'Kava kod Đure'),
        _row('2026-01-03', 'Eating out', desc: 'POS CAFFE DJURE'),
      ];
      expect(suggestCategoriesForText('dure', history, cz), ['Eating out']);
      expect(suggestCategoriesForText('ĐURE', history, cz), ['Eating out']);
    });

    test('text under 3 characters skips the history (rules still apply)', () {
      final history = [_row('2026-01-02', 'Eating out', desc: 'POS ZARA ZAGREB')];
      expect(suggestCategoriesForText('za', history, cz), isEmpty);
      expect(suggestCategoriesForText('zar', history, cz), ['Eating out']);
      expect(suggestCategoriesForText('a1', const [], cz), ['Bills & subscriptions']);
      expect(suggestCategoriesForText('   ', history, cz), isEmpty);
    });

    test('deleted rows never count; the amount never matters', () {
      final history = [
        _row('2026-01-02', 'Eating out', desc: 'POS IKEA ZAGREB', deleted: true),
        _row('2026-01-03', 'Home & tools', desc: 'POS IKEA ZAGREB', cents: -999999),
      ];
      expect(suggestCategoriesForText('ikea', history, cz), ['Home & tools']);
    });

    test('hidden and deleted categories are never offered; a rule and the history give one entry', () {
      final table = CategoryTable.from(const [
        CategoryRow(id: 'Eating out', hidden: true),
        CategoryRow(id: 'kaaaaaaaaaaaa', name: 'Old one', kind: BudgetKind.flex, deleted: true),
        CategoryRow(id: 'kbbbbbbbbbbbb', name: 'Coffee', kind: BudgetKind.flex),
      ]);
      final c = Categorizer(table: table);
      final history = [
        _row('2026-01-01', 'Eating out', desc: 'POS LIDL CAFE'),
        _row('2026-01-02', 'Eating out', desc: 'POS LIDL CAFE'),
        _row('2026-01-03', 'kaaaaaaaaaaaa', desc: 'POS LIDL CAFE'),
        _row('2026-01-04', 'kbbbbbbbbbbbb', desc: 'POS LIDL CAFE'),
        _row('2026-01-05', 'Groceries', desc: 'POS LIDL CAFE'),
      ];
      expect(suggestCategoriesForText('lidl', history, c), ['Groceries', 'kbbbbbbbbbbbb']);
    });

    test('a pattern rule to a hidden category is skipped', () {
      final c = Categorizer(table: CategoryTable.from(const [CategoryRow(id: 'Groceries', hidden: true)]), patterns: const []);
      expect(suggestCategoriesForText('lidl', const [], c), isEmpty);
    });

    test('kinds and exclude match the Add expense picker on every step, before the limit (review fix)', () {
      // Without kinds, "revolut" offered Internal transfer first: one tap made a cash expense count nowhere.
      const sheet = {BudgetKind.flex};
      final transfers = [
        for (var i = 1; i <= 3; i++) _row('2026-01-0$i', 'Internal transfer', desc: 'REVOLUT TOPUP'),
        _row('2026-01-05', 'Salary', desc: 'REVOLUT PAYOUT'),
        _row('2026-01-06', 'Bank fees', desc: 'REVOLUT FEE'),
      ];
      final history = [...transfers, _row('2026-01-04', 'Shopping', desc: 'Revolut shop')];
      expect(suggestCategoriesForText('revolut', history, cz, limit: 1), ['Internal transfer']);
      expect(suggestCategoriesForText('revolut', history, cz, limit: 1, kinds: sheet, exclude: const {'Bank fees'}), ['Shopping']);
      expect(suggestCategoriesForText('revolut', transfers, cz, kinds: sheet, exclude: const {'Bank fees'}), isEmpty);
      expect(suggestCategoriesForText('revolut', transfers, cz, kinds: sheet), ['Bank fees']);
      // The rule step too: Netflix's built-in rule is a fixed tag.
      expect(suggestCategoriesForText('netflix', const [], cz), ['Bills & subscriptions']);
      expect(suggestCategoriesForText('netflix', const [], cz, kinds: sheet), isEmpty);
    });

    test('limit', () {
      final history = [
        for (final cat in ['Shopping', 'Cash', 'Home & tools', 'Eating out']) _row('2026-01-02', cat, desc: 'POS BAUHAUS ZAGREB'),
      ];
      expect(suggestCategoriesForText('bauhaus', history, cz), hasLength(3));
      expect(suggestCategoriesForText('bauhaus', history, cz, limit: 0), isEmpty);
    });
  });

  group('recentPayees', () {
    test('names starting with the prefix first, then those containing it, each newest first', () {
      final history = [
        _row('2026-01-01', 'Groceries', desc: 'POS LIDL HRVATSKA ZAGREB'),
        _row('2026-01-05', 'Groceries', desc: 'POS KAUFLAND ZAGREB'),
        _row('2026-01-03', 'Shopping', desc: 'POS ZARA ZAGREB'),
        _row('2026-01-04', 'Eating out', source: 'manual', note: 'Zagreb market'),
      ];
      expect(recentPayees(history, 'zag'), ['Zagreb market', 'KAUFLAND ZAGREB', 'ZARA ZAGREB', 'LIDL HRVATSKA ZAGREB']);
    });

    test('distinct by folded name, spelled as the newest row; accents folded', () {
      final history = [
        _row('2026-01-01', 'Eating out', source: 'manual', note: 'Pekara Đuro'),
        _row('2026-01-02', 'Eating out', source: 'manual', note: 'pekara djuro'),
        _row('2026-01-03', 'Eating out', source: 'manual', note: 'Pekara Duro '),
      ];
      expect(recentPayees(history, 'pek'), ['Pekara Duro']);
      expect(recentPayees(history, 'đur'), ['Pekara Duro']);
    });

    test('hand-added rows without a note never offer their category; deleted rows never count', () {
      final history = [
        _row('2026-01-01', 'Groceries', source: 'manual'),
        _row('2026-01-02', 'Shopping', desc: 'POS SPAR 0000 ZAGREB', deleted: true),
      ];
      expect(recentPayees(history, 'gro'), isEmpty);
      expect(recentPayees(history, 'spar'), isEmpty);
    });

    test('a bank row offers its merchant name and its note', () {
      final history = [_row('2026-01-01', 'Groceries', desc: 'POS DM DROGERIE ZAGREB', note: 'DM gifts')];
      expect(recentPayees(history, 'dm'), ['DM DROGERIE ZAGREB', 'DM gifts']);
    });

    test('blank prefix = the newest names; limit', () {
      final history = [
        for (var i = 1; i <= 7; i++) _row('2026-01-0$i', 'Shopping', desc: 'POS SHOP $i ZAGREB'),
      ];
      expect(recentPayees(history, ''), ['SHOP 7 ZAGREB', 'SHOP 6 ZAGREB', 'SHOP 5 ZAGREB', 'SHOP 4 ZAGREB', 'SHOP 3 ZAGREB']);
      expect(recentPayees(history, ' ', limit: 2), hasLength(2));
      expect(recentPayees(history, 'shop', limit: 0), isEmpty);
    });
  });
}
