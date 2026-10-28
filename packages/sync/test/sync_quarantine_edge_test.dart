// A bad peer sync file must not stop the run: it is skipped, recorded with a reason (badKey, corrupt, unknownVersion,
// applyFailed), not retried until it changes, and reported in `problems` on every run while it is there (device short
// id + reason + isNew, never a full id). Files apply strictly in order per device, so a bad file holds up that
// device's later files (`waiting`) while other devices go on.
// Files are put on a MemoryTransport by hand so nothing depends on how the writing side builds them. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

int _clock = 4000000000000;

/// This device's wall clock in these tests: the synthetic clock the ops above are stamped with, so they are never more
/// than an hour ahead of it (H7 would quarantine them as clockDrift, or refuse local writes behind them).
int _wall() => _clock;

Map<String, Object?> _setting(String key, Object? value) =>
    Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, Hlc(_clock++, 0, 'peer').toString()).toJson();

const _devA = 'aaaa1111bbbb2222';
const _devB = 'cccc3333dddd4444';

/// A relay whose `state` always fails with [failure].
class _Failing implements SyncTransport {
  final TransportFailure failure;
  _Failing(this.failure);
  Never _fail() => throw TransportException(failure, 'synthetic');
  @override
  Future<RelayState> state() async => _fail();
  @override
  Future<void> put(String device, int seq, List<int> bytes) async => _fail();
  @override
  Future<List<int>> get(String device, int seq) async => _fail();
  @override
  Future<void> ack(String device, Map<String, int> cursors) async => _fail();
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) async => _fail();
  @override
  Future<List<int>> getSnapshot(String id) async => _fail();
  @override
  Future<void> putBlob(String hash, List<int> bytes) async => _fail();
  @override
  Future<List<int>?> getBlob(String hash) async => _fail();
  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) async => _fail();
}

