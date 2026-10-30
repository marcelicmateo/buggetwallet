// HP-T1: engine invariants that survived mutation testing of sync_engine.dart: the stream list after a "behind" move
// and the snapshot id form. All data SYNTHETIC.
import 'dart:convert';

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
}
