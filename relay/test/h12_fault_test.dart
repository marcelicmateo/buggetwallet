// Stage H12 (relay storage faults): a crash between a file write and the meta save, a failed disk write, a damaged
// meta, truncated and missing files. The relay is stopped and started again over the same folder; the faults are
// made on the folder itself (the relay runs as root in the container, so permission tricks do not work: a directory
// in the place of a file makes the write fail the way a full or broken disk does). The `RelayTestHooks` seam of the
// Stage H contract lives in h12_hooks_test.dart. Synthetic ids only.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

const _t = Timeout(Duration(seconds: 30));

String _p(Harness h, String wid, String rest) => '${h.dir.path}/$wid/$rest';

Future<Map<String, Object?>> _norm(Harness h, String wallet, {TestKey? key}) async {
  final s = await h.state(wallet, key: key);
  final devices = (s['devices'] as Map<String, Object?>)
      .map((k, v) => MapEntry(k, Map<String, Object?>.of(v! as Map<String, Object?>)..remove('lastSeen')));
  return {...s, 'devices': devices};
}

void main() {
  group('a crash between the file write and the meta save', () {
    test('the file the meta does not know is found at the next start: last includes it, the same PUT is idempotent', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      File(_p(h, w1, 'd/dev1/3')).writeAsStringSync('three'); // written, meta never saved
      await h.restart();
      expect((await h.device(w1, 'dev1'))['last'], 3);
      expect((await h.getData(w1, 'dev1', 3)).body, 'three');
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 200, reason: 'the client retries what it never saw acknowledged');
      expect((await h.putData(w1, 'dev1', 3, 'THREE')).statusCode, 409);
      expect((await h.putData(w1, 'dev1', 4, 'four')).statusCode, 201);
    }, timeout: _t);

    test('a device whose first file was written but never recorded: the wallet exists again with that device', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      Directory(_p(h, w1, 'd/dev2')).createSync(recursive: true);
      File(_p(h, w1, 'd/dev2/1')).writeAsStringSync('x');
      await h.restart();
      final s = await h.state(w1);
      expect((s['devices'] as Map<String, Object?>).keys, containsAll(['dev1', 'dev2']));
      expect((await h.getData(w1, 'dev2', 1)).body, 'x');
    }, timeout: _t);

    test('a snapshot file the meta does not name is deleted at start (it was never acknowledged), and its id can be used again', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      Directory(_p(h, w1, 'snap')).createSync(recursive: true);
      File(_p(h, w1, 'snap/s9')).writeAsStringSync('orphan');
      await h.restart();
      expect(File(_p(h, w1, 'snap/s9')).existsSync(), isFalse);
      expect((await h.getSnapshot(w1, 's9')).statusCode, 404);
      expect((await h.putSnapshot(w1, 's9', {'dev1': 1}, 'real')).statusCode, anyOf(200, 201));
      expect((await h.getSnapshot(w1, 's9')).body, 'real');
    }, timeout: _t);

    test('a temp file left by a crash inside writeAtomic of a data file is removed and never shown', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      File(_p(h, w1, 'd/dev1/.tmp-4242-7')).writeAsStringSync('half');
      await h.restart();
      final names = Directory(h.dir.path).listSync(recursive: true).map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last);
      expect(names.where((n) => n.startsWith('.tmp')), isEmpty);
      expect((await h.device(w1, 'dev1'))['last'], 1);
    }, timeout: _t);

    test('a temp file of an interrupted meta save (in the wallet folder) is removed at the next start', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      File(_p(h, w1, '.tmp-4242-8')).writeAsStringSync('{"v":2');
      await h.restart();
      final names = Directory(h.dir.path).listSync(recursive: true).map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last);
      expect(names.where((n) => n.startsWith('.tmp')), isEmpty);
    }, timeout: _t);

    test('the meta save fails after the file was written: 5xx, then the retry of the same bytes succeeds and a restart agrees', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final meta = File(_p(h, w1, 'meta.json'));
      final saved = meta.readAsStringSync();
      meta.deleteSync();
      Directory(meta.path).createSync(); // the rename of the new meta onto it fails
      final failed = await h.putData(w1, 'dev1', 2, 'two');
      expect(failed.statusCode, greaterThanOrEqualTo(500), reason: 'an I/O failure is not the client\'s fault');
      expect(h.logs.join('\n'), isNot(contains('two')), reason: 'no body in the log');
      Directory(meta.path).deleteSync();
      meta.writeAsStringSync(saved);
      // The file is on disk although the meta never named it: the retry is the same bytes, so it is accepted.
      final retry = await h.putData(w1, 'dev1', 2, 'two');
      expect(retry.statusCode, anyOf(200, 201));
      final before = await _norm(h, w1);
      expect((before['devices'] as Map<String, Object?>)['dev1'], containsPair('last', 2));
      await h.restart();
      expect(await _norm(h, w1), before);
      expect((await h.getData(w1, 'dev1', 2)).body, 'two');
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201, reason: 'no gap, no stuck seq');
    }, timeout: _t);
  });

  group('a failed disk write (standing in for disk full)', () {
    test('a data write that fails leaves the state as it was; once the obstacle is gone the same PUT works with no gap', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      final before = await _norm(h, w1);
      Directory(_p(h, w1, 'd/dev1/2')).createSync(); // the rename onto a directory fails
      final failed = await h.putData(w1, 'dev1', 2, 'two');
      expect(failed.statusCode, greaterThanOrEqualTo(500));
      Directory(_p(h, w1, 'd/dev1/2')).deleteSync();
      expect(await _norm(h, w1), before, reason: 'a failed write is not a stored file');
      expect((await h.device(w1, 'dev1'))['last'], 1);
      expect((await h.getData(w1, 'dev1', 2)).statusCode, anyOf(404, 422));
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 3, 'three')).statusCode, 201);
      expect((await h.get('/v2/health')).statusCode, 200, reason: 'the relay stays up');
    }, timeout: _t);

    test('a failed write leaves no temp file after a restart, and its bytes never count against the quota', () async {
      final h = await freshHarness(minFileCost: 1, maxBytes: 100);
      expect((await h.putData(w1, 'dev1', 1, 'a' * 60)).statusCode, 201);
      Directory(_p(h, w1, 'd/dev1/2')).createSync();
      expect((await h.putData(w1, 'dev1', 2, 'b' * 30)).statusCode, greaterThanOrEqualTo(500));
      Directory(_p(h, w1, 'd/dev1/2')).deleteSync();
      // 60 stored + 39 fits only if the 30 bytes that never reached the disk were not counted (60 + 30 + 39 would not).
      expect((await h.putData(w1, 'dev1', 2, 'c' * 39)).statusCode, 201);
      await h.restart();
      final names = Directory(h.dir.path).listSync(recursive: true).map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last);
      expect(names.where((n) => n.startsWith('.tmp')), isEmpty, reason: 'the failed write\'s temp file is cleaned at the next start');
      // After the restart the count is rebuilt from the disk: 99 bytes, so two more do not fit and one would.
      expect((await h.putData(w1, 'dev1', 3, 'dd')).statusCode, anyOf(507, 413));
      expect((await h.device(w1, 'dev1'))['last'], 2);
    }, timeout: _t);

    test('a failed snapshot write is not kept and prunes nothing', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      Directory(_p(h, w1, 'snap')).createSync(recursive: true);
      Directory(_p(h, w1, 'snap/s1')).createSync();
      final failed = await h.putSnapshot(w1, 's1', {'dev1': 2}, 'snap');
      expect(failed.statusCode, greaterThanOrEqualTo(500));
      Directory(_p(h, w1, 'snap/s1')).deleteSync();
      final s = await h.state(w1);
      expect(s['snapshot'], isNull);
      expect((s['devices'] as Map<String, Object?>)['dev1'], containsPair('first', 1));
      expect((await h.getData(w1, 'dev1', 1)).statusCode, 200,
          reason: 'nothing was pruned on the strength of a snapshot that is not there');
    }, timeout: _t);

    test('the relay quota (--max-bytes) is the 507 path: refused, state unchanged, a smaller file still fits', () async {
      final h = await freshHarness(minFileCost: 1, maxBytes: 100);
      expect((await h.putData(w1, 'dev1', 1, 'a' * 60)).statusCode, 201);
      final before = await _norm(h, w1);
      final full = await h.putData(w1, 'dev1', 2, 'b' * 60);
      expect(full.statusCode, anyOf(507, 413));
      expect(await _norm(h, w1), before);
      expect((await h.putData(w1, 'dev1', 2, 'c' * 20)).statusCode, 201);
    }, timeout: _t);
  });

  group('damaged files on disk', () {
    for (final (name, content) in [
      ('truncated', '{"v":2,"pub":"abc'),
      ('empty', ''),
      ('not json', 'hello'),
      ('a list', '[1,2,3]'),
      ('wrong types', '{"v":2,"pub":5,"devices":"x"}'),
      ('v1 token hash', '{"v":1,"token":"abcdef"}'),
    ]) {
      test('meta.json $name: the relay starts, that folder is not a wallet, the other wallet is untouched', () async {
        final h = await freshHarness();
        await h.putData(w1, 'dev1', 1, 'one');
        await h.putData(w2, 'devX', 1, 'other', key: keyB);
        final other = await _norm(h, w2, key: keyB);
        File(_p(h, w1, 'meta.json')).writeAsStringSync(content);
        await h.restart();
        expect(h.relay.walletCount, 1);
        expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 404);
        expect(await _norm(h, w2, key: keyB), other);
        expect((await h.get('/v2/health')).statusCode, 200);
        // The owner's next first PUT starts the wallet again (documented: a folder without a readable meta is not a wallet).
        expect((await h.putData(w1, 'dev1', 1, 'again')).statusCode, 201);
      }, timeout: _t);
    }

    test('a truncated data file is served as it is (the relay cannot read it) and counts at its real size', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'a' * 1000);
      File(_p(h, w1, 'd/dev1/1')).writeAsStringSync('a' * 10);
      await h.restart();
      final r = await h.getData(w1, 'dev1', 1);
      expect(r.statusCode, 200);
      expect(r.body.length, 10, reason: 'the client\'s unseal reports it damaged; the relay does not guess');
      final s = await h.state(w1);
      expect((s['devices'] as Map<String, Object?>)['dev1'], containsPair('last', 1));
    }, timeout: _t);

    test('a data file that vanished: the other files of the device still serve, the state does not crash', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      File(_p(h, w1, 'd/dev1/1')).deleteSync();
      expect((await h.getData(w1, 'dev1', 2)).body, 'two');
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 200);
      await h.restart();
      expect((await h.getData(w1, 'dev1', 2)).body, 'two');
    }, timeout: _t);

    test('a missing file of a known device is 404 {"error":"missing"}, not a 500', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'one');
      await h.putData(w1, 'dev1', 2, 'two');
      File(_p(h, w1, 'd/dev1/2')).deleteSync();
      final r = await h.getData(w1, 'dev1', 2);
      expect(r.statusCode, 404);
      expect(jsonDecode(r.body), {'error': 'missing'});
    }, timeout: _t);

    test('a damaged meta.json next to data files: the wallet is gone, its data files are not served to another key', () async {
      final h = await freshHarness();
      await h.putData(w1, 'dev1', 1, 'secret-ish');
      File(_p(h, w1, 'meta.json')).writeAsStringSync('{');
      await h.restart();
      final r = await h.getData(w1, 'dev1', 1, key: keyB);
      expect(r.statusCode, anyOf(401, 404));
      expect(r.body, isNot(contains('secret-ish')));
    }, timeout: _t);
  });
}
