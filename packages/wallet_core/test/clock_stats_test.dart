// WalletRepo.clockStats: field-clock count and newest clock (not a change mark; see dataVersion). All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

void main() {
  final t0 = DateTime.utc(2026, 3, 10, 12).millisecondsSinceEpoch;

  ({int count, String? maxHlc}) fromTable(WalletRepo r) {
    final hlcs = [for (final row in r.db.select('SELECT hlc FROM clocks')) row['hlc'] as String]..sort();
    return (count: hlcs.length, maxHlc: hlcs.isEmpty ? null : hlcs.last);
  }

  test('an empty wallet: no clocks', () {
    final r = WalletRepo.inMemory(now: () => t0);
    addTearDown(r.close);
    expect(r.clockStats(), fromTable(r));
    expect(r.clockStats().maxHlc, isNull);
  });

  test('count and newest clock follow data writes, not sync bookkeeping', () {
    var now = t0;
    final r = WalletRepo.inMemory(now: () => now);
    addTearDown(r.close);
    final empty = r.clockStats();
    r.importBatch(january);
    final imported = r.clockStats();
    expect(imported, fromTable(r));
    expect(imported.count, greaterThan(empty.count));
    expect(imported.maxHlc, isNotNull);

    r.setSyncCursor('peer-device', 3);
    r.recordSyncFile('peer-device', 3, 7);
    r.setLocalValue('syncTestKey', 'x');
    expect(r.clockStats(), imported, reason: 'bookkeeping writes no field clock');

    now += 60000;
    r.setCategory(r.transactions().first.id, 'Groceries');
    final edited = r.clockStats();
    expect(edited, fromTable(r));
    expect(edited.maxHlc!.compareTo(imported.maxHlc!), greaterThan(0), reason: 'an edit carries the newest clock');
  });

  test('two devices: the peer that applies the files ends with the same stats', () async {
    final now = t0;
    Net();
    final key = VaultKey.generate();
    final a = Device('a', null, key, () => now), b = Device('b', null, key, () => now);
    addTearDown(a.close);
    addTearDown(b.close);
    a.repo.importBatch(january);
    final before = b.repo.clockStats();
    await a.run();
    await b.run();
    expect(b.repo.clockStats(), isNot(before));
    await a.run();
    expect(b.repo.clockStats(), a.repo.clockStats());
    expect(b.repo.clockStats(), fromTable(b.repo));
  });
}
