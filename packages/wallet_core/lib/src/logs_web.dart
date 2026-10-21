// Web twin of `logs_io.dart`: the browser has no log folder. The web app uses `MemoryLogSink` (logs.dart) instead.
import 'logs.dart';

/// Not available on the web: the constructor throws. Use [MemoryLogSink].
class RotatingFileSink implements LogSink {
  /// Same shape as the native sink's fields, so code that only names them still compiles.
  final Object dir;
  final int maxFileBytes, maxTotalBytes;
  Duration flushDelay = const Duration(seconds: 1);
  Object? lastError;
  int errors = 0;

  RotatingFileSink(this.dir, {this.maxFileBytes = 2 * 1024 * 1024, this.maxTotalBytes = 20 * 1024 * 1024, DateTime Function()? now}) {
    throw UnsupportedError('RotatingFileSink is not available on the web: use MemoryLogSink');
  }

  @override
  void add(String line) {}

  @override
  Future<void> flush() => Future.value();

  @override
  Future<void> close() => Future.value();

  /// All log files, oldest first (none on the web).
  List<Object> files() => const [];
}
