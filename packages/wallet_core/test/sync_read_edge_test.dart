// The reading side of FolderSync: odd folder contents, files that are not ours, unreadable payloads, future formats.
// Files are written by hand, so nothing here depends on how the writing side builds them. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

int _clock = 3000000000000;

/// A setting op from a peer, newer than anything local.
Map<String, Object?> _setting(String key, Object? value) =>
    Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, Hlc(_clock++, 0, 'peer').toString()).toJson();

void main() {
  late Directory tmp;
  late VaultKey key;
  late WalletRepo repo;

  Directory devices() => Directory('${tmp.path}/budget-wallet/devices');

  /// Writes a peer's file: sealed [ops] under devices/[device]/[name], or raw [bytes] when given.
  Future<File> peer(String device, String name, {List<Object?>? ops, List<int>? bytes}) async {
    final dir = Directory('${devices().path}/$device')..createSync(recursive: true);
    final f = File('${dir.path}/$name');
    f.writeAsBytesSync(bytes ?? await seal(utf8.encode(jsonEncode(ops)), key));
    return f;
  }

  Future<SyncReport> run() => FolderSync(tmp.path, key).run(repo);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-syncread-');
    key = VaultKey.generate();
    repo = WalletRepo.inMemory();
  });
  tearDown(() {
    repo.close();
    tmp.deleteSync(recursive: true);
  });

  group('what is read', () {
    test('temporary, hidden, other-extension and directory entries are ignored; real files apply', () async {
      final bad = [_setting('rent', 999)];
      await peer('p1', '.0000000001.bwop.tmp', ops: bad);
      await peer('p1', '.0000000002.bwop', ops: bad);
      await peer('p1', '0000000003.bwop.part', ops: bad);
      await peer('p1', '0000000004.BWOP', ops: bad);
      await peer('p1', 'notes.txt', ops: bad);
      await peer('p1', '0000000005.bwop.bak', ops: bad);
      Directory('${devices().path}/p1/0000000006.bwop').createSync();
      File('${devices().path}/readme.txt').writeAsStringSync('not a device folder');
      await peer('p1', '0000000007.bwop', ops: [_setting('salary', 150000)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles, rep.received), (1, 0, 1));
      expect(repo.settings().salary, 150000);
      expect(repo.settings().rent, 0);
    });

    test('this device\'s own folder is never read, even when it holds garbage or a valid file', () async {
      await peer(repo.deviceId, '0000000001.bwop', bytes: [1, 2, 3]);
      await peer(repo.deviceId, '0000000002.bwop', ops: [_setting('rent', 999)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (0, 0));
      expect(repo.settings().rent, 0);
    });

    test('the same file name in two device folders is two files', () async {
      await peer('devA', '0000000001.bwop', ops: [_setting('salary', 1)]);
      await peer('devB', '0000000001.bwop', ops: [_setting('rent', 2)]);
      final rep = await run();
      expect(rep.filesRead, 2);
      expect((repo.settings().salary, repo.settings().rent), (1, 2));
      expect(repo.peerFileSeen('devA', '0000000001.bwop'), isTrue);
      expect(repo.peerFileSeen('devB', '0000000001.bwop'), isTrue);
      expect((await run()).filesRead, 0);
    });

    test('conflict copies made by the file sync are separate files and apply', () async {
      await peer('p1', '0000000001.bwop', ops: [_setting('salary', 1)]);
      await peer('p1', '0000000001.sync-conflict-20260101-000000-ABCDEFG.bwop', ops: [_setting('rent', 2)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (2, 0));
      expect((repo.settings().salary, repo.settings().rent), (1, 2));
    });

    test('device folders with spaces and non-ASCII names, and a folder path with spaces, work', () async {
      final odd = Directory('${tmp.path}/Moj novac čšž')..createSync();
      final dev = Directory('${odd.path}/budget-wallet/devices/uređaj 1')..createSync(recursive: true);
      File('${dev.path}/0000000001.bwop').writeAsBytesSync(await seal(utf8.encode(jsonEncode([_setting('salary', 7)])), key));
      final rep = await FolderSync(odd.path, key).run(repo);
      expect(rep.filesRead, 1);
      expect(repo.settings().salary, 7);
    });

    test('a folder path with a trailing separator works', () async {
      await peer('p1', '0000000001.bwop', ops: [_setting('salary', 3)]);
      await FolderSync('${tmp.path}/', key).run(repo);
      expect(repo.settings().salary, 3);
    });

    test('a file is read once: replacing it later with other content is ignored (files are never rewritten)', () async {
      final f = await peer('p1', '0000000001.bwop', ops: [_setting('salary', 1)]);
      await run();
      f.writeAsBytesSync(await seal(utf8.encode(jsonEncode([_setting('salary', 2)])), key));
      final rep = await run();
      expect(rep.filesRead, 0);
      expect(repo.settings().salary, 1);
    });

    test('no devices at all, an empty device folder and a device folder of only ignored files give an empty report', () async {
      expect((await run()).filesRead, 0);
      Directory('${devices().path}/empty').createSync(recursive: true);
      await peer('p2', '.tmp.bwop', ops: [_setting('rent', 1)]);
      final rep = await run();
      expect((rep.sent, rep.received, rep.filesRead, rep.badFiles), (0, 0, 0, 0));
    });

    test('the sync folder is a file, or does not exist: refused with a SyncException that names no path', () async {
      final file = File('${tmp.path}/just-a-file')..writeAsStringSync('x');
      for (final path in [file.path, '${tmp.path}/missing', '']) {
        await expectLater(
            FolderSync(path, key).run(repo),
            throwsA(
                isA<SyncException>().having((e) => e.message, 'message', allOf(isNot(contains(tmp.path)), isNot(contains('just-a-file'))))),
            reason: path);
      }
    });
  });

  group('vault.json', () {
    test('a new folder gets a vault.json with the format and the key fingerprint only', () async {
      await run();
      final j = jsonDecode(File('${tmp.path}/budget-wallet/vault.json').readAsStringSync()) as Map;
      expect(j, {'v': 1, 'kid': await key.keyId()});
      final text = File('${tmp.path}/budget-wallet/vault.json').readAsStringSync().toUpperCase();
      expect(text.contains((await key.toText()).replaceAll('-', '').substring(3, 20)), isFalse);
    });

    test('a different fingerprint, a missing one, a non-text one or another case is refused as a different wallet', () async {
      await run();
      final f = File('${tmp.path}/budget-wallet/vault.json');
      final kid = await key.keyId();
      for (final j in [
        {'v': 1, 'kid': 'ffffffffffffffff'},
        {'v': 1},
        {'v': 1, 'kid': null},
        {'v': 1, 'kid': 12},
        {'v': 1, 'kid': kid.toUpperCase()},
        {'v': 1, 'kid': ' $kid'},
        {
          'v': 1,
          'kid': [kid]
        },
        <String, Object?>{},
      ]) {
        f.writeAsStringSync(jsonEncode(j));
        repo.updateSettings({'salary': 1});
        final before = repo.pendingOps().length;
        await expectLater(run(), throwsA(isA<SyncException>()), reason: jsonEncode(j));
        expect(repo.pendingOps().length, before, reason: 'outbox kept');
      }
    });

    test('a vault.json that is empty, cut off or not an object leaves the wallet untouched', () async {
      await run();
      final f = File('${tmp.path}/budget-wallet/vault.json');
      await peer('p1', '0000000001.bwop', ops: [_setting('salary', 5)]);
      repo.updateSettings({'rent': 11});
      for (final text in ['', '{', '{"v":1,"kid":"', '[]', 'null', '"text"', '42', 'garbage', '\u0000\u0000']) {
        f.writeAsStringSync(text);
        await expectLater(run(), throwsA(anything), reason: jsonEncode(text));
        expect(repo.settings().salary, 0, reason: 'nothing applied: ${jsonEncode(text)}');
        expect(repo.pendingOps(), isNotEmpty, reason: 'outbox kept: ${jsonEncode(text)}');
        expect(Directory('${devices().path}/${repo.deviceId}').existsSync(), isFalse, reason: 'nothing written: ${jsonEncode(text)}');
      }
    });

    test('a vault.json that is empty or cut off (a half-synced file) is refused with a SyncException, not a raw parse error', () async {
      await run();
      final f = File('${tmp.path}/budget-wallet/vault.json');
      for (final text in ['', '{', '[]', 'null', 'garbage']) {
        f.writeAsStringSync(text);
        await expectLater(run(), throwsA(isA<SyncException>()), reason: jsonEncode(text));
      }
    });

    test('after a bad vault.json is repaired, the next run works and sends the kept changes', () async {
      await run();
      final f = File('${tmp.path}/budget-wallet/vault.json');
      final good = f.readAsStringSync();
      repo.updateSettings({'rent': 11});
      f.writeAsStringSync('');
      await expectLater(run(), throwsA(anything));
      f.writeAsStringSync(good);
      final rep = await run();
      expect(rep.sent, 1);
    });
  });

  group('payloads that are sealed correctly but wrong inside', () {
    Future<void> expectBad(Object? payload) async {
      await peer('p1', '0000000001.bwop', bytes: await seal(utf8.encode(payload is String ? payload : jsonEncode(payload)), key));
      final before = repo.db.select('SELECT COUNT(*) AS n FROM clocks').first['n'];
      final rep = await run();
      expect(rep.badFiles, 1, reason: jsonEncode(payload));
      expect(rep.filesRead, 0);
      expect(repo.settings().salary, 0);
      expect(repo.db.select('SELECT COUNT(*) AS n FROM clocks').first['n'], before);
      expect(repo.peerFileSeen('p1', '0000000001.bwop'), isFalse);
      File('${devices().path}/p1/0000000001.bwop').deleteSync();
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
        await peer('p1', '0000000001.bwop', bytes: await seal(raw, key));
        final rep = await run();
        expect(rep.badFiles, 1, reason: raw.toString());
        File('${devices().path}/p1/0000000001.bwop').deleteSync();
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
      await peer('p1', '0000000001.bwop', ops: [
        _setting('salary', 5),
        Op('tx', id, fields, Hlc(_clock++, 0, 'peer').toString()).toJson(),
      ]);
      final rep = await run();
      expect((rep.badFiles, rep.filesRead), (0, 1));
      expect(repo.settings().salary, 5);
      expect(repo.peerFileSeen('p1', '0000000001.bwop'), isTrue);
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
      await peer('p1', '0000000001.bwop', ops: const []);
      final rep = await run();
      expect((rep.filesRead, rep.received, rep.badFiles), (1, 0, 0));
      expect(repo.peerFileSeen('p1', '0000000001.bwop'), isTrue);
    });

    test('unknown entities, unknown fields and extra keys on ops are skipped; known data in the same file applies', () async {
      final h = Hlc(_clock++, 0, 'peer').toString();
      await peer('p1', '0000000001.bwop', ops: [
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

    test('a file with a newer format version (BWOP2) is skipped and retried; later files of the same device still apply', () async {
      final good = await seal(utf8.encode(jsonEncode([_setting('salary', 9)])), key);
      final future = Uint8List.fromList([...utf8.encode('BWOP2'), ...good.sublist(5)]);
      await peer('p1', '0000000001.bwop', bytes: future);
      await peer('p1', '0000000002.bwop', ops: [_setting('rent', 4)]);
      final rep = await run();
      expect((rep.filesRead, rep.badFiles), (1, 1));
      expect((repo.settings().rent, repo.settings().salary), (4, 0));
      expect(repo.peerFileSeen('p1', '0000000001.bwop'), isFalse);
      // The same file, readable after an upgrade, applies on the next run.
      File('${devices().path}/p1/0000000001.bwop').writeAsBytesSync(good);
      final again = await run();
      expect((again.filesRead, again.badFiles), (1, 0));
      expect(repo.settings().salary, 9);
    });

    test('a bad file is counted on every run until it is repaired, and never marked seen', () async {
      await peer('p1', '0000000001.bwop', bytes: [0, 1, 2]);
      for (var i = 0; i < 3; i++) {
        expect((await run()).badFiles, 1, reason: 'run $i');
      }
      expect(repo.peerFileSeen('p1', '0000000001.bwop'), isFalse);
    });

    test('a very large file (thousands of ops) applies in one run', () async {
      final ops = [for (var i = 0; i < 5000; i++) _setting('k$i', i)];
      await peer('p1', '0000000001.bwop', ops: ops);
      final sw = Stopwatch()..start();
      final rep = await run();
      expect((rep.filesRead, rep.received), (1, 5000));
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    });

    test('ops with huge clocks from a peer are applied and later local writes still win', () async {
      final far = const Hlc(900000000000000, 99999, 'peer').toString();
      await peer('p1', '0000000001.bwop', ops: [
        Op('setting', 'salary', {'value': '1', 'deleted': 0}, far).toJson()
      ]);
      await run();
      repo.updateSettings({'salary': 2});
      expect(repo.settings().salary, 2);
      expect(Hlc.compareStrings(repo.pendingOps().last.$2.hlc, far), greaterThan(0));
    });
  });

  test('sync file names never reach the log (only the sequence number)', () async {
    final lines = <String>[];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    try {
      await peer('device-with-a-secret-name', '0000000042.sync-conflict-20260101-ABCDEFG.bwop', bytes: [9, 9, 9]);
      await peer('device-with-a-secret-name', '0000000043.bwop', ops: [_setting('salary', 1)]);
      await run();
    } finally {
      await sub.cancel();
      Logger.root.level = was;
    }
    final all = lines.join('\n');
    expect(all, isNot(contains('secret-name')));
    expect(all, isNot(contains('ABCDEFG')));
    expect(all, isNot(contains(tmp.path)));
  });
}
