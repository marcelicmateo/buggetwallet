// When a device uses a relay snapshot (stage R review M2, L5): the unblock path only for a file refused for good
// (quarantined) and only with a snapshot of this schema or newer; a snapshot that cannot be fetched or refuses to apply
// is remembered device-locally and not downloaded again until the relay names another one (fetch failures: after an
// hour). All data is SYNTHETIC.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/engine_spec_sim.dart';

void main() {
  late Sim sim;
  setUp(() => sim = Sim());
  tearDown(() => sim.closeAll());

  int snapGets() => sim.transport.calls['getSnapshot'] ?? 0;
  Future<List<int>> sealed(WalletRepo r, String id) async => seal(backupPayload(r.snapshotOps()), sim.key, aad: aadSnapshot(id));

  /// A uploads two files; B applies the first one.
  Future<(Dev, Dev)> twoFiles() async {
    final a = sim.device(), b = sim.device();
    a.repo.updateSettings({'rent': 1});
    await a.sync();
    sim.tick();
    expect((await b.sync()).caughtUp, isTrue);
    a.repo.updateSettings({'rent': 2});
    await a.sync();
    sim.tick();
    return (a, b);
  }

  group('unblock (M2)', () {
    test('a file that merely could not be fetched does not pull the snapshot', () async {
      final (a, b) = await twoFiles();
      await sim.transport
          .putSnapshot('s${WalletRepo.schemaVersion}-0-aa', {a.id: 2}, await sealed(a.repo, 's${WalletRepo.schemaVersion}-0-aa'));
      sim.transport.failGet(a.id, 2);
      final r = await b.sync();
      expect(snapGets(), 0, reason: 'one network blip is not worth a full snapshot download');
      expect(r.caughtUp, isFalse);
      expect(r.waiting.single.reason, isNull);
      expect(b.repo.syncCursors()[a.id], 1);
      final again = await b.sync();
      expect(again.caughtUp, isTrue);
      expect(b.repo.settings().rent, 2);
      expect(snapGets(), 0);
    });

    test('a quarantined file is not unblocked by a snapshot of an older schema', () async {
      final (a, b) = await twoFiles();
      await sim.transport
          .putSnapshot('s${WalletRepo.schemaVersion - 1}-0-aa', {a.id: 2}, await sealed(a.repo, 's${WalletRepo.schemaVersion - 1}-0-aa'));
      sim.transport.corrupt(a.id, 2);
      final r = await b.sync();
      expect(snapGets(), 0);
      expect(r.waiting.single.reason, SyncProblemReason.corrupt);
      expect(b.repo.syncCursors()[a.id], 1, reason: 'cursors are not raised by a snapshot that lacks fields');
      expect(b.repo.settings().rent, 1);
    });

    test('a quarantined file a current snapshot covers is still unblocked by it', () async {
      final (a, b) = await twoFiles();
      await sim.transport
          .putSnapshot('s${WalletRepo.schemaVersion}-0-aa', {a.id: 2}, await sealed(a.repo, 's${WalletRepo.schemaVersion}-0-aa'));
      sim.transport.corrupt(a.id, 2);
      final r = await b.sync();
      expect(snapGets(), 1);
      expect(r.caughtUp, isTrue);
      expect(b.repo.settings().rent, 2);
    });
  });

  group('snapshots not used are remembered (L5)', () {
    /// A uploads two files, then a snapshot covering them is stored with [bytes]; with no other device the relay prunes
    /// both files, so a new device needs that snapshot.
    Future<Dev> pruned(String id, Future<List<int>> Function(Dev a) bytes) async {
      final a = sim.device();
      a.repo.updateSettings({'rent': 1});
      await a.sync();
      a.repo.updateSettings({'rent': 2});
      await a.sync();
      await sim.transport.putSnapshot(id, {a.id: 2}, await bytes(a));
      expect((await sim.transport.state()).devices[a.id]!.first, 3, reason: 'both files pruned');
      return a;
    }

    test('a refused snapshot is downloaded once, reported, and skipped until another id appears', () async {
      final other = VaultKey.generate();
      final a = await pruned('s${WalletRepo.schemaVersion}-0-aa',
          (a) => seal(backupPayload(a.repo.snapshotOps()), other, aad: aadSnapshot('s${WalletRepo.schemaVersion}-0-aa')));
      final c = sim.device();
      final r1 = await c.sync();
      expect(snapGets(), 1);
      expect(r1.caughtUp, isFalse);
      final p1 = r1.problems.singleWhere((p) => p.snapshot);
      expect((p1.reason, p1.isNew, p1.device), (SyncProblemReason.otherKey, true, ''));
      expect(r1.waiting.single.seq, 1);

      sim.tick();
      final r2 = await c.sync();
      expect(snapGets(), 1, reason: 'not downloaded again');
      final p2 = r2.problems.singleWhere((p) => p.snapshot);
      expect((p2.reason, p2.isNew), (SyncProblemReason.otherKey, false));

      // Another device writes a good snapshot: a new id, fetched and applied.
      sim.tick();
      await sim.transport
          .putSnapshot('s${WalletRepo.schemaVersion}-1-bb', {a.id: 2}, await sealed(a.repo, 's${WalletRepo.schemaVersion}-1-bb'));
      final r3 = await c.sync();
      expect(snapGets(), 2);
      expect(r3.caughtUp, isTrue);
      expect(r3.problems, isEmpty);
      expect(c.repo.settings().rent, 2);
    });

    test('a snapshot that could not be fetched is tried again after an hour, not before', () async {
      const id = 's${WalletRepo.schemaVersion}-0-aa';
      await pruned(id, (a) => sealed(a.repo, id));
      sim.transport.failGetSnapshot(id);
      final c = sim.device();
      final r1 = await c.sync();
      expect(snapGets(), 1);
      expect(r1.problems.singleWhere((p) => p.snapshot).reason, SyncProblemReason.unreadable);
      sim.tick(const Duration(minutes: 30));
      final r2 = await c.sync();
      expect(snapGets(), 1);
      expect(r2.problems.singleWhere((p) => p.snapshot).isNew, isFalse);
      sim.tick(const Duration(minutes: 31));
      final r3 = await c.sync();
      expect(snapGets(), 2);
      expect(r3.caughtUp, isTrue);
      expect(c.repo.settings().rent, 2);
    });

    test('a snapshot of a newer format is tried again once after the app version changes', () async {
      const id = 's${WalletRepo.schemaVersion}-0-aa';
      final a = sim.device();
      a.repo.updateSettings({'rent': 1});
      await a.sync();
      await sim.transport.putSnapshot(id, {a.id: 1}, await seal(utf8.encode('{"v":99,"ops":[]}'), sim.key, aad: aadSnapshot(id)));
      final c = sim.device();
      expect((await c.sync()).problems.singleWhere((p) => p.snapshot).reason, SyncProblemReason.unknownVersion);
      await c.sync();
      expect(snapGets(), 1);
      final upgraded = SyncEngine(sim.transport, sim.key, appVersion: '2.0.0', now: () => sim.clock.t);
      await upgraded.run(c.repo);
      expect(snapGets(), 2);
      await upgraded.run(c.repo);
      expect(snapGets(), 2);
    });
  });
}
