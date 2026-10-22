// Transport-agnostic sync (DESIGN_DECISIONS §4.9, docs/context/RELAY_PROTOCOL.md). Web-safe: no dart:io here or in
// the transports (`sync_memory.dart`, `sync_relay.dart`).
import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/common.dart' show SqliteException;

import 'backup.dart';
import 'hlc.dart';
import 'logs.dart';
import 'repo.dart';
import 'sync.dart';
import 'sync_problems.dart';
import 'vault.dart';

export 'sync_memory.dart';
export 'sync_relay.dart';

final _log = Logger('bw.sync');

/// A kept snapshot on the relay: its [id] and how far it covers each device's files (device → seq).
class RelaySnapshot {
  final String id;
  final Map<String, int> covers;
  const RelaySnapshot(this.id, this.covers);

  Map<String, Object?> toJson() => {'id': id, 'covers': covers};
}

/// One device on the relay: files [first]..[last] are stored ([first] = [last] + 1 when all were pruned, 1 and 0 for
/// a device that only acked), when it was last heard from, and how far it applied each other device ([acks]).
class RelayDevice {
  final int first, last;
  final DateTime? lastSeen;
  final Map<String, int> acks;
  const RelayDevice({this.first = 1, this.last = 0, this.lastSeen, this.acks = const {}});

  Map<String, Object?> toJson() => {'first': first, 'last': last, 'lastSeen': lastSeen?.toUtc().toIso8601String(), 'acks': acks};
}

/// What `GET state` returns.
class RelayState {
  final Map<String, RelayDevice> devices;
  final RelaySnapshot? snapshot, previous;
  const RelayState({this.devices = const {}, this.snapshot, this.previous});

  /// A relay that never heard of this wallet.
  static const empty = RelayState();

  /// Parses the state JSON (the `api` field is checked by the transport). Throws [FormatException] when it is not one.
  factory RelayState.fromJson(Object? j) {
    if (j is! Map) throw const FormatException('state is not an object');
    Map<String, int> seqs(Object? m) {
      if (m == null) return const {};
      if (m is! Map) throw const FormatException('not a map of seqs');
      final out = <String, int>{};
      for (final MapEntry(:key, :value) in m.entries) {
        if (key is! String || value is! int) throw const FormatException('bad seq');
        out[key] = value;
      }
      return out;
    }

    RelayDevice dev(Object? v) {
      if (v is! Map || v['first'] is! int || v['last'] is! int) throw const FormatException('bad device');
      final seen = v['lastSeen'];
      return RelayDevice(
        first: v['first'] as int,
        last: v['last'] as int,
        lastSeen: seen is String ? DateTime.tryParse(seen) : null,
        acks: seqs(v['acks']),
      );
    }

    RelaySnapshot? snap(Object? s) {
      if (s == null) return null;
      if (s is! Map || s['id'] is! String) throw const FormatException('bad snapshot');
      return RelaySnapshot(s['id'] as String, seqs(s['covers']));
    }

    final devs = j['devices'] ?? const <String, Object?>{};
    if (devs is! Map) throw const FormatException('bad devices');
    return RelayState(
      devices: {for (final MapEntry(:key, :value) in devs.entries) '$key': dev(value)},
      snapshot: snap(j['snapshot']),
      previous: snap(j['previous']),
    );
  }

  Map<String, Object?> toJson() => {
        'api': 1,
        'devices': {for (final e in devices.entries) e.key: e.value.toJson()},
        'snapshot': snapshot?.toJson(),
        'previous': previous?.toJson(),
      };
}

/// Why a transport call failed (HTTP status in the relay's terms).
enum TransportFailure {
  /// No answer (network down, wrong address, timeout).
  unreachable,

  /// 401: the relay holds this wallet id with another token.
  refused,

  /// 410: pruned (below the device's `first`).
  gone,

  /// 404: never stored.
  missing,

  /// 409: other bytes already stored for that seq, or a snapshot that does not dominate the current one.
  conflict,

