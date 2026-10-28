// V2: device state digests and the "devices disagree" repair. The records travel as ops of reserved kinds inside normal
// sync files; builds before V2 skip them like any unknown kind (Q8). Web-safe: no dart:io.
import 'dart:convert';

import 'package:wallet_core/wallet_core.dart';

final _log = Logger('bw.sync');

/// Reserved op kind of a state digest record: `{"digest": <hex>, "vector": {"<stream>": seq}, "schema": n}`, id = the
/// writer's stream.
const digestKind = '_digest';

/// Reserved op kind of a repair record: `{"ask": bool}`, id = the writer's stream. The data ops of a file holding one
/// are a repair resend and apply with the equal-clock tie-break; `ask` asks every device to resend its state once.
const repairKind = '_repair';

/// Whether [op] is a record ([digestKind], [repairKind]) rather than wallet data.
bool isSyncRecord(Op op) => op.entity == digestKind || op.entity == repairKind;

/// A peer's digest record.
class DigestRecord {
  final String digest;
  final Map<String, int> vector;
  final int schema;
  const DigestRecord(this.digest, this.vector, this.schema);

  Op toOp(String stream, String hlc) => Op(digestKind, stream, {'digest': digest, 'vector': vector, 'schema': schema}, hlc);

  /// The record in [op], or null when it does not parse (then it is ignored).
  static DigestRecord? fromOp(Op op) {
    final (d, v, s) = (op.fields['digest'], op.fields['vector'], op.fields['schema']);
    if (d is! String || v is! Map || s is! int) return null;
    final vector = <String, int>{};
    for (final MapEntry(:key, :value) in v.entries) {
      if (key is! String || value is! int) return null;
      if (value > 0) vector[key] = value;
    }
    return DigestRecord(d, vector, s);
  }
}

/// Whether two data vectors name the same files (entries of 0 count as absent).
bool sameVector(Map<String, int> a, Map<String, int> b) {
  final x = {
    for (final e in a.entries)
      if (e.value > 0) e.key: e.value
  };
  final y = {
    for (final e in b.entries)
      if (e.value > 0) e.key: e.value
  };
  return x.length == y.length && x.entries.every((e) => y[e.key] == e.value);
}

/// This device's digest bookkeeping, one device-local value ([key], never synced):
/// `{"v": {"<stream>": seq}, "d": 1, "at": ms, "ans": ["<ask id>", …], "send": "<hlc>", "ask": 1, "dis": "<short id>"}`.
/// - `v`: the data vector: per stream, the seq of the last file holding data ops this device applied or wrote;
/// - `d`: data ops were applied or written since the last digest this device sent;
/// - `at`: when this device last started or answered a repair; `ans`: the ids (record clocks) of the repair asks it
///   answered or wrote itself, newest [maxAnswered] kept;
/// - `send`: the HLC of the [repairKind] record a repair resend waiting in the outbox carries in each of its files;
///   `ask`: that record asks the other devices to resend too (this device started the repair);
/// - `dis`: the peer of a second mismatch within [SyncDigests.repairQuiet] of a repair (`devicesDisagree`).
class DigestBook {
  static const key = 'syncDigest';

  /// How many answered ask ids are kept (oldest dropped first).
  static const maxAnswered = 32;
  final Map<String, int> vector;
  final List<String> answered;
  bool dirty, sendAsk;
  int? repairAt;
  String? send, disagree;
  DigestBook._(this.vector, {this.dirty = false, this.repairAt, List<String>? answered, this.send, this.sendAsk = false, this.disagree})
      : answered = answered ?? [];

  /// Records [ask] as answered (kept to the newest [maxAnswered]).
  void answer(String ask) {
    if (answered.contains(ask)) return;
    answered.add(ask);
    if (answered.length > maxAnswered) answered.removeRange(0, answered.length - maxAnswered);
  }

  static DigestBook load(WalletRepo repo) {
    final raw = repo.localValue(key);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map;
        final v = j['v'];
        return DigestBook._(
          {
            if (v is Map)
              for (final MapEntry(:key, :value) in v.entries)
                if (key is String && value is int && value > 0) key: value
          },
          dirty: j['d'] == 1,
          repairAt: j['at'] is int ? j['at'] as int : null,
          answered: [if (j['ans'] case final List<Object?> l) ...l.whereType<String>()],
          send: j['send'] is String ? j['send'] as String : null,
          sendAsk: j['ask'] == 1,
          disagree: j['dis'] is String ? j['dis'] as String : null,
        );
      } on Object catch (e, st) {
        // Only this device's bookkeeping: start over (the next data change sends a digest again).
        logError(_log, 'sync.digest.unreadable', e, st);
      }
    }
    return DigestBook._({});
  }

  void save(WalletRepo repo) {
    final j = <String, Object?>{
      if (vector.isNotEmpty) 'v': vector,
      if (dirty) 'd': 1,
      if (repairAt != null) 'at': repairAt,
      if (answered.isNotEmpty) 'ans': answered,
      if (send != null) 'send': send,
      if (sendAsk) 'ask': 1,
      if (disagree != null) 'dis': disagree,
    };
    repo.setLocalValue(key, j.isEmpty ? null : jsonEncode(j));
  }

  /// File [seq] of [stream] held data ops and was applied (or written, for this device's own stream).
  void data(String stream, int seq) {
    if ((vector[stream] ?? 0) < seq) vector[stream] = seq;
    dirty = true;
  }
}

/// Records collected while applying the peers' files of one run.
class RunRecords {
  /// The newest digest record per peer stream.
  final digests = <String, DigestRecord>{};

  /// The repair asks read (their record clocks = their ids).
  final asks = <String>{};

  void add(String stream, List<Op> records) {
    for (final op in records) {
      if (op.entity == digestKind) {
        final r = DigestRecord.fromOp(op);
        if (r != null) {
          digests[stream] = r;
        } else {
          logEvent(_log, Level.WARNING, 'sync.digest.badRecord');
        }
      } else if (op.entity == repairKind && op.fields['ask'] == true) {
        asks.add(op.hlc);
      }
    }
  }
}

/// Constants of the digest rule.
abstract final class SyncDigests {
  /// A second mismatch within this long of a repair stops automatic repair (`devicesDisagree`).
  static const repairQuiet = Duration(days: 7);
}
