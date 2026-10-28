// M2: the state digest read off the UI isolate (`stateDigestAsync`): a file database is read in another isolate on its
// own read-only connection; in-memory repos (and the web's `fromDatabase`) keep the synchronous path. All data is
// SYNTHETIC.
import 'dart:async';
import 'dart:io';

import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:test/test.dart';
import 'package:wallet_core/src/sqlite_io.dart' show readInIsolate;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

/// Isolate reader that starts its snapshot, says so (`<db>.snap`), then holds it until the main isolate committed
/// (`<db>.go`), and reports the `loan` rows it saw before and after: `loan <before> <after>`.
(String, int) _heldRead(CommonDatabase db) {
  final path = db.select('PRAGMA database_list').first['file'] as String;
  int loans() => db.select("SELECT COUNT(*) AS n FROM settings WHERE id = 'loan'").first['n'] as int;
  final before = loans(); // the first read starts the WAL snapshot
  File('$path.snap').writeAsStringSync('');
  final sw = Stopwatch()..start();
  while (!File('$path.go').existsSync()) {
    if (sw.elapsed > const Duration(seconds: 30)) throw StateError('the main isolate never committed');
    sleep(const Duration(milliseconds: 2));
  }
  return ('loan $before ${loans()}', 0);
}

/// Waits (bounded) until the isolate reader has started its snapshot.
Future<void> _started(String db) async {
  final sw = Stopwatch()..start();
  while (!File('$db.snap').existsSync()) {
    if (sw.elapsed > const Duration(seconds: 30)) fail('the reader never started');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

const _t0 = 1767225600000;
String _hlc(int ms, [String node = 'n1']) => Hlc(_t0 + ms, 0, node).toString();
Op _setting(String id, Object? value, int ms) => Op('setting', id, {'value': value, 'deleted': 0}, _hlc(ms));

List<LogEvent> _capture() {
  final events = <LogEvent>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) {
    if (r.object case final LogEvent e) events.add(e);
  });
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = was;
  });
  return events;
}

