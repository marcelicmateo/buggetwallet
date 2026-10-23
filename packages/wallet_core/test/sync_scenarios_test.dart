// Sync edge cases a tester would hit: idempotence, strict per-device order, late joiners, clock skew, wrong key,
// damaged or truncated files, writes during a sync, and import/delete/match races between devices (relay model:
// SyncEngine + MemoryTransport). All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

/// Random ops on a few ids from three nodes, every HLC unique.
List<Op> _randomOps(Random r, int count) {
  final ops = <Op>[];
  final used = <String>{};
  const values = <String, List<Object?>>{
    'tx': ['date', 'amount', 'category', 'deleted', 'matched_to'],
    'goal': ['name', 'saved', 'deleted'],
    'setting': ['value', 'deleted'],
    'rule': ['category'],
    'wish': ['status', 'price'],
  };
  Object? value(String field, Random r) => switch (field) {
        'date' => addDays('2026-01-01', r.nextInt(30)),
        'amount' || 'saved' || 'price' => r.nextInt(10000) - 5000,
        'deleted' => r.nextBool() ? 1 : (r.nextBool() ? true : false),
        'value' => jsonEncode(r.nextInt(100)),
        'matched_to' => r.nextBool() ? null : 'x${r.nextInt(3)}',
        'status' => ['waiting', 'bought', 'skipped'][r.nextInt(3)],
        'name' => 'Synthetic ${r.nextInt(3)}',
        _ => ['Groceries', 'Shopping', null][r.nextInt(3)], // category: nullable
      };
  while (ops.length < count) {
    final entity = values.keys.elementAt(r.nextInt(values.length));
    final fields = values[entity]!.cast<String>();
    final pick = {
      for (final f in fields)
        if (r.nextBool()) f: value(f, r)
    };
    if (pick.isEmpty) continue;
    final h = Hlc(1000 + r.nextInt(50), r.nextInt(3), 'n${r.nextInt(3)}').toString();
    if (!used.add(h)) continue;
    ops.add(Op(entity, '$entity${r.nextInt(4)}', pick, h));
  }
  return ops;
}

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = 1767225600000;
  final devices = <Device>[];
  Device device(String name, {int skew = 0}) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now + skew);
    devices.add(d);
    return d;
  }

  Future<void> syncAll(List<Device> ds) async {
    for (var round = 0; round < 2; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        await d.run();
        d.upload(net);
      }
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-sync-');
    key = VaultKey.generate();
    net = Net();
    now = 1767225600000;
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  group('applying ops', () {
    test('order and duplicates do not matter (property, many random op lists)', () {
      final n = fuzzIterations(150);
      final base = fuzzSeed(77);
      for (var i = 0; i < n; i++) {
        final r = Random(base + i);
        final ops = _randomOps(r, 5 + r.nextInt(30));
        final a = WalletRepo.inMemory(), b = WalletRepo.inMemory(), c = WalletRepo.inMemory();
        a.applyRemote(ops);
        final shuffled = [...ops]..shuffle(r);
        b.applyRemote(shuffled);
        // One op per call, reversed, every op twice.
        for (final op in [...ops.reversed, ...ops]) {
          c.applyRemote([op]);
        }
        expect(dump(b), dump(a), reason: 'seed ${base + i}');
        expect(dump(c), dump(a), reason: 'seed ${base + i}');
        expect(lwwDiff(a, lastWriterWins(ops)), isEmpty, reason: 'seed ${base + i}');
        expect(a.applyRemote(ops), 0, reason: 'seed ${base + i}: applying again changes nothing');
        expect(a.pendingOps(), isEmpty, reason: 'remote ops are never re-exported');
        for (final x in [a, b, c]) {
          x.close();
        }
      }
    });

    test('an op for an unknown entity or field is ignored (forward compatible)', () {
      final r = WalletRepo.inMemory();
      final changed = r.applyRemote([
        Op('future_entity', 'x', const {'a': 1}, const Hlc(5, 0, 'n').toString()),
        Op('goal', 'g1', const {'name': 'Synthetic goal', 'colour': 'blue'}, const Hlc(6, 0, 'n').toString()),
      ]);
      expect(changed, 1);
      expect(r.goals().single.name, 'Synthetic goal');
      r.close();
    });
  });

  group('files', () {
    test('a file applied again (cursor forgotten) changes nothing; with the cursor it is not fetched at all', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      await a.run();
      expect((await b.run()).filesRead, 1);
      final before = dump(b.repo);
      expect((await b.run()).filesRead, 0);
      b.repo.setSyncCursor(a.repo.deviceId, 0);
      final again = await b.run();
      expect(again.filesRead, 1);
      expect(again.received, 0);
      expect(dump(b.repo), before);
    });

    test('a device\'s files apply strictly in seq order: one that cannot be fetched holds up the later ones', () async {
      final a = device('a'), inOrder = device('b'), late = device('c');
      a.repo.importBatch(january);
      final lidl = a.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      for (final c in ['Shopping', 'Eating out', 'Groceries']) {
        now += 1000;
        a.repo.setCategory(lidl, c);
        await a.run();
      }
      await inOrder.run();
      net.relay.failGet(a.repo.deviceId, 3);
      final first = await late.run();
      expect(first.filesRead, 2);
      expect(late.repo.transaction(lidl)!.category, 'Eating out', reason: 'files 1 (the whole state, Shopping) and 2 only');
      expect(first.waiting.single.seq, 3);
      expect(first.waiting.single.reason, isNull);
      expect(first.waiting.single.device, SyncProblem.shortId(a.repo.deviceId));
      expect(first.caughtUp, isFalse);
      final second = await late.run();
      expect((second.filesRead, second.caughtUp, second.waiting.length), (1, true, 0));
      expect(inOrder.repo.transaction(lidl)!.category, 'Groceries');
      expect(dump(late.repo), dump(inOrder.repo));
    });

    test('a device joining late gets everything, and its own edits reach the others', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 0, monthly: 5000, sort: 1);
      await syncAll([a, b]);
      b.repo.updateSettings({'salary': 150000, 'paydayDay': 12});
      now += 5000;
      await syncAll([a, b]);
      final late = device('late');
      await syncAll([late]);
      expect(dump(late.repo), dump(a.repo));
      late.repo.addTransaction(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await syncAll([late, a, b]);
      expect(dump(a.repo), dump(late.repo));
      expect(dump(b.repo), dump(late.repo));
      expect(a.repo.transactions().where((t) => t.manual).length, 1);
    });

    test('writes made while a sync is running are not lost', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      var running = true;
      final run = a.run().whenComplete(() => running = false);
      var written = 0;
      while (running) {
        a.repo.addTransaction(date: '2026-01-2${written % 9}', amount: 100 + written, category: 'Groceries');
        written++;
        await Future<void>.delayed(Duration.zero);
      }
      await run;
      await a.run(); // uploads what was written during the first run
      await b.run();
      expect(written, greaterThan(0));
      expect(b.repo.transactions().where((t) => t.manual).length, written);
      expect(dump(b.repo, clocks: false), dump(a.repo, clocks: false));
    });

    test('an unreachable relay is a SyncException and keeps the outbox; the next run sends it', () async {
      final a = device('a');
      await a.run();
      a.repo.updateSettings({'salary': 1});
      net.relay.offline = true;
      await expectLater(a.run(), throwsA(isA<SyncException>()));
      expect(a.repo.pendingOps().length, 1);
      net.relay.offline = false;
      expect((await a.run()).sent, 1);
      expect(a.repo.pendingOps(), isEmpty);
    });

    test('the first run on a relay uploads the whole wallet once (the migration from a folder); later runs only changes', () async {
      final a = device('a');
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      a.repo.markExported(a.repo.pendingOps().last.$1); // as if a folder sync had sent it all already
      final first = await a.run();
      expect(first.sent, a.repo.snapshotOps().length);
      a.repo.updateSettings({'rent': 1});
      expect((await a.run()).sent, 1);
      final b = device('b');
      await b.run();
      expect(dump(b.repo), dump(a.repo));
    });

    test('a relay that lost this device\'s files (new or wiped) gets its whole state again', () async {
      final a = device('a');
      a.repo.importBatch(january);
      await a.run();
      a.repo.updateSettings({'rent': 1});
      await a.run();
      final fresh = Net();
      a.net = fresh;
      final rep = await a.run();
      expect(rep.sent, a.repo.snapshotOps().length);
      final b = Device('b', null, key, () => now, net: fresh);
      devices.add(b);
      await b.run();
      expect(dump(b.repo), dump(a.repo));
    });

    test('a new device replays the files rather than trust a snapshot written by an older schema', () async {
      final a = device('a'), b = device('b');
      await b.run(); // b is known to the relay (its ack keeps a's files from being pruned) but has applied nothing
      a.repo.importBatch(january);
      await a.run();
      // A snapshot an older build wrote: it claims to cover a's file 1 but holds nothing this schema needs.
      await net.relay.putSnapshot('s1-0-aa', {a.repo.deviceId: 1}, await seal(backupPayload(const []), key));
      final rep = await b.run();
      expect(rep.filesRead, 1);
      expect(b.repo.transactions().length, january.transactions.length);
      expect(net.relay.calls['getSnapshot'], isNull);
    });
  });

  group('wrong key', () {
    test('typed key text: typos are refused with VaultException, never another error or a different key', () async {
      final r = Random(fuzzSeed(42));
      const noise = ['', ' ', '-', '0', '1', '8', '9', 'O', 'I', 'l', 'a', 'z', '=', 'Š', '🙂', '\n', 'BW1', 'bw1-'];
      for (var i = 0; i < fuzzIterations(200); i++) {
        final k = VaultKey.generate();
        final text = await k.toText();
        final chars = text.split('');
        final p = 4 + r.nextInt(chars.length - 4);
        final mutated = switch (r.nextInt(5)) {
          0 => ([...chars]..removeAt(p)).join(),
          1 => ([...chars]..insert(p, noise[r.nextInt(noise.length)])).join(),
          2 => ([...chars]..[p] = noise[r.nextInt(noise.length)]).join(),
          3 => text.substring(0, r.nextInt(text.length)),
          _ => ([...chars]..[p] = chars[p == chars.length - 1 ? p - 1 : p + 1]).join(),
        };
        try {
          final back = await VaultKey.parse(mutated);
          expect(back.bytes, k.bytes, reason: 'seed case $i: "$mutated" parsed to a different key');
        } on VaultException {
          // refused, fine
        }
      }
      // Case, spaces, dashes and line breaks do not matter.
      final k = VaultKey.generate();
      final text = await k.toText();
      expect((await VaultKey.parse(' ${text.toLowerCase().replaceAll('-', '\n')} ')).bytes, k.bytes);
    });

    test('a device with another wallet\'s key on the same relay: its files are refused both ways as badKey', () async {
      final a = device('a');
      a.repo.importBatch(january);
      await a.run();
      final b = Device('b', null, VaultKey.generate(), () => now); // the same relay, another wallet's key
      devices.add(b);
      b.repo.updateSettings({'salary': 99});
      final rb = await b.run();
      expect(rb.waiting.single.reason, SyncProblemReason.badKey);
      expect(rb.caughtUp, isFalse);
      expect(b.repo.transactions(), isEmpty);
      final ra = await a.run();
      expect(ra.problems.single.reason, SyncProblemReason.badKey);
      expect(a.repo.settings().salary, isNot(99));
    });

    test('a file sealed with another key is rejected and nothing is applied', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'salary': 5});
      await a.run();
      final clear = await unseal(net.files['d/${a.repo.deviceId}/1']!, key);
      net.relay.replace(a.repo.deviceId, 1, await seal(clear, VaultKey.generate()));
      final before = dump(b.repo);
      final rep = await b.run();
      expect(rep.badFiles, 1);
      expect(rep.filesRead, 0);
      expect(dump(b.repo), before);
      expect(b.repo.syncCursors(), isEmpty);
    });
  });

  group('damaged files', () {
    Future<(Device, Device, Uint8List)> setup() async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      a.repo.updateSettings({'salary': 150000});
      await a.run();
      return (a, b, net.files['d/${a.repo.deviceId}/1']!);
    }

    test('truncated or bit-flipped files are rejected without changing anything; the repaired file then applies', () async {
      final (a, b, good) = await setup();
      final r = Random(fuzzSeed(5));
      final cases = <Uint8List>[
        Uint8List(0),
        Uint8List.sublistView(good, 0, 4),
        Uint8List.sublistView(good, 0, 44),
        for (var i = 0; i < fuzzIterations(25); i++) Uint8List.sublistView(good, 0, r.nextInt(good.length)),
        for (var i = 0; i < fuzzIterations(25); i++) Uint8List.fromList(good)..[r.nextInt(good.length)] ^= 1 << r.nextInt(8),
      ];
      final before = dump(b.repo);
      for (final (i, bad) in cases.indexed) {
        net.relay.replace(a.repo.deviceId, 1, bad);
        final rep = await b.run(); // skipped and counted, not thrown
        expect(rep.badFiles, 1, reason: 'case $i (${bad.length} bytes) was accepted');
        expect(rep.filesRead, 0, reason: 'case $i');
        expect(dump(b.repo), before, reason: 'case $i');
        expect(b.repo.syncCursors(), isEmpty, reason: 'case $i');
      }
      net.relay.replace(a.repo.deviceId, 1, good);
      final rep = await b.run();
      expect(rep.filesRead, 1);
      expect(dump(b.repo, clocks: false), dump(a.repo, clocks: false));
    });

    test('a correctly sealed file with broken contents changes nothing (no partial writes)', () async {
      final (a, b, _) = await setup();
      final good = Op('setting', 'salary', const {'value': '1'}, Hlc(now + 10, 0, 'zz').toString()).toJson();
      final payloads = <Object>[
        'not json',
        '{"e":"tx"}',
        jsonEncode([good, 'not an op']),
        jsonEncode([
          good,
          {
            'e': 'setting',
            'id': 'rent',
            'f': {'value': '2'},
            'h': 'not-a-clock'
          }
        ]),
        jsonEncode([
          good,
          {'e': 'setting', 'id': 'rent', 'f': 'not a map', 'h': const Hlc(1, 0, 'zz').toString()}
        ]),
      ];
      final before = dump(b.repo);
      for (final p in payloads) {
        net.relay.replace(a.repo.deviceId, 1, await seal(utf8.encode(p as String), key));
        expect((await b.run()).badFiles, 1, reason: p);
        expect(dump(b.repo), before, reason: p);
        expect(b.repo.settings().salary, 0);
      }
    });

    test('a damaged file the snapshot covers: the device starts from the snapshot and goes on after it', () async {
      final (a, b, _) = await setup();
      expect((await b.run()).filesRead, 1);
      a.repo.updateSettings({'rent': 2});
      await a.run();
      a.repo.updateSettings({'loan': 3});
      await a.run();
      // A snapshot from a device that read file 2 before it was damaged on the relay.
      await net.relay.putSnapshot('s${WalletRepo.schemaVersion}-0-aa', {a.repo.deviceId: 2, b.repo.deviceId: 0},
          await seal(backupPayload(a.repo.snapshotOps()), key));
      net.relay.corrupt(a.repo.deviceId, 2);
      final rep = await b.run();
      expect((rep.caughtUp, rep.waiting.length, rep.problems.length), (true, 0, 0));
      expect(rep.filesRead, 2, reason: 'the snapshot, then file 3');
      expect((b.repo.settings().rent, b.repo.settings().loan), (2, 3));
      expect(b.repo.syncCursors()[a.repo.deviceId], 3);
    });

    test('one damaged file does not stop files from other devices being applied', () async {
      final (a, b, good) = await setup();
      final c = device('c');
      c.repo.updateSettings({'rent': 40000});
      await c.run();
      net.relay.replace(a.repo.deviceId, 1, Uint8List.sublistView(good, 0, good.length ~/ 2)); // a's file is damaged
      final rep = await b.run();
      expect(rep.badFiles, 1);
      expect(b.repo.settings().rent, 40000);
      // The repaired file applies on the next run.
      net.relay.replace(a.repo.deviceId, 1, good);
      final again = await b.run();
      expect(again.badFiles, 0);
      expect(b.repo.settings().salary, 150000);
    });
  });

  group('clocks', () {
    test('a device whose clock is an hour behind still wins with an edit made after it synced (causality)', () async {
      final a = device('a'), b = device('b', skew: -3600000);
      a.repo.importBatch(january);
      final lidl = a.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      a.repo.setCategory(lidl, 'Shopping');
      await syncAll([a, b]);
      now += 1000; // real time moves on; b's wall clock is still an hour behind a's edit
      b.repo.setCategory(lidl, 'Eating out');
      await syncAll([a, b]);
      expect(a.repo.transaction(lidl)!.category, 'Eating out');
      expect(b.repo.transaction(lidl)!.category, 'Eating out');
    });

    test('a device a year in the future does not freeze the others: their later edits still win', () async {
      final future = device('future', skew: 365 * 86400000), b = device('b');
      future.repo.updateSettings({'salary': 1000});
      await syncAll([future, b]);
      expect(b.repo.clock.last.millis, greaterThanOrEqualTo(now + 365 * 86400000));
      for (var i = 0; i < 5; i++) {
        now += 10;
        b.repo.updateSettings({'salary': 2000 + i});
        await syncAll([b, future]);
        expect(future.repo.settings().salary, 2000 + i);
      }
    });

    test('HLCs written by the repo strictly increase, also across remote receives and a clock going backwards', () {
      var t = 5000000;
      final r = WalletRepo.inMemory(now: () => t);
      final seen = <String>[];
      for (var i = 0; i < 50; i++) {
        t += [-1000, 0, 3, -7, 2000][i % 5];
        if (i % 7 == 0) {
          r.applyRemote([
            Op('setting', 'x$i', const {'value': '1'}, Hlc(t + 500, 9, 'other').toString())
          ]);
        }
        r.updateSettings({'k$i': i});
        seen.add(r.pendingOps().last.$2.hlc);
      }
      expect([...seen]..sort(), seen);
      expect(seen.toSet().length, seen.length);
      r.close();
    });

    test('HLC order stays correct past 99999 events in one millisecond', () {
      expect(const Hlc(1, 100000, 'a').compareTo(const Hlc(1, 99999, 'a')), greaterThan(0));
      // A peer's op far ahead of this device's wall clock, then a later local edit of the same setting.
      final r = WalletRepo.inMemory(now: () => 0);
      r.applyRemote([
        Op('setting', 'salary', const {'value': '1'}, const Hlc(9000000000000, 99998, 'peer').toString())
      ]);
      r.updateSettings({'salary': 2});
      final local = r.pendingOps().last.$2.hlc;
      r.close();
      expect(local.compareTo(const Hlc(9000000000000, 99998, 'peer').toString()), greaterThan(0), reason: local);
    });

    test('the clock never writes a counter past 5 digits, so strings keep sorting right on older versions', () {
      final c = HlcClock('me', now: () => 0, last: const Hlc(5000, 99997, 'me').toString());
      final seen = [for (var i = 0; i < 5; i++) c.tick().toString()];
      expect(seen, [
        '000000000005000:99998:me',
        '000000000005000:99999:me',
        '000000000005001:00000:me',
        '000000000005001:00001:me',
        '000000000005001:00002:me'
      ]);
      expect([...seen]..sort(), seen);
      c.receive(const Hlc(9000, 99999, 'peer'));
      expect(c.last.toString(), '000000000009001:00000:me');
      // A counter wider than 5 digits (no version writes one) still parses, compares by value and is overtaken.
      c.receive(Hlc.parse('000000000009001:123456:peer'));
      expect(c.last.compareTo(Hlc.parse('000000000009001:123456:peer')), greaterThan(0));
      expect(c.last.toString(), '000000000009002:00000:me');
    });

    test('HLC strings compare by value: old 5-digit strings, and wider counters, in any mix', () {
      expect(Hlc.compareStrings('000000000000001:00002:a', '000000000000001:00010:a'), lessThan(0));
      expect(Hlc.compareStrings('000000000000001:100000:a', '000000000000001:99999:a'), greaterThan(0));
      expect(Hlc.compareStrings('000000000000002:00000:a', '000000000000001:99999:z'), greaterThan(0));
      expect(Hlc.compareStrings('000000000000001:00001:b', '000000000000001:00001:a'), greaterThan(0));
      expect(Hlc.compareStrings('000000000000001:00001:a', '000000000000001:00001:a'), 0);
      // A stored clock with a wide counter is not overwritten by an older op.
      final r = WalletRepo.inMemory();
      r.applyRemote([
        const Op('setting', 'salary', {'value': '1'}, '000000000000001:100000:peer')
      ]);
      r.applyRemote([
        const Op('setting', 'salary', {'value': '2'}, '000000000000001:99999:peer')
      ]);
      expect(r.settings().salary, 1);
      r.close();
    });
  });

  group('races between devices', () {
    test('re-importing on another device does not resurrect a transaction deleted elsewhere', () async {
      final a = device('a'), b = device('b'), c = device('c');
      a.repo.importBatch(january);
      await syncAll([a, b]);
      final lidl = b.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      now += 1000;
      b.repo.deleteTransaction(lidl);
      await syncAll([b, a]);
      now += 1000;
      c.repo.importBatch(january); // c imports the same export before it has synced
      await syncAll([a, b, c]);
      expect(a.repo.transaction(lidl)!.deleted, isTrue);
      expect(c.repo.transaction(lidl)!.deleted, isTrue);
    });

    test('import ops never carry the deleted field (only deletes write it)', () {
      final r = WalletRepo.inMemory();
      r.importBatch(january);
      expect(r.pendingOps().where((o) => o.$2.fields.containsKey('deleted')), isEmpty);
      expect(r.transactions().length, january.transactions.length, reason: 'new rows are live by default');
      r.close();
    });

    test('the same export imported on two devices before syncing gives one copy of each row', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      b.repo.importBatch(january);
      await syncAll([a, b]);
      expect(a.repo.transactions().length, january.transactions.length);
      expect(dump(a.repo), dump(b.repo));
    });

    test('a category set on one device survives the other device importing the same rows later', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(january);
      final lidl = a.repo.transactions().firstWhere((t) => t.amount == -2340).id;
      a.repo.setCategory(lidl, 'Eating out');
      now += 1000;
      b.repo.importBatch(january);
      await syncAll([a, b]);
      expect(b.repo.transaction(lidl)!.category, 'Eating out');
      expect(a.repo.transaction(lidl)!.category, 'Eating out');
    });

    for (final phoneFirst in [true, false]) {
      test(
          'a hand-added expense added offline, then the bank row imported on another device: matched once, in either '
          'sync order (${phoneFirst ? 'phone' : 'laptop'} syncs first)', () async {
        final phone = device('phone'), laptop = device('laptop');
        phone.repo.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic lunch');
        now += 1000; // later, the laptop imports the export before the phone's entry arrived
        laptop.repo.importBatch(january);
        await syncAll(phoneFirst ? [phone, laptop] : [laptop, phone]);
        for (final d in [phone, laptop]) {
          final live = d.repo.transactions().where((t) => t.amount == -2340).toList();
          expect(live.length, 1, reason: '${d.name}: the manual entry and the bank row are one expense');
          expect(live.single.manual, isFalse, reason: d.name);
          expect(d.repo.categorizer().categoryOf(live.single), 'Eating out', reason: '${d.name}: the bank row keeps the manual category');
        }
        await syncAll([phone, laptop]);
        expect(dump(phone.repo, clocks: false), dump(laptop.repo, clocks: false));
        expect(phone.repo.pendingOps(), isEmpty);
      });
    }

    test('an expense added by hand when the bank row is already in the wallet (synced or not) is a separate expense', () async {
      final phone = device('phone'), laptop = device('laptop');
      laptop.repo.importBatch(january); // Saturday's synthetic card payment of 23.40
      await syncAll([laptop, phone]);
      now += 1000;
      phone.repo.addTransaction(date: '2026-01-19', amount: 2340, category: 'Eating out', note: 'synthetic cash'); // Monday, cash
      now += 1000;
      laptop.repo.addTransaction(date: '2026-01-18', amount: 2340, category: 'Shopping', note: 'synthetic cash'); // also cash
      await syncAll([phone, laptop]);
      await syncAll([laptop, phone]);
      for (final d in [phone, laptop]) {
        final rows = d.repo.transactions(includeHidden: true).where((t) => t.amount == -2340).toList();
        expect(rows.where((t) => t.matchedTo != null), isEmpty, reason: d.name);
        expect(rows.where((t) => t.live).length, 3, reason: '${d.name}: card payment and both cash expenses count');
      }
      expect(dump(phone.repo), dump(laptop.repo));
    });

    test('two devices each add the same expense by hand, one bank row: one pair matched, same on both devices', () async {
      final phone = device('phone'), laptop = device('laptop');
      phone.repo.addTransaction(date: '2026-01-16', amount: 2340, category: 'Eating out', note: 'synthetic');
      laptop.repo.addTransaction(date: '2026-01-18', amount: 2340, category: 'Shopping', note: 'synthetic');
      now += 1000; // the bank row comes after both entries (rule: only a later bank row replaces an entry)
      laptop.repo.importBatch(january);
      for (var i = 0; i < 3; i++) {
        await syncAll([phone, laptop]);
      }
      for (final d in [phone, laptop]) {
        final rows = d.repo.transactions(includeHidden: true).where((t) => t.amount == -2340).toList();
        expect(rows.length, 3);
        expect(rows.where((t) => t.manual && t.matchedTo != null).length, 1, reason: d.name);
        expect(rows.where((t) => t.live).length, 2, reason: '${d.name}: the bank row and the unmatched entry');
      }
      expect(dump(phone.repo), dump(laptop.repo));
      expect(phone.repo.pendingOps(), isEmpty);
    });
  });

  group('a hand-added expense and bank rows imported on another device first', () {
    for (final phoneFirst in [true, false]) {
      test(
          'the laptop imports in the morning, the phone (not synced) adds the same expense in the evening: one expense on '
          'both devices (${phoneFirst ? 'phone' : 'laptop'} syncs first)', () async {
        final phone = device('phone'), laptop = device('laptop');
        laptop.repo.importBatch(january); // 09:00: holds the synthetic 23.40 card payment of 2026-01-17
        now += 10 * 3600000; // 19:00, the phone has not synced since
        final m = phone.repo.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic lunch');
        await syncAll(phoneFirst ? [phone, laptop] : [laptop, phone]);
        for (final d in [phone, laptop]) {
          final live = d.repo.transactions().where((t) => t.amount == -2340).toList();
          expect(live.length, 1, reason: '${d.name}: counted once');
          expect(live.single.manual, isFalse, reason: d.name);
          expect(d.repo.transaction(m)!.matchedTo, live.single.id, reason: d.name);
          expect(d.repo.categorizer().categoryOf(live.single), 'Eating out', reason: d.name);
        }
        await syncAll([phone, laptop]);
        expect(dump(phone.repo), dump(laptop.repo));
        expect(phone.repo.pendingOps(), isEmpty);
        expect(laptop.repo.pendingOps(), isEmpty);
      });
    }

    test('the phone already had Saturday\'s card coffee: a Monday cash coffee stays separate, also after later imports', () async {
      final phone = device('phone'), laptop = device('laptop');
      laptop.repo.importBatch(ImportBatch(source: 'pbz', transactions: [bankRow('2026-01-17', -240, 'POS plaćanje', 'POS EXAMPLE CAFE')]));
      await syncAll([laptop, phone]);
      now += 3600000;
      // The laptop imports the next statement (other rows) before the phone's entry arrives.
      laptop.repo.importBatch(ImportBatch(source: 'pbz', transactions: [bankRow('2026-01-18', -5000, 'POS plaćanje', 'POS EXAMPLE SHOP')]));
      now += 3600000;
      final cash = phone.repo.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out', note: 'synthetic cash coffee');
      await syncAll([phone, laptop]);
      await syncAll([laptop, phone]);
      for (final d in [phone, laptop]) {
        expect(d.repo.transaction(cash)!.matchedTo, isNull, reason: d.name);
        expect(d.repo.transactions().where((t) => t.amount == -240).length, 2, reason: '${d.name}: two coffees');
      }
      expect(dump(phone.repo), dump(laptop.repo));
    });
  });

  group('matching while a sync file never arrives (strict order: the match never comes without its rows)', () {
    int out(Device d) {
      final cz = d.repo.categorizer();
      return monthSummary(d.repo.transactions().map(cz.categorize).toList(), '2026-01', currency: 'EUR').out;
    }

    test(
        'the rows file cannot be fetched: the phone applies neither it nor the later match file; the entry counts once, '
        'then the row once', () async {
      final phone = device('phone'), laptop = device('laptop');
      final m = phone.repo.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic lunch');
      await phone.run();
      now += 1000;
      laptop.repo.importBatch(january);
      final b = laptop.repo.transactions().singleWhere((t) => t.amount == -2340).id;
      await laptop.run(); // the rows file (its whole state), then reads the entry and matches it
      expect(laptop.repo.transaction(m)!.matchedTo, b);
      await laptop.run(); // the match file
      expect(net.files.keys.where((k) => k.startsWith('d/${laptop.repo.deviceId}/')), hasLength(2));
      net.relay.failGet(laptop.repo.deviceId, 1);
      final rep = await phone.run();
      expect((rep.filesRead, rep.caughtUp, rep.waiting.single.seq), (0, false, 1));
      expect(phone.repo.transaction(m)!.matchedTo, isNull, reason: 'the match file waits behind the rows file');
      expect(phone.repo.pendingOps(), isEmpty, reason: 'no writes');
      expect(phone.repo.transactions().where((t) => t.amount == -2340).map((t) => t.id), [m], reason: 'counted once');
      expect(out(phone), 2340);

      final again = await phone.run(); // it arrives
      expect((again.filesRead, again.caughtUp), (2, true));
      expect(phone.repo.transactions().where((t) => t.amount == -2340).map((t) => t.id), [b], reason: 'the row, once');
      expect(phone.repo.transaction(m)!.live, isFalse);
      expect(out(phone), out(laptop));
      expect(phone.repo.pendingOps(), isEmpty);
    });

    for (final damaged in [true, false]) {
      test(
          'the file with the bank row is ${damaged ? 'damaged' : 'not fetchable'} for the phone for good: the phone keeps '
          'its entry, does not match on its own, and repeated syncs write nothing new', () async {
        final phone = device('phone'), laptop = device('laptop');
        List<String> files() => net.files.keys.where((k) => k.startsWith('d/')).toList()..sort();
        phone.repo.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic lunch');
        now += 1000;
        laptop.repo.importBatch(january);
        laptop.repo.setCategory(laptop.repo.transactions().singleWhere((t) => t.amount == -2340).id, 'Groceries');
        await laptop.run();
        final rows = laptop.repo.deviceId;
        final good = net.files['d/$rows/1']!;
        if (damaged) net.relay.replace(rows, 1, Uint8List.sublistView(good, 0, good.length ~/ 2));
        var repaired = false;

        Future<void> round() async {
          for (final d in [phone, laptop]) {
            if (d == phone && !damaged && !repaired) net.relay.failGet(rows, 1);
            now += 120000; // the 2-minute sync
            final rep = await d.run();
            if (d == phone && !repaired) {
              expect(rep.caughtUp, isFalse);
              expect(rep.waiting.single.reason, damaged ? isNotNull : isNull);
            }
          }
        }

        for (var i = 0; i < 3; i++) {
          await round();
        }
        final m = phone.repo.transactions(includeHidden: true).singleWhere((t) => t.manual);
        final bank = laptop.repo.transaction(m.id)!.matchedTo;
        expect(bank, isNotNull, reason: 'the laptop holds the bank row and matched the entry');
        expect(phone.repo.transaction(m.id)!.matchedTo, isNull, reason: 'the phone got neither the row nor the match');
        expect(phone.repo.transaction(m.id)!.live, isTrue, reason: 'the entry still counts on the phone');
        final settled = files();
        for (var i = 0; i < 5; i++) {
          await round();
        }
        expect(files(), settled, reason: 'no new sync files: nobody rewrites the match');
        expect(phone.repo.pendingOps(), isEmpty);
        expect(laptop.repo.pendingOps(), isEmpty);

        // The file is repaired (or can be fetched again): one expense on both devices, same state.
        repaired = true;
        if (damaged) net.relay.replace(rows, 1, good);
        await round();
        await round();
        for (final d in [phone, laptop]) {
          final live = d.repo.transactions().where((t) => t.amount == -2340).toList();
          expect(live.map((t) => t.id), [bank], reason: d.name);
        }
        expect(dump(phone.repo, clocks: false), dump(laptop.repo, clocks: false));
      });
    }
  });
}
