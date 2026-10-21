// App-wide logging: console + rotating files, error hooks, startup, frame, memory and lifecycle logs.
//
// Privacy (hard rule, also on the device): never log amounts, balances, descriptions, merchant names, notes,
// wish/goal names, account numbers, the wallet key, sync file contents, paths or bank file names.
// Log event names, counts, durations, sizes, built-in categories, period dates, setting keys and enum states.
import 'dart:async';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show FlutterVersion, PlatformException;
import 'package:flutter/widgets.dart';
import 'package:wallet_core/wallet_core.dart';

import 'log_backend.dart';

export 'log_backend.dart' show LogStats, nativeInfo;

/// Keep in step with `version:` in pubspec.yaml (checked by test/logging_test.dart).
const appVersion = '2.0.0+1';

final _app = Logger('bw.app');
final _err = Logger('bw.error');
final _frames = Logger('bw.frames');
final _mem = Logger('bw.mem');
final _life = Logger('bw.lifecycle');
final _nav = Logger('bw.nav');

/// Navigation and UI actions (tab switches, sheets, buttons) on `bw.nav`. Fields must be safe (see top of file).
void logNav(String event, [Map<String, Object?> fields = const {}]) => logEvent(_nav, Level.INFO, event, fields);

/// Shows [future] (a sheet or dialog) in the log as `<name>.open` and `<name>.close` with its result.
Future<T?> loggedRoute<T>(String name, Future<T?> future) async {
  logEvent(_nav, Level.INFO, 'sheet.open', {'sheet': name});
  final r = await future;
  // Results are fixed words ('added', 'saved', 'deleted', …); anything else is reduced to its type.
  logEvent(_nav, Level.INFO, 'sheet.close', {'sheet': name, 'result': r == null || r is String ? r : r.runtimeType.toString()});
  return r;
}

