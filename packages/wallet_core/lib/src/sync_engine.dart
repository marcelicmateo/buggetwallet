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

  /// The relay's id for this wallet's store (32 hex, random, kept in its `meta.json`): a wiped or replaced relay
  /// names another one. Null from an older relay (api 2) and for a wallet it does not know yet.
  final String? instance;

  /// Relay usage (Stage I): the wallet's stored bytes as the relay's `--max-bytes` counts them (sync files + kept
  /// snapshots + bill files) and that limit. Null from an older relay, and each alone when its value is not a
  /// non-negative integer (shown as "unknown"; usage never fails a sync).
  final int? bytes, maxBytes;

  /// The relay's api version as the state names it (3 or 4 from a relay; null when unknown). From 4 on the engine
  /// declares each snapshot's blob set ([SyncTransport.putSnapshotBlobs]) and the relay collects old bill files.
  final int? api;
  const RelayState({this.devices = const {}, this.snapshot, this.previous, this.instance, this.bytes, this.maxBytes, this.api});

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
    final instance = j['instance'];
    if (instance != null && (instance is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(instance))) {
      throw const FormatException('bad instance');
    }
    int? usage(Object? v) => v is int && v >= 0 ? v : null;
    return RelayState(
      api: j['api'] is int ? j['api'] as int : null,
      instance: instance as String?,
      bytes: usage(j['bytes']),
      maxBytes: usage(j['maxBytes']),
      devices: {for (final MapEntry(:key, :value) in devs.entries) '$key': dev(value)},
      snapshot: snap(j['snapshot']),
      previous: snap(j['previous']),
    );
  }

  Map<String, Object?> toJson() => {
        'api': api ?? 1,
        'devices': {for (final e in devices.entries) e.key: e.value.toJson()},
        'snapshot': snapshot?.toJson(),
        'previous': previous?.toJson(),
        if (instance != null) 'instance': instance,
        if (bytes != null) 'bytes': bytes,
        if (maxBytes != null) 'maxBytes': maxBytes,
      };
}

/// Why a transport call failed (HTTP status in the relay's terms).
enum TransportFailure {
  /// No answer (network down, wrong address, timeout).
  unreachable,

  /// 401: the relay holds this wallet id with another key (the signature does not verify).
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

  /// The relay speaks an older API than this build (update the relay).
  olderApi,

  /// The relay's clock (its `Date` header) differs from this device's by more than a day: not trusted, not retried.
  clockSkew,

  /// 403 `createToken`: the relay creates wallets only with its create token, and this device sent none or a wrong one.
  createToken,

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

  /// Stores a sealed bill file under [hash] (RELAY_PROTOCOL.md "Blobs"). A relay that does not know the wallet yet, or
  /// an older relay without blobs, answers 404: [TransportFailure.missing]. The defaults here are such an older relay.
  Future<void> putBlob(String hash, List<int> bytes) async => throw const TransportException(TransportFailure.missing, 'no blobs');

  /// The sealed file stored under [hash], or null when the relay does not have it (404).
  Future<List<int>?> getBlob(String hash) async => null;

  /// Declares the blob hashes the live bills of snapshot [id] reference (api 4, RELAY_PROTOCOL.md "Blob garbage
  /// collection"): sent right after that snapshot's PUT. Clients never delete blobs; there is no delete call. The
  /// default is a relay without declared sets (404).
  Future<void> putSnapshotBlobs(String id, List<String> hashes) async =>
      throw const TransportException(TransportFailure.missing, 'no declared sets');
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

  /// [SyncProblemReason.clockDrift]: when (wall clock, ms) the file is no longer too far ahead.
  final int? retryAt;
  _Refused(this.reason, this.error, this.stack, {this.retryAt});
}

SyncProblemReason _unsealReason(VaultException e) => switch (e.failure) {
      UnsealFailure.badKey => SyncProblemReason.badKey,
      UnsealFailure.newerFormat => SyncProblemReason.unknownVersion,
      UnsealFailure.damaged || UnsealFailure.tooLarge || null => SyncProblemReason.corrupt,
    };

