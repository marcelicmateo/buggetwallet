// V2 (Stage V): device state digests travel with the sync files; a mismatch repairs itself (whole state + ask, the
// equal-clock tie-break), a second one within 7 days raises devicesDisagree; quiet devices stay quiet. Divergence is
// forced by writing a device's database behind the change log. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/engine_spec_sim.dart';
import '../../wallet_core/test/support/synthetic.dart';

/// A relay whose bill-file PUTs can be made to fail.
class _NoBlobs extends MemoryTransport {
  _NoBlobs({super.now});
  bool fail = false;
  @override
  Future<void> putBlob(String hash, List<int> bytes) {
    if (fail) throw const TransportException(TransportFailure.unreachable, 'down');
    return super.putBlob(hash, bytes);
  }
}

List<String> _capture() {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = was;
  });
  return lines;
}

void main() {
  late Sim sim;
  setUp(() => sim = Sim());
  tearDown(() => sim.closeAll());

  Future<Map<String, int>> lasts() async => {for (final e in (await sim.transport.state()).devices.entries) e.key: e.value.last};
  String text(Map<String, int> m) => jsonEncode(Map.fromEntries(m.entries.toList()..sort((x, y) => x.key.compareTo(y.key))));

  /// Sync rounds until one where no device reads or sends anything and the relay holds no new file. Returns the rounds
  /// it took (the quiet one included); fails after [max].
  Future<int> settle(List<Dev> ds, {int max = 8}) async {
    for (var i = 1; i <= max; i++) {
      final before = await lasts();
      var busy = false;
      for (final d in ds) {
        final r = await d.sync();
        if (r.filesRead > 0 || r.sent > 0) busy = true;
        sim.tick(const Duration(seconds: 5));
      }
      if (!busy && text(before) == text(await lasts())) return i;
    }
    fail('still busy after $max rounds');
  }

  void expectSame(List<Dev> ds) {
    for (final d in ds.skip(1)) {
      expect(d.repo.stateDigest(), ds.first.repo.stateDigest());
      expect(canon(d.repo, clocks: true), canon(ds.first.repo, clocks: true));
    }
  }

  /// [n] devices in sync on a small wallet.
  Future<List<Dev>> cluster(int n) async {
    final ds = [for (var i = 0; i < n; i++) sim.device()];
    ds.first.repo
      ..importBatch(january)
      ..updateSettings({'salary': 150000, 'rent': 50000});
    await settle(ds);
    expectSame(ds);
    return ds;
  }

  group('no ping-pong', () {
    for (final n in [2, 3]) {
      test('$n devices: one edit costs at most one digest file per reader, then every device stays quiet', () async {
        final ds = await cluster(n);
        final start = await lasts();
        sim.tick();
        ds.first.repo.updateSettings({'rent': 51000});
        await settle(ds);
        final after = await lasts();
        final grown = {for (final e in after.entries) e.key: e.value - (start[e.key] ?? 0)};
        expect(grown[ds.first.id], 1, reason: 'the writer: its data file carries its digest');
        for (final d in ds.skip(1)) {
          expect(grown[d.id], lessThanOrEqualTo(1), reason: 'a reader: at most one digest file');
        }
        for (var i = 0; i < 3; i++) {
          for (final d in ds) {
            final r = await d.sync();
            expect((r.sent, r.filesRead), (0, 0));
            expect(r.problems, isEmpty);
            sim.tick(const Duration(hours: 1));
          }
        }
        expect(await lasts(), after, reason: 'quiet devices write nothing');
        expectSame(ds);
      });
    }

    test('matching digests are compared and logged as matched, never as a mismatch', () async {
      final lines = _capture();
      final ds = await cluster(2);
      sim.tick();
      ds.first.repo.updateSettings({'rent': 52000});
      await settle(ds);
      final text = lines.join('\n');
      expect(text, contains('sync.digest.compare {"matched":1,"differ":0'));
      expect(text, isNot(contains('sync.digest.mismatch')));
      expect(text, isNot(contains('sync.repair')));
    });
  });

  group('repair', () {
    void corrupt(Dev d, String sql) => d.repo.db.execute(sql);

    test('same clock, different value: the higher value (canonical JSON) wins on every device, then quiet', () async {
      final lines = _capture();
      final ds = await cluster(2);
      final [a, b] = ds;
      // b's salary changed behind the change log: same clock as a's, another value ("9" sorts above "150000").
      corrupt(b, "UPDATE settings SET value = '9' WHERE id = 'salary'");
      expect(b.repo.settings().salary, 9);
      sim.tick();
      a.repo.updateSettings({'rent': 51000}); // any data change sends a digest
      await settle(ds);
      expectSame(ds);
      expect((a.repo.settings().salary, b.repo.settings().salary), (9, 9));
      expect(a.repo.settings().rent, 51000);
      final text = lines.join('\n');
      expect(text, contains('sync.digest.mismatch'));
      expect(text, contains('sync.repair.start'));
      expect(text, contains('sync.repair.answer'));
      expect(RegExp('sync.repair.start').allMatches(text), hasLength(1), reason: 'one repair');
      for (final d in ds) {
        expect((await d.sync()).problems, isEmpty);
      }
    });

    test('a value that sorts lower loses: the device that was changed gets the others\' value back', () async {
      final ds = await cluster(3);
      final [a, b, c] = ds;
      corrupt(c, "UPDATE settings SET value = '0' WHERE id = 'salary'");
      sim.tick();
      b.repo.updateSettings({'rent': 51000});
      await settle(ds);
      expectSame(ds);
      expect([for (final d in ds) d.repo.settings().salary], [150000, 150000, 150000]);
      expect(a.repo.settings().rent, 51000);
    });

    test('a row lost on one device (row and clocks gone) comes back from the others', () async {
      final ds = await cluster(2);
      final [a, b] = ds;
      corrupt(b, "DELETE FROM settings WHERE id = 'rent'");
      corrupt(b, "DELETE FROM clocks WHERE entity = 'setting' AND id = 'rent'");
      expect(b.repo.settings().rent, 0);
      sim.tick();
      a.repo.updateSettings({'salary': 151000});
      await settle(ds);
      expectSame(ds);
      expect(b.repo.settings().rent, 50000);
    });

    test('nothing is deleted by a repair: rows only one device holds stay and spread', () async {
      final ds = await cluster(2);
      final [a, b] = ds;
      final rows = a.repo.transactions().length;
      // b lost a row behind the change log; a holds it. After the repair both hold every row.
      final victim = b.repo.transactions().first.id;
      corrupt(b, "DELETE FROM tx WHERE id = '$victim'");
      sim.tick();
      a.repo.updateSettings({'rent': 49000});
      await settle(ds);
      expectSame(ds);
      expect(b.repo.transactions().length, rows);
    });
  });

  group('devicesDisagree', () {
    test('a second mismatch within 7 days of a repair: no second repair, devicesDisagree until a compare matches', () async {
      final lines = _capture();
      final ds = await cluster(2);
      final [a, b] = ds;
      b.repo.db.execute("UPDATE settings SET value = '9' WHERE id = 'salary'");
      sim.tick();
      a.repo.updateSettings({'rent': 51000});
      await settle(ds);
      expectSame(ds);

      // Again, two days later: b's value changes behind the log once more.
      sim.tick(const Duration(days: 2));
      b.repo.db.execute("UPDATE settings SET value = '8' WHERE id = 'salary'");
      a.repo.updateSettings({'rent': 52000});
      await a.sync();
      final r = await b.sync();
      final p = r.problems.singleWhere((p) => p.reason == SyncProblemReason.devicesDisagree);
      expect((p.device, p.bytes, p.isNew, p.snapshot), (a.short, 0, true, false));
      expect(r.caughtUp, isTrue, reason: 'not a file left unread');
      expect(RegExp('sync.repair.start').allMatches(lines.join('\n')), hasLength(1), reason: 'no second repair');
      final again = await b.sync();
      expect(again.problems.single.reason, SyncProblemReason.devicesDisagree);
      expect(again.problems.single.isNew, isFalse, reason: 'kept, not new');
      expect(again.badFiles, 0, reason: 'not a file that could not be read');
      expect(again.problemsByDevice, isEmpty);

      // Past the 7 days, still disagreeing: devicesDisagree stops automatic repair until a compare matches.
      sim.tick(const Duration(days: 8));
      b.repo.db.execute("UPDATE settings SET value = '7' WHERE id = 'salary'");
      a.repo.updateSettings({'rent': 52500});
      await a.sync();
      final late = await b.sync();
      expect(late.problems.single.reason, SyncProblemReason.devicesDisagree);
      expect(RegExp('sync.repair.start').allMatches(lines.join('\n')), hasLength(1), reason: 'still no second repair');
      expect(b.repo.pendingOps(), isEmpty, reason: 'no whole-state resend queued');

      // Put right (by hand here): the next compare matches and clears it.
      b.repo.db.execute("UPDATE settings SET value = '9' WHERE id = 'salary'");
      sim.tick();
      a.repo.updateSettings({'rent': 53000});
      await a.sync();
      expect((await b.sync()).problems, isEmpty);
      expect(lines.join('\n'), contains('sync.digest.agree'));
    });

    test('after 7 days quiet a new mismatch repairs again', () async {
      final lines = _capture();
      final ds = await cluster(2);
      final [a, b] = ds;
      b.repo.db.execute("UPDATE settings SET value = '9' WHERE id = 'salary'");
      sim.tick();
      a.repo.updateSettings({'rent': 51000});
      await settle(ds);
      sim.tick(const Duration(days: 8));
      b.repo.db.execute("UPDATE settings SET value = '99' WHERE id = 'salary'");
      a.repo.updateSettings({'rent': 52000});
      await settle(ds);
      expectSame(ds);
      expect(RegExp('sync.repair.start').allMatches(lines.join('\n')), hasLength(2));
      for (final d in ds) {
        expect((await d.sync()).problems, isEmpty);
      }
    });
  });

  group('compare rules (forged peer files)', () {
    Future<void> peerFile(String device, int seq, List<Op> ops) async => sim.transport
        .put(device, seq, await seal(utf8.encode(jsonEncode([for (final op in ops) op.toJson()])), sim.key, aad: aadSyncFile(device, seq)));
    Op data(int n) => Op('setting', 'rent', {'value': '$n', 'deleted': 0}, Hlc(sim.clock.ms - 1000, n, 'p1').toString());
    Op digest(String hex, Map<String, int> vector, {int? schema}) => Op('_digest', 'p1',
        {'digest': hex, 'vector': vector, 'schema': schema ?? WalletRepo.schemaVersion}, Hlc(sim.clock.ms, 0, 'p1').toString());

    test('equal vector and schema, other digest: a repair starts (whole state queued, then uploaded with an ask)', () async {
      final lines = _capture();
      final d = sim.device();
      await peerFile('p1', 1, [
        data(1),
        digest('00' * 32, {'p1': 1})
      ]);
      await d.sync();
      expect(lines.join('\n'), contains('sync.digest.mismatch {"peers":1,"matched":0}'));
      expect(d.repo.pendingOps(), isNotEmpty, reason: 'the whole state waits for the next upload');
      await d.sync();
      final mine = (await sim.transport.state()).devices[d.id]!.last;
      final clear = await unseal(await sim.transport.get(d.id, mine), sim.key, aad: aadSyncFile(d.id, mine));
      final kinds = [for (final o in jsonDecode(utf8.decode(clear)) as List) (o as Map)['e']];
      expect(kinds.first, '_repair');
      expect(kinds, contains('setting'));
    });

    test('another schema, a stale or ahead vector, or a broken record: ignored', () async {
      final lines = _capture();
      final d = sim.device();
      await peerFile('p1', 1, [
        data(1),
        digest('00' * 32, {'p1': 1}, schema: WalletRepo.schemaVersion + 1),
      ]);
      await peerFile('p2', 1, [
        data(2),
        Op('_digest', 'p2', {'digest': 5}, Hlc(sim.clock.ms, 0, 'p2').toString()),
      ]);
      await d.sync();
      await peerFile('p1', 2, [
        data(3),
        digest('00' * 32, {'p1': 1, 'p2': 1})
      ]); // stale: p1 2 not in it
      await d.sync();
      await peerFile('p1', 3, [
        data(4),
        digest('00' * 32, {'p1': 3, 'p2': 1, 'p3': 1})
      ]); // ahead
      await d.sync();
      final text = lines.join('\n');
      expect(text, isNot(contains('sync.digest.mismatch')));
      expect(text, contains('sync.digest.badRecord'));
      expect(d.repo.pendingOps(), isEmpty);
    });

    test('logs of the digest and repair carry counts and enum words only', () async {
      final lines = _capture();
      final d = sim.device();
      d.repo.updateSettings({'salary': 123456});
      await d.sync(); // its own file 1
      await peerFile('p1', 1, [
        data(1),
        digest('ab' * 32, {'p1': 1, d.id: 1})
      ]);
      await d.sync();
      await d.sync();
      final digestLines = lines.where((l) => l.contains('sync.digest') || l.contains('sync.repair')).join('\n');
      expect(digestLines, contains('sync.repair.start'));
      expect(digestLines, isNot(contains(d.id)));
      expect(digestLines, isNot(contains('p1')));
      expect(digestLines, isNot(contains('123456')));
      expect(digestLines, isNot(contains('abab')));
      expect(digestLines, isNot(contains(d.repo.stateDigest())));
    });

    Op ask(int ms) => Op('_repair', 'p1', {'ask': true}, Hlc(ms, 0, 'p1').toString());

    test('an ask written before this device first met the relay is not answered (a replay of old files)', () async {
      final lines = _capture();
      final d = sim.device();
      await peerFile('p1', 1, [data(1), ask(sim.clock.ms - const Duration(days: 3).inMilliseconds)]);
      await d.sync();
      await d.sync();
      expect(lines.join('\n'), isNot(contains('sync.repair.answer')));
      expect(d.repo.pendingOps(), isEmpty);
    });

    test('asks count once by id, not by clock order: an ask with an older clock (skewed asker) is still answered', () async {
      final lines = _capture();
      final d = sim.device();
      d.repo.updateSettings({'salary': 1000});
      await d.sync(); // first meets the relay now
      final t0 = sim.clock.ms;
      sim.tick(const Duration(hours: 1));
      await peerFile('p1', 1, [data(1), ask(t0 + const Duration(minutes: 40).inMilliseconds)]);
      await d.sync(); // answers: whole state queued
      await d.sync(); // ... and sent
      expect(d.repo.pendingOps(), isEmpty);
      await peerFile('p1', 2, [data(2), ask(t0 + const Duration(minutes: 10).inMilliseconds)]); // another asker's clock, behind
      await peerFile('p1', 3, [data(3), ask(t0 + const Duration(minutes: 40).inMilliseconds)]); // the first ask again
      await d.sync();
      await d.sync();
      expect(RegExp('sync.repair.answer').allMatches(lines.join('\n')), hasLength(2));
    });

    test('bill fields held back for a file that could not be PUT go later still carrying the repair record', () async {
      final relay = _NoBlobs(now: () => sim.clock.t);
      final repo = WalletRepo.inMemory(now: () => sim.clock.ms);
      addTearDown(repo.close);
      final engine = SyncEngine(relay, sim.key, now: () => sim.clock.t);
      Future<void> put(String device, int seq, List<Op> ops) async => relay.put(
          device, seq, await seal(utf8.encode(jsonEncode([for (final op in ops) op.toJson()])), sim.key, aad: aadSyncFile(device, seq)));
      Future<List<Op>> lastFile() async {
        final last = (await relay.state()).devices[repo.deviceId]!.last;
        final clear = await unseal(await relay.get(repo.deviceId, last), sim.key, aad: aadSyncFile(repo.deviceId, last));
        return [for (final o in jsonDecode(utf8.decode(clear)) as List) Op.fromJson(Map<String, Object?>.from(o as Map))];
      }

      repo.updateSettings({'salary': 1000});
      await engine.run(repo);
      relay.fail = true;
      final ref = await BlobStore(repo, sim.key).add(Uint8List.fromList(List<int>.generate(300, (i) => i % 251)), 'jpg');
      final (billId, _) = repo.importBill(
          const NormalizedBill(
              source: BillSource.pdf, externalId: 'jir:synthetic-v2h', date: '2026-01-09', total: 1000, payee: 'Test Shop'),
          file: ref);
      await engine.run(repo); // the file waits: its bill fields are held
      sim.tick(const Duration(minutes: 5));
      await put('p1', 1, [data(1), ask(sim.clock.ms)]);
      await engine.run(repo); // answers: whole state queued
      await engine.run(repo); // resend goes, the bill's file fields stay held (PUT still failing)
      expect((await lastFile()).first.entity, '_repair');
      expect(repo.pendingOps(), isNotEmpty);
      relay.fail = false;
      final r = await engine.run(repo);
      expect(r.blobsSent, 1);
      expect(repo.pendingOps(), isEmpty);
      final ops = await lastFile();
      expect(ops.first.entity, '_repair', reason: 'the held fields apply with the tie-break too');
      expect(ops.any((o) => o.entity == 'bill' && o.id == billId && o.fields['blob'] == ref.hash), isTrue);
    });

    test('a repair resend does not PUT bill files this device already stored; their bill fields go with the record', () async {
      final d = sim.device();
      d.repo.updateSettings({'salary': 1000});
      await d.sync();
      final ref = await BlobStore(d.repo, sim.key).add(Uint8List.fromList(List<int>.generate(300, (i) => i % 251)), 'jpg');
      final (billId, _) = d.repo.importBill(
          const NormalizedBill(source: BillSource.pdf, externalId: 'jir:synthetic-v2', date: '2026-01-09', total: 1000, payee: 'Test Shop'),
          file: ref);
      final up = await d.sync();
      expect(up.blobsSent, 1);
      final mine = (await lasts())[d.id]!;
      await peerFile('p1', 1, [
        data(1),
        digest('00' * 32, {'p1': 1, d.id: mine})
      ]);
      await d.sync(); // mismatch: repair starts
      final resend = await d.sync();
      expect(resend.sent, greaterThan(0));
      expect(resend.blobsSent, 0, reason: 'already on the relay');
      expect(d.repo.pendingOps(), isEmpty, reason: 'nothing held back');
      final last = (await lasts())[d.id]!;
      final clear = await unseal(await sim.transport.get(d.id, last), sim.key, aad: aadSyncFile(d.id, last));
      final ops = [for (final o in jsonDecode(utf8.decode(clear)) as List) Op.fromJson(Map<String, Object?>.from(o as Map))];
      expect(ops.first.entity, '_repair');
      expect(ops.any((o) => o.entity == 'bill' && o.id == billId && o.fields['blob'] == ref.hash), isTrue);
    });
  });
}
