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
  SyncEngine(this.transport, this.key, {this.appVersion = '', DateTime Function()? now, this.partBytes = maxPartBytes})
      : _now = now ?? DateTime.now;

  /// Largest sealed file this device uploads ([maxPartBytes]; lower in tests). An upload with more is split into
  /// several files (seqs), each at most this big: the relay refuses files over 16 MiB.
  final int partBytes;
  static const maxPartBytes = 8 << 20;

  /// Device-local: snapshots this device could not use, by id ([_BadSnapshots]).
  static const badSnapshotKey = 'syncBadSnapshots';

  /// A snapshot that could not be fetched (not refused) is fetched again only after this long.
  static const snapshotRetry = Duration(hours: 1);

  /// A caught-up device writes a snapshot when the newest is older than this (with none: since its first relay sync).
  static const snapshotAge = Duration(days: 7);

  /// ... or when files not covered by the newest snapshot hold at least this many ops.
  static const snapshotOpsBehind = 500;

  /// Device-local values: this device's last uploaded seq (absent = never met a relay) and when it first did.
  static const sentKey = 'syncSent', sinceKey = 'syncSince';

  /// Device-local: per (peer, device) pair where the peer's ack for that device's files is below what this device holds
  /// of them (its cursor, or its own last), that ack and since when (ms) it has stayed there
  /// (`{"<peer>/<device>": [ack, ms]}`); and when this device last wrote a heal snapshot (ms).
  static const stuckKey = 'syncPeerStuck', healKey = 'syncHealAt';

  /// Self-heal: a device seen within this long whose ack for some device's files has stayed below what this device
  /// applied of them for longer than this is taken as blocked on a file it refused; a caught-up device that holds the
  /// file then writes a snapshot at once (at most one heal snapshot per device per this long).
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
    final badSnaps = _BadSnapshots.load(repo);
    var badChanged = false, complete = false;
    // Per device that stopped: what it waits on, and the problem to report (none when a pruned file has no snapshot).
    final blocked = <String, (SyncWaiting, SyncProblem?)>{};
    Future<bool> snapshot({bool Function(RelaySnapshot s)? usable}) async {
      final got = await _applySnapshot(repo, state, cursors, badSnaps, usable: usable);
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
      if (snap != null && (pruned || (fresh && _current(snap)))) {
        // A pruned file leaves no choice; otherwise only a snapshot of this schema or newer (else it lacks fields).
        usedSnapshot = await snapshot(usable: pruned ? null : _current);
      }
      for (final d in peers) {
        await applyPeer(d);
      }
      // A file refused for good (quarantined, not one that merely could not be fetched) that a snapshot of this schema
      // or newer covers (it was readable for the device that wrote it): start from that snapshot, then go on after
      // it. Otherwise that device would wait for good.
      final refused = {
        for (final MapEntry(key: d, value: (w, _)) in blocked.entries)
          if (w.reason != null) d: w.seq
      };
      bool unblocks(RelaySnapshot s) => _current(s) && refused.entries.any((e) => e.value <= (s.covers[e.key] ?? 0));
      if (!usedSnapshot && [state.snapshot, state.previous].nonNulls.any(unblocks)) {
        logEvent(_log, Level.INFO, 'sync.snapshot.unblock', {'devices': refused.length});
        if (await snapshot(usable: unblocks)) {
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
        badSnaps.keepOnly({
          for (final s in [state.snapshot, state.previous].nonNulls) s.id
        });
      }
      if (badChanged) bad.save(repo);
      badSnaps.save(repo);
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
    final heal = _trackStuck(repo, state, cursors, myLast, now);
    final caughtUp = waiting.isEmpty && problems.isEmpty && peers.every((d) => cur(d) >= state.devices[d]!.last);
    // Snapshots not used are reported, but a device that applied every file is caught up without them.
    problems.addAll(badSnaps.problems.values);
    // Local imports and deletes match at once only while this holds (WalletRepo.syncCaughtUp); otherwise they wait
    // for the next caught-up run, like the ops applied here.
    repo.setLocalValue(WalletRepo.caughtUpKey, caughtUp ? '1' : '0');
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

  /// Uploads this device's next file (several when over [partBytes]). Returns (ops sent, this device's last seq on the
  /// relay after it).
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
    // One file per [partBytes] at most (the relay refuses files over 16 MiB): split by op count, sealed size
    // measured, halved while over. The outbox and [sentKey] change only once every part is stored, so a run that stops
    // half-way sends everything again next time (ops are idempotent: a clock is only taken when newer).
    var seq = relayLast, done = 0, size = ops.length, jsonBytes = 0, bytes = 0;
    while (done < ops.length) {
      var count = min(size, ops.length - done);
      List<int> payload, sealed;
      while (true) {
        payload = _filePayload(ops.sublist(done, done + count));
        sealed = await seal(payload, key);
        if (sealed.length <= partBytes || count == 1) break;
        count = (count + 1) ~/ 2;
      }
      try {
        await transport.put(me, seq + 1, sealed);
      } on TransportException catch (e) {
        if (e.failure == TransportFailure.conflict || e.failure == TransportFailure.rejected) {
          // The relay moved on since `state` (another install with this device id): kept, sent on the next run.
          logEvent(_log, Level.WARNING, 'sync.export.conflict', {'seq': seq + 1, 'failure': e.failure.name});
          return (0, seq);
        }
        throw _fatal('put', e);
      }
      seq++;
      repo.recordSyncFile(me, seq, count);
      done += count;
      size = count;
      jsonBytes += payload.length;
      bytes += sealed.length;
    }
    if (pending.isNotEmpty) repo.markExported(pending.last.$1);
    repo.setLocalValue(sentKey, '$seq');
    if (first) {
      repo.setLocalValue(sinceKey, repo.localValue(sinceKey) ?? '${_now().millisecondsSinceEpoch}');
      logEvent(_log, Level.INFO, 'sync.connect', {'ops': ops.length, 'relayLast': relayLast});
    }
    t.done({'ops': ops.length, 'seq': seq, 'files': seq - relayLast, 'jsonBytes': jsonBytes, 'bytes': bytes, 'whole': first});
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

  /// Whether a snapshot was written by this schema or newer (an older one lacks fields this build syncs).
  static bool _current(RelaySnapshot s) => (_snapshotSchema(s.id) ?? 0) >= WalletRepo.schemaVersion;

  /// Applies the latest snapshot (falling back to `previous`), only those [usable] accepts, and raises the cursors to
  /// its covers. One this device refused before is skipped until the relay names another id (unknownVersion and
  /// applyFailed: once more after [build] changes), one that could not be fetched until [snapshotRetry] has passed;
  /// both are recorded in [bad]. Returns (fields changed, ops, bytes), or null when none could be used.
  Future<(int, int, int)?> _applySnapshot(WalletRepo repo, RelayState state, Map<String, int> cursors, _BadSnapshots bad,
      {bool Function(RelaySnapshot s)? usable}) async {
    final now = _now();
    for (final (which, s) in [('latest', state.snapshot), ('previous', state.previous)]) {
      if (s == null || (usable != null && !usable(s))) continue;
      if (bad.skip(s.id, build, now)) {
        logEvent(_log, Level.INFO, 'sync.snapshot.skipped', {'which': which, 'reason': 'known'});
        continue;
      }
      final List<int> bytes;
      try {
        bytes = await transport.getSnapshot(s.id);
      } on TransportException catch (e) {
        logEvent(_log, Level.WARNING, 'sync.snapshot.unreadable', {'which': which, 'failure': e.failure.name});
        bad.unreadable(s.id, now);
        continue;
      }
      final int changed, count;
      try {
        (changed, count) = await _applyBytes(repo, key, bytes, (c) => backupPayloadOps(c, event: 'sync.snapshot.damaged'));
      } on _Refused catch (r) {
        logError(_log, 'sync.snapshot.failed', r.error, r.stack, fields: {'which': which, 'reason': r.reason.name, 'bytes': bytes.length});
        bad.refused(s.id, r.reason, bytes.length, await fileHash(bytes), build, now);
        continue;
      }
      bad.applied(s.id);
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
  /// device seen within [stuckAfter] has kept the same ack for some device D below what this device holds of D (its
  /// cursor, or [myLast] for its own files) for longer than [stuckAfter] (a file it refused stops it there for good: the
  /// relay never overwrites one, see the known limits), the newest snapshot does not cover the file it needs (else it
  /// starts from that snapshot by itself), and this device wrote no heal snapshot within [stuckAfter] ([healKey]).
  bool _trackStuck(WalletRepo repo, RelayState state, Map<String, int> cursors, int myLast, DateTime now) {
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
    final covers = state.snapshot?.covers ?? const <String, int>{};
    final next = <String, List<int>>{};
    var stuck = 0;
    for (final MapEntry(key: p, value: peer) in state.devices.entries) {
      final seen = peer.lastSeen;
      if (p == me || seen == null || now.difference(seen) > stuckAfter) continue;
      for (final d in state.devices.keys) {
        if (d == p) continue;
        final held = d == me ? myLast : cursors[d] ?? 0, ack = peer.acks[d] ?? 0;
        if (ack >= held) continue;
        final prev = old['$p/$d'];
        final since = prev is List && prev.length == 2 && prev[0] == ack && prev[1] is int ? prev[1] as int : now.millisecondsSinceEpoch;
        next['$p/$d'] = [ack, since];
        if ((covers[d] ?? 0) <= ack && now.difference(DateTime.fromMillisecondsSinceEpoch(since, isUtc: true)) > stuckAfter) stuck++;
      }
    }
    final text = jsonEncode(next);
    if (text != (stored ?? '{}')) repo.setLocalValue(stuckKey, text);
    if (stuck == 0) return false;
    final last = int.tryParse(repo.localValue(healKey) ?? '');
    final recent = last != null && now.difference(DateTime.fromMillisecondsSinceEpoch(last, isUtc: true)) < stuckAfter;
    logEvent(_log, Level.INFO, 'sync.stuck', {'pairs': stuck, 'recentHeal': recent});
    return !recent;
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
    if (heal) repo.setLocalValue(healKey, '${now.millisecondsSinceEpoch}');
    t.done({'ops': ops.length, 'bytes': sealed.length, 'devices': covers.length, 'behind': behind, 'aged': aged, 'heal': heal});
  }
}

/// Snapshots this device could not use, kept device-locally ([SyncEngine.badSnapshotKey], never synced) as
/// `{"<id>": {"reason": <SyncProblemReason name, null = could not be fetched>, "bytes", "hash", "build", "at" (ms)}}`,
/// so a snapshot of up to 64 MiB is not downloaded on every run. A refused one is skipped until the relay names another
/// id (a relay never stores other bytes under an id); unknownVersion/applyFailed are tried once more after the build
/// changes; one that could not be fetched is tried again after [SyncEngine.snapshotRetry]. Records of ids the relay no
/// longer lists are forgotten.
class _BadSnapshots {
  _BadSnapshots(this._byId, this._stored);
  final Map<String, Map<String, Object?>> _byId;
  final String? _stored;

  /// Snapshots wanted in this run but not applied, for [SyncReport.problems].
  final Map<String, SyncProblem> problems = {};

  static _BadSnapshots load(WalletRepo repo) {
    final stored = repo.localValue(SyncEngine.badSnapshotKey);
    final out = <String, Map<String, Object?>>{};
    if (stored != null) {
      try {
        for (final MapEntry(key: id, value: v) in (jsonDecode(stored) as Map).cast<String, Object?>().entries) {
          if (v is Map) out[id] = v.cast<String, Object?>();
        }
      } catch (e, st) {
        logError(_log, 'sync.badSnapshots.unreadable', e, st);
      }
    }
    return _BadSnapshots(out, stored);
  }

  static SyncProblemReason? _reason(Map<String, Object?> r) => switch (r['reason']) {
        final String n => SyncProblemReason.values.where((v) => v.name == n).firstOrNull ?? SyncProblemReason.corrupt,
        _ => null,
      };

  /// Whether [id] is skipped in this run (and then listed in [problems] as known).
  bool skip(String id, String build, DateTime now) {
    final r = _byId[id];
    if (r == null) return false;
    final reason = _reason(r);
    final at = r['at'] is int ? r['at'] as int : 0;
    final skipped = switch (reason) {
      null => now.difference(DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)) < SyncEngine.snapshotRetry,
      SyncProblemReason.unknownVersion || SyncProblemReason.applyFailed => r['build'] == build,
      _ => true,
    };
    if (skipped) {
      problems[id] = SyncProblem('', reason ?? SyncProblemReason.unreadable,
          bytes: r['bytes'] is int ? r['bytes'] as int : 0, isNew: false, snapshot: true);
    }
    return skipped;
  }

  void unreadable(String id, DateTime now) {
    _byId[id] = {'reason': null, 'at': now.millisecondsSinceEpoch};
    problems[id] = const SyncProblem('', SyncProblemReason.unreadable, bytes: 0, snapshot: true);
  }

  void refused(String id, SyncProblemReason reason, int bytes, String hash, String build, DateTime now) {
    _byId[id] = {'reason': reason.name, 'bytes': bytes, 'hash': hash, 'build': build, 'at': now.millisecondsSinceEpoch};
    problems[id] = SyncProblem('', reason, bytes: bytes, snapshot: true);
  }

  void applied(String id) {
    _byId.remove(id);
    problems.remove(id);
  }

  void keepOnly(Set<String> ids) => _byId.removeWhere((id, _) => !ids.contains(id));

  void save(WalletRepo repo) {
    final text = _byId.isEmpty ? null : jsonEncode(_byId);
    if (text != _stored) repo.setLocalValue(SyncEngine.badSnapshotKey, text);
  }
}
