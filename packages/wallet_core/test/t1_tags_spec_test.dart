// Stage T1 (docs/context/T1_SPEC.md §7): tags on one device. Written from the spec, not the code.
// Money in cents; `addTransaction` takes an expense as a POSITIVE amount. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/t1.dart';

const _t = Timeout(Duration(seconds: 60));
final _tagId = RegExp(r'^t[0-9a-f]{12}$');
final _oct = DateRange(start: '2026-10-01', end: '2026-10-31');

void main() {
  late WalletRepo repo;
  var now = 1791590400000; // 2026-10-10 00:00 UTC

  setUp(() {
    now = 1791590400000;
    repo = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => repo.close());

  String expense(String note, {String date = '2026-10-05', int cents = 1000, String category = 'Groceries'}) =>
      repo.addTransaction(date: date, amount: cents, category: category, note: note);

  String payeeOf(String id) => merchantKey(repo.transactions().firstWhere((t) => t.id == id));

  group('names', () {
    test('id shape, trimming, 1 and 40 characters are fine', () async {
      final id = await repo.addTag('  Trip  ');
      expect(id, matches(_tagId));
      expect(repo.tagTable().label(id), 'Trip');
      await repo.addTag('x');
      await repo.addTag('y' * 40);
      expect(repo.tags(), hasLength(3));
    }, timeout: _t);

    test('41 characters, empty and blank are refused; nothing is written', () async {
      await expectLater(repo.addTag('y' * 41), throwsArgumentError);
      await expectLater(repo.addTag(''), throwsArgumentError);
      await expectLater(repo.addTag('   '), throwsArgumentError);
      expect(repo.tags(), isEmpty);
    }, timeout: _t);

    test('41 characters only after trimming is fine; 41 inside is not', () async {
      await repo.addTag(' ${'z' * 40} ');
      await expectLater(repo.addTag('${'w' * 20} ${'w' * 20}'), throwsArgumentError);
    }, timeout: _t);

    test('unique by case and accents, among live tags only', () async {
      final id = await repo.addTag('Čaj');
      await expectLater(repo.addTag('caj'), throwsArgumentError);
      await expectLater(repo.addTag(' ČAJ '), throwsArgumentError);
      await repo.deleteTag(id);
      final again = await repo.addTag('caj');
      expect(again, isNot(id));
    }, timeout: _t);

    test('a name equal to the label of a live main tag is refused (built-in, case folded)', () async {
      await expectLater(repo.addTag('Groceries'), throwsArgumentError);
      await expectLater(repo.addTag('groceries'), throwsArgumentError);
      await expectLater(repo.addTag('EATING OUT'), throwsArgumentError);
      expect(repo.tags(), isEmpty);
    }, timeout: _t);

    test('a relabelled built-in clashes under its new label, not the old one', () async {
      await repo.updateCategory('Groceries', name: 'Food shop');
      await expectLater(repo.addTag('food shop'), throwsArgumentError);
      await repo.addTag('Groceries');
    }, timeout: _t);

    test('a custom main tag clashes while live and stops clashing once deleted', () async {
      final k = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await expectLater(repo.addTag('pets'), throwsArgumentError);
      await repo.deleteCategory(k);
      await repo.addTag('pets');
    }, timeout: _t);

    test('rename: clash with another tag or a main tag refused, own name in another case allowed', () async {
      final a = await repo.addTag('Trip');
      await repo.addTag('Gift');
      await expectLater(repo.updateTag(a, name: 'gift'), throwsArgumentError);
      await expectLater(repo.updateTag(a, name: 'Shopping'), throwsArgumentError);
      await expectLater(repo.updateTag(a, name: 'q' * 41), throwsArgumentError);
      await expectLater(repo.updateTag('tdeadbeef0000', name: 'Nope'), throwsArgumentError);
      await repo.updateTag(a, name: 'TRIP');
      expect(repo.tagTable().label(a), 'TRIP');
    }, timeout: _t);

    test('at most 500 live tags; a deleted one frees a slot', () async {
      final ids = <String>[];
      for (var i = 0; i < 500; i++) {
        ids.add(await repo.addTag('Tag $i'));
      }
      await expectLater(repo.addTag('One more'), throwsArgumentError);
      expect(repo.tags(), hasLength(500));
      await repo.deleteTag(ids.first);
      await repo.addTag('One more');
      expect(repo.tags(), hasLength(500));
      expect(repo.tags(includeDeleted: true), hasLength(501));
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('hidden tags are not pickable but stay live; deleted ones are not live', () async {
      final a = await repo.addTag('Trip');
      final b = await repo.addTag('Gift');
      await repo.updateTag(a, hidden: true);
      await repo.deleteTag(b);
      final t = repo.tagTable();
      expect(t.pickable(), isNot(contains(a)));
      expect(t.isLive(a), isTrue);
      expect(t.isLive(b), isFalse);
      expect(t.pickable(), isNot(contains(b)));
      await repo.undeleteTag(b);
      expect(repo.tagTable().pickable(), contains(b));
    }, timeout: _t);

    test('tags and main tags are separate: a tag does not become a category', () async {
      final a = await repo.addTag('Trip');
      expect(repo.categoryTable().isLive(a), isFalse);
      expect(repo.categoryTable().pickable(), isNot(contains(a)));
    }, timeout: _t);
  });

  group('tagsOf', () {
    test('a rule tag appears on every row of its payee and on no other payee', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      final b = expense('Lidl', date: '2026-10-06');
      final c = expense('Konzum');
      await repo.setRuleTag(payeeOf(a), tag, true);
      expect(effective(repo, a), [tag]);
      expect(effective(repo, b), [tag]);
      expect(effective(repo, c), isEmpty);
      expect(repo.ruleTags()[payeeOf(a)], {tag});
    }, timeout: _t);

    test('an off link removes a rule tag from one row only', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      final b = expense('Lidl', date: '2026-10-06');
      await repo.setRuleTag(payeeOf(a), tag, true);
      await repo.setTxTag(a, tag, false);
      expect(effective(repo, a), isEmpty);
      expect(effective(repo, b), [tag]);
    }, timeout: _t);

    test('off written before the rule exists still wins', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      await repo.setTxTag(a, tag, true);
      await repo.setTxTag(a, tag, false); // off with no rule yet: the link exists because it was on
      await repo.setRuleTag(payeeOf(a), tag, true);
      expect(effective(repo, a), isEmpty);
    }, timeout: _t);

    test('on, off, on again', () async {
      final tag = await repo.addTag('Trip');
      final a = expense('Hotel');
      await repo.setTxTag(a, tag, true);
      expect(effective(repo, a), [tag]);
      await repo.setTxTag(a, tag, false);
      expect(effective(repo, a), isEmpty);
      await repo.setTxTag(a, tag, true);
      expect(effective(repo, a), [tag]);
      expect(repo.db.select('SELECT * FROM tx_tags WHERE tx = ?', [a]), hasLength(1), reason: 'one link row, id <tx>|<tag>');
      expect(repo.db.select('SELECT id FROM tx_tags').single['id'], '$a|$tag');
    }, timeout: _t);

    test('rule off, off link, then on again: the tag is back', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      await repo.setRuleTag(payeeOf(a), tag, true);
      await repo.setTxTag(a, tag, false);
      await repo.setTxTag(a, tag, true);
      expect(effective(repo, a), [tag]);
    }, timeout: _t);

    test('rule and on link together give the tag once', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      await repo.setTxTag(a, tag, true);
      await repo.setRuleTag(payeeOf(a), tag, true);
      expect(effective(repo, a), [tag]);
    }, timeout: _t);

    test('removing the rule: an on link stays, no link or an off link means no tag', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      final b = expense('Lidl', date: '2026-10-06');
      final c = expense('Lidl', date: '2026-10-07');
      await repo.setRuleTag(payeeOf(a), tag, true);
      await repo.setTxTag(a, tag, false); // off then on: the on link is written (the rule alone would make it a no-op)
      await repo.setTxTag(a, tag, true);
      await repo.setTxTag(c, tag, false);
      await repo.setRuleTag(payeeOf(a), tag, false);
      expect(effective(repo, a), [tag]);
      expect(effective(repo, b), isEmpty);
      expect(effective(repo, c), isEmpty);
      expect(repo.ruleTags()[payeeOf(a)] ?? <String>{}, isEmpty);
      await repo.setRuleTag(payeeOf(a), tag, true);
      expect(effective(repo, b), [tag]);
      expect(effective(repo, c), isEmpty, reason: 'the off link still overrides');
    }, timeout: _t);

    test('writing on for a tag a rule already gives is a no-op, unless the link was off', () async {
      final tag = await repo.addTag('Weekly shop');
      final a = expense('Lidl');
      await repo.setRuleTag(payeeOf(a), tag, true);
      final before = repo.pendingOps().length;
      await repo.setTxTag(a, tag, true);
      expect(repo.db.select('SELECT * FROM tx_tags'), isEmpty);
      expect(repo.pendingOps().length, before);
      await repo.setTxTag(a, tag, false);
      await repo.setTxTag(a, tag, true);
      expect(effective(repo, a), [tag]);
      expect(repo.db.select('SELECT state FROM tx_tags').single['state'], 'on');
    }, timeout: _t);

    test('a deleted tag disappears from rows, and comes back after undelete', () async {
      final tag = await repo.addTag('Trip');
      final other = await repo.addTag('Gift');
      final a = expense('Hotel');
      await repo.setTxTag(a, tag, true);
      await repo.setRuleTag(payeeOf(a), other, true);
      expect(effective(repo, a), unorderedEquals([tag, other]));
      await repo.deleteTag(tag);
      await repo.deleteTag(other);
      expect(effective(repo, a), isEmpty);
      await repo.undeleteTag(tag);
      expect(effective(repo, a), [tag]);
      await repo.undeleteTag(other);
      expect(effective(repo, a), unorderedEquals([tag, other]));
    }, timeout: _t);

    test('the order is the order of pickable', () async {
      final ids = [
        for (final n in ['Delta', 'Alpha', 'Charlie', 'Bravo']) await repo.addTag(n)
      ];
      await repo.updateTag(ids[2], position: 0);
      final a = expense('Hotel');
      for (final id in ids.reversed) {
        await repo.setTxTag(a, id, true);
      }
      final want = [
        for (final id in repo.tagTable().pickable())
          if (ids.contains(id)) id
      ];
      expect(effective(repo, a), want);
      expect(want.first, ids[2]);
    }, timeout: _t);

    test('a hidden tag still shows on rows that carry it, a link to an unknown tag is dropped', () async {
      final tag = await repo.addTag('Trip');
      final a = expense('Hotel');
      await repo.setTxTag(a, tag, true);
      await repo.updateTag(tag, hidden: true);
      expect(effective(repo, a), [tag]);
      final t = repo.transactions().firstWhere((x) => x.id == a);
      final got = tagsOf(t, tags: repo.tagTable(), ruleTags: const {}, links: {
        a: {tag: true, 'tffffffffffff': true},
      });
      expect(got, [tag]);
    }, timeout: _t);

    test('tagsOf is pure: empty inputs give an empty list, and CategorizedTx.tags defaults to empty and is unmodifiable', () {
      final tx = plain('r1', '2026-10-01', -100, 'LIDL ZAGREB');
      expect(tagsOf(tx, tags: repo.tagTable(), ruleTags: const {}, links: const {}), isEmpty);
      final c = tagged(tx, 'Groceries');
      expect(c.tags, isEmpty);
      expect(() => c.tags.add('y'), throwsUnsupportedError);
    });
  });

  group('suggestTags', () {
    late String trip, gift, food, hotel;
    late TagTable tags;
    setUp(() async {
      trip = await repo.addTag('Trip');
      gift = await repo.addTag('Gift');
      food = await repo.addTag('Food');
      hotel = await repo.addTag('Hotel');
      tags = repo.tagTable();
    });

    CategorizedTx row(String id, String date, List<String> t, {String desc = 'LIDL ZAGREB', bool deleted = false}) =>
        tagged(plain(id, date, -500, desc, deleted: deleted), 'Groceries', t);

    test('needs at least 2 other live rows of the payee', () {
      final cur = plain('cur', '2026-10-09', -500, 'LIDL ZAGREB');
      final history = [
        row('h1', '2026-10-01', [trip]),
        row('h2', '2026-10-02', [trip, gift]),
        row('h3', '2026-10-03', [gift])
      ];
      expect(suggestTags(cur, history, tags), [gift, trip], reason: 'both used twice; gift more recently');
    });

    test('exactly 1 use is not enough, 2 is; other payees and deleted rows do not count', () {
      final cur = plain('cur', '2026-10-09', -500, 'LIDL ZAGREB');
      final history = [
        row('h1', '2026-10-01', [trip]),
        row('h2', '2026-10-02', [gift], desc: 'KONZUM SPLIT'),
        row('h3', '2026-10-03', [gift], desc: 'KONZUM SPLIT'),
        row('h4', '2026-10-04', [food]),
        row('h5', '2026-10-05', [food], deleted: true),
      ];
      expect(suggestTags(cur, history, tags), isEmpty);
      history.add(row('h6', '2026-10-06', [trip]));
      expect(suggestTags(cur, history, tags), [trip]);
    });

    test('the row itself does not count as a use', () {
      final cur = plain('cur', '2026-10-09', -500, 'LIDL ZAGREB');
      final history = [
        tagged(cur, 'Groceries', [trip]),
        row('h1', '2026-10-01', [trip])
      ];
      expect(suggestTags(cur, history, tags), isEmpty);
    });

    test('tags already on this row are not suggested', () {
      final cur = plain('cur', '2026-10-09', -500, 'LIDL ZAGREB');
      final history = [
        tagged(cur, 'Groceries', [trip]),
        row('h1', '2026-10-01', [trip, gift]),
        row('h2', '2026-10-02', [trip, gift]),
      ];
      expect(suggestTags(cur, history, tags), [gift]);
    });

    test('ordered by count, then the most recent use, then the label', () {
      final cur = plain('cur', '2026-10-20', -500, 'LIDL ZAGREB');
      final history = [
        row('h1', '2026-10-01', [hotel, food, gift, trip]),
        row('h2', '2026-10-02', [hotel, food, gift, trip]),
        row('h3', '2026-10-03', [hotel]),
        row('h4', '2026-10-08', [gift]),
        row('h5', '2026-10-08', [food]),
      ];
      // hotel 3; gift 3 (latest 10-08); food 3 (latest 10-08); trip 2.
      // count 3: gift, food, hotel by recency (gift/food 10-08 tie -> label Food < Gift; hotel 10-03), then trip.
      expect(suggestTags(cur, history, tags), [food, gift, hotel, trip]);
    });

    test('limit defaults to 5 and can be lowered; dead tags are not suggested', () async {
      final extra = [for (var i = 0; i < 4; i++) await repo.addTag('Extra $i')];
      final all = [trip, gift, food, hotel, ...extra];
      final history = [
        row('h1', '2026-10-01', all),
        row('h2', '2026-10-02', all),
      ];
      final cur = plain('cur', '2026-10-20', -500, 'LIDL ZAGREB');
      expect(suggestTags(cur, history, repo.tagTable()), hasLength(5));
      expect(suggestTags(cur, history, repo.tagTable(), limit: 2), hasLength(2));
      expect(suggestTags(cur, history, repo.tagTable(), limit: 20), hasLength(8));
      await repo.deleteTag(trip);
      expect(suggestTags(cur, history, repo.tagTable(), limit: 20), isNot(contains(trip)));
    });
  });

  group('recommended tags', () {
    CategorizedTx at(String id, String desc, String cat, [String date = '2026-10-01']) => tagged(plain(id, date, -500, desc), cat);

    test('main tags: this payee first by count, then overall use, then table order', () async {
      final cur = plain('cur', '2026-10-20', -500, 'STORE ONE');
      final history = [
        at('a', 'STORE ONE', 'Shopping'),
        at('b', 'STORE ONE', 'Shopping'),
        at('c', 'STORE ONE', 'Home & tools'),
        for (var i = 0; i < 5; i++) at('d$i', 'OTHER', 'Cash'),
        for (var i = 0; i < 2; i++) at('e$i', 'OTHER', 'Eating out'),
      ];
      final table = repo.categoryTable();
      final got = recommendedMainTags(cur, history, table);
      expect(got.take(4), ['Shopping', 'Home & tools', 'Cash', 'Eating out']);
      expect(got, unorderedEquals(table.pickable()));
      final rest = got.skip(4).toList();
      expect(rest, [
        for (final id in table.pickable())
          if (!got.take(4).contains(id)) id
      ]);
    }, timeout: _t);

    test('kinds filter, hidden and deleted tags are left out, an own main tag can lead', () async {
      final pets = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final gone = await repo.addCategory(name: 'Gone', kind: BudgetKind.flex);
      await repo.deleteCategory(gone);
      await repo.updateCategory('Shopping', hidden: true);
      final cur = plain('cur', '2026-10-20', -500, 'PET SHOP');
      final history = [at('a', 'PET SHOP', pets), at('b', 'PET SHOP', gone), at('c', 'PET SHOP', 'Shopping')];
      final table = repo.categoryTable();
      final got = recommendedMainTags(cur, history, table);
      expect(got.first, pets);
      expect(got, isNot(contains(gone)));
      expect(got, isNot(contains('Shopping')));
      final flexOnly = recommendedMainTags(cur, history, table, kinds: {BudgetKind.flex});
      expect(flexOnly, isNot(contains('Salary')));
      expect(flexOnly, isNot(contains('Rent')));
      expect(flexOnly.first, pets);
      expect(got, contains('Salary'));
    }, timeout: _t);

    test('with no history the order is the table order', () {
      final cur = plain('cur', '2026-10-20', -500, 'STORE ONE');
      final table = repo.categoryTable();
      expect(recommendedMainTags(cur, const [], table), table.pickable());
    });

    test('extra tags: payee first, then overall use, then table order', () async {
      final a = await repo.addTag('Alpha');
      final b = await repo.addTag('Bravo');
      final c = await repo.addTag('Charlie');
      final cur = plain('cur', '2026-10-20', -500, 'STORE ONE');
      final history = [
        tagged(plain('h1', '2026-10-01', -500, 'STORE ONE'), 'Shopping', [c]),
        tagged(plain('h2', '2026-10-01', -500, 'OTHER'), 'Shopping', [b]),
        tagged(plain('h3', '2026-10-02', -500, 'OTHER'), 'Shopping', [b]),
      ];
      expect(recommendedTags(cur, history, repo.tagTable()), [c, b, a]);
    });
  });

  group('tagShare, rowsForTag, tagTrend', () {
    const a = 'ta', b = 'tb';
    late List<CategorizedTx> rows;
    setUp(() {
      rows = [
        tagged(plain('r1', '2026-10-03', -1000, 'LIDL'), 'Groceries', [a]),
        tagged(plain('r2', '2026-10-04', -2000, 'CAFE'), 'Eating out', [a, b]),
        tagged(plain('r3', '2026-10-05', -500, 'SHOP'), 'Shopping'),
        tagged(plain('r4', '2026-10-06', 300, 'LIDL'), 'Groceries', [a]), // refund
        tagged(plain('x1', '2026-10-07', 100000, 'PAY'), 'Salary', [a]),
        tagged(plain('x2', '2026-10-08', -5000, 'REVOLUT'), 'Internal transfer', [a]),
        tagged(plain('x3', '2026-10-09', -700, 'LIDL', currency: 'USD'), 'Groceries', [a]),
        tagged(plain('x4', '2026-10-10', -900, 'LIDL', deleted: true), 'Groceries', [a]),
        tagged(plain('x5', '2026-09-30', -800, 'LIDL'), 'Groceries', [a]),
        tagged(plain('x6', '2026-11-01', -800, 'LIDL'), 'Groceries', [a]),
        tagged(plain('x7', '2026-10-11', -600, 'LIDL', matchedTo: 'bank1'), 'Groceries', [a]),
      ];
    });

    int spentOf(TagShare s, String tag) => s.slices.where((x) => x.tag == tag).fold(0, (p, x) => p + x.spent);

    test('per tag spending counts like Where it goes; excluded rows never count', () {
      final s = tagShare(rows, _oct, currency: 'EUR');
      expect(spentOf(s, a), 1000 + 2000 - 300);
      expect(spentOf(s, b), 2000);
      expect(s.slices.map((x) => x.tag).toSet(), {a, b});
    });

    test('totals overlap: the slices add up to more than the spending; untaggedSpent is the rest', () {
      final s = tagShare(rows, _oct, currency: 'EUR');
      final total = categoryShare(rows, _oct, currency: 'EUR').total;
      expect(total, 1000 + 2000 + 500 - 300);
      expect(s.untaggedSpent, 500);
      expect(s.slices.fold<int>(0, (p, x) => p + x.spent), 2700 + 2000);
      expect(s.untaggedSpent + 2700, total, reason: 'rows with any extra tag are 2700 net');
    });

    test('count is the number of rows', () {
      final s = tagShare(rows.where((r) => r.tx.id != 'r4').toList(), _oct, currency: 'EUR');
      expect(s.slices.firstWhere((x) => x.tag == a).count, 2);
      expect(s.slices.firstWhere((x) => x.tag == b).count, 1);
    });

    test('each slice equals the rows behind it, newest first', () {
      final s = tagShare(rows, _oct, currency: 'EUR');
      for (final slice in s.slices) {
        final behind = rowsForTag(slice.tag, rows, _oct, currency: 'EUR');
        expect(-behind.fold<int>(0, (p, x) => p + x.amount), slice.spent, reason: slice.tag);
      }
      final ids = rowsForTag(a, rows, _oct, currency: 'EUR').map((x) => x.tx.id).toList();
      expect(ids, ['r4', 'r2', 'r1']);
      expect(rowsForTag('tunknown', rows, _oct, currency: 'EUR'), isEmpty);
    });

    test('same-day rows order by id, descending', () {
      final two = [
        tagged(plain('m1', '2026-10-03', -100, 'A'), 'Groceries', [a]),
        tagged(plain('m2', '2026-10-03', -100, 'A'), 'Groceries', [a]),
      ];
      expect(rowsForTag(a, two, _oct, currency: 'EUR').map((x) => x.tx.id), ['m2', 'm1']);
    });

    test('a range clips by day, inclusive', () {
      final r = DateRange(start: '2026-10-04', end: '2026-10-04');
      expect(spentOf(tagShare(rows, r, currency: 'EUR'), a), 2000);
    });

    test('nothing tagged, nothing at all, and everything tagged', () {
      final none = tagShare(const [], _oct, currency: 'EUR');
      expect(none.slices, isEmpty);
      expect(none.untaggedSpent, 0);
      final untagged = tagShare([tagged(plain('u', '2026-10-03', -100, 'A'), 'Groceries')], _oct, currency: 'EUR');
      expect(untagged.slices, isEmpty);
      expect(untagged.untaggedSpent, 100);
      final all = tagShare([
        tagged(plain('u', '2026-10-03', -100, 'A'), 'Groceries', [a])
      ], _oct, currency: 'EUR');
      expect(all.untaggedSpent, 0);
    });

    test('another home currency counts that currency only', () {
      expect(spentOf(tagShare(rows, _oct, currency: 'USD'), a), 700);
    });

    test('tagTrend gives one bar per month with the tag spending', () {
      final long = [
        ...rows,
        tagged(plain('y1', '2026-08-15', -400, 'LIDL'), 'Groceries', [a]),
      ];
      final r = DateRange(start: '2026-08-01', end: '2026-10-31');
      final bars = tagTrend(a, long, r, today: '2026-10-15', currency: 'EUR');
      expect(bars.map((x) => x.month), ['2026-08', '2026-09', '2026-10']);
      expect(bars.map((x) => x.spent), [400, 800, 2700]);
    });

    test('tags do not change categoryShare or spendingByMonth', () {
      final stripped = [for (final r in rows) CategorizedTx(r.tx, r.category, r.kind)];
      final x = categoryShare(rows, _oct, currency: 'EUR');
      final y = categoryShare(stripped, _oct, currency: 'EUR');
      expect(x.total, y.total);
      expect([for (final s in x.slices) (s.category, s.spent, s.permille)], [for (final s in y.slices) (s.category, s.spent, s.permille)]);
      expect(spendingByMonth(rows, _oct, currency: 'EUR', today: '2026-10-15').map((m) => m.spent),
          spendingByMonth(stripped, _oct, currency: 'EUR', today: '2026-10-15').map((m) => m.spent));
    });
  });

  group('CSV and search', () {
    late TagTable table;
    late String trip, gift;
    setUp(() async {
      trip = await repo.addTag('Trip');
      gift = await repo.addTag('Dad, gifts');
      table = repo.tagTable();
    });

    List<List<String>> parse(String csv) => [for (final l in csv.trimRight().split('\n')) l.split(',')];

    test('a tags column after category, labels joined with "; ", main tag label stays in category', () {
      final txs = [
        tagged(plain('r1', '2026-10-01', -1000, 'HOTEL ROMA'), 'Shopping', [trip]),
        tagged(plain('r2', '2026-10-02', -500, 'KIOSK'), 'Groceries'),
      ];
      final csv = transactionsCsv(txs, tags: table);
      final head = csv.split('\n').first.split(',');
      final i = head.indexOf('category');
      expect(head[i + 1], 'tags');
      final lines = parse(csv);
      expect(lines[1][i], 'Shopping');
      expect(lines[1][i + 1], 'Trip');
      expect(lines[2][i + 1], '', reason: 'no tags: an empty cell');
      expect(lines[2], hasLength(head.length));
    });

    test('several tags are joined with "; " in the row order, and a label with a comma is quoted', () {
      final txs = [
        tagged(plain('r1', '2026-10-01', -1000, 'HOTEL ROMA'), 'Shopping', [trip, gift]),
      ];
      final csv = transactionsCsv(txs, tags: table);
      expect(csv, contains('"Trip; Dad, gifts"'));
    });

    test('a deleted row is not exported, with tags either', () {
      final txs = [
        tagged(plain('r1', '2026-10-01', -1000, 'HOTEL ROMA', deleted: true), 'Shopping', [trip])
      ];
      expect(transactionsCsv(txs, tags: table).trimRight().split('\n'), hasLength(1));
    });

    SearchResult search(String q, List<CategorizedTx> txs) =>
        searchAll(q, txs: txs, goals: const [], wishlist: const [], bills: const [], tags: table);

    test('a tag label finds the rows that carry it, folded and partial', () async {
      final caj = await repo.addTag('Čaj');
      final t2 = repo.tagTable();
      final txs = [
        tagged(plain('r1', '2026-10-01', -1000, 'HOTEL ROMA'), 'Shopping', [trip]),
        tagged(plain('r2', '2026-10-02', -500, 'KIOSK'), 'Groceries', [caj]),
        tagged(plain('r3', '2026-10-03', -500, 'BAKERY'), 'Groceries'),
      ];
      SearchResult s(String q) => searchAll(q, txs: txs, goals: const [], wishlist: const [], bills: const [], tags: t2);
      expect(s('TRIP').txs.map((x) => x.tx.id), ['r1']);
      expect(s('tri').txs.map((x) => x.tx.id), ['r1']);
      expect(s('caj').txs.map((x) => x.tx.id), ['r2']);
      expect(s('nothing here').txs, isEmpty);
    });

    test('a deleted row with the tag is not found; a row is listed once even with two matching tags', () {
      final txs = [
        tagged(plain('r1', '2026-10-01', -1000, 'HOTEL', deleted: true), 'Shopping', [trip]),
        tagged(plain('r2', '2026-10-02', -1000, 'HOTEL'), 'Shopping', [trip, gift]),
      ];
      expect(search('trip', txs).txs.map((x) => x.tx.id), ['r2']);
      expect(search('t', txs).txs.where((x) => x.tx.id == 'r2'), hasLength(1));
    });
  });

  group('P1 clean-up', () {
    test('addCategory and updateCategory refuse a parent: "Use a tag for this."', () async {
      final p = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await expectLater(repo.addCategory(name: 'Food', kind: BudgetKind.flex, parent: p),
          throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', contains('Use a tag for this'))));
      final c = await repo.addCategory(name: 'Food', kind: BudgetKind.flex);
      await expectLater(repo.updateCategory(c, parent: p), throwsArgumentError);
      expect(repo.categoryTable().childrenOf(p), isEmpty);
      expect(repo.categoryTable().parentOf(c), isNull);
    }, timeout: _t);

    test('a stored child counts as its own main tag: no roll-up, own slice, own kind source', () {
      final table = CategoryTable.from(const [
        CategoryRow(id: 'kaaaaaaaaaaaa', name: 'Pets', kind: BudgetKind.flex),
        CategoryRow(id: 'kbbbbbbbbbbbb', name: 'Vet', kind: BudgetKind.flex, parent: 'kaaaaaaaaaaaa'),
      ]);
      expect(table.parentOf('kbbbbbbbbbbbb'), isNull);
      expect(table.topLevel('kbbbbbbbbbbbb'), 'kbbbbbbbbbbbb');
      expect(table.childrenOf('kaaaaaaaaaaaa'), isEmpty);
      expect(table.pickable(), containsAll(['kaaaaaaaaaaaa', 'kbbbbbbbbbbbb']));
      expect(rollUp({'kaaaaaaaaaaaa': 100, 'kbbbbbbbbbbbb': 50}, table), {'kaaaaaaaaaaaa': 100, 'kbbbbbbbbbbbb': 50});
      final rows = [
        tagged(plain('r1', '2026-10-01', -100, 'PET SHOP'), 'kaaaaaaaaaaaa'),
        tagged(plain('r2', '2026-10-02', -50, 'VET'), 'kbbbbbbbbbbbb'),
      ];
      final share = categoryShare(rows, _oct, currency: 'EUR', rollUp: true, table: table);
      expect(share.total, 150, reason: 'exact sum, nothing lost or doubled');
      expect({for (final s in share.slices) s.category: s.spent}, {'kaaaaaaaaaaaa': 100, 'kbbbbbbbbbbbb': 50});
    });
  });
}
