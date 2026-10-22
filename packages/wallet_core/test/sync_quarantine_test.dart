// A sync file that cannot be used is skipped, recorded with a reason and reported per device; that device's later
// files wait behind it (strict order), the other devices go on, and the file is read again only when it changes (or
// after an update, for a newer format). All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';
import 'package:wallet_core/src/sync_problems.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

int _clock = 3000000000000;

/// A setting op from a peer, newer than anything local.
Map<String, Object?> _setting(String key, Object? value) =>
    Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, Hlc(_clock++, 0, 'peer').toString()).toJson();

/// Formatted log lines of the test, every level.
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
  late Directory tmp;
  late MemoryTransport relay;
  late VaultKey key;
  late WalletRepo repo;

  Future<Uint8List> sealed(List<Object?> ops, [VaultKey? k]) => seal(utf8.encode(jsonEncode(ops)), k ?? key);

  /// Puts a peer's file [seq]: sealed [ops], or raw [bytes] when given; replaces a stored one (a repair on the server).
  Future<void> peer(String device, int seq, {List<Object?>? ops, List<int>? bytes}) async {
    final b = bytes ?? await sealed(ops!);
    if (relay.files.containsKey('d/$device/$seq')) {
      relay.replace(device, seq, b);
    } else {
      await relay.put(device, seq, b);
    }
  }

  bool seen(String device, int seq) => (repo.syncCursors()[device] ?? 0) >= seq;

  Future<SyncReport> run({String appVersion = ''}) => SyncEngine(relay, key, appVersion: appVersion).run(repo);
  int failedLogs(List<String> lines) => lines.where((l) => l.contains('sync.file.failed')).length;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-quarantine-');
    relay = MemoryTransport();
    key = VaultKey.generate();
    repo = WalletRepo.inMemory();
  });
  tearDown(() {
    repo.close();
    tmp.deleteSync(recursive: true);
  });

  group('reasons', () {
    test('another key or a changed byte is badKey, garbage is corrupt, BWOP2 is unknownVersion; each with device and size', () async {
      final good = await sealed([_setting('salary', 1)]);
      final files = {
        'dev-key': await sealed([_setting('rent', 1)], VaultKey.generate()),
        // Cut off after sealing: authentication fails, which cannot be told apart from another key.
        'dev-cut': good.sublist(0, good.length - 7),
        'dev-junk': Uint8List.fromList([1, 2, 3]),
        'dev-new': Uint8List.fromList([...utf8.encode('BWOP2'), ...good.sublist(5)]),
      };
      for (final e in files.entries) {
        await peer(e.key, 1, bytes: e.value);
      }
      final rep = await run();
      final got = {for (final p in rep.problems) p.device: (p.reason, p.bytes, p.isNew)};
      expect(got, {
        'dev-key': (SyncProblemReason.badKey, files['dev-key']!.length, true),
        'dev-cut': (SyncProblemReason.badKey, good.length - 7, true),
        'dev-junk': (SyncProblemReason.corrupt, 3, true),
        'dev-new': (SyncProblemReason.unknownVersion, good.length, true),
      });
      expect(rep.badFiles, 4);
      expect(rep.problemsByDevice, {'dev-key': 1, 'dev-cut': 1, 'dev-junk': 1, 'dev-new': 1});
      expect(rep.filesRead, 0);
    });

    test('sealed correctly but not ops (not a list, not an op, a clock that does not parse) is corrupt', () async {
      final payloads = <Object?>[
        {'e': 'setting'},
        [_setting('salary', 5), 'not an op'],
        [
          _setting('salary', 5),
          {
            'e': 'setting',
            'id': 'rent',
            'f': {'value': '1'},
            'h': 'a:b:c'
          }
        ],
      ];
      for (final (i, p) in payloads.indexed) {
        await peer('p$i', 1,
            ops: p is List ? p : null, bytes: p is List ? null : await seal(utf8.encode(jsonEncode(p)), key));
      }
      final rep = await run();
      expect([for (final p in rep.problems) p.reason], List.filled(payloads.length, SyncProblemReason.corrupt));
      expect(repo.settings().salary, 0, reason: 'nothing of a refused file applies');
    });

    test('a file the database refuses is applyFailed; it is read again after an app update', () async {
      // Synthetic merchant rule op; hiding its table makes the database refuse the file (stands in for a bug).
      final rule = Op('rule', 'synthetic shop', {'category': 'Groceries'}, Hlc(_clock++, 0, 'peer').toString()).toJson();
      await run(); // the first run on the relay reads every table (its whole-state upload)
      await peer('p1', 1, ops: [rule, _setting('salary', 3)]);
      repo.db.execute('ALTER TABLE merchant_rules RENAME TO merchant_rules_hidden');
      final rep = await run(appVersion: '1.0.0');
      expect(rep.problems.single.reason, SyncProblemReason.applyFailed);
      expect(repo.settings().salary, 0, reason: 'the file is applied in one transaction');
      repo.db.execute('ALTER TABLE merchant_rules_hidden RENAME TO merchant_rules');
      // Same build: not read again.
      expect((await run(appVersion: '1.0.0')).problems.single.isNew, isFalse);
      // After an update it is retried, and applies.
      final again = await run(appVersion: '1.0.1');
      expect((again.filesRead, again.badFiles), (1, 0));
      expect(repo.settings().salary, 3);
      expect(repo.localValue(BadFiles.localKey), isNull, reason: 'the quarantine entry is gone');
    });

    test('a database that cannot be written (read-only) stops the run; the file is not quarantined and applies later', () async {
      await peer('p1', 1, ops: [_setting('salary', 4)]);
      repo.db.execute('PRAGMA query_only = 1');
      await expectLater(run(), throwsA(isA<SqliteException>()));
      repo.db.execute('PRAGMA query_only = 0');
      expect(repo.localValue(BadFiles.localKey), isNull);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (1, 0));
      expect(repo.settings().salary, 4);
    });
  });

  group('not retried until it changes', () {
    test('an unchanged bad file is read once: later runs report it (isNew false) without trying it again', () async {
      final lines = _capture();
      await peer('p1', 1, bytes: [9, 9, 9, 9]);
      final first = await run();
      expect(first.problems.single.isNew, isTrue);
      for (var i = 0; i < 3; i++) {
        final rep = await run();
        expect(rep.problems.single.isNew, isFalse);
        expect(rep.problems.single.reason, SyncProblemReason.corrupt);
      }
      expect(failedLogs(lines), 1, reason: 'unsealed and logged once only');
      expect(seen('p1', 1), isFalse);
    });

    test('a repaired copy of the same size still applies (content decides)', () async {
      final good = await sealed([_setting('salary', 8)]);
      await peer('p1', 1, bytes: Uint8List.fromList(good)..[good.length - 1] ^= 1);
      expect((await run()).problems.single.reason, SyncProblemReason.badKey, reason: 'a changed byte fails authentication');
      await peer('p1', 1, bytes: good);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (1, 0));
      expect(repo.settings().salary, 8);
      expect(repo.localValue(BadFiles.localKey), isNull);
    });

    test('a newer-format file is not retried by the same build, and is retried once after an app update', () async {
      final lines = _capture();
      final good = await sealed([_setting('salary', 9)]);
      await peer('p1', 1, bytes: [...utf8.encode('BWOP2'), ...good.sublist(5)]);
      await run(appVersion: '1.0.0');
      await run(appVersion: '1.0.0');
      expect(failedLogs(lines), 1);
      final upgraded = await run(appVersion: '1.1.0');
      expect(upgraded.problems.single, isA<SyncProblem>().having((p) => p.isNew, 'isNew', isTrue));
      expect(failedLogs(lines), 2, reason: 'tried again after the update (still unreadable here)');
      await run(appVersion: '1.1.0');
      expect(failedLogs(lines), 2);
    });

    test('a corrupt file is not retried after an app update (only a changed file is)', () async {
      final lines = _capture();
      await peer('p1', 1, bytes: [1, 2, 3]);
      await run(appVersion: '1.0.0');
      await run(appVersion: '2.0.0');
      expect(failedLogs(lines), 1);
    });

    test('a bad file no longer needed (the cursor moved past it, as a snapshot does) is forgotten: no problem, no entry', () async {
      await peer('p1', 1, bytes: [1, 2, 3]);
      expect((await run()).badFiles, 1);
      expect(repo.localValue(BadFiles.localKey), isNotNull);
      repo.setSyncCursor('p1', 1);
      final rep = await run();
      expect((rep.badFiles, rep.caughtUp), (0, true));
      expect(repo.localValue(BadFiles.localKey), isNull);
    });

    test('damaged bookkeeping is ignored: the files are simply checked again', () async {
      await peer('p1', 1, bytes: [1, 2, 3]);
      await run();
      for (final junk in ['not json', '{}', '[1, {"d": 5}]', '[{"d":"p1","f":"1","r":"nope","n":3,"h":"x","b":"1+"}]']) {
        repo.setLocalValue(BadFiles.localKey, junk);
        final rep = await run();
        expect(rep.problems.single.isNew, isTrue, reason: junk);
      }
    });

    test('quarantine is per device and per seq', () async {
      await peer('a', 1, bytes: [1, 2, 3]);
      await peer('b', 1, bytes: [1, 2, 3]);
      await peer('c', 1, ops: [_setting('rent', 6)]);
      final rep = await run();
      expect(rep.problemsByDevice, {'a': 1, 'b': 1});
      expect(repo.settings().rent, 6);
      final entries = jsonDecode(repo.localValue(BadFiles.localKey)!) as List;
      expect(entries.length, 2);
    });
  });

  group('the run goes on with the other devices; the bad device waits', () {
    test('files before a bad file and files from other devices apply; later files of that device wait', () async {
      await peer('p1', 1, ops: [_setting('salary', 1)]);
      await peer('p1', 2, bytes: [0, 0, 0]);
      await peer('p1', 3, ops: [_setting('rent', 3)]);
      await peer('p2', 1, ops: [_setting('loan', 5)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles, rep.caughtUp), (2, 1, false));
      expect((repo.settings().salary, repo.settings().rent, repo.settings().loan), (1, 0, 5));
      expect(rep.problems.single.device, 'p1');
      expect((rep.waiting.single.device, rep.waiting.single.seq, rep.waiting.single.reason), ('p1', 2, SyncProblemReason.corrupt));
      expect(repo.syncCursors(), {'p1': 1, 'p2': 1});
    });

    test('two devices: a damaged middle file holds up the files after it; the repaired file converges both', () async {
      final net = Net();
      final a = Device('a', null, key, () => 1767225600000, net: net);
      final b = Device('b', null, key, () => 1767225600000, net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      a.repo.importBatch(january);
      await a.run();
      a.repo.updateSettings({'salary': 150000});
      await a.run();
      a.repo.addManual(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await a.run();
      expect(net.files.keys.where((k) => k.startsWith('d/')), hasLength(3));
      final good = net.files['d/${a.repo.deviceId}/2']!;
      net.relay.replace(a.repo.deviceId, 2, good.sublist(0, good.length ~/ 2));
      final rep = await b.run();
      expect((rep.filesRead, rep.badFiles), (1, 1));
      expect(rep.problems.single.device, SyncProblem.shortId(a.repo.deviceId), reason: 'a short id, never the whole id');
      expect(b.repo.transactions().where((t) => t.manual), isEmpty, reason: 'the file after the damaged one waits');
      expect(b.repo.settings().salary, 0);
      net.relay.replace(a.repo.deviceId, 2, good);
      final again = await b.run();
      expect((again.filesRead, again.badFiles, again.caughtUp), (2, 0, true));
      expect(dump(b.repo, clocks: false), dump(a.repo, clocks: false));
    });
  });

  group('schema upgrade (every peer file is read again)', () {
    test('two devices: a quarantined file stays quarantined through the replay, the re-read files change nothing, a repaired copy applies',
        () async {
      final lines = _capture();
      final net = Net();
      final a = Device('a', null, key, () => 1767225600000, net: net);
      final b = Device('b', null, key, () => 1767225600000, dbPath: '${tmp.path}/b.db', net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      a.repo.importBatch(january);
      await a.run();
      a.repo.updateSettings({'salary': 150000});
      await a.run();
      a.repo.addManual(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await a.run();
      final good = net.files['d/${a.repo.deviceId}/3']!;
      net.relay.replace(a.repo.deviceId, 3, good.sublist(0, good.length - 3));
      final first = await b.run();
      expect((first.filesRead, first.badFiles, first.problems.single.reason), (2, 1, SyncProblemReason.badKey));
      expect(failedLogs(lines), 1);
      final before = dump(b.repo, clocks: false);
      // The database as the build before `goal_contrib` left it: this build then forgets how far it applied each device.
      b.repo.db.execute("UPDATE meta SET value = '1' WHERE key = 'schema'");
      b.reopen();
      expect(bookkeeping(b.repo)['sync_cursor'], 0);
      final replay = await b.run();
      expect((replay.filesRead, replay.received, replay.badFiles), (2, 0, 1), reason: 're-read, nothing new, still one problem');
      expect(replay.problems.single.isNew, isFalse, reason: 'unchanged, so not unsealed again');
      expect(failedLogs(lines), 1);
      expect(dump(b.repo, clocks: false), before);
      expect(b.repo.syncCursors(), {a.repo.deviceId: 2});
      net.relay.replace(a.repo.deviceId, 3, good);
      final fixed = await b.run();
      expect((fixed.filesRead, fixed.badFiles), (1, 0));
      expect(dump(b.repo, clocks: false), dump(a.repo, clocks: false));
      expect(b.repo.localValue(BadFiles.localKey), isNull);
    });

    test('a file the previous build\'s database refused is retried once after the upgrade, also without an app version', () async {
      final rule = Op('rule', 'synthetic shop', {'category': 'Groceries'}, Hlc(_clock++, 0, 'peer').toString()).toJson();
      await run(); // the first run on the relay reads every table (its whole-state upload)
      await peer('p1', 1, ops: [rule, _setting('salary', 3)]);
      repo.db.execute('ALTER TABLE merchant_rules RENAME TO merchant_rules_hidden');
      expect((await run()).problems.single.reason, SyncProblemReason.applyFailed);
      repo.db.execute('ALTER TABLE merchant_rules_hidden RENAME TO merchant_rules');
      expect((await run()).problems.single.isNew, isFalse, reason: 'same build: not read again');
      // The record as the build with the previous schema would have written it.
      final bad = BadFiles.load(repo);
      final was = bad.byKey.values.single;
      expect(was.build, '$syncReaderVersion.${WalletRepo.schemaVersion}+');
      bad.byKey[was.key] = BadFile(was.device, was.file, was.reason,
          size: was.size, hash: was.hash, build: '$syncReaderVersion.${WalletRepo.schemaVersion - 1}+');
      bad.save(repo);
      final again = await run();
      expect((again.filesRead, again.badFiles), (1, 0));
      expect(repo.settings().salary, 3);
    });
  });

  test('logs carry reason words, sizes and sequence numbers only (no device ids)', () async {
    final lines = _capture();
    await peer('device-secret-name', 1, ops: [_setting('salary', 1)]);
    await peer('device-secret-name', 2, bytes: [5, 5, 5]);
    await peer('device-secret-other', 1, bytes: await sealed([_setting('rent', 1)], VaultKey.generate()));
    await run();
    await run();
    final text = lines.join('\n');
    expect(text, contains('sync.file.failed {"seq":2,"reason":"corrupt","bytes":3}'));
    expect(text, contains('"reason":"badKey"'));
    expect(text, contains('sync.files.skipped {"bad":2,"new":0}'));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('device-')));
  });

  group('BadFile', () {
    const b = BadFile('dev', '0000000001.bwop', SyncProblemReason.unknownVersion, size: 10, stamp: '5', hash: 'ab', build: '1+1.0');

    test('round-trips through JSON; garbage gives null', () {
      final back = BadFile.fromJson(jsonDecode(jsonEncode(b.toJson())))!;
      expect((back.device, back.file, back.reason, back.size, back.stamp, back.hash, back.build),
          (b.device, b.file, b.reason, 10, '5', 'ab', '1+1.0'));
      for (final j in <Object?>[
        null,
        1,
        'x',
        <String, Object?>{},
        {...b.toJson(), 'r': 'nope'},
        {...b.toJson(), 'n': '10'},
        {...b.toJson(), 's': 5}
      ]) {
        expect(BadFile.fromJson(j), isNull, reason: '$j');
      }
    });

    test('retried after an update only for unknownVersion and applyFailed; listed change by size or stamp', () {
      expect(b.retryAfterUpgrade('1+1.0'), isFalse);
      expect(b.retryAfterUpgrade('2+1.0'), isTrue);
      const c = BadFile('dev', 'f', SyncProblemReason.corrupt, size: 10, hash: 'ab', build: '1+');
      const k = BadFile('dev', 'f', SyncProblemReason.badKey, size: 10, hash: 'ab', build: '1+');
      expect((c.retryAfterUpgrade('9+9'), k.retryAfterUpgrade('9+9')), (false, false));
      expect((b.listedChanged(10, '5'), b.listedChanged(11, '5'), b.listedChanged(10, '6'), b.listedChanged(10, null)),
          (false, true, true, true));
    });
  });
}
