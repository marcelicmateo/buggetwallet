// Logging for Budget Wallet: structured events, one-line format, rotating log files, perf timers, frame stats.
//
// Privacy (hard rule): log event names, counts, durations, sizes, built-in category names, period dates, setting
// keys and enum states only. Never money amounts, descriptions, merchant names, notes, wish/goal names, account
// numbers, the wallet key, sync file contents, paths or bank file names. Errors are printed through [describeError],
// which drops the parts of common exceptions that can carry data (FormatException source, SQL parameters, paths).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

export 'package:logging/logging.dart' show Level, LogRecord, Logger;

/// A structured log message: the record's message is [event], [fields] are printed as JSON after it.
class LogEvent {
  final String event;
  final Map<String, Object?> fields;
  const LogEvent(this.event, [this.fields = const {}]);
  @override
  String toString() => event;
}

/// Structured event: `event` is a short dotted name (e.g. 'import.done'), fields are safe scalars.
void logEvent(Logger logger, Level level, String event, [Map<String, Object?> fields = const {}]) {
  if (!logger.isLoggable(level)) return;
  logger.log(level, LogEvent(event, fields));
}

/// An event with an error and its stack trace (for catch blocks). WARNING unless [level] says otherwise.
void logError(Logger logger, String event, Object error, StackTrace? stack,
    {Map<String, Object?> fields = const {}, Level level = Level.WARNING}) {
  if (!logger.isLoggable(level)) return;
  logger.log(level, LogEvent(event, fields), error, stack);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Level names in the log: FINE is shown as DEBUG, the others keep their `package:logging` names.
String levelName(Level l) => l == Level.FINE ? 'DEBUG' : l.name;

/// `2026-10-16T19:01:02.123+02:00` (local time, UTC offset, milliseconds).
String formatLogTime(DateTime t) {
  final l = t.toLocal();
  final off = l.timeZoneOffset;
  final mins = off.inMinutes.abs();
  return '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}T${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}'
      '.${l.millisecond.toString().padLeft(3, '0')}${off.isNegative ? '-' : '+'}${_two(mins ~/ 60)}:${_two(mins % 60)}';
}

/// Error text without the parts that can carry user data.
String describeError(Object? e) {
  switch (e) {
    case SqliteException():
      // toString() would append the statement's parameters (descriptions, amounts).
      final b = StringBuffer('SqliteException(${e.extendedResultCode}): ${e.message}');
      if (e.explanation != null) b.write(', ${e.explanation}');
      if (e.causingStatement != null) b.write(' [statement: ${e.causingStatement}]');
      return b.toString();
    case FileSystemException():
      // The path can name a bank export or contain the user's name.
      return '${e.runtimeType}: ${e.message}${e.osError != null ? ' (${e.osError})' : ''}';
    case FormatException():
      // The source excerpt can be decrypted sync data or a bank file line.
      return 'FormatException: ${e.message}${e.offset != null ? ' (at offset ${e.offset})' : ''}';
    case RangeError():
      return e.toString(); // numbers only
    case ArgumentError():
      // invalidValue can be any value; keep the name and message.
      return 'ArgumentError${e.name != null ? '(${e.name})' : ''}: ${e.message ?? 'invalid argument'}';
    default:
      return '$e';
  }
}

Object? _encodable(Object? o) => o is DateTime ? o.toIso8601String() : o.toString();

/// One line per record:
/// `2026-10-16T19:01:02.123+02:00 DEBUG bw.import import.done {"rows":312,"dupes":4,"ms":41}`
/// then, if present, `  error: <error>` and the stack trace lines indented by two spaces.
/// Fields are JSON-encoded (keys in insertion order). Local time with UTC offset, millisecond precision.
String formatLogRecord(LogRecord r) {
  final b = StringBuffer()
    ..write(formatLogTime(r.time))
    ..write(' ')
    ..write(levelName(r.level))
    ..write(' ')
    ..write(r.loggerName)
    ..write(' ')
    ..write(r.message);
  final o = r.object;
  final fields = o is LogEvent ? o.fields : (o is Map<String, Object?> ? o : null);
  if (fields != null && fields.isNotEmpty) {
    b
      ..write(' ')
      ..write(jsonEncode(fields, toEncodable: _encodable));
  }
  if (r.error != null) {
    b
      ..write('\n  error: ')
      ..write(describeError(r.error).replaceAll('\n', '\n  '));
  }
  final st = r.stackTrace;
  if (st != null && st != StackTrace.empty) {
    for (final line in st.toString().split('\n')) {
      if (line.trim().isEmpty) continue;
      b
        ..write('\n  ')
        ..write(line);
    }
  }
  return b.toString();
}

final _perf = Logger('bw.perf');

/// Logs a finished timing on `bw.perf`: FINE, or WARNING when [ms] >= [warnMs]. Fields: {"ms": ms, ...fields}.
void logPerf(String name, int ms, {Map<String, Object?> fields = const {}, int warnMs = 200}) {
  final level = ms >= warnMs ? Level.WARNING : Level.FINE;
  if (!_perf.isLoggable(level)) return;
  _perf.log(level, LogEvent(name, {'ms': ms, ...fields}));
}

/// A running timer for operations whose fields are only known at the end (counts from the result).
class PerfTimer {
  final String name;
  final int warnMs;
  final Stopwatch _sw = Stopwatch()..start();
  PerfTimer(this.name, {this.warnMs = 200});

  int get ms => _sw.elapsedMilliseconds;

  /// Logs the timing (see [logPerf]) and returns the milliseconds.
  int done([Map<String, Object?> fields = const {}]) {
    final ms = _sw.elapsedMilliseconds;
    logPerf(name, ms, fields: fields, warnMs: warnMs);
    return ms;
  }
}

/// Times [body]; logs `<name>` at FINE on `bw.perf` with `{"ms": <int>, ...fields}`; at WARNING if ms >= warnMs.
/// If [body] throws, the timing is logged with `"failed": true` and the error is rethrown.
T timed<T>(String name, T Function() body, {Map<String, Object?> fields = const {}, int warnMs = 200}) {
  final sw = Stopwatch()..start();
  try {
    final r = body();
    logPerf(name, sw.elapsedMilliseconds, fields: fields, warnMs: warnMs);
    return r;
  } catch (_) {
    logPerf(name, sw.elapsedMilliseconds, fields: {...fields, 'failed': true}, warnMs: warnMs);
    rethrow;
  }
}

/// Async version of [timed].
Future<T> timedAsync<T>(String name, Future<T> Function() body, {Map<String, Object?> fields = const {}, int warnMs = 500}) async {
  final sw = Stopwatch()..start();
  try {
    final r = await body();
    logPerf(name, sw.elapsedMilliseconds, fields: fields, warnMs: warnMs);
    return r;
  } catch (_) {
    logPerf(name, sw.elapsedMilliseconds, fields: {...fields, 'failed': true}, warnMs: warnMs);
    rethrow;
  }
}

/// Frame timing aggregation (fed from Flutter's FrameTiming in the app). Microseconds in, summary out.
class FrameStats {
  final int budgetMicros;
  final List<int> _build = [], _raster = [];
  int _janky = 0;
  FrameStats({this.budgetMicros = 16667});

  void add({required int buildMicros, required int rasterMicros}) {
    _build.add(buildMicros);
    _raster.add(rasterMicros);
    if (buildMicros > budgetMicros || rasterMicros > budgetMicros) _janky++;
  }

  int get count => _build.length;

  /// Frames where build or raster exceeded the budget.
  int get janky => _janky;

  static double _ms(int micros) => (micros / 100).round() / 10;

  static Map<String, Object?> _stats(String prefix, List<int> xs) {
    final s = [...xs]..sort();
    int at(int p) => s[((p * s.length + 99) ~/ 100).clamp(1, s.length) - 1]; // nearest rank, integer maths
    return {
      '${prefix}_p50_ms': _ms(at(50)),
      '${prefix}_p90_ms': _ms(at(90)),
      '${prefix}_p99_ms': _ms(at(99)),
      '${prefix}_max_ms': _ms(s.last),
    };
  }

  /// {"frames":n,"janky":n,"build_p50_ms":..,"build_p90_ms":..,"build_p99_ms":..,"build_max_ms":..,
  ///  "raster_p50_ms":..,"raster_p90_ms":..,"raster_p99_ms":..,"raster_max_ms":..}  (ms rounded to 0.1)
  /// Percentile = nearest-rank on the sorted samples. Empty → {"frames":0,"janky":0}.
  Map<String, Object?> summary() {
    if (_build.isEmpty) return {'frames': 0, 'janky': 0};
    return {'frames': count, 'janky': janky, ..._stats('build', _build), ..._stats('raster', _raster)};
  }

  void reset() {
    _build.clear();
    _raster.clear();
    _janky = 0;
  }
}

class _Chunk {
  final String day;
  final List<String> lines = [];
  _Chunk(this.day);
}

final _logName = RegExp(r'^bw-(\d{4}-\d{2}-\d{2})(?:\.(\d+))?\.log$');

/// Appends formatted lines to `<dir>/bw-YYYY-MM-DD.log`, buffered; rotates by day and when a file exceeds
/// [maxFileBytes] (continues in `bw-YYYY-MM-DD.1.log`, `.2`, …); deletes oldest files so the total stays
/// under [maxTotalBytes]. `flush()` writes the buffer; `close()` flushes and closes.
///
/// [add] never touches the disk: it appends to memory and schedules a flush within [flushDelay].
class RotatingFileSink {
  final Directory dir;
  final int maxFileBytes, maxTotalBytes;
  final DateTime Function() _now;

  /// How long [add] waits before writing the buffer (spec: at most 1 s).
  Duration flushDelay = const Duration(seconds: 1);

  /// Last write error (the sink cannot log its own failures), and how many writes failed.
  Object? lastError;
  int errors = 0;

  final List<_Chunk> _pending = [];
  Future<void> _chain = Future.value();
  Timer? _timer;
  bool _closed = false;
  String? _curDay;
  int _curIndex = 0, _curSize = 0, _total = 0;

  RotatingFileSink(this.dir, {this.maxFileBytes = 2 * 1024 * 1024, this.maxTotalBytes = 20 * 1024 * 1024, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static String _day(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';

  String _path(String day, int index) => '${dir.path}${Platform.pathSeparator}bw-$day${index == 0 ? '' : '.$index'}.log';

  void add(String line) {
    if (_closed) return;
    final day = _day(_now());
    if (_pending.isEmpty || _pending.last.day != day) _pending.add(_Chunk(day));
    _pending.last.lines.add(line);
    _timer ??= Timer(flushDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return _chain;
    final work = [..._pending];
    _pending.clear();
    return _chain = _chain.then((_) => _write(work));
  }

  Future<void> close() async {
    if (_closed) return _chain;
    final f = flush();
    _closed = true;
    await f;
  }

  Future<void> _write(List<_Chunk> work) async {
    try {
      await dir.create(recursive: true);
      for (final c in work) {
        if (c.day != _curDay) await _open(c.day);
        final out = BytesBuilder(copy: false);
        for (final line in c.lines) {
          final bytes = utf8.encode('$line\n');
          if (_curSize > 0 && _curSize + out.length + bytes.length > maxFileBytes) {
            await _append(out.takeBytes());
            _curIndex++;
            _curSize = 0;
            if (_total > maxTotalBytes) await _trim();
          }
          out.add(bytes);
        }
        await _append(out.takeBytes());
      }
      if (_total > maxTotalBytes) await _trim();
    } catch (e) {
      lastError = e;
      errors++;
      _curDay = null; // re-scan the folder next time
    }
  }

  /// Picks the newest file of [day] and measures the folder (once per day or after an error, not per flush).
  Future<void> _open(String day) async {
    var index = 0;
    _total = 0;
    for (final f in files()) {
      _total += await f.length();
      final m = _logName.firstMatch(_baseName(f));
      if (m != null && m[1] == day) index = int.parse(m[2] ?? '0');
    }
    final f = File(_path(day, index));
    _curDay = day;
    _curIndex = index;
    _curSize = await f.exists() ? await f.length() : 0;
    if (_total > maxTotalBytes) await _trim();
  }

  Future<void> _append(List<int> bytes) async {
    if (bytes.isEmpty) return;
    await File(_path(_curDay!, _curIndex)).writeAsBytes(bytes, mode: FileMode.append);
    _curSize += bytes.length;
    _total += bytes.length;
  }

  /// Deletes the oldest files (never the one being written) until the total is under [maxTotalBytes].
  Future<void> _trim() async {
    final all = files();
    final sizes = [for (final f in all) await f.length()];
    _total = sizes.fold<int>(0, (s, x) => s + x);
    final current = _path(_curDay!, _curIndex);
    for (var i = 0; i < all.length && _total > maxTotalBytes; i++) {
      if (all[i].path == current) continue;
      await all[i].delete();
      _total -= sizes[i];
    }
  }

  static String _baseName(FileSystemEntity f) => f.path.split(Platform.pathSeparator).last;

  /// All log files, oldest first.
  List<File> files() {
    if (!dir.existsSync()) return const [];
    final found = <(String, int, File)>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final m = _logName.firstMatch(_baseName(e));
      if (m != null) found.add((m[1]!, int.parse(m[2] ?? '0'), e));
    }
    found.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final (_, _, f) in found) f];
  }
}
