import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'signing.dart';

/// The protocol version this relay speaks (`api` in health and state). 3: requests sign the host (`bw-relay-v3`), state
/// carries `instance`. 4: `bw-relay-v4` (v3 still accepted), blob DELETE is a no-op, declared sets and blob GC.
const int apiVersion = 4;

/// A blob stored (or re-uploaded) more recently than this is never collected.
const Duration gcGrace = Duration(days: 30);

/// Most hashes one declared set may hold.
const int maxDeclaredBlobs = 100000;

/// A declared set ([Snap.blobSet]) from its stored or sent JSON: a list of distinct blob hashes, at most
/// [maxDeclaredBlobs]; null when it is not one.
Set<String>? parseBlobSet(List<int> bytes) {
  final Object? v;
  try {
    v = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (v is! List || v.length > maxDeclaredBlobs) return null;
  final out = <String>{};
  for (final h in v) {
    if (h is! String || !blobHashPattern.hasMatch(h) || !out.add(h)) return null;
  }
  return out;
}

/// The stored form of a declared set: sorted JSON array.
List<int> encodeBlobSet(Set<String> set) => utf8.encode(jsonEncode(set.toList()..sort()));

/// Test seams for fault injection (tests only; production passes none), `Relay(hooks: ...)`. A throw from a callback
/// acts like a crash or a full disk at that point: the request fails with 500 and what was already written stays.
class RelayTestHooks {
  const RelayTestHooks({this.afterFileWrite, this.beforeMetaSave});

  /// After sync file [seq] of [device] in wallet [wid] was written, before the meta is saved.
  final FutureOr<void> Function(String wid, String device, int seq)? afterFileWrite;

  /// Before `meta.json` of wallet [wid] is written by a request (not by a load).
  final FutureOr<void> Function(String wid)? beforeMetaSave;
}

/// A new relay instance id: 32 random hex characters.
String newInstanceId() {
  final r = math.Random.secure();
  return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

final RegExp _instancePattern = RegExp(r'^[0-9a-f]{32}$');

/// Names accepted on the wire (docs/context/RELAY_PROTOCOL.md, "Names").
final RegExp widPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp namePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// A blob name: lowercase hex SHA-256 of the sealed bytes.
final RegExp blobHashPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _seqPattern = RegExp(r'^[1-9][0-9]{0,15}$');

/// Highest sequence number: 2^53 - 1 (what a JS client can count to).
const int maxSeq = 9007199254740991;

/// Parses a decimal `seq` (no leading zeros, 1 ... 2^53 - 1); null when invalid.
int? parseSeq(String s) {
  if (!_seqPattern.hasMatch(s)) return null;
  final n = int.parse(s);
  return n <= maxSeq ? n : null;
}

/// A device that has not been seen for this long no longer holds back pruning.
const Duration deviceMemory = Duration(days: 90);

/// Constant-time comparison of two strings.
bool constantTimeEquals(String a, String b) {
  var diff = a.length ^ b.length;
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// `2026-10-22T10:00:00Z` (whole seconds).
String formatTime(DateTime t) {
  final u = t.toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(u.year, 4)}-${p(u.month)}-${p(u.day)}T${p(u.hour)}:${p(u.minute)}:${p(u.second)}Z';
}

int _counter = 0;

/// Writes [bytes] to [target] through a temp file in the same folder, then renames it over [target].
Future<void> writeAtomic(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.parent.path}/.tmp-$pid-${_counter++}');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(target.path);
}

/// One device's files on the relay.
class DeviceState {
  DeviceState(this.lastSeen);

  /// Lowest seq still stored, or `last + 1` when all were pruned.
  int first = 1;
  int last = 0;
  DateTime lastSeen;
  final Map<String, int> acks = {};
}

/// A kept snapshot: id, what it covers and its size on disk.
class Snap {
  Snap(this.id, this.covers, this.size);

  final String id;
  final Map<String, int> covers;
  final int size;

  /// The blob hashes this snapshot's live bills reference (`PUT snapshot/<id>/blobs`, stored in `sets/<id>`); null
  /// until declared (an api-3 app never declares one), which holds blob GC back.
  Set<String>? blobSet;

  Map<String, Object?> toJson() => {'id': id, 'covers': covers};
}

/// One wallet: its public signing key, devices, snapshots and the byte total, rebuilt from its folder on start.
class Wallet {
  Wallet(this.wid, this.dir, this.pub, {String? instance, this.hooks})
      : pubBytes = decodeBase64Url(pub, 32)!,
        instance = instance ?? newInstanceId();

  /// This store's id for the wallet (`instance` in state, kept in `meta.json`): random when the wallet is created (or
  /// first loaded by a relay that did not have one), so a wiped or replaced data folder names another one.
  final String instance;

  /// Fault injection for tests ([RelayTestHooks]).
  final RelayTestHooks? hooks;

  final String wid;
  final Directory dir;

  /// Ed25519 public key (base64url, no padding) set by the request that created the wallet: verifies every request.
  final String pub;
  final Uint8List pubBytes;
  final Map<String, DeviceState> devices = {};
  Snap? snapshot;
  Snap? previous;

  /// Bytes in sealed files and kept snapshots (blobs are counted apart: [blobBytes]).
  int bytes = 0;

  /// Stored blobs (`blobs/<hash>`): how many and their total size.
  int blobCount = 0;
  int blobBytes = 0;

  /// What `--max-bytes` limits: files + kept snapshots + blobs.
  int get totalBytes => bytes + blobBytes;

  File get metaFile => File('${dir.path}/meta.json');
  File dataFile(String device, int seq) => File('${dir.path}/d/$device/$seq');
  File snapFile(String id) => File('${dir.path}/snap/$id');
  File blobFile(String hash) => File('${dir.path}/blobs/$hash');
  File setFile(String id) => File('${dir.path}/sets/$id');

  /// Blob GC (RELAY_PROTOCOL.md "Blob garbage collection"): when both kept snapshots carry a declared set, deletes every
  /// blob in neither set whose stored time (file modification time) is more than [gcGrace] before [now]. Returns
  /// (kept, deleted, bytes deleted); null when it did not run.
  Future<(int, int, int)?> collectBlobs(DateTime now) async {
    final a = snapshot?.blobSet, b = previous?.blobSet;
    if (a == null || b == null) return null;
    final dBlobs = Directory('${dir.path}/blobs');
    if (!await dBlobs.exists()) return (0, 0, 0);
    final cutoff = now.subtract(gcGrace);
    var kept = 0, deleted = 0, freed = 0;
    await for (final f in dBlobs.list(followLinks: false)) {
      if (f is! File) continue;
      final hash = f.uri.pathSegments.last;
      if (!blobHashPattern.hasMatch(hash)) continue;
      try {
        if (a.contains(hash) || b.contains(hash) || !(await f.lastModified()).isBefore(cutoff)) {
          kept++;
          continue;
        }
        final size = await f.length();
        await f.delete();
        blobCount--;
        blobBytes -= size;
        deleted++;
        freed += size;
      } on FileSystemException {
        // gone meanwhile: counted when the folder is read again
      }
    }
    return (kept, deleted, freed);
  }

  /// The state JSON (RELAY_PROTOCOL.md "State JSON"); [maxBytes] is the relay's `--max-bytes`, reported with [totalBytes].
  /// [api] is 3 for a request signed with the api-3 text.
  Map<String, Object?> stateJson({required int maxBytes, int api = apiVersion}) {
    final names = devices.keys.toList()..sort();
    return {
      'api': api,
      'instance': instance,
      'devices': {
        for (final n in names)
          n: {
            'first': devices[n]!.first,
            'last': devices[n]!.last,
            'lastSeen': formatTime(devices[n]!.lastSeen),
            'acks': {for (final k in (devices[n]!.acks.keys.toList()..sort())) k: devices[n]!.acks[k]},
          },
      },
      'snapshot': snapshot?.toJson(),
      'previous': previous?.toJson(),
      'blobs': {'count': blobCount, 'bytes': blobBytes},
      'bytes': totalBytes,
      'maxBytes': maxBytes,
    };
  }

  /// Writes sync file [seq] of [device] ([writeAtomic]), then calls [RelayTestHooks.afterFileWrite].
  Future<void> writeData(String device, int seq, List<int> bytes) async {
    await writeAtomic(dataFile(device, seq), bytes);
    await hooks?.afterFileWrite?.call(wid, device, seq);
  }

  /// Writes `meta.json` (temp + rename). [RelayTestHooks.beforeMetaSave] runs first unless [load] (the save of a load).
  Future<void> saveMeta({bool load = false}) async {
    if (!load) await hooks?.beforeMetaSave?.call(wid);
    final meta = {
      'v': 2,
      'pub': pub,
      'instance': instance,
      'devices': {
        for (final e in devices.entries) e.key: {'last': e.value.last, 'lastSeen': formatTime(e.value.lastSeen), 'acks': e.value.acks},
      },
      'snapshot': snapshot?.toJson(),
      'previous': previous?.toJson(),
    };
    await writeAtomic(metaFile, utf8.encode(jsonEncode(meta)));
  }

  /// Deletes every file the kept snapshots cover and every device seen within 90 days acked (see RELAY_PROTOCOL.md).
  Future<void> prune(DateTime now) async {
    final kept = [snapshot, previous].whereType<Snap>().toList();
    if (kept.isEmpty) return;
    final cutoff = now.subtract(deviceMemory);
    for (final e in devices.entries) {
      final owner = e.key;
      final st = e.value;
      var limit = st.last;
      for (final s in kept) {
        limit = math.min(limit, s.covers[owner] ?? 0);
      }
      for (final o in devices.entries) {
        if (o.key == owner || o.value.lastSeen.isBefore(cutoff)) continue;
        limit = math.min(limit, o.value.acks[owner] ?? 0);
      }
      while (st.first <= limit) {
        final f = dataFile(owner, st.first);
        try {
          bytes -= await f.length();
          await f.delete();
        } on FileSystemException {
          // already gone
        }
        st.first++;
      }
    }
  }

  /// Rebuilds a wallet from [dir]; null when `meta.json` is missing or unreadable.
  /// Files win over the meta for `last` (a crash between writing a file and the meta), unknown files are cleaned up.
  static Future<Wallet?> load(Directory dir, String wid, DateTime now, {RelayTestHooks? hooks}) async {
    final Map<String, Object?> meta;
    try {
      final decoded = jsonDecode(await File('${dir.path}/meta.json').readAsString());
      if (decoded is! Map<String, Object?>) return null;
      meta = decoded;
    } on Object {
      return null;
    }
    final pub = meta['pub'];
    if (pub is! String || decodeBase64Url(pub, 32) == null) return null; // a v1 meta (token hash) is not a wallet any more
    final stored = meta['instance'];
    final hadInstance = stored is String && _instancePattern.hasMatch(stored);
    final w = Wallet(wid, dir, pub, instance: hadInstance ? stored : null, hooks: hooks);
    final devs = meta['devices'];
    if (devs is Map<String, Object?>) {
      for (final e in devs.entries) {
        final v = e.value;
        if (!namePattern.hasMatch(e.key) || v is! Map<String, Object?>) continue;
        final seen = v['lastSeen'];
        final st = DeviceState((seen is String ? DateTime.tryParse(seen) : null) ?? now);
        final last = v['last'];
        if (last is int && last >= 0) st.last = last;
        final acks = v['acks'];
        if (acks is Map<String, Object?>) {
          for (final a in acks.entries) {
            final n = a.value;
            if (namePattern.hasMatch(a.key) && n is int && n >= 0) st.acks[a.key] = n;
          }
        }
        w.devices[e.key] = st;
      }
    }
    final dData = Directory('${dir.path}/d');
    if (await dData.exists()) {
      await for (final ent in dData.list(followLinks: false)) {
        if (ent is! Directory) continue;
        final name = ent.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (!namePattern.hasMatch(name)) continue;
        final seqs = <int>[];
        await for (final f in ent.list(followLinks: false)) {
          if (f is! File) continue;
          final base = f.uri.pathSegments.last;
          final seq = parseSeq(base);
          if (seq == null) {
            await f.delete(); // temp file of an interrupted write
            continue;
          }
          seqs.add(seq);
          w.bytes += await f.length();
        }
        if (seqs.isEmpty) continue;
        seqs.sort();
        final st = w.devices.putIfAbsent(name, () => DeviceState(now));
        st.last = math.max(st.last, seqs.last);
        st.first = seqs.first;
      }
    }
    for (final st in w.devices.values) {
      if (st.first > st.last + 1) st.first = st.last + 1;
    }
    // Devices without files: everything up to `last` was pruned.
    for (final e in w.devices.entries) {
      final f = w.dataFile(e.key, e.value.last);
      if (e.value.last > 0 && !await f.exists()) e.value.first = e.value.last + 1;
    }
    final keep = <String>{};
    Future<Snap?> snap(Object? raw) async {
      if (raw is! Map<String, Object?>) return null;
      final id = raw['id'];
      final covers = raw['covers'];
      if (id is! String || !namePattern.hasMatch(id) || covers is! Map<String, Object?>) return null;
      final f = w.snapFile(id);
      if (!await f.exists()) return null;
      final map = <String, int>{};
      for (final c in covers.entries) {
        final n = c.value;
        if (namePattern.hasMatch(c.key) && n is int && n >= 0) map[c.key] = n;
      }
      final size = await f.length();
      keep.add(id);
      w.bytes += size;
      return Snap(id, map, size);
    }

    w.snapshot = await snap(meta['snapshot']);
    w.previous = await snap(meta['previous']);
    // Declared sets of the kept snapshots; any other set file (a dropped snapshot's, a temp file) goes.
    final dSets = Directory('${dir.path}/sets');
    if (await dSets.exists()) {
      await for (final f in dSets.list(followLinks: false)) {
        if (f is! File) continue;
        final s = [w.snapshot, w.previous].whereType<Snap>().where((s) => s.id == f.uri.pathSegments.last).firstOrNull;
        if (s == null) {
          await f.delete();
          continue;
        }
        try {
          s.blobSet = parseBlobSet(await f.readAsBytes()); // unreadable = no set: GC waits
        } on FileSystemException {
          s.blobSet = null;
        }
      }
    }
    // Temp files of an interrupted meta save ([writeAtomic] next to `meta.json`).
    await for (final f in dir.list(followLinks: false)) {
      if (f is File && f.uri.pathSegments.last.startsWith('.tmp-')) await f.delete();
    }
    final dSnap = Directory('${dir.path}/snap');
    if (await dSnap.exists()) {
      await for (final f in dSnap.list(followLinks: false)) {
        if (f is File && !keep.contains(f.uri.pathSegments.last)) await f.delete();
      }
    }
    final dBlobs = Directory('${dir.path}/blobs');
    if (await dBlobs.exists()) {
      await for (final f in dBlobs.list(followLinks: false)) {
        if (f is! File) continue;
        if (!blobHashPattern.hasMatch(f.uri.pathSegments.last)) {
          await f.delete(); // temp file of an interrupted write
          continue;
        }
        w.blobCount++;
        w.blobBytes += await f.length();
      }
    }
    // A meta from before instance ids: the new id is kept at once, so a restart before the next write names the same.
    if (!hadInstance) await w.saveMeta(load: true);
    return w;
  }
}
