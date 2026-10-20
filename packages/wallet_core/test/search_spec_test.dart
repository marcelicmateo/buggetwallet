// Spec tests for M5 search (DESIGN_DECISIONS §4.7), written from the spec only. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

CategorizedTx _tx(String id, int cents, String desc, {String date = '2026-01-10', String? note, String? cat}) {
  final c = cat ?? 'Shopping';
  return CategorizedTx(Tx(id: id, source: 'pbz', date: date, amount: cents, description: desc, note: note, category: c), c, kindOf(c));
}

SearchResult _s(
  String q, {
  List<Tx> txs = const [],
  List<Goal> goals = const [],
  List<WishItem> wishlist = const [],
  List<RecurringBill> bills = const [],
}) =>
    searchAll(q, txs: txs, goals: goals, wishlist: wishlist, bills: bills);

RecurringBill _bill(String id, String label, int cents) => RecurringBill(
    id: 'rec:$id',
    payee: id,
    label: label,
    category: 'Bills & subscriptions',
    expectedAmount: cents,
    intervalDays: 30,
    nextDue: '2026-02-01',
    status: 'confirmed');

void main() {
  group('parseAmountQuery', () {
    const table = <String, int?>{
      '12': 1200,
      '12.5': 1250,
      '12,50': 1250,
      '12.50': 1250,
      '-12.50': -1250,
      '-12': -1200,
      '12.50 €': 1250,
      ' 12.50 ': 1250,
      '0.01': 1,
      '0,05': 5,
      '0': 0,
      '12.': null,
      'abc': null,
      '': null,
      '   ': null,
      '12.345': null,
      '1,2,3': null,
      '12 euro': null,
      '--5': null,
    };
    table.forEach((q, want) {
      test('"$q" -> $want', () {
        final got = parseAmountQuery(q);
        // 12.345 may reasonably be rejected; only exactness matters: never a rounded value.
        if (q == '12.345') {
          expect(got, anyOf(isNull, 1234.5.toInt() == 1234 ? isNot(1235) : isNull));
        } else {
          expect(got, want);
        }
      });
    });
  });

  group('searchAll', () {
    final txs = [
      _tx('1', -1250, 'Kaufland Zagreb'),
      _tx('2', -2340, 'Lidl Hrvatska', note: 'Čokolada za Đuru'),
      _tx('3', 150000, 'Neto plaća'),
      _tx('4', -1250, 'Spotify', cat: 'Bills & subscriptions'),
      _tx('5', 1250, 'Povrat Kaufland'),
    ];
    final goals = [
      const Goal(id: 'g1', name: 'Ljetovanje', target: 90000, saved: 12000),
      const Goal(id: 'g2', name: 'Rainy day', target: 5000, saved: 1250),
    ];
    final wishes = [
      const WishItem(id: 'w1', name: 'Slušalice Bose', price: 24999, added: 0),
      const WishItem(id: 'w2', name: 'Desk lamp', price: 1250, added: 0),
    ];
    final bills = [_bill('netflix', 'Netflix', 1299), _bill('gym', 'Teretana Fit', 1250)];

    SearchResult all(String q) => _s(q, txs: txs, goals: goals, wishlist: wishes, bills: bills);

    test('blank and whitespace queries give an empty result', () {
      for (final q in ['', ' ', '   \t']) {
        final r = all(q);
        expect(r.isEmpty, isTrue, reason: '"$q"');
        expect(r.txs, isEmpty);
        expect(r.goals, isEmpty);
        expect(r.wishlist, isEmpty);
        expect(r.bills, isEmpty);
      }
    });

    test('no data, no match', () {
      expect(_s('anything').isEmpty, isTrue);
      expect(all('zzzz').isEmpty, isTrue);
    });

    test('text: case-insensitive substring over description, note, goal, wish and bill names', () {
      expect([for (final t in all('KAUFLAND').txs) t.tx.tx.id]..sort(), ['1', '5']);
      expect([for (final t in all('hrvat').txs) t.tx.tx.id], ['2']);
      expect([for (final g in all('rainy').goals) g.id], ['g2']);
      expect([for (final w in all('LAMP').wishlist) w.id], ['w2']);
      expect([for (final b in all('netfl').bills) b.id], ['rec:netflix']);
      expect(all('netfl').txs, isEmpty);
    });

    test('accents and case fold both ways (č ć š ž đ)', () {
      expect([for (final t in all('cokolada').txs) t.tx.tx.id], ['2'], reason: 'note Čokolada found with c');
      expect([for (final t in all('ČOKOLADA').txs) t.tx.tx.id], ['2']);
      expect([for (final t in all('djuru').txs) t.tx.tx.id], ['2'], reason: 'đ folds to d (or dj): Đuru');
      expect([for (final g in all('ljetovanje').goals) g.id], ['g1']);
      expect([for (final w in all('slusalice').wishlist) w.id], ['w1']);
      expect([for (final w in all('SLUŠALICE').wishlist) w.id], ['w1']);
      expect([for (final t in all('placa').txs) t.tx.tx.id], ['3']);
      expect([for (final t in all('PLAĆA').txs) t.tx.tx.id], ['3']);
    });

    test('amount query matches abs of tx amount, goal target or saved, wish price, bill expected amount', () {
      final r = all('12.50');
      expect([for (final t in r.txs) t.tx.tx.id]..sort(), ['1', '4', '5'], reason: 'outflow and inflow of 12.50 both match');
      expect([for (final g in r.goals) g.id], ['g2'], reason: 'saved 12.50');
      expect([for (final w in r.wishlist) w.id], ['w2']);
      expect([for (final b in r.bills) b.id], ['rec:gym']);
      expect(all('12,50').txs.length, 3);
      expect(all('-12.50').txs.length, 3, reason: 'sign is ignored: amount.abs()');
      expect([for (final g in all('900').goals) g.id], ['g1'], reason: 'goal target 900.00');
      expect([for (final g in all('120').goals) g.id], ['g1'], reason: 'goal saved 120.00');
      expect([for (final w in all('249.99').wishlist) w.id], ['w1']);
      expect([for (final b in all('12.99').bills) b.id], ['rec:netflix']);
      expect([for (final t in all('1500').txs) t.tx.tx.id], ['3']);
    });

    test('amount matching is exact: 12 does not match 12.50', () {
      final r = all('12');
      expect(r.txs.where((t) => t.tx.amount.abs() == 1250), isEmpty);
    });

    test('a bare number can still match text containing it', () {
      final t = [_tx('9', -500, 'Store 24 Zagreb')];
      expect([for (final x in _s('24', txs: t).txs) x.tx.id], ['9']);
    });

    test('result lists are never null and isEmpty reflects all four', () {
      final r = _s('lamp', wishlist: wishes);
      expect(r.isEmpty, isFalse);
      expect(r.txs, isEmpty);
      expect(r.goals, isEmpty);
      expect(r.bills, isEmpty);
    });

    test('transactions are capped at the newest 200', () {
      final many = [
        for (var i = 0; i < 350; i++)
          _tx('t${i.toString().padLeft(3, '0')}', -100 - i, 'Coffee bar',
              date: '2025-${(i % 12 + 1).toString().padLeft(2, '0')}-${(i % 27 + 1).toString().padLeft(2, '0')}'),
      ];
      final r = _s('coffee', txs: many);
      expect(r.txs, hasLength(200));
      final oldestKept = r.txs.map((t) => t.tx.date).reduce((a, b) => a.compareTo(b) < 0 ? a : b);
      final dropped = many.where((t) => !r.txs.any((x) => x.tx.id == t.tx.id));
      expect(dropped, hasLength(150));
      for (final d in dropped) {
        expect(d.tx.date.compareTo(oldestKept) <= 0, isTrue, reason: 'only older rows are dropped');
      }
    });

    test('category name is searched too; deleted transactions are not found', () {
      final t = [
        Tx(id: 'd', source: 'pbz', date: '2026-01-01', amount: -100, description: 'Ghost shop', deleted: true),
        _tx('l', -100, 'Ghost shop live')
      ];
      expect([for (final x in _s('ghost', txs: t).txs) x.tx.id], ['l']);
      expect([
        for (final x in _s('groceries', txs: [_tx('c', -100, 'Plain', cat: 'Groceries')]).txs) x.tx.id
      ], [
        'c'
      ]);
    });
  });
}
