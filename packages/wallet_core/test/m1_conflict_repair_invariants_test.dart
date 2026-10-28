// M1 follow-up: invariants of the repair/conflict/dry-run/type-check paths of repo_sync_apply.dart (VC, Q3) that
// survived mutation testing. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

String _hlc(int ms, [String node = 'n1']) => Hlc(1767225600000 + ms, 0, node).toString();

void main() {
  final repos = <WalletRepo>[];
  WalletRepo repo() {
    final r = WalletRepo.inMemory(now: () => 1767225600000 + 100000);
    repos.add(r);
    return r;
  }

  tearDown(() {
    for (final r in repos) {
      r.close();
    }
    repos.clear();
  });

  Object? cell(WalletRepo r, String table, String col, String id) {
    final rows = r.db.select('SELECT $col AS v FROM $table WHERE id = ?', [id]);
    return rows.isEmpty ? #none : rows.first['v'];
  }

  Op tx(String id, Map<String, Object?> f, int ms) => Op('tx', id, {'date': '2026-01-03', 'description': 'SYNTHETIC SHOP', ...f}, _hlc(ms));

  group('dry run (a merge preview)', () {
    test('counts the ops that change something, per entity, and changes nothing', () {
      final r = repo();
      final ops = [
        tx('a', {'amount': -100}, 1),
        tx('b', {'amount': -200}, 2),
        Op('setting', 'salary', {'value': '100', 'deleted': 0}, _hlc(3)),
      ];
      expect(r.applyRemoteByEntity(ops, match: false, dryRun: true), {'tx': 2, 'setting': 1});
      expect(cell(r, 'tx', 'amount', 'a'), #none);
      expect(r.applyRemoteByEntity(ops, match: false), {'tx': 2, 'setting': 1}, reason: 'the real apply gives the same counts');
    });
    test('an op equal in clock to a stored field changes nothing in a dry run, even for a lost row', () {
      final r = repo();
      final op = tx('a', {'amount': -100}, 1);
      r.applyRemote([op], match: false);
      expect(r.applyRemoteByEntity([op], match: false, dryRun: true), isEmpty);
      r.db.execute('DELETE FROM tx WHERE id = ?', ['a']); // damage: the row is gone, its clocks remain
      expect(r.applyRemoteByEntity([op], match: false, dryRun: true), isEmpty, reason: 'only a repair resend restores a row');
      expect(cell(r, 'tx', 'amount', 'a'), #none);
    });
  });

  group('lost row restored from a repair resend (VC)', () {
    test('a deleted payment stays hidden; its newer deleted field becomes a conflict (mine 1)', () {
      final r = repo();
      r.applyRemote([
        tx('t1', {'amount': -100, 'deleted': 1}, 5)
      ], match: false);
      r.db.execute('DELETE FROM tx WHERE id = ?', ['t1']);
      // An older resend of the row with one field this device never wrote (note).
      r.applyRemote([
        tx('t1', {'amount': -100, 'deleted': 0, 'note': 'x'}, 3)
      ], match: false, repair: true);
      expect(cell(r, 'tx', 'deleted', 't1'), 1, reason: 'a payment the owner deleted never comes back by itself');
      expect(cell(r, 'tx', 'note', 't1'), 'x');
      final byField = {for (final c in r.syncConflicts()) c.field: c};
      expect(byField['deleted']?.mine, 1);
      expect(byField['deleted']?.theirs, 0);
      expect(byField['amount']?.theirs, -100);
    });
    test('the same with equal clocks and a resend that lacks the deleted field', () {
      final r = repo();
      r.applyRemote([
        tx('t1', {'amount': -100, 'deleted': 1}, 5)
      ], match: false);
      r.db.execute('DELETE FROM tx WHERE id = ?', ['t1']);
      r.applyRemote([
        tx('t1', {'amount': -100}, 5)
      ], match: false, repair: true);
      expect(cell(r, 'tx', 'deleted', 't1'), 1);
      expect(cell(r, 'tx', 'amount', 't1'), -100, reason: 'equal clock: the resend value is taken');
    });
    test('a lost row with no deleted clock comes back visible', () {
      final r = repo();
      r.applyRemote([
        tx('t1', {'amount': -100}, 5)
      ], match: false);
      r.db.execute('DELETE FROM tx WHERE id = ?', ['t1']);
      r.applyRemote([
        tx('t1', {'amount': -100}, 5)
      ], match: false, repair: true);
      expect(cell(r, 'tx', 'deleted', 't1'), 0);
    });
  });

  group('type check of synced values', () {
    int? goalTarget(WalletRepo r, String id) => cell(r, 'goals', 'target', id) as int?;
    Op goal(String id, Object? target) => Op('goal', id, {'target': target}, _hlc(1));

    test('an integer column takes a whole double, refuses a fractional or non-finite one', () {
      final r = repo();
      r.applyRemote([goal('g1', 5.0), goal('g2', 5.5), goal('g3', double.infinity), goal('g4', double.nan)], match: false);
      expect(goalTarget(r, 'g1'), 5);
      expect(cell(r, 'goals', 'target', 'g2'), #none);
      expect(cell(r, 'goals', 'target', 'g3'), #none);
      expect(cell(r, 'goals', 'target', 'g4'), #none);
    });
    test('2^53 is the largest whole double taken; beyond it is refused', () {
      final r = repo();
      r.applyRemote([goal('g1', 9007199254740992.0), goal('g2', 18014398509481984.0)], match: false);
      expect(goalTarget(r, 'g1'), 9007199254740992);
      expect(cell(r, 'goals', 'target', 'g2'), #none);
    });
    test('a transaction amount is taken up to exactly the legacy cap, either sign, and refused beyond', () {
      final r = repo();
      r.applyRemote([
        tx('hi', {'amount': legacyRowCapCents}, 1),
        tx('lo', {'amount': -legacyRowCapCents}, 1),
        tx('hi1', {'amount': legacyRowCapCents + 1}, 1),
        tx('lo1', {'amount': -legacyRowCapCents - 1}, 1),
      ], match: false);
      expect(cell(r, 'tx', 'amount', 'hi'), legacyRowCapCents);
      expect(cell(r, 'tx', 'amount', 'lo'), -legacyRowCapCents);
      expect(cell(r, 'tx', 'amount', 'hi1'), isNot(legacyRowCapCents + 1));
      expect(cell(r, 'tx', 'amount', 'lo1'), isNot(-legacyRowCapCents - 1));
    });
  });
}
