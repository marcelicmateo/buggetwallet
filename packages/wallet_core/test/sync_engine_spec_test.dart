// Spec tests for the relay sync engine (DESIGN_DECISIONS §4.9, RELAY_PROTOCOL.md), written from the spec, not the code.
// Strict per-device order, matching only when caught up, snapshots, pruning, first connect, relay rules, errors.
// All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/engine_spec_sim.dart';

const _day = Duration(days: 1);

void main() {
  late Sim sim;
  setUp(() => sim = Sim());
  tearDown(() => sim.closeAll());

  Iterable<SyncWaiting> waitingFor(SyncReport r, Dev d) => r.waiting.where((w) => w.device == d.short);

  group('convergence', () {
    for (final seed in [1, 2, 3, 4, 5]) {
      test('3 devices, random offline/online rounds (seed $seed): all converge, nothing counted twice', () async {
        final rnd = Random(seed);
        final ds = [sim.device(), sim.device(), sim.device()];
        for (var round = 0; round < 14; round++) {
          for (final d in ds) {
            if (rnd.nextInt(3) == 0) continue; // offline this round
            for (var k = rnd.nextInt(3); k > 0; k--) {
              randomAction(rnd, d);
              sim.tick();
            }
            if (rnd.nextBool()) await d.sync();
            sim.tick();
          }
        }
        await sim.syncAll(ds, rounds: 4);
        final base = canon(ds[0].repo);
        expect(canon(ds[1].repo), base);
        expect(canon(ds[2].repo), base);
        expect(counted(ds[1].repo), counted(ds[0].repo));
        expect(counted(ds[2].repo), counted(ds[0].repo));
        for (final d in ds) {
          final ids = d.repo.transactions().map((t) => t.id).toList();
          expect(ids.toSet().length, ids.length);
          // A hidden (matched) entry points at a bank row that exists and is live.
          for (final t in d.repo.transactions(includeHidden: true).where((t) => t.matchedTo != null && !t.deleted)) {
            expect(d.repo.transaction(t.matchedTo!), isNotNull, reason: 'match target present');
          }
        }
      });
    }

    test('a second run without changes sends and receives nothing; all devices report caught up and list each other', () async {
      final a = sim.device(), b = sim.device(), c = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      b.repo.addManual(date: '2026-01-13', amount: 500, category: 'Eating out');
      await sim.syncAll([a, b, c]);
      for (final d in [a, b, c]) {
        final r = await d.sync();
        expect(r.sent, 0);
        expect(r.received, 0);
        expect(r.caughtUp, isTrue);
        expect(r.waiting, isEmpty);
        expect(r.problems, isEmpty);
        expect(r.devices.length, 3);
        expect(r.devices.where((x) => x.isThis).length, 1);
        expect(r.devices.singleWhere((x) => x.isThis).device, d.short);
      }
    });

    test('data arriving in a different order on two devices ends equal (clocks included)', () async {
      final a = sim.device(), b = sim.device(), c = sim.device(), d = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      sim.tick();
      b.repo.importBatch(batch([('2026-01-13', -700, 'POS TESTSHOP 2')]));
      await a.sync();
      await b.sync();
      await c.sync(); // sees a then b
      sim.tick();
      a.repo.setCategory(a.repo.transactions().first.id, 'Groceries');
      await a.sync();
      await d.sync(); // only joins later
      await sim.syncAll([a, b, c, d]);
      expect(canon(d.repo), canon(a.repo));
      expect(canon(c.repo), canon(a.repo));
    });
  });

  group('strict order', () {
    test('a corrupted file N stops that device\'s later files; other devices still apply; stays waiting', () async {
      final a = sim.device(), b = sim.device(), c = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      await a.sync(); // seq 1
      a.repo.importBatch(batch([('2026-01-13', -700, 'POS TESTSHOP 2')]));
      await a.sync(); // seq 2
      a.repo.importBatch(batch([('2026-01-14', -300, 'POS TESTSHOP 3')]));
      await a.sync(); // seq 3
      c.repo.addManual(date: '2026-01-15', amount: 100, category: 'Eating out');
      await c.sync();
      sim.transport.corrupt(a.id, 2);
      b.repo.addManual(date: '2026-01-16', amount: 250, category: 'Eating out');
      final r = await b.sync();
      expect(r.caughtUp, isFalse);
      final w = waitingFor(r, a).single;
      expect(w.seq, 2);
      expect(w.reason, SyncProblemReason.corrupt);
      expect(r.problems.any((p) => p.reason == SyncProblemReason.corrupt), isTrue);
      final amounts = b.repo.transactions().map((t) => t.amount).toSet();
      expect(amounts, containsAll([-1200, -100, -250]), reason: 'seq 1 of A, C\'s file and own entry');
      expect(amounts, isNot(contains(-700)));
      expect(amounts, isNot(contains(-300)), reason: 'seq 3 is behind the gap');
      expect(r.sent, greaterThan(0), reason: 'own file is uploaded while waiting');
      // Next run: still waiting, nothing new applied from A, ack is up to what was applied (1).
      final r2 = await b.sync();
      expect(r2.caughtUp, isFalse);
      expect(waitingFor(r2, a).single.seq, 2);
      expect((await sim.transport.state()).devices[b.id]!.acks[a.id], 1);
      expect(b.repo.transactions().map((t) => t.amount), isNot(contains(-300)));
      // C is not blocked by A's bad file and receives B's entry.
      await c.sync();
      expect(c.repo.transactions().map((t) => t.amount), contains(-250));
    });

    test('a transient read failure: waiting with no reason, the next run applies and is caught up', () async {
      final a = sim.device(), b = sim.device();
      for (var i = 0; i < 3; i++) {
        a.repo.importBatch(batch([('2026-01-1${2 + i}', -100 * (i + 1), 'POS TESTSHOP $i')]));
        await a.sync();
      }
      sim.transport.failGet(a.id, 2);
      final r = await b.sync();
      expect(r.caughtUp, isFalse);
      final w = waitingFor(r, a).single;
      expect(w.seq, 2);
      expect(w.reason, isNull);
      expect(b.repo.transactions().length, 1, reason: 'only seq 1');
      final r2 = await b.sync();
      expect(r2.caughtUp, isTrue);
      expect(r2.waiting, isEmpty);
      expect(b.repo.transactions().length, 3);
      expect(canon(b.repo), canon(a.repo));
    });

    test('applying is idempotent: a device that already has the data and re-syncs changes nothing', () async {
      final a = sim.device(), b = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      await sim.syncAll([a, b]);
      final before = canon(b.repo, clocks: true);
      await sim.syncAll([a, b]);
      expect(canon(b.repo, clocks: true), before);
    });
  });

  group('matching only when caught up', () {
    test('lagging device: no match to an equal card payment it never held; once caught up the closest row matches', () async {
      final l = sim.device(), p = sim.device();
      l.repo.importBatch(batch([('2026-01-15', -2340, 'POS EXAMPLE MART')])); // R1, an earlier purchase
      await l.sync(); // seq 1
      l.repo.importBatch(batch([('2026-01-17', -2340, 'POS EXAMPLE MART')])); // R2, the real one
      await l.sync(); // seq 2
      // P holds nothing yet and adds the cash entry for the 17th.
      final m = p.repo.addManual(date: '2026-01-17', amount: 2340, category: 'Eating out');
      sim.transport.failGet(l.id, 2);
      final r = await p.sync(); // applies seq 1 (R1), then waits for seq 2
      expect(r.caughtUp, isFalse);
      expect(p.repo.transaction(m)!.matchedTo, isNull, reason: 'matching waits until caught up');
      expect(p.repo.transactions().where((t) => t.manual).length, 1);
      final r2 = await p.sync();
      expect(r2.caughtUp, isTrue);
      final r2row = bankRow(p.repo, '2026-01-17', -2340);
      expect(p.repo.transaction(m)!.matchedTo, r2row.id, reason: 'closest day wins once both rows are known');
      expect(p.repo.transactions().where((t) => t.manual), isEmpty);
      expect(counted(p.repo), -4680, reason: 'two card payments, the entry is gone');
      await sim.syncAll([l, p]);
      expect(l.repo.transaction(m)!.matchedTo, r2row.id);
      expect(canon(l.repo), canon(p.repo));
    });

    test('a gap does not let seen_bank claim rows never held: the entry is replaced, not counted twice', () async {
      final l = sim.device(), p = sim.device();
      l.repo.importBatch(batch([('2026-01-05', -1000, 'POS TESTSHOP A')]));
      await l.sync(); // seq 1
      await p.sync(); // P holds seq 1
      l.repo.importBatch(batch([('2026-01-17', -2340, 'POS EXAMPLE MART')]));
      await l.sync(); // seq 2
      l.repo.importBatch(batch([('2026-01-20', -700, 'POS TESTSHOP B')]));
      await l.sync(); // seq 3
      final m = p.repo.addManual(date: '2026-01-17', amount: 2340, category: 'Eating out');
      sim.transport.failGet(l.id, 2);
      final r = await p.sync();
      expect(r.caughtUp, isFalse);
      expect(p.repo.transactions().map((t) => t.amount), isNot(contains(-700)), reason: 'seq 3 is behind the gap');
      expect(p.repo.transaction(m)!.matchedTo, isNull);
      expect(counted(p.repo), -1000 - 2340);
      final r2 = await p.sync();
      expect(r2.caughtUp, isTrue);
      expect(p.repo.transaction(m)!.matchedTo, bankRow(p.repo, '2026-01-17', -2340).id);
      expect(counted(p.repo), -1000 - 2340 - 700, reason: 'each expense once');
      await sim.syncAll([l, p]);
      expect(counted(l.repo), counted(p.repo));
      expect(canon(l.repo), canon(p.repo));
    });

    test('a permanent gap (corrupt file) never matches: the entry keeps counting, the unseen row is not applied', () async {
      final l = sim.device(), p = sim.device();
      l.repo.importBatch(batch([('2026-01-05', -1000, 'POS TESTSHOP A')]));
      await l.sync();
      l.repo.importBatch(batch([('2026-01-17', -2340, 'POS EXAMPLE MART')]));
      await l.sync();
      sim.transport.corrupt(l.id, 2);
      final m = p.repo.addManual(date: '2026-01-17', amount: 2340, category: 'Eating out');
      for (var i = 0; i < 3; i++) {
        final r = await p.sync();
        expect(r.caughtUp, isFalse);
        expect(p.repo.transaction(m)!.matchedTo, isNull);
      }
      expect(counted(p.repo), -1000 - 2340);
    });

    test('own-transfer pairing also waits: no pairing while a device is behind', () async {
      final l = sim.device(), p = sim.device();
      l.repo.importBatch(batch([('2026-01-05', -1000, 'POS TESTSHOP A')]));
      await l.sync();
      l.repo.importBatch(batch([('2026-01-06', -500, 'POS TESTSHOP B')]));
      await l.sync();
      sim.transport.failGet(l.id, 2);
      final r = await p.sync();
      expect(r.caughtUp, isFalse);
      expect(p.repo.transactions().every((t) => t.transferTo == null), isTrue);
    });
  });

  group('snapshots', () {
    Future<void> activity(Dev d, int rows) async {
      for (var i = 0; i < rows; i++) {
        d.repo.addManual(date: '2026-01-1${i % 9}', amount: 100 + i, category: 'Eating out');
      }
    }

    test('written by a caught-up device after 7 days; covers = everything it applied plus its own last seq', () async {
      final a = sim.device(), b = sim.device();
      await activity(a, 3);
      await sim.syncAll([a, b]);
      sim.tick(_day * 8);
      await sim.syncAll([a, b]);
      final s = await sim.transport.state();
      expect(s.snapshot, isNotNull);
      for (final e in s.devices.entries) {
        expect(s.snapshot!.covers[e.key], e.value.last, reason: 'covers ${e.key}');
      }
    });

    test('not written by a device that is not caught up, even after 8 days', () async {
      final a = sim.device(), b = sim.device();
      await activity(a, 2);
      await a.sync();
      sim.tick(_day * 8);
      sim.transport.failGet(a.id, 1, times: 5);
      await b.sync(); // never caught up
      sim.tick(_day * 1);
      final r = await b.sync();
      expect(r.caughtUp, isFalse);
      expect((await sim.transport.state()).snapshot, isNull);
    });

    test('no second snapshot a day after the first (few ops, recent)', () async {
      final a = sim.device();
      await activity(a, 2);
      await a.sync();
      sim.tick(_day * 8);
      await a.sync();
      final first = (await sim.transport.state()).snapshot!.id;
      sim.tick(_day * 1);
      await activity(a, 1);
      await a.sync();
      expect((await sim.transport.state()).snapshot!.id, first);
    });

    test('written after 500 ops without waiting 7 days', () async {
      final a = sim.device();
      await activity(a, 520);
      await a.sync();
      await a.sync();
      expect((await sim.transport.state()).snapshot, isNotNull);
    });

    /// A, B active for [days] days (an entry each step, snapshots every 8 days), pruned once everyone acked.
    Future<void> longRun(List<Dev> active, int days) async {
      for (var d = 0; d < days; d += 8) {
        sim.tick(_day * 8);
        active.first.repo.addManual(date: '2026-02-01', amount: 100 + d, category: 'Eating out');
        await sim.syncAll(active, rounds: 3);
      }
    }

    test('a new device starts from the snapshot (files pruned) and ends equal, clocks kept', () async {
      final a = sim.device(), b = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      a.repo.setCategory(a.repo.transactions().first.id, 'Groceries');
      sim.tick();
      b.repo.addManual(date: '2026-01-13', amount: 500, category: 'Eating out');
      await longRun([a, b], 40);
      final s = await sim.transport.state();
      expect(s.devices[a.id]!.first, greaterThan(1), reason: 'early files pruned (two snapshots cover them, both acked)');
      final c = sim.device();
      final r = await c.sync();
      expect(r.caughtUp, isTrue);
      await sim.syncAll([a, b, c]);
      expect(canon(c.repo, clocks: true), canon(a.repo, clocks: true));
      expect(canon(c.repo), canon(b.repo));
    });

    test('later edits on other devices still win or lose by their original clocks (after a snapshot)', () async {
      for (final bLater in [false, true]) {
        final s = Sim();
        addTearDown(s.closeAll);
        final a = s.device(), b = s.device();
        a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
        await s.syncAll([a, b]);
        final id = a.repo.transactions().single.id;
        // Both edit offline; the order of the clocks decides.
        s.tick();
        (bLater ? a : b).repo.setCategory(id, 'Groceries');
        s.tick();
        (bLater ? b : a).repo.setCategory(id, 'Transport');
        const winner = 'Transport';
        await a.sync(); // a uploads, snapshot-age passes while b is away
        s.tick(_day * 8);
        await a.sync();
        await a.sync();
        await b.sync(); // b catches up: its older/newer edit meets the snapshotted state
        await s.syncAll([a, b]);
        final c = s.device();
        await s.syncAll([a, b, c]);
        for (final d in [a, b, c]) {
          expect(d.repo.transaction(id)!.category, winner, reason: 'bLater=$bLater');
        }
        expect(canon(a.repo, clocks: true), canon(c.repo, clocks: true));
      }
    });

    test('goal contributions survive a snapshot and a late joiner', () async {
      final a = sim.device(), b = sim.device();
      final g = a.repo.saveGoal(name: 'Trip', target: 100000, saved: 1000, monthly: 0);
      await sim.syncAll([a, b]);
      a.repo.addGoalContribution(g, 5000);
      sim.tick();
      b.repo.addGoalContribution(g, 2000);
      await longRun([a, b], 40);
      final s = await sim.transport.state();
      expect(s.devices[a.id]!.first, greaterThan(1));
      final c = sim.device();
      await sim.syncAll([a, b, c]);
      for (final d in [a, b, c]) {
        expect(d.repo.goals().single.saved, 8000, reason: 'base 1000 + 5000 + 2000, each once');
      }
    });
  });

  group('pruning', () {
    test('kept while a device seen within 90 days has not acked; pruned once it is silent for 91 days', () async {
      final a = sim.device(), b = sim.device(), d = sim.device();
      a.repo.addManual(date: '2026-01-12', amount: 100, category: 'Eating out');
      await sim.syncAll([a, b, d]);
      final dAck = (await sim.transport.state()).devices[d.id]!.acks[a.id]!;
      expect(dAck, greaterThan(0));
      // D goes silent. A and B keep going.
      var t = 0;
      Future<void> step() async {
        sim.tick(_day * 8);
        t += 8;
        a.repo.addManual(date: '2026-02-01', amount: 100 + t, category: 'Eating out');
        await sim.syncAll([a, b], rounds: 3);
      }

      while (t < 80) {
        await step();
      }
      var s = await sim.transport.state();
      expect(s.devices[a.id]!.first, lessThanOrEqualTo(dAck + 1), reason: 'D (seen < 90 days ago) still needs these');
      while (t < 100) {
        await step();
      }
      s = await sim.transport.state();
      expect(s.devices[a.id]!.first, greaterThan(dAck + 1), reason: 'D silent 91+ days no longer holds files back');
      // D returns with an unsynced local edit; its next needed file is gone.
      d.repo.addManual(date: '2026-02-02', amount: 4242, category: 'Eating out');
      final r = await d.sync();
      expect(r.caughtUp, isTrue);
      await sim.syncAll([a, b, d]);
      for (final x in [a, b, d]) {
        expect(x.repo.transactions().map((e) => e.amount), contains(-4242), reason: 'D\'s own edit kept and shared');
      }
      expect(canon(d.repo), canon(a.repo));
      expect(canon(b.repo), canon(a.repo));
    });
  });

  group('first connect', () {
    test('two devices with data from the old folder sync connect to an empty relay: full state first, last writer wins', () async {
      final a = sim.device(), b = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      // The old sync delivered the import to b.
      b.repo.applyRemote([for (final (_, op) in a.repo.pendingOps()) op]);
      sim.tick();
      a.repo.addManual(date: '2026-01-13', amount: 111, category: 'Eating out');
      b.repo.addManual(date: '2026-01-14', amount: 222, category: 'Eating out');
      final id = a.repo.transactions().firstWhere((t) => !t.manual).id;
      sim.tick();
      a.repo.setCategory(id, 'Groceries');
      sim.tick();
      b.repo.setCategory(id, 'Transport'); // later
      // Everything counts as already exported by the old sync.
      for (final d in [a, b]) {
        final p = d.repo.pendingOps();
        if (p.isNotEmpty) d.repo.markExported(p.map((e) => e.$1).reduce(max));
        expect(d.repo.pendingOps(), isEmpty);
      }
      final ra = await a.sync();
      expect(ra.sent, greaterThan(0), reason: 'the whole state is uploaded although nothing was pending');
      await b.sync();
      await sim.syncAll([a, b]);
      expect(canon(a.repo), canon(b.repo));
      expect(a.repo.transaction(id)!.category, 'Transport');
      expect(a.repo.transactions().map((t) => t.amount), containsAll([-111, -222, -1200]));
    });
  });

  group('relay rules (MemoryTransport)', () {
    final bytes = [1, 2, 3];
    Future<void> expectFailure(Future<void> f, TransportFailure failure) async {
      try {
        await f;
        fail('expected $failure');
      } on TransportException catch (e) {
        expect(e.failure, failure);
      }
    }

    test('a gap is rejected, the next seq is accepted, the same bytes again are fine, other bytes conflict', () async {
      final t = sim.transport;
      await expectFailure(t.put('dev-a', 2, bytes), TransportFailure.rejected);
      await t.put('dev-a', 1, bytes);
      await t.put('dev-a', 1, bytes);
      await expectFailure(t.put('dev-a', 1, [9, 9]), TransportFailure.conflict);
      expect(await t.get('dev-a', 1), bytes, reason: 'never overwritten');
      await expectFailure(t.put('dev-a', 3, bytes), TransportFailure.rejected);
      await t.put('dev-a', 2, bytes);
      final s = await t.state();
      expect(s.devices['dev-a']!.first, 1);
      expect(s.devices['dev-a']!.last, 2);
    });

    test('get of a never stored file is missing', () async {
      await sim.transport.put('dev-a', 1, bytes);
      await expectFailure(sim.transport.get('dev-a', 5), TransportFailure.missing);
      await expectFailure(sim.transport.getSnapshot('nope'), TransportFailure.missing);
    });

    test('acks only grow; an ack above the peer\'s last is rejected', () async {
      final t = sim.transport;
      await t.put('dev-a', 1, bytes);
      await t.put('dev-a', 2, bytes);
      await t.ack('dev-b', {'dev-a': 2});
      await t.ack('dev-b', {'dev-a': 1});
      expect((await t.state()).devices['dev-b']!.acks['dev-a'], 2);
      await expectFailure(t.ack('dev-b', {'dev-a': 3}), TransportFailure.rejected);
      expect((await t.state()).devices['dev-b']!.acks['dev-a'], 2);
    });

    test('a snapshot must dominate the current one and stay within last; the older of the two is dropped', () async {
      final t = sim.transport;
      for (var i = 1; i <= 3; i++) {
        await t.put('dev-a', i, bytes);
      }
      await t.putSnapshot('s1', {'dev-a': 2}, bytes);
      await expectFailure(t.putSnapshot('s2', {'dev-a': 1}, bytes), TransportFailure.conflict);
      await expectFailure(t.putSnapshot('s2', {'dev-a': 4}, bytes), TransportFailure.rejected);
      await t.putSnapshot('s2', {'dev-a': 3}, bytes);
      await t.putSnapshot('s3', {'dev-a': 3}, bytes);
      final s = await t.state();
      expect(s.snapshot!.id, 's3');
      expect(s.previous!.id, 's2');
      await expectFailure(t.getSnapshot('s1'), TransportFailure.missing);
      expect(await t.getSnapshot('s3'), bytes);
    });

    test('a file is pruned only when both kept snapshots cover it and every device seen in 90 days acked it', () async {
      final t = sim.transport;
      for (var i = 1; i <= 3; i++) {
        await t.put('dev-a', i, bytes);
      }
      await t.ack('dev-b', {'dev-a': 2});
      await t.ack('dev-c', {'dev-a': 1});
      await t.putSnapshot('s1', {'dev-a': 3}, bytes);
      await t.putSnapshot('s2', {'dev-a': 3}, bytes);
      var s = await t.state();
      expect(s.devices['dev-a']!.first, 2, reason: 'C acked only 1');
      await expectFailure(t.get('dev-a', 1), TransportFailure.gone);
      expect(await t.get('dev-a', 2), bytes);
      await t.ack('dev-c', {'dev-a': 2});
      s = await t.state();
      expect(s.devices['dev-a']!.first, 3);
      // C silent for 91 days no longer blocks; B acked 2 only, so 3 stays until B acks it.
      sim.tick(_day * 91);
      await t.ack('dev-b', {'dev-a': 3});
      s = await t.state();
      expect(s.devices['dev-a']!.first, 4, reason: 'all pruned: first = last + 1');
    });

    test('a file only one snapshot covers is not pruned', () async {
      final t = sim.transport;
      for (var i = 1; i <= 3; i++) {
        await t.put('dev-a', i, bytes);
      }
      await t.ack('dev-b', {'dev-a': 3});
      await t.putSnapshot('s1', {'dev-a': 1}, bytes);
      await t.putSnapshot('s2', {'dev-a': 3}, bytes);
      expect((await t.state()).devices['dev-a']!.first, 2, reason: 'only seq 1 is covered by both');
    });

    test('offline: every call fails as unreachable', () async {
      sim.transport.offline = true;
      await expectFailure(sim.transport.state(), TransportFailure.unreachable);
    });
  });

  group('errors', () {
    test('offline: run() throws SyncException and nothing is marked exported', () async {
      final a = sim.device();
      a.repo.importBatch(batch([('2026-01-12', -1200, 'POS TESTSHOP 1')]));
      final pending = a.repo.pendingOps().length;
      expect(pending, greaterThan(0));
      sim.transport.offline = true;
      await expectLater(a.sync(), throwsA(isA<SyncException>()));
      expect(a.repo.pendingOps().length, pending);
      sim.transport.offline = false;
      final r = await a.sync();
      expect(r.sent, greaterThan(0));
      expect(a.repo.pendingOps(), isEmpty);
    });

    test('files sealed with another wallet\'s key are quarantined as badKey and never applied', () async {
      final good = sim.device(), stranger = sim.device(otherKey: VaultKey.generate());
      stranger.repo.addManual(date: '2026-01-12', amount: 999, category: 'Eating out');
      await stranger.sync();
      good.repo.addManual(date: '2026-01-13', amount: 111, category: 'Eating out');
      final r = await good.sync();
      expect(r.problems.where((p) => p.reason == SyncProblemReason.badKey), isNotEmpty);
      expect(good.repo.transactions().map((t) => t.amount), [-111]);
      expect(r.caughtUp, isFalse);
      final w = waitingFor(r, stranger).single;
      expect(w.reason, SyncProblemReason.badKey);
      final r2 = await good.sync();
      expect(good.repo.transactions().map((t) => t.amount), [-111]);
      expect(r2.problems.any((p) => p.reason == SyncProblemReason.badKey), isTrue);
    });
  });

  group('deriveKey', () {
    final k = VaultKey(List<int>.generate(32, (i) => i));
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    test('deterministic, differs per info and per key, length honoured', () async {
      final a = await deriveKey(k, 'bw-test-a');
      expect(await deriveKey(k, 'bw-test-a'), a);
      expect(a.length, 32);
      expect(await deriveKey(k, 'bw-test-b'), isNot(a));
      expect(await deriveKey(VaultKey.generate(), 'bw-test-a'), isNot(a));
      for (final l in [1, 16, 64]) {
        expect((await deriveKey(k, 'bw-test-a', length: l)).length, l);
      }
    });

    test('matches HKDF-SHA256 with an empty salt (known answers for the key 00 01 .. 1f)', () async {
      expect(hex(await deriveKey(k, 'bw-relay-id-v1', length: 16)), 'f8dd068ef9f042c4f529e15c8ae50335');
      expect(hex(await deriveKey(k, 'bw-relay-auth-v1')), '0a50dea33ef1ee469c20bcbeb4ce774f43478efa25a88e1449c916e163879de2');
      expect(hex(await deriveKey(k, 'bw-local-db-v1')), 'e2adf976d66d436d55e0daf2d8d19856b7bfdbc147fa3e31a0303af52f21d14a');
    });
  });
}
