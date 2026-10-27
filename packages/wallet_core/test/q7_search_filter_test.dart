// Q7 core: search filters (amount, dates, main tags, attachments, split, uncategorised) and match spans for bold
// highlighting. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

CategorizedTx _tx(String id, int cents, String desc,
        {String date = '2026-01-10', String cat = 'Shopping', String? own, bool deleted = false}) =>
    CategorizedTx(
        Tx(id: id, source: 'pbz', date: date, amount: cents, description: desc, category: own, deleted: deleted), cat, kindOf(cat));

SearchResult _s(String q, List<CategorizedTx> txs, SearchFilter? f, {List<Goal> goals = const [], List<Bill> billsDb = const []}) =>
    searchAll(q, txs: txs, goals: goals, wishlist: const [], bills: const [], billsDb: billsDb, filter: f);

List<String> _ids(SearchResult r) => [for (final t in r.txs) t.tx.id];

void main() {
  final txs = [
    _tx('a', -999, 'POS LIDL ZAGREB', date: '2026-01-01', cat: 'Groceries'),
    _tx('b', -1000, 'POS LIDL ZAGREB', date: '2026-01-05', cat: 'Groceries'),
    _tx('c', -5000, 'POS ZARA ZAGREB', date: '2026-01-10', own: 'Shopping'),
    _tx('d', 1000, 'REFUND ZARA', date: '2026-01-15', cat: 'Extra income'),
    _tx('e', -5001, 'POS IKEA ZAGREB', date: '2026-01-31', cat: 'Home & tools'),
    _tx('x', -1000, 'POS LIDL ZAGREB', date: '2026-01-06', cat: 'Groceries', deleted: true),
  ];

  group('SearchFilter', () {
    test('isEmpty: no filter behaves exactly as before', () {
      expect(const SearchFilter().isEmpty, isTrue);
      expect(const SearchFilter(uncategorised: true).isEmpty, isFalse);
      expect(const SearchFilter(split: false).isEmpty, isFalse);
      expect(_s('', txs, const SearchFilter()), same(SearchResult.empty));
      expect(_ids(_s('lidl', txs, const SearchFilter())), ['b', 'a']);
    });

    test('a filter with a blank query lists every live payment that fits, payments only', () {
      final goals = [const Goal(id: 'g', name: 'Zara coat', target: 1000)];
      final r = _s('', txs, const SearchFilter(from: '2026-01-01'), goals: goals);
      expect(_ids(r), ['e', 'd', 'c', 'b', 'a']);
      expect(r.goals, isEmpty);
      // With a query too, other lists stay empty while a filter is on.
      expect(_s('zara', txs, const SearchFilter(from: '2026-01-01'), goals: goals).goals, isEmpty);
      expect(_s('zara', txs, null, goals: goals).goals, hasLength(1));
    });

    test('amount bounds on the absolute amount, inclusive', () {
      expect(_ids(_s('', txs, const SearchFilter(minCents: 1000, maxCents: 5000))), ['d', 'c', 'b']);
      expect(_ids(_s('', txs, const SearchFilter(minCents: 5001))), ['e']);
      expect(_ids(_s('', txs, const SearchFilter(maxCents: 999))), ['a']);
      expect(_ids(_s('', txs, const SearchFilter(minCents: 2000, maxCents: 1000))), isEmpty);
    });

    test('dates inclusive on both ends', () {
      expect(_ids(_s('', txs, const SearchFilter(from: '2026-01-05', to: '2026-01-15'))), ['d', 'c', 'b']);
      expect(_ids(_s('', txs, const SearchFilter(to: '2026-01-01'))), ['a']);
      expect(_ids(_s('', txs, const SearchFilter(from: '2026-01-31'))), ['e']);
    });

    test('query and filter together', () {
      expect(_ids(_s('lidl', txs, const SearchFilter(minCents: 1000))), ['b']);
      expect(_ids(_s('zara', txs, const SearchFilter(categories: {'Extra income'}))), ['d']);
    });

    test('main tags', () {
      expect(_ids(_s('', txs, const SearchFilter(categories: {'Groceries', 'Home & tools'}))), ['e', 'b', 'a']);
      expect(_ids(_s('', txs, const SearchFilter(categories: {'Rent'}))), isEmpty);
    });

    test('a sync duplicate main tag is found by its twin, on rows and on parts (review fix)', () {
      final table = CategoryTable.from(const [
        CategoryRow(id: 'kaaaaaaaaaaaa', name: 'Cinema', kind: BudgetKind.flex),
        CategoryRow(id: 'kbbbbbbbbbbbb', name: 'Cinema', kind: BudgetKind.flex),
      ]);
      expect(table.duplicateOf('kbbbbbbbbbbbb'), 'kaaaaaaaaaaaa');
      const whole = CategorizedTx(
          Tx(id: 's', source: 'pbz', date: '2026-01-20', amount: -3000, description: 'POS CINESTAR ZAGREB'), 'Shopping', BudgetKind.flex);
      final rows = [
        _tx('dup', -700, 'POS CINESTAR ZAGREB', cat: 'kbbbbbbbbbbbb'),
        _tx('orig', -800, 'POS CINESTAR ZAGREB', cat: 'kaaaaaaaaaaaa'),
        _tx('other', -900, 'POS CINESTAR ZAGREB'),
        CategorizedTx(whole.tx, 'Shopping', BudgetKind.flex, amount: -1000, part: 0, parts: 2, whole: whole),
        CategorizedTx(whole.tx, 'kbbbbbbbbbbbb', BudgetKind.flex, amount: -2000, part: 1, parts: 2, whole: whole),
      ];
      List<String> by(String id) => _ids(searchAll('',
          txs: rows, goals: const [], wishlist: const [], bills: const [], table: table, filter: SearchFilter(categories: {id})));
      expect(by('kaaaaaaaaaaaa'), unorderedEquals(['dup', 'orig', 's']));
      expect(by('kbbbbbbbbbbbb'), unorderedEquals(['dup', 'orig', 's']));
    });

    test('uncategorised = the owner never chose the main tag', () {
      expect(_ids(_s('', txs, const SearchFilter(uncategorised: true))), ['e', 'd', 'b', 'a']);
    });

    test('attachments, through a real repo: attachedTxIds() (bills() leaves attachments out)', () {
      // Review fix: the ids came from billsDb, which the app fills from bills(): no attachment there, so the filter
      // found nothing.
      final repo = WalletRepo.inMemory(now: () => DateTime.utc(2026, 1, 20).millisecondsSinceEpoch);
      addTearDown(repo.close);
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-01-02', -2340, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        n('2026-01-03', -5000, 'POS plaćanje', 'POS ZARA ZAGREB'),
        n('2026-01-04', -999, 'POS plaćanje', 'POS IKEA ZAGREB'),
      ]));
      final ids = {for (final t in repo.transactions()) t.description: t.id};
      final konzum = ids['POS KONZUM 0000 ZAGREB']!, zara = ids['POS ZARA ZAGREB']!, ikea = ids['POS IKEA ZAGREB']!;
      BlobRef file(String c) => BlobRef(hash: c * 64, type: 'jpg', bytes: 300);
      repo.addAttachment(konzum, file('a'));
      repo.addAttachment(konzum, file('b'));
      repo.removeAttachment(repo.addAttachment(zara, file('c')));
      expect(repo.bills(), isEmpty);
      expect(repo.attachedTxIds(), {konzum});
      final rows = repo.categorizer().expandAll(repo.transactions());
      SearchResult go(bool has) => searchAll('',
          txs: rows,
          goals: const [],
          wishlist: const [],
          bills: const [],
          billsDb: repo.bills(),
          attachedTx: repo.attachedTxIds(),
          filter: SearchFilter(hasAttachment: has));
      expect(_ids(go(true)), [konzum]);
      expect(_ids(go(false)), [ikea, zara]);
    });

    test('split payments: whole amount, any part main tag, split flag; never uncategorised', () {
      const whole = CategorizedTx(
          Tx(id: 's', source: 'pbz', date: '2026-01-20', amount: -3000, description: 'POS SPAR ZAGREB'), 'Groceries', BudgetKind.flex);
      final parts = [
        CategorizedTx(whole.tx, 'Groceries', BudgetKind.flex, amount: -1000, part: 0, parts: 2, whole: whole),
        CategorizedTx(whole.tx, 'Health & care', BudgetKind.flex, amount: -2000, part: 1, parts: 2, whole: whole),
      ];
      final all = [...txs, ...parts];
      expect(_ids(_s('', all, const SearchFilter(split: true))), ['s']);
      expect(_ids(_s('', all, const SearchFilter(split: false))), ['e', 'd', 'c', 'b', 'a']);
      expect(_ids(_s('', all, const SearchFilter(categories: {'Health & care'}))), ['s']);
      // The whole amount (3000) counts, not a part's.
      expect(_ids(_s('', all, const SearchFilter(minCents: 2500, maxCents: 3500))), ['s']);
      expect(_ids(_s('', all, const SearchFilter(minCents: 2000, maxCents: 2000))), isEmpty);
      expect(_ids(_s('', all, const SearchFilter(uncategorised: true))), isNot(contains('s')));
      // A part matched by its amount still names the part.
      expect(_s('20', all, const SearchFilter(split: true)).matchedPart, {'s': 1});
    });
  });

  group('matchSpans', () {
    test('every occurrence, case-insensitive, in the original text', () {
      expect(matchSpans('Lidl and LIDL', 'lidl'), [(0, 4), (9, 13)]);
      expect(matchSpans('POS LIDL', '  lid '), [(4, 7)]);
    });

    test('accents: the match maps back to the original letters', () {
      expect(matchSpans('Čokolada šećer', 'secer'), [(9, 14)]);
      expect(matchSpans('Kod Đure', 'dure'), [(4, 8)]);
    });

    test('dj and ß fold to another length', () {
      // `djuro` folds to `duro`: the span covers the `j`.
      expect(matchSpans('Pekara Djuro', 'duro'), [(7, 12)]);
      expect(matchSpans('Pekara Djuro', 'djuro'), [(7, 12)]);
      expect(matchSpans('Straße 5', 'strasse'), [(0, 6)]);
      expect(matchSpans('Straße 5', 'stras'), [(0, 5)]);
      expect(matchSpans('Kod dj', 'd'), [(2, 3), (4, 6)]);
    });

    test('no match, blank query, empty text', () {
      expect(matchSpans('Lidl', 'spar'), isEmpty);
      expect(matchSpans('Lidl', '  '), isEmpty);
      expect(matchSpans('', 'a'), isEmpty);
    });

    test('hits never overlap: a letter folded to two matches once', () {
      expect(matchSpans('aaa', 'aa'), [(0, 2)]);
      expect(matchSpans('ßß', 's'), [(0, 1), (1, 2)]);
    });
  });
}
