// A bad peer sync file must not stop the run: it is skipped, recorded with a reason (badKey, corrupt, unknownVersion,
// applyFailed), not retried until it changes, and reported in `problems` (device short id + reason, never a path).
// Files are written by hand so nothing depends on how the writing side builds them. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

int _clock = 4000000000000;

Map<String, Object?> _setting(String key, Object? value) =>
    Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, Hlc(_clock++, 0, 'peer').toString()).toJson();

const _devA = 'aaaa1111bbbb2222';
const _devB = 'cccc3333dddd4444';

void main() {
  late Directory tmp;
  late VaultKey key;
  late WalletRepo repo;

  Directory devices() => Directory('${tmp.path}/budget-wallet/devices');

  Future<Uint8List> sealed(List<Object?> ops, [VaultKey? k]) => seal(utf8.encode(jsonEncode(ops)), k ?? key);

  Future<File> put(String device, String name, List<int> bytes) async {
    final dir = Directory('${devices().path}/$device')..createSync(recursive: true);
    return File('${dir.path}/$name')..writeAsBytesSync(bytes);
  }

  Future<File> good(String device, String name, String setting, Object? value) async =>
      put(device, name, await sealed([_setting(setting, value)]));

  Future<SyncReport> run() => FolderSync(tmp.path, key).run(repo);

  List<String> capture() {
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

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-quarantine-');
    key = VaultKey.generate();
    repo = WalletRepo.inMemory();
  });
  tearDown(() {
    repo.close();
    tmp.deleteSync(recursive: true);
  });

  group('a bad file does not stop the others', () {
    for (final pos in [0, 1, 2]) {
      test('bad file at position $pos of three: the other two apply, one problem is reported', () async {
        final names = ['0000000001.bwop', '0000000002.bwop', '0000000003.bwop'];
        final settings = ['salary', 'rent', 'loan'];
        for (var i = 0; i < 3; i++) {
          if (i == pos) {
            await put(_devA, names[i], [9, 9, 9, 9, 9, 9, 9, 9]);
          } else {
            await good(_devA, names[i], settings[i], 100 + i);
          }
        }
        final rep = await run();
        final st = repo.settings();
        final got = {'salary': st.salary, 'rent': st.rent, 'loan': st.loan};
        for (var i = 0; i < 3; i++) {
          expect(got[settings[i]], i == pos ? 0 : 100 + i, reason: settings[i]);
        }
        expect(rep.problems, hasLength(1));
        expect(rep.filesRead, 2);
      });
    }

    test('two devices, one with only bad files: the good device\'s ops all land', () async {
      await put(_devA, '0000000001.bwop', Uint8List(0));
      await put(_devA, '0000000002.bwop', [1, 2, 3]);
      await good(_devB, '0000000001.bwop', 'salary', 1);
      await good(_devB, '0000000002.bwop', 'rent', 2);
      await good(_devB, '0000000003.bwop', 'loan', 3);
      final rep = await run();
      final st = repo.settings();
      expect((st.salary, st.rent, st.loan), (1, 2, 3));
      expect(rep.problems, hasLength(2));
      expect(rep.problems.every((p) => _devA.startsWith(p.device)), isTrue);
    });

    test('a run where every peer file is bad still exports this device\'s own ops', () async {
      repo.updateSettings({'salary': 12345});
      await put(_devA, '0000000001.bwop', [0, 1, 2]);
      await put(_devB, '0000000001.bwop', Uint8List(0));
      final rep = await run();
      expect(rep.problems, hasLength(2));
      expect(rep.sent, greaterThan(0));
      final own = Directory('${devices().path}/${repo.deviceId}');
      final files = own.listSync().whereType<File>().where((f) => f.path.endsWith('.bwop')).toList();
      expect(files, hasLength(1));
      final ops = jsonDecode(utf8.decode(await unseal(files.single.readAsBytesSync(), key))) as List;
      expect(ops, isNotEmpty);
      expect(repo.pendingOps(), isEmpty);
    });

    test('a file with one good op and one unappliable op is skipped as a whole (nothing half-applied)', () async {
      final badOp = const Op('setting', 'rent', {'value': '5', 'deleted': 0}, 'not-an-hlc').toJson();
      await put(_devA, '0000000001.bwop', await sealed([_setting('salary', 777), badOp]));
      await good(_devA, '0000000002.bwop', 'loan', 8);
      final rep = await run();
      expect(repo.settings().salary, 0);
      expect(repo.settings().loan, 8);
      expect(rep.problems.single.reason.name, 'applyFailed');
    });
  });

  group('reasons', () {
    test('truncated file: corrupt or badKey (cannot be told apart from damage), never a crash', () async {
      final full = await sealed([_setting('salary', 1)]);
      await put(_devA, '0000000001.bwop', full.sublist(0, full.length - 9));
      await put(_devA, '0000000002.bwop', full.sublist(0, 12));
      final rep = await run();
      expect(rep.problems, hasLength(2));
      for (final p in rep.problems) {
        expect(['corrupt', 'badKey'], contains(p.reason.name));
      }
      expect(repo.settings().salary, 0);
    });

    test('a flipped byte in the ciphertext is a problem, not an applied change', () async {
      final bytes = await sealed([_setting('salary', 1)]);
      bytes[bytes.length - 3] ^= 0x01;
      await put(_devA, '0000000001.bwop', bytes);
      final rep = await run();
      expect(['corrupt', 'badKey'], contains(rep.problems.single.reason.name));
      expect(repo.settings().salary, 0);
    });

    test('a file sealed with another key is badKey (or corrupt when the formats cannot tell), and others apply', () async {
      final other = VaultKey.generate();
      await put(_devA, '0000000001.bwop', await sealed([_setting('salary', 1)], other));
      await good(_devA, '0000000002.bwop', 'rent', 2);
      final rep = await run();
      expect(['badKey', 'corrupt'], contains(rep.problems.single.reason.name));
      expect(repo.settings().salary, 0);
      expect(repo.settings().rent, 2);
    });

    test('a future format version (BWOP2) is unknownVersion', () async {
      final bytes = await sealed([_setting('salary', 1)]);
      bytes[4] = '2'.codeUnitAt(0); // "BWOP1" -> "BWOP2"
      await put(_devA, '0000000001.bwop', bytes);
      final rep = await run();
      expect(rep.problems.single.reason.name, 'unknownVersion');
      expect(repo.settings().salary, 0);
    });

    test('an empty file and a 0-byte file are problems that do not stop later files', () async {
      await put(_devA, '0000000001.bwop', Uint8List(0));
      await good(_devA, '0000000002.bwop', 'salary', 5);
      final rep = await run();
      expect(rep.problems, hasLength(1));
      expect(repo.settings().salary, 5);
    });

    test('valid encryption around something that is not an op list is applyFailed', () async {
      await put(_devA, '0000000001.bwop', await seal(utf8.encode('{"not":"a list"}'), key));
      await put(_devA, '0000000002.bwop', await seal(utf8.encode('[1, 2, 3]'), key));
      await put(_devA, '0000000003.bwop', await seal(utf8.encode('not json at all'), key));
      final rep = await run();
      expect(rep.problems, hasLength(3));
      for (final p in rep.problems) {
        expect(p.reason.name, anyOf('applyFailed', 'corrupt'));
      }
    });
  });

  group('not retried until it changes', () {
    test('an unchanged bad file is not reported or read again on later runs', () async {
      await put(_devA, '0000000001.bwop', [7, 7, 7, 7, 7, 7]);
      final first = await run();
      expect(first.problems, hasLength(1));
      final lines = capture();
      for (var i = 0; i < 3; i++) {
        final again = await run();
        expect(again.problems, isEmpty, reason: 'run ${i + 2}');
        expect(again.filesRead, 0);
      }
      final decryptTries = lines.where((l) => RegExp(r'vault\.unseal\.(short|magic|auth|format)').hasMatch(l));
      expect(decryptTries, isEmpty, reason: 'the bad file was read again');
    });

    test('a file fixed later (same name, new bytes) is applied on the next run', () async {
      final f = await put(_devA, '0000000001.bwop', [1, 2, 3]);
      expect((await run()).problems, hasLength(1));
      expect(repo.settings().salary, 0);
      f.writeAsBytesSync(await sealed([_setting('salary', 4242)]));
      final rep = await run();
      expect(rep.problems, isEmpty);
      expect(rep.filesRead, 1);
      expect(repo.settings().salary, 4242);
      expect((await run()).filesRead, 0, reason: 'applied once');
    });

    test('a partial copy (0 bytes, then cut off, then whole) applies exactly when it is whole', () async {
      final full = await sealed([_setting('salary', 31)]);
      final f = await put(_devA, '0000000001.bwop', Uint8List(0));
      await good(_devA, '0000000002.bwop', 'rent', 2);
      expect((await run()).problems, hasLength(1));
      expect(repo.settings().salary, 0);
      expect(repo.settings().rent, 2);
      f.writeAsBytesSync(full.sublist(0, full.length ~/ 2));
      expect((await run()).problems, hasLength(1), reason: 'size changed: looked at again, still bad');
      expect(repo.settings().salary, 0);
      f.writeAsBytesSync(full);
      final rep = await run();
      expect(rep.problems, isEmpty);
      expect(repo.settings().salary, 31);
    });

    test('different bad bytes of the same size are looked at again (hash, not only size)', () async {
      final f = await put(_devA, '0000000001.bwop', [1, 1, 1, 1, 1, 1]);
      expect((await run()).problems, hasLength(1));
      expect((await run()).problems, isEmpty);
      f.writeAsBytesSync([2, 2, 2, 2, 2, 2]);
      expect((await run()).problems, hasLength(1));
    });

    test('same bytes rewritten (touched) is not looked at again', () async {
      final f = await put(_devA, '0000000001.bwop', [1, 1, 1, 1, 1, 1]);
      await run();
      f.writeAsBytesSync([1, 1, 1, 1, 1, 1]);
      expect((await run()).problems, isEmpty);
    });

    test('the record of a bad file survives reopening the database', () async {
      final path = '${tmp.path}/w.db';
      final r1 = WalletRepo.open(path);
      await put(_devA, '0000000001.bwop', [3, 3, 3]);
      expect((await FolderSync(tmp.path, key).run(r1)).problems, hasLength(1));
      r1.close();
      final r2 = WalletRepo.open(path);
      addTearDown(r2.close);
      expect((await FolderSync(tmp.path, key).run(r2)).problems, isEmpty);
    });

    test('a bad file on one device does not hide the same file name being good on another device', () async {
      await put(_devA, '0000000001.bwop', [5, 5, 5]);
      await good(_devB, '0000000001.bwop', 'salary', 99);
      final rep = await run();
      expect(rep.problems, hasLength(1));
      expect(repo.settings().salary, 99);
    });
  });

  group('privacy of problems and logs', () {
    test('problems hold a short device id and a reason: no path, file name or full device folder name', () async {
      await put(_devA, '0000000001.bwop', [1, 2, 3]);
      await put(_devA, '0000000002.sync-conflict-20260101-000000-ABCDEFG.bwop', Uint8List(0));
      await put(_devB, '0000000007.bwop', (await sealed([_setting('salary', 1)]))..[4] = '2'.codeUnitAt(0));
      final lines = capture();
      final rep = await run();
      expect(rep.problems, hasLength(3));
      final shown = [for (final p in rep.problems) '${p.device}|${p.reason.name}|$p'].join('\n');
      for (final p in rep.problems) {
        expect(p.device, isNotEmpty);
        expect(p.device.length, lessThan(_devA.length), reason: 'a short id, not the whole folder name');
        expect(_devA.startsWith(p.device) || _devB.startsWith(p.device), isTrue);
      }
      for (final bad in [tmp.path, '.bwop', 'sync-conflict', 'ABCDEFG', _devA, _devB, '/']) {
        expect(shown, isNot(contains(bad)), reason: 'problems leak "$bad"');
      }
      final logs = lines.join('\n');
      for (final bad in [tmp.path, '.bwop', 'sync-conflict', 'ABCDEFG', _devA, _devB]) {
        expect(logs, isNot(contains(bad)), reason: 'logs leak "$bad"');
      }
    });

    test('logs of a run with bad files name no amounts or setting values', () async {
      final lines = capture();
      await put(_devA, '0000000001.bwop', await sealed([_setting('salary', 987654)], VaultKey.generate()));
      await good(_devA, '0000000002.bwop', 'rent', 424242);
      await run();
      expect(lines.join('\n'), allOf(isNot(contains('987654')), isNot(contains('424242'))));
    });
  });

  group('vault.json is still fatal', () {
    test('an unreadable vault.json raises SyncException, even when no peer file is bad', () async {
      Directory('${tmp.path}/budget-wallet').createSync(recursive: true);
      File('${tmp.path}/budget-wallet/vault.json').writeAsStringSync('{"v": 1, "ki');
      await good(_devA, '0000000001.bwop', 'salary', 1);
      await expectLater(run(), throwsA(isA<SyncException>()));
      expect(repo.settings().salary, 0);
    });

    test('a vault.json of another wallet raises SyncException and applies nothing', () async {
      Directory('${tmp.path}/budget-wallet').createSync(recursive: true);
      File('${tmp.path}/budget-wallet/vault.json').writeAsStringSync(jsonEncode({'v': 1, 'kid': 'someone-else'}));
      await good(_devA, '0000000001.bwop', 'salary', 1);
      await expectLater(run(), throwsA(isA<SyncException>()));
      expect(repo.settings().salary, 0);
    });
  });
}
