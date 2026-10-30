// HP-T1: invariants of the quarantine records (sync_problems.dart). All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_sync/src/sync_problems.dart';

BadFile bad(SyncProblemReason r, {String build = 'b1', int? retryAt, int size = 10, String? stamp}) =>
    BadFile('dev0123456789', '7.sync', r, size: size, stamp: stamp, hash: 'h', build: build, retryAt: retryAt);

void main() {
  test('shortId keeps up to 8 characters and cuts longer ids at exactly 8', () {
    expect(SyncProblem.shortId(''), '');
    expect(SyncProblem.shortId('abcdefg'), 'abcdefg');
    expect(SyncProblem.shortId('abcdefgh'), 'abcdefgh');
    expect(SyncProblem.shortId('abcdefghi'), 'abcdefgh');
  });

  test('toString names snapshot, reason, bytes and new', () {
    expect(const SyncProblem('d', SyncProblemReason.corrupt, bytes: 5).toString(), 'SyncProblem(corrupt, 5 bytes, new)');
    expect(const SyncProblem('', SyncProblemReason.corrupt, bytes: 5, isNew: false, snapshot: true).toString(),
        'SyncProblem(snapshot, corrupt, 5 bytes)');
  });

  test('key joins device and file; keyOf agrees', () {
    expect(bad(SyncProblemReason.corrupt).key, 'dev0123456789/7.sync');
    expect(BadFile.keyOf('a', 'b'), 'a/b');
  });

  group('retryAfterUpgrade: only the three upgrade-sensitive reasons, only when the build differs', () {
    for (final r in SyncProblemReason.values) {
      final sensitive = {SyncProblemReason.unknownVersion, SyncProblemReason.applyFailed, SyncProblemReason.clockDrift}.contains(r);
      test(r.name, () {
        expect(bad(r).retryAfterUpgrade('b2'), sensitive);
        expect(bad(r).retryAfterUpgrade('b1'), false, reason: 'same build never retries');
      });
    }
  });

  test('retryNow: upgrade, or the wall clock reached retryAt (inclusive); never without either', () {
    final drift = bad(SyncProblemReason.clockDrift, retryAt: 1000);
    expect(drift.retryNow('b1', 999), false);
    expect(drift.retryNow('b1', 1000), true);
    expect(drift.retryNow('b1', 1001), true);
    expect(drift.retryNow('b2', 0), true);
    final corrupt = bad(SyncProblemReason.corrupt);
    expect(corrupt.retryNow('b1', 1 << 50), false);
    expect(corrupt.retryNow('b2', 0), false);
    expect(bad(SyncProblemReason.corrupt, retryAt: 5).retryNow('b1', 5), true);
  });

  test('listedChanged: size or stamp differs', () {
    final b = bad(SyncProblemReason.corrupt, size: 10, stamp: 's');
    expect(b.listedChanged(10, 's'), false);
    expect(b.listedChanged(11, 's'), true);
    expect(b.listedChanged(10, 't'), true);
    expect(b.listedChanged(10, null), true);
    expect(bad(SyncProblemReason.corrupt).listedChanged(10, null), false);
  });

  test('problem carries the short id, reason, size and the given isNew', () {
    final p = bad(SyncProblemReason.corrupt, size: 42).problem(isNew: false);
    expect(p.device, 'dev01234');
    expect(p.reason, SyncProblemReason.corrupt);
    expect(p.bytes, 42);
    expect(p.isNew, false);
    expect(p.snapshot, false);
    expect(bad(SyncProblemReason.corrupt).problem(isNew: true).isNew, true);
  });

  group('toJson / fromJson', () {
    test('round trip keeps every field, with and without retryAt and stamp', () {
      for (final b in [bad(SyncProblemReason.clockDrift, retryAt: 77, stamp: 'st'), bad(SyncProblemReason.applyFailed)]) {
        final c = BadFile.fromJson(b.toJson())!;
        expect((c.device, c.file, c.reason, c.size, c.stamp, c.hash, c.build, c.retryAt),
            (b.device, b.file, b.reason, b.size, b.stamp, b.hash, b.build, b.retryAt));
      }
      expect(bad(SyncProblemReason.corrupt).toJson().containsKey('u'), false);
      expect(bad(SyncProblemReason.corrupt, retryAt: 1).toJson()['u'], 1);
    });

    test('each malformed field alone makes it null', () {
      final ok = bad(SyncProblemReason.corrupt, stamp: 's', retryAt: 3).toJson();
      expect(BadFile.fromJson(ok), isNotNull);
      expect(BadFile.fromJson('x'), isNull);
      expect(BadFile.fromJson(null), isNull);
      for (final bogus in <String, Object?>{'r': 'nope', 'd': 1, 'f': 1, 'n': '1', 's': 1, 'h': 1, 'b': 1, 'u': '1'}.entries) {
        expect(BadFile.fromJson({...ok, bogus.key: bogus.value}), isNull, reason: bogus.key);
      }
      for (final missing in ['r', 'd', 'f', 'n', 'h', 'b']) {
        expect(BadFile.fromJson({...ok}..remove(missing)), isNull, reason: 'missing $missing');
      }
      final noOptional = {...ok}
        ..remove('s')
        ..remove('u');
      expect(BadFile.fromJson(noOptional), isNotNull);
    });
  });

  test('fileHash: first 16 bytes of SHA-256 as 32 lowercase hex, zero-padded', () async {
    expect(await fileHash('abc'.codeUnits), 'ba7816bf8f01cfea414140de5dae2223');
    expect(await fileHash(const []), 'e3b0c44298fc1c149afbf4c8996fb924');
    for (var i = 0; i < 40; i++) {
      final h = await fileHash([i]);
      expect(h, matches(RegExp(r'^[0-9a-f]{32}$')));
    }
  });
}