  /// 422 / 400: a gap, an ack beyond `last`, a bad name.
  rejected,

  /// 507 / 413: the relay is full or the body too big.
  full,

  /// The relay speaks a newer API than this build.
  newerApi,

  /// Anything else.
  other,
}

/// A failed transport call. [message] is short and names no address, id or path.
class TransportException implements Exception {
  final TransportFailure failure;
  final String message;
  const TransportException(this.failure, [this.message = '']);
  @override
  String toString() => 'TransportException(${failure.name}${message.isEmpty ? '' : ': $message'})';
}

/// Where sealed sync files live: a relay ([RelayTransport]) or memory ([MemoryTransport], tests).
abstract class SyncTransport {
  Future<RelayState> state();
  Future<void> put(String device, int seq, List<int> bytes);
  Future<List<int>> get(String device, int seq);
  Future<void> ack(String device, Map<String, int> cursors);
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes);
  Future<List<int>> getSnapshot(String id);
}

/// SQLite result codes that are about this device's database, not about the file being applied (busy, locked, out of
/// memory, read-only, I/O error, damaged database, disk full, cannot open, not a database). Those stop the run, and
/// the file is read again next time, instead of being refused for good.
const _dbTrouble = {5, 6, 7, 8, 10, 11, 13, 14, 26};

/// A file refused for [reason]; [error] is what was thrown.
class _Refused implements Exception {
  final SyncProblemReason reason;
  final Object error;
  final StackTrace stack;
  _Refused(this.reason, this.error, this.stack);
}

SyncProblemReason _unsealReason(VaultException e) => switch (e.failure) {
      UnsealFailure.badKey => SyncProblemReason.badKey,
      UnsealFailure.newerFormat => SyncProblemReason.unknownVersion,
      _ => SyncProblemReason.corrupt,
    };

/// Unseals [bytes], parses them with [parse] and applies the ops (matching is left to the caller). Returns (fields
/// changed, ops read). Throws [_Refused] when the file cannot be used; database errors from [_dbTrouble] are rethrown
/// as they are. The file is applied in one transaction: a refused file changes nothing.
Future<(int, int)> _applyBytes(WalletRepo repo, VaultKey key, List<int> bytes, List<Op> Function(List<int> clear) parse) async {
  final List<int> clear;
  try {
    clear = await unseal(bytes, key);
  } on VaultException catch (e, st) {
    throw _Refused(_unsealReason(e), e, st);
  }
  final List<Op> ops;
  try {
    ops = parse(clear);
  } on BackupException catch (e, st) {
    throw _Refused(e.reason == BackupFailure.newerVersion ? SyncProblemReason.unknownVersion : SyncProblemReason.corrupt, e, st);
  } on Object catch (e, st) {
    throw _Refused(SyncProblemReason.corrupt, e, st);
  }
  try {
    return (repo.applyRemote(ops, match: false), ops.length);
  } on SqliteException catch (e, st) {
    if (_dbTrouble.contains(e.resultCode)) rethrow;
    throw _Refused(SyncProblemReason.applyFailed, e, st);
  } on Object catch (e, st) {
    throw _Refused(SyncProblemReason.applyFailed, e, st);
  }
}

/// A sync file's content: a JSON list of ops. A clock that does not parse makes the whole file damaged.
List<Op> _fileOps(List<int> clear) {
  final ops = [for (final j in jsonDecode(utf8.decode(clear)) as List) Op.fromJson(Map<String, Object?>.from(j as Map))];
  for (final op in ops) {
    Hlc.parse(op.hlc);
  }
  return ops;
}

List<int> _filePayload(List<Op> ops) => utf8.encode(jsonEncode([for (final op in ops) op.toJson()]));

