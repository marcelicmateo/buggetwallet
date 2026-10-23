// ignore_for_file: avoid_dynamic_calls
// Stage H12 (sync against the real relay server in-process): A -> B -> A, a relay restored from an older copy of its data
// folder or wiped, cloned device ids, two runs at once, invariants on the real relay's state, and the model
// equivalence "MemoryTransport behaves like the real relay" on one scripted scenario. Written from the Stage H spec;
// behaviour a build does not have yet skips with `BUG: H<n>`. All data is SYNTHETIC.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/engine_spec_sim.dart';
import 'support/h_compat.dart';
import 'support/h_sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 60));

Future<(Cluster, RelayRig)> _relayCluster() async {
  final clock = SimClock();
  final rig = RelayRig(clock);
  await rig.start();
  addTearDown(rig.dispose);
  final key = VaultKey.generate();
  final c = Cluster(rig.transport(key), clock, key);
  addTearDown(c.closeAll);
  return (c, rig);
}

String _add(Dev d, String note, {int cents = -1000}) =>
    d.repo.addTransaction(date: '2026-01-14', amount: cents, category: 'Groceries', note: note);

Set<String> _ids(Dev d) => {for (final t in d.repo.transactions(includeHidden: true)) t.id};

void main() {
  group('A -> B -> A through the real relay', () {
    test('first connect, edits both ways, idle rounds, invariants on the relay state', () async {
      final (c, _) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      final first = await a.sync();
      expect(first.problems, isEmpty);
      c.tick();
      final got = await b.sync();
      expect(got.filesRead, 1);
      expect(got.caughtUp, isTrue);
      final fromB = _add(b, 'from b');
      c.tick();
      await b.sync();
      c.tick();
      final back = await a.sync();
      expect(back.filesRead, 1);
      expect(_ids(a), contains(fromB));
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
      await c.syncAll(rounds: 2);
      for (final d in c.devs) {
        final r = await d.sync();
        expect((r.sent, r.received, r.filesRead), (0, 0, 0), reason: 'the second full round is idle');
      }
      expect(data(a), data(b));
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);

    test('a late third device and a device back after 91 days (files pruned on the real relay)', () async {
      final (c, _) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final offline = _add(b, 'offline');
      for (var i = 0; i < 10; i++) {
        c.tick(const Duration(days: 10));
        _add(a, 'a$i', cents: -100 - i);
        await a.sync();
      }
      final s = await c.transport.state();
      expect(s.devices[a.id]!.first, greaterThan(1), reason: 'the relay pruned what only a dead device still needed');
      c.tick(const Duration(seconds: 1));
      final late = c.add();
      await c.syncAll(rounds: 3);
      expect(data(a), data(b));
      expect(data(a), data(late));
      expect(_ids(a), contains(offline));
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);
  });

  group('a relay restored from an older copy of its data folder', () {
    Future<void> restore(RelayRig rig, Directory copy) async {
      await rig.relay.close();
      rig.restoreFrom(copy);
      await rig.start(port: rig.base.port);
    }

    test('both devices ahead of the relay: they upload what it lost and end identical, nothing lost', () async {
      final (c, rig) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final copy = rig.copyData();
      addTearDown(() => copy.deleteSync(recursive: true));
      final kept = <String>{};
      for (var i = 0; i < 3; i++) {
        kept.add(_add(a, 'a$i', cents: -100 - i));
        c.tick();
        await a.sync();
        await b.sync();
        kept.add(_add(b, 'b$i', cents: -200 - i));
        c.tick();
        await b.sync();
        await a.sync();
      }
      await restore(rig, copy);
      await c.syncAll(rounds: 4);
      expect(data(a), data(b));
      for (final d in [a, b]) {
        expect(_ids(d).containsAll(kept), isTrue, reason: 'device ${d.short}');
      }
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);

    test('a device that joined after the copy was taken (the relay never heard of it)', () async {
      final (c, rig) = await _relayCluster();
      final a = c.add();
      a.repo.importBatch(january);
      await c.syncAll(rounds: 2);
      final copy = rig.copyData();
      addTearDown(() => copy.deleteSync(recursive: true));
      final b = c.add();
      final kept = <String>{_add(a, 'a-after'), _add(b, 'b-new')};
      await c.syncAll(rounds: 3);
      await restore(rig, copy);
      await c.syncAll(rounds: 4);
      expect(data(a), data(b));
      expect(_ids(b).containsAll(kept), isTrue);
      expect(_ids(a).containsAll(kept), isTrue);
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);

    test('edits made between the restore and the first sync are not lost either', () async {
      final (c, rig) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final copy = rig.copyData();
      addTearDown(() => copy.deleteSync(recursive: true));
      _add(a, 'before');
      await c.syncAll(rounds: 2);
      await restore(rig, copy);
      final kept = <String>{_add(a, 'after-a'), _add(b, 'after-b')};
      await c.syncAll(rounds: 4);
      final onlyA = data(a).toSet().difference(data(b).toSet()), onlyB = data(b).toSet().difference(data(a).toSet());
      expect([onlyA, onlyB], [<String>{}, <String>{}]);
      expect(data(a), data(b));
      expect(_ids(a).containsAll(kept), isTrue);
      expect(_ids(b).containsAll(kept), isTrue);
    }, skip: 'BUG: H5b - relay restored from an older copy loses edits made after it', timeout: _t);

    test('a lagging peer: the restored relay re-numbers a device\'s files, and the peer still gets its newest edit', () async {
      // A uploads seq 1, B reads it, A uploads seq 2 and 3, B reads 2 only. The relay goes back to "A has 1 file".
      // A re-uploads its whole state as the next file (seq 2), which B's cursor (2) says it already has.
      final (c, rig) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await a.sync();
      await b.sync();
      final copy = rig.copyData();
      addTearDown(() => copy.deleteSync(recursive: true));
      _add(a, 'e1');
      c.tick();
      await a.sync();
      await b.sync();
      final e2 = _add(a, 'e2');
      c.tick();
      await a.sync();
      await restore(rig, copy);
      await c.syncAll(rounds: 5);
      expect(_ids(b), contains(e2), reason: "B must end with A's newest edit although its cursor says it read that file number");
      expect(data(a), data(b));
    }, skip: 'BUG: H5b - relay restored from an older copy loses edits made after it', timeout: _t);
    test('both streams roll back: A and B both uploaded past the copy, then new edits on both sides reach the other', () async {
      final (c, rig) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final copy = rig.copyData();
      addTearDown(() => copy.deleteSync(recursive: true));
      final kept = <String>{};
      for (var i = 0; i < 2; i++) {
        kept.add(_add(a, 'a-past$i', cents: -100 - i));
        c.tick();
        await a.sync();
        await b.sync();
        kept.add(_add(b, 'b-past$i', cents: -200 - i));
        c.tick();
        await b.sync();
        await a.sync();
      }
      await restore(rig, copy);
      kept.add(_add(a, 'a-after'));
      kept.add(_add(b, 'b-after'));
      await c.syncAll(rounds: 5);
      expect(_ids(a).containsAll(kept), isTrue, reason: 'A lost an edit');
      expect(_ids(b).containsAll(kept), isTrue, reason: 'B lost an edit');
      expect(data(a), data(b));
    }, timeout: _t);
  });

  group('a wiped relay and the relay instance id (H5)', () {
    test('GET state carries a 32-hex instance id that survives a restart of the same data folder', () async {
      final (c, rig) = await _relayCluster();
      final a = c.add();
      a.repo.importBatch(january);
      final r1 = await a.sync();
      final i1 = (r1 as dynamic).relayInstance as String?;
      expect(i1, matches(RegExp(r'^[0-9a-f]{32}$')));
      await rig.restart();
      c.tick();
      final r2 = await a.sync();
      expect((r2 as dynamic).relayInstance, i1, reason: 'kept in meta.json');
      expect((r2 as dynamic).relayChanged, isFalse);
    }, skip: bugUnless(hasRelayInstance, 'H5', 'RelayState.instance / SyncReport.relayInstance / relayChanged'), timeout: _t);

    test('a wiped relay has a new instance id: every device reports relayChanged once, then not again', () async {
      final (c, rig) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      await c.syncAll(rounds: 3);
      final i1 = (await a.sync() as dynamic).relayInstance as String;
      await rig.relay.close();
      for (final e in rig.dir.listSync()) {
        e.deleteSync(recursive: true);
      }
      await rig.start(port: rig.base.port);
      c.tick();
      final ra = await a.sync();
      expect((ra as dynamic).relayChanged, isTrue);
      expect((ra as dynamic).relayInstance, isNot(i1));
      final rb = await b.sync();
      expect((rb as dynamic).relayChanged, isTrue);
      expect((await a.sync() as dynamic).relayChanged, isFalse);
      expect((await b.sync() as dynamic).relayChanged, isFalse);
      expect(data(a), data(b));
    }, skip: bugUnless(hasRelayInstance, 'H5', 'relay instance id changes when the relay is wiped; a change = first connect'), timeout: _t);

    test('today: a wiped relay is refilled by every device and nothing is lost', () async {
      final (c, rig) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      a.repo.importBatch(january);
      final kept = {_add(a, 'one'), _add(b, 'two')};
      await c.syncAll(rounds: 3);
      await rig.relay.close();
      for (final e in rig.dir.listSync()) {
        e.deleteSync(recursive: true);
      }
      await rig.start(port: rig.base.port);
      await c.syncAll(rounds: 4);
      expect(data(a), data(b));
      expect(_ids(a).containsAll(kept), isTrue);
      expect(_ids(b).containsAll(kept), isTrue);
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);
  });

  group('cloned device id (H6)', () {
    // Two installs of one database file (a restored phone backup, a copied profile) write as one device.
    Future<(Cluster, Dev, Dev, Dev)> clones() async {
      final clock = SimClock();
      final c = Cluster(MemoryTransport(now: () => clock.t), clock);
      addTearDown(c.closeAll);
      final dir = Directory.systemTemp.createTempSync('bw-h12-clone-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final origin = WalletRepo.open('${dir.path}/o.db', now: () => clock.ms);
      origin.importBatch(january);
      origin.close();
      File('${dir.path}/o.db').copySync('${dir.path}/c.db');
      Dev open(String f) {
        final repo = WalletRepo.open('${dir.path}/$f', now: () => clock.ms);
        final d = Dev(repo, SyncEngine(c.transport, c.key, appVersion: '1.0.0', now: () => clock.t));
        c.devs.add(d);
        return d;
      }

      final x1 = open('o.db'), x2 = open('c.db');
      expect(x1.id, x2.id, reason: 'a copied database is the same device');
      return (c, x1, x2, c.add());
    }

    test('both installs write: nothing crashes, the peer ends with the first install\'s edit', () async {
      final (c, x1, x2, p) = await clones();
      final e1 = _add(x1, 'x1');
      final e2 = _add(x2, 'x2');
      for (var round = 0; round < 5; round++) {
        for (final d in [x1, x2, p]) {
          await d.sync();
          c.tick();
        }
      }
      expect(_ids(p), contains(e1));
      expect(_ids(x1).contains(e1) && _ids(x2).contains(e2), isTrue);
      if (reasonNamed('deviceIdInUse') == null) {
        expect(_ids(p), contains(e2), reason: 'today both get through, interleaved (known limit)');
      }
    }, timeout: _t);

    test(
        'the clone and the original both keep editing: they converge with the peer, deviceIdInUse is reported once and never blocks caughtUp',
        () async {
      final (c, x1, x2, p) = await clones();
      final reason = reasonNamed('deviceIdInUse')!;
      final kept = <String>{};
      final inUse = <Dev, int>{x1: 0, x2: 0, p: 0};
      SyncReport? lastX1, lastX2;
      for (var round = 0; round < 6; round++) {
        kept.add(_add(x1, 'x1-$round', cents: -100 - round));
        kept.add(_add(x2, 'x2-$round', cents: -200 - round));
        for (final d in [x1, x2, p]) {
          final r = await d.sync();
          if (r.problems.any((q) => q.reason == reason)) inUse[d] = inUse[d]! + 1;
          if (d == x1) lastX1 = r;
          if (d == x2) lastX2 = r;
          c.tick();
        }
      }
      await c.syncAll(rounds: 3);
      for (final d in [x1, x2, p]) {
        expect(_ids(d).containsAll(kept), isTrue, reason: 'device ${d.short} lost an edit');
      }
      expect(data(x1), data(x2));
      expect(data(x2), data(p));
      expect(inUse[x1]! + inUse[x2]!, greaterThanOrEqualTo(1), reason: 'the clash is reported');
      expect(inUse[x1]!, lessThanOrEqualTo(1), reason: 'reported once per install, not on every run');
      expect(inUse[x2]!, lessThanOrEqualTo(1));
      expect(inUse[p], 0, reason: 'the peer shares nobody\'s id');
      expect((lastX1!.caughtUp, lastX2!.caughtUp), (true, true), reason: 'information only: it does not block catching up');
    },
        skip: bugUnless(reasonNamed('deviceIdInUse') != null, 'H6', 'two installs of one device id converge; deviceIdInUse is information'),
        timeout: _t);

    test('a new install takes the id it is given and re-exports the old id\'s outbox as a first connect', () async {
      final clock = SimClock();
      final dir = Directory.systemTemp.createTempSync('bw-h12-devid-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final one = openRepo('${dir.path}/w.db', now: () => clock.ms);
      final old = one.deviceId;
      one.importBatch(january);
      one.close();
      final two = openRepo('${dir.path}/w.db', deviceId: 'abcdef0123456789', now: () => clock.ms);
      addTearDown(two.close);
      expect(two.deviceId, 'abcdef0123456789');
      expect(two.deviceId, isNot(old));
      expect(two.pendingOps(), isNotEmpty, reason: 'the old id\'s unsent ops are exported again under the new id');
      final reopened = openRepo('${dir.path}/w.db', now: () => clock.ms);
      addTearDown(reopened.close);
      expect(reopened.deviceId, 'abcdef0123456789', reason: 'the stored id follows the install');
    }, skip: bugUnless(openHasDeviceId, 'H6', 'WalletRepo.open(deviceId:)'), timeout: _t);
  });

  group('two runs at once against the real relay', () {
    test('two engines on one repo: both end cleanly and the peer has every edit exactly once', () async {
      final (c, _) = await _relayCluster();
      final [a, b] = [c.add(), c.add()];
      final kept = {for (var i = 0; i < 15; i++) _add(a, 'n$i', cents: -100 - i)};
      final second = SyncEngine(c.transport, c.key, appVersion: '1.0.0', now: () => c.clock.t);
      final results = await Future.wait([
        a.sync().then<Object>((r) => r, onError: (Object e) => e),
        second.run(a.repo).then<Object>((r) => r, onError: (Object e) => e),
      ]);
      for (final r in results) {
        expect(r is SyncReport || r is SyncException, isTrue, reason: '$r');
      }
      await c.syncAll(rounds: 3);
      expect(_ids(b).containsAll(kept), isTrue);
      expect(b.repo.transactions().length, 15);
      expect(await invariantViolations(c.transport, c.devs), isEmpty);
    }, timeout: _t);
  });

  group('model equivalence: MemoryTransport vs the real relay', () {
    // The same scripted scenario on both; after every step the relay's state (device ids renamed, times and snapshot
    // ids left out) and each device's visible data must be identical.
    Future<List<String>> script(Cluster c) async {
      final trace = <String>[];
      final names = <String, String>{};
      Future<void> snap(String step) async {
        final s = await c.transport.state();
        final parts = <String>[];
        String nm(String id) => names[id] ?? '?';
        for (final e in s.devices.entries.toList()..sort((x, y) => nm(x.key).compareTo(nm(y.key)))) {
          final acks = e.value.acks.entries.map((a) => '${nm(a.key)}:${a.value}').toList()..sort();
          parts.add('${nm(e.key)}[${e.value.first}-${e.value.last}] acks ${acks.join(',')}');
        }
        String cov(RelaySnapshot? x) =>
            x == null ? '-' : (x.covers.entries.map((e) => '${nm(e.key)}:${e.value}').toList()..sort()).join(',');
        parts.add('snap ${cov(s.snapshot)} prev ${cov(s.previous)}');
        for (final d in c.devs) {
          parts.add('${nm(d.id)}: ${d.repo.transactions().length} rows ${counted(d.repo)} cents salary ${d.repo.settings().salary}');
        }
        trace.add('$step | ${parts.join(' | ')}');
      }

      final [a, b, d] = [c.add(), c.add(), c.add()];
      names[a.id] = 'A';
      names[b.id] = 'B';
      names[d.id] = 'C';
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      for (final x in [a, b, d]) {
        final r = await x.sync();
        trace.add('first ${names[x.id]} sent ${r.sent} read ${r.filesRead} caught ${r.caughtUp} bad ${r.badFiles}');
        await snap('first ${names[x.id]}');
        c.tick();
      }
      _add(b, 'b1', cents: -321);
      d.repo.updateSettings({'salary': 160000});
      await c.syncAll(rounds: 2);
      await snap('edits');
      // C goes away; A and B work for 100 days: snapshots, then the prune that ignores a dead device.
      for (var i = 0; i < 10; i++) {
        c.tick(const Duration(days: 10));
        _add(a, 'a$i', cents: -100 - i);
        await a.sync();
        await b.sync();
        await snap('away $i');
      }
      c.tick(const Duration(seconds: 1));
      final r = await d.sync();
      trace.add('return sent ${r.sent} read ${r.filesRead} caught ${r.caughtUp} bad ${r.badFiles}');
      await c.syncAll(rounds: 3);
      await snap('end');
      return trace;
    }

    test('the scripted scenario gives the same trace on both', () async {
      final clockM = SimClock();
      final mem = Cluster(MemoryTransport(now: () => clockM.t), clockM);
      addTearDown(mem.closeAll);
      final memTrace = await script(mem);
      final (real, _) = await _relayCluster();
      final realTrace = await script(real);
      expect(realTrace.length, memTrace.length);
      for (var i = 0; i < memTrace.length; i++) {
        expect(realTrace[i], memTrace[i], reason: 'step $i');
      }
      expect(memTrace.last, contains('A:'), reason: 'the trace is not empty');
    }, timeout: _t);
  });
}
