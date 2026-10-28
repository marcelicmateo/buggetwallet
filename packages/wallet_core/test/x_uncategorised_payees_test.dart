// Stage X step 6: payees whose bank rows nothing decides yet. All data SYNTHETIC (made-up shop names that no
// built-in rule knows, made-up amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

Tx _bank(String date, String desc,
        {String? category,
        int cents = -1500,
        String source = 'pbz',
        String type = 'POS plaćanje',
        bool deleted = false,
        bool manual = false,
        TxKind? kind,
        String? transferTo,
        String? id}) =>
    Tx(
        id: id ?? 'x6-${(_seq++).toString().padLeft(4, '0')}',
        source: manual ? 'manual' : source,
        date: date,
        amount: cents,
        bankType: type,
        description: desc,
        category: category,
        manual: manual,
        kindHint: kind,
        transferTo: transferTo,
        deleted: deleted);

/// [n] rows of [desc] on consecutive January days from [day].
List<Tx> _rows(String desc, int n, {int day = 1, int cents = -1500, String? category}) => [
      for (var i = 0; i < n; i++) _bank('2026-01-${(day + i).toString().padLeft(2, '0')}', desc, cents: cents, category: category),
    ];

void main() {
  final cz = Categorizer();

  group('uncategorisedPayees', () {
    test('fallback rows are counted per payee, name from the newest row', () {
      final rows = [
        _bank('2026-01-02', 'POS ZZ ALPHA SHOP 1'),
        _bank('2026-01-09', 'POS ZZ ALPHA SHOP 2'),
        _bank('2026-01-05', 'POS ZZ ALPHA SHOP 3'),
        _bank('2026-01-03', 'POS ZZ BETA KIOSK'),
      ];
      expect(uncategorisedPayees(rows, cz), [
        const PayeeCount('zz_alpha_shop', 'ZZ ALPHA SHOP 2', 3),
        const PayeeCount('zz_beta_kiosk', 'ZZ BETA KIOSK', 1),
      ]);
    });

    test('a revolut card row and a non-POS pbz row fall back too', () {
      final rows = [
        _bank('2026-01-02', 'ZZ GAMMA STORE', source: 'revolut', type: 'Card Payment'),
        _bank('2026-01-03', 'ZZ DELTA UTILITY', type: 'Nalog'),
      ];
      expect(uncategorisedPayees(rows, cz).map((p) => p.merchantKey), ['zz_delta_utility', 'zz_gamma_store']);
    });

    test('rows decided by something else are left out', () {
      final withRules = Categorizer(
        merchantRules: {'zz_ruled_shop': 'Groceries'},
        patterns: [
          ['Groceries', 'zz pattern']
        ],
      );
      final rows = [
        ..._rows('POS ZZ RULED SHOP', 2),
        ..._rows('POS ZZ PATTERN MART', 2),
        ..._rows('POS NETFLIX COM', 2),
        ..._rows('POS ZZ OWNER SET', 2, category: 'Groceries'),
        _bank('2026-01-03', 'POS ZZ SALARY CO', kind: TxKind.salary),
        _bank('2026-01-04', 'POS ZZ ATM SPOT', kind: TxKind.atm),
        _bank('2026-01-05', 'POS ZZ FEE DESK', kind: TxKind.fee),
        _bank('2026-01-06', 'POS ZZ OWN MOVE', kind: TxKind.ownTransfer),
        _bank('2026-01-07', 'POS ZZ EXCHANGE', kind: TxKind.exchange),
        _bank('2026-01-08', 'POS ZZ PAIRED', transferTo: 'other'),
        _bank('2026-01-09', 'ZZ HAND ADDED', manual: true),
        _bank('2026-01-10', 'POS ZZ DELETED', deleted: true),
        _bank('2026-01-11', 'POS ZZ KEPT'),
      ];
      expect(uncategorisedPayees(rows, withRules), [const PayeeCount('zz_kept', 'ZZ KEPT', 1)]);
    });

    test('a split row is left out', () {
      final r = _bank('2026-01-02', 'POS ZZ SPLIT SHOP', cents: -1000, id: 'x6-split');
      final withSplit = Categorizer(splits: {
        'x6-split': const [SplitPart(amount: -600, category: 'Groceries'), SplitPart(amount: -400, category: 'Shopping')]
      });
      expect(uncategorisedPayees([r], withSplit), isEmpty);
      expect(uncategorisedPayees([r], cz), hasLength(1));
    });

    test('a dead own category does not decide', () {
      expect(uncategorisedPayees([_bank('2026-01-02', 'POS ZZ DEAD CAT', category: 'kdeadcategory0')], cz), hasLength(1));
    });

    test('a payee with no name is skipped', () {
      final rows = [_bank('2026-01-02', 'POS 123 456'), _bank('2026-01-03', 'POS ***'), _bank('2026-01-04', 'POS ZZ NAMED')];
      expect(uncategorisedPayees(rows, cz).map((p) => p.merchantKey), ['zz_named']);
    });

    test('order: count desc, newest date desc, key; equal counts', () {
      final rows = [
        ..._rows('POS ZZ TWO OLD', 2, day: 1),
        ..._rows('POS ZZ TWO NEW', 2, day: 10),
        ..._rows('POS ZZ TWO NEWER', 2, day: 10),
        ..._rows('POS ZZ THREE', 3, day: 1),
        _bank('2026-02-01', 'POS ZZ ONE'),
      ];
      expect(uncategorisedPayees(rows, cz).map((p) => p.merchantKey), ['zz_three', 'zz_two_new', 'zz_two_newer', 'zz_two_old', 'zz_one']);
    });

    test('amounts never rank', () {
      final rows = [
        ..._rows('POS ZZ SMALL', 2, cents: -100),
        _bank('2026-01-01', 'POS ZZ HUGE', cents: -9000000),
        _bank('2026-01-02', 'POS ZZ HUGE', cents: -9000000),
        _bank('2026-01-03', 'POS ZZ HUGE', cents: -9000000),
      ];
      expect(uncategorisedPayees(rows, cz).map((p) => p.merchantKey), ['zz_huge', 'zz_small']);
    });

    test('limit caps the list (default 10)', () {
      final rows = [
        for (var i = 0; i < 12; i++) _bank('2026-01-${(i + 1).toString().padLeft(2, '0')}', 'POS ZZ SHOP ${'abcdefghijkl'[i]}')
      ];
      expect(uncategorisedPayees(rows, cz), hasLength(10));
      expect(uncategorisedPayees(rows, cz, limit: 3), hasLength(3));
      expect(uncategorisedPayees(rows, cz, limit: 0), isEmpty);
    });

    test('PayeeCount equality', () {
      expect(const PayeeCount('a', 'A', 2), const PayeeCount('a', 'A', 2));
      expect(const PayeeCount('a', 'A', 2).hashCode, const PayeeCount('a', 'A', 2).hashCode);
      expect(const PayeeCount('a', 'A', 2) == const PayeeCount('a', 'A', 3), isFalse);
    });
  });
}