/// Syncs a [WalletRepo] through a [SyncTransport]. One [run]:
/// 1. reads the relay's state; uploads this device's pending ops as its next file (`last + 1`, so a failed upload
///    never leaves a gap). The first time this device meets a relay (or a relay that lost its files) the file is its
///    whole state instead ([WalletRepo.snapshotOps], original clocks), which also migrates a folder-sync wallet;
/// 2. starts from the latest snapshot (or `previous`) when a needed file was pruned, or when this device has applied
///    nothing yet (new device, schema-bump replay) and the snapshot is of this schema or newer;
/// 3. applies each other device's files strictly in seq order from its cursor ([WalletRepo.syncCursors]); a file that
///    cannot be fetched or is refused (quarantined in [BadFiles]) stops that device's later files ([SyncReport.waiting]);
/// 4. acks the cursors (every run, which keeps this device's `lastSeen` fresh);
/// 5. when caught up (every device applied through its `last`, nothing waiting or refused) runs matching and pairing
///    ([WalletRepo.runPendingMatch]) and writes a snapshot when the newest is older than [snapshotAge] or
///    [snapshotOpsBehind] ops behind.
class SyncEngine {
  final SyncTransport transport;
  final VaultKey key;

  /// The app's version, if the caller knows it: files refused because the database rejected them, or as a newer
  /// format, are read again once after it changes.
  final String appVersion;
  final DateTime Function() _now;
  SyncEngine(this.transport, this.key, {this.appVersion = '', DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// A caught-up device writes a snapshot when the newest is older than this (with none: since its first relay sync).
  static const snapshotAge = Duration(days: 7);

  /// ... or when files not covered by the newest snapshot hold at least this many ops.
  static const snapshotOpsBehind = 500;

  /// Device-local values: this device's last uploaded seq (absent = never met a relay) and when it first did.
  static const sentKey = 'syncSent', sinceKey = 'syncSince';

  /// Device-local: per other device whose ack for this device's files is below this device's last, that ack and since
  /// when (ms) it has stayed there (`{<device>: [ack, ms]}`).
  static const stuckKey = 'syncPeerStuck';

  /// Self-heal: a device seen within this long whose ack for this device's files has stayed below this device's last
  /// for longer than this is taken as blocked on a file it refused; a caught-up author then writes a snapshot at once.
  static const stuckAfter = Duration(hours: 24);

  /// What a quarantined file's record says about the build that refused it ([BadFile.build]): the file format this
  /// build reads, the database schema and the app version. Files refused as [SyncProblemReason.badKey] or
  /// [SyncProblemReason.corrupt] are never retried for a build change: only a changed file is.
  String get build => '$syncReaderVersion.${WalletRepo.schemaVersion}+$appVersion';

  static String _short(String device) => SyncProblem.shortId(device);

  /// A transport failure that ends the run, as a short message for people (no address, id or path).
  static SyncException _fatal(String step, TransportException e) {
    logEvent(_log, Level.WARNING, 'sync.failed', {'step': step, 'failure': e.failure.name});
    return SyncException(switch (e.failure) {
      TransportFailure.unreachable => 'The relay cannot be reached. Check its address and that this device is on the home network or VPN.',
      TransportFailure.refused => 'The relay refused this wallet: it holds a wallet with another key at this address.',
      TransportFailure.full => 'The relay is full. Free space on the home server or raise the relay\'s limits.',
      TransportFailure.newerApi => 'The relay runs a newer version. Update the app.',
      _ => 'The relay answered with an error. Try again later.',
    });
  }

  Future<SyncReport> run(WalletRepo repo) async {
    final t = PerfTimer('sync.run', warnMs: 2000);
    final me = repo.deviceId;
    final RelayState state;
    try {
      state = await transport.state();
    } on TransportException catch (e) {
      throw _fatal('state', e);
    }

    // 1. Upload.
    final (sent, myLast) = await _upload(repo, state);

    // 2. + 3. Apply the other devices' files.
    final peers = state.devices.keys.where((d) => d != me).toList()..sort();
    final cursors = repo.syncCursors();
    for (final d in peers) {
      final c = cursors[d] ?? 0, last = state.devices[d]!.last;
      if (c > last) {
        // The relay lost this device's files (a new or wiped relay): they start again at 1 with its whole state.
        logEvent(_log, Level.WARNING, 'sync.cursor.reset', {'was': c, 'last': last});
        repo.setSyncCursor(d, 0);
        cursors.remove(d);
      }
    }
    int cur(String d) => cursors[d] ?? 0;

    var received = 0, filesRead = 0, opsRead = 0, bytesRead = 0, known = 0;
    final problems = <SyncProblem>[];
    final waiting = <SyncWaiting>[];
    final bad = BadFiles.load(repo), listed = <String>{};
    var badChanged = false, complete = false;
    // Per device that stopped: what it waits on, and the problem to report (none when a pruned file has no snapshot).
    final blocked = <String, (SyncWaiting, SyncProblem?)>{};
    Future<bool> snapshot() async {
      final got = await _applySnapshot(repo, state, cursors);
      if (got == null) return false;
      received += got.$1;
      opsRead += got.$2;
      bytesRead += got.$3;
      filesRead++;
      return true;
    }

    /// Applies [d]'s files from its cursor, strictly in order, until one cannot be used.
    Future<void> applyPeer(String d) async {
      final dev = state.devices[d]!;
      while (cur(d) < dev.last) {
        final seq = cur(d) + 1;
        if (seq < dev.first) {
          logEvent(_log, Level.WARNING, 'sync.file.pruned', {'seq': seq});
          blocked[d] = (SyncWaiting(_short(d), seq), null);
          return;
        }
        final k = BadFile.keyOf(d, '$seq');
        final List<int> bytes;
        try {
          bytes = await transport.get(d, seq);
        } on TransportException catch (e) {
          // Not the file's fault (or not known to be): not quarantined, fetched again next run.
          logEvent(_log, Level.WARNING, 'sync.file.unreadable', {'seq': seq, 'failure': e.failure.name});
          blocked[d] = (SyncWaiting(_short(d), seq), SyncProblem(_short(d), SyncProblemReason.unreadable, bytes: 0));
          return;
        }
        final was = bad.byKey[k];
        if (was != null && !was.retryAfterUpgrade(build) && was.hash == await fileHash(bytes)) {
          listed.add(k);
          blocked[d] = (SyncWaiting(_short(d), seq, reason: was.reason), was.problem(isNew: false));
          known++;
          return;
        }
        final int changed, count;
        try {
          (changed, count) = await _applyBytes(repo, key, bytes, _fileOps);
        } on _Refused catch (r) {
          logError(_log, 'sync.file.failed', r.error, r.stack, fields: {'seq': seq, 'reason': r.reason.name, 'bytes': bytes.length});
          listed.add(k);
          bad.byKey[k] = BadFile(d, '$seq', r.reason, size: bytes.length, hash: await fileHash(bytes), build: build);
          badChanged = true;
          blocked[d] = (SyncWaiting(_short(d), seq, reason: r.reason), SyncProblem(_short(d), r.reason, bytes: bytes.length));
          return;
        }
        if (bad.byKey.remove(k) != null) badChanged = true;
        repo.setSyncCursor(d, seq);
        repo.recordSyncFile(d, seq, count);
        cursors[d] = seq;
        received += changed;
        filesRead++;
        opsRead += count;
        bytesRead += bytes.length;
        logEvent(_log, Level.FINE, 'sync.file', {'seq': seq, 'bytes': bytes.length, 'ops': count, 'changed': changed});
      }
    }

    try {
      final pruned = peers.any((d) {
        final dev = state.devices[d]!;
        return cur(d) < dev.last && cur(d) + 1 < dev.first;
      });
      final fresh = cursors.isEmpty && peers.any((d) => state.devices[d]!.last > 0);
      final snap = state.snapshot;
      var usedSnapshot = false;
      if (snap != null && (pruned || (fresh && (_snapshotSchema(snap.id) ?? 0) >= WalletRepo.schemaVersion))) {
        usedSnapshot = await snapshot();
      }
      for (final d in peers) {
        await applyPeer(d);
      }
      // A file that cannot be used but that the snapshot covers (it was readable for the device that wrote the
      // snapshot): start from the snapshot, then go on after it. Otherwise that device would wait for good.
      if (!usedSnapshot && snap != null && blocked.entries.any((e) => e.value.$1.seq <= (snap.covers[e.key] ?? 0))) {
        logEvent(_log, Level.INFO, 'sync.snapshot.unblock', {'devices': blocked.length});
        if (await snapshot()) {
          for (final d in blocked.keys.toList()) {
            if (cur(d) < blocked[d]!.$1.seq) continue;
            blocked.remove(d);
            await applyPeer(d);
          }
        }
      }
      for (final (w, p) in blocked.values) {
        waiting.add(w);
        if (p != null) problems.add(p);
      }
      complete = true;
    } finally {
      // Records of files that are no longer the one a device waits on (applied, or older bookkeeping) are forgotten,
      // but only after a complete pass.
      if (complete) {
        final gone = [
          for (final k in bad.byKey.keys)
            if (!listed.contains(k)) k
        ];
        for (final k in gone) {
          bad.byKey.remove(k);
        }
        badChanged |= gone.isNotEmpty;
      }
      if (badChanged) bad.save(repo);
    }

    // 4. Ack what was applied.
    final now = _now();
    var acked = false;
    try {
      await transport.ack(me, {
        for (final d in peers)
          if (cur(d) > 0 && cur(d) <= state.devices[d]!.last) d: cur(d)
      });
      acked = true;
    } on TransportException catch (e) {
      logEvent(_log, Level.WARNING, 'sync.ack.failed', {'failure': e.failure.name});
    }

    // 5. Caught up: match, and maybe write a snapshot.
    final heal = _trackStuck(repo, state, myLast, now);
    final caughtUp = waiting.isEmpty && problems.isEmpty && peers.every((d) => cur(d) >= state.devices[d]!.last);
    if (caughtUp) {
      repo.runPendingMatch();
      await _maybeSnapshot(repo, state, cursors, myLast, now, heal: heal);
    } else {
      logEvent(_log, Level.INFO, 'sync.match.waiting', {'waiting': waiting.length, 'bad': problems.length});
    }

    final fresh = problems.where((p) => p.isNew).length;
    if (problems.isNotEmpty) {
      logEvent(_log, fresh > 0 ? Level.WARNING : Level.INFO, 'sync.files.skipped', {'bad': problems.length, 'new': fresh});
    }
    final ids = {...state.devices.keys, me}.toList()..sort();
    t.done({
      'devices': peers.length,
      'sent': sent,
      'files': filesRead,
      'ops': opsRead,
      'changed': received,
      'bytes': bytesRead,
      'bad': problems.length,
      'known': known,
      'waiting': waiting.length,
      'caughtUp': caughtUp,
    });
    return SyncReport(sent, received, filesRead, problems: problems, caughtUp: caughtUp, waiting: waiting, devices: [
      for (final d in ids)
        SyncDevice(_short(d),
            lastSeen: d == me ? (acked || sent > 0 ? now : state.devices[d]?.lastSeen) : state.devices[d]!.lastSeen, isThis: d == me),
    ]);
  }

  /// Uploads this device's next file. Returns (ops sent, this device's last seq on the relay after it).
  Future<(int, int)> _upload(WalletRepo repo, RelayState state) async {
    final me = repo.deviceId;
    final relayLast = state.devices[me]?.last ?? 0;
    final marker = int.tryParse(repo.localValue(sentKey) ?? '');
    final first = marker == null || relayLast < marker;
    final pending = repo.pendingOps();
    final ops = first ? repo.snapshotOps() : [for (final (_, op) in pending) op];
    if (ops.isEmpty) {
      if (first) {
        repo.setLocalValue(sentKey, '$relayLast');
        repo.setLocalValue(sinceKey, repo.localValue(sinceKey) ?? '${_now().millisecondsSinceEpoch}');
        if (pending.isNotEmpty) repo.markExported(pending.last.$1);
        logEvent(_log, Level.INFO, 'sync.connect', {'ops': 0, 'relayLast': relayLast});
      } else {
        logEvent(_log, Level.FINE, 'sync.export.none');
      }
      return (0, relayLast);
    }
    final t = PerfTimer('sync.export', warnMs: 500);
    final seq = relayLast + 1;
    final payload = _filePayload(ops);
    final sealed = await seal(payload, key);
    try {
      await transport.put(me, seq, sealed);
    } on TransportException catch (e) {
      if (e.failure == TransportFailure.conflict || e.failure == TransportFailure.rejected) {
        // The relay moved on since `state` (another install with this device id): kept, sent on the next run.
        logEvent(_log, Level.WARNING, 'sync.export.conflict', {'seq': seq, 'failure': e.failure.name});
        return (0, relayLast);
      }
      throw _fatal('put', e);
    }
    if (pending.isNotEmpty) repo.markExported(pending.last.$1);
    repo.setLocalValue(sentKey, '$seq');
    repo.recordSyncFile(me, seq, ops.length);
    if (first) {
      repo.setLocalValue(sinceKey, repo.localValue(sinceKey) ?? '${_now().millisecondsSinceEpoch}');
      logEvent(_log, Level.INFO, 'sync.connect', {'ops': ops.length, 'relayLast': relayLast});
    }
    t.done({'ops': ops.length, 'seq': seq, 'jsonBytes': payload.length, 'bytes': sealed.length, 'whole': first});
    return (ops.length, seq);
  }

  /// The schema version a snapshot id names (`s<schema>-<ms>-<random>`, see [_snapshotId]); null for another form.
  static int? _snapshotSchema(String id) => int.tryParse(RegExp(r'^s(\d+)-\d+-').firstMatch(id)?.group(1) ?? '');

  /// When a snapshot id says it was written; null for another form.
  static DateTime? _snapshotTime(String id) {
    final ms = int.tryParse(RegExp(r'^s\d+-(\d+)-').firstMatch(id)?.group(1) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  static String _snapshotId(DateTime now) {
    final r = Random.secure();
    final tail = List.generate(4, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 's${WalletRepo.schemaVersion}-${now.millisecondsSinceEpoch}-$tail';
  }

  /// Applies the latest snapshot (falling back to `previous`) and raises the cursors to its covers. Returns (fields
  /// changed, ops, bytes), or null when neither could be used.
  Future<(int, int, int)?> _applySnapshot(WalletRepo repo, RelayState state, Map<String, int> cursors) async {
    for (final (which, s) in [('latest', state.snapshot), ('previous', state.previous)]) {
      if (s == null) continue;
      final List<int> bytes;
      try {
        bytes = await transport.getSnapshot(s.id);
      } on TransportException catch (e) {
        logEvent(_log, Level.WARNING, 'sync.snapshot.unreadable', {'which': which, 'failure': e.failure.name});
        continue;
      }
      final int changed, count;
      try {
        (changed, count) = await _applyBytes(repo, key, bytes, (c) => backupPayloadOps(c, event: 'sync.snapshot.damaged'));
      } on _Refused catch (r) {
        logError(_log, 'sync.snapshot.failed', r.error, r.stack, fields: {'which': which, 'reason': r.reason.name, 'bytes': bytes.length});
        continue;
      }
      var raised = 0;
      for (final MapEntry(key: d, value: seq) in s.covers.entries) {
        if (d == repo.deviceId || seq <= (cursors[d] ?? 0)) continue;
        repo.setSyncCursor(d, seq);
        cursors[d] = seq;
        raised++;
      }
      logEvent(_log, Level.INFO, 'sync.snapshot.applied',
          {'which': which, 'ops': count, 'changed': changed, 'bytes': bytes.length, 'devices': raised});
      return (changed, count, bytes.length);
    }
    return null;
  }

  /// Updates [stuckKey] (every run, caught up or not) and says whether a snapshot should heal a peer now: another
  /// device seen within [stuckAfter] has kept the same ack below [myLast] for this device's files for longer than
  /// [stuckAfter] (a file it refused stops it there for good: the relay never overwrites one, see the known limits), and
  /// the newest snapshot does not cover the file it needs (else it starts from that snapshot by itself).
  bool _trackStuck(WalletRepo repo, RelayState state, int myLast, DateTime now) {
    final me = repo.deviceId;
    final stored = repo.localValue(stuckKey);
    var old = const <String, Object?>{};
    if (stored != null) {
      try {
        old = (jsonDecode(stored) as Map).cast<String, Object?>();
      } catch (e, st) {
        logError(_log, 'sync.stuck.unreadable', e, st);
      }
    }
    final covered = state.snapshot?.covers[me] ?? 0;
    final next = <String, List<int>>{};
    var heal = 0;
    for (final MapEntry(key: d, value: dev) in state.devices.entries) {
      final seen = dev.lastSeen, ack = dev.acks[me] ?? 0;
      if (d == me || seen == null || now.difference(seen) > stuckAfter || ack >= myLast) continue;
      final prev = old[d];
      final since = prev is List && prev.length == 2 && prev[0] == ack && prev[1] is int ? prev[1] as int : now.millisecondsSinceEpoch;
      next[d] = [ack, since];
      if (covered <= ack && now.difference(DateTime.fromMillisecondsSinceEpoch(since, isUtc: true)) > stuckAfter) heal++;
    }
    final text = jsonEncode(next);
    if (text != (stored ?? '{}')) repo.setLocalValue(stuckKey, text);
    if (heal > 0) logEvent(_log, Level.INFO, 'sync.stuck', {'devices': heal});
    return heal > 0;
  }

  /// Writes a snapshot when the newest is older than [snapshotAge] or [snapshotOpsBehind] ops behind, or at once with
  /// [heal] ([_trackStuck]) (called only when caught up). Failures are logged: another device may simply have written a
  /// newer one.
  Future<void> _maybeSnapshot(WalletRepo repo, RelayState state, Map<String, int> cursors, int myLast, DateTime now,
      {bool heal = false}) async {
    final me = repo.deviceId;
    final current = state.snapshot;
    final old = current?.covers ?? const <String, int>{};
    repo.forgetSyncFiles(old);
    final behind = repo.syncOpsAfter(old);
    if (behind == 0 && !heal) return;
    final since = current == null
        ? switch (int.tryParse(repo.localValue(sinceKey) ?? '')) {
            final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
            null => null,
          }
        : _snapshotTime(current.id);
    final aged = since != null && now.difference(since) > snapshotAge;
    if (behind < snapshotOpsBehind && !aged && !heal) return;
    final covers = <String, int>{
      for (final d in state.devices.keys)
        if (d != me) d: cursors[d] ?? 0,
      me: myLast,
    };
    for (final MapEntry(key: d, value: seq) in old.entries) {
      if ((covers[d] ?? 0) < seq) {
        logEvent(_log, Level.INFO, 'sync.snapshot.skipped', {'reason': 'behind'});
        return;
      }
    }
    final t = PerfTimer('sync.snapshot.write', warnMs: 2000);
    final ops = repo.snapshotOps();
    final sealed = await seal(backupPayload(ops), key);
    try {
      await transport.putSnapshot(_snapshotId(now), covers, sealed);
    } on TransportException catch (e) {
      logEvent(_log, Level.WARNING, 'sync.snapshot.refused', {'failure': e.failure.name});
      return;
    }
    repo.forgetSyncFiles(covers);
    t.done({'ops': ops.length, 'bytes': sealed.length, 'devices': covers.length, 'behind': behind, 'aged': aged, 'heal': heal});
  }
}