void main() {
  late Directory dir;
  final repos = <WalletRepo>[];
  int now() => _t0 + 100000;
  setUp(() => dir = Directory.systemTemp.createTempSync('bw_digest_async_'));
  tearDown(() {
    for (final r in repos) {
      r.close();
    }
    repos.clear();
    dir.deleteSync(recursive: true);
  });

  WalletRepo file(String name, {List<int>? dbKey}) => WalletRepo.open('${dir.path}/$name.db', dbKey: dbKey, now: now)..also(repos.add);
  WalletRepo memory() => WalletRepo.inMemory(now: now)..also(repos.add);
  final dbKey = List<int>.generate(32, (i) => (i * 7 + 3) & 0xff); // synthetic key

  /// A small synthetic wallet: an import plus settings, the same ops on every repo given.
  void fill(WalletRepo r) => r
    ..importBatch(january)
    ..applyRemote([_setting('salary', '150000', 1), _setting('rent', '50000', 2)], match: false);

  group('stateDigestAsync', () {
    for (final keyed in [false, true]) {
      test('a file database${keyed ? ' (encrypted)' : ''}: read in another isolate, the same digest as the synchronous path', () async {
        final events = _capture();
        final f = file('a', dbKey: keyed ? dbKey : null);
        fill(f);
        final m = memory()..applyRemote(f.snapshotOps(), match: false); // same rows and clocks
        final runs = f.stateDigestComputations;
        final d = await f.stateDigestAsync();
        expect(d, m.stateDigest());
        expect(events.map((e) => e.event), contains('repo.stateDigest.isolate'));
        expect(events.where((e) => e.event == 'repo.stateDigest' && e.fields['isolate'] == true), hasLength(1));
        expect(f.stateDigestComputations, runs + 1);
        expect(f.stateDigest(), d, reason: 'cached for this dataVersion');
        expect(f.stateDigestComputations, runs + 1);
        // A change committed (in the WAL, not checkpointed) is seen by the second connection.
        f.applyRemote([_setting('loan', '1', 30)], match: false);
        m.applyRemote([_setting('loan', '1', 30)], match: false);
        expect(await f.stateDigestAsync(), m.stateDigest());
        // And the synchronous path on the same file agrees with the isolate's.
        final g = file('b', dbKey: keyed ? dbKey : null);
        g.applyRemote(f.snapshotOps(), match: false);
        expect(g.stateDigest(), await f.stateDigestAsync());
      });
    }

    test('a write while the digest is read: discarded (null, never cached), the next call reads the new state', () async {
      final f = file('a');
      fill(f);
      final m = memory()..applyRemote(f.snapshotOps(), match: false);
      final runs = f.stateDigestComputations;
      final pending = f.stateDigestAsync();
      f.applyRemote([_setting('loan', '1', 30)], match: false); // committed while the isolate reads
      expect(await pending, isNull);
      expect(f.stateDigestComputations, runs, reason: 'a stale result is not cached');
      m.applyRemote([_setting('loan', '1', 30)], match: false);
      expect(await f.stateDigestAsync(), m.stateDigest());

      // A version whose digest is cached is answered at once (that state is the one asked for); a new one is read.
      final cached = f.stateDigestAsync();
      f.applyRemote([_setting('loan', '2', 31)], match: false);
      expect(await cached, m.stateDigest());
      final owner = f.stateDigestAsync();
      f.updateSettings({'salary': 160000}); // an owner write (outbox) does the same
      expect(await owner, isNull);
      final copy = memory()..applyRemote(f.snapshotOps(), match: false);
      expect(await f.stateDigestAsync(), copy.stateDigest());
    });

    test('the isolate reads the old state and the main isolate commits afterwards: null, nothing cached', () async {
      final f = file('a');
      fill(f);
      final db = '${dir.path}/a.db';
      // The reader's snapshot really is the old state, whatever commits meanwhile.
      final read = readInIsolate(db, null, _heldRead);
      await _started(db);
      f.applyRemote([_setting('loan', '1', 30)], match: false);
      File('$db.go').writeAsStringSync('');
      expect(await read, ('loan 0 0', 0));

      File('$db.snap').deleteSync();
      File('$db.go').deleteSync();
      WalletRepo.debugDigestReader = _heldRead;
      addTearDown(() => WalletRepo.debugDigestReader = null);
      final runs = f.stateDigestComputations;
      final pending = f.stateDigestAsync();
      await _started(db);
      f.applyRemote([_setting('loan', '2', 31)], match: false); // committed after the isolate's snapshot began
      File('$db.go').writeAsStringSync('');
      expect(await pending, isNull);
      expect(f.stateDigestComputations, runs, reason: 'nothing cached');
      WalletRepo.debugDigestReader = null;
      final copy = memory()..applyRemote(f.snapshotOps(), match: false);
      expect(await f.stateDigestAsync(), copy.stateDigest());
      expect(f.stateDigestComputations, runs + 1);
    });

    test('atVersion: a version the data already left gives null; the current one the digest', () async {
      final f = file('a');
      fill(f);
      final v = f.dataVersion;
      f.applyRemote([_setting('loan', '1', 30)], match: false);
      expect(await f.stateDigestAsync(atVersion: v), isNull);
      expect(await f.stateDigestAsync(atVersion: f.dataVersion), f.stateDigest());
      final m = memory();
      fill(m);
      expect(await m.stateDigestAsync(atVersion: m.dataVersion - 1), isNull);
    });

    test('in memory: the synchronous path (no isolate), same text and cache', () async {
      final events = _capture();
      final m = memory();
      fill(m);
      final runs = m.stateDigestComputations;
      final d = await m.stateDigestAsync();
      expect(d, m.stateDigest());
      expect(m.stateDigestComputations, runs + 1);
      expect(events.map((e) => e.event), isNot(contains('repo.stateDigest.isolate')));
      expect(events.where((e) => e.event == 'repo.stateDigest').single.fields['isolate'], false);
    });

    test('the file cannot be opened by the isolate: logged, falls back to the synchronous path', () async {
      final events = _capture();
      final f = file('a');
      fill(f);
      final m = memory()..applyRemote(f.snapshotOps(), match: false);
      // The main connection keeps its open file; a new connection finds nothing at the path (never created there).
      File('${dir.path}/a.db').renameSync('${dir.path}/moved.db');
      expect(await f.stateDigestAsync(), m.stateDigest());
      expect(events.map((e) => e.event), contains('repo.stateDigest.isolateFailed'));
      expect(File('${dir.path}/a.db').existsSync(), isFalse, reason: 'the reader never creates a database');
    });

    test('20k-row file wallet: the UI isolate stays free while the digest is read (numbers in the output, no limit)', () async {
      final f = file('big', dbKey: dbKey);
      final start = DateTime.utc(2021, 1, 1);
      f.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (var i = 0; i < 20000; i++)
          n(start.add(Duration(days: i ~/ 11)).toIso8601String().substring(0, 10), -(100 + i % 9000), 'POS', 'SHOP ${i % 400} ZAGREB',
              occ: i),
      ]));
      // Longest gap between event-loop turns on this isolate while the digest is read elsewhere.
      var maxGap = 0;
      var last = Stopwatch()..start();
      final tick = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (last.elapsedMilliseconds > maxGap) maxGap = last.elapsedMilliseconds;
        last = Stopwatch()..start();
      });
      var sw = Stopwatch()..start();
      final d = await f.stateDigestAsync();
      final asyncMs = sw.elapsedMilliseconds;
      tick.cancel();
      f.applyRemote([_setting('loan', '1', 30)], match: false);
      sw = Stopwatch()..start();
      final s = f.stateDigest();
      final syncMs = sw.elapsedMilliseconds;
      expect(d, isNotNull);
      expect(s, isNot(d));
      expect(await f.stateDigestAsync(), s);
      // ignore: avoid_print
      print('M2 perf: rows 20000 (encrypted file), stateDigestAsync ${asyncMs}ms wall, longest UI-isolate gap ${maxGap}ms; '
          'stateDigest on the UI isolate ${syncMs}ms');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
