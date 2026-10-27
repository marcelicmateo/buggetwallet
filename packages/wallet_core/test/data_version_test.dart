// WalletRepo.dataVersion: goes up on every committed data write (local or applied from a peer), never on bookkeeping.
// Repro of the clock-stats change-mark gap. All data SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

final _t0 = DateTime.utc(2026, 3, 10, 12).millisecondsSinceEpoch;

/// A setting op from a peer at [millis] (an exact HLC, so tests choose the order).
Op _setting(String key, String value, int millis) => Op('setting', key, {'value': value, 'deleted': 0}, Hlc(millis, 0, 'peer').toString());

String? _value(WalletRepo r, String key) => r.db.select('SELECT value FROM settings WHERE id = ?', [key]).firstOrNull?['value'] as String?;

void main() {
  test('repro: a peer op with an older clock than the newest replaces a field: clockStats stays, dataVersion moves', () {
    final r = WalletRepo.inMemory(now: () => _t0);
    addTearDown(r.close);
    r.applyRemote([_setting('alpha', '"one"', _t0 - 3000), _setting('beta', '"x"', _t0 - 1000)]);
    final stats = r.clockStats(), version = r.dataVersion;
    // Newer than alpha's clock, older than beta's (the newest overall): it wins for alpha.
    expect(r.applyRemote([_setting('alpha', '"two"', _t0 - 2000)]), 1);
    expect(_value(r, 'alpha'), '"two"', reason: 'the data changed');
    expect(r.clockStats(), stats, reason: 'count and newest clock cannot see this change');
    expect(r.dataVersion, greaterThan(version));
  });

  test('local writes move it; sync bookkeeping does not', () {
    var now = _t0;
    final r = WalletRepo.inMemory(now: () => now);
    addTearDown(r.close);
    var v = r.dataVersion;
    r.importBatch(january);
    expect(r.dataVersion, greaterThan(v));
    v = r.dataVersion;

    r.setSyncCursor('peer-device', 3);
    r.recordSyncFile('peer-device', 3, 7);
    r.setLocalValue('dataVersionTestKey', 'x');
    r.markExported(r.pendingOps().last.$1);
    expect(r.dataVersion, v, reason: 'cursors, file records, local values and the outbox are bookkeeping');

    now += 60000;
    r.setCategory(r.transactions().first.id, 'Groceries');
    expect(r.dataVersion, greaterThan(v));
  });

  test('applied ops move it once per apply that changed something; a re-apply or a dry run does not', () {
    final r = WalletRepo.inMemory(now: () => _t0);
    addTearDown(r.close);
    final ops = [_setting('alpha', '"one"', _t0 - 3000), _setting('beta', '"x"', _t0 - 1000)];
    final v0 = r.dataVersion;
    expect(r.applyRemote(ops), 2);
    final v1 = r.dataVersion;
    expect(v1, greaterThan(v0));
    expect(r.applyRemote(ops), 0);
    expect(r.applyRemote([_setting('alpha', '"older"', _t0 - 9000)]), 0);
    expect(r.dataVersion, v1, reason: 'nothing written');
    final counts = r.applyRemoteByEntity([_setting('alpha', '"dry"', _t0)], dryRun: true);
    expect(counts, {'setting': 1});
    expect(r.dataVersion, v1, reason: 'a dry run is rolled back');
    expect(_value(r, 'alpha'), '"one"');
  });

  group('sync', () {
    late MemoryTransport relay;
    late VaultKey key;
    late WalletRepo repo;

    setUp(() {
      relay = MemoryTransport();
      key = VaultKey.generate();
      repo = WalletRepo.inMemory(now: () => _t0);
    });
    tearDown(() => repo.close());

    Future<Uint8List> sealed(List<Op> ops, String device, int seq, [VaultKey? k]) =>
        seal(utf8.encode(jsonEncode([for (final o in ops) o.toJson()])), k ?? key, aad: aadSyncFile(device, seq));

    test('a peer file applied by the engine moves it; a refused file does not', () async {
      await relay.put('p1', 1, await sealed([_setting('alpha', '"one"', _t0 - 3000)], 'p1', 1));
      final v0 = repo.dataVersion;
      final first = await SyncEngine(relay, key).run(repo);
      expect(first.received, 1);
      final v1 = repo.dataVersion;
      expect(v1, greaterThan(v0));

      // Sealed with another key: refused (quarantined), nothing applied.
      await relay.put('p1', 2, await sealed([_setting('alpha', '"two"', _t0 - 2000)], 'p1', 2, VaultKey.generate()));
      final second = await SyncEngine(relay, key).run(repo);
      expect(second.problems.map((p) => p.reason), contains(SyncProblemReason.badKey));
      expect(_value(repo, 'alpha'), '"one"');
      expect(repo.dataVersion, v1);

      // A run with nothing new writes no data either.
      await SyncEngine(relay, key).run(repo);
      expect(repo.dataVersion, v1);
    });
  });
}
