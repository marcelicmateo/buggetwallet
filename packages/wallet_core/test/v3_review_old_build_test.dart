// V3: a schema-17 build meets the `review` record kind schema 18 added. Simulated as the Q8 test does
// (q8_iou_old_build_test.dart): while "old", the device's meta says schema 17 and its sync reads every relay file with
// the `review` ops renamed to an entity name this build does not know either, so the real unknown-entity `_apply` path
// skips them (nothing stored, no clock). The old build still counts its streak in the legacy settings, which sync to the
// new device as its base. The upgrade is the real one: reopening runs `_migrate` (17 → 18), which clears the cursors so
// the skipped ops replay. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));

/// What a schema-17 build sees of the relay: `review` is a name it does not know.
class _Schema17Reader implements SyncTransport {
  final SyncTransport inner;
  final VaultKey key;
  int renamed = 0;
  _Schema17Reader(this.inner, this.key);

  Future<List<int>> _rewrite(List<int> bytes, List<int> aad) async {
    final j = jsonDecode(utf8.decode(await unseal(bytes, key, aad: aad)));
    final ops = (j is Map ? j['ops'] : j) as List;
    final out = [
      for (final o in ops.cast<Map<String, Object?>>())
        if (o['e'] == 'review') {...o, 'e': 'review~v18'} else o
    ];
    final n = out.where((o) => o['e'] == 'review~v18').length;
    if (n == 0) return bytes;
    renamed += n;
    return seal(utf8.encode(jsonEncode(j is Map ? {...j, 'ops': out} : out)), key, aad: aad);
  }

  @override
  Future<List<int>> get(String device, int seq) async => _rewrite(await inner.get(device, seq), aadSyncFile(device, seq));
  @override
  Future<List<int>> getSnapshot(String id) async => _rewrite(await inner.getSnapshot(id), aadSnapshot(id));
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) => inner.put(device, seq, bytes);
  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) => inner.putSnapshot(id, covers, bytes);
  @override
  Future<void> putBlob(String hash, List<int> bytes) => inner.putBlob(hash, bytes);
  @override
  Future<List<int>?> getBlob(String hash) => inner.getBlob(hash);
  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) => inner.putSnapshotBlobs(id, hashes);
}

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = DateTime.utc(2026, 3, 1, 9).millisecondsSinceEpoch;
  final devices = <Device>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-v3-old-');
    key = VaultKey.generate();
    net = Net();
    now = DateTime.utc(2026, 3, 1, 9).millisecondsSinceEpoch;
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  int streak(WalletRepo r) => reviewStreak(r.reviewDates(), legacyLast: r.settings().lastReview, legacyStreak: r.settings().reviewStreak);
  int count(WalletRepo r, String sql) => r.db.select(sql).first['n'] as int;

  test('a schema-17 device skips review ops, its legacy streak is the new device\'s base, and after the upgrade the rows replay', () async {
    final neu = Device('new', null, key, () => now, net: net);
    devices.add(neu);
    final old = Device('old', tmp, key, () => now, dbPath: '${tmp.path}/old.db', net: net);
    devices.add(old);
    old.repo.db.execute("UPDATE meta SET value = '17' WHERE key = 'schema'");
    late _Schema17Reader reader;
    Future<SyncReport> oldRun() {
      reader = _Schema17Reader(old.relay, key);
      return SyncEngine(reader, key).run(old.repo);
    }

    // The old build counts its streak in the settings, as its markReviewDone did.
    old.repo.updateSettings({'lastReview': '2026-02-22', 'reviewStreak': 3});
    now += 1000;
    await oldRun();
    now += 1000;
    neu.repo.markReviewDone('2026-03-01');
    now += 1000;
    await neu.run();
    now += 1000;
    final report = await oldRun();
    expect(report.problems, isEmpty, reason: 'an unknown record kind is no problem');
    expect(reader.renamed, 1);
    expect(count(old.repo, 'SELECT COUNT(*) AS n FROM reviews'), 0);
    expect(count(old.repo, "SELECT COUNT(*) AS n FROM clocks WHERE entity LIKE 'review%'"), 0, reason: 'no clock: it replays later');
    expect(streak(neu.repo), 4, reason: 'the row joins the legacy base the old device synced');

    // The upgrade: 17 → 18 clears the cursors, the skipped op replays.
    old.reopen();
    expect(old.repo.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '18');
    now += 1000;
    await old.run();
    expect(old.repo.reviewDates(), ['2026-03-01']);
    old.repo.markReviewDone('2026-03-08');
    now += 1000;
    await old.run();
    now += 1000;
    await neu.run();
    for (final d in [old, neu]) {
      expect(d.repo.reviewDates(), ['2026-03-01', '2026-03-08'], reason: d.name);
      expect(streak(d.repo), 5, reason: d.name);
      expect((d.repo.settings().lastReview, d.repo.settings().reviewStreak), ('2026-02-22', 3), reason: 'legacy never rewritten');
    }
    expect(dump(old.repo, clocks: false), dump(neu.repo, clocks: false));
  }, timeout: _t);
}
