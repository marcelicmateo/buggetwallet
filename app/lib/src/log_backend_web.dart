import 'dart:convert';

import 'core_shim.dart';
import 'log_stats.dart';

/// No dart:io facts in the browser.
Map<String, Object?> nativeInfo() => const {};

/// The browser does not tell the page its memory use.
Map<String, Object?> memoryFacts() => const {};

/// The log lines in a bounded buffer in memory ([MemoryLogSink]): they last until the tab closes, "Save logs…" downloads them.
class LogBackend {
  final MemoryLogSink _sink;
  LogBackend._(this._sink);

  static Future<LogBackend> open() async => LogBackend._(MemoryLogSink(maxBytes: 1024 * 1024));

  void add(String line) => _sink.add(line);
  Future<void> flush() async {}
  Future<void> close() async {}

  Future<LogStats> stats() async => LogStats(1, utf8.encode(_sink.dump()).length);

  Future<String> combined(void Function(Object e, StackTrace st) onError) async => _sink.dump();

  /// Forgets all lines: a fresh, empty buffer.
  Future<LogBackend> clear(void Function(Object e, StackTrace st) onError) async => LogBackend._(MemoryLogSink(maxBytes: 1024 * 1024));
}