/// Unseals [bytes] (sealed for [aad]), parses them with [parse] and applies the ops (matching is left to the caller).
/// Returns (fields changed, ops read). Throws [_Refused] when the file cannot be used, also when its newest clock is
/// more than [maxClockDrift] ahead of [nowMs]; database errors from [_dbTrouble] are rethrown as they are. The file is
/// applied in one transaction: a refused file changes nothing.
Future<(int, int)> _applyBytes(
    WalletRepo repo, VaultKey key, List<int> bytes, List<Op> Function(List<int> clear) parse, List<int> aad, int nowMs) async {
  final List<int> clear;
  try {
    clear = await unseal(bytes, key, aad: aad);
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
  var newest = 0;
  for (final op in ops) {
    final m = Hlc.parse(op.hlc).millis;
    if (m > newest) newest = m;
  }
  final drift = maxClockDrift.inMilliseconds;
  if (newest - nowMs > drift) {
    throw _Refused(SyncProblemReason.clockDrift, StateError('clock ahead by ${(newest - nowMs) ~/ 60000} min'), StackTrace.current,
        retryAt: newest - drift);
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

  /// Device-local: the relay instance id ([RelayState.instance]) of the last run whose upload went through. Another id
  /// from the relay = a wiped, restored or replaced relay: that run is a first connect ([SyncReport.relayChanged]).
  static const instanceKey = 'syncInstance';

  /// Device-local (H5b): the relay device name this install writes under now, its **stream** ([streamName]; absent =
  /// its device id, as every file before Stage H). A fresh stream is taken whenever this one may not be this install's
  /// alone ([_move]): the relay holds fewer of its files than were sent (a restored copy or a wiped relay: a seq reused
  /// with other content would be skipped by peers that read the old one), more than were sent with no own upload cut
  /// short, or a 409 on an own seq (another install with this id, e.g. a copied database). The new stream starts at
  /// seq 1 with the whole state; peers never saw its name, so they read all of it.
  static const streamKey = 'syncStream';

  /// Device-local: the streams this install has written (JSON list), the current one included once it uploaded to it,
  /// the old id's after an id change (H6). It acks under each of them that the relay still lists, so nothing it wrote
  /// holds back pruning. A stream left because another install may write it is dropped from the list (never acked as).
  static const streamsKey = 'syncStreams';

  /// Device-local: streams of this device id written by another install, already reported as
  /// [SyncProblemReason.deviceIdInUse] (JSON list), so each is reported once.
  static const foreignKey = 'syncForeign';

  /// Device-local: `{"from": <the stream's last before it>, "parts": {"<seq>": "<fileHash of the sealed part>"}}` while
  /// an upload is under way (each part recorded before its PUT). Cleared once every part is stored (and on a 409).
  /// When the stream holds more than [sentKey] says, a seq counts as this install's own cut-off file only if its stored
  /// bytes hash to the recorded part (fetched once to check); anything else is another install's.
  static const sendingKey = 'syncSending';

  /// Device-local: per stream in [streamsKey] that this install no longer writes, the relay `last` when it left it
  /// (`{"<stream>": n}`; an H6 id change records the old id's `syncSent`). Should the relay ever hold more, another install
  /// writes it: it is dropped from [streamsKey] (never acked as again) and treated as foreign.
  static const streamLastKey = 'syncStreamLast';

  /// Device-local: the acks this install stored per stream it acks as (`{"<stream>": {"<device>": seq}}`). The relay
  /// only ever raises acks, so one below these means the relay was rolled back (its data folder restored from a copy,
  /// even with the same instance): every cursor goes back to 0 ([SyncReport.relayChanged]).
  static const ackedKey = 'syncAcked';

  static Map<String, Object?> _map(WalletRepo repo, String key) {
    final raw = repo.localValue(key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } on Object catch (e, st) {
      logError(_log, 'sync.local.unreadable', e, st, fields: {'key': key});
      return {};
    }
  }

  static void _setMap(WalletRepo repo, String key, Map<String, Object?> v) => repo.setLocalValue(key, v.isEmpty ? null : jsonEncode(v));

  /// The relay device name of [deviceId]'s stream [epoch]: the id itself for epoch 0 (every file before Stage H), else
  /// `<id>-<epoch><tag>` with [tag] six random lower-case letters, so two installs (or one install after a double
  /// restore) never pick the same name. Device ids hold only letters and digits (at most 48), so the name parses back
  /// and stays within the relay's 64 characters.
  static String streamName(String deviceId, int epoch, [String tag = '']) => epoch == 0 ? deviceId : '$deviceId-$epoch$tag';

  static final _streamPattern = RegExp(r'^(.+)-(\d{1,9})([a-z]{6})$');

  /// The device id a relay device name belongs to ([streamName] backwards).
  static String streamBase(String stream) => _streamPattern.firstMatch(stream)?.group(1) ?? stream;

  /// The epoch of a relay device name (0 for a plain id).
  static int streamEpoch(String stream) => int.tryParse(_streamPattern.firstMatch(stream)?.group(2) ?? '') ?? 0;

  /// This install's current stream name ([streamKey]; one of another id, left over, counts as absent).
  static String _streamOf(WalletRepo repo) {
    final s = repo.localValue(streamKey);
    return s != null && streamBase(s) == repo.deviceId ? s : repo.deviceId;
  }

  static List<String> _list(WalletRepo repo, String key) {
    final raw = repo.localValue(key);
    if (raw == null) return [];
    try {
      return [for (final v in jsonDecode(raw) as List) v as String];
    } on Object catch (e, st) {
      logError(_log, 'sync.streams.unreadable', e, st);
      return [];
    }
  }

  static void _setList(WalletRepo repo, String key, List<String> v) => repo.setLocalValue(key, v.isEmpty ? null : jsonEncode(v));

  /// Takes a fresh stream ([streamKey]): the next epoch above every stream of this id the relay lists or this install
  /// wrote, with a random tag. [shared]: the stream left may be written by another install, so it is no longer acked as
  /// and not reported as foreign later; otherwise (the relay lost files) it stays in [streamsKey]. [sentKey] and
  /// [sendingKey] are cleared, so the next upload is the whole state.
  static String _move(WalletRepo repo, RelayState state, {required bool shared, required String reason}) {
    final cur = _streamOf(repo), id = repo.deviceId;
    final written = _list(repo, streamsKey);
    if (shared) {
      written.remove(cur);
      _setList(repo, foreignKey, {..._list(repo, foreignKey), cur}.toList());
    } else {
      if (repo.localValue(sentKey) != null && !written.contains(cur)) written.add(cur); // listed only since Stage H
      // Its relay `last` now: should it grow, another install writes it ([streamLastKey]).
      _setMap(repo, streamLastKey, {..._map(repo, streamLastKey), cur: state.devices[cur]?.last ?? 0});
    }
    var epoch = streamEpoch(cur);
    for (final d in [...state.devices.keys, ...written]) {
      if (streamBase(d) == id) epoch = max(epoch, streamEpoch(d));
    }
    final r = Random.secure();
    final name = streamName(id, epoch + 1, String.fromCharCodes([for (var i = 0; i < 6; i++) 0x61 + r.nextInt(26)]));
    _setList(repo, streamsKey, written);
    repo.setLocalValue(streamKey, name);
    repo.setLocalValue(sentKey, null);
    repo.setLocalValue(sendingKey, null);
    logEvent(_log, Level.WARNING, 'sync.stream.moved', {'epoch': epoch + 1, 'reason': reason});
    return name;
  }

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

  /// The short id the app shows for relay device name [device]: of its device id, so every stream of one device
  /// reads as that device.
  static String _short(String device) => SyncProblem.shortId(streamBase(device));

  /// A transport failure that ends the run, as a short message for people (no address, id or path).
  static SyncException _fatal(String step, TransportException e) {
    logEvent(_log, Level.WARNING, 'sync.failed', {'step': step, 'failure': e.failure.name});
    return SyncException(switch (e.failure) {
      TransportFailure.unreachable => 'The relay cannot be reached. Check its address and that this device is on the home network or VPN.',
      TransportFailure.refused => 'The relay refused this wallet: it holds a wallet with another key at this address.',
      TransportFailure.full => 'The relay is full. Free space on the home server or raise the relay\'s limits.',
      TransportFailure.newerApi => 'The relay runs a newer version. Update the app.',
      TransportFailure.olderApi => 'The relay runs an older version. Update the relay on the home server.',
      TransportFailure.clockSkew =>
        "This device's clock and the relay's clock differ by more than a day. Check the date and time settings.",
      TransportFailure.createToken => "The relay needs its create token to start a new wallet. Enter it in this device's sync settings.",
      _ => 'The relay answered with an error. Try again later.',
    });
  }

  Future<SyncReport>? _running;

  /// One sync run: upload, apply, ack, match/snapshot when caught up. A call while a run of this engine is still in
  /// progress starts no second one: it returns the running run's future (`sync.run.joined`). Runs of two engines on
  /// one database are not guarded (the app keeps one engine per wallet).
  Future<SyncReport> run(WalletRepo repo) {
    if (_running case final r?) {
      logEvent(_log, Level.FINE, 'sync.run.joined');
      return r;
    }
    return _running = _run(repo).whenComplete(() => _running = null);
  }

  Future<SyncReport> _run(WalletRepo repo) async {
    final t = PerfTimer('sync.run', warnMs: 2000);
    final me = repo.deviceId;
    RelayState state;
    try {
      state = await transport.state();
    } on TransportException catch (e) {
      throw _fatal('state', e);
    }
    // H5: a relay that names another instance than last time lost (or never had) what this device knows of it, even
    // when its seq numbers look plausible (an older image restored): a first connect, every cursor from the start.
    final storedInstance = repo.localValue(instanceKey);
    var relayChanged = state.instance != null && storedInstance != null && storedInstance != state.instance;
    // HBb: acks only ever grow on a relay. One below what this install stored = the relay's folder was restored from an
    // older copy (same instance): files it now numbers again may differ from the ones read. Start over like a new relay.
    if (!relayChanged) {
      var rolledBack = false;
      for (final MapEntry(key: s, value: m) in _map(repo, ackedKey).entries) {
        final relay = state.devices[s]?.acks ?? const <String, int>{};
        if (m is Map && m.entries.any((e) => e.value is int && (relay[e.key] ?? 0) < (e.value as int))) rolledBack = true;
      }
      if (rolledBack) {
        logEvent(_log, Level.WARNING, 'sync.relay.rolledBack');
        relayChanged = true;
      }
    }
    if (relayChanged) {
      repo.setLocalValue(ackedKey, null);
      final reset = repo.syncCursors();
      for (final d in reset.keys) {
        repo.setSyncCursor(d, 0);
      }
      logEvent(_log, Level.WARNING, 'sync.relay.changed', {'cursors': reset.length});
    }

    // 1. Upload: bill files first, then the ops (P14 "upload before ops": a bill op that references a file this device
    // holds goes up only once that file was stored in this run; RELAY_PROTOCOL.md "Client rules for blobs"). A first
    // connect (new or changed relay) re-uploads every cached file a live bill points to.
    final sentMarker = int.tryParse(repo.localValue(sentKey) ?? '');
    // Also a relay that holds fewer of this stream's files than were sent (wiped, or restored from an older copy).
    final firstConnect = relayChanged || sentMarker == null || (state.devices[_streamOf(repo)]?.last ?? 0) < sentMarker;
    // The schema-15 migration lists the live bills' files to put again (api-3 builds deleted files on the relay).
    final reuploadList = _reuploadList(repo);
    Set<String> refs() => {...repo.pendingBlobRefs(), if (firstConnect) ...repo.liveBlobHashes(), ...?reuploadList};
    final blobsStored = <String>{};
    final blobFailures = <String, TransportFailure>{};
    var (blobsSent, blobMissing) = await _uploadBlobs(repo, refs(), blobsStored, blobFailures);
    final walletKnown = (state.devices[_streamOf(repo)]?.last ?? 0) > 0;
    // 404 on a bill file of a wallet the relay knows: an older relay without blob storage. Its ops then go without
    // their files (they could never be stored there); the files stay queued.
    var blobsUnsupported = blobMissing && walletKnown;
    var (sent, myLast, inUseUpload) =
        await _upload(repo, state, relayChanged: relayChanged, stored: blobsStored, holdNone: blobsUnsupported);
    var refreshed = false;
    if (state.devices.isEmpty && myLast > 0) {
      // The relay did not know this wallet (new, or wiped) and this upload created it: its instance id exists only now.
      // Asked once more, so this run reports and keeps it (a wiped relay is then `relayChanged` here too).
      try {
        state = await transport.state();
        if (state.instance != null && storedInstance != null && storedInstance != state.instance) {
          relayChanged = true;
          logEvent(_log, Level.WARNING, 'sync.relay.changed', {'cursors': 0});
        }
        _keepInstance(repo, state);
        refreshed = true;
      } on TransportException catch (e) {
        logEvent(_log, Level.WARNING, 'sync.state.again', {'failure': e.failure.name});
      }
    }
    // From here on `stream` is this device's relay name (the upload may have started a new epoch). Its older streams
    // are read like a peer's (idempotent: this device holds those ops) and acked under their names too, so they never
    // hold back pruning or look stuck. A stream of this id with a higher epoch than this device ever used was written
    // by another install with this id.
    final stream = _streamOf(repo);
    final written = _list(repo, streamsKey);
    // A stream this install left that holds more files than when it left it: another install writes it (an H6 id
    // change on a copied database while the original goes on, or a 'behind' stream someone else continued). Never
    // acked as again: its acks would claim reads that install never made, and let the relay prune too early.
    final leftAt = _map(repo, streamLastKey);
    final grown = [
      for (final d in written)
        if (d != stream && leftAt[d] is int && (state.devices[d]?.last ?? 0) > (leftAt[d] as int)) d
    ];
    if (grown.isNotEmpty) {
      logEvent(_log, Level.WARNING, 'sync.stream.grown', {'streams': grown.length});
      written.removeWhere(grown.contains);
      _setList(repo, streamsKey, written);
      _setList(repo, foreignKey, {..._list(repo, foreignKey), ...grown}.toList());
      _setMap(repo, ackedKey, _map(repo, ackedKey)..removeWhere((k, _) => grown.contains(k)));
    }
    final ownOld = [
      for (final d in written)
        if (d != stream && state.devices.containsKey(d)) d
    ]..sort();
    // A stream of this id that this install never wrote and has not reported yet: another install with this id (it
    // writes there, so this install only reads it). Reported once; nothing to do, both keep syncing.
    final reported = _list(repo, foreignKey);
    final sighted = [
      for (final d in state.devices.keys)
        if (streamBase(d) == me && d != stream && !written.contains(d) && !reported.contains(d)) d
    ];
    if (sighted.isNotEmpty) {
      logEvent(_log, Level.WARNING, 'sync.stream.foreign', {'streams': sighted.length});
      _setList(repo, foreignKey, [...reported, ...sighted]);
    }
    final inUse =
        inUseUpload ?? (sighted.isNotEmpty || grown.isNotEmpty ? SyncProblem(_short(me), SyncProblemReason.deviceIdInUse, bytes: 0) : null);
    if (blobMissing && !walletKnown && myLast > 0) {
      // A relay creates a wallet only with this device's first file: the files it refused before that go now, and
      // then the ops that waited for them (with a fresh state only, so the upload continues this stream's seqs).
      final before = blobsStored.length;
      final (more, missingAgain) = await _uploadBlobs(repo, refs(), blobsStored, blobFailures);
      blobsSent += more;
      blobsUnsupported = missingAgain;
      if (refreshed && (blobsStored.length > before || missingAgain) && repo.pendingOps().isNotEmpty) {
        final (n, last, _) = await _upload(repo, state, relayChanged: false, stored: blobsStored, holdNone: missingAgain);
        sent += n;
        myLast = last;
      }
    }
    if (reuploadList != null) {
      // Only the ones not confirmed yet stay listed (a file that keeps failing never makes every run re-upload the whole
      // cache); a relay without blob storage ends it.
      final left = blobsUnsupported
          ? const <String>[]
          : [
              for (final h in reuploadList)
                if (!blobsStored.contains(h) && repo.hasCachedBlob(h)) h
            ];
      repo.setLocalValue(WalletRepo.blobReuploadKey, left.isEmpty ? null : jsonEncode(left));
      logEvent(_log, Level.INFO, 'sync.blobs.reupload', {'left': left.length, 'unsupported': blobsUnsupported});
    }

    // 2. + 3. Apply the other devices' files.
    final peers = state.devices.keys.where((d) => d != stream).toList()..sort();
    final cursors = repo.syncCursors();
    for (final d in cursors.keys.where((d) => !state.devices.containsKey(d)).toList()) {
      // A stream the relay does not list any more (a wiped relay, or one restored from a copy made before it): if that
      // name comes back, its files start at 1 and are read from there.
      logEvent(_log, Level.WARNING, 'sync.cursor.reset', {'was': cursors[d], 'last': 0});
      repo.setSyncCursor(d, 0);
      cursors.remove(d);
    }
    for (final d in peers) {
      final c = cursors[d] ?? 0, last = state.devices[d]!.last;
      if (c > last) {
        // The relay lost this device's files (a new or wiped relay): they start again at 1 with its whole state.
        logEvent(_log, Level.WARNING, 'sync.cursor.reset', {'was': c, 'last': last});
        repo.setSyncCursor(d, 0);
        cursors.remove(d);
      }
    }
    final run = _ApplyRun(state, cursors, BadFiles.load(repo), _BadSnapshots.load(repo));
    final problems = <SyncProblem>[if (inUse != null) inUse];
    final waiting = <SyncWaiting>[];
    try {
      final usedSnapshot = await _startFromSnapshot(repo, run, peers);
      for (final d in peers) {
        run.record(d, await _applyPeer(repo, run, d));
      }
      if (!usedSnapshot) await _unblockBySnapshot(repo, run);
      for (final (w, p) in run.blocked.values) {
        waiting.add(w);
        if (p != null) problems.add(p);
      }
      run.complete = true;
    } finally {
      if (run.complete) run.forgetUnlisted();
      if (run.badChanged) run.bad.save(repo);
      run.badSnaps.save(repo);
    }

    // 4. Ack what was applied.
    final now = _now();
    var acked = false;
    final acks = {
      for (final d in peers)
        if (run.cur(d) > 0 && run.cur(d) <= state.devices[d]!.last) d: run.cur(d)
    };
    final stored = _map(repo, ackedKey);
    void remember(String as, Map<String, int> m) {
      final had = stored[as] is Map ? (stored[as] as Map).cast<String, Object?>() : <String, Object?>{};
      stored[as] = {
        ...had,
        for (final e in m.entries)
          if (e.value > ((had[e.key] as int?) ?? 0)) e.key: e.value,
      };
    }

    try {
      await transport.ack(stream, acks);
      acked = true;
      remember(stream, acks);
      for (final old in ownOld) {
        final m = {
          for (final e in acks.entries)
            if (e.key != old) e.key: e.value,
          if (myLast > 0) stream: myLast,
        };
        await transport.ack(old, m);
        remember(old, m);
      }
    } on TransportException catch (e) {
      logEvent(_log, Level.WARNING, 'sync.ack.failed', {'failure': e.failure.name});
    }
    _setMap(repo, ackedKey, stored);

    // 5. Caught up: match, and maybe write a snapshot.
    final heal = _trackStuck(repo, state, cursors, myLast, now, stream, {...ownOld, stream});
    // deviceIdInUse is information about this install's own stream (already handled), not a file left unread.
    final caughtUp = waiting.isEmpty &&
        problems.every((p) => p.reason == SyncProblemReason.deviceIdInUse) &&
        peers.every((d) => run.cur(d) >= state.devices[d]!.last);
    // Snapshots not used are reported, but a device that applied every file is caught up without them.
    problems.addAll(run.badSnaps.problems.values);
    // Local imports and deletes match at once only while this holds (WalletRepo.syncCaughtUp); otherwise they wait
    // for the next caught-up run, like the ops applied here.
    repo.setLocalValue(WalletRepo.caughtUpKey, caughtUp ? '1' : '0');
    if (caughtUp) {
      try {
        repo.runPendingMatch();
      } on ClockBehindException catch (e, st) {
        // Never from the internal write paths it uses; kept so a run can never fail on the device clock. Matching stays
        // pending (match_pending) for the next run.
        logError(_log, 'sync.match.clockBehind', e, st);
      }
      // Ops still waiting for a file that could be stored later (anything but a relay too full for it, 507) keep the
      // snapshot back: it would carry their file references first. Read after applying the peers' files (an op
      // overtaken by one references nothing). A file that does not fit never blocks it (the snapshot is what frees
      // room); its ops and file stay queued, and the snapshot declares it anyway (it is in this device's state).
      final waitingRefs = repo.pendingBlobRefs().where((h) => repo.hasCachedBlob(h) && !blobsStored.contains(h)).toList();
      final heldBlobs = waitingRefs.any((h) => blobFailures[h] != TransportFailure.full);
      // While a file that did not fit waits, this device's state names it where the others (and the relay) may still
      // name another file for that bill: a set from it could let GC drop theirs. The snapshot goes, its set does not.
      final fullHeld = waitingRefs.any((h) => blobFailures[h] == TransportFailure.full);
      await _maybeSnapshot(repo, state, cursors, myLast, now, heal: heal, heldBlobs: heldBlobs, declare: !fullHeld);
    } else {
      logEvent(_log, Level.INFO, 'sync.match.waiting', {'waiting': waiting.length, 'bad': problems.length});
    }

    final fresh = problems.where((p) => p.isNew).length;
    if (problems.isNotEmpty) {
      logEvent(_log, fresh > 0 ? Level.WARNING : Level.INFO, 'sync.files.skipped', {'bad': problems.length, 'new': fresh});
    }
    // One entry per device id, however many streams it has (lastSeen = the newest of them).
    final seenById = <String, DateTime?>{};
    for (final MapEntry(key: d, value: dev) in state.devices.entries) {
      final b = streamBase(d), was = seenById[b], seen = dev.lastSeen;
      seenById[b] = was == null || (seen != null && seen.isAfter(was)) ? seen : was;
    }
    final ids = {...seenById.keys, me}.toList()..sort();
    t.done({
      'devices': peers.length,
      'sent': sent,
      'files': run.filesRead,
      'ops': run.opsRead,
      'changed': run.received,
      'bytes': run.bytesRead,
      'bad': problems.length,
      'known': run.known,
      'waiting': waiting.length,
      'caughtUp': caughtUp,
      'blobsSent': blobsSent,
      'blobsWaiting': repo.queuedBlobs().length,
      'blobsUnsupported': blobsUnsupported,
    });
    return SyncReport(sent, run.received, run.filesRead,
        problems: problems,
        caughtUp: caughtUp,
        waiting: waiting,
        blobsSent: blobsSent,
        blobsWaiting: repo.queuedBlobs().length,
        blobsUnsupported: blobsUnsupported,
        relayInstance: state.instance,
        relayChanged: relayChanged,
        relayBytes: state.bytes,
        relayMaxBytes: state.maxBytes,
        relayApi: state.api,
        devices: [
          for (final d in ids)
            SyncDevice(_short(d), lastSeen: d == me ? (acked || sent > 0 ? now : seenById[d]) : seenById[d], isThis: d == me),
        ]);
  }

  /// Step 2: starts from the relay's snapshot when a file a peer still needs was pruned, or when this device has applied
  /// nothing yet and the snapshot is of this schema or newer. Returns whether one was applied.
  Future<bool> _startFromSnapshot(WalletRepo repo, _ApplyRun run, List<String> peers) async {
    final state = run.state;
    final pruned = peers.any((d) {
      final dev = state.devices[d]!;
      return run.cur(d) < dev.last && run.cur(d) + 1 < dev.first;
    });
    final fresh = run.cursors.isEmpty && peers.any((d) => state.devices[d]!.last > 0);
    final snap = state.snapshot;
    if (snap == null || !(pruned || (fresh && _current(snap)))) return false;
    // A pruned file leaves no choice; otherwise only a snapshot of this schema or newer (else it lacks fields).
    return _useSnapshot(repo, run, usable: pruned ? null : _current);
  }

  /// Applies a snapshot of the relay ([_applySnapshot]) and counts it as one file read. Returns whether one was applied.
  Future<bool> _useSnapshot(WalletRepo repo, _ApplyRun run, {bool Function(RelaySnapshot s)? usable}) async {
    final got = await _applySnapshot(repo, run.state, run.cursors, run.badSnaps, usable: usable);
    if (got == null) return false;
    run
      ..received += got.$1
      ..opsRead += got.$2
      ..bytesRead += got.$3
      ..filesRead += 1;
    return true;
  }

  /// Step 3 for peer [d]: applies its files from its cursor, strictly in order, until one cannot be used.
  Future<_PeerResult> _applyPeer(WalletRepo repo, _ApplyRun run, String d) async {
    final dev = run.state.devices[d]!;
    while (run.cur(d) < dev.last) {
      final seq = run.cur(d) + 1;
      if (seq < dev.first) {
        logEvent(_log, Level.WARNING, 'sync.file.pruned', {'seq': seq});
        return _PeerWaiting(SyncWaiting(_short(d), seq), null);
      }
      final k = BadFile.keyOf(d, '$seq');
      final List<int> bytes;
      try {
        bytes = await transport.get(d, seq);
      } on TransportException catch (e) {
        // Not the file's fault (or not known to be): not quarantined, fetched again next run.
        logEvent(_log, Level.WARNING, 'sync.file.unreadable', {'seq': seq, 'failure': e.failure.name});
        return _PeerWaiting(SyncWaiting(_short(d), seq), SyncProblem(_short(d), SyncProblemReason.unreadable, bytes: 0));
      }
      final was = run.bad.byKey[k];
      if (was != null && !was.retryNow(build, repo.clock.now()) && was.hash == await fileHash(bytes)) {
        run.listed.add(k);
        return _PeerBlocked(SyncWaiting(_short(d), seq, reason: was.reason), was.problem(isNew: false));
      }
      final clocksBefore = _debugClockStats(repo), versionBefore = repo.dataVersion;
      final int changed, count;
      try {
        (changed, count) = await _applyBytes(repo, key, bytes, _fileOps, aadSyncFile(d, seq), repo.clock.now());
      } on _Refused catch (r) {
        assert(run.cur(d) == seq - 1 && repo.dataVersion == versionBefore && repo.clockStats() == clocksBefore,
            'a refused file changes nothing');
        logError(_log, 'sync.file.failed', r.error, r.stack, fields: {'seq': seq, 'reason': r.reason.name, 'bytes': bytes.length});
        run.listed.add(k);
        run.bad.byKey[k] = BadFile(d, '$seq', r.reason, size: bytes.length, hash: await fileHash(bytes), build: build, retryAt: r.retryAt);
        run.badChanged = true;
        return _PeerRefused(SyncWaiting(_short(d), seq, reason: r.reason), SyncProblem(_short(d), r.reason, bytes: bytes.length));
      }
      if (run.bad.byKey.remove(k) != null) run.badChanged = true;
      repo.setSyncCursor(d, seq);
      repo.recordSyncFile(d, seq, count);
      run.applied(d, seq, changed: changed, ops: count, bytes: bytes.length);
      logEvent(_log, Level.FINE, 'sync.file', {'seq': seq, 'bytes': bytes.length, 'ops': count, 'changed': changed});
    }
    return const _PeerApplied();
  }

  /// A file refused for good (quarantined, not one that merely could not be fetched) that a snapshot of this schema or
  /// newer covers (it was readable for the device that wrote it): start from that snapshot, then go on after it.
  /// Otherwise that device would wait for good. Only when no snapshot was used in step 2.
  Future<void> _unblockBySnapshot(WalletRepo repo, _ApplyRun run) async {
    final state = run.state, blocked = run.blocked;
    final refused = {
      for (final MapEntry(key: d, value: (w, _)) in blocked.entries)
        if (w.reason != null) d: w.seq
    };
    bool unblocks(RelaySnapshot s) => _current(s) && refused.entries.any((e) => e.value <= (s.covers[e.key] ?? 0));
    if (![state.snapshot, state.previous].nonNulls.any(unblocks)) return;
    logEvent(_log, Level.INFO, 'sync.snapshot.unblock', {'devices': refused.length});
    if (!await _useSnapshot(repo, run, usable: unblocks)) return;
    for (final d in blocked.keys.toList()) {
      if (run.cur(d) < blocked[d]!.$1.seq) continue;
      blocked.remove(d);
      run.record(d, await _applyPeer(repo, run, d));
    }
  }

  /// [WalletRepo.clockStats] while asserts are on (debug builds and tests), else null: for the "a refused file changes
  /// nothing" check in [_applyPeer].
  static ({int count, String? maxHlc})? _debugClockStats(WalletRepo repo) {
    ({int count, String? maxHlc})? stats;
    assert(() {
      stats = repo.clockStats();
      return true;
    }());
    return stats;
  }

  /// Uploads the bill files waiting for upload plus the cached ones in [refs] (files the ops about to go up reference:
  /// PUT again even when uploaded before, which refreshes their stored time on the relay, P14), skipping those already
  /// in [stored] this run. Each one stored goes into [stored]. A refused or failed one stays queued and the run goes on
  /// with the others; its last failure goes into [failures]. Returns (uploaded, whether one was refused as missing: a
  /// wallet the relay does not know yet, or an older relay without blobs).
  Future<(int, bool)> _uploadBlobs(WalletRepo repo, Set<String> refs, Set<String> stored, Map<String, TransportFailure> failures) async {
    final queue = {...repo.queuedBlobs(), ...repo.cachedOf(refs)}.where((h) => !stored.contains(h)).toList()..sort();
    if (queue.isEmpty) return (0, false);
    var sent = 0, failed = 0;
    var missing = false;
    for (final hash in queue) {
      final sealed = repo.cachedBlob(hash, touch: false);
      if (sealed == null) continue; // evicted meanwhile (only an uploaded one can be)
      try {
        await transport.putBlob(hash, sealed);
        repo.markBlobUploaded(hash);
        stored.add(hash);
        failures.remove(hash);
        sent++;
      } on TransportException catch (e) {
        failed++;
        failures[hash] = e.failure;
        if (e.failure == TransportFailure.missing) missing = true;
        logEvent(_log, Level.WARNING, 'sync.blob.failed', {'failure': e.failure.name});
      }
    }
    logEvent(_log, Level.INFO, 'sync.blobs', {'sent': sent, 'failed': failed, 'queued': queue.length});
    return (sent, missing);
  }

  /// The files the schema-15 migration listed for one more upload ([WalletRepo.blobReuploadKey], a JSON list of
  /// hashes), null when none are left. An unreadable value lists every cached file of a live bill.
  static List<String>? _reuploadList(WalletRepo repo) {
    final v = repo.localValue(WalletRepo.blobReuploadKey);
    if (v == null) return null;
    try {
      final j = jsonDecode(v);
      if (j is List) {
        return [
          for (final h in j)
            if (h is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) h
        ];
      }
    } on FormatException catch (e, st) {
      logError(_log, 'sync.blobs.reuploadList', e, st, level: Level.WARNING);
    }
    return repo.cachedOf(repo.liveBlobHashes());
  }

  /// The bill fields that reference a file (RELAY_PROTOCOL.md "Client rules for blobs"): they wait for it.
  static const _blobFields = {'blob', 'blob_type', 'blob_bytes', 'deleted'};

  /// Splits [ops] into (to send, held back): an op that references a file this device holds and that was not stored on
  /// the relay in this run ([stored]) keeps its file fields ([_blobFields]) back, same clock; its other fields go.
  /// [holdNone] (a relay without blob storage) holds nothing.
  static (List<Op>, List<Op>) _holdForBlobs(WalletRepo repo, List<Op> ops, Set<String> stored, {required bool holdNone}) {
    if (holdNone) return (ops, const []);
    final send = <Op>[], held = <Op>[];
    for (final op in ops) {
      final ref = repo.blobRefOf(op);
      if (ref == null || stored.contains(ref) || !repo.hasCachedBlob(ref)) {
        send.add(op);
        continue;
      }
      final keep = {
        for (final e in op.fields.entries)
          if (_blobFields.contains(e.key)) e.key: e.value
      };
      final rest = {
        for (final e in op.fields.entries)
          if (!_blobFields.contains(e.key)) e.key: e.value
      };
      held.add(Op(op.entity, op.id, keep, op.hlc));
      if (rest.isNotEmpty) send.add(Op(op.entity, op.id, rest, op.hlc));
    }
    return (send, held);
  }

  /// Uploads this device's next file (several when over [partBytes]) to its stream, after moving to a fresh stream
  /// when the current one may not be this install's alone ([streamKey], [_move]). Returns (ops sent, this stream's last
  /// seq on the relay after it, the [SyncProblemReason.deviceIdInUse] problem when it moved because another install
  /// writes with this id: informational, the run goes on and the problem heals itself).
  /// Ops that reference a file not stored in this run wait in the outbox ([_holdForBlobs]; [stored], [holdNone]).
  Future<(int, int, SyncProblem?)> _upload(WalletRepo repo, RelayState state,
      {required bool relayChanged, required Set<String> stored, required bool holdNone, bool moved = false}) async {
    SyncProblem? inUse;
    SyncProblem foreign(int bytes) => SyncProblem(_short(repo.deviceId), SyncProblemReason.deviceIdInUse, bytes: bytes);
    var me = _streamOf(repo);
    var relayLast = state.devices[me]?.last ?? 0;
    var marker = int.tryParse(repo.localValue(sentKey) ?? '');
    if (marker != null && relayLast < marker) {
      // The relay lost files of this stream (a restored copy, a wiped relay): never reuse a seq with other content.
      me = _move(repo, state, shared: false, reason: 'behind');
    } else if (relayLast > (marker ?? 0)) {
      // More files than this install stored: its own cut-off upload only if every extra seq holds a part it recorded
      // ([sendingKey], checked by hash); else another install writes here (a copied database or key store, or this
      // database restored from an older copy). Leave it to them and read it as a peer.
      final own = await _ownCutOff(repo, me, marker ?? 0, relayLast);
      if (own == null) return (0, relayLast, null); // could not check now: nothing sent, checked again next run
      if (!own) {
        me = _move(repo, state, shared: !relayChanged, reason: relayChanged ? 'relay' : 'foreign');
        if (!relayChanged) inUse = foreign(0);
      }
    }
    relayLast = state.devices[me]?.last ?? 0;
    marker = int.tryParse(repo.localValue(sentKey) ?? '');
    final first = marker == null || relayChanged;
    final pending = repo.pendingOps();
    final (ops, held) = _holdForBlobs(repo, first ? repo.snapshotOps() : [for (final (_, op) in pending) op], stored, holdNone: holdNone);
    if (held.isNotEmpty) logEvent(_log, Level.INFO, 'sync.export.held', {'ops': held.length});
    if (ops.isEmpty) {
      if (first) {
        repo.setLocalValue(sentKey, '$relayLast');
        repo.setLocalValue(sinceKey, repo.localValue(sinceKey) ?? '${_now().millisecondsSinceEpoch}');
        repo.markExportedHolding(pending.isEmpty ? null : pending.last.$1, held);
        logEvent(_log, Level.INFO, 'sync.connect', {'ops': 0, 'relayLast': relayLast});
      } else {
        logEvent(_log, Level.FINE, 'sync.export.none');
      }
      _keepInstance(repo, state);
      return (0, relayLast, inUse);
    }
    final t = PerfTimer('sync.export', warnMs: 500);
    final written = _list(repo, streamsKey);
    if (!written.contains(me)) _setList(repo, streamsKey, [...written, me]);
    // One file per [partBytes] at most (the relay refuses files over 16 MiB): split by op count, sealed size
    // measured, halved while over. The outbox and [sentKey] change only once every part is stored, so a run that stops
    // half-way sends everything again next time (ops are idempotent: a clock is only taken when newer).
    var seq = relayLast, done = 0, size = ops.length, jsonBytes = 0, bytes = 0;
    final parts = <String, Object?>{};
    while (done < ops.length) {
      var count = min(size, ops.length - done);
      List<int> payload, sealed;
      while (true) {
        payload = _filePayload(ops.sublist(done, done + count));
        sealed = await seal(payload, key, aad: aadSyncFile(me, seq + 1));
        if (sealed.length <= partBytes || count == 1) break;
        count = (count + 1) ~/ 2;
      }
      parts['${seq + 1}'] = await fileHash(sealed);
      repo.setLocalValue(sendingKey, jsonEncode({'from': relayLast, 'parts': parts}));
      try {
        await transport.put(me, seq + 1, sealed);
      } on TransportException catch (e) {
        if (e.failure == TransportFailure.conflict) {
          // Other bytes under this stream's next seq, stored since `state`: another install writes here. Move to a
          // fresh stream and send the whole state there (once per run); the outbox is kept until it is stored.
          logEvent(_log, Level.WARNING, 'sync.export.conflict', {'seq': seq + 1, 'failure': e.failure.name});
          repo.setLocalValue(sendingKey, null);
          if (moved) return (0, seq, foreign(sealed.length));
          _move(repo, state, shared: true, reason: 'conflict');
          final (n, last, _) = await _upload(repo, state, relayChanged: relayChanged, stored: stored, holdNone: holdNone, moved: true);
          return (n, last, foreign(sealed.length));
        }
        if (e.failure == TransportFailure.rejected) {
          // A gap (the relay moved on since `state`): kept, sent on the next run.
          logEvent(_log, Level.WARNING, 'sync.export.conflict', {'seq': seq + 1, 'failure': e.failure.name});
          return (0, seq, inUse);
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
    repo.markExportedHolding(pending.isEmpty ? null : pending.last.$1, held);
    repo.setLocalValue(sentKey, '$seq');
    repo.setLocalValue(sendingKey, null);
    if (first) {
      repo.setLocalValue(sinceKey, repo.localValue(sinceKey) ?? '${_now().millisecondsSinceEpoch}');
      logEvent(_log, Level.INFO, 'sync.connect', {'ops': ops.length, 'relayLast': relayLast});
    }
    _keepInstance(repo, state);
    t.done({'ops': ops.length, 'seq': seq, 'files': seq - relayLast, 'jsonBytes': jsonBytes, 'bytes': bytes, 'whole': first});
    return (ops.length, seq, inUse);
  }

  /// Whether seqs `marker + 1 .. relayLast` of this install's stream [me] are its own cut-off upload: each recorded in
  /// [sendingKey] and its stored bytes hash to the recorded part. Null when one could not be fetched (checked again on
  /// the next run).
  Future<bool?> _ownCutOff(WalletRepo repo, String me, int marker, int relayLast) async {
    final sending = _map(repo, sendingKey);
    final parts = sending['parts'], from = sending['from'];
    if (parts is! Map || from is! int) return false;
    for (var q = max(marker, from) + 1; q <= relayLast; q++) {
      final want = parts['$q'];
      if (want is! String) return false;
      try {
        if (await fileHash(await transport.get(me, q)) != want) return false;
      } on TransportException catch (e) {
        logEvent(_log, Level.WARNING, 'sync.stream.checkFailed', {'seq': q, 'failure': e.failure.name});
        return null;
      }
    }
    return true;
  }

  /// Stores the relay's instance id once an upload went through completely (a first connect that stopped half-way is
  /// a first connect again next run). An older relay without one leaves the stored id as it is.
  static void _keepInstance(WalletRepo repo, RelayState state) {
    final id = state.instance;
    if (id != null && repo.localValue(instanceKey) != id) repo.setLocalValue(instanceKey, id);
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
      if (bad.skip(s.id, build, now, repo.clock.now())) {
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
        (changed, count) = await _applyBytes(
            repo, key, bytes, (c) => backupPayloadOps(c, event: 'sync.snapshot.damaged'), aadSnapshot(s.id), repo.clock.now());
      } on _Refused catch (r) {
        logError(_log, 'sync.snapshot.failed', r.error, r.stack, fields: {'which': which, 'reason': r.reason.name, 'bytes': bytes.length});
        bad.refused(s.id, r.reason, bytes.length, await fileHash(bytes), build, now, retryAt: r.retryAt);
        continue;
      }
      bad.applied(s.id);
      var raised = 0;
      for (final MapEntry(key: d, value: seq) in s.covers.entries) {
        if (d == _streamOf(repo) || seq <= (cursors[d] ?? 0)) continue;
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
  bool _trackStuck(WalletRepo repo, RelayState state, Map<String, int> cursors, int myLast, DateTime now, String me, Set<String> mine) {
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
      // The streams this install acks as are its own.
      if (mine.contains(p) || seen == null || now.difference(seen) > stuckAfter) continue;
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
      {bool heal = false, bool heldBlobs = false, bool declare = true}) async {
    final me = _streamOf(repo);
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
    // A snapshot holds the whole state, file references included: none while an op still waits for a file that can be
    // stored later (P14 upload before ops; [heldBlobs], see `_run`), or a device starting from it could point at a file
    // the relay does not have yet. A file the relay is too full for does not hold it back: the snapshot frees room.
    if (heldBlobs) {
      logEvent(_log, Level.INFO, 'sync.snapshot.skipped', {'reason': 'heldBlobs'});
      return;
    }
    final t = PerfTimer('sync.snapshot.write', warnMs: 2000);
    final ops = repo.snapshotOps();
    // The files this snapshot's live bills point to, read with the same database state as [ops] (P14).
    final declared = repo.liveBlobHashes();
    final id = _snapshotId(now);
    final sealed = await seal(backupPayload(ops), key, aad: aadSnapshot(id));
    try {
      await transport.putSnapshot(id, covers, sealed);
    } on TransportException catch (e) {
      logEvent(_log, Level.WARNING, 'sync.snapshot.refused', {'failure': e.failure.name});
      return;
    }
    if ((state.api ?? 0) >= 4 && !declare) {
      logEvent(_log, Level.INFO, 'sync.snapshot.blobs.skipped', {'reason': 'fullHeld'});
    } else if ((state.api ?? 0) >= 4) {
      // Not retried: a snapshot without a set only holds the relay's blob GC back.
      try {
        await transport.putSnapshotBlobs(id, declared);
        logEvent(_log, Level.INFO, 'sync.snapshot.blobs', {'files': declared.length});
      } on TransportException catch (e) {
        logEvent(_log, Level.WARNING, 'sync.snapshot.blobsFailed', {'failure': e.failure.name});
      }
    }
    repo.forgetSyncFiles(covers);
    if (heal) repo.setLocalValue(healKey, '${now.millisecondsSinceEpoch}');
    t.done({'ops': ops.length, 'bytes': sealed.length, 'devices': covers.length, 'behind': behind, 'aged': aged, 'heal': heal});
  }
}

/// How one peer's apply pass ([SyncEngine._applyPeer]) ended.
sealed class _PeerResult {
  const _PeerResult();
}

/// Every file the relay lists for the peer is applied.
final class _PeerApplied extends _PeerResult {
  const _PeerApplied();
}

/// Stopped at file `waiting.seq`; that device's later files wait for it. [problem] is what the run reports (none for a
/// pruned file with no snapshot to start from).
sealed class _PeerStopped extends _PeerResult {
  final SyncWaiting waiting;
  final SyncProblem? problem;
  const _PeerStopped(this.waiting, this.problem);
}

/// The file is not there to read: pruned, or it could not be fetched (not quarantined, fetched again next run).
final class _PeerWaiting extends _PeerStopped {
  const _PeerWaiting(super.waiting, super.problem);
}

/// The file was refused in this run and is now quarantined in [BadFiles]; it changed nothing.
final class _PeerRefused extends _PeerStopped {
  const _PeerRefused(super.waiting, SyncProblem super.problem);
}

/// The file is quarantined from an earlier run, with the same bytes and not due for a retry.
final class _PeerBlocked extends _PeerStopped {
  const _PeerBlocked(super.waiting, SyncProblem super.problem);
}

/// The state of one run's apply phase (steps 2 and 3 of [SyncEngine]): cursors, quarantine records, what stopped each
/// peer, and the counts the report and the run log carry.
class _ApplyRun {
  final RelayState state;

  /// Device → last applied seq, kept equal to [WalletRepo.syncCursors] (a snapshot raises them).
  final Map<String, int> cursors;
  final BadFiles bad;
  final _BadSnapshots badSnaps;

  /// Quarantine keys still current this run (a file some device waits on); the others are forgotten after a complete
  /// pass ([forgetUnlisted]).
  final listed = <String>{};

  /// Per device that stopped: what it waits on, and the problem to report (none when a pruned file has no snapshot).
  final blocked = <String, (SyncWaiting, SyncProblem?)>{};
  var received = 0, filesRead = 0, opsRead = 0, bytesRead = 0, known = 0;
  var badChanged = false;

  /// Every peer was tried and the waiting list built: only then are quarantine records forgotten.
  var complete = false;

  _ApplyRun(this.state, this.cursors, this.bad, this.badSnaps);

  int cur(String d) => cursors[d] ?? 0;

  /// [d]'s file [seq] was applied: [changed] fields, [ops] ops, [bytes] long.
  void applied(String d, int seq, {required int changed, required int ops, required int bytes}) {
    assert(seq == cur(d) + 1, 'files apply strictly in order per device');
    cursors[d] = seq;
    received += changed;
    filesRead++;
    opsRead += ops;
    bytesRead += bytes;
  }

  /// Notes where [d]'s pass ended.
  void record(String d, _PeerResult r) {
    if (r case _PeerStopped(:final waiting, :final problem)) {
      blocked[d] = (waiting, problem);
      if (r is _PeerBlocked) known++;
    }
  }

  /// Forgets the records of files that are no longer the one a device waits on (applied, or older bookkeeping) and of
  /// snapshots the relay no longer lists. Only after a complete pass: one that stopped early has not listed them all.
  void forgetUnlisted() {
    assert(complete, 'forget only after a complete pass');
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
    assert(blocked.entries.every((e) => e.value.$1.reason == null || bad.byKey.containsKey(BadFile.keyOf(e.key, '${e.value.$1.seq}'))),
        'a file refused for good keeps its quarantine record');
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

  /// Whether [id] is skipped in this run (and then listed in [problems] as known). [wallMs] is this device's wall
  /// clock (the one its HLC uses) for a [SyncProblemReason.clockDrift] record.
  bool skip(String id, String build, DateTime now, int wallMs) {
    final r = _byId[id];
    if (r == null) return false;
    final reason = _reason(r);
    final at = r['at'] is int ? r['at'] as int : 0;
    final skipped = switch (reason) {
      null => now.difference(DateTime.fromMillisecondsSinceEpoch(at, isUtc: true)) < SyncEngine.snapshotRetry,
      SyncProblemReason.unknownVersion || SyncProblemReason.applyFailed => r['build'] == build,
      SyncProblemReason.clockDrift => r['build'] == build && (r['retryAt'] is! int || wallMs < (r['retryAt'] as int)),
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

  void refused(String id, SyncProblemReason reason, int bytes, String hash, String build, DateTime now, {int? retryAt}) {
    _byId[id] = {
      'reason': reason.name,
      'bytes': bytes,
      'hash': hash,
      'build': build,
      'at': now.millisecondsSinceEpoch,
      if (retryAt != null) 'retryAt': retryAt,
    };
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
