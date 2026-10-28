// Stage V2 spec tests: device state digest, "devices disagree" repair, no ping-pong, and a peer of another wallet key
// (V1 otherKey). Written from docs/context/STAGE_V_PLAN.md only (not from the implementation). All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/sim.dart';

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  final devices = <Device>[];
  const now = 1767225600000;

  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  /// Runs every device [rounds] times; returns every report in order.
  Future<List<SyncReport>> settle(List<Device> ds, {int rounds = 8}) async {
    final out = <SyncReport>[];
    for (var round = 0; round < rounds; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        out.add(await d.run());
      }
    }
    return out;
  }

  Future<Set<String>> digests(List<Device> ds) async => {for (final d in ds) d.repo.stateDigest()};

  Set<SyncProblemReason> reasons(Iterable<SyncReport> rs) => {
        for (final r in rs) ...[...r.problems.map((p) => p.reason), ...r.waiting.map((w) => w.reason).whereType<SyncProblemReason>()],
      };

  /// Bypasses `_write`: no clock, no op (what a bug or a damaged file would do).
  void corrupt(Device d, String sql, List<Object?> args) => d.repo.db.execute(sql, args);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-vdigest-');
    key = VaultKey.generate();
    net = Net();
  });
  tearDown(() {
    for (final d in devices) {
      d.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  group('stateDigest', () {
    test('is lowercase hex SHA-256 (64 chars)', () async {
      final d = device('a');
      d.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      expect(d.repo.stateDigest(), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('two devices that synced the same data have equal digests', () async {
      final a = device('a'), b = device('b');
      a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      b.repo.addTransaction(date: '2026-01-06', amount: -300, category: 'Shopping');
      b.repo.updateSettings({'salary': 150000});
      await settle([a, b]);
      expect((await digests([a, b])).length, 1);
      expect(a.repo.transactions().length, 2);
    });

    test('the same state applied in a different order gives the same digest', () async {
      final ops = [
        for (var i = 0; i < 12; i++)
          Op(
              'tx',
              'synthetic$i',
              {
                'date': '2026-01-${(i + 1).toString().padLeft(2, '0')}',
                'amount': -100 * (i + 1),
                'category': 'Groceries',
              },
              Hlc(1000 + i, 0, 'n${i % 3}').toString()),
        Op('tx', 'synthetic3', {'deleted': 1}, const Hlc(2000, 0, 'n1').toString()),
        Op('tx', 'synthetic4', {'category': 'Shopping'}, const Hlc(2001, 0, 'n2').toString()),
      ];
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory(), c = WalletRepo.inMemory();
      a.applyRemote(ops);
      b.applyRemote(ops.reversed.toList());
      c.applyRemote([...ops]..shuffle(Random(5)));
      final da = a.stateDigest();
      expect(b.stateDigest(), da);
      expect(c.stateDigest(), da);
      a.close();
      b.close();
      c.close();
    });

    test('device-local values do not change it', () async {
      final a = device('a');
      a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      final before = a.repo.stateDigest();
      a.repo.setLocalValue('someLocalThing', 'x');
      expect(a.repo.stateDigest(), before);
    });

    test('changing one synced value, one clock, or deleting a row changes it', () async {
      final a = device('a');
      final id = a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      final d0 = a.repo.stateDigest();
      a.repo.setCategory(id, 'Shopping');
      final d1 = a.repo.stateDigest();
      expect(d1, isNot(d0));
      a.repo.updateSettings({'salary': 150000});
      final d2 = a.repo.stateDigest();
      expect(d2, isNot(d1));
      a.repo.deleteTransaction(id);
      expect(a.repo.stateDigest(), isNot(d2), reason: 'deleted rows are part of the state');
    });

    test('a corrupted value (no clock change) changes it once the next data change lands (cached per dataVersion)', () async {
      // b is a's clean twin: same synced data. a's value is changed behind the change log; then the same new row
      // reaches both (a data change on each), and only the corruption tells them apart.
      final a = device('a'), b = device('b');
      final id = a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      await settle([a, b]);
      expect((await digests([a, b])).length, 1, reason: 'twins without corruption match');
      final before = a.repo.stateDigest();
      final stored = a.repo.db.select('SELECT amount FROM tx WHERE id = ?', [id]).single['amount'] as int;
      corrupt(a, 'UPDATE tx SET amount = ? WHERE id = ?', [stored - 250, id]);
      expect(a.repo.stateDigest(), before, reason: 'no data version change yet: the cached digest');
      // The same op on both (same id, fields and clock), applied as a peer's: a data change, identical on the twins.
      final op = Op('tx', 'synthetic-twin', {'date': '2026-01-06', 'amount': -300, 'description': 'SYNTHETIC', 'deleted': 0},
          const Hlc(now + 5000, 0, 'other').toString());
      a.repo.applyRemote([op], match: false);
      b.repo.applyRemote([op], match: false);
      expect(a.repo.stateDigest(), isNot(b.repo.stateDigest()), reason: 'the corrupted value is in the digest');
      corrupt(a, 'UPDATE tx SET amount = ? WHERE id = ?', [stored, id]); // healed by hand
      final op2 = Op('tx', 'synthetic-twin2', {'date': '2026-01-07', 'amount': -10, 'description': 'SYNTHETIC', 'deleted': 0},
          const Hlc(now + 6000, 0, 'other').toString());
      a.repo.applyRemote([op2], match: false);
      b.repo.applyRemote([op2], match: false);
      expect(a.repo.stateDigest(), b.repo.stateDigest(), reason: 'the same state again: the same digest');
    });
  });

  group('divergence is detected and repaired', () {
    test('a corrupted row on one device: devices end with equal digests and last-writer-wins values', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      a.repo.addTransaction(date: '2026-01-06', amount: -300, category: 'Shopping');
      await settle([a, b]);
      expect((await digests([a, b])).length, 1);
      // addTransaction stores an expense of -1250 as 1250 (sign by category), so read what was stored.
      final original = a.repo.transactions().firstWhere((t) => t.id == id).amount;

      // -1000 sorts below the original as JSON text ("-" before digits), so the equal-clock tie-break keeps the original.
      corrupt(a, 'UPDATE tx SET amount = ? WHERE id = ?', [-1000, id]);
      // stateDigest is cached per dataVersion (known limit): a change behind the change log shows after the next data change.
      a.repo.addTransaction(date: '2026-01-07', amount: -50, category: 'Groceries'); // new data: a digest is due
      expect((await digests([a, b])).length, 2);
      await settle([a, b, a, b]);

      expect((await digests([a, b])).length, 1, reason: 'repaired');
      final want = lastWriterWins(await opsInNet(net, key));
      expect(lwwDiff(a.repo, want), isEmpty);
      expect(lwwDiff(b.repo, want), isEmpty);
      expect(a.repo.transactions().firstWhere((t) => t.id == id).amount, original);
    });

    test('the same clock with a different value converges to the same value on both (the higher canonical JSON)', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries', note: 'aaa');
      await settle([a, b]);
      corrupt(a, 'UPDATE tx SET note = ? WHERE id = ?', ['zzz', id]);
      a.repo.addTransaction(date: '2026-01-07', amount: -50, category: 'Groceries');
      await settle([a, b, a, b]);
      String note(Device d) => d.repo.db.select('SELECT note FROM tx WHERE id = ?', [id]).single['note'] as String;
      expect(note(a), note(b));
      expect(note(a), 'zzz', reason: '"zzz" sorts above "aaa" as JSON');
      expect((await digests([a, b])).length, 1);
    });

    test('three devices: one corrupted, all three end equal', () async {
      final a = device('a'), b = device('b'), c = device('c');
      final id = a.repo.addTransaction(date: '2026-01-05', amount: -2500, category: 'Groceries');
      b.repo.addTransaction(date: '2026-01-06', amount: -300, category: 'Shopping');
      await settle([a, b, c]);
      expect((await digests([a, b, c])).length, 1);
      corrupt(c, 'UPDATE tx SET amount = ? WHERE id = ?', [-2000, id]); // JSON text below the original
      c.repo.addTransaction(date: '2026-01-08', amount: -75, category: 'Groceries');
      await settle([a, b, c, a, b, c]);
      expect((await digests([a, b, c])).length, 1);
      final want = lastWriterWins(await opsInNet(net, key));
      for (final d in [a, b, c]) {
        expect(lwwDiff(d.repo, want), isEmpty);
      }
    });

    test('a repair deletes nothing: every row is still there afterwards', () async {
      final a = device('a'), b = device('b');
      final ids = [
        for (var i = 0; i < 5; i++) a.repo.addTransaction(date: '2026-01-0${i + 1}', amount: -100 * (i + 1), category: 'Groceries'),
      ];
      await settle([a, b]);
      corrupt(b, 'UPDATE tx SET amount = ? WHERE id = ?', [-1, ids[3]]);
      b.repo.addTransaction(date: '2026-01-09', amount: -5, category: 'Groceries');
      await settle([a, b, a, b]);
      expect(a.repo.transactions().length, 6);
      expect(b.repo.transactions().length, 6);
    });
  });

  group('no ping-pong', () {
    for (final n in [2, 3]) {
      test('$n quiet devices after converging: the relay stops growing', () async {
        final ds = [for (var i = 0; i < n; i++) device('d$i')];
        ds[0].repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
        ds[1].repo.addTransaction(date: '2026-01-06', amount: -300, category: 'Shopping');
        await settle(ds, rounds: 6);
        final settled = net.files.length;
        final reports = await settle(ds, rounds: 12);
        expect(net.files.length, settled, reason: 'no new file once everybody is equal and quiet');
        expect(reports.every((r) => r.sent == 0), isTrue, reason: 'nothing to send');
        expect((await digests(ds)).length, 1);
      });
    }

    test('after a repair the devices also go quiet', () async {
      final a = device('a'), b = device('b'), c = device('c');
      final id = a.repo.addTransaction(date: '2026-01-05', amount: -2500, category: 'Groceries');
      await settle([a, b, c]);
      corrupt(b, 'UPDATE tx SET amount = ? WHERE id = ?', [-2000, id]);
      b.repo.addTransaction(date: '2026-01-08', amount: -75, category: 'Groceries');
      await settle([a, b, c], rounds: 10);
      final settled = net.files.length;
      await settle([a, b, c], rounds: 12);
      expect(net.files.length, settled);
    });

    test('a second divergence within 7 days: devicesDisagree is reported, resends do not go on for ever', () async {
      final a = device('a'), b = device('b');
      final id1 = a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      final id2 = a.repo.addTransaction(date: '2026-01-06', amount: -2500, category: 'Groceries');
      await settle([a, b]);
      corrupt(a, 'UPDATE tx SET amount = ? WHERE id = ?', [-1000, id1]);
      a.repo.addTransaction(date: '2026-01-07', amount: -50, category: 'Groceries');
      await settle([a, b], rounds: 8);
      expect((await digests([a, b])).length, 1, reason: 'first divergence repaired');

      corrupt(b, 'UPDATE tx SET amount = ? WHERE id = ?', [-2000, id2]);
      b.repo.addTransaction(date: '2026-01-08', amount: -60, category: 'Groceries');
      final reports = await settle([a, b], rounds: 8);
      // API: assumed: devicesDisagree is a SyncProblem in the report (device-local, kept until a later compare matches).
      expect(reasons(reports), contains(SyncProblemReason.devicesDisagree));
      final settled = net.files.length;
      await settle([a, b], rounds: 12);
      expect(net.files.length, settled, reason: 'no endless resends');
    });
  });

  group('a peer of another wallet key', () {
    test('its file is an otherKey problem, and the other peers\' files still apply', () async {
      final a = device('a'), c = device('c');
      final x = Device('x', null, VaultKey.generate(), () => now); // same relay, another wallet's key
      devices.add(x);
      x.repo.updateSettings({'salary': 99});
      await x.run();
      a.repo.addTransaction(date: '2026-01-05', amount: -1250, category: 'Groceries');
      final reports = await settle([a, c], rounds: 4);
      expect(reasons(reports), contains(SyncProblemReason.otherKey));
      expect(reasons(reports), isNot(contains(SyncProblemReason.badKey)));
      expect(c.repo.transactions().length, 1, reason: 'a\'s file applies although x\'s is refused');
      expect(c.repo.settings().salary, isNot(99));
    });
  });
}
