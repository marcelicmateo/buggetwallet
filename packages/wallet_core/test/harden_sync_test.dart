// Stage H, items H5–H9 (core-builder B): relay instance id, stream epochs, device id per install, bounded HLC,
// BWOP2 (associated data, inflate cap), field-pair repair and one run at a time. Synthetic data only.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _hour = 3600000;

/// A sealed file as builds before Stage H wrote it: `BWOP1`, no associated data.
Future<Uint8List> _sealV1(List<int> plain, VaultKey key) async {
  final box = await Xchacha20.poly1305Aead().encrypt(gzip.encode(plain), secretKey: SecretKey(key.bytes));
  return Uint8List.fromList([...utf8.encode('BWOP1'), ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = 1767225600000;
  final devices = <Device>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-harden-');
    key = VaultKey.generate();
    now = 1767225600000;
    net = Net();
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  Device device(String name, {int skew = 0, String? deviceId}) {
    final d = Device(name, null, key, () => now + skew, net: net, deviceId: deviceId);
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

  void expectSame(List<Device> ds) {
    for (final d in ds.skip(1)) {
      expect(dump(d.repo), dump(ds.first.repo), reason: '${d.name} vs ${ds.first.name}');
    }
  }

  group('H5 relay instance id', () {
    test('state names the instance once the wallet exists; the device keeps it; fingerprint xxxx-xxxx', () async {
      final a = device('a');
      expect((await net.relay.state()).instance, isNull, reason: 'a wallet the relay does not know yet');
      a.repo.updateSettings({'salary': 1});
      final first = await a.run();
      expect(first.relayChanged, isFalse, reason: 'the very first sync');
      expect(first.relayInstance, net.relay.instance, reason: 'read again once its upload created the wallet');
      final second = await a.run();
      expect(second.relayInstance, net.relay.instance);
      expect(second.relayChanged, isFalse);
      expect(a.repo.localValue(SyncEngine.instanceKey), net.relay.instance);
      expect(relayFingerprint('0123456789abcdef0123456789abcdef'), '0123-4567');
      expect(relayFingerprint('ABCDEF0123'), 'abcd-ef01');
    });

    test('a replaced relay and then the old one back (A → B → A): each change is a first connect, nothing is lost', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'salary': 1});
      await rounds([a, b]);
      final relayA = net.relay.copy();
      now += 1000;
      a.repo.updateSettings({'rent': 2});
      await rounds([a, b]);
      final idA = net.relay.instance;

      // Relay B: empty, another instance.
      net.relay.wipe();
      now += 1000;
      b.repo.updateSettings({'loan': 3});
      // The first device back finds no wallet there: its upload creates it, the new instance is read right after
      // (relayChanged), and its own files being gone it starts a new stream when it had stored any.
      final rb = await b.run();
      expect(rb.relayChanged, isTrue);
      expect(rb.relayInstance, net.relay.instance);
      expect(rb.sent, greaterThan(0));
      final ra = await a.run();
      expect(ra.relayChanged, isTrue);
      expect((await b.run()).relayChanged, isFalse, reason: 'adopted quietly, no second first connect');
      await rounds([a, b]);
      expect(b.repo.settings().rent, 2);
      expect(a.repo.settings().loan, 3);
      expect((await a.run()).relayChanged, isFalse, reason: 'only the first run after the change');

      // Back to relay A (restored, its old instance): it lacks loan = 3 and the files after the copy.
      net.relay.restore(relayA);
      expect(net.relay.instance, idA);
      now += 1000;
      a.repo.updateSettings({'salary': 4});
      final back = await a.run();
      expect(back.relayChanged, isTrue);
      await rounds([b, a], 3);
      expectSame([a, b]);
      expect((b.repo.settings().salary, b.repo.settings().rent, b.repo.settings().loan), (4, 2, 3));
    });

    test('an older relay without an instance id keeps the stored id; no stored id yet is adopted quietly', () async {
      final a = device('a');
      a.repo.updateSettings({'salary': 1});
      final id = net.relay.instance;
      net.relay.instance = null;
      await a.run();
      await a.run();
      expect(a.repo.localValue(SyncEngine.instanceKey), isNull);
      net.relay.instance = id;
      final r = await a.run();
      expect((r.relayChanged, r.sent), (false, 0), reason: 'adopted, not a first connect');
      expect(a.repo.localValue(SyncEngine.instanceKey), id);
      net.relay.instance = null;
      expect((await a.run()).relayChanged, isFalse);
      expect(a.repo.localValue(SyncEngine.instanceKey), id);
    });

    test('RelayState.fromJson reads instance; a malformed one is a FormatException', () {
      expect(RelayState.fromJson({'devices': <String, Object?>{}, 'instance': 'ab' * 16}).instance, 'ab' * 16);
      expect(RelayState.fromJson({'devices': <String, Object?>{}}).instance, isNull);
      expect(() => RelayState.fromJson({'devices': <String, Object?>{}, 'instance': 'xyz'}), throwsFormatException);
      expect(() => RelayState.fromJson({'devices': <String, Object?>{}, 'instance': 5}), throwsFormatException);
    });
  });

  group('H5b stream epochs (a relay restored from an older copy)', () {
    test('two devices: edits on both sides after the restore all arrive (the lead repro)', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'salary': 1});
      await rounds([a, b]);
      final copy = net.relay.copy(); // A.last = 1
      now += 1000;
      a.repo.updateSettings({'rent': 2});
      await rounds([a, b]); // A seq 2; B's cursor for A = 2
      net.relay.restore(copy);
      now += 1000;
      a.repo.updateSettings({'loan': 30}); // 'after-a'
      b.repo.updateSettings({'paydayDay': 15});
      await rounds([a, b], 4);
      expectSame([a, b]);
      expect((b.repo.settings().rent, b.repo.settings().loan, a.repo.settings().paydayDay), (2, 30, 15));
      final streams = (await net.relay.state()).devices.keys.where((d) => d.startsWith(a.repo.deviceId)).toList()..sort();
      expect(streams, [a.repo.deviceId, '${a.repo.deviceId}-1'], reason: 'the new epoch is a new name, seq from 1');
      expect(a.repo.localValue(SyncEngine.epochKey), '1');
      // One device per id in the report, however many streams.
      final rep = await b.run();
      expect(rep.devices.map((d) => d.device).toList(), hasLength(2));
      expect(rep.problems, isEmpty);
    });

    test('B uploaded past the copy too: both start a new epoch and converge', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'salary': 1});
      b.repo.updateSettings({'rent': 1});
      await rounds([a, b]);
      final copy = net.relay.copy();
      now += 1000;
      a.repo.updateSettings({'salary': 2});
      b.repo.updateSettings({'rent': 2});
      await rounds([a, b]);
      net.relay.restore(copy);
      now += 1000;
      a.repo.updateSettings({'loan': 3});
      b.repo.updateSettings({'paydayDay': 20});
      await rounds([a, b], 4);
      expectSame([a, b]);
      expect((a.repo.settings().salary, a.repo.settings().rent, a.repo.settings().loan, a.repo.settings().paydayDay), (2, 2, 3, 20));
      expect((a.repo.localValue(SyncEngine.epochKey), b.repo.localValue(SyncEngine.epochKey)), ('1', '1'));
    });

    test('three devices, a restore and then a second restore of an even older copy', () async {
      final a = device('a'), b = device('b'), c = device('c');
      a.repo.updateSettings({'salary': 1});
      await rounds([a, b, c]);
      final oldest = net.relay.copy();
      now += 1000;
      b.repo.updateSettings({'rent': 2});
      await rounds([a, b, c]);
      final older = net.relay.copy();
      now += 1000;
      c.repo.updateSettings({'loan': 3});
      a.repo.updateSettings({'salary': 4});
      await rounds([a, b, c]);
      net.relay.restore(older);
      now += 1000;
      a.repo.updateSettings({'paydayDay': 5});
      await rounds([a, b, c], 3);
      expectSame([a, b, c]);
      net.relay.restore(oldest);
      now += 1000;
      b.repo.updateSettings({'rent': 6});
      c.repo.updateSettings({'loan': 7});
      await rounds([c, a, b], 4);
      expectSame([a, b, c]);
      final s = a.repo.settings();
      expect((s.salary, s.rent, s.loan, s.paydayDay), (4, 6, 7, 5));
      expect(int.parse(a.repo.localValue(SyncEngine.epochKey)!), greaterThanOrEqualTo(1));
      expect(SyncEngine.streamBase('${a.repo.deviceId}-2'), a.repo.deviceId);
      expect(SyncEngine.streamEpoch('${a.repo.deviceId}-2'), 2);
      expect(SyncEngine.streamEpoch(a.repo.deviceId), 0);
    });

    test('a wiped relay without instance ids (older relay) also moves to a new stream; nothing is skipped', () async {
      final a = device('a'), b = device('b');
      net.relay.instance = null;
      for (var i = 1; i <= 3; i++) {
        now += 1000;
        a.repo.updateSettings({'salary': i});
        await rounds([a, b]);
      }
      net.relay.wipe();
      net.relay.instance = null;
      now += 1000;
      a.repo.updateSettings({'rent': 9});
      // A re-uploads before B syncs: on the old rule its 3+ files would have looked like the ones B already read.
      await a.run();
      await a.run();
      await a.run();
      await rounds([b, a], 3);
      expectSame([a, b]);
      expect(b.repo.settings().rent, 9);
    });
  });

  group('H6 device id per install', () {
    test('open(deviceId:) on a new database takes it; storedDeviceId reads it; newDeviceId is 16 hex', () {
      final id = WalletRepo.newDeviceId();
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      final path = '${tmp.path}/w.db';
      final r = WalletRepo.open(path, deviceId: id);
      expect(r.deviceId, id);
      expect(WalletRepo.storedDeviceId(r.db), id);
      r.close();
      final again = WalletRepo.open(path);
      expect(again.deviceId, id, reason: 'null = the stored one');
      again.close();
      expect(() => WalletRepo.inMemory(deviceId: 'has-dash'), throwsArgumentError);
      expect(() => WalletRepo.inMemory(deviceId: ''), throwsArgumentError);
    });

    test('another id for an existing database: the install takes it and the next sync is a first connect under it', () async {
      final a = Device('a', tmp, key, () => now, net: net, dbPath: '${tmp.path}/a.db');
      devices.add(a);
      final b = device('b');
      a.repo.updateSettings({'salary': 1});
      await rounds([a, b]);
      final old = a.repo.deviceId;
      now += 1000;
      a.repo.updateSettings({'rent': 2}); // in the outbox under the old id
      a.deviceId = WalletRepo.newDeviceId();
      a.reopen();
      expect(a.repo.deviceId, isNot(old));
      expect(a.repo.pendingOps(), isNotEmpty, reason: 'the outbox is kept');
      final r = await a.run();
      expect(r.sent, greaterThan(1), reason: 'whole state under the new id');
      await rounds([b, a]);
      expectSame([a, b]);
      expect(b.repo.settings().rent, 2);
    });

    test('two installs with one device id (a copied database): deviceIdInUse, never interleaved; a new id fixes it', () async {
      final shared = WalletRepo.newDeviceId();
      final a = device('a', deviceId: shared), b = device('b');
      final clone = Device('clone', tmp, key, () => now, net: net, dbPath: '${tmp.path}/clone.db', deviceId: shared);
      devices.add(clone);
      a.repo.updateSettings({'salary': 1});
      await a.run();
      clone.repo.updateSettings({'rent': 2});
      final rc = await clone.run();
      expect(rc.problems.single.reason, SyncProblemReason.deviceIdInUse, reason: 'its own stream already holds files');
      expect(rc.problems.single.device, SyncProblem.shortId(shared));
      expect(rc.sent, 0);
      expect(clone.repo.pendingOps(), isNotEmpty, reason: 'outbox kept, not retried silently');
      expect(rc.caughtUp, isFalse);
      expect((await clone.run()).problems.single.reason, SyncProblemReason.deviceIdInUse, reason: 'every run');
      // The clone gets an id of its own (the app's fix: the database reopened with it) and joins as a new device.
      clone.deviceId = WalletRepo.newDeviceId();
      clone.reopen();
      await rounds([a, clone, b], 3);
      expectSame([a, clone, b]);
      expect((b.repo.settings().salary, b.repo.settings().rent), (1, 2));
    });

    test('a 409 on an own seq (another install wrote it since state) is deviceIdInUse with the outbox kept', () async {
      final shared = WalletRepo.newDeviceId();
      final a = device('a', deviceId: shared);
      a.repo.updateSettings({'salary': 1});
      await a.run();
      a.repo.updateSettings({'salary': 2});
      // Another install stores seq 2 between this run's state and its PUT.
      final racing = _RacingTransport(net.relay, () => net.relay.put(shared, 2, [1, 2, 3]));
      final rep = await SyncEngine(racing, key).run(a.repo);
      expect(rep.problems.single.reason, SyncProblemReason.deviceIdInUse);
      expect(a.repo.pendingOps(), isNotEmpty);
    });
  });

  group('H7 bounded HLC', () {
    test('a peer file more than an hour ahead is quarantined as clockDrift and applies once the clock catches up', () async {
      final ahead = device('ahead', skew: 2 * _hour), a = device('a');
      ahead.repo.updateSettings({'salary': 7});
      await ahead.run();
      final r1 = await a.run();
      expect(r1.problems.single.reason, SyncProblemReason.clockDrift);
      expect(r1.waiting.single.reason, SyncProblemReason.clockDrift);
      expect(a.repo.settings().salary, 0);
      expect((await a.run()).problems.single.isNew, isFalse, reason: 'not read again while the clock is behind');
      now += _hour + 60000; // the wall clock caught up (the file is now under an hour ahead)
      final r2 = await a.run();
      expect(r2.problems, isEmpty);
      expect(a.repo.settings().salary, 7);
    });

    test('a snapshot more than an hour ahead is not used either', () async {
      final ahead = device('ahead', skew: 2 * _hour);
      ahead.repo.updateSettings({'salary': 7});
      await ahead.run();
      const id = 's${WalletRepo.schemaVersion}-0-aa';
      await net.relay
          .putSnapshot(id, {ahead.repo.deviceId: 1}, await seal(backupPayload(ahead.repo.snapshotOps()), key, aad: aadSnapshot(id)));
      final a = device('a');
      final r = await a.run();
      expect(r.problems.map((p) => p.reason), everyElement(SyncProblemReason.clockDrift));
      expect(a.repo.settings().salary, 0);
    });

    test('a local write with the wall clock more than an hour behind the newest clock is refused, nothing written', () {
      var t = 1767225600000;
      final r = WalletRepo.inMemory(now: () => t);
      addTearDown(r.close);
      r.updateSettings({'salary': 1});
      final outbox = r.pendingOps().length, data = dump(r);
      t -= _hour + 1;
      expect(() => r.updateSettings({'salary': 2}), throwsA(isA<ClockBehindException>()));
      expect(r.pendingOps().length, outbox);
      expect(dump(r), data);
      expect(const ClockBehindException().message, isNot(matches(RegExp(r'\d'))), reason: 'no clock values');
      t += 2; // an hour behind exactly: still fine
      r.updateSettings({'salary': 2});
      expect(r.settings().salary, 2);
      expect(maxClockDrift, const Duration(hours: 1));
    });
  });

  group('H8 BWOP2', () {
    test('sealed for one place opens only there (another seq, device or use is badKey); BWOP1 still opens', () async {
      final plain = utf8.encode('[]');
      final f = await seal(plain, key, aad: aadSyncFile('dev1', 3));
      expect(f.sublist(0, 5), utf8.encode('BWOP2'));
      expect(await unseal(f, key, aad: aadSyncFile('dev1', 3)), plain);
      for (final other in [aadSyncFile('dev1', 4), aadSyncFile('dev2', 3), aadSnapshot('3'), aadBackup, aadBlob, aadWebKey]) {
        await expectLater(
            unseal(f, key, aad: other), throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.badKey)));
      }
      final old = await _sealV1(plain, key);
      for (final any in [aadBackup, aadSyncFile('x', 1)]) {
        expect(await unseal(old, key, aad: any), plain, reason: 'older builds wrote no associated data');
      }
      expect(utf8.decode(aadSyncFile('ab', 7)), 'bw-sync-file\nab\n7');
      expect(utf8.decode(aadSnapshot('s7-1-x')), 'bw-snapshot\ns7-1-x');
      expect([utf8.decode(aadBackup), utf8.decode(aadBlob), utf8.decode(aadWebKey)], ['bw-backup', 'bw-blob', 'bw-web-key']);
    });

    test('a fixed nonce gives fixed bytes (known-answer seam); random nonces never repeat', () async {
      final k = VaultKey(List.generate(32, (i) => i));
      final n = List.generate(24, (i) => 100 + i);
      final x = await seal(utf8.encode('synthetic'), k, aad: aadBackup, nonce: n);
      final y = await seal(utf8.encode('synthetic'), k, aad: aadBackup, nonce: n);
      expect(x, y);
      expect(x.sublist(5, 29), n);
      expect(() => seal(const [1], k, aad: aadBackup, nonce: const [1, 2]), throwsArgumentError);
      final nonces = {
        for (var i = 0; i < 200; i++) base64.encode((await seal(const [1], k, aad: aadBackup)).sublist(5, 29))
      };
      expect(nonces, hasLength(200));
    });

    test('inflating past the cap is tooLarge (a decompression bomb), within it fine', () async {
      expect(maxUnsealBytes, 256 * 1024 * 1024);
      final bomb = await seal(Uint8List(2 << 20), key, aad: aadBlob); // 2 MiB of zeros, a few KiB sealed
      expect(bomb.length, lessThan(64 * 1024));
      await expectLater(unseal(bomb, key, aad: aadBlob, maxBytes: 1 << 20),
          throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.tooLarge)));
      expect((await unseal(bomb, key, aad: aadBlob, maxBytes: 2 << 20)).length, 2 << 20);
    });

    test('a peer file moved to another seq or device on the relay is refused (badKey), BWOP1 peer files still apply', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'salary': 1});
      await a.run();
      a.repo.updateSettings({'rent': 2});
      await a.run();
      final one = net.files['d/${a.repo.deviceId}/1']!;
      net.relay.replace(a.repo.deviceId, 2, one); // the relay serves file 1 as file 2
      final r = await b.run();
      expect(r.problems.single.reason, SyncProblemReason.badKey);
      expect(r.waiting.single.seq, 2);

      final c = device('c');
      final ops = [
        Op('setting', 'loan', {'value': '5', 'deleted': 0}, Hlc(now, 0, 'oldbuild').toString()).toJson()
      ];
      await net.relay.put('oldbuild', 1, await _sealV1(utf8.encode(jsonEncode(ops)), key));
      await c.run();
      expect(c.repo.settings().loan, 5);
    });

    test('the local database cipher is pinned: a file keyed by an unpinned build opens', () {
      final path = '${tmp.path}/keyed.db';
      final dbKey = List.generate(32, (i) => 255 - i);
      final first = WalletRepo.open(path, dbKey: dbKey);
      first.updateSettings({'salary': 3});
      first.close();
      final again = WalletRepo.open(path, dbKey: dbKey);
      expect(again.settings().salary, 3);
      again.close();
    });
  });

  group('H9 field pairs and one run at a time', () {
    test('planned paid_tx is cleared when another device (an older build) set the status alone; both converge', () async {
      final a = device('a'), b = device('b');
      final tx = a.repo.addTransaction(date: '2026-01-05', amount: -2500, category: 'Groceries');
      final id = a.repo.addPlanned(title: 'Synthetic dentist', date: '2026-01-06', amount: 2500, category: 'Groceries');
      a.repo.markPlannedPaid(id, tx);
      await rounds([a, b]);
      // An older build's Skip: status only, newer clock, sent from b.
      now += 1000;
      b.repo.applyRemote([
        Op('planned', id, const {'status': 'skipped'}, Hlc(now, 0, 'oldbuild').toString())
      ], resend: true);
      await rounds([b, a], 3);
      for (final d in [a, b]) {
        final row = d.repo.db.select('SELECT status, paid_tx FROM planned WHERE id = ?', [id]).single;
        expect((row['status'], row['paid_tx']), ('skipped', null), reason: d.name);
      }
      expectSame([a, b]);
      a.repo.skipPlanned(id);
      expect(a.repo.db.select('SELECT paid_tx FROM planned WHERE id = ?', [id]).single['paid_tx'], isNull);
    });

    test('one payment linked to two bills on two devices offline: the first link stays, the other is unlinked', () async {
      final a = device('a'), b = device('b');
      final tx = a.repo.addTransaction(date: '2026-01-05', amount: -4599, category: 'Bills & subscriptions');
      final (b1, _) = a.repo.importBill(const NormalizedBill(
          source: BillSource.hub3, externalId: 'synthetic-1', date: '2026-01-02', total: 4599, payee: 'Synthetic Utility'));
      final (b2, _) = a.repo.importBill(const NormalizedBill(
          source: BillSource.hub3, externalId: 'synthetic-2', date: '2026-01-03', total: 4599, payee: 'Synthetic Water'));
      await rounds([a, b]);
      now += 1000;
      a.repo.linkBill(b1, tx);
      now += 1000;
      b.repo.linkBill(b2, tx);
      await rounds([a, b], 3);
      expectSame([a, b]);
      final linked = [
        for (final d in [a, b]) d.repo.bills().where((x) => x.linkedTx == tx).map((x) => x.id).toList()
      ];
      expect(linked, [
        [b1],
        [b1]
      ]);
    });

    test('run while a run of the same engine is in progress returns the same future; a later call runs again', () async {
      final a = device('a');
      a.repo.updateSettings({'salary': 1});
      await a.run(); // the wallet exists on the relay (a run that creates it asks the state twice)
      a.repo.updateSettings({'salary': 2});
      final engine = SyncEngine(net.relay, key);
      final before = net.relay.calls['state']!;
      final f1 = engine.run(a.repo), f2 = engine.run(a.repo);
      expect(identical(f1, f2), isTrue);
      final r1 = await f1;
      expect(identical(await f2, r1), isTrue);
      expect(net.relay.calls['state'], before + 1, reason: 'one run only');
      await engine.run(a.repo);
      expect(net.relay.calls['state'], before + 2);
    });
  });
}

/// Forwards to [inner], running [race] once before the first PUT (another install storing a file meanwhile).
class _RacingTransport implements SyncTransport {
  final SyncTransport inner;
  Future<void> Function()? race;
  _RacingTransport(this.inner, this.race);
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) async {
    final r = race;
    race = null;
    if (r != null) await r();
    return inner.put(device, seq, bytes);
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
