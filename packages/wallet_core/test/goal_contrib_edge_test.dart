// Edge cases for goal contributions stored as synced rows (`goal_contrib`: id, goal_id, amount in cents, date) instead
// of one overwritten `saved` number. Written from the spec: Goal.saved = stored base + sum of live contributions.
// All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

int _h = 5000000000000;
String _hlc([String node = 'peer']) => Hlc(_h++, 0, node).toString();

Op _goal(String id, {int saved = 0, int monthly = 0, int deleted = 0, String? hlc}) => Op('goal', id,
    {'name': 'Synthetic goal', 'target': 100000, 'saved': saved, 'monthly': monthly, 'sort': 1, 'deleted': deleted}, hlc ?? _hlc());

Op _contrib(String id, String goal, Object? amount, {String date = '2026-03-05', String? hlc}) =>
    Op('goal_contrib', id, {'goal_id': goal, 'amount': amount, 'date': date}, hlc ?? _hlc());

int _saved(WalletRepo r, String id) => r.goals().firstWhere((g) => g.id == id).saved;

List<Op> _pendingContribs(WalletRepo r) => [
      for (final (_, op) in r.pendingOps())
        if (op.entity == 'goal_contrib') op
    ];

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = 1767225600000;
  final devices = <Device>[];
  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  Future<void> syncAll(List<Device> ds) async {
    for (var round = 0; round < 3; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        await d.run();
        d.upload(net);
      }
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-gc-');
    key = VaultKey.generate();
    net = Net();
    now = 1767225600000;
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  group('offline adds on several devices', () {
    for (final count in [2, 3, 4]) {
      test('$count devices each add to the same goal offline: everyone converges on the sum, no lost update', () async {
        final ds = [for (var i = 0; i < count; i++) device('d$i')];
        final gid = ds[0].repo.saveGoal(name: 'Synthetic goal', target: 500000, saved: 10000, monthly: 0);
        await syncAll(ds);
        for (final d in ds) {
          expect(_saved(d.repo, gid), 10000);
        }
        var want = 10000;
        for (var i = 0; i < count; i++) {
          final a = 1000 * (i + 1);
          ds[i].repo.addGoalContribution(gid, a, date: '2026-03-0${i + 1}');
          want += a;
          if (i.isEven) {
            ds[i].repo.addGoalContribution(gid, 7, date: '2026-03-10');
            want += 7;
          }
        }
        for (final d in ds) {
          expect(_saved(d.repo, gid), greaterThan(10000), reason: 'own adds show at once');
        }
        await syncAll(ds);
        for (final d in ds) {
          expect(_saved(d.repo, gid), want, reason: d.name);
          expect(d.repo.goals(), hasLength(1));
        }
      });
    }

    test('an add on one device and an edit-down (negative delta) on another: both survive', () async {
      final a = device('a'), b = device('b');
      final gid = a.repo.saveGoal(name: 'Synthetic goal', target: 500000, saved: 10000, monthly: 0);
      await syncAll([a, b]);
      a.repo.saveGoal(id: gid, name: 'Synthetic goal', target: 500000, saved: 7000, monthly: 0); // -3000
      b.repo.addGoalContribution(gid, 2500);
      expect(_saved(a.repo, gid), 7000);
      expect(_saved(b.repo, gid), 12500);
      await syncAll([a, b]);
      expect(_saved(a.repo, gid), 9500);
      expect(_saved(b.repo, gid), 9500);
    });

    test('two concurrent edits to different "so far" values both apply as deltas', () async {
      final a = device('a'), b = device('b');
      final gid = a.repo.saveGoal(name: 'Synthetic goal', target: 500000, saved: 10000, monthly: 0);
      await syncAll([a, b]);
      a.repo.saveGoal(id: gid, name: 'Synthetic goal', target: 500000, saved: 12000, monthly: 0); // +2000
      b.repo.saveGoal(id: gid, name: 'Synthetic goal', target: 500000, saved: 9000, monthly: 0); // -1000
      await syncAll([a, b]);
      expect(_saved(a.repo, gid), 11000);
      expect(_saved(b.repo, gid), 11000);
    });
  });

  group('saveGoal(saved:) writes a delta', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('editing "so far" to the same value writes no contribution op', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 4000, monthly: 0);
      r.markExported(r.pendingOps().last.$1);
      r.saveGoal(id: gid, name: 'Synthetic goal', target: 100000, saved: 4000, monthly: 0);
      expect(_pendingContribs(r), isEmpty);
      expect(_saved(r, gid), 4000);
      r.saveGoal(id: gid, name: 'Synthetic goal 2', target: 200000, saved: 4000, monthly: 500);
      expect(_pendingContribs(r), isEmpty);
      expect(_saved(r, gid), 4000);
    });

    test('a brand-new goal stores its saved amount as the base: no contribution, with 0 or more (per the package notes)', () {
      final g0 = r.saveGoal(name: 'Synthetic zero', target: 100000, saved: 0, monthly: 0);
      expect(_pendingContribs(r), isEmpty);
      final g1 = r.saveGoal(name: 'Synthetic some', target: 100000, saved: 2500, monthly: 0);
      expect(_pendingContribs(r), isEmpty);
      final goalOp = r.pendingOps().map((p) => p.$2).lastWhere((op) => op.entity == 'goal' && op.id == g1);
      expect(goalOp.fields['saved'], 2500);
      expect(_saved(r, g0), 0);
      expect(_saved(r, g1), 2500);
    });

    test('editing down writes one negative contribution of the difference', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 5000, monthly: 0);
      r.markExported(r.pendingOps().last.$1);
      r.saveGoal(id: gid, name: 'Synthetic goal', target: 100000, saved: 1800, monthly: 0);
      final cs = _pendingContribs(r);
      expect(cs, hasLength(1));
      expect(cs.single.fields['amount'], -3200);
      expect(_saved(r, gid), 1800);
    });

    test('editing down to zero and below zero works; the total follows', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 5000, monthly: 0);
      r.saveGoal(id: gid, name: 'Synthetic goal', target: 100000, saved: 0, monthly: 0);
      expect(_saved(r, gid), 0);
      r.saveGoal(id: gid, name: 'Synthetic goal', target: 100000, saved: -300, monthly: 0);
      expect(_saved(r, gid), -300);
    });

    test('the delta is taken against the legacy stored value plus earlier contributions', () {
      r.applyRemote([_goal('legacy', saved: 8000)]);
      expect(_saved(r, 'legacy'), 8000);
      r.addGoalContribution('legacy', 1500);
      expect(_saved(r, 'legacy'), 9500);
      r.markExported(r.pendingOps().last.$1);
      r.saveGoal(id: 'legacy', name: 'Synthetic goal', target: 100000, saved: 9500, monthly: 0);
      expect(_pendingContribs(r), isEmpty);
      r.saveGoal(id: 'legacy', name: 'Synthetic goal', target: 100000, saved: 10000, monthly: 0);
      expect(_pendingContribs(r).single.fields['amount'], 500);
      expect(_saved(r, 'legacy'), 10000);
    });
  });

  group('addGoalContribution', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('amount 0 leaves the total as it was (whether or not a row is written)', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 1234, monthly: 0);
      r.addGoalContribution(gid, 0);
      expect(_saved(r, gid), 1234);
    });

    test('negative amounts subtract; many small adds add up exactly', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 0, monthly: 0);
      var want = 0;
      for (var i = 1; i <= 40; i++) {
        final a = i.isOdd ? i * 37 : -i * 11;
        r.addGoalContribution(gid, a, date: '2026-03-${(i % 28 + 1).toString().padLeft(2, '0')}');
        want += a;
      }
      expect(_saved(r, gid), want);
    });

    test('two adds on the same day with the same amount are two contributions, not one', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 0, monthly: 0);
      r.addGoalContribution(gid, 1000, date: '2026-03-05');
      r.addGoalContribution(gid, 1000, date: '2026-03-05');
      expect(_saved(r, gid), 2000);
    });

    test('contributions to one goal do not touch another goal', () {
      final a = r.saveGoal(name: 'Synthetic A', target: 100000, saved: 100, monthly: 0);
      final b = r.saveGoal(name: 'Synthetic B', target: 100000, saved: 200, monthly: 0);
      r.addGoalContribution(a, 50);
      expect(_saved(r, a), 150);
      expect(_saved(r, b), 200);
    });

    test('an amount near the 10 billion cap stays exact, and a negative one returns to the start', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 0, monthly: 0);
      const big = 10000000000;
      r.addGoalContribution(gid, big - 1);
      r.addGoalContribution(gid, 1);
      expect(_saved(r, gid), big);
      r.addGoalContribution(gid, -big);
      expect(_saved(r, gid), 0);
      for (var i = 0; i < 5; i++) {
        r.addGoalContribution(gid, big - 1);
      }
      expect(_saved(r, gid), 5 * (big - 1));
    });
  });

  group('applying remote contribution ops', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('the same op applied twice (or in one list twice) counts once', () {
      r.applyRemote([_goal('g1', saved: 1000)]);
      final c = _contrib('c1', 'g1', 400);
      expect(r.applyRemote([c]), 1);
      expect(r.applyRemote([c]), 0);
      expect(r.applyRemote([c, c]), 0);
      expect(_saved(r, 'g1'), 1400);
      expect(r.pendingOps(), isEmpty, reason: 'remote ops are not re-exported');
    });

    test('a contribution that arrives before its goal shows up in the total once the goal arrives', () {
      r.applyRemote([_contrib('c1', 'late', 600), _contrib('c2', 'late', -100)]);
      expect(r.goals(), isEmpty, reason: 'no goal row yet, nothing to show');
      r.applyRemote([_goal('late', saved: 5000)]);
      expect(_saved(r, 'late'), 5500);
    });

    test('order of goal and contributions does not matter', () {
      final ops = [_goal('g1', saved: 300), _contrib('c1', 'g1', 70), _contrib('c2', 'g1', -20), _contrib('c3', 'g1', 1000)];
      for (final p in [
        [0, 1, 2, 3],
        [3, 2, 1, 0],
        [1, 0, 3, 2],
        [2, 3, 0, 1],
        [1, 2, 3, 0],
        [3, 0, 2, 1]
      ]) {
        final x = WalletRepo.inMemory();
        for (final i in p) {
          x.applyRemote([ops[i]]);
        }
        expect(_saved(x, 'g1'), 1350, reason: '$p');
        x.close();
      }
    });

    test('a contribution for a deleted goal does not bring the goal back; a deleted goal hides its contributions', () {
      r.applyRemote([_goal('g1', saved: 100), _contrib('c1', 'g1', 50)]);
      expect(_saved(r, 'g1'), 150);
      r.deleteGoal('g1');
      expect(r.goals(), isEmpty);
      r.applyRemote([_contrib('c2', 'g1', 900)]);
      expect(r.goals(), isEmpty);
    });

    test('adding a contribution locally to a goal that was deleted does not throw or resurrect it', () {
      final gid = r.saveGoal(name: 'Synthetic goal', target: 100000, saved: 100, monthly: 0);
      r.deleteGoal(gid);
      r.addGoalContribution(gid, 10);
      expect(r.goals(), isEmpty);
    });

    test('deleting a goal on one device while another adds: the goal stays deleted everywhere', () async {
      final a = device('a'), b = device('b');
      final gid = a.repo.saveGoal(name: 'Synthetic goal', target: 500000, saved: 1000, monthly: 0);
      await syncAll([a, b]);
      a.repo.deleteGoal(gid);
      b.repo.addGoalContribution(gid, 500);
      await syncAll([a, b]);
      expect(a.repo.goals(), isEmpty);
      expect(b.repo.goals(), isEmpty);
    });

    test('wrong-typed amounts are ignored: nothing is added, the total stays an int', () {
      r.applyRemote([_goal('g1', saved: 1000)]);
      var i = 0;
      for (final bad in <Object?>[
        'abc',
        12.5,
        null,
        true,
        [1],
        {'a': 1}
      ]) {
        r.applyRemote([_contrib('bad${i++}', 'g1', bad)]);
      }
      expect(_saved(r, 'g1'), 1000);
      expect(r.goals().single.saved, isA<int>());
      r.applyRemote([_contrib('ok', 'g1', 5)]);
      expect(_saved(r, 'g1'), 1005);
    });

    test('a wrong-typed goal field never applies the contribution to any goal and never crashes reads', () {
      r.applyRemote([_goal('g1', saved: 1000)]);
      r.applyRemote([
        Op('goal_contrib', 'x1', {'goal_id': 42, 'amount': 900, 'date': '2026-03-05'}, _hlc()),
      ]);
      expect(r.goals(), hasLength(1));
      expect(_saved(r, 'g1'), 1000);
    });

    test('a newer clock on the same contribution id updates its amount; an older one loses', () {
      r.applyRemote([_goal('g1', saved: 0)]);
      r.applyRemote([_contrib('c1', 'g1', 100, hlc: const Hlc(9000000000000, 0, 'p').toString())]);
      r.applyRemote([_contrib('c1', 'g1', 250, hlc: const Hlc(9000000000001, 0, 'p').toString())]);
      r.applyRemote([_contrib('c1', 'g1', 999, hlc: const Hlc(8000000000000, 0, 'p').toString())]);
      expect(_saved(r, 'g1'), 250);
    });

    test('unknown extra fields on a contribution op are ignored', () {
      r.applyRemote([_goal('g1', saved: 0)]);
      r.applyRemote([
        Op('goal_contrib', 'c1', {'goal_id': 'g1', 'amount': 70, 'date': '2026-03-05', 'colour': 'blue'}, _hlc())
      ]);
      expect(_saved(r, 'g1'), 70);
    });
  });

  group('migration of existing data', () {
    test('goals stored by an older build keep their exact total', () {
      final r = WalletRepo.inMemory();
      r.db.execute("INSERT INTO goals(id, name, target, saved, monthly, sort) VALUES('old1', 'Synthetic old', 90000, 12345, 2000, 1)");
      r.db.execute("INSERT INTO goals(id, name, target, saved, monthly, sort) VALUES('old2', 'Synthetic old 2', 50000, 0, 0, 2)");
      r.db.execute("INSERT INTO goals(id, name, target, saved, monthly, sort) VALUES('old3', 'Synthetic neg', 50000, -700, 0, 3)");
      expect(_saved(r, 'old1'), 12345);
      expect(_saved(r, 'old2'), 0);
      expect(_saved(r, 'old3'), -700);
      r.addGoalContribution('old1', 55);
      expect(_saved(r, 'old1'), 12400);
      r.close();
    });

    test('a database file written before the feature reopens with the same totals', () {
      final path = '${tmp.path}/old.db';
      final first = WalletRepo.open(path);
      first.saveGoal(id: 'g1', name: 'Synthetic goal', target: 100000, saved: 0, monthly: 3000);
      first.db.execute("UPDATE goals SET saved = 7777 WHERE id = 'g1'");
      first.close();
      final again = WalletRepo.open(path);
      expect(_saved(again, 'g1'), 7777);
      again.addGoalContribution('g1', 223);
      again.close();
      final third = WalletRepo.open(path);
      expect(_saved(third, 'g1'), 8000);
      third.close();
    });

    test('a legacy saved value synced from an old build still counts alongside contributions', () {
      final r = WalletRepo.inMemory();
      r.applyRemote([_goal('g1', saved: 2000)]);
      r.addGoalContribution('g1', 300);
      r.applyRemote([
        Op('goal', 'g1', {'saved': 2600}, _hlc('oldbuild'))
      ]);
      expect(_saved(r, 'g1'), 2900, reason: 'legacy 2600 + contribution 300');
      r.close();
    });
  });

  group('budget engine is unchanged', () {
    test('per-period goal monthly depends only on the goals\' monthly, not on contributions', () {
      final r = WalletRepo.inMemory();
      final g1 = r.saveGoal(name: 'Synthetic A', target: 500000, saved: 0, monthly: 10000);
      final g2 = r.saveGoal(name: 'Synthetic B', target: 500000, saved: 0, monthly: 5000);
      const st = WalletSettings(salary: 150000, paydayDay: 15, periodStart: '2026-01-15');
      final before = computePeriod(const [], st, r.goals(), '2026-01-20');
      r.addGoalContribution(g1, 123456);
      r.addGoalContribution(g2, -999);
      r.saveGoal(id: g2, name: 'Synthetic B', target: 500000, saved: 70000, monthly: 5000);
      final after = computePeriod(const [], st, r.goals(), '2026-01-20');
      expect(before.goalMonthly, 15000);
      expect(after.goalMonthly, 15000);
      expect(after.allowanceToday, before.allowanceToday);
      r.close();
    });

    test('a contribution is not a transaction', () {
      final r = WalletRepo.inMemory();
      final g = r.saveGoal(name: 'Synthetic A', target: 500000, saved: 0, monthly: 0);
      r.importBatch(january);
      final txBefore = r.transactions().length;
      r.addGoalContribution(g, 40000);
      expect(r.transactions(), hasLength(txBefore));
      r.close();
    });
  });

  group('logs carry no amounts or names', () {
    test('adding, editing, applying and syncing contributions logs nothing private', () async {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = was;
      });
      final a = device('a'), b = device('b');
      final gid = a.repo.saveGoal(name: 'Zebra Fund Synthetic', target: 987654, saved: 424242, monthly: 0);
      a.repo.addGoalContribution(gid, 313131);
      a.repo.saveGoal(id: gid, name: 'Zebra Fund Synthetic', target: 987654, saved: 515151, monthly: 0);
      b.repo.applyRemote([_contrib('c9', gid, 'Synthetic Secret'), _contrib('c8', gid, 272727)]);
      await syncAll([a, b]);
      final text = lines.join('\n');
      expect(text, isNotEmpty);
      for (final s in ['Zebra', '424242', '313131', '515151', '272727', '987654', 'Synthetic Secret']) {
        expect(text, isNot(contains(s)), reason: 'private "$s" in the log');
      }
      final bad = lines.where((l) => l.contains('repo.badField') && l.contains('goal_contrib')).toList();
      expect(bad, isNotEmpty);
      expect(bad.join(), contains('"field":"amount"'));
    });
  });
}
