// Uploads larger than one relay file (stage R review L6): the relay refuses files over 16 MiB, so a first connect or a
// big pending batch is split into several seqs, each sealed file at most `partBytes`; the outbox is marked exported
// only once every part is stored, and a run that stops half-way sends everything again. The limits are lowered
// through test hooks (MemoryTransport.maxFileBytes, SyncEngine.partBytes) so a few hundred rows need several parts.
// All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/engine_spec_sim.dart';
import 'support/synthetic.dart';

/// Records the size of every stored file per device (the relay may prune them later) and fails every PUT after the
/// first [okPuts] (a run that dies half-way through an upload).
class _Recorder implements SyncTransport {
  _Recorder(this.inner);
  final SyncTransport inner;
  int okPuts = 1 << 30;
  final Map<String, List<int>> sizes = {};
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) async {
    if (okPuts-- <= 0) throw const TransportException(TransportFailure.unreachable, 'gone');
    await inner.put(device, seq, bytes);
    (sizes[device] ??= []).add(bytes.length);
  }

  @override
  Future<List<int>> get(String device, int seq) => inner.get(device, seq);
  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) => inner.putSnapshot(id, covers, bytes);
  @override
  Future<List<int>> getSnapshot(String id) => inner.getSnapshot(id);
  @override
  Future<void> putBlob(String hash, List<int> bytes) => inner.putBlob(hash, bytes);
  @override
  Future<List<int>?> getBlob(String hash) => inner.getBlob(hash);
  @override
  Future<void> deleteBlob(String hash) => inner.deleteBlob(hash);
}

const part = 16 << 10, relayMax = 32 << 10;

/// [count] synthetic rows with random descriptions (so they do not compress away).
ImportBatch rows(int count, int seed) {
  final r = Random(seed);
  String word() => List.generate(20, (_) => r.nextInt(36).toRadixString(36)).join();
  return ImportBatch(source: 'pbz', transactions: [
    for (var i = 0; i < count; i++)
      n('2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}', -(100 + r.nextInt(90000)), 'POS plaćanje', 'SYN ${word()}'),
  ]);
}

void main() {
  late Sim sim;
  late _Recorder rec;
  setUp(() {
    sim = Sim();
    sim.transport.maxFileBytes = relayMax;
    rec = _Recorder(sim.transport);
  });
  tearDown(() => sim.closeAll());

  Dev device() {
    final repo = WalletRepo.inMemory(now: () => sim.clock.ms);
    final d = Dev(repo, SyncEngine(rec, sim.key, appVersion: '1.0.0', now: () => sim.clock.t, partBytes: part));
    sim.all.add(d);
    return d;
  }

  List<int> fileSizes(String device) => rec.sizes[device] ?? const [];

  test('the limit is real: one file over the relay limit is refused as full', () async {
    final big =
        Dev(WalletRepo.inMemory(now: () => sim.clock.ms), SyncEngine(sim.transport, sim.key, now: () => sim.clock.t, partBytes: 1 << 30));
    sim.all.add(big);
    big.repo.importBatch(rows(2000, 1));
    await expectLater(big.sync(), throwsA(isA<SyncException>()));
  });

  test('first connect of a big wallet: several files, each within the part size; a new device ends equal', () async {
    final a = device();
    a.repo.importBatch(rows(2000, 1));
    final ops = a.repo.snapshotOps().length;
    final r = await a.sync();
    expect(r.sent, ops);
    final sizes = fileSizes(a.id);
    expect(sizes.length, greaterThanOrEqualTo(3));
    expect(sizes.every((s) => s <= part), isTrue, reason: '$sizes');
    expect(a.repo.pendingOps(), isEmpty);
    expect(a.repo.localValue(SyncEngine.sentKey), '${sizes.length}');
    sim.tick();
    final b = device();
    expect((await b.sync()).caughtUp, isTrue);
    expect(canon(b.repo), canon(a.repo));
  });

  test('a big pending batch after the first connect is split the same way', () async {
    final a = device(), b = device();
    a.repo.updateSettings({'rent': 1});
    await a.sync();
    await b.sync();
    sim.tick();
    a.repo.importBatch(rows(2000, 2));
    final pending = a.repo.pendingOps().length;
    final r = await a.sync();
    expect(r.sent, pending);
    expect(fileSizes(a.id).length, greaterThanOrEqualTo(4));
    expect(a.repo.pendingOps(), isEmpty);
    sim.tick();
    expect((await b.sync()).caughtUp, isTrue);
    expect(canon(b.repo), canon(a.repo));
  });

  test('a run that dies half-way keeps the outbox; the next run sends everything again and peers converge', () async {
    rec.okPuts = 2;
    final a = device();
    a.repo.importBatch(rows(2000, 3));
    final before = a.repo.pendingOps().length;
    await expectLater(a.sync(), throwsA(isA<SyncException>()));
    expect(fileSizes(a.id), hasLength(2));
    expect(a.repo.pendingOps(), hasLength(before), reason: 'not marked exported');
    expect(a.repo.localValue(SyncEngine.sentKey), isNull, reason: 'still a first connect');
    rec.okPuts = 1 << 30;
    sim.tick();
    await a.sync();
    expect(a.repo.pendingOps(), isEmpty);
    expect(fileSizes(a.id).length, greaterThan(3));
    sim.tick();
    final b = device();
    expect((await b.sync()).caughtUp, isTrue);
    expect(canon(b.repo), canon(a.repo));
  });
}
