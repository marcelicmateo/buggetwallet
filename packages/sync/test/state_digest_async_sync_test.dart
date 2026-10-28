// M2: the engine reads the state digest off the UI isolate (`WalletRepo.stateDigestAsync`) for a device on a database
// file (the app's case). A write landing while the digest is read must never be recorded under the earlier vector.
// All data is SYNTHETIC.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/engine_spec_sim.dart';
import '../../wallet_core/test/support/synthetic.dart';

void main() {
  late Sim sim;
  late Directory dir;
  setUp(() {
    sim = Sim();
    dir = Directory.systemTemp.createTempSync('bw_digest_engine_');
  });
  tearDown(() {
    sim.closeAll();
    dir.deleteSync(recursive: true);
  });

  /// A device on an encrypted database file, like the app's.
  Dev fileDevice(String name) {
    final repo = WalletRepo.open('${dir.path}/$name.db',
        dbKey: List<int>.generate(32, (i) => (i * 5 + 1) & 0xff), now: () => sim.clock.ms); // synthetic key
    final d = Dev(repo, SyncEngine(sim.transport, sim.key, appVersion: '1.0.0', now: () => sim.clock.t));
    sim.all.add(d);
    return d;
  }

  List<LogEvent> capture(void Function(LogEvent e) on) {
    final events = <LogEvent>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) {
      if (r.object case final LogEvent e) {
        events.add(e);
        on(e);
      }
    });
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = was;
    });
    return events;
  }

  Future<void> rounds(List<Dev> ds, int n) async {
    for (var i = 0; i < n; i++) {
      for (final d in ds) {
        await d.sync();
        sim.tick(const Duration(seconds: 5));
      }
    }
  }

  test('file devices: digests read in another isolate match the peers\' and settle with no repair', () async {
    final events = capture((_) {});
    final a = fileDevice('a'), b = fileDevice('b');
    a.repo
      ..importBatch(january)
      ..updateSettings({'salary': 150000, 'rent': 50000});
    await rounds([a, b], 3);
    expect(b.repo.stateDigest(), a.repo.stateDigest());
    expect(events.where((e) => e.event == 'repo.stateDigest' && e.fields['isolate'] == true), isNotEmpty);
    expect(events.where((e) => e.event == 'sync.digest.compare' && (e.fields['matched'] as int) > 0), isNotEmpty);
    expect(events.map((e) => e.event), isNot(anyOf(contains('sync.digest.mismatch'), contains('sync.repair.start'))));
  });

  test('a write while the digest is read: nothing recorded for the stale state, a later run sends it, no repair', () async {
    final a = fileDevice('a');
    final b = sim.device();
    var writes = 0;
    final events = capture((e) {
      // The cue is logged just before the isolate starts: the owner edits right after (a microtask runs before the
      // isolate's answer, which comes as a later event; a write inside the log listener would log re-entrantly).
      if (e.event != 'repo.stateDigest.isolate' || writes >= 3) return;
      writes++;
      scheduleMicrotask(() {
        sim.tick(const Duration(seconds: 1));
        a.repo.updateSettings({'rent': 50000 + writes});
      });
    });
    a.repo
      ..importBatch(january)
      ..updateSettings({'salary': 150000});
    await rounds([a, b], 6);
    expect(writes, 3);
    expect(events.where((e) => e.event == 'sync.digest.stale'), isNotEmpty);
    expect(events.where((e) => e.event == 'repo.stateDigest' && e.fields['stale'] == true), isNotEmpty);
    expect(b.repo.settings().rent, 50003);
    expect(b.repo.stateDigest(), a.repo.stateDigest());
    expect(events.where((e) => e.event == 'sync.digest.compare' && (e.fields['matched'] as int) > 0), isNotEmpty,
        reason: 'the digest went out once the device was quiet, and matched');
    expect(events.map((e) => e.event), isNot(anyOf(contains('sync.digest.mismatch'), contains('sync.repair.start'))));
  });
}
