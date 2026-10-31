// KL: a quarantined peer file that stops the device's later files. The engine tracks it (device-local), asks its author
// to resend its state and write a snapshot covering it, and the owner may skip it (Settings › Sync). Web-safe: no dart:io.
import 'dart:convert';

import 'package:wallet_core/wallet_core.dart';

import 'sync_engine.dart' show SyncEngine;
import 'sync_problems.dart';

final _log = Logger('bw.sync');

/// A quarantined file of another device that stops this device's later files of that device: a later file exists.
class BlockedFile {
  /// The other device's relay stream name (never shown or logged; the UI shows [short]).
  final String device;

  /// The file's seq, as text (the quarantine key's file part, like [BadFile.file]).
  final String file;
  final SyncProblemReason reason;

  /// When this device first found it blocking.
  final DateTime since;

  /// When the author (any stream of its device id) last synced with the relay, as of this device's last run; null when
  /// the relay never said.
  final DateTime? authorSeen;
  const BlockedFile(this.device, this.file, this.reason, {required this.since, this.authorSeen});

  /// The author's short id, as [SyncProblem.device] shows it.
  String get short => SyncProblem.shortId(SyncEngine.streamBase(device));

  @override
  String toString() => 'BlockedFile($short, ${reason.name})';
}

/// The files that block this device now, as its last complete sync run found them (device-local, no network).
List<BlockedFile> blockedFiles(WalletRepo repo) {
  final skipped = SkippedFiles.load(repo);
  return [
    for (final MapEntry(key: k, value: b) in BlockedBook.load(repo).byKey.entries)
      if (!skipped.byKey.containsKey(k)) b.file(k),
  ];
}

/// The owner skips blocked file [file] of [device] (from [blockedFiles]): device-local, never synced. The next run treats
/// that file (these bytes: a repaired copy on the relay is read normally) as applied and empty, so the device's later
/// files are read; it is never retried. Its changes are lost on this device unless its author resends its state (any
/// state resend still repairs it). A file that is not quarantined here is left alone.
void skipBlockedFile(WalletRepo repo, String device, String file) {
  final key = BadFile.keyOf(device, file);
  final bad = BadFiles.load(repo).byKey[key];
  if (bad == null) {
    logEvent(_log, Level.INFO, 'sync.skipFile.none');
    return;
  }
  final skipped = SkippedFiles.load(repo);
  skipped.byKey[key] = bad.hash;
  skipped.save(repo);
  final book = BlockedBook.load(repo);
  if (book.byKey.remove(key) != null) book.save(repo);
  logEvent(_log, Level.WARNING, 'sync.skipFile', {'reason': bad.reason.name});
}

/// One blocking file as the engine tracks it.
class BlockedEntry {
  /// First found blocking; runs it blocked in; when this device last asked the author (ms); the author's lastSeen (ms).
  int since, runs;
  int? asked, seen;
  SyncProblemReason reason;
  BlockedEntry(this.reason, {required this.since, this.runs = 1, this.asked, this.seen});

  BlockedFile file(String key) {
    final i = key.lastIndexOf('/');
    return BlockedFile(key.substring(0, i), key.substring(i + 1), reason,
        since: DateTime.fromMillisecondsSinceEpoch(since, isUtc: true),
        authorSeen: seen == null ? null : DateTime.fromMillisecondsSinceEpoch(seen!, isUtc: true));
  }

  Map<String, Object?> toJson() => {'r': reason.name, 's': since, 'n': runs, if (asked != null) 'a': asked, if (seen != null) 'w': seen};

  static BlockedEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final reason = SyncProblemReason.values.asNameMap()[j['r']];
    final (s, n, a, w) = (j['s'], j['n'], j['a'], j['w']);
    if (reason == null || s is! int || n is! int || (a != null && a is! int) || (w != null && w is! int)) return null;
    return BlockedEntry(reason, since: s, runs: n, asked: a as int?, seen: w as int?);
  }
}

/// The files blocking this device (`{"<stream>/<seq>": {"r", "s", "n", "a", "w"}}`), one device-local value
/// ([localKey], never synced), rewritten by every complete sync run.
class BlockedBook {
  static const localKey = 'syncBlocked';
  final Map<String, BlockedEntry> byKey;
  BlockedBook(this.byKey);

  static BlockedBook load(WalletRepo repo) => BlockedBook(_loadMap(repo, localKey, BlockedEntry.fromJson));

  void save(WalletRepo repo) =>
      repo.setLocalValue(localKey, byKey.isEmpty ? null : jsonEncode({for (final e in byKey.entries) e.key: e.value.toJson()}));
}

/// The files the owner skipped (`{"<stream>/<seq>": "<fileHash>"}`), one device-local value ([localKey], never synced).
/// Kept for good (the newest [maxKept]), so the same bytes are never retried, also after cursors start over.
class SkippedFiles {
  static const localKey = 'syncSkipped';
  static const maxKept = 64;
  final Map<String, String> byKey;
  SkippedFiles(this.byKey);

  static SkippedFiles load(WalletRepo repo) => SkippedFiles(_loadMap(repo, localKey, (j) => j is String ? j : null));

  void save(WalletRepo repo) {
    while (byKey.length > maxKept) {
      byKey.remove(byKey.keys.first);
    }
    repo.setLocalValue(localKey, byKey.isEmpty ? null : jsonEncode(byKey));
  }
}

Map<String, T> _loadMap<T extends Object>(WalletRepo repo, String localKey, T? Function(Object? j) parse) {
  final raw = repo.localValue(localKey);
  final out = <String, T>{};
  if (raw == null) return out;
  try {
    for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
      final v = parse(value);
      if (key is String && v != null) out[key] = v;
    }
  } on Object catch (e, st) {
    // Only this device's bookkeeping: start over (blocking files are found again on the next run).
    logError(_log, 'sync.blocked.unreadable', e, st, fields: {'value': localKey});
  }
  return out;
}
