import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'log_stats.dart';

/// OS version, Dart version and CPU count: facts only dart:io has.
Map<String, Object?> nativeInfo() =>
    {'os': Platform.operatingSystemVersion, 'dart': Platform.version.split(' ').first, 'cpus': Platform.numberOfProcessors};

/// Process memory in MB for the `mem` log line.
Map<String, Object?> memoryFacts() {
  double mb(int b) => (b / 104857.6).round() / 10;
  return {'rss_mb': mb(ProcessInfo.currentRss), 'max_rss_mb': mb(ProcessInfo.maxRss)};
}

/// The log lines in `<app support dir>/logs/bw-YYYY-MM-DD.log` through a [RotatingFileSink].
class LogBackend {
  final Directory _dir;
  final RotatingFileSink _sink;
  LogBackend._(this._dir, this._sink);

  /// Opens the log folder. Throws when it can't be made.
  static Future<LogBackend> open() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}logs');
    return LogBackend._(dir, RotatingFileSink(dir));
  }

  void add(String line) => _sink.add(line);
  Future<void> flush() => _sink.flush();
  Future<void> close() => _sink.close();

  Future<LogStats> stats() async {
    await flush();
    var bytes = 0;
    final files = _sink.files();
    for (final f in files) {
      bytes += await f.length();
    }
    return LogStats(files.length, bytes, _sink.errors);
  }

  /// All log files, oldest first, as one text. [onError] gets a file that could not be read.
  Future<String> combined(void Function(Object e, StackTrace st) onError) async {
    await flush();
    final b = StringBuffer();
    for (final f in _sink.files()) {
      try {
        b.write(await f.readAsString());
      } catch (e, st) {
        onError(e, st);
      }
    }
    return b.toString();
  }

  /// Deletes all log files and returns a fresh backend writing a new one. This one is closed.
  Future<LogBackend> clear(void Function(Object e, StackTrace st) onError) async {
    await _sink.close();
    for (final f in _sink.files()) {
      try {
        await f.delete();
      } catch (e, st) {
        onError(e, st);
      }
    }
    return LogBackend._(_dir, RotatingFileSink(_dir));
  }
}
