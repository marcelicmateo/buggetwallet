// M5 search, core half: amount parsing, accent folding, what is searched and the cap. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

CategorizedTx _tx(String id, int cents, String desc,
        {String date = '2026-01-10', String? note, String cat = 'Shopping', String? matchedTo, bool deleted = false}) =>
    CategorizedTx(
        Tx(id: id, source: 'pbz', date: date, amount: cents, description: desc, note: note, matchedTo: matchedTo, deleted: deleted),
        cat,
        kindOf(cat));

SearchResult _s(String q,
        {List<CategorizedTx> txs = const [],
        List<Goal> goals = const [],
        List<WishItem> wishlist = const [],
        List<RecurringBill> bills = const []}) =>
    searchAll(q, txs: txs, goals: goals, wishlist: wishlist, bills: bills);

void main() {
  group('parseAmountQuery', () {
    test('accepted forms', () {
      const table = {
        '12': 1200,
        '12.5': 1250,
        '12,5': 1250,
        '12,50': 1250,
        '-12.50': -1250,
        '12.50 €': 1250,
        '12.50€': 1250,
        '  7  ': 700,
        '0': 0,
        '0.00': 0,
        '-0.01': -1,
        '999999999999999': 99999999999999900,
      };
      table.forEach((q, want) => expect(parseAmountQuery(q), want, reason: '"$q"'));
    });

    test('rejected forms: partial, too many decimals, words, signs, separators, too long', () {
      for (final q in [
        '12.',
        '12,',
        '.5',
        '12.345',
        '1,000.00',
        '1.000,00',
        '12 €€',
        '€12',
        'EUR 12',
        '12 euro',
        '+12',
        '--5',
        '-',
        '',
        ' ',
        '1234567890123456',
        '1e3',
        '0x10',
        '12.50 kn'
      ]) {
        expect(parseAmountQuery(q), isNull, reason: '"$q"');
      }
    });
  });

  group('foldText', () {
    test('lower-cases and folds Croatian letters, dj, and common accents', () {
      expect(foldText('ČĆŠŽĐ čćšžđ'), 'ccszd ccszd');
      expect(foldText('Đuro Džip'), 'duro dzip');
      expect(foldText('Djuro'), 'duro', reason: 'the ASCII spelling of đ');
      expect(foldText('Café Müller Straße'), 'cafe muller strasse');
      expect(foldText('ABC 123 €'), 'abc 123 €');
    });
  });

  group('searchAll', () {
    test('matches description, note and category; deleted and replaced entries are never found', () {
      final txs = [
        _tx('d', -100, 'Synthetic market', note: 'weekly'),
        _tx('n', -200, 'Other', note: 'synthetic note'),
        _tx('c', -300, 'Other', cat: 'Groceries'),
        _tx('x', -400, 'Synthetic gone', deleted: true),
        _tx('m', -500, 'Synthetic replaced', matchedTo: 'd'),
      ];
      expect([for (final t in _s('synthetic', txs: txs).txs) t.tx.id], ['n', 'd']);
      expect([for (final t in _s('grocer', txs: txs).txs) t.tx.id], ['c']);
      expect(_s('gone', txs: txs).txs, isEmpty);
      expect(_s('replaced', txs: txs).txs, isEmpty);
    });

    test('a row matching by text and by amount is listed once; newest first, then id descending', () {
      final txs = [
        _tx('a', -1200, 'Twelve 12', date: '2026-01-01'),
        _tx('b', -1200, 'Other', date: '2026-01-03'),
        _tx('c', 1200, 'Refund', date: '2026-01-03'),
        _tx('d', -1250, 'Not twelve', date: '2026-01-04'),
      ];
      expect([for (final t in _s('12', txs: txs).txs) t.tx.id], ['c', 'b', 'a']);
    });

    test('goals by name, target or saved; wishes by name or price; bills by label, category or amount', () {
      const goals = [Goal(id: 'g', name: 'Synthetic fund', target: 90000, saved: 12000)];
      const wishes = [WishItem(id: 'w', name: 'Synthetic lamp', price: 1250, added: 0)];
      const bills = [
        RecurringBill(
            id: 'rec:x', payee: 'x', label: 'Synthetic Stream', category: 'Bills & subscriptions', expectedAmount: 1299, nextDue: '')
      ];
      expect(_s('fund', goals: goals).goals, hasLength(1));
      expect(_s('900', goals: goals).goals, hasLength(1));
      expect(_s('120.00', goals: goals).goals, hasLength(1));
      expect(_s('120.01', goals: goals).goals, isEmpty);
      expect(_s('lamp', wishlist: wishes).wishlist, hasLength(1));
      expect(_s('12,50', wishlist: wishes).wishlist, hasLength(1));
      expect(_s('stream', bills: bills).bills, hasLength(1));
      expect(_s('subscriptions', bills: bills).bills, hasLength(1));
      expect(_s('12.99', bills: bills).bills, hasLength(1));
      expect(_s('-12.99', bills: bills).bills, hasLength(1), reason: 'sign ignored');
      final r = _s('synthetic', goals: goals, wishlist: wishes, bills: bills);
      expect(r.isEmpty, isFalse);
      expect(r.txs, isEmpty);
      expect(r.goals.single.id, 'g');
      expect(r.wishlist.single.id, 'w');
      expect(r.bills.single.id, 'rec:x');
    });

    test('blank query is the empty result; whitespace around a query is ignored', () {
      final txs = [_tx('a', -100, 'Synthetic')];
      expect(_s('  ', txs: txs), same(SearchResult.empty));
      expect(_s(' synth ', txs: txs).txs, hasLength(1));
    });

    test('the cap keeps the newest 200 of more matches, in order', () {
      final many = [
        for (var i = 0; i < 250; i++)
          _tx('t${i.toString().padLeft(3, '0')}', -100, 'Coffee', date: '2025-01-${(i % 28 + 1).toString().padLeft(2, '0')}')
      ];
      final r = _s('coffee', txs: many).txs;
      expect(r, hasLength(searchTxLimit));
      for (var i = 1; i < r.length; i++) {
        final c = r[i - 1].date.compareTo(r[i].date);
        expect(c > 0 || (c == 0 && r[i - 1].tx.id.compareTo(r[i].tx.id) > 0), isTrue, reason: 'newest first at $i');
      }
    });
  });
}
