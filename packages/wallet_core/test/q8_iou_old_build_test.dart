// Q8 technical item: a schema-16 build meets the record kinds schema 17 added (`iou`, `iou_part`), in both directions.
//
// The old device is the committed schema-16 release database (test/fixtures/old_builds/schema16_plain.db). This code
// cannot run the old build itself, so it is simulated as close to the wire as possible: while "old", the device's meta
// says schema 16 and its sync runs through [_Schema16Reader], which hands it every relay file with the `iou` / `iou_part`
// ops renamed to entity names this build does not know either. So the real `_apply` path for an unknown entity (the one
// the schema-16 build ran: `entitySchema[op.entity] == null` → nothing stored, no clock) handles them, inside the real
// files, with the real cursors. The snapshots it writes are named `s16-…` as a schema-16 build names them. The upgrade is
// the real one: reopening the file runs `_migrate` (16 → 17), which clears the cursors so the skipped ops replay.
// All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));
final _fixtures = Directory('test/fixtures/old_builds');

/// What a schema-16 build sees of the relay: the schema-17 record kinds are names it does not know.
const _unknown = {'iou': 'iou~v17', 'iou_part': 'iou_part~v17'};

class _Schema16Reader implements SyncTransport {
  final SyncTransport inner;
  final VaultKey key;
  int renamed = 0;
  _Schema16Reader(this.inner, this.key);

  /// The file with the schema-17 ops renamed, sealed again for the same place; untouched (same bytes, same hash) when it
  /// holds none.
  Future<List<int>> _rewrite(List<int> bytes, List<int> aad) async {
    final j = jsonDecode(utf8.decode(await unseal(bytes, key, aad: aad)));
    final ops = (j is Map ? j['ops'] : j) as List;
    var n = 0;
    final out = <Map<String, Object?>>[];
    for (final o in ops.cast<Map<String, Object?>>()) {
      final e = _unknown[o['e']];
      if (e != null) n++;
      out.add(e == null ? o : {...o, 'e': e});
    }
    if (n == 0) return bytes;
    renamed += n;
    return seal(utf8.encode(jsonEncode(j is Map ? {...j, 'ops': out} : out)), key, aad: aad);
  }

