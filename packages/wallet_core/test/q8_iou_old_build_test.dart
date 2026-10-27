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

  /// Snapshot ids as the old build judges them: it is schema 16, this engine is newer, so a `s16-` id (its own schema)
  /// is shown under the engine's schema; newer ones stay as they are (newer than 16 either way).
  final _real = <String, String>{};
  RelaySnapshot? _shown(RelaySnapshot? s) {
    if (s == null) return null;
    final id = s.id.replaceFirst(RegExp(r'^s16-'), 's${WalletRepo.schemaVersion}-');
    _real[id] = s.id;
    return RelaySnapshot(id, s.covers);
  }

  @override
  Future<RelayState> state() async {
    final s = await inner.state();
    return RelayState(
        devices: s.devices,
        snapshot: _shown(s.snapshot),
        previous: _shown(s.previous),
        instance: s.instance,
        bytes: s.bytes,
        maxBytes: s.maxBytes,
        api: s.api);
  }

  @override
  Future<List<int>> getSnapshot(String id) async {
    final real = _real[id] ?? id;
    return _rewrite(await inner.getSnapshot(real), aadSnapshot(real));
  }

  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) async {
    final old = id.replaceFirst(RegExp(r'^s\d+-'), 's16-');
    final clear = await unseal(bytes, key, aad: aadSnapshot(id));
    return inner.putSnapshot(old, covers, await seal(clear, key, aad: aadSnapshot(old)));
  }

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

  group('the relay pruned the file holding the IOUs before the old device upgraded', () {
    // Wall clock of every device and of the relay (prune rule, lastSeen), moved on by hand.
    var t = DateTime.utc(2026, 1, 25, 9);
    late MemoryTransport relay;
    late WalletRepo phone, laptop;
    late String phonePath;
    setUp(() {
      t = DateTime.utc(2026, 1, 25, 9);
      relay = MemoryTransport(now: () => t);
      phonePath = '${tmp.path}/phone.db';
      File('${_fixtures.path}/schema16_plain.db').copySync(phonePath);
      phone = WalletRepo.open(phonePath, now: () => t.millisecondsSinceEpoch);
      phone.db.execute("UPDATE meta SET value = '16' WHERE key = 'schema'");
      laptop = WalletRepo.inMemory(now: () => t.millisecondsSinceEpoch);
    });
    tearDown(() {
      phone.close();
      laptop.close();
    });
    Future<SyncReport> oldPhone() => SyncEngine(_Schema16Reader(relay, key), key, now: () => t).run(phone);
    Future<SyncReport> run(WalletRepo r) => SyncEngine(relay, key, now: () => t).run(r);
    String? snapSchema(RelaySnapshot? s) => s?.id.split('-').first;

    /// The laptop's IOU file, skipped and acked by the old phone, then two old-schema snapshots from the phone (eight
    /// days apart: [SyncEngine.snapshotAge]); with [laptopBetween] the laptop syncs between them. Returns the IOU file's seq.
    Future<int> setUpPruned({required bool laptopBetween}) async {
      await oldPhone();
      await run(laptop);
      laptop.addIou(person: 'Ana', direction: IouDirection.lent, amount: 2000, currency: 'EUR', date: '2026-01-24');
      await run(laptop);
      final iouFile = (await relay.state()).devices[laptop.deviceId]!.last;
      await oldPhone();
      expect(iouRows(phone), 0);
      t = t.add(const Duration(days: 8));
      await oldPhone();
      expect(snapSchema((await relay.state()).snapshot), 's16');
      if (laptopBetween) {
        await run(laptop);
        expect(snapSchema((await relay.state()).snapshot), 's${WalletRepo.schemaVersion}',
            reason: 'a newer build replaces an older-schema newest snapshot with its own');
      }
      t = t.add(const Duration(days: 8));
      phone.addWish('Synthetic kettle', 2500); // the phone has news, so its aged snapshot rule writes again
      await oldPhone();
      final st = await relay.state();
      expect(snapSchema(st.snapshot), 's16');
      expect(st.devices[laptop.deviceId]!.first, greaterThan(iouFile), reason: 'the file with the IOU is pruned');
      return iouFile;
    }

    test('with a snapshot of the new schema still kept, the upgraded device starts from it (and the older one on top)', () async {
      await setUpPruned(laptopBetween: true);
      expect(snapSchema((await relay.state()).previous), 's${WalletRepo.schemaVersion}');
      phone.close();
      phone = WalletRepo.open(phonePath, now: () => t.millisecondsSinceEpoch);
      expect(cursors(phone), isEmpty, reason: 'the real migration cleared the cursors');
      final r = await run(phone);
      expect(r.problems, isEmpty);
      expect(ious(phone), ious(laptop));
      expect(phone.localValue(SyncEngine.wantCurrentKey), isNull);
      await run(laptop);
      await run(phone);
      expect(dump(phone, clocks: false), dump(laptop, clocks: false));
    }, timeout: _t);

    test(
        'with only older-schema snapshots left, the upgraded device holds its own snapshots back until the newer build '
        'writes one, then takes the IOUs from it', () async {
      await setUpPruned(laptopBetween: false);
      phone.close();
      phone = WalletRepo.open(phonePath, now: () => t.millisecondsSinceEpoch);
      await run(phone);
      expect(ious(phone), isEmpty, reason: 'nothing on the relay holds them yet');
      expect(phone.localValue(SyncEngine.wantCurrentKey), isNotNull);
      t = t.add(const Duration(days: 8));
      await run(phone);
      expect(snapSchema((await relay.state()).snapshot), 's16', reason: 'the phone writes no snapshot of its own meanwhile');
      await run(laptop);
      expect(snapSchema((await relay.state()).snapshot), 's${WalletRepo.schemaVersion}');
      await run(phone);
      expect(ious(phone), ious(laptop));
      expect(phone.localValue(SyncEngine.wantCurrentKey), isNull);
      await run(laptop);
      await run(phone);
      expect(dump(phone, clocks: false), dump(laptop, clocks: false));
    }, timeout: _t);

    Future<void> upgradePhone() async {
      phone.close();
      phone = WalletRepo.open(phonePath, now: () => t.millisecondsSinceEpoch);
      expect(cursors(phone), isEmpty);
    }

    test(
        'the IOU written after the newer build\'s snapshot: the upgraded device stops at that snapshot and reads the files '
        'after it (an older one on top would skip them); a leftover mark is cleared', () async {
      await oldPhone();
      laptop.addWish('Synthetic mug', 900);
      await run(laptop); // a file of its own before its snapshot
      t = t.add(const Duration(days: 8));
      await oldPhone(); // s16, aged
      await run(laptop); // replaces it with its own (newest is older-schema)
      expect(snapSchema((await relay.state()).snapshot), 's${WalletRepo.schemaVersion}');
      final covered = (await relay.state()).snapshot!.covers[laptop.deviceId]!;
      laptop.addIou(person: 'Ana', direction: IouDirection.lent, amount: 2000, currency: 'EUR', date: '2026-02-02');
      await run(laptop);
      final iouFile = (await relay.state()).devices[laptop.deviceId]!.last;
      expect(iouFile, greaterThan(covered));
      await oldPhone(); // skips the IOU, acks the file
      t = t.add(const Duration(days: 8));
      phone.addWish('Synthetic kettle', 2500);
      await oldPhone(); // s16 covering the IOU file
      final st = await relay.state();
      expect((snapSchema(st.snapshot), snapSchema(st.previous)), ('s16', 's${WalletRepo.schemaVersion}'));
      expect(st.snapshot!.covers[laptop.deviceId], greaterThanOrEqualTo(iouFile));
      expect(st.devices[laptop.deviceId]!.first, greaterThan(1), reason: 'files both snapshots cover are pruned');
      expect(st.devices[laptop.deviceId]!.first, lessThanOrEqualTo(iouFile), reason: 'the IOU file is still there');

      await upgradePhone();
      phone.setLocalValue(SyncEngine.wantCurrentKey, '${t.millisecondsSinceEpoch}');
      final r = await run(phone);
      expect(r.problems, isEmpty);
      expect(ious(phone), ious(laptop));
      expect(phone.localValue(SyncEngine.wantCurrentKey), isNull);
    }, timeout: _t);

    test(
        'a device that kept its cursors never waits for a current snapshot: after 90 days away the newer build writes '
        'one and the upgraded device takes the IOUs from it', () async {
      await oldPhone();
      await run(laptop);
      laptop.addIou(person: 'Ana', direction: IouDirection.lent, amount: 2000, currency: 'EUR', date: '2026-01-24');
      await run(laptop);
      await oldPhone();
      // The laptop is away for over 90 days; the phone keeps writing older-schema snapshots, and its files go too.
      for (var i = 0; i < 13; i++) {
        t = t.add(const Duration(days: 8));
        phone.addWish('Synthetic item $i', 100 + i);
        await oldPhone();
      }
      final st = await relay.state();
      expect((snapSchema(st.snapshot), snapSchema(st.previous)), ('s16', 's16'));
      expect(st.devices[phone.deviceId]!.first, greaterThan(cursors(laptop)[phone.deviceId]! + 1), reason: 'pruned past the laptop');

      final back = await run(laptop);
      expect(back.problems, isEmpty);
      expect(laptop.localValue(SyncEngine.wantCurrentKey), isNull, reason: 'it kept its cursors: nothing skipped');
      expect(snapSchema((await relay.state()).snapshot), 's${WalletRepo.schemaVersion}', reason: 'so it writes a current one');
      expect(ious(laptop), hasLength(1));

      await upgradePhone();
      await run(phone);
      expect(ious(phone), ious(laptop));
      expect(phone.localValue(SyncEngine.wantCurrentKey), isNull);
    }, timeout: _t);

    test('the mark holds snapshots back for 30 days at most', () async {
      await oldPhone();
      await run(laptop);
      t = t.add(const Duration(days: 8));
      await oldPhone(); // s16
      laptop.setLocalValue(SyncEngine.wantCurrentKey, '${t.millisecondsSinceEpoch}');
      await run(laptop);
      expect(snapSchema((await relay.state()).snapshot), 's16', reason: 'held back while marked');
      expect(laptop.localValue(SyncEngine.wantCurrentKey), isNotNull);
      t = t.add(SyncEngine.wantCurrentFor + const Duration(days: 1));
      await run(laptop);
      expect(laptop.localValue(SyncEngine.wantCurrentKey), isNull, reason: 'expired');
      expect(snapSchema((await relay.state()).snapshot), 's${WalletRepo.schemaVersion}');
    }, timeout: _t);
  });

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
