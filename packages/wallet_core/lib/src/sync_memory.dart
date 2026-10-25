// In-memory relay for tests and the web smoke check: the same rules as `relay/` (docs/context/RELAY_PROTOCOL.md).
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'bills.dart' show sha256Hex;
import 'sync_engine.dart';

class _Dev {
  int first = 1, last = 0;
  DateTime? lastSeen;
  final Map<String, int> acks = {};
  final Map<int, Uint8List> files = {};
}

class _Snap {
  final String id;
  final Map<String, int> covers;
  final Uint8List bytes;

  /// The declared blob set (api 4), null until declared.
  Set<String>? blobSet;
  _Snap(this.id, this.covers, this.bytes);
}

/// A relay in memory, with the relay's rules: no gaps (422), stored files never overwritten (409; the same bytes
/// again are fine), acks only grow and never pass a device's `last` (422), a snapshot must dominate the current one
/// (409) and stay within each device's `last` (422), 16 MiB per file and 64 MiB per snapshot (`full`), and pruning
/// after every accepted write: a file goes once every kept snapshot covers it and every other device seen within 90
/// days ([now]) acked it. No signature check (the relay's job): files sealed with another key are stored like any.
///
/// Blobs (bill files) as the relay keeps them: PUT checks the hash (64 lowercase hex = SHA-256 of the body, else
/// `rejected`), needs a known wallet (a stored file, else `missing`) and 16 MiB at most; GET of an absent one is null;
/// clients never delete them (api 4). [api] 4: each kept snapshot may get a declared set
/// ([putSnapshotBlobs]); with both kept snapshots declared, a blob in neither set stored more than [gcGrace] ago is
/// collected, as the relay does. [api] 3: no declared sets (404), no GC.
///
/// Test hooks: [offline], [corrupt], [failGet], [failGetSnapshot], [replace], [files], [maxFileBytes], [blobs],
/// [blobRoutes], [tamperBlob], [api], [declared], [gcRuns].
class MemoryTransport implements SyncTransport {
  MemoryTransport({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  /// This store's relay instance id (`GET state` → `instance`, sent once the wallet exists). Random per transport;
  /// null = an older relay (api 2) that sends none. Tests may set another one ("the relay was replaced").
  String? instance = newInstanceId();

  /// 32 random hex characters, like the relay's `meta.json` instance id.
  static String newInstanceId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Test hook: the relay lost everything (wiped data directory): no devices, files, snapshots or blobs, and a new
  /// [instance] id.
  void wipe() {
    _devs.clear();
    _snap = _prev = null;
    _blobs.clear();
    _blobAt.clear();
    instance = newInstanceId();
  }

  /// Test hook: a copy of everything stored (a backup of the relay's data folder), for [restore].
  Object copy() => (
        {
          for (final MapEntry(key: id, value: d) in _devs.entries)
            id: _Dev()
              ..first = d.first
              ..last = d.last
              ..lastSeen = d.lastSeen
              ..acks.addAll(d.acks)
              ..files.addAll({for (final f in d.files.entries) f.key: Uint8List.fromList(f.value)}),
        },
        _snap,
        _prev,
        Map.of(_blobs),
        instance,
      );

  /// Test hook: the relay restored from an older [copy] (its `instance` id included, as a restored `meta.json` keeps
  /// it). What was stored since is gone.
  void restore(Object copy) {
    final (devs, snap, prev, blobs, inst) = copy as (Map<String, _Dev>, _Snap?, _Snap?, Map<String, Uint8List>, String?);
    _devs
      ..clear()
      ..addAll({
        for (final MapEntry(key: id, value: d) in devs.entries)
          id: _Dev()
            ..first = d.first
            ..last = d.last
            ..lastSeen = d.lastSeen
            ..acks.addAll(d.acks)
            ..files.addAll({for (final f in d.files.entries) f.key: Uint8List.fromList(f.value)}),
      });
    _snap = snap;
    _prev = prev;
    _blobs
      ..clear()
      ..addAll(blobs);
    instance = inst;
  }

  final Map<String, _Dev> _devs = {};
  _Snap? _snap, _prev;
  final Map<(String, int), int> _failGets = {};
  final Map<String, int> _failSnapshotGets = {};
  final Map<String, Uint8List> _blobs = {};
  final Map<String, DateTime> _blobAt = {};

  /// The api version `GET state` names: 4 (declared sets, GC) or 3 (an api-3 relay: blobs, never deleted, no sets).
  int api = 4;

  /// Blob GC grace, as the relay's `GC_GRACE`.
  static const gcGrace = Duration(days: 30);

  /// Declared sets of the kept snapshots, by snapshot id (sorted hashes), for tests.
  Map<String, List<String>> get declared => {
        for (final s in [_snap, _prev].nonNulls)
          if (s.blobSet case final b?) s.id: b.toList()..sort(),
      };

  /// How many times the GC ran (both kept snapshots declared), for tests.
  int gcRuns = 0;

  /// False = an older relay without blobs: every blob call answers 404 ([TransportFailure.missing]).
  bool blobRoutes = true;

  /// Read-only view of the stored blobs by hash.
  Map<String, Uint8List> get blobs => UnmodifiableMapView(_blobs);

  /// Flips one byte of a stored blob (a damaged disk or a hostile relay): its hash no longer matches.
  void tamperBlob(String hash) {
    final b = _blobs[hash];
    if (b == null) throw StateError('no such blob');
    b[b.length ~/ 2] ^= 0xff;
  }

  static const maxFile = 16 << 20, maxSnapshot = 64 << 20;
  static const activeFor = Duration(days: 90);

  /// Largest file a PUT may store ([maxFile] like the relay; lower in tests so a big upload needs few rows).
  int maxFileBytes = maxFile;

  /// The relay's `--max-bytes` as `GET state` reports it (`RelayState.maxBytes`, with `bytes` = files + snapshots +
  /// blobs stored here). Reported only, not enforced. Null = an older relay that sends neither.
  int? maxBytes = 1 << 30;

  /// What the relay's `--max-bytes` counts: stored files, kept snapshots and blobs.
  int get storedBytes {
    var n = 0;
    for (final d in _devs.values) {
      for (final b in d.files.values) {
        n += b.length;
      }
    }
    for (final b in _blobs.values) {
      n += b.length;
    }
    return n + (_snap?.bytes.length ?? 0) + (_prev?.bytes.length ?? 0);
  }

  /// Every call throws [TransportFailure.unreachable] while true.
  bool offline = false;

  /// Calls made, by kind (`state`, `put`, `get`, `ack`, `putSnapshot`, `getSnapshot`), for tests.
  final Map<String, int> calls = {};

  /// Flips every byte of a stored file (as a damaged disk would): no longer a sync file at all, so `corrupt`.
  void corrupt(String device, int seq) {
    final f = _devs[device]?.files[seq];
    if (f == null) throw StateError('no such file');
    for (var i = 0; i < f.length; i++) {
      f[i] ^= 0xff;
    }
  }

  /// The next [times] GETs of that file fail as [TransportFailure.unreachable] (a dropped connection).
  void failGet(String device, int seq, {int times = 1}) => _failGets[(device, seq)] = times;

  /// The next [times] GETs of snapshot [id] fail as [TransportFailure.unreachable].
  void failGetSnapshot(String id, {int times = 1}) => _failSnapshotGets[id] = times;

  /// Replaces a stored file's bytes, which the relay itself never does (a repair made on the server).
  void replace(String device, int seq, List<int> bytes) {
    final d = _devs[device];
    if (d == null || !d.files.containsKey(seq)) throw StateError('no such file');
    d.files[seq] = Uint8List.fromList(bytes);
  }

  /// Read-only view of what is stored: `d/<device>/<seq>` and `snapshot/<id>`.
  Map<String, Uint8List> get files => UnmodifiableMapView({
        for (final MapEntry(key: d, value: dev) in _devs.entries)
          for (final MapEntry(key: s, value: b) in dev.files.entries) 'd/$d/$s': b,
        if (_snap case final s?) 'snapshot/${s.id}': s.bytes,
        if (_prev case final s?) 'snapshot/${s.id}': s.bytes,
      });

  void _call(String kind) {
    calls[kind] = (calls[kind] ?? 0) + 1;
    if (offline) throw const TransportException(TransportFailure.unreachable, 'offline');
  }

  static final _name = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static void _checkName(String s) {
    if (!_name.hasMatch(s)) throw const TransportException(TransportFailure.rejected, 'bad name');
  }

  static void _checkSeq(int seq) {
    if (seq < 1 || seq > 9007199254740991) throw const TransportException(TransportFailure.rejected, 'bad seq');
  }

  @override
  Future<RelayState> state() async {
    _call('state');
    return RelayState(
      devices: {
        for (final MapEntry(key: id, value: d) in _devs.entries)
          id: RelayDevice(first: d.first, last: d.last, lastSeen: d.lastSeen, acks: Map.unmodifiable(d.acks)),
      },
      snapshot: _snap == null ? null : RelaySnapshot(_snap!.id, Map.unmodifiable(_snap!.covers)),
      previous: _prev == null ? null : RelaySnapshot(_prev!.id, Map.unmodifiable(_prev!.covers)),
      instance: _devs.isEmpty ? null : instance,
      bytes: _devs.isEmpty || maxBytes == null ? null : storedBytes,
      maxBytes: _devs.isEmpty ? null : maxBytes,
      api: _devs.isEmpty ? null : api,
    );
  }

  @override
  Future<void> put(String device, int seq, List<int> bytes) async {
    _call('put');
    _checkName(device);
    _checkSeq(seq);
    if (bytes.length > maxFileBytes) throw const TransportException(TransportFailure.full, 'too big');
    // A known device is seen by any PUT that reaches the seq check; a new one appears only once a file is stored.
    final d = _devs[device] ?? _Dev();
    if (_devs.containsKey(device)) d.lastSeen = _now().toUtc();
    if (seq > d.last + 1) throw const TransportException(TransportFailure.rejected, 'gap');
    if (seq < d.first) throw const TransportException(TransportFailure.gone, 'pruned');
    _devs[device] = d;
    d.lastSeen = _now().toUtc();
    final had = d.files[seq];
    if (had != null) {
      if (!_same(had, bytes)) throw const TransportException(TransportFailure.conflict, 'other bytes stored');
      return;
    }
    d.files[seq] = Uint8List.fromList(bytes);
    d.last = seq;
    _prune();
  }

  @override
  Future<List<int>> get(String device, int seq) async {
    _call('get');
    _checkName(device);
    _checkSeq(seq);
    final left = _failGets[(device, seq)];
    if (left != null && left > 0) {
      _failGets[(device, seq)] = left - 1;
      throw const TransportException(TransportFailure.unreachable, 'dropped');
    }
    final d = _devs[device];
    if (d != null && seq < d.first) throw const TransportException(TransportFailure.gone, 'pruned');
    final f = d?.files[seq];
    if (f == null) throw const TransportException(TransportFailure.missing, 'not stored');
    return Uint8List.fromList(f);
  }

  @override
  Future<void> ack(String device, Map<String, int> cursors) async {
    _call('ack');
    _checkName(device);
    for (final MapEntry(key: p, value: s) in cursors.entries) {
      _checkName(p);
      if (s < 0 || s > (_devs[p]?.last ?? 0)) throw const TransportException(TransportFailure.rejected, 'ack beyond last');
    }
    final d = _devs[device] ??= _Dev();
    d.lastSeen = _now().toUtc();
    for (final MapEntry(key: p, value: s) in cursors.entries) {
      if (s > (d.acks[p] ?? 0)) d.acks[p] = s;
    }
    _prune();
  }

  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) async {
    _call('putSnapshot');
    _checkName(id);
    if (bytes.length > maxSnapshot) throw const TransportException(TransportFailure.full, 'too big');
    for (final MapEntry(key: d, value: s) in covers.entries) {
      _checkName(d);
      if (s < 0 || s > (_devs[d]?.last ?? 0)) throw const TransportException(TransportFailure.rejected, 'covers beyond last');
    }
    for (final s in [_snap, _prev]) {
      if (s == null || s.id != id) continue;
      final same = _same(s.bytes, bytes) && s.covers.length == covers.length && covers.entries.every((e) => s.covers[e.key] == e.value);
      if (same) return; // the same snapshot again: 200
      throw const TransportException(TransportFailure.conflict, 'other content under this id');
    }
    for (final MapEntry(key: d, value: s) in (_snap?.covers ?? const <String, int>{}).entries) {
      if ((covers[d] ?? -1) < s) throw const TransportException(TransportFailure.conflict, 'does not dominate');
    }
    _prev = _snap;
    _snap = _Snap(id, Map.of(covers), Uint8List.fromList(bytes));
    _prune();
  }

  @override
  Future<List<int>> getSnapshot(String id) async {
    _call('getSnapshot');
    _checkName(id);
    final left = _failSnapshotGets[id];
    if (left != null && left > 0) {
      _failSnapshotGets[id] = left - 1;
      throw const TransportException(TransportFailure.unreachable, 'dropped');
    }
    for (final s in [_snap, _prev]) {
      if (s != null && s.id == id) return Uint8List.fromList(s.bytes);
    }
    throw const TransportException(TransportFailure.missing, 'no such snapshot');
  }

  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  void _blobCall(String kind, String hash) {
    _call(kind);
    if (!blobRoutes) throw const TransportException(TransportFailure.missing, 'no blob routes');
    if (!_hash.hasMatch(hash)) throw const TransportException(TransportFailure.rejected, 'bad hash');
  }

  @override
  Future<void> putBlob(String hash, List<int> bytes) async {
    _blobCall('putBlob', hash);
    if (_devs.isEmpty) throw const TransportException(TransportFailure.missing, 'unknown wallet');
    if (bytes.length > maxFile) throw const TransportException(TransportFailure.full, 'too big');
    if (sha256Hex(bytes) != hash) throw const TransportException(TransportFailure.rejected, 'hash');
    _blobs[hash] ??= Uint8List.fromList(bytes);
    _blobAt[hash] = _now(); // a re-upload refreshes the stored time
  }

  @override
  Future<List<int>?> getBlob(String hash) async {
    _blobCall('getBlob', hash);
    final b = _blobs[hash];
    return b == null ? null : Uint8List.fromList(b);
  }

  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) async {
    _call('putSnapshotBlobs');
    if (api < 4) throw const TransportException(TransportFailure.missing, 'no declared sets');
    final set = hashes.toSet();
    if (set.length != hashes.length || hashes.length > 100000 || !hashes.every(_hash.hasMatch)) {
      throw const TransportException(TransportFailure.rejected, 'bad blob set');
    }
    final s = [_snap, _prev].nonNulls.where((s) => s.id == id).firstOrNull;
    if (s == null) throw const TransportException(TransportFailure.missing, 'no such snapshot');
    if (s.blobSet case final had?) {
      if (had.length == set.length && had.containsAll(set)) return;
      throw const TransportException(TransportFailure.conflict, 'blob set already declared');
    }
    s.blobSet = set;
    final a = _snap?.blobSet, b = _prev?.blobSet;
    if (a == null || b == null) return;
    gcRuns++;
    final cutoff = _now().subtract(gcGrace);
    for (final h in _blobs.keys.toList()) {
      if (a.contains(h) || b.contains(h) || !(_blobAt[h] ?? _now()).isBefore(cutoff)) continue;
      _blobs.remove(h);
      _blobAt.remove(h);
    }
  }

  /// Deletes every file that every kept snapshot covers and every other device seen within [activeFor] acked.
  void _prune() {
    final kept = [_snap, _prev].nonNulls.toList();
    if (kept.isEmpty) return;
    final now = _now();
    for (final MapEntry(key: id, value: d) in _devs.entries) {
      final readers = [
        for (final MapEntry(key: o, value: od) in _devs.entries)
          if (o != id && od.lastSeen != null && now.difference(od.lastSeen!) <= activeFor) od,
      ];
      while (d.first <= d.last) {
        final seq = d.first;
        if (!kept.every((s) => (s.covers[id] ?? 0) >= seq)) break;
        if (!readers.every((r) => (r.acks[id] ?? 0) >= seq)) break;
        d.files.remove(seq);
        d.first++;
      }
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