void main() {
  late Directory tmp;
  late MemoryTransport relay;
  late VaultKey key;
  late WalletRepo repo;

  Future<Uint8List> sealed(List<Object?> ops, [VaultKey? k, String device = 'p1', int seq = 1]) =>
      seal(utf8.encode(jsonEncode(ops)), k ?? key, aad: aadSyncFile(device, seq));

  /// Stores [bytes] as [device]'s file [seq], replacing a stored one (a repair on the server).
  Future<void> put(String device, int seq, List<int> bytes) async {
    if (relay.files.containsKey('d/$device/$seq')) {
      relay.replace(device, seq, bytes);
    } else {
      await relay.put(device, seq, bytes);
    }
  }

  Future<void> good(String device, int seq, String setting, Object? value) async =>
      put(device, seq, await sealed([_setting(setting, value)], null, device, seq));

  Future<SyncReport> run() => SyncEngine(relay, key).run(repo);

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
    relay = MemoryTransport();
    key = VaultKey.generate();
    repo = WalletRepo.inMemory(now: _wall);
  });
  tearDown(() {
    repo.close();
    tmp.deleteSync(recursive: true);
  });

  group('a bad file holds up only its own device', () {
    for (final pos in [0, 1, 2]) {
      test('bad file at position $pos of three: the files before it apply, the ones after it wait', () async {
        final settings = ['salary', 'rent', 'loan'];
        for (var i = 0; i < 3; i++) {
          if (i == pos) {
            await put(_devA, i + 1, [9, 9, 9, 9, 9, 9, 9, 9]);
          } else {
            await good(_devA, i + 1, settings[i], 100 + i);
          }
        }
        final rep = await run();
        final st = repo.settings();
        final got = {'salary': st.salary, 'rent': st.rent, 'loan': st.loan};
        for (var i = 0; i < 3; i++) {
          expect(got[settings[i]], i < pos ? 100 + i : 0, reason: settings[i]);
        }
        expect(rep.problems, hasLength(1));
        expect(rep.filesRead, pos);
        expect((rep.waiting.single.seq, rep.caughtUp), (pos + 1, false));
      });
    }

    test('two devices, one with only bad files: the good device\'s ops all land', () async {
      await put(_devA, 1, Uint8List(0));
      await put(_devA, 2, [1, 2, 3]);
      await good(_devB, 1, 'salary', 1);
      await good(_devB, 2, 'rent', 2);
      await good(_devB, 3, 'loan', 3);
      final rep = await run();
      final st = repo.settings();
      expect((st.salary, st.rent, st.loan), (1, 2, 3));
      expect(rep.problems, hasLength(1), reason: 'the second bad file is not even fetched: it waits behind the first');
      expect(rep.problems.every((p) => _devA.startsWith(p.device)), isTrue);
      expect(rep.waiting.single.device, SyncProblem.shortId(_devA));
    });

    test('a run where every peer file is bad still uploads this device\'s own ops', () async {
      repo.updateSettings({'salary': 12345});
      await put(_devA, 1, [0, 1, 2]);
      await put(_devB, 1, Uint8List(0));
      final rep = await run();
      expect(rep.problems, hasLength(2));
      expect(rep.sent, greaterThan(0));
      final own = relay.files.keys.where((k) => k.startsWith('d/${repo.deviceId}/')).toList();
      expect(own, ['d/${repo.deviceId}/1']);
      final ops = jsonDecode(utf8.decode(await unseal(relay.files[own.single]!, key, aad: aadSyncFile(repo.deviceId, 1)))) as List;
      expect(ops, isNotEmpty);
      expect(repo.pendingOps(), isEmpty);
    });

    test('a file with one good op and one unappliable op is skipped as a whole (nothing half-applied)', () async {
      final badOp = const Op('setting', 'rent', {'value': '5', 'deleted': 0}, 'not-an-hlc').toJson();
      await put(_devA, 1, await sealed([_setting('salary', 777), badOp], null, _devA, 1));
      await good(_devA, 2, 'loan', 8);
      final rep = await run();
      expect(repo.settings().salary, 0);
      expect(repo.settings().loan, 0, reason: 'waits behind the refused file');
      // A clock that does not parse is damage in the file (no update of this app would read it), so corrupt, not applyFailed.
      expect(rep.problems.single.reason.name, 'corrupt');
    });
  });

  group('reasons', () {
    test('truncated file: corrupt or badKey (cannot be told apart from damage), never a crash', () async {
      final full = await sealed([_setting('salary', 1)]);
      await put(_devA, 1, full.sublist(0, full.length - 9));
      await put(_devB, 1, full.sublist(0, 12));
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
      await put(_devA, 1, bytes);
      final rep = await run();
      expect(['corrupt', 'badKey'], contains(rep.problems.single.reason.name));
      expect(repo.settings().salary, 0);
    });

    test('a file sealed with another key is otherKey (V1), and the other devices apply', () async {
      final other = VaultKey.generate();
      await put(_devA, 1, await sealed([_setting('salary', 1)], other));
      await good(_devB, 1, 'rent', 2);
      final rep = await run();
      expect(rep.problems.single.reason, SyncProblemReason.otherKey);
      expect(rep.waiting.single.reason, SyncProblemReason.otherKey);
      expect(repo.settings().salary, 0);
      expect(repo.settings().rent, 2);
    });

    test('a future format version (BWOP4) is unknownVersion', () async {
      final bytes = await sealed([_setting('salary', 1)]);
      bytes[4] = '4'.codeUnitAt(0); // "BWOP3" -> "BWOP4"
      await put(_devA, 1, bytes);
      final rep = await run();
      expect(rep.problems.single.reason.name, 'unknownVersion');
      expect(repo.settings().salary, 0);
    });

    test('a 0-byte file is a problem that holds up the later files of its device', () async {
      await put(_devA, 1, Uint8List(0));
      await good(_devA, 2, 'salary', 5);
      final rep = await run();
      expect(rep.problems, hasLength(1));
      expect(repo.settings().salary, 0);
      expect(rep.waiting.single.seq, 1);
    });

    test('valid encryption around something that is not an op list is refused', () async {
      await put('dev1', 1, await seal(utf8.encode('{"not":"a list"}'), key, aad: aadSyncFile('dev1', 1)));
      await put('dev2', 1, await seal(utf8.encode('[1, 2, 3]'), key, aad: aadSyncFile('dev2', 1)));
      await put('dev3', 1, await seal(utf8.encode('not json at all'), key, aad: aadSyncFile('dev3', 1)));
      final rep = await run();
      expect(rep.problems, hasLength(3));
      for (final p in rep.problems) {
        expect(p.reason.name, anyOf('applyFailed', 'corrupt'));
      }
    });
  });

  group('not retried until it changes', () {
    test('an unchanged bad file is reported as known (isNew false) and not unsealed again on later runs', () async {
      await put(_devA, 1, [7, 7, 7, 7, 7, 7]);
      final first = await run();
      expect(first.problems.single.isNew, isTrue);
      final lines = capture();
      for (var i = 0; i < 3; i++) {
        final again = await run();
        expect(again.problems.single.isNew, isFalse, reason: 'run ${i + 2}: still there, so still listed, but known');
        expect(again.filesRead, 0);
      }
      final decryptTries = lines.where((l) => RegExp(r'vault\.unseal\.(short|magic|auth|format)').hasMatch(l));
      expect(decryptTries, isEmpty, reason: 'the bad file was unsealed again');
    });

    test('a file fixed later (same seq, new bytes) is applied on the next run', () async {
      await put(_devA, 1, [1, 2, 3]);
      expect((await run()).problems, hasLength(1));
      expect(repo.settings().salary, 0);
      await put(_devA, 1, await sealed([_setting('salary', 4242)], null, _devA, 1));
      final rep = await run();
      expect(rep.problems, isEmpty);
      expect(rep.filesRead, 1);
      expect(repo.settings().salary, 4242);
      expect((await run()).filesRead, 0, reason: 'applied once');
    });

    test('a partial copy (0 bytes, then cut off, then whole) applies exactly when it is whole, then the file after it', () async {
      final full = await sealed([_setting('salary', 31)], null, _devA, 1);
      await put(_devA, 1, Uint8List(0));
      await good(_devA, 2, 'rent', 2);
      expect((await run()).problems, hasLength(1));
      expect((repo.settings().salary, repo.settings().rent), (0, 0));
      await put(_devA, 1, full.sublist(0, full.length ~/ 2));
      expect((await run()).problems, hasLength(1), reason: 'changed: looked at again, still bad');
      expect(repo.settings().salary, 0);
      await put(_devA, 1, full);
      final rep = await run();
      expect(rep.problems, isEmpty);
      expect((repo.settings().salary, repo.settings().rent), (31, 2));
    });

    test('different bad bytes of the same size are looked at again (hash, not only size)', () async {
      await put(_devA, 1, [1, 1, 1, 1, 1, 1]);
      expect((await run()).problems.single.isNew, isTrue);
      expect((await run()).problems.single.isNew, isFalse);
      await put(_devA, 1, [2, 2, 2, 2, 2, 2]);
      expect((await run()).problems.single.isNew, isTrue);
    });

    test('the same bytes stored again are not looked at again', () async {
      await put(_devA, 1, [1, 1, 1, 1, 1, 1]);
      await run();
      await put(_devA, 1, [1, 1, 1, 1, 1, 1]);
      expect((await run()).problems.single.isNew, isFalse);
    });

    test('the record of a bad file survives reopening the database', () async {
      final path = '${tmp.path}/w.db';
      final r1 = WalletRepo.open(path, now: _wall);
      await put(_devA, 1, [3, 3, 3]);
      expect((await SyncEngine(relay, key).run(r1)).problems, hasLength(1));
      r1.close();
      final r2 = WalletRepo.open(path, now: _wall);
      addTearDown(r2.close);
      expect((await SyncEngine(relay, key).run(r2)).problems.single.isNew, isFalse, reason: 'known from the record, not read again');
    });

    test('a bad file on one device does not hide the same seq being good on another device', () async {
      await put(_devA, 1, [5, 5, 5]);
      await good(_devB, 1, 'salary', 99);
      final rep = await run();
      expect(rep.problems, hasLength(1));
      expect(repo.settings().salary, 99);
    });
  });

  group('privacy of problems and logs', () {
    test('problems and waiting hold a short device id and a reason: never the whole id', () async {
      await put(_devA, 1, [1, 2, 3]);
      await put(_devA, 2, Uint8List(0));
      await put(_devB, 1, (await sealed([_setting('salary', 1)]))..[4] = '3'.codeUnitAt(0));
      final lines = capture();
      final rep = await run();
      expect(rep.problems, hasLength(2));
      final shown = [
        for (final p in rep.problems) '${p.device}|${p.reason.name}|$p',
        for (final w in rep.waiting) '${w.device}|$w',
        for (final d in rep.devices) '${d.device}|$d',
      ].join('\n');
      for (final p in rep.problems) {
        expect(p.device, isNotEmpty);
        expect(p.device.length, lessThan(_devA.length), reason: 'a short id, not the whole id');
        expect(_devA.startsWith(p.device) || _devB.startsWith(p.device), isTrue);
      }
      for (final bad in [_devA, _devB, repo.deviceId]) {
        expect(shown, isNot(contains(bad)), reason: 'report leaks "$bad"');
      }
      final logs = lines.join('\n');
      for (final bad in [_devA, _devB, SyncProblem.shortId(_devA), SyncProblem.shortId(_devB), repo.deviceId]) {
        expect(logs, isNot(contains(bad)), reason: 'logs leak "$bad"');
      }
    });

    test('logs of a run with bad files name no amounts or setting values', () async {
      final lines = capture();
      await put(_devA, 1, await sealed([_setting('salary', 987654)], VaultKey.generate()));
      await good(_devB, 1, 'rent', 424242);
      await run();
      expect(lines.join('\n'), allOf(isNot(contains('987654')), isNot(contains('424242'))));
    });
  });

  group('relay errors end the run', () {
    for (final f in [
      TransportFailure.unreachable,
      TransportFailure.refused,
      TransportFailure.full,
      TransportFailure.newerApi,
      TransportFailure.other
    ]) {
      test('${f.name} on state is a SyncException with a short message; nothing is applied or marked sent', () async {
        repo.updateSettings({'salary': 1});
        final e = await SyncEngine(_Failing(f), key).run(repo).then<Object?>((_) => null, onError: (Object e) => e);
        expect(e, isA<SyncException>());
        final msg = (e as SyncException).message;
        expect(msg, isNotEmpty);
        expect(msg, isNot(contains('http')));
        expect(msg, isNot(contains(repo.deviceId)));
        expect(repo.pendingOps(), hasLength(1));
        expect(repo.localValue(SyncEngine.sentKey), isNull);
      });
    }

    test('the messages tell the failures apart', () async {
      final msgs = <String>{};
      for (final f in [TransportFailure.unreachable, TransportFailure.refused, TransportFailure.full, TransportFailure.newerApi]) {
        try {
          await SyncEngine(_Failing(f), key).run(repo);
        } on SyncException catch (e) {
          msgs.add(e.message);
        }
      }
      expect(msgs, hasLength(4));
    });
  });
}
