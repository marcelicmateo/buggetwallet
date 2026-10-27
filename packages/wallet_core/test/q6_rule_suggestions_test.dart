// Q6 core: payee rules suggested from the owner's own category choices. All data SYNTHETIC (made-up shop names
// that no built-in rule knows, made-up amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

Tx _bank(String date, String desc, {String? category, int cents = -1500, String source = 'pbz', bool deleted = false, String? id}) => Tx(
    id: id ?? 'q6-${(_seq++).toString().padLeft(4, '0')}',
    source: source,
    date: date,
    amount: cents,
    bankType: 'POS plaćanje',
    description: desc,
    category: category,
    deleted: deleted);

/// [n] rows of [desc] on consecutive January days from [day], each set to [category] by hand (null = automatic).
List<Tx> _rows(String desc, int n, String? category, {int day = 1, int cents = -1500}) => [
      for (var i = 0; i < n; i++) _bank('2026-01-${(day + i).toString().padLeft(2, '0')}', desc, category: category, cents: cents),
    ];

void main() {
  final cz = Categorizer();

  group('ruleSuggestions', () {
    test('three of the last five agreeing make a suggestion; two do not', () {
      final rows = [
        ..._rows('POS CINESTAR ZAGREB', 3, 'Eating out'),
        ..._rows('POS KINOTEKA ZAGREB', 2, 'Eating out'),
      ];
      expect(ruleSuggestions(rows, cz), [const RuleSuggestion('cinestar_zagreb', 'CINESTAR ZAGREB', 'Eating out', 3)]);
    });

    test('only the newest five count: older agreeing rows do not', () {
      final rows = [
        ..._rows('POS CINESTAR ZAGREB', 4, 'Eating out', day: 1),
        ..._rows('POS CINESTAR ZAGREB', 3, null, day: 10),
        ..._rows('POS CINESTAR ZAGREB', 2, 'Eating out', day: 20),
      ];
      // Newest five: 2 × Eating out (20th, 21st) + 3 automatic → too few.
      expect(ruleSuggestions(rows, cz), isEmpty);
      // One more agreeing row on top: three of the newest five.
      expect(ruleSuggestions([...rows, _bank('2026-01-25', 'POS CINESTAR ZAGREB', category: 'Eating out')], cz).single.count, 3);
    });

    test('a payee that already has a rule, or was dismissed, is never offered', () {
      final rows = _rows('POS CINESTAR ZAGREB', 4, 'Eating out');
      expect(ruleSuggestions(rows, Categorizer(merchantRules: const {'cinestar_zagreb': 'Shopping'})), isEmpty);
      expect(ruleSuggestions(rows, cz, off: const {'cinestar_zagreb'}), isEmpty);
      expect(ruleSuggestions(rows, cz, off: const {'other'}), hasLength(1));
    });

    test('hand-added, deleted and automatic rows never count', () {
      final rows = [
        ..._rows('POS CINESTAR ZAGREB', 2, 'Eating out'),
        _bank('2026-01-10', 'POS CINESTAR ZAGREB', category: 'Eating out', deleted: true),
        _bank('2026-01-11', 'POS CINESTAR ZAGREB', category: 'Eating out', source: 'manual'),
      ];
      expect(ruleSuggestions(rows, cz), isEmpty);
    });

    test('a deleted custom category is not a choice; a sync duplicate counts for its original', () {
      final table = CategoryTable.from(const [
        CategoryRow(id: 'kaaaaaaaaaaaa', name: 'Cinema', kind: BudgetKind.flex),
        CategoryRow(id: 'kbbbbbbbbbbbb', name: 'Cinema', kind: BudgetKind.flex),
        CategoryRow(id: 'kcccccccccccc', name: 'Gone', kind: BudgetKind.flex, deleted: true),
      ]);
      final c = Categorizer(table: table);
      final rows = [
        ..._rows('POS CINESTAR ZAGREB', 2, 'kaaaaaaaaaaaa'),
        ..._rows('POS CINESTAR ZAGREB', 1, 'kbbbbbbbbbbbb', day: 5),
        ..._rows('POS KINOTEKA ZAGREB', 3, 'kcccccccccccc'),
      ];
      expect(ruleSuggestions(rows, c), [const RuleSuggestion('cinestar_zagreb', 'CINESTAR ZAGREB', 'kaaaaaaaaaaaa', 3)]);
    });

    test('a tie between two categories goes to the one on the newest row', () {
      final rows = [
        ..._rows('POS CINESTAR ZAGREB', 2, 'Shopping', day: 1),
        ..._rows('POS CINESTAR ZAGREB', 2, 'Eating out', day: 3),
      ];
      expect(ruleSuggestions(rows, cz, min: 2).single.category, 'Eating out');
    });

    test('never for rows a payee rule would not decide (income, extra income)', () {
      // Money in from a CSV source is Extra income automatically; a payee rule never applies to it, so making one
      // would drop the owner's own choice.
      final rows = [
        for (var i = 1; i <= 3; i++)
          Tx(id: 'q6-in-$i', source: 'csv:test', date: '2026-01-0$i', amount: 5000, description: 'REFUND DESK', category: 'Shopping'),
      ];
      expect(ruleSuggestions(rows, cz), isEmpty);
    });

    test('the amount is never looked at', () {
      final rows = [
        _bank('2026-01-01', 'POS CINESTAR ZAGREB', category: 'Eating out', cents: -1),
        _bank('2026-01-02', 'POS CINESTAR ZAGREB', category: 'Eating out', cents: -9999999),
        _bank('2026-01-03', 'POS CINESTAR ZAGREB', category: 'Eating out', cents: -1500),
      ];
      expect(ruleSuggestions(rows, cz).single.count, 3);
    });

    test('order: most rows, then the name; min below 1 reads as 1', () {
      final rows = [
        ..._rows('POS KINOTEKA ZAGREB', 3, 'Eating out'),
        ..._rows('POS CINESTAR ZAGREB', 3, 'Eating out'),
        ..._rows('POS ARENA ZAGREB', 4, 'Shopping'),
      ];
      expect([for (final s in ruleSuggestions(rows, cz)) s.merchantKey], ['arena_zagreb', 'cinestar_zagreb', 'kinoteka_zagreb']);
      expect(ruleSuggestions(_rows('POS ARENA ZAGREB', 1, 'Shopping'), cz, min: 0), hasLength(1));
    });

    test('nothing for empty input', () {
      expect(ruleSuggestions(const [], cz), isEmpty);
    });
  });

  group('ruleSuggestionFor', () {
    test('after the third agreeing choice, the edited row stands in for its stored one', () {
      final rows = [
        ..._rows('POS CINESTAR ZAGREB', 2, 'Eating out'),
        _bank('2026-01-09', 'POS CINESTAR ZAGREB', id: 'edited'),
      ];
      expect(ruleSuggestionFor(rows.last, rows, cz), isNull);
      final edited = _bank('2026-01-09', 'POS CINESTAR ZAGREB', id: 'edited', category: 'Eating out');
      expect(ruleSuggestionFor(edited, rows, cz), const RuleSuggestion('cinestar_zagreb', 'CINESTAR ZAGREB', 'Eating out', 3));
    });

    test('null for a hand-added row, a rule already there, a dismissed payee', () {
      final rows = _rows('POS CINESTAR ZAGREB', 3, 'Eating out');
      expect(ruleSuggestionFor(rows.first, rows, cz), isNotNull);
      const manual =
          Tx(id: 'm1', source: 'manual', date: '2026-01-09', amount: -100, category: 'Eating out', note: 'CINESTAR ZAGREB', manual: true);
      expect(ruleSuggestionFor(manual, rows, cz), isNull);
      expect(ruleSuggestionFor(rows.first, rows, Categorizer(merchantRules: const {'cinestar_zagreb': 'Eating out'})), isNull);
      expect(ruleSuggestionFor(rows.first, rows, cz, off: const {'cinestar_zagreb'}), isNull);
    });
  });
}
