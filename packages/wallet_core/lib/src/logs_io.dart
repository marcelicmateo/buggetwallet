// Log files (dart:io): the rotating file sink used by the app on phone and desktop. The web twin is `logs_web.dart`;
// everything platform-neutral (events, formatting, timers, `LogSink`, `MemoryLogSink`) is in `logs.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'logs.dart';

class _Chunk {
  final String day;
  final List<String> lines = [];
  _Chunk(this.day);
}

final _logName = RegExp(r'^bw-(\d{4}-\d{2}-\d{2})(?:\.(\d+))?\.log$');

String _two(int n) => n.toString().padLeft(2, '0');

/// Appends formatted lines to `<dir>/bw-YYYY-MM-DD.log`, buffered; rotates by day and when a file exceeds
/// [maxFileBytes] (continues in `bw-YYYY-MM-DD.1.log`, `.2`, …); deletes oldest files so the total stays
/// under [maxTotalBytes]. `flush()` writes the buffer; `close()` flushes and closes.
///
/// [add] never touches the disk: it appends to memory and schedules a flush within [flushDelay].
class RotatingFileSink implements LogSink {
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

  @override
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

  @override
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return _chain;
    final work = [..._pending];
    _pending.clear();
    return _chain = _chain.then((_) => _write(work));
  }

  @override
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
      if (errors++ == 0) {
        // The sink can't log to itself; say it once on the console (stdout reaches logcat/terminal).
        // ignore: avoid_print
        print('${formatLogTime(DateTime.now())} SEVERE bw.logs log.writeFailed ${describeError(e)}');
      }
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
