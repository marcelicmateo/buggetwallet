// Stage T1 review fixes (core): writes judged on the tag the owner sees (sync duplicates), tag links carried over
// when a bank row replaces a hand-added entry, and duplicate groups for tags and categories. All data is SYNTHETIC.
library;

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 12:00 UTC.
const _noon = 1791633600000;

/// Two tags with the same name from two devices: [_o] (smallest id) is the original, [_d] its duplicate.
const _o = 't00000000000a', _d = 't00000000000b';

String _peer([int n = 0]) => Hlc(_noon - 60000 + n, 0, 'peer').toString();

NormalizedTransaction _bank(String date, int cents, String desc) => NormalizedTransaction(
    id: transactionId(date, cents, desc, 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: 'EUR',
    description: desc,
    bankType: 'POS plaćanje');

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => _noon));
  tearDown(() => repo.close());

  void twoTags() => repo.applyRemote([
        Op('tag', _o, {'name': 'Trip', 'position': 0, 'hidden': 0, 'deleted': 0}, _peer(1)),
        Op('tag', _d, {'name': 'trip', 'position': 1, 'hidden': 0, 'deleted': 0}, _peer(2)),
      ]);

  Tx bankRow() {
    repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('2026-09-01', -1000, 'SYNTH CAFE')]));
    return repo.transactions().single;
  }

  List<String> effective(String txId) => repo.transactions().map(repo.categorizer().categorize).firstWhere((c) => c.tx.id == txId).tags;

  group('1: setTxTag and setRuleTag judge the tag the owner sees', () {
    test('a link held by the duplicate is removed and added again through the original', () async {
      twoTags();
      final tx = bankRow();
      repo.applyRemote([
        Op('txtag', '${tx.id}|$_d', {'tx': tx.id, 'tag': _d, 'state': 'on'}, _peer(3))
      ]);
      expect(effective(tx.id), [_o]);
      await repo.setTxTag(tx.id, _o, false);
      expect(effective(tx.id), isEmpty);
      expect(repo.tagLinks()[tx.id], {_o: false, _d: false}, reason: 'the duplicate link is turned off in the same write');
      await repo.setTxTag(tx.id, _o, true);
      expect(effective(tx.id), [_o]);
      expect(repo.tagLinks()[tx.id], {_o: true, _d: true});
      final ops = repo.pendingOps().length;
      await repo.setTxTag(tx.id, _d, true);
      expect(repo.pendingOps().length, ops, reason: 'already on: nothing written');
    }, timeout: _t);

    test('a rule held by the duplicate: off on one row through the original, then on again', () async {
      twoTags();
      final tx = bankRow();
      repo.applyRemote([
        Op('ruletag', '${merchantKey(tx)}|$_d', {'payee': merchantKey(tx), 'tag': _d, 'deleted': 0}, _peer(3))
      ]);
      expect(effective(tx.id), [_o]);
      await repo.setTxTag(tx.id, _o, false);
      expect(effective(tx.id), isEmpty);
      expect(
          repo.ruleTags(),
          {
            merchantKey(tx): {_d}
          },
          reason: 'the rule stays for the other rows');
      await repo.setTxTag(tx.id, _o, true);
      expect(effective(tx.id), [_o]);
    }, timeout: _t);

    test('setRuleTag removes a duplicate\'s rule through the original and adds it again', () async {
      twoTags();
      final tx = bankRow();
      final payee = merchantKey(tx);
      repo.applyRemote([
        Op('ruletag', '$payee|$_d', {'payee': payee, 'tag': _d, 'deleted': 0}, _peer(3))
      ]);
      final ops = repo.pendingOps().length;
      await repo.setRuleTag(payee, _o, true);
      expect(repo.pendingOps().length, ops, reason: 'the group already gives it');
      await repo.setRuleTag(payee, _o, false);
      expect(repo.ruleTags(), isEmpty);
      expect(effective(tx.id), isEmpty);
      await repo.setRuleTag(payee, _o, true);
      expect(repo.ruleTags(), {
        payee: {_o}
      });
      expect(effective(tx.id), [_o]);
    }, timeout: _t);
  });

  test('2: a bank row that replaces a hand-added entry gets its on links, never its off links', () async {
    final trip = await repo.addTag('Trip'), work = await repo.addTag('Work');
    final m = repo.addTransaction(date: '2026-09-01', amount: 1000, category: 'Groceries', note: 'synth note');
    await repo.setTxTag(m, trip, true);
    await repo.setRuleTag('synth_note', work, true);
    await repo.setTxTag(m, work, false);
    expect(repo.tagLinks()[m], {trip: true, work: false});
    final bank = bankRow();
    final entry = repo.transactions(includeHidden: true).firstWhere((t) => t.id == m);
    expect(entry.matchedTo, bank.id, reason: 'the bank row replaced the entry');
    expect(repo.tagLinks()[bank.id], {trip: true});
    expect(effective(bank.id), [trip]);
  }, timeout: _t);

  group('3: duplicate groups act as one', () {
    test('tags: rename, hide, delete and undelete the whole group; no false name clash on undelete', () async {
      twoTags();
      await repo.updateTag(_o, name: 'Travel');
      expect((repo.tagTable().label(_o), repo.tagTable().label(_d)), ('Travel', 'Travel'));
      expect(repo.tagTable().duplicateOf(_d), _o);
      await repo.updateTag(_o, hidden: true);
      expect(repo.tags().every((r) => r.hidden), isTrue);
      await repo.updateTag(_o, hidden: false, position: 4);
      expect(repo.tags().map((r) => r.position), [4, 4]);
      await repo.deleteTag(_o);
      expect(repo.tags(), isEmpty);
      await repo.undeleteTag(_o);
      expect(repo.tags().map((r) => r.id).toSet(), {_o, _d});
      expect(repo.tagTable().pickable(), [_o]);
    }, timeout: _t);

    test('categories: rename, delete and undelete the whole group; no false name clash on undelete', () async {
      const a = 'k00000000000a', b = 'k00000000000b';
      repo.applyRemote([
        Op('category', a, {'name': 'Pets', 'kind': 'flex', 'position': 30, 'hidden': 0, 'deleted': 0}, _peer(1)),
        Op('category', b, {'name': 'pets', 'kind': 'flex', 'position': 31, 'hidden': 0, 'deleted': 0}, _peer(2)),
      ]);
      expect(repo.categoryTable().duplicateOf(b), a);
      await repo.updateCategory(a, name: 'Animals');
      expect((repo.categoryTable().label(a), repo.categoryTable().label(b)), ('Animals', 'Animals'));
      await repo.deleteCategory(a);
      expect(repo.categoryTable().isLive(b), isFalse);
      await repo.undeleteCategory(a);
      final t = repo.categoryTable();
      expect((t.isLive(a), t.isLive(b)), (true, true));
      expect(t.pickable(), contains(a));
      expect(t.pickable(), isNot(contains(b)));
    }, timeout: _t);

    test('a custom duplicate of a built-in follows the built-in\'s relabel; deleting it leaves the built-in', () async {
      const k = 'k00000000000c';
      repo.applyRemote([
        Op('category', k, {'name': 'groceries', 'kind': 'flex', 'position': 30, 'hidden': 0, 'deleted': 0}, _peer(1)),
      ]);
      await repo.updateCategory('Groceries', name: 'Food shop');
      expect((repo.categoryTable().label('Groceries'), repo.categoryTable().label(k)), ('Food shop', 'Food shop'));
      await repo.deleteCategory(k);
      expect((repo.categoryTable().isLive('Groceries'), repo.categoryTable().isLive(k)), (true, false));
    }, timeout: _t);

    test('deleting the duplicate itself removes only the copy (tags and categories)', () async {
      twoTags();
      await repo.deleteTag(_d);
      expect(repo.tags().map((r) => r.id), [_o]);
      const a = 'k00000000000a', b = 'k00000000000b';
      repo.applyRemote([
        Op('category', a, {'name': 'Pets', 'kind': 'flex', 'position': 30, 'hidden': 0, 'deleted': 0}, _peer(5)),
        Op('category', b, {'name': 'pets', 'kind': 'flex', 'position': 31, 'hidden': 0, 'deleted': 0}, _peer(6)),
      ]);
      await repo.deleteCategory(b);
      expect((repo.categoryTable().isLive(a), repo.categoryTable().isLive(b)), (true, false));
    }, timeout: _t);
  });

  test('4: tagsOf returns early without rules or links for the row', () {
    final t = TagTable.from(const [TagRow(id: 'ta', name: 'A')]);
    const tx = Tx(id: 'r1', source: 'pbz', date: '2026-09-01', amount: -100, description: 'SYNTH');
    expect(
        identical(
            tagsOf(tx, tags: t, ruleTags: const {}, links: const {
              'other': {'ta': true}
            }),
            const <String>[]),
        isTrue);
  });
}