/// The extension of a file name, or '' (never the name itself).
String fileExt(String name) {
  final i = name.lastIndexOf('.');
  final ext = i < 0 ? '' : name.substring(i + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : (ext.isEmpty ? '' : 'other');
}

/// Log levels the user can pick in Plan › Diagnostics (stored per device as `logLevel`).
const logLevels = {'all': Level.ALL, 'info': Level.INFO, 'warning': Level.WARNING};

/// Sets up and owns the log sinks and monitors. Everything here is static: there is one log per app.
class AppLog {
  static LogBackend? _sink; // rotating files, or a buffer in memory in the browser
  static final List<String> _early = []; // lines logged before the sink is ready
  static StreamSubscription<LogRecord>? _sub;
  static final FrameStats _stats = FrameStats();
  static Timer? _frameTimer, _memTimer;
  static AppLifecycleListener? _lifecycle;
  static bool _monitoring = false;

  /// Print each line with debugPrint too (reaches `adb logcat`, also in release builds).
  static bool console = true;

  /// Current screen for frame logs ('today', 'spending', …). Change it with [setScreen].
  static String screen = 'start';

  /// Closes the frame window of the old screen (so each window belongs to one screen), then switches.
  static void setScreen(String name) {
    if (name == screen) return;
    logFrameWindow();
    screen = name;
  }

  /// Starts logging: root level ALL until the stored level is applied, console + file sink in
  /// `<app support dir>/logs/`. With [catchErrors], Flutter and platform errors are logged SEVERE.
  static Future<void> init({bool catchErrors = true}) async {
    if (_sub != null) return;
    Logger.root.level = Level.ALL;
    // PlatformException messages/details can carry content:// URIs or paths (bank file names): log the code only.
    describeErrorHook = (e) => e is PlatformException ? 'PlatformException(${e.code})' : null;
    _sub = Logger.root.onRecord.listen(_onRecord);
    if (catchErrors) _hookErrors();
    try {
      final backend = await LogBackend.open();
      for (final l in _early) {
        backend.add(l);
      }
      _early.clear();
      _sink = backend;
    } catch (e, st) {
      logError(_app, 'log.fileSinkFailed', e, st, level: Level.SEVERE);
    }
  }

  static void _onRecord(LogRecord r) {
    final line = formatLogRecord(r);
    // Synchronous: debugPrint is throttled (~12 KB/s) with an unbounded queue, which lags and grows under bursts.
    if (console) debugPrintSynchronously(line);
    final sink = _sink;
    if (sink == null) {
      if (_early.length < 5000) _early.add(line);
    } else {
      sink.add(line);
      if (r.level >= Level.SEVERE) unawaited(sink.flush());
    }
  }

  static void _hookErrors() {
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      // Only the exception and stack: the full details can describe widgets and their text.
      _err.log(Level.SEVERE, LogEvent('flutter.error', {'library': details.library, 'silent': details.silent}), details.exception,
          details.stack);
      prevFlutter?.call(details);
    };
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      logError(_err, 'platform.error', error, stack, level: Level.SEVERE);
      return prevPlatform?.call(error, stack) ?? false;
    };
  }

  /// For the zone around the app (runZonedGuarded).
  static void zoneError(Object error, StackTrace stack) => logError(_err, 'zone.error', error, stack, level: Level.SEVERE);

  /// Applies a stored level name ('all', 'info', 'warning'); unknown or missing → all.
  static void setLevel(String? name) {
    Logger.root.level = logLevels[name] ?? Level.ALL;
  }

  /// App, platform and device facts that help reading a log. No ids.
  static void logAppInfo() {
    final pd = PlatformDispatcher.instance;
    final view = pd.views.firstOrNull;
    logEvent(_app, Level.INFO, 'app.info', {
      'version': appVersion,
      'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'platform': defaultTargetPlatform.name,
      ...nativeInfo(),
      'flutter': FlutterVersion.version,
      'locale': pd.locale.toLanguageTag(),
      if (view != null) 'screen': '${view.physicalSize.width.round()}x${view.physicalSize.height.round()}@${view.devicePixelRatio}',
      'logLevel': Logger.root.level.name,
    });
  }

  /// Frame timings, memory every 60 s and lifecycle changes. Call once after runApp.
  static void startMonitors() {
    if (_monitoring) return;
    _monitoring = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _frameTimer = Timer.periodic(const Duration(seconds: 10), (_) => logFrameWindow());
    _memTimer = Timer.periodic(const Duration(seconds: 60), (_) => logMemory());
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    logMemory();
  }

  static void stopMonitors() {
    if (!_monitoring) return;
    _monitoring = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _frameTimer?.cancel();
    _memTimer?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds, raster = t.rasterDuration.inMicroseconds;
      _stats.add(buildMicros: build, rasterMicros: raster);
      if (build > 100000 || raster > 100000) {
        logEvent(_frames, Level.WARNING, 'frames.slow',
            {'build_ms': (build / 100).round() / 10, 'raster_ms': (raster / 100).round() / 10, 'tab': screen});
      }
    }
  }

  /// Logs the frames since the last window (if any) and starts a new one.
  static void logFrameWindow() {
    if (_stats.count == 0) return;
    logEvent(_frames, Level.INFO, 'frames.window', {..._stats.summary(), 'tab': screen});
    _stats.reset();
  }

  static void logMemory() {
    final facts = memoryFacts();
    if (facts.isNotEmpty) logEvent(_mem, Level.FINE, 'mem', facts);
  }

  static void _onLifecycle(AppLifecycleState s) {
    logEvent(_life, Level.INFO, 'lifecycle', {'state': s.name});
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden || s == AppLifecycleState.detached) {
      logFrameWindow();
      unawaited(flush());
    }
  }

  static Future<void> flush() async => _sink?.flush();

  /// Stops logging: monitors off, listener cancelled, files flushed and closed (tests; the app logs until it dies).
  static Future<void> close() async {
    stopMonitors();
    await _sub?.cancel();
    _sub = null;
    final sink = _sink;
    _sink = null;
    await sink?.close();
  }

  /// Number of log files and their total size.
  static Future<LogStats> stats() async => await _sink?.stats() ?? const LogStats(0, 0);

  /// All log lines, oldest first, as one text.
  static Future<String> combined() async => await _sink?.combined((e, st) => logError(_app, 'log.readFailed', e, st)) ?? '';

  /// Deletes all log files and starts a fresh one.
  static Future<void> clear() async {
    final old = _sink;
    if (old == null) return;
    _sink = null; // lines logged meanwhile wait in _early
    final fresh = await old.clear((e, st) => logError(_app, 'log.deleteFailed', e, st));
    for (final l in _early) {
      fresh.add(l);
    }
    _early.clear();
    _sink = fresh;
    logEvent(_app, Level.INFO, 'log.cleared');
  }
}
