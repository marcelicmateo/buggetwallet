// Logging for Budget Wallet: structured events, one-line format, log sinks, perf timers, frame stats.
// This file compiles for the web; the rotating file sink (dart:io) is in `logs_io.dart`.
//
// Privacy (hard rule): log event names, counts, durations, sizes, built-in category names, period dates, setting
// keys and enum states only. Never money amounts, descriptions, merchant names, notes, wish/goal names, account
// numbers, the wallet key, sync file contents, paths or bank file names. Errors are printed through [describeError],
// which drops the parts of common exceptions that can carry data (FormatException source, SQL parameters, paths).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:wallet_importer/wallet_importer.dart' show ImportException;

import 'platform_error_io.dart' if (dart.library.js_interop) 'platform_error_web.dart' as platform;
import 'sync.dart' show SyncException;
import 'vault.dart' show VaultException;

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

/// Extra redaction for error types this package can't see (the app registers one for PlatformException).
/// Return null to fall through to the default handling.
String? Function(Object e)? describeErrorHook;

/// Error text without the parts that can carry user data. Only error types known to carry no user data keep
/// their message; anything else is logged as its type name (its toString can hold paths, URIs or values).
String describeError(Object? e) {
  if (e != null) {
    final hooked = describeErrorHook?.call(e);
    if (hooked != null) return hooked;
    // dart:io errors (FileSystemException: the path can name a bank export or contain the user's name); none on the web.
    final io = platform.describePlatformError(e);
    if (io != null) return io;
  }
  switch (e) {
    case SqliteException():
      // toString() would append the statement's parameters (descriptions, amounts).
      final b = StringBuffer('SqliteException(${e.extendedResultCode}): ${e.message}');
      if (e.explanation != null) b.write(', ${e.explanation}');
      if (e.causingStatement != null) b.write(' [statement: ${e.causingStatement}]');
      return b.toString();
    case FormatException():
      // The source excerpt can be decrypted sync data or a bank file line.
      return 'FormatException: ${e.message}${e.offset != null ? ' (at offset ${e.offset})' : ''}';
    case RangeError():
      return e.toString(); // numbers only
    case ArgumentError():
      // invalidValue can be any value; keep the name and message.
      return 'ArgumentError${e.name != null ? '(${e.name})' : ''}: ${e.message ?? 'invalid argument'}';
    // Our own exceptions and Dart errors whose messages are fixed texts or numbers.
    case ImportException() || SyncException() || VaultException() || StateError() || UnsupportedError() || TimeoutException():
      return e.toString();
    case TypeError():
      return 'TypeError'; // can name runtime values' types only, but keep it minimal
    case null:
      return 'null';
    default:
      // PlatformException (URIs/paths), ProcessException (command lines), NoSuchMethodError (values), …
      return e.runtimeType.toString();
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

/// Where formatted log lines go: `RotatingFileSink` (files, native) or [MemoryLogSink] (web, tests).
abstract interface class LogSink {
  /// Takes one formatted line; never blocks on I/O.
  void add(String line);

  /// Writes what [add] buffered.
  Future<void> flush();

  /// Flushes; later [add] calls are dropped.
  Future<void> close();
}

/// Keeps the newest lines in memory, up to [maxBytes] of UTF-8 (default 2 MiB): the oldest lines go first, counted
/// in [dropped]; the newest line is always kept, even when it is larger than [maxBytes] on its own. [dump] is the
/// buffer as one text (lines joined with `\n`), what the web app offers for download.
class MemoryLogSink implements LogSink {
  final int maxBytes;
  final Queue<String> _lines = Queue();
  int _bytes = 0, _dropped = 0;
  bool _closed = false;

  MemoryLogSink({this.maxBytes = 2 * 1024 * 1024}) {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
  }

  /// The lines held, oldest first (a copy).
  List<String> get lines => List.unmodifiable(_lines);

  /// Lines removed to stay under [maxBytes].
  int get dropped => _dropped;

  /// Bytes (UTF-8, plus one per line for the newline) currently held.
  int get bytes => _bytes;

  @override
  void add(String line) {
    if (_closed) return;
    _lines.add(line);
    _bytes += utf8.encode(line).length + 1;
    while (_bytes > maxBytes && _lines.length > 1) {
      _bytes -= utf8.encode(_lines.removeFirst()).length + 1;
      _dropped++;
    }
  }

  /// Everything held, joined with `\n` (no trailing newline).
  String dump() => _lines.join('\n');

  @override
  Future<void> flush() => Future.value();

  @override
  Future<void> close() {
    _closed = true;
    return Future.value();
  }
}
