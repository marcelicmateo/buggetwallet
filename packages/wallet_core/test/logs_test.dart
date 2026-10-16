// Tests for the logging contract (lib/src/logs.dart), written from the feature spec, not the implementation.
// All data here is synthetic.
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

/// A copy of [r] with a fixed [time], so formatted lines are deterministic.
class _AtTime extends LogRecord {
  _AtTime(LogRecord r, this._t) : super(r.level, r.message, r.loggerName, r.error, r.stackTrace, r.zone, r.object);
  final DateTime _t;
  @override
  DateTime get time => _t;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// `+HH:MM` / `-HH:MM` for the zone [t] is in (computed, because the test machine's zone is not fixed).
String _offset(DateTime t) {
  final o = t.timeZoneOffset;
  final m = o.inMinutes.abs();
  return '${o.isNegative ? '-' : '+'}${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// Collects records published on [logger] until the test ends.
List<LogRecord> _capture(Logger logger) {
  final out = <LogRecord>[];
  final sub = logger.onRecord.listen(out.add);
  addTearDown(() async {
    await sub.cancel();
  });
  return out;
}

/// Turns on hierarchical logging and gives [names] their own level for one test; restores everything after.
void _levels(Map<String, Level> names) {
  final wasHierarchical = hierarchicalLoggingEnabled;
  hierarchicalLoggingEnabled = true;
  names.forEach((name, level) => Logger(name).level = level);
  addTearDown(() {
    for (final name in names.keys) {
      Logger(name).level = null;
    }
    hierarchicalLoggingEnabled = wasHierarchical;
  });
}

/// The JSON fields at the end of a record's first formatted line (insertion order kept).
Map<String, Object?> _fields(LogRecord r) {
  final first = formatLogRecord(r).split('\n').first;
  final i = first.indexOf(' {');
  expect(i, greaterThan(0), reason: 'no fields in "$first"');
  return jsonDecode(first.substring(i + 1)) as Map<String, Object?>;
}

String _base(File f) => f.uri.pathSegments.last;

/// A 40-byte line on disk (39 ASCII chars + newline).
String _line(int i) => 'line ${i.toString().padLeft(3, '0')} ${'x' * 30}';

List<String> _content(RotatingFileSink sink) => [for (final f in sink.files()) ...f.readAsLinesSync()];

int _bytes(RotatingFileSink sink) => sink.files().fold(0, (sum, f) => sum + f.lengthSync());

void main() {
  group('formatLogRecord', () {
    final t = DateTime(2026, 10, 16, 19, 1, 2, 123);
    final ts = '2026-10-16T19:01:02.123${_offset(t)}';

    test('time with ms and UTC offset, level, logger, message; no fields → no suffix', () {
      final r = _AtTime(LogRecord(Level.INFO, 'app.start', 'bw.app'), t);
      expect(formatLogRecord(r), '$ts INFO bw.app app.start');
    });

    test('milliseconds are zero-padded to 3 digits and microseconds dropped', () {
      final a = DateTime(2026, 3, 7, 4, 5, 6, 5);
      final b = DateTime(2026, 3, 7, 4, 5, 6, 0, 999);
      expect(formatLogRecord(_AtTime(LogRecord(Level.INFO, 'e', 'bw.app'), a)), '2026-03-07T04:05:06.005${_offset(a)} INFO bw.app e');
      expect(formatLogRecord(_AtTime(LogRecord(Level.INFO, 'e', 'bw.app'), b)), '2026-03-07T04:05:06.000${_offset(b)} INFO bw.app e');
    });

    test('a UTC record time is written as local time with its offset', () {
      final u = DateTime.utc(2026, 1, 5, 23, 59, 58, 7);
      final l = u.toLocal();
      final expected = '${l.year}-${_two(l.month)}-${_two(l.day)}T${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}'
          '.${l.millisecond.toString().padLeft(3, '0')}${_offset(l)}';
      expect(formatLogRecord(_AtTime(LogRecord(Level.INFO, 'e', 'bw.app'), u)), '$expected INFO bw.app e');
    });

    test('level names: INFO, WARNING, SEVERE as in package:logging; FINE as FINE or DEBUG', () {
      String level(Level lv) => formatLogRecord(_AtTime(LogRecord(lv, 'e', 'bw.x'), t)).split(' ')[1];
      expect(level(Level.INFO), 'INFO');
      expect(level(Level.WARNING), 'WARNING');
      expect(level(Level.SEVERE), 'SEVERE');
      // The spec's example line says DEBUG for a debug event, but package:logging calls that level FINE.
      expect(level(Level.FINE), anyOf('FINE', 'DEBUG'));
    });

    test('event fields are JSON in insertion order after one space', () {
      final logger = Logger('bw.test.fmt');
      _levels({'bw.test.fmt': Level.ALL});
      final got = _capture(logger);
      logEvent(logger, Level.INFO, 'import.done', {'rows': 312, 'dupes': 4, 'ms': 41});
      expect(got, hasLength(1));
      expect(formatLogRecord(_AtTime(got.single, t)), '$ts INFO bw.test.fmt import.done {"rows":312,"dupes":4,"ms":41}');
    });

    test('field values of every scalar type are JSON-encoded', () {
      final logger = Logger('bw.test.fmt');
      _levels({'bw.test.fmt': Level.ALL});
      final got = _capture(logger);
      logEvent(logger, Level.INFO, 'nav.tab', {'tab': 'plan', 'ok': true, 'none': null, 'ratio': 0.5, 'n': -3});
      expect(
          formatLogRecord(_AtTime(got.single, t)), '$ts INFO bw.test.fmt nav.tab {"tab":"plan","ok":true,"none":null,"ratio":0.5,"n":-3}');
    });

    test('error and stack trace lines follow, indented by two spaces', () {
      final stack = StackTrace.fromString('#0      SyncThing.run (file:///a.dart:10:5)\n#1      main (file:///b.dart:3:1)');
      final r = _AtTime(LogRecord(Level.SEVERE, 'sync.failed', 'bw.sync', const FormatException('bad header'), stack), t);
      expect(formatLogRecord(r).split('\n'), [
        '$ts SEVERE bw.sync sync.failed',
        '  error: FormatException: bad header',
        '  #0      SyncThing.run (file:///a.dart:10:5)',
        '  #1      main (file:///b.dart:3:1)',
      ]);
    });

    test('a stack trace ending in a newline adds no extra content line', () {
      final stack = StackTrace.fromString('#0      f (file:///a.dart:1:1)\n');
      final r = _AtTime(LogRecord(Level.SEVERE, 'boom', 'bw.error', StateError('nope'), stack), t);
      expect(formatLogRecord(r).trimRight().split('\n'), [
        '$ts SEVERE bw.error boom',
        '  error: Bad state: nope',
        '  #0      f (file:///a.dart:1:1)',
      ]);
    });

    test('error without a stack trace', () {
      final r = _AtTime(LogRecord(Level.WARNING, 'key.read', 'bw.vault', StateError('locked')), t);
      expect(formatLogRecord(r).trimRight().split('\n'), ['$ts WARNING bw.vault key.read', '  error: Bad state: locked']);
    });
  });

  group('logEvent', () {
    test('level, logger, event and fields reach a listener on the logger', () {
      final logger = Logger('bw.test.events');
      _levels({'bw.test.events': Level.ALL});
      final got = _capture(logger);
      logEvent(logger, Level.FINE, 'import.done', {'rows': 312, 'dupes': 4, 'ms': 41});
      expect(got, hasLength(1));
      final r = got.single;
      expect(r.level, Level.FINE);
      expect(r.loggerName, 'bw.test.events');
      expect(r.message, startsWith('import.done'));
      expect(formatLogRecord(r), endsWith(' bw.test.events import.done {"rows":312,"dupes":4,"ms":41}'));
      expect(_fields(r).keys.toList(), ['rows', 'dupes', 'ms']);
    });

    test('without fields the line ends at the event name', () {
      final logger = Logger('bw.test.events');
      _levels({'bw.test.events': Level.ALL});
      final got = _capture(logger);
      logEvent(logger, Level.INFO, 'app.start');
      expect(got.single.level, Level.INFO);
      expect(formatLogRecord(got.single), endsWith(' bw.test.events app.start'));
      expect(formatLogRecord(got.single), isNot(contains('{')));
    });

    test('respects the logger level', () {
      final logger = Logger('bw.test.events');
      _levels({'bw.test.events': Level.INFO});
      final got = _capture(logger);
      logEvent(logger, Level.FINE, 'too.chatty', {'n': 1});
      logEvent(logger, Level.WARNING, 'slow', {'n': 2});
      expect(got.map((r) => r.level).toList(), [Level.WARNING]);
      expect(_fields(got.single), {'n': 2});
    });

    test('records propagate to parent loggers', () {
      final child = Logger('bw.test.events.child');
      _levels({'bw.test.events': Level.ALL});
      final got = _capture(Logger('bw.test.events'));
      logEvent(child, Level.INFO, 'child.event', {'k': 'v'});
      expect(got.single.loggerName, 'bw.test.events.child');
      expect(formatLogRecord(got.single), endsWith(' bw.test.events.child child.event {"k":"v"}'));
    });
  });

  group('RotatingFileSink', () {
    late Directory dir;
    late DateTime clock;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('bw_logs_test_');
      clock = DateTime(2026, 3, 7, 10, 30);
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    RotatingFileSink sink({int? maxFileBytes, int? maxTotalBytes}) => RotatingFileSink(dir,
        maxFileBytes: maxFileBytes ?? 2 * 1024 * 1024, maxTotalBytes: maxTotalBytes ?? 20 * 1024 * 1024, now: () => clock);
    File day(String name) => File('${dir.path}/$name');

    test('buffers lines: nothing on disk before flush; flush appends to bw-YYYY-MM-DD.log', () async {
      final s = sink();
      s.add('first line');
      s.add('second line');
      final f = day('bw-2026-03-07.log');
      expect(!f.existsSync() || f.lengthSync() == 0, isTrue, reason: 'add() must not write synchronously');
      await s.flush();
      expect(f.readAsLinesSync(), ['first line', 'second line']);
      expect(f.readAsStringSync(), endsWith('second line\n'));
      s.add('third line');
      await s.flush();
      expect(f.readAsLinesSync(), ['first line', 'second line', 'third line']);
      expect(s.files().map(_base).toList(), ['bw-2026-03-07.log']);
      await s.close();
    });

    test('close flushes the buffer', () async {
      final s = sink();
      s.add('only line');
      await s.close();
      expect(day('bw-2026-03-07.log').readAsLinesSync(), ['only line']);
    });

    test('rotates to .1, .2, … when a file exceeds maxFileBytes', () async {
      final s = sink(maxFileBytes: 100);
      final lines = [for (var i = 1; i <= 10; i++) _line(i)];
      for (final l in lines) {
        s.add(l);
        await s.flush();
      }
      final names = s.files().map(_base).toList();
      expect(names.length, greaterThanOrEqualTo(3));
      expect(names.take(3), ['bw-2026-03-07.log', 'bw-2026-03-07.1.log', 'bw-2026-03-07.2.log']);
      expect(names, everyElement(startsWith('bw-2026-03-07.')));
      expect(_content(s), lines, reason: 'every line kept, in order, across the rotated files');
      // A 40-byte line never fits exactly: whichever moment the sink rotates (before or after crossing the limit),
      // every full file holds more than 60 and at most 140 bytes.
      final files = s.files();
      for (final f in files.take(files.length - 1)) {
        expect(f.lengthSync(), allOf(greaterThan(60), lessThanOrEqualTo(140)), reason: _base(f));
      }
      await s.close();
    });

    test('files() is oldest first, also past .9 (numeric, not lexical order)', () async {
      final s = sink(maxFileBytes: 100);
      final lines = [for (var i = 1; i <= 40; i++) _line(i)];
      for (final l in lines) {
        s.add(l);
        await s.flush();
      }
      final names = s.files().map(_base).toList();
      expect(names.length, greaterThanOrEqualTo(12));
      expect(names, [
        'bw-2026-03-07.log',
        for (var i = 1; i < names.length; i++) 'bw-2026-03-07.$i.log',
      ]);
      expect(_content(s), lines);
      await s.close();
    });

    test('a new day starts a new file', () async {
      final s = sink();
      s.add('day one');
      await s.flush();
      clock = DateTime(2026, 3, 8, 0, 0, 1);
      s.add('day two');
      await s.flush();
      expect(day('bw-2026-03-07.log').readAsLinesSync(), ['day one']);
      expect(day('bw-2026-03-08.log').readAsLinesSync(), ['day two']);
      expect(s.files().map(_base).toList(), ['bw-2026-03-07.log', 'bw-2026-03-08.log']);
      await s.close();
    });

    test('day file names are zero-padded and files() orders across days and parts', () async {
      clock = DateTime(2026, 1, 2, 9);
      final s = sink(maxFileBytes: 100);
      final lines = [for (var i = 1; i <= 8; i++) _line(i)];
      for (final l in lines.take(4)) {
        s.add(l);
        await s.flush();
      }
      clock = DateTime(2026, 1, 3, 9);
      for (final l in lines.skip(4)) {
        s.add(l);
        await s.flush();
      }
      final names = s.files().map(_base).toList();
      expect(names.first, 'bw-2026-01-02.log');
      expect(names, contains('bw-2026-01-02.1.log'));
      expect(names, contains('bw-2026-01-03.log'));
      expect(names.indexOf('bw-2026-01-02.1.log'), lessThan(names.indexOf('bw-2026-01-03.log')));
      expect(_content(s), lines);
      await s.close();
    });

    test('deletes the oldest files to keep the total within maxTotalBytes', () async {
      final s = sink(maxFileBytes: 100, maxTotalBytes: 300);
      final lines = [for (var i = 1; i <= 20; i++) _line(i)];
      for (final l in lines) {
        s.add(l);
        await s.flush();
        expect(_bytes(s), lessThanOrEqualTo(300));
      }
      final kept = _content(s);
      expect(kept, lines.sublist(lines.length - kept.length), reason: 'what is left is the newest lines, in order');
      expect(_bytes(s), greaterThanOrEqualTo(100), reason: 'must not delete more than needed');
      expect(day('bw-2026-03-07.log').existsSync(), isFalse, reason: 'the oldest file is deleted from disk');
      final onDisk = dir.listSync().whereType<File>().map(_base).toSet();
      expect(onDisk, s.files().map(_base).toSet());
      await s.close();
    });

    test('older days are deleted before the current day', () async {
      final s = sink(maxFileBytes: 100, maxTotalBytes: 300);
      final lines = [for (var i = 1; i <= 10; i++) _line(i)];
      for (final l in lines.take(5)) {
        s.add(l);
        await s.flush();
      }
      clock = DateTime(2026, 3, 8, 8);
      for (final l in lines.skip(5)) {
        s.add(l);
        await s.flush();
      }
      expect(_bytes(s), lessThanOrEqualTo(300));
      final kept = _content(s);
      expect(kept.length, greaterThanOrEqualTo(5), reason: "today's 200 bytes fit, so they are all kept");
      expect(kept, lines.sublist(lines.length - kept.length));
      expect(s.files().map(_base), contains('bw-2026-03-08.log'));
      await s.close();
    });

    test('a new sink on the same folder continues the existing day file (app restart)', () async {
      final a = sink();
      a.add('before restart 1');
      a.add('before restart 2');
      await a.close();
      final b = sink();
      b.add('after restart');
      await b.flush();
      expect(b.files().map(_base).toList(), ['bw-2026-03-07.log']);
      expect(_content(b), ['before restart 1', 'before restart 2', 'after restart']);
      await b.close();
    });

    test('ignores and keeps files that are not logs', () async {
      final other = day('notes.txt')..writeAsStringSync('keep me');
      final s = sink(maxFileBytes: 100, maxTotalBytes: 300);
      for (var i = 1; i <= 20; i++) {
        s.add(_line(i));
        await s.flush();
      }
      expect(s.files().map(_base), isNot(contains('notes.txt')));
      expect(other.readAsStringSync(), 'keep me');
      await s.close();
    });
  });

  group('timed', () {
    late List<LogRecord> perf;
    setUp(() {
      _levels({'bw.perf': Level.ALL});
      perf = _capture(Logger('bw.perf'));
    });

    test('returns the body value and logs FINE on bw.perf with ms first, then fields', () {
      final v = timed('categorize', () => 42, fields: {'rows': 3, 'kind': 'all'});
      expect(v, 42);
      expect(perf, hasLength(1));
      final r = perf.single;
      expect(r.level, Level.FINE);
      expect(r.loggerName, 'bw.perf');
      expect(formatLogRecord(r), matches(RegExp(r' bw\.perf categorize \{"ms":\d+,"rows":3,"kind":"all"\}$')));
      expect(_fields(r)['ms'], isA<int>());
    });

    test('without fields logs only ms', () {
      timed('period', () => 'x');
      expect(_fields(perf.single).keys.toList(), ['ms']);
    });

    test('WARNING when the body takes at least warnMs; ms is the elapsed time', () {
      final v = timed('slow.thing', () {
        final sw = Stopwatch()..start();
        while (sw.elapsedMilliseconds < 30) {}
        return 'done';
      }, warnMs: 10);
      expect(v, 'done');
      final r = perf.single;
      expect(r.level, Level.WARNING);
      expect(_fields(r)['ms'] as int, allOf(greaterThanOrEqualTo(30), lessThan(5000)));
    });

    test('ms >= warnMs is a warning: warnMs 0 always warns', () {
      timed('instant', () => 1, warnMs: 0);
      expect(perf.single.level, Level.WARNING);
    });

    test('nothing is logged when bw.perf is above FINE', () {
      Logger('bw.perf').level = Level.INFO;
      expect(timed('quiet', () => 7), 7);
      expect(perf, isEmpty);
    });

    test('exceptions from the body propagate', () {
      expect(() => timed<int>('fails', () => throw StateError('boom')), throwsStateError);
    });
  });

  group('timedAsync', () {
    late List<LogRecord> perf;
    setUp(() {
      _levels({'bw.perf': Level.ALL});
      perf = _capture(Logger('bw.perf'));
    });

    test('returns the body value and logs FINE with ms and fields', () async {
      final v = await timedAsync('sync.now', () async => 'ok', fields: {'files': 2});
      expect(v, 'ok');
      final r = perf.single;
      expect(r.level, Level.FINE);
      expect(r.loggerName, 'bw.perf');
      expect(formatLogRecord(r), matches(RegExp(r' bw\.perf sync\.now \{"ms":\d+,"files":2\}$')));
    });

    test('measures the awaited time and warns at warnMs', () async {
      final v = await timedAsync('import.file', () async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return 5;
      }, warnMs: 10);
      expect(v, 5);
      final r = perf.single;
      expect(r.level, Level.WARNING);
      expect(_fields(r)['ms'] as int, allOf(greaterThanOrEqualTo(30), lessThan(5000)));
    });

    test('exceptions from the body propagate', () async {
      await expectLater(timedAsync<int>('fails', () async => throw StateError('boom')), throwsStateError);
    });
  });

  group('FrameStats', () {
    test('janky = build or raster exceeded the budget; exactly at budget is fine', () {
      final s = FrameStats();
      s.add(buildMicros: 16667, rasterMicros: 16667);
      s.add(buildMicros: 16668, rasterMicros: 1000);
      s.add(buildMicros: 1000, rasterMicros: 16668);
      s.add(buildMicros: 40000, rasterMicros: 40000);
      s.add(buildMicros: 0, rasterMicros: 0);
      expect(s.count, 5);
      expect(s.janky, 3);
    });

    test('custom budget', () {
      final s = FrameStats(budgetMicros: 8000);
      s.add(buildMicros: 8000, rasterMicros: 8000);
      s.add(buildMicros: 8001, rasterMicros: 0);
      s.add(buildMicros: 10000, rasterMicros: 1000);
      expect(s.count, 3);
      expect(s.janky, 2);
    });

    test('summary: nearest-rank percentiles per series, keys in the documented order', () {
      final s = FrameStats();
      // build 1..10 ms, raster 5.0..0.5 ms, added out of order.
      for (final i in [7, 2, 10, 4, 1, 9, 3, 6, 8, 5]) {
        s.add(buildMicros: i * 1000, rasterMicros: (11 - i) * 500);
      }
      final m = s.summary();
      expect(m.keys.toList(), [
        'frames',
        'janky',
        'build_p50_ms',
        'build_p90_ms',
        'build_p99_ms',
        'build_max_ms',
        'raster_p50_ms',
        'raster_p90_ms',
        'raster_p99_ms',
        'raster_max_ms',
      ]);
      // n=10: p50 → rank ceil(5)=5, p90 → rank 9, p99 → rank ceil(9.9)=10.
      expect(m, {
        'frames': 10,
        'janky': 0,
        'build_p50_ms': 5.0,
        'build_p90_ms': 9.0,
        'build_p99_ms': 10.0,
        'build_max_ms': 10.0,
        'raster_p50_ms': 2.5,
        'raster_p90_ms': 4.5,
        'raster_p99_ms': 5.0,
        'raster_max_ms': 5.0,
      });
    });

    test('nearest-rank on 20 samples and on a single sample', () {
      final s = FrameStats();
      for (var i = 20; i >= 1; i--) {
        s.add(buildMicros: i * 1000, rasterMicros: 2000);
      }
      final m = s.summary();
      // n=20: p50 → rank 10, p90 → rank 18, p99 → rank ceil(19.8)=20.
      expect([m['build_p50_ms'], m['build_p90_ms'], m['build_p99_ms'], m['build_max_ms']], [10.0, 18.0, 20.0, 20.0]);
      expect(m['janky'], 4, reason: '17..20 ms exceed 16.667 ms');

      final one = FrameStats()..add(buildMicros: 3300, rasterMicros: 4400);
      final o = one.summary();
      expect([o['build_p50_ms'], o['build_p90_ms'], o['build_p99_ms'], o['build_max_ms']], [3.3, 3.3, 3.3, 3.3]);
      expect([o['raster_p50_ms'], o['raster_p90_ms'], o['raster_p99_ms'], o['raster_max_ms']], [4.4, 4.4, 4.4, 4.4]);
    });

    test('ms are rounded to 0.1', () {
      final s = FrameStats();
      s.add(buildMicros: 12345, rasterMicros: 40); // 12.345 → 12.3, 0.04 → 0.0
      s.add(buildMicros: 12375, rasterMicros: 999); // 12.375 → 12.4, 0.999 → 1.0
      s.add(buildMicros: 12390, rasterMicros: 60); // 12.39 → 12.4, 0.06 → 0.1
      final m = s.summary();
      // n=3: p50 → rank 2, p90/p99 → rank 3.
      expect(m['build_p50_ms'], 12.4); // sorted 12345, 12375, 12390
      expect(m['build_max_ms'], 12.4);
      expect(m['raster_p50_ms'], 0.1); // sorted 40, 60, 999
      expect(m['raster_p90_ms'], 1.0);
      expect(m['raster_max_ms'], 1.0);
      final low = (FrameStats()..add(buildMicros: 12345, rasterMicros: 40)).summary();
      expect(low['build_max_ms'], 12.3);
      expect(low['raster_max_ms'], 0.0);
      expect(jsonEncode(low['build_max_ms']), '12.3');
    });

    test('empty summary', () {
      expect(FrameStats().summary(), {'frames': 0, 'janky': 0});
    });

    test('reset clears everything', () {
      final s = FrameStats();
      s.add(buildMicros: 30000, rasterMicros: 30000);
      s.add(buildMicros: 1000, rasterMicros: 1000);
      s.reset();
      expect(s.count, 0);
      expect(s.janky, 0);
      expect(s.summary(), {'frames': 0, 'janky': 0});
      s.add(buildMicros: 2000, rasterMicros: 3000);
      expect(s.summary(), containsPair('frames', 1));
      expect(s.summary(), containsPair('janky', 0));
      expect(s.summary(), containsPair('build_max_ms', 2.0));
      expect(s.summary(), containsPair('raster_max_ms', 3.0));
    });
  });
}
