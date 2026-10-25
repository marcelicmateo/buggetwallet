// Stage P6 implementation tests (core-builder): the read model's edge cases (fallbacks, broken and ignored splits,
// tag resolution, order), CSV and search details, and the repo writes' normalisation. SYNTHETIC data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

Tx _bank(String id, int cents, {String desc = 'PBZ POS PBZ7ZORBLEX ZAGREB', String? category, String? transferTo, bool deleted = false}) =>
    Tx(
        id: id,
        source: 'pbz',
        date: '2026-03-12',
        amount: cents,
        bankType: 'POS plaćanje',
        description: desc,
        category: category,
        transferTo: transferTo,
        deleted: deleted);

const _tags = [
  TagRow(id: 'ta', name: 'Trip', position: 0),
  TagRow(id: 'tb', name: 'Work', position: 1),
  TagRow(id: 'tz', name: 'trip', position: 2), // a sync duplicate of ta (same folded name, larger id)
  TagRow(id: 'td', name: 'Gone', position: 3, deleted: true),
];

Categorizer _cz(Map<String, List<SplitPart>> splits, {bool tags = true}) =>
    Categorizer(splits: splits, tagContext: tags ? TagContext(tags: TagTable.from(_tags)) : null);

void main() {
  group('Categorizer.expand', () {
    test('parts in stored order with their fields; the payment counted once in total', () {
      final t = _bank('p', -10000);
      final rows = _cz({
        'p': const [
          SplitPart(amount: -2500, category: 'Groceries', note: 'bread'),
          SplitPart(amount: -7500, category: 'Eating out', tags: ['tb'])
        ]
      }).expand(t);
      expect(rows.map((x) => x.amount), [-2500, -7500]);
      expect(rows.map((x) => x.category), ['Groceries', 'Eating out']);
      expect(rows.map((x) => x.part), [0, 1]);
      expect(rows.every((x) => x.parts == 2 && x.isPart && !x.splitBroken && identical(x.tx, t)), isTrue);
      expect(rows.map((x) => x.partNote), ['bread', null]);
      expect(rows[1].tags, ['tb']);
      expect(rows.fold<int>(0, (s, x) => s + x.amount), t.amount);
    });

    test('part tags: duplicates resolve to the original, dead and unknown ones are dropped, in table order', () {
      final rows = _cz({
        'p': const [
          SplitPart(amount: -1, category: 'Groceries', tags: ['tb', 'tz', 'ta', 'td', 'nope']),
          SplitPart(amount: -1, category: 'Groceries')
        ]
      }).expand(_bank('p', -2));
      expect(rows[0].tags, ['ta', 'tb']);
      expect(rows[1].tags, isEmpty);
    });

    test('part tags are the part list only: no payee rule tags or links of the payment', () {
      final t = _bank('p', -2);
      final cz = Categorizer(
          splits: {
            'p': const [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -1, category: 'Shopping')]
          },
          tagContext: TagContext(tags: TagTable.from(_tags), ruleTags: {
            merchantKey(t): {'ta'}
          }, links: {
            'p': {'tb': true}
          }));
      expect(cz.categorize(t).tags, ['ta', 'tb']);
      expect(cz.expand(t).map((x) => x.tags), [isEmpty, isEmpty]);
    });

    test('no tag context: parts carry no tags', () {
      final rows = _cz({
        'p': const [
          SplitPart(amount: -1, category: 'Groceries', tags: ['ta']),
          SplitPart(amount: -1, category: 'Groceries')
        ]
      }, tags: false)
          .expand(_bank('p', -2));
      expect(rows.map((x) => x.tags), [isEmpty, isEmpty]);
    });

    test('a part with a category that is not live falls back to the automatic one, ignoring the payment override', () {
      final t = _bank('p', -3000, category: 'Eating out'); // owner override on the payment
      final cz = _cz({
        'p': const [SplitPart(amount: -1000, category: 'cDeadCustom'), SplitPart(amount: -2000, category: 'Rent')]
      });
      expect(cz.categorize(t).category, 'Eating out');
      final rows = cz.expand(t);
      expect(rows[0].category, cz.autoCategory(t), reason: 'automatic, not the override');
      expect(rows[0].kind, kindOf(cz.autoCategory(t)));
      expect((rows[1].category, rows[1].kind), ('Rent', BudgetKind.fixed));
    });

    test('a hand-added payment: a dead part category falls back to the entry category', () {
      const t = Tx(id: 'm', source: 'manual', date: '2026-03-12', amount: -3000, category: 'Groceries', manual: true);
      final rows = _cz({
        'm': const [SplitPart(amount: -1000, category: 'cDead'), SplitPart(amount: -2000, category: 'Shopping')]
      }).expand(t);
      expect(rows.map((x) => x.category), ['Groceries', 'Shopping']);
    });

    for (final (why, parts) in [
      ('one cent short', const [SplitPart(amount: -4999, category: 'Groceries'), SplitPart(amount: -5000, category: 'Shopping')]),
      ('one cent over', const [SplitPart(amount: -5001, category: 'Groceries'), SplitPart(amount: -5000, category: 'Shopping')]),
      ('wrong sign', const [SplitPart(amount: -12000, category: 'Groceries'), SplitPart(amount: 2000, category: 'Shopping')]),
      ('a zero part', const [SplitPart(amount: -10000, category: 'Groceries'), SplitPart(amount: 0, category: 'Shopping')]),
      ('one part', const [SplitPart(amount: -10000, category: 'Groceries')]),
      ('unreadable (decoded as empty)', const <SplitPart>[]),
    ]) {
      test('a split that does not fit ($why) is ignored: whole payment, splitBroken', () {
        final t = _bank('p', -10000, category: 'Groceries');
        final rows = _cz({'p': parts}).expand(t);
        expect(rows, hasLength(1));
        expect((rows.single.amount, rows.single.category, rows.single.part, rows.single.parts, rows.single.splitBroken),
            (-10000, 'Groceries', null, 0, true));
      });
    }

    test('a split on a payment that is now a transfer, or not live, is ignored without the broken mark', () {
      const parts = [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -1, category: 'Shopping')];
      for (final t in [
        _bank('p', -2, transferTo: 'other'),
        _bank('p', -2, desc: 'Revolut top-up'), // PBZ text with revolut: an internal transfer
        _bank('p', -2, deleted: true),
      ]) {
        final rows = _cz({'p': parts}).expand(t);
        expect((rows.length, rows.single.isPart, rows.single.splitBroken, rows.single.amount), (1, false, false, -2),
            reason: t.description);
      }
    });

    test('expandAll keeps the input order and expands only split payments', () {
      final cz = _cz({
        'b': const [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -1, category: 'Shopping')]
      });
      final rows = cz.expandAll([_bank('a', -5), _bank('b', -2), _bank('c', -7)]);
      expect(rows.map((x) => '${x.tx.id}${x.part ?? ''}'), ['a', 'b0', 'b1', 'c']);
      expect(wholePayments(rows).map((t) => t.id), ['a', 'b', 'c']);
    });

    test('decodeSplitParts: round trip, and anything malformed reads as empty', () {
      const parts = [
        SplitPart(amount: -1, category: 'Groceries', tags: ['ta'], note: 'x'),
        SplitPart(amount: -2, category: 'Shopping')
      ];
      expect(decodeSplitParts(encodeSplitParts(parts)), parts);
      for (final bad in ['', 'nope', '{}', '[1]', '[{"a":"1","c":"Groceries"}]', '[{"a":1}]', '[{"a":1,"c":"G","t":[1]}]']) {
        expect(decodeSplitParts(bad), isEmpty, reason: bad);
      }
      expect(splitFits(-3, parts), isTrue);
      expect(splitFits(-4, parts), isFalse);
    });
  });

  group('consumers', () {
    final t = _bank('p', -10000, desc: 'PBZ POS PBZ7ZORBLEX ZAGREB');
    final cz = _cz({
      'p': const [
        SplitPart(amount: -5000, category: 'Groceries'),
        SplitPart(amount: -5000, category: 'Groceries', note: 'quorvant', tags: ['ta'])
      ]
    });
    final rows = cz.expand(t);

    test('transactionsCsv marks the parts #1 and #2 in the description, in part order', () {
      final lines = transactionsCsv(rows.reversed.toList()).trim().split('\n');
      expect(lines.sublist(1), [
        '2026-03-12,-50.00,Groceries,PBZ POS PBZ7ZORBLEX ZAGREB #1,pbz,',
        '2026-03-12,-50.00,Groceries,PBZ POS PBZ7ZORBLEX ZAGREB #2,pbz,quorvant',
      ]);
    });

    test('searchAll finds the payment once, as the part that matched; the whole amount finds it too', () {
      SearchResult s(String q) => searchAll(q, txs: rows, goals: const [], wishlist: const [], bills: const [], tags: TagTable.from(_tags));
      expect(s('quorvant').txs.map((x) => (x.tx.id, x.part)), [('p', 1)]);
      expect(s('trip').txs.map((x) => (x.tx.id, x.part)), [('p', 1)]);
      expect(s('100.00').txs.map((x) => x.tx.id), ['p']);
      expect(s('50').txs.map((x) => (x.tx.id, x.part)), [('p', 0)]);
      expect(s('zorblex').txs, hasLength(1));
    });

    test('rowsFor and biggestRows keep equal parts in part order', () {
      final r = DateRange(start: '2026-03-01', end: '2026-03-31');
      expect(rowsFor('Groceries', null, rows.reversed.toList(), r, currency: 'EUR').map((x) => x.part), [0, 1]);
      expect(biggestRows(rows.reversed.toList(), r, currency: 'EUR').map((x) => x.part), [0, 1]);
    });

    test('compareCategory keeps part amounts when it rolls a tree up', () {
      final c = compareCategory('Groceries', rows, '2026-03', currency: 'EUR', table: CategoryTable.builtIn);
      expect(c.thisMonth, 10000);
    });

    test('the review counts no part as an automatic row to confirm', () {
      const st = WalletSettings(reviewDay: 1);
      final whole = ct('2026-03-12', -700, 'Shopping');
      final s = reviewState([...rows, whole], st, const [], const {}, today: '2026-03-14');
      expect(s.steps.firstWhere((x) => x.id == 'categories').count, 1);
    });

    test('a split payment that pays a recurring bill is matched whole once (dueCycles)', () {
      final bill = RecurringBill(
          id: 'b',
          payee: merchantKey(t),
          label: 'Zorblex',
          category: 'Groceries',
          expectedAmount: 10000,
          nextDue: '2026-03-12',
          status: 'confirmed');
      final once = dueCycles([bill], [cz.categorize(t)], '2026-03-10', '2026-04-10', currency: 'EUR');
      final split = dueCycles([bill], rows, '2026-03-10', '2026-04-10', currency: 'EUR');
      expect(split.map((c) => (c.due, c.reserve, c.paid)), once.map((c) => (c.due, c.reserve, c.paid)));
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('setSplit trims notes (empty = none), stores resolved tag ids, refuses a repeat after resolving', () async {
      final ta = await r.addTag('Zorbtrip');
      final id = r.addTransaction(date: '2026-03-12', amount: 3000, category: 'Shopping');
      r.setSplit(id, [
        SplitPart(amount: -1000, category: 'Groceries', tags: [ta], note: '  zorb  '),
        const SplitPart(amount: -2000, category: 'Shopping', note: '   '),
      ]);
      expect(r.splitOf(id)!.map((p) => (p.note, p.tags.join(','))), [('zorb', ta), (null, '')]);
      expect(
          () => r.setSplit(id, [
                SplitPart(amount: -1000, category: 'Groceries', tags: [ta, ta]),
                const SplitPart(amount: -2000, category: 'Shopping'),
              ]),
          throwsArgumentError);
    });

    test('a note of 200 characters is saved, 201 refused; a transfer category part is refused', () {
      final id = r.addTransaction(date: '2026-03-12', amount: 3000, category: 'Shopping');
      r.setSplit(
          id, [SplitPart(amount: -1000, category: 'Groceries', note: 'z' * 200), const SplitPart(amount: -2000, category: 'Shopping')]);
      expect(
          () => r.setSplit(
              id, [SplitPart(amount: -1000, category: 'Groceries', note: 'z' * 201), const SplitPart(amount: -2000, category: 'Shopping')]),
          throwsArgumentError);
      expect(
          () => r.setSplit(
              id, const [SplitPart(amount: -1000, category: 'Internal transfer'), SplitPart(amount: -2000, category: 'Shopping')]),
          throwsArgumentError);
    });

    test('a bank row the importer marked as an own transfer cannot be split', () {
      final row = n('2026-03-12', -5000, 'Ostalo', 'SYNTH OWN', kind: TxKind.ownTransfer);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [row]));
      expect(
          () => r.setSplit(row.id, const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -4000, category: 'Shopping')]),
          throwsArgumentError);
      expect(r.splitOf(row.id), isNull);
    });

    test('removeSplit without a split writes nothing; setSplit after a remove brings a split back', () {
      final id = r.addTransaction(date: '2026-03-12', amount: 3000, category: 'Shopping');
      final before = r.pendingOps().length;
      r.removeSplit(id);
      expect(r.pendingOps().length, before);
      r.setSplit(id, const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Shopping')]);
      r.removeSplit(id);
      expect(r.splitOf(id), isNull);
      expect(r.splits(), isEmpty);
      r.setSplit(id, const [SplitPart(amount: -1500, category: 'Groceries'), SplitPart(amount: -1500, category: 'Shopping')]);
      expect(r.splitOf(id)!.map((p) => p.amount), [-1500, -1500]);
    });

    test('categorizer(withTags: false) holds no splits: the internal whole-payment paths never see parts', () {
      final id = r.addTransaction(date: '2026-03-12', amount: 3000, category: 'Shopping');
      r.setSplit(id, const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Shopping')]);
      final t = r.transaction(id)!;
      expect(r.categorizer().expand(t), hasLength(2));
      expect(r.categorizer(withTags: false).expand(t), hasLength(1));
    });

    test('an unreadable stored split reads as empty and counts the payment whole, marked broken', () {
      final id = r.addTransaction(date: '2026-03-12', amount: 3000, category: 'Shopping');
      r.setSplit(id, const [SplitPart(amount: -1000, category: 'Groceries'), SplitPart(amount: -2000, category: 'Shopping')]);
      r.db.execute("UPDATE tx_splits SET parts = 'not json' WHERE id = ?", [id]);
      expect(r.splitOf(id), isEmpty);
      final rows = r.categorizer().expand(r.transaction(id)!);
      expect((rows.length, rows.single.splitBroken, rows.single.amount), (1, true, -3000));
    });
  });
}
