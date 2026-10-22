// Sync self-heal (R6a, R3 follow-up): a file a peer refused that no snapshot covers would block that peer for good.
// The author, when caught up, writes a snapshot once a recently seen peer has been stuck on its files for over 24 h.
// All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/engine_spec_sim.dart';

void main() {
  late Sim sim;
  setUp(() => sim = Sim());
  tearDown(() => sim.closeAll());

  /// A and B in sync, then A's file 2 is damaged on the relay before B reads it: B stops at it.
  Future<(Dev, Dev)> stuckPair() async {
    final a = sim.device(), b = sim.device();
    a.repo.importBatch(batch([('2026-01-08', -1200, 'POS TESTSHOP 1')]));
    await a.sync(); // seq 1 (first connect: whole state)
    await b.sync();
    await a.sync();
    a.repo.addTransaction(date: '2026-01-09', amount: 450, category: 'Eating out');
    await a.sync(); // seq 2
    sim.transport.corrupt(a.id, 2);
    sim.tick();
    final r = await b.sync();
    expect(r.caughtUp, isFalse);
    expect(r.waiting.single.seq, 2);
    return (a, b);
  }

  Future<RelaySnapshot?> snapshot() async => (await sim.transport.state()).snapshot;

  test('the author writes a snapshot once the peer is stuck over 24 h; the peer is unstuck on its next run', () async {
    final (a, b) = await stuckPair();
    final before = (await snapshot())?.id;
    // Within 24 h of A's upload (A tracks B from then: B's ack is below A's last): both keep syncing, B stays stuck,
    // no snapshot yet (not aged, far below 500 ops).
    for (final h in [6, 6, 6, 5]) {
      sim.tick(Duration(hours: h));
      expect((await b.sync()).caughtUp, isFalse);
      expect((await a.sync()).caughtUp, isTrue);
      expect((await snapshot())?.id, before);
    }
    // Past 24 h: A heals.
    sim.tick(const Duration(hours: 1, minutes: 30));
    await b.sync(); // B is still around (lastSeen fresh) and still stuck
    await a.sync();
    final snap = await snapshot();
    expect(snap, isNotNull);
    expect(snap!.id, isNot(before));
    expect(snap.covers[a.id], greaterThanOrEqualTo(2));

    final r = await b.sync();
    expect(r.caughtUp, isTrue);
    expect(r.waiting, isEmpty);
    expect(b.repo.transactions().map((t) => t.amount), contains(-450), reason: 'the refused file\'s change arrived via the snapshot');
    expect(canon(b.repo), canon(a.repo));

    // Healed: no further snapshots while nothing new happens.
    sim.tick(const Duration(hours: 30));
    await b.sync();
    await a.sync();
    expect((await snapshot())!.id, snap.id);
  });

  test('a peer not seen for 24 h gets no snapshot (it is away, not stuck)', () async {
    final (a, _) = await stuckPair();
    final before = (await snapshot())?.id;
    sim.tick(const Duration(hours: 12));
    await a.sync();
    sim.tick(const Duration(hours: 14)); // B was last seen 26 h ago
    await a.sync();
    expect((await snapshot())?.id, before);
  });

  test('a peer that keeps applying is never taken as stuck', () async {
    final a = sim.device(), b = sim.device();
    await a.sync();
    await b.sync();
    final before = (await snapshot())?.id;
    for (var i = 0; i < 8; i++) {
      a.repo.addTransaction(date: '2026-01-10', amount: 100 + i, category: 'Eating out');
      sim.tick(const Duration(hours: 5));
      await a.sync();
      await b.sync();
    }
    expect((await snapshot())?.id, before);
  });

  test('a device that is not caught up never heals, even with a stuck peer', () async {
    final (a, b) = await stuckPair();
    final c = sim.device();
    await c.sync();
    await a.sync();
    c.repo.addTransaction(date: '2026-01-10', amount: 77, category: 'Eating out');
    await c.sync();
    final seq = (await sim.transport.state()).devices[c.id]!.last;
    sim.transport.corrupt(c.id, seq); // A stops at C's file: A is not caught up
    final before = (await snapshot())?.id;
    for (var i = 0; i < 6; i++) {
      sim.tick(const Duration(hours: 6));
      await b.sync();
      expect((await a.sync()).caughtUp, isFalse);
    }
    expect((await snapshot())?.id, before);
  });

  test('author gone for good: another device that applied the file heals the stuck peer after 24 h', () async {
    final a = sim.device(), b = sim.device(), c = sim.device();
    a.repo.importBatch(batch([('2026-01-08', -1200, 'POS TESTSHOP 1')]));
    await a.sync();
    await b.sync();
    await c.sync();
    a.repo.addTransaction(date: '2026-01-09', amount: 450, category: 'Eating out');
    await a.sync(); // seq 2: A's last file; A is never heard from again
    await c.sync(); // C applies it
    sim.transport.corrupt(a.id, 2);
    sim.tick();
    expect((await b.sync()).waiting.single.seq, 2);
    final before = (await snapshot())?.id;
    for (final h in [6, 6, 6, 5]) {
      sim.tick(Duration(hours: h));
      await b.sync();
      expect((await c.sync()).caughtUp, isTrue);
      expect((await snapshot())?.id, before);
    }
    sim.tick(const Duration(hours: 1, minutes: 30));
    await b.sync();
    await c.sync();
    final snap = await snapshot();
    expect(snap?.id, isNot(before));
    expect(snap!.covers[a.id], 2);
    final r = await b.sync();
    expect(r.caughtUp, isTrue);
    expect(b.repo.transactions().map((t) => t.amount), contains(-450));
  });

  test('no snapshot storm: three devices see the same stuck peer, at most one snapshot is accepted per 24 h', () async {
    final a = sim.device(), b = sim.device(), c = sim.device(), d = sim.device();
    final healers = [a, c, d];
    a.repo.importBatch(batch([('2026-01-08', -1200, 'POS TESTSHOP 1')]));
    await sim.syncAll([a, b, c, d]);
    a.repo.addTransaction(date: '2026-01-09', amount: 450, category: 'Eating out');
    await a.sync();
    await c.sync();
    await d.sync();
    sim.transport.corrupt(a.id, 2);
    expect((await b.sync()).caughtUp, isFalse);
    final accepted = <String, DateTime>{};
    Future<void> note() async {
      final id = (await snapshot())?.id;
      if (id != null) accepted.putIfAbsent(id, () => sim.clock.t);
    }

    await note();
    final initial = accepted.length;
    for (var i = 0; i < 24; i++) {
      sim.tick(const Duration(hours: 3));
      for (final h in healers) {
        await h.sync();
        await note();
      }
      if (i < 12) await b.sync(); // B is around (and stuck) for the first 36 h
    }
    final heals = accepted.values.skip(initial).toList();
    expect(heals, hasLength(1), reason: 'one heal snapshot, written by whichever healer came first');
    final r = await b.sync();
    expect(r.caughtUp, isTrue);
  });

  test('at most one heal snapshot per device per 24 h', () async {
    final (a, b) = await stuckPair();
    final before = (await snapshot())?.id;
    sim.tick(const Duration(hours: 23));
    await b.sync();
    await a.sync();
    a.repo.setLocalValue(SyncEngine.healKey, '${sim.clock.ms}'); // A wrote a heal snapshot (for something else) just now
    sim.tick(const Duration(hours: 2));
    await b.sync();
    await a.sync(); // B stuck for 25 h, but A's last heal is 2 h old
    expect((await snapshot())?.id, before);
    sim.tick(const Duration(hours: 22, minutes: 30));
    await b.sync();
    await a.sync(); // the mark is 24.5 h old
    expect((await snapshot())?.id, isNot(before));
    expect((await b.sync()).caughtUp, isTrue);
  });
}
