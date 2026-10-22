import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography/dart.dart';

/// Names accepted on the wire (docs/context/RELAY_PROTOCOL.md, "Names").
final RegExp widPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp namePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
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

/// SHA-256 of [s] (UTF-8) as lowercase hex.
String sha256Hex(String s) {
  final h = const DartSha256().hashSync(utf8.encode(s));
  return [for (final b in h.bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

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

  Map<String, Object?> toJson() => {'id': id, 'covers': covers};
}

/// One wallet: auth hash, devices, snapshots and the byte total, rebuilt from its folder on start.
class Wallet {
  Wallet(this.wid, this.dir, this.tokenHash);

  final String wid;
  final Directory dir;
  final String tokenHash;
  final Map<String, DeviceState> devices = {};
  Snap? snapshot;
  Snap? previous;

  /// Bytes in sealed files and kept snapshots.
  int bytes = 0;

  File get metaFile => File('${dir.path}/meta.json');
  File dataFile(String device, int seq) => File('${dir.path}/d/$device/$seq');
  File snapFile(String id) => File('${dir.path}/snap/$id');

  Map<String, Object?> stateJson() {
    final names = devices.keys.toList()..sort();
    return {
      'api': 1,
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
    };
  }

  Future<void> saveMeta() async {
    final meta = {
      'v': 1,
      'tokenHash': tokenHash,
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
  static Future<Wallet?> load(Directory dir, String wid, DateTime now) async {
    final Map<String, Object?> meta;
    try {
      final decoded = jsonDecode(await File('${dir.path}/meta.json').readAsString());
      if (decoded is! Map<String, Object?>) return null;
      meta = decoded;
    } on Object {
      return null;
    }
    final hash = meta['tokenHash'];
    if (hash is! String || hash.isEmpty) return null;
    final w = Wallet(wid, dir, hash);
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
    final dSnap = Directory('${dir.path}/snap');
    if (await dSnap.exists()) {
      await for (final f in dSnap.list(followLinks: false)) {
        if (f is File && !keep.contains(f.uri.pathSegments.last)) await f.delete();
      }
    }
    return w;
  }
}
