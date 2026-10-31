// KL (owner 2026-10-31): a device stuck on a damaged sync file asks the file's author to resend its state and write a
// snapshot covering it; if the author is gone, the owner can skip the file (Settings › Sync). All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/engine_spec_sim.dart';

void main() {
  late Sim sim;
  setUp(() => sim = Sim());
  tearDown(() => sim.closeAll());

  Future<RelayState> state() => sim.transport.state();
  Future<int> lastOf(Dev d) async => (await state()).devices[d.id]?.last ?? 0;
  bool resendQueued(Dev d) => (jsonDecode(d.repo.localValue('syncDigest') ?? '{}') as Map).containsKey('send');

  /// A and B in sync; A's file 2 (a change B has not read) is damaged on the relay, then A writes file 3. With [c] given,
  /// it reads file 2 before the damage. B's first run after that stops at file 2 (quarantined, a later file exists).
  Future<(Dev, Dev)> blockedPair({Dev? c}) async {
    final a = sim.device(), b = sim.device();
    a.repo.importBatch(batch([('2026-01-08', -1200, 'POS TESTSHOP 1')]));
    await a.sync(); // seq 1: whole state
    await b.sync();
    if (c != null) await c.sync();
    await a.sync();
    sim.tick();
    a.repo.addTransaction(date: '2026-01-09', amount: 450, category: 'Eating out');
    await a.sync(); // seq 2
    if (c != null) await c.sync();
    sim.transport.corrupt(a.id, 2);
    sim.tick();
    a.repo.addTransaction(date: '2026-01-09', amount: 730, category: 'Groceries');
    await a.sync(); // seq 3
    sim.tick();
    final r = await b.sync();
    expect(r.caughtUp, isFalse);
    expect(r.waiting.single.seq, 2);
    return (a, b);
  }

  test('blocked B asks the author; the author writes a covering snapshot (the answer, no resend); B goes on without skipping', () async {
    final (a, b) = await blockedPair();
    final blocked = blockedFiles(b.repo);
    expect(blocked, hasLength(1));
    expect([blocked.single.device, blocked.single.file, blocked.single.reason], [a.id, '2', SyncProblemReason.corrupt]);
    expect(blocked.single.short, a.short);
    expect(blocked.single.authorSeen, isNotNull);
    final bLast = await lastOf(b);

    sim.tick();
    expect((await b.sync()).caughtUp, isFalse, reason: 'second blocked run: the ask goes out');
    expect(await lastOf(b), bLast + 1, reason: 'one records-only file with the ask');

    sim.tick();
    final snapBefore = (await state()).snapshot?.id;
    await a.sync(); // reads the ask: snapshot now
    final snap = (await state()).snapshot;
    expect(snap?.id, isNot(snapBefore));
    expect(snap!.covers[a.id], greaterThanOrEqualTo(2));
    expect(resendQueued(a), isFalse, reason: 'RF7: the snapshot covers the asked file, so it is the answer');

    sim.tick();
    final r = await b.sync();
    expect(r.caughtUp, isTrue);
    expect(b.repo.transactions().map((t) => t.amount), containsAll([-450, -730]));
    expect(blockedFiles(b.repo), isEmpty);
    expect(b.repo.localValue('syncSkipped'), isNull, reason: 'nothing skipped');

    await a.sync();
    await b.sync();
    expect(canon(b.repo), canon(a.repo));
    // Settled: no more asks, snapshots or resends.
    final (la, lb, id) = (await lastOf(a), await lastOf(b), (await state()).snapshot!.id);
    for (var i = 0; i < 3; i++) {
      sim.tick(const Duration(hours: 10));
      await b.sync();
      await a.sync();
    }
    expect(await lastOf(b), lb);
    expect((await state()).snapshot!.id, id);
    expect(await lastOf(a), lessThanOrEqualTo(la + 1), reason: 'at most a digest record file');
  });

  test('the ask is bounded: one per blocked file per 24 h, however often B runs', () async {
    final (_, b) = await blockedPair(); // A never syncs again
    final bLast = await lastOf(b);
    for (var i = 0; i < 10; i++) {
      sim.tick(const Duration(hours: 2));
      await b.sync();
    }
    expect(await lastOf(b), bLast + 1, reason: 'one ask in 20 h');
    sim.tick(const Duration(hours: 7)); // 25 h after the ask (second run, 2 h in)
    await b.sync();
    expect(await lastOf(b), bLast + 2);
    await b.sync();
    expect(await lastOf(b), bLast + 2);
  });

  test('only the author answers an addressed ask: a bystander that holds the file resends nothing', () async {
    final c = sim.device();
    final (a, b) = await blockedPair(c: c);
    await c.sync();
    sim.tick();
    await b.sync(); // the ask
    sim.tick();
    await c.sync();
    expect(resendQueued(c), isFalse);
    await a.sync();
    expect((await state()).snapshot!.covers[a.id], greaterThanOrEqualTo(2), reason: 'the author answers with a covering snapshot');
    expect(resendQueued(a), isFalse);
  });

  /// [blockedPair] with a third device C whose newest file A cannot read (its GETs fail): A is never caught up, so it
  /// writes no snapshot and answers B's ask with a state resend.
  Future<(Dev, Dev)> blockedAuthorBehind() async {
    final c = sim.device();
    final (a, b) = await blockedPair(c: c);
    c.repo.addTransaction(date: '2026-01-11', amount: 310, category: 'Groceries');
    await c.sync();
    sim.transport.failGet(c.id, await lastOf(c), times: 1000);
    sim.tick();
    await b.sync(); // the ask
    return (a, b);
  }

  test('RF7: an ask no snapshot covers gets one resend; the ask repeated a day later gets no second one', () async {
    final (a, b) = await blockedAuthorBehind();
    sim.tick();
    final r = await a.sync();
    expect(r.caughtUp, isFalse, reason: 'precondition: A cannot write a snapshot');
    expect(resendQueued(a), isTrue, reason: 'the first ask is answered with a resend');
    await a.sync(); // sends it
    expect(resendQueued(a), isFalse);
    final bLast = await lastOf(b);
    sim.tick(const Duration(hours: 25));
    await b.sync();
    expect(blockedFiles(b.repo), hasLength(1), reason: 'precondition: B is still blocked');
    expect(await lastOf(b), bLast + 1, reason: 'precondition: B asked again');
    sim.tick();
    await a.sync();
    expect(resendQueued(a), isFalse, reason: 'one resend per asked file');
    expect(a.repo.localValue(SyncEngine.unblockSentKey), contains('${a.id}/2'));
  });

  test('author gone: blockedFiles shows it with an old authorSeen; skip lets B read the later files', () async {
    final (a, b) = await blockedPair();
    final seenAt = (await state()).devices[a.id]!.lastSeen!;
    sim.tick(const Duration(days: 10));
    await b.sync();
    final blocked = blockedFiles(b.repo).single;
    expect(blocked.authorSeen, seenAt);
    expect(sim.clock.t.difference(blocked.authorSeen!), greaterThan(const Duration(days: 9)));
    expect(blocked.since.isBefore(sim.clock.t), isTrue);

    final outbox = b.repo.pendingOps().length;
    skipBlockedFile(b.repo, blocked.device, blocked.file);
    expect(b.repo.pendingOps().length, outbox, reason: 'device-local: nothing to sync');
    expect(blockedFiles(b.repo), isEmpty);

    final r = await b.sync();
    expect(r.caughtUp, isTrue);
    expect(r.problems, isEmpty);
    final amounts = b.repo.transactions().map((t) => t.amount);
    expect(amounts, contains(-730), reason: 'the later file was read');
    expect(amounts, isNot(contains(-450)), reason: 'the skipped file is lost here');
    expect(b.repo.syncCursors()[a.id], 3);

    // Never retried, and the author coming back later repairs it with a resend.
    await b.sync();
    expect(b.repo.transactions().map((t) => t.amount), isNot(contains(-450)));
    a.repo.queueStateResend();
    await a.sync();
    await b.sync();
    expect(b.repo.transactions().map((t) => t.amount), contains(-450));
    expect(canon(b.repo), canon(a.repo));
  });

  test('three devices: B skips the file C holds; the state digest repair restores it and the digests match', () async {
    final c = sim.device();
    final (a, b) = await blockedPair(c: c);
    expect(c.repo.transactions().map((t) => t.amount), contains(-450));
    // A is gone from here on.
    await c.sync();
    final blocked = blockedFiles(b.repo).single;
    skipBlockedFile(b.repo, blocked.device, blocked.file);
    for (var i = 0; i < 6; i++) {
      sim.tick(const Duration(minutes: 5));
      await b.sync();
      await c.sync();
    }
    expect(b.repo.transactions().map((t) => t.amount), contains(-450), reason: 'C resent its state after the mismatch');
    expect(canon(b.repo), canon(c.repo));
    expect(b.repo.stateDigest(), c.repo.stateDigest());
    expect(canon(b.repo), canon(a.repo));
  });

  test('the skip is device-local and survives a restart', () async {
    final a = sim.device();
    final dir = Directory.systemTemp.createTempSync('bw-kl-skip-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/b.db';
    WalletRepo open() => WalletRepo.open(path, now: () => sim.clock.ms);
    SyncEngine engine() => SyncEngine(sim.transport, sim.key, appVersion: '1.0.0', now: () => sim.clock.t);
    var b = open();
    a.repo.importBatch(batch([('2026-01-08', -1200, 'POS TESTSHOP 1')]));
    await a.sync();
    await engine().run(b);
    a.repo.addTransaction(date: '2026-01-09', amount: 450, category: 'Eating out');
    await a.sync();
    sim.transport.corrupt(a.id, 2);
    a.repo.addTransaction(date: '2026-01-09', amount: 730, category: 'Groceries');
    await a.sync();
    await engine().run(b);
    final blocked = blockedFiles(b).single;
    skipBlockedFile(b, blocked.device, blocked.file);
    b.close();

    b = open();
    addTearDown(b.close);
    expect(blockedFiles(b), isEmpty);
    final r = await engine().run(b);
    expect(r.caughtUp, isTrue);
    expect(b.transactions().map((t) => t.amount), contains(-730));
    expect(b.transactions().map((t) => t.amount), isNot(contains(-450)));
    expect(b.localValue('syncSkipped'), isNotNull, reason: 'kept, so the same bytes are never retried');
  });

  test('a quarantined file with no later file is not listed (it blocks nothing yet); a later file makes it block', () async {
    final a = sim.device(), b = sim.device();
    a.repo.importBatch(batch([('2026-01-08', -1200, 'POS TESTSHOP 1')]));
    await a.sync();
    await b.sync();
    a.repo.addTransaction(date: '2026-01-09', amount: 450, category: 'Eating out');
    await a.sync();
    sim.transport.corrupt(a.id, 2);
    final r = await b.sync();
    expect(r.problems.single.reason, SyncProblemReason.corrupt);
    expect(blockedFiles(b.repo), isEmpty);
    final bLast = await lastOf(b);
    await b.sync();
    expect(await lastOf(b), bLast, reason: 'no ask for a file that blocks nothing');

    a.repo.addTransaction(date: '2026-01-10', amount: 730, category: 'Groceries');
    await a.sync();
    await b.sync();
    expect(blockedFiles(b.repo).single.file, '2');
  });

  test('skipping a file that is not quarantined does nothing', () async {
    final (a, b) = await blockedPair();
    skipBlockedFile(b.repo, a.id, '3');
    expect(b.repo.localValue('syncSkipped'), isNull);
    expect(blockedFiles(b.repo), hasLength(1));
  });

  /// B's quarantine entry of A's file 2 rewritten to [reason] (same bytes, same hash), as if it had been refused so.
  void requarantine(Dev b, SyncProblemReason reason) {
    final list = jsonDecode(b.repo.localValue('syncBadFiles')!) as List;
    for (final j in list) {
      (j as Map)['r'] = reason.name;
    }
    b.repo.setLocalValue('syncBadFiles', jsonEncode(list));
    final book = jsonDecode(b.repo.localValue('syncBlocked')!) as Map;
    for (final e in book.values) {
      (e as Map)['r'] = reason.name;
    }
    b.repo.setLocalValue('syncBlocked', jsonEncode(book));
  }

  for (final reason in [SyncProblemReason.unknownVersion, SyncProblemReason.clockDrift, SyncProblemReason.applyFailed]) {
    test('RF3: a file quarantined as ${reason.name} is listed as not skippable and cannot be skipped', () async {
      final (_, b) = await blockedPair();
      expect(blockedFiles(b.repo).single.skippable, isTrue, reason: 'precondition: a damaged file');
      requarantine(b, reason);
      final blocked = blockedFiles(b.repo).single;
      expect((blocked.reason, blocked.skippable), (reason, false));
      expect(() => skipBlockedFile(b.repo, blocked.device, blocked.file), throwsArgumentError);
      expect(b.repo.localValue('syncSkipped'), isNull, reason: 'nothing stored');
      expect(blockedFiles(b.repo), hasLength(1));
    });
  }

  test('RF3: the engine never honours a skip of a file now quarantined for a reason that waits', () async {
    final (a, b) = await blockedPair();
    final blocked = blockedFiles(b.repo).single;
    skipBlockedFile(b.repo, blocked.device, blocked.file);
    // The skip of the damaged bytes is stored; the same bytes are then refused as a newer format (another build).
    final skipped = b.repo.localValue('syncSkipped');
    expect(skipped, isNotNull);
    final bad = jsonDecode(b.repo.localValue('syncBadFiles')!) as List;
    for (final j in bad) {
      (j as Map)['r'] = SyncProblemReason.unknownVersion.name;
    }
    b.repo.setLocalValue('syncBadFiles', jsonEncode(bad));
    final r = await b.sync();
    expect(r.caughtUp, isFalse);
    expect(r.waiting.single.seq, 2, reason: 'still waiting for the update, not skipped');
    expect(b.repo.syncCursors()[a.id], 1);
  });

  test('RF3: a skipped damaged file stays skipped over later runs', () async {
    final (a, b) = await blockedPair();
    final blocked = blockedFiles(b.repo).single;
    expect(blocked.reason, SyncProblemReason.corrupt);
    skipBlockedFile(b.repo, blocked.device, blocked.file);
    for (var i = 0; i < 3; i++) {
      sim.tick(const Duration(days: 2));
      final r = await b.sync();
      expect(r.caughtUp, isTrue, reason: 'run $i');
      expect(r.problems, isEmpty, reason: 'run $i');
      expect(blockedFiles(b.repo), isEmpty);
    }
    expect(b.repo.localValue('syncBadFiles'), isNull, reason: 'no longer quarantined');
    expect((jsonDecode(b.repo.localValue('syncSkipped')!) as Map).keys, ['${blocked.device}/2']);
    expect(b.repo.syncCursors()[a.id], 3);
  });
}