  @override
  Future<List<int>> get(String device, int seq) async => _rewrite(await inner.get(device, seq), aadSyncFile(device, seq));
  @override
  Future<List<int>> getSnapshot(String id) async => _rewrite(await inner.getSnapshot(id), aadSnapshot(id));
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) async {
    final old = id.replaceFirst(RegExp(r'^s\d+-'), 's16-');
    final clear = await unseal(bytes, key, aad: aadSnapshot(id));
    return inner.putSnapshot(old, covers, await seal(clear, key, aad: aadSnapshot(old)));
  }

  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) => inner.put(device, seq, bytes);
  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
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
  var now = DateTime.utc(2026, 1, 25, 9).millisecondsSinceEpoch;
  final devices = <Device>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-q8-old-');
    key = VaultKey.generate();
    net = Net();
    now = DateTime.utc(2026, 1, 25, 9).millisecondsSinceEpoch;
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  Device fresh(String name) {
    final d = Device(name, null, key, () => now, net: net);
    devices.add(d);
    return d;
  }

  /// The schema-16 release database as an old install: opened (which stamps 17), then set back to 16, as the old build
  /// keeps it.
  Device oldInstall() {
    final path = '${tmp.path}/old.db';
    File('${_fixtures.path}/schema16_plain.db').copySync(path);
    final d = Device('old', tmp, key, () => now, dbPath: path, net: net);
    devices.add(d);
    d.repo.db.execute("UPDATE meta SET value = '16' WHERE key = 'schema'");
    return d;
  }

  late _Schema16Reader reader;
  Future<SyncReport> oldRun(Device d) {
    reader = _Schema16Reader(d.relay, key);
    return SyncEngine(reader, key).run(d.repo);
  }

  int count(WalletRepo r, String sql) => r.db.select(sql).first['n'] as int;
  int iouRows(WalletRepo r) => count(r, 'SELECT (SELECT COUNT(*) FROM ious) + (SELECT COUNT(*) FROM iou_parts) AS n');
  int iouClocks(WalletRepo r) => count(r, "SELECT COUNT(*) AS n FROM clocks WHERE entity IN ('iou', 'iou_part') OR entity LIKE 'iou%~v17'");
  Map<String, int> cursors(WalletRepo r) =>
      {for (final x in r.db.select('SELECT device, seq FROM sync_cursor')) x['device'] as String: x['seq'] as int};
  int spent(WalletRepo r) {
    final cz = r.categorizer();
    return monthSummary(cz.expandAll(r.transactions()), '2026-01', currency: 'EUR').out;
  }

  List<(String, int, int)> ious(WalletRepo r) => [for (final v in r.ious()) (v.iou.id, v.iou.amount, v.outstanding)];

  test('fixture: the schema-16 release database opens and syncs', () async {
    final old = oldInstall();
    expect((jsonDecode(File('${_fixtures.path}/schema16.json').readAsStringSync()) as Map)['schema'], 16);
    final r = await oldRun(old);
    expect(r.problems, isEmpty);
    expect(old.repo.transactions(), isNotEmpty);
  }, timeout: _t);

  test(
      'new → old: the schema-16 device skips iou / iou_part ops without error, moves its cursor on and applies the rest of the '
      'file; after the upgrade the skipped ops replay and the IOUs appear', () async {
    final old = oldInstall();
    final a = fresh('a');
    await oldRun(old);
    await a.run();
    final row = a.repo
        .transactions()
        .firstWhere((t) => t.amount <= -1000 && !t.manual && a.repo.categorizer().categorize(t).kind == BudgetKind.flex);
    final before = spent(a.repo);
    expect(spent(old.repo), before);

    // One file from the new build: two IOUs, a repayment, a linked payment, and a wish (a kind the old build knows).
    final lent = a.repo.addIou(
        person: 'Ana', direction: IouDirection.lent, amount: -row.amount, currency: 'EUR', date: row.date, note: 'synthetic', tx: row.id);
    a.repo.addIouPart(lent, amount: 100, date: '2026-01-24');
    a.repo.addIou(person: 'Bo', direction: IouDirection.borrowed, amount: 2000, currency: 'EUR', date: '2026-01-02');
    a.repo.addWish('Synthetic lamp', 3000);
    expect(spent(a.repo), before + row.amount, reason: 'the new build leaves the linked payment out');
    await a.run();

    final r = await oldRun(old);
    expect(reader.renamed, greaterThanOrEqualTo(3), reason: 'the file held the schema-17 ops');
    expect(r.problems, isEmpty, reason: 'unknown record kinds are no problem');
    expect(r.caughtUp, isTrue);
    expect(iouRows(old.repo), 0);
    expect(iouClocks(old.repo), 0, reason: 'nothing stored, no clock: a replay applies them later');
    expect(cursors(old.repo)[a.repo.deviceId], greaterThan(0), reason: 'the cursor moved past the file');
    expect(old.repo.wishlist().map((w) => w.name), contains('Synthetic lamp'), reason: "the file's other ops applied");
    expect(spent(old.repo), before, reason: 'the old build still counts the payment (it cannot know the link)');
    final again = await oldRun(old);
    expect(again.problems, isEmpty, reason: 'a second run is quiet too');
    expect(iouRows(old.repo), 0);

    // The upgrade: the real migration (16 → 17) clears the cursors; the next run replays and the IOUs appear.
    old.reopen();
    expect(old.repo.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
    expect(cursors(old.repo), isEmpty);
    final up = await old.run();
    expect(up.problems, isEmpty);
    expect(ious(old.repo), ious(a.repo));
    expect(old.repo.iouLinkedTx(), {row.id});
    expect(spent(old.repo), spent(a.repo));
    await a.run();
    expect(dump(old.repo), dump(a.repo));
  }, timeout: _t);

  test(
      'old → new: what the schema-16 device writes meets the IOUs without harm; a device joining later and the upgraded one '
      'end the same', () async {
    final old = oldInstall();
    final a = fresh('a');
    // The old build adds a cash payment; the new one links it as money lent.
    final cash = old.repo.addTransaction(date: '2026-01-23', amount: 3000, category: 'To people', note: 'synthetic');
    await oldRun(old);
    await a.run();
    final lent = a.repo.addIou(person: 'Ana', direction: IouDirection.lent, amount: 3000, currency: 'EUR', date: '2026-01-23', tx: cash);
    final part = a.repo.addIouPart(lent, amount: 1000, date: '2026-01-24');
    await a.run();
    expect((await oldRun(old)).problems, isEmpty);

    // The old build keeps writing: it edits the linked payment's category, adds a goal, deletes another row.
    old.repo.setCategory(cash, 'Shopping');
    final other = old.repo.transactions().firstWhere((t) => t.id != cash && t.amount < 0);
    old.repo.deleteTransaction(other.id);
    old.repo.saveGoal(name: 'Synthetic trip', target: 50000, saved: 0, monthly: 1000);
    expect((await oldRun(old)).problems, isEmpty);
    final r = await a.run();
    expect(r.problems, isEmpty);
    expect(a.repo.transaction(cash)!.category, 'Shopping', reason: "the old device's edit applies");
    expect(ious(a.repo), [(lent, 3000, 2000)], reason: 'the IOU and its repayment are untouched');
    expect(a.repo.iouLinkedTx(), {cash});
    final cz = a.repo.categorizer();
    final row = cz.categorize(a.repo.transaction(cash)!);
    expect((row.category, row.kind), ('Shopping', BudgetKind.transfer), reason: 'keeps the main tag, counts as neither');

    // A new device joining now gets everything (it reads the files, not an older-schema snapshot).
    final c = fresh('c');
    for (var i = 0; i < 2; i++) {
      await c.run();
      await a.run();
    }
    expect(ious(c.repo), ious(a.repo));
    expect(spent(c.repo), spent(a.repo));

    // The old device upgrades: the same IOUs, link and totals.
    old.reopen();
    await old.run();
    expect(ious(old.repo), ious(a.repo));
    expect(old.repo.ious().single.parts.single.id, part);
    expect(spent(old.repo), spent(a.repo));
    for (var i = 0; i < 2; i++) {
      for (final d in [a, c, old]) {
        d.deliver(net, Random(i));
        await d.run();
      }
    }
    expect(dump(old.repo), dump(a.repo));
    expect(dump(c.repo), dump(a.repo));
  }, timeout: _t);

  test('the skip itself: an op of a record kind this build does not know stores nothing, records no clock and fails nothing', () {
    final r = WalletRepo.inMemory(now: () => now);
    addTearDown(r.close);
    final applied = r.applyRemote([
      Op('iou~v99', 'o1', {'person': 'x', 'amount': 5}, Hlc(now, 0, 'peer').toString()),
      Op('wish', 'w1', {'name': 'Synthetic', 'price': 100, 'added': now, 'status': 'waiting', 'deleted': 0},
          Hlc(now, 1, 'peer').toString()),
    ]);
    expect(applied, 1);
    expect(count(r, "SELECT COUNT(*) AS n FROM clocks WHERE entity = 'iou~v99'"), 0);
    expect(r.wishlist().single.name, 'Synthetic');
  });
}
