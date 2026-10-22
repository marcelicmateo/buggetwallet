// The reading side of SyncEngine: files that are not ours, unreadable payloads, future formats. Files are put on a
// MemoryTransport by hand, so nothing here depends on how the writing side builds them. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

int _clock = 3000000000000;

/// A setting op from a peer, newer than anything local.
Map<String, Object?> _setting(String key, Object? value) =>
    Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, Hlc(_clock++, 0, 'peer').toString()).toJson();

void main() {
  late MemoryTransport relay;
  late VaultKey key;
  late WalletRepo repo;

  /// Puts a peer's file [seq]: sealed [ops], or raw [bytes] when given; replaces a stored one (a repair on the server).
  Future<void> peer(String device, int seq, {List<Object?>? ops, List<int>? bytes}) async {
    final b = bytes ?? await seal(utf8.encode(jsonEncode(ops)), key);
    if (relay.files.containsKey('d/$device/$seq')) {
      relay.replace(device, seq, b);
    } else {
      await relay.put(device, seq, b);
    }
  }

  bool seen(String device, int seq) => (repo.syncCursors()[device] ?? 0) >= seq;

  Future<SyncReport> run() => SyncEngine(relay, key).run(repo);

  setUp(() {
    relay = MemoryTransport();
    key = VaultKey.generate();
    repo = WalletRepo.inMemory();
  });
  tearDown(() => repo.close());

  group('what is read', () {
    test('this device\'s own files are never applied, even garbage or a valid file', () async {
      await peer(repo.deviceId, 1, bytes: [1, 2, 3]);
      await peer(repo.deviceId, 2, ops: [_setting('rent', 999)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles, rep.caughtUp), (0, 0, true));
      expect(repo.settings().rent, 0);
    });

    test('the same seq from two devices is two files', () async {
      await peer('devA', 1, ops: [_setting('salary', 1)]);
      await peer('devB', 1, ops: [_setting('rent', 2)]);
      final rep = await run();
      expect(rep.filesRead, 2);
      expect((repo.settings().salary, repo.settings().rent), (1, 2));
      expect(repo.syncCursors(), {'devA': 1, 'devB': 1});
      expect((await run()).filesRead, 0);
    });

    test('a file is applied once: replacing it later with other content is ignored (files are never rewritten)', () async {
      await peer('p1', 1, ops: [_setting('salary', 1)]);
      await run();
      await peer('p1', 1, ops: [_setting('salary', 2)]);
      final rep = await run();
      expect(rep.filesRead, 0);
      expect(repo.settings().salary, 1);
    });

    test('an empty relay, and a device known only by its ack, give an empty report that is caught up', () async {
      final first = await run();
      expect((first.sent, first.received, first.filesRead, first.badFiles, first.caughtUp), (0, 0, 0, 0, true));
      await relay.ack('p2', const {});
      final rep = await run();
      expect((rep.sent, rep.received, rep.filesRead, rep.badFiles, rep.caughtUp), (0, 0, 0, 0, true));
      expect(rep.devices.map((d) => (d.device, d.isThis)), unorderedEquals([('p2', false), (SyncProblem.shortId(repo.deviceId), true)]));
    });

    test('a device whose files the relay lost starts again from 1 (cursor above its last)', () async {
      await peer('p1', 1, ops: [_setting('salary', 1)]);
      await run();
      repo.setSyncCursor('p1', 5); // as if this device had applied more from p1 on a relay that was then wiped
      final rep = await run();
      expect(rep.filesRead, 1, reason: 'file 1 applied again (it changes nothing)');
      expect(repo.syncCursors()['p1'], 1);
    });
  });

  group('payloads that are sealed correctly but wrong inside', () {
    Future<void> expectBad(Object? payload) async {
      await peer('p1', 1, bytes: await seal(utf8.encode(payload is String ? payload : jsonEncode(payload)), key));
      final before = repo.db.select('SELECT COUNT(*) AS n FROM clocks').first['n'];
      final rep = await run();
      expect(rep.badFiles, 1, reason: jsonEncode(payload));
      expect(rep.filesRead, 0);
      expect(repo.settings().salary, 0);
      expect(repo.db.select('SELECT COUNT(*) AS n FROM clocks').first['n'], before);
      expect(seen('p1', 1), isFalse);
    }

    test('not a list: null, a number, a string, an object, an empty text', () async {
      for (final p in ['null', '42', '"text"', '{}', '{"e":"setting"}', 'true', '']) {
        await expectBad(p);
      }
    });

    test('invalid UTF-8 is refused and retried later, never half-applied', () async {
      for (final raw in [
        <int>[0xff, 0xfe, 0x5b, 0x5d],
        <int>[0xC3, 0x28],
        <int>[0x5b, 0xC3, 0x5d],
      ]) {
        await peer('p1', 1, bytes: await seal(raw, key));
        final rep = await run();
        expect(rep.badFiles, 1, reason: raw.toString());
      }
    });

    test('a list whose items are not ops: nothing at all is applied, also not the good ops before them', () async {
      final good = _setting('salary', 5);
      for (final bad in <Object?>[
        null,
        42,
        'op',
        [],
        <String, Object?>{},
        {'e': 'setting'},
        {
          'e': 'setting',
          'id': 'rent',
          'f': {'value': '1'}
        }, // no clock
        {'e': 5, 'id': 'rent', 'f': <String, Object?>{}, 'h': '1:1:a'},
        {'e': 'setting', 'id': null, 'f': <String, Object?>{}, 'h': '1:1:a'},
        {
          'e': 'setting',
          'id': 'rent',
          'f': [1],
          'h': '1:1:a'
        },
        {'e': 'setting', 'id': 'rent', 'f': null, 'h': '1:1:a'},
        {'e': 'setting', 'id': 'rent', 'f': <String, Object?>{}, 'h': 12345},
        {'e': 'setting', 'id': 'rent', 'f': <String, Object?>{}, 'h': ''},
        {'e': 'setting', 'id': 'rent', 'f': <String, Object?>{}, 'h': 'a:b:c'},
        {
          'e': 'setting',
          'id': 'rent',
          'f': {'value': '1'},
          'h': '99999999999999999999:1:a'
        },
      ]) {
        await expectBad([good, bad]);
        await expectBad([bad, good]);
      }
    });

    // Field values of the wrong type are checked per field (repo `_apply`): the bad field is ignored, the rest of the
    // op and the file apply, on every device alike. (Before that check, such a value rolled the whole file back.)
    Future<void> expectFieldIgnored(String id, Map<String, Object?> fields) async {
      await peer('p1', 1, ops: [
        _setting('salary', 5),
        Op('tx', id, fields, Hlc(_clock++, 0, 'peer').toString()).toJson(),
      ]);
      final rep = await run();
      expect((rep.badFiles, rep.filesRead), (0, 1));
      expect(repo.settings().salary, 5);
      expect(seen('p1', 1), isTrue);
    }

    test('a value that cannot be stored (NULL in a required column) is ignored; the rest of the file applies', () async {
      await expectFieldIgnored('x1', {'source': 'pbz', 'date': '2026-01-01', 'amount': null});
      final t = repo.transaction('x1')!;
      expect((t.date, t.amount), ('2026-01-01', 0));
      expect(repo.db.select("SELECT 1 FROM clocks WHERE id = 'x1' AND field = 'amount'"), isEmpty);
    });

    test('a value of a type SQLite cannot bind is ignored; the rest of the file applies', () async {
      // Nested lists and objects cannot be stored in a column.
      await expectFieldIgnored('x2', {
        'source': 'pbz',
        'date': '2026-01-01',
        'amount': -5,
        'note': ['a']
      });
      final t = repo.transaction('x2')!;
      expect((t.amount, t.note), (-5, null));
      expect(repo.db.select("SELECT 1 FROM clocks WHERE id = 'x2' AND field = 'note'"), isEmpty);
    });
  });

  group('forward compatibility', () {
    test('an empty list is a valid file: counted as read, nothing changed', () async {
      await peer('p1', 1, ops: const []);
      final rep = await run();
      expect((rep.filesRead, rep.received, rep.badFiles), (1, 0, 0));
      expect(seen('p1', 1), isTrue);
    });

    test('unknown entities, unknown fields and extra keys on ops are skipped; known data in the same file applies', () async {
      final h = Hlc(_clock++, 0, 'peer').toString();
      await peer('p1', 1, ops: [
        {
          'e': 'budgetx',
          'id': 'n1',
          'f': {'name': 'Future thing'},
          'h': h,
          'v': 3
        },
        {
          'e': 'tx',
          'id': 't1',
          'f': {'source': 'pbz', 'date': '2026-01-05', 'amount': -2500, 'colour': 'red'},
          'h': h,
          'extra': [1, 2]
        },
        _setting('salary', 150000),
      ]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (1, 0));
      expect(repo.transaction('t1')!.amount, -2500);
      expect(repo.settings().salary, 150000);
      expect(repo.transactions().length, 1);
    });

    test('a file with a newer format version (BWOP2) is skipped and holds up the later files of that device', () async {
      final good = await seal(utf8.encode(jsonEncode([_setting('salary', 9)])), key);
      final future = Uint8List.fromList([...utf8.encode('BWOP2'), ...good.sublist(5)]);
      await peer('p1', 1, bytes: future);
      await peer('p1', 2, ops: [_setting('rent', 4)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (0, 1));
      expect(rep.waiting.single.reason, SyncProblemReason.unknownVersion);
      expect((repo.settings().rent, repo.settings().salary), (0, 0));
      expect(seen('p1', 1), isFalse);
      // The same file, readable now (as after an upgrade), applies on the next run, and the waiting one after it.
      await peer('p1', 1, bytes: good);
      final again = await run();
      expect((again.filesRead, again.badFiles, again.caughtUp), (2, 0, true));
      expect((repo.settings().rent, repo.settings().salary), (4, 9));
    });

    test('a bad file is counted on every run until it is repaired, and never marked seen', () async {
      await peer('p1', 1, bytes: [0, 1, 2]);
      for (var i = 0; i < 3; i++) {
        final rep = await run();
        expect(rep.badFiles, 1, reason: 'run $i');
        expect(rep.problems.single.isNew, i == 0, reason: 'run $i: only the first run reads it (quarantined until it changes)');
      }
      expect(seen('p1', 1), isFalse);
    });

    test('a very large file (thousands of ops) applies in one run', () async {
      final ops = [for (var i = 0; i < 5000; i++) _setting('k$i', i)];
      await peer('p1', 1, ops: ops);
      final sw = Stopwatch()..start();
      final rep = await run();
      expect((rep.filesRead, rep.received), (1, 5000));
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    });

    test('ops with huge clocks from a peer are applied and later local writes still win', () async {
      final far = const Hlc(900000000000000, 99999, 'peer').toString();
      await peer('p1', 1, ops: [
        Op('setting', 'salary', {'value': '1', 'deleted': 0}, far).toJson()
      ]);
      await run();
      repo.updateSettings({'salary': 2});
      expect(repo.settings().salary, 2);
      expect(Hlc.compareStrings(repo.pendingOps().last.$2.hlc, far), greaterThan(0));
    });
  });

  test('device ids never reach the log (only sequence numbers)', () async {
    final lines = <String>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    try {
      await peer('device-with-a-secret-name', 1, ops: [_setting('salary', 1)]);
      await peer('device-with-a-secret-name', 2, bytes: [9, 9, 9]);
      await run();
    } finally {
      await sub.cancel();
      Logger.root.level = was;
    }
    final all = lines.join('\n');
    expect(all, contains('"seq":2'));
    expect(all, isNot(contains('secret')));
    expect(all, isNot(contains('device-wi')));
    expect(all, isNot(contains(repo.deviceId)));
  });
}
