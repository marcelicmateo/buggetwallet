// HP-T1: engine invariants that survived mutation testing of sync_engine.dart: the stream list after a "behind" move
// and the snapshot id form. All data SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/engine_spec_sim.dart';
import '../../wallet_core/test/support/sim.dart';

void main() {
  late VaultKey key;
  late Net net;
  var now = 1767225600000;
  final devices = <Device>[];

  setUp(() {
    key = VaultKey.generate();
    now = 1767225600000;
    net = Net();
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
  });

  Device device(String name) {
    final d = Device(name, null, key, () => now, net: net);
    devices.add(d);
    return d;
  }

  Future<void> rounds(List<Device> ds, [int n = 2]) async {
    for (var i = 0; i < n; i++) {
      for (final d in ds) {
        now += 10;
        await d.run();
      }
    }
  }

  List<String> listOf(Device d, String k) {
    final raw = d.repo.localValue(k);
    return raw == null ? const [] : [for (final e in jsonDecode(raw) as List) e as String];
  }

  test('a relay restored from an older copy: the left stream is listed once as written and is not foreign', () async {
    final a = device('a'), b = device('b');
    a.repo.updateSettings({'salary': 1});
    await rounds([a, b]);
    final copy = net.relay.copy();
    now += 1000;
    a.repo.updateSettings({'rent': 2});
    await rounds([a, b]);
    net.relay.restore(copy);
    // A database from before Stage H has no list of streams written: the move lists the left one.
    a.repo.setLocalValue(SyncEngine.streamsKey, null);
    now += 1000;
    a.repo.updateSettings({'loan': 3});
    await rounds([a, b], 4);
    final id = a.repo.deviceId;
    final current = a.repo.localValue(SyncEngine.streamKey)!;
    expect(current, isNot(id), reason: 'moved to a fresh stream');
    expect(SyncEngine.streamBase(current), id);
    final written = listOf(a, SyncEngine.streamsKey);
    expect(written.where((s) => s == id), hasLength(1), reason: 'the old stream is listed exactly once (it is still acked as)');
    expect(written.where((s) => s == current), hasLength(1));
    expect(listOf(a, SyncEngine.foreignKey), isEmpty, reason: 'a restored relay is not another install writing the stream');
  });

  test('a snapshot id is s<schema>-<ms of the write>-<8 hex>', () async {
    final sim = Sim();
    addTearDown(sim.closeAll);
    final a = sim.device();
    a.repo.updateSettings({'salary': 1});
    await a.sync();
    sim.tick(const Duration(days: 8));
    a.repo.updateSettings({'rent': 2});
    await a.sync();
    await a.sync();
    final id = (await sim.transport.state()).snapshot?.id;
    expect(id, isNotNull, reason: 'a week-old wallet without a snapshot writes one');
    expect(id, matches(RegExp('^s${WalletRepo.schemaVersion}-${sim.clock.ms}-[0-9a-f]{8}\$')));
  });

  test('a clockDrift snapshot is fetched again once the wall clock reaches newest - 1 h (retryAt is remembered)', () async {
    final ahead = device('ahead');
    ahead.repo.updateSettings({'salary': 7});
    await ahead.run();
    // A snapshot whose ops are 2 h ahead of the reader's wall clock.
    final writer = Device('w', null, key, () => now + 2 * 3600000, net: net);
    devices.add(writer);
    writer.repo.updateSettings({'salary': 7});
    const id = 's${WalletRepo.schemaVersion}-0-aa';
    await net.relay
        .putSnapshot(id, {ahead.repo.deviceId: 1}, await seal(backupPayload(writer.repo.snapshotOps()), key, aad: aadSnapshot(id)));
    final a = device('a');
    final first = await a.run();
    expect(first.problems.where((p) => p.snapshot).map((p) => p.reason), [SyncProblemReason.clockDrift]);
    now += 30 * 60000; // still more than an hour ahead
    expect((await a.run()).problems.where((p) => p.snapshot).map((p) => p.reason), [SyncProblemReason.clockDrift]);
    now += 40 * 60000; // newest clock - 1 h has passed
    final later = await a.run();
    expect(later.problems.where((p) => p.snapshot), isEmpty, reason: 'tried again, and applied');
    expect(a.repo.settings().salary, 7);
  });

  test('a known wallet with a bill file that cannot be PUT: one attempt per run, not a second retry', () async {
    final relay = _CountingRelay();
    final repo = WalletRepo.inMemory();
    addTearDown(repo.close);
    final engine = SyncEngine(relay, key);
    repo.updateSettings({'returnReminderDays': 3});
    await engine.run(repo);
    final r = Uint8List.fromList(List.generate(300, (i) => (i * 37 + 11) & 255));
    final ref = await BlobStore(repo, key).add(r, 'jpg');
    repo.importBill(
        const NormalizedBill(source: BillSource.pdf, externalId: 'jir:synthetic-x', date: '2026-02-25', total: 1000, payee: 'Test Shop'),
        file: ref);
    relay.failBlobs = true;
    final rep = await engine.run(repo);
    expect(rep.blobsWaiting, 1);
    expect(relay.blobPuts, 1);
  });

  group('snapshot start and covers (engine_spec_sim clock)', () {
    const day = Duration(days: 1);

    test('a snapshot covers 0 for a listed device that has no files (never a file it has not read)', () async {
      final sim = Sim();
      addTearDown(sim.closeAll);
      final a = sim.device(), b = sim.device();
      a.repo.updateSettings({'salary': 1});
      await sim.syncAll([a, b]);
      sim.tick(day * 8);
      a.repo.updateSettings({'rent': 2});
      await sim.syncAll([a, b]);
      final s = await sim.transport.state();
      expect(s.snapshot, isNotNull);
      for (final e in s.snapshot!.covers.entries) {
        final dev = s.devices[e.key];
        expect(e.value, lessThanOrEqualTo(dev?.last ?? 0), reason: 'covers never claim a file that does not exist: ${e.key}');
      }
    });

    test('a file right after the pruned ones is read as a file, not by starting from the snapshot', () async {
      final sim = Sim();
      addTearDown(sim.closeAll);
      final a = sim.device(), b = sim.device();
      a.repo.updateSettings({'salary': 1});
      await sim.syncAll([a, b]);
      for (var d = 0; d < 64; d += 8) {
        sim.tick(day * 8);
        a.repo.addTransaction(date: '2026-02-01', amount: 100 + d, category: 'Eating out');
        await sim.syncAll([a, b], rounds: 3);
      }
      var s = await sim.transport.state();
      final dev = s.devices[a.id]!;
      sim.tick(day * 8);
      a.repo.addTransaction(date: '2026-02-02', amount: 7, category: 'Eating out');
      await a.sync();
      await a.sync(); // the snapshot that, with the one before it, covers B's last file
      s = await sim.transport.state();
      expect(s.devices[a.id]!.first, dev.last + 1, reason: 'B read up to the pruned file; the new one is the first kept');
      final snapshotGets = sim.transport.calls['getSnapshot'] ?? 0;
      final r = await b.sync();
      expect(r.filesRead, 1, reason: 'just the one file');
      expect(sim.transport.calls['getSnapshot'] ?? 0, snapshotGets, reason: 'no snapshot downloaded: nothing B needs is pruned');
      expect(canon(b.repo), canon(a.repo));
    });
  });
}

class _CountingRelay extends MemoryTransport {
  bool failBlobs = false;
  int blobPuts = 0;
  @override
  Future<void> putBlob(String hash, List<int> bytes) {
    blobPuts++;
    if (failBlobs) throw const TransportException(TransportFailure.unreachable, 'down');
    return super.putBlob(hash, bytes);
  }
}
