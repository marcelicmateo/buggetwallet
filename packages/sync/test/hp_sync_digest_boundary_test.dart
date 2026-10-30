// HP-T1b: the repair-quiet boundary (V2): a second mismatch exactly 7 days after a repair is no longer "within 7 days",
// so it repairs again; one millisecond earlier it only raises devicesDisagree. All data SYNTHETIC.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/engine_spec_sim.dart';
import '../../wallet_core/test/support/synthetic.dart';

void main() {
  late Sim sim;
  setUp(() => sim = Sim());
  tearDown(() => sim.closeAll());

  Future<void> settle(List<Dev> ds) async {
    for (var i = 0; i < 6; i++) {
      for (final d in ds) {
        await d.sync();
        sim.tick(const Duration(seconds: 5));
      }
    }
  }

  void lose(Dev d, String key) {
    d.repo.db.execute("DELETE FROM settings WHERE id = '$key'");
    d.repo.db.execute("DELETE FROM clocks WHERE entity = 'setting' AND id = '$key'");
  }

  int? repairAt(Dev d) {
    final raw = d.repo.localValue('syncDigest');
    return raw == null ? null : (jsonDecode(raw) as Map)['at'] as int?;
  }

  Future<({bool repaired, bool disagree})> secondMismatch(int offsetMs) async {
    final a = sim.device(), b = sim.device();
    a.repo
      ..importBatch(january)
      ..updateSettings({'salary': 150000, 'rent': 50000});
    await settle([a, b]);
    sim.tick();
    a.repo.updateSettings({'loan': 30000, 'subs': 2000});
    await settle([a, b]);
    lose(b, 'loan');
    sim.tick();
    a.repo.updateSettings({'rent': 51000});
    await settle([a, b]);
    final (starter, other) = repairAt(a) != null ? (a, b) : (b, a);
    final at = repairAt(starter);
    expect(at, isNotNull, reason: 'one of them started the first repair');
    // The other loses a row and says so in a new digest; the starter reads it at exactly [at] + 7 days + offset.
    sim.tick(const Duration(days: 3));
    lose(other, 'subs');
    other.repo.updateSettings({'rent': 52000});
    await other.sync();
    sim.clock.t = DateTime.fromMillisecondsSinceEpoch(at! + const Duration(days: 7).inMilliseconds + offsetMs, isUtc: true);
    final r = await starter.sync();
    final book = jsonDecode(starter.repo.localValue('syncDigest')!) as Map;
    return (
      repaired: repairAt(starter) != at,
      disagree: r.problems.any((p) => p.reason == SyncProblemReason.devicesDisagree) || book['dis'] != null,
    );
  }

  test('exactly 7 days after the last repair a new mismatch repairs again', () async {
    final r = await secondMismatch(0);
    expect(r.repaired, isTrue);
    expect(r.disagree, isFalse);
  });

  test('one millisecond short of 7 days: no repair, devicesDisagree', () async {
    final r = await secondMismatch(-1);
    expect(r.repaired, isFalse);
    expect(r.disagree, isTrue);
  });
}
