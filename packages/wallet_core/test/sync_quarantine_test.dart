// A sync file that cannot be used is skipped, recorded with a reason and reported per device; the run goes on with
// the other files and devices, and the file is read again only when it changes (or after an update, for a newer
// format). All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
  late VaultKey key;
  late WalletRepo repo;

  Directory devices() => Directory('${tmp.path}/budget-wallet/devices');
  File fileOf(String device, String name) => File('${devices().path}/$device/$name');

  Future<Uint8List> sealed(List<Object?> ops, [VaultKey? k]) => seal(utf8.encode(jsonEncode(ops)), k ?? key);

  /// Writes a peer's file: sealed [ops], or raw [bytes] when given.
  Future<File> peer(String device, String name, {List<Object?>? ops, List<int>? bytes}) async {
    final f = fileOf(device, name)..parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes ?? await sealed(ops!));
    return f;
  }

  Future<SyncReport> run({String appVersion = ''}) => FolderSync(tmp.path, key, appVersion: appVersion).run(repo);
  int failedLogs(List<String> lines) => lines.where((l) => l.contains('sync.file.failed')).length;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-quarantine-');
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
        await peer(e.key, '0000000001.bwop', bytes: e.value);
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
        await peer('p$i', '0000000001.bwop',
            ops: p is List ? p : null, bytes: p is List ? null : await seal(utf8.encode(jsonEncode(p)), key));
      }
      final rep = await run();
      expect([for (final p in rep.problems) p.reason], List.filled(payloads.length, SyncProblemReason.corrupt));
      expect(repo.settings().salary, 0, reason: 'nothing of a refused file applies');
    });

    test('a file the database refuses is applyFailed; it is read again after an app update', () async {
      // Synthetic merchant rule op; hiding its table makes the database refuse the file (stands in for a bug).
      final rule = Op('rule', 'synthetic shop', {'category': 'Groceries'}, Hlc(_clock++, 0, 'peer').toString()).toJson();
      await peer('p1', '0000000001.bwop', ops: [rule, _setting('salary', 3)]);
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
      await peer('p1', '0000000001.bwop', ops: [_setting('salary', 4)]);
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
      await peer('p1', '0000000001.bwop', bytes: [9, 9, 9, 9]);
      final first = await run();
      expect(first.problems.single.isNew, isTrue);
      for (var i = 0; i < 3; i++) {
        final rep = await run();
        expect(rep.problems.single.isNew, isFalse);
        expect(rep.problems.single.reason, SyncProblemReason.corrupt);
      }
      expect(failedLogs(lines), 1, reason: 'unsealed and logged once only');
      expect(repo.peerFileSeen('p1', '0000000001.bwop'), isFalse);
    });

    test('a repaired copy with the same size and time stamp still applies (content decides)', () async {
      final good = await sealed([_setting('salary', 8)]);
      final f = await peer('p1', '0000000001.bwop', bytes: Uint8List.fromList(good)..[good.length - 1] ^= 1);
      final stamp = f.lastModifiedSync();
      expect((await run()).problems.single.reason, SyncProblemReason.badKey, reason: 'a changed byte fails authentication');
      f.writeAsBytesSync(good);
      f.setLastModifiedSync(stamp);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (1, 0));
      expect(repo.settings().salary, 8);
      expect(repo.localValue(BadFiles.localKey), isNull);
    });

    test('a newer-format file is not retried by the same build, and is retried once after an app update', () async {
      final lines = _capture();
      final good = await sealed([_setting('salary', 9)]);
      await peer('p1', '0000000001.bwop', bytes: [...utf8.encode('BWOP2'), ...good.sublist(5)]);
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
      await peer('p1', '0000000001.bwop', bytes: [1, 2, 3]);
      await run(appVersion: '1.0.0');
      await run(appVersion: '2.0.0');
      expect(failedLogs(lines), 1);
    });

    test('a removed bad file is forgotten: no problem reported, no entry kept', () async {
      final f = await peer('p1', '0000000001.bwop', bytes: [1, 2, 3]);
      expect((await run()).badFiles, 1);
      expect(repo.localValue(BadFiles.localKey), isNotNull);
      f.deleteSync();
      expect((await run()).badFiles, 0);
      expect(repo.localValue(BadFiles.localKey), isNull);
    });

    test('damaged bookkeeping is ignored: the files are simply checked again', () async {
      await peer('p1', '0000000001.bwop', bytes: [1, 2, 3]);
      await run();
      for (final junk in ['not json', '{}', '[1, {"d": 5}]', '[{"d":"p1","f":"0000000001.bwop","r":"nope","n":3,"h":"x","b":"1+"}]']) {
        repo.setLocalValue(BadFiles.localKey, junk);
        final rep = await run();
        expect(rep.problems.single.isNew, isTrue, reason: junk);
      }
    });

    test('quarantine is per device and per file name (conflict copies too)', () async {
      await peer('a', '0000000001.bwop', bytes: [1, 2, 3]);
      await peer('b', '0000000001.bwop', bytes: [1, 2, 3]);
      await peer('a', '0000000001.sync-conflict-20260101-000000-ABCDEFG.bwop', ops: [_setting('rent', 6)]);
      final rep = await run();
      expect(rep.problemsByDevice, {'a': 1, 'b': 1});
      expect(repo.settings().rent, 6);
      final entries = jsonDecode(repo.localValue(BadFiles.localKey)!) as List;
      expect(entries.length, 2);
    });
  });

  group('the run goes on', () {
    test('later files from the same device and files from other devices apply past a bad file', () async {
      await peer('p1', '0000000001.bwop', ops: [_setting('salary', 1)]);
      await peer('p1', '0000000002.bwop', bytes: [0, 0, 0]);
      await peer('p1', '0000000003.bwop', ops: [_setting('rent', 3)]);
      await peer('p2', '0000000001.bwop', ops: [_setting('loan', 5)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (3, 1));
      expect((repo.settings().salary, repo.settings().rent, repo.settings().loan), (1, 3, 5));
      expect(rep.problems.single.device, 'p1');
    });

    test('two devices: a damaged middle file is skipped, the rest applies, and the repaired file converges both', () async {
      final net = Net();
      final a = Device('a', Directory('${tmp.path}/a')..createSync(), key, () => 1767225600000);
      final b = Device('b', Directory('${tmp.path}/b')..createSync(), key, () => 1767225600000);
      addTearDown(a.close);
      addTearDown(b.close);
      a.repo.importBatch(january);
      await a.run();
      a.repo.updateSettings({'salary': 150000});
      await a.run();
      a.repo.addManual(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await a.run();
      a.upload(net);
      final names = net.files.keys.where((k) => k.endsWith('.bwop')).toList()..sort();
      expect(names.length, 3);
      final good = net.files[names[1]]!;
      b.deliver(net, Random(1));
      File('${b.root.path}/${names[1]}').writeAsBytesSync(good.sublist(0, good.length ~/ 2));
      final rep = await b.run();
      expect((rep.filesRead, rep.badFiles), (2, 1));
      expect(rep.problems.single.device, SyncProblem.shortId(a.repo.deviceId), reason: 'a short id, never the folder name');
      expect(b.repo.transactions().where((t) => t.manual).length, 1, reason: 'the file after the damaged one applied');
      expect(b.repo.settings().salary, 0);
      File('${b.root.path}/${names[1]}').writeAsBytesSync(good);
      final again = await b.run();
      expect((again.filesRead, again.badFiles), (1, 0));
      expect(dump(b.repo, clocks: false), dump(a.repo, clocks: false));
    });
  });

  group('schema upgrade (every peer file is listed again)', () {
    test('two devices: a quarantined file stays quarantined through the replay, the re-read files change nothing, a repaired copy applies',
        () async {
      final lines = _capture();
      final net = Net();
      final a = Device('a', Directory('${tmp.path}/a')..createSync(), key, () => 1767225600000);
      final b = Device('b', Directory('${tmp.path}/b')..createSync(), key, () => 1767225600000, dbPath: '${tmp.path}/b.db');
      addTearDown(a.close);
      addTearDown(b.close);
      a.repo.importBatch(january);
      await a.run();
      a.repo.updateSettings({'salary': 150000});
      await a.run();
      a.repo.addManual(date: '2026-01-21', amount: 450, category: 'Eating out', note: 'synthetic');
      await a.run();
      a.upload(net);
      final names = net.files.keys.where((k) => k.endsWith('.bwop')).toList()..sort();
      final good = net.files[names[1]]!;
      b.deliver(net, Random(1));
      final damaged = File('${b.root.path}/${names[1]}')..writeAsBytesSync(good.sublist(0, good.length - 3));
      final first = await b.run();
      expect((first.filesRead, first.badFiles, first.problems.single.reason), (2, 1, SyncProblemReason.badKey));
      expect(failedLogs(lines), 1);
      final before = dump(b.repo, clocks: false);
      // The database as the build before `goal_contrib` left it: this build then forgets which peer files it read.
      b.repo.db.execute("UPDATE meta SET value = '1' WHERE key = 'schema'");
      b.reopen();
      expect(bookkeeping(b.repo)['peer_files'], 0);
      final replay = await b.run();
      expect((replay.filesRead, replay.received, replay.badFiles), (2, 0, 1), reason: 're-read, nothing new, still one problem');
      expect(replay.problems.single.isNew, isFalse, reason: 'unchanged, so not unsealed again');
      expect(failedLogs(lines), 1);
      expect(dump(b.repo, clocks: false), before);
      expect(bookkeeping(b.repo)['peer_files'], 2);
      damaged.writeAsBytesSync(good);
      final fixed = await b.run();
      expect((fixed.filesRead, fixed.badFiles), (1, 0));
      expect(dump(b.repo, clocks: false), dump(a.repo, clocks: false));
      expect(b.repo.localValue(BadFiles.localKey), isNull);
    });

    test('a file the previous build\'s database refused is retried once after the upgrade, also without an app version', () async {
      final rule = Op('rule', 'synthetic shop', {'category': 'Groceries'}, Hlc(_clock++, 0, 'peer').toString()).toJson();
      await peer('p1', '0000000001.bwop', ops: [rule, _setting('salary', 3)]);
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

  test('logs carry reason words, sizes and sequence numbers only (no device ids, file names or paths)', () async {
    final lines = _capture();
    await peer('device-secret-name', '0000000007.sync-conflict-20260101-ABCDEFG.bwop', bytes: [5, 5, 5]);
    await peer('device-secret-name', '0000000008.bwop', bytes: await sealed([_setting('rent', 1)], VaultKey.generate()));
    await run();
    await run();
    final text = lines.join('\n');
    expect(text, contains('sync.file.failed {"file":"0000000007","reason":"corrupt","bytes":3}'));
    expect(text, contains('"reason":"badKey"'));
    expect(text, contains('sync.files.skipped {"bad":2,"new":0}'));
    expect(text, isNot(contains('secret-name')));
    expect(text, isNot(contains('ABCDEFG')));
    expect(text, isNot(contains(tmp.path)));
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
