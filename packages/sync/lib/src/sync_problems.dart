import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:wallet_core/wallet_core.dart';

final _log = Logger('bw.sync');

/// The highest sync file format (`BWOPn`) this build reads. Bump it with a new format: files refused as
/// [SyncProblemReason.unknownVersion] are read again after the upgrade.
const syncReaderVersion = 3;

/// Why a sync file from another device was not applied.
enum SyncProblemReason {
  /// An old `BWOP1`/`BWOP2` file sealed with another wallet's key, or changed after sealing (those formats cannot tell).
  badKey,

  /// Damaged: cut off, not a sync file, or sealed correctly but not a list of valid ops.
  corrupt,

  /// A newer file format: readable after updating the app.
  unknownVersion,

  /// Read fine but the database refused it (a bug in this build or the writer's).
  applyFailed,

  /// The file could not be read at all this time (removed or locked mid-run). Not quarantined: read again next run.
  unreadable,

  /// This device's own upload was refused with 409: the relay already holds another file under this device's next
  /// seq, so another install writes as this device (a copied database or key store). Never retried silently; the
  /// outbox is kept. [SyncProblem.device] is this device's short id.
  deviceIdInUse,

  /// The file's newest clock is more than an hour ahead of this device's wall clock (a peer with a wrong date, or this
  /// device's clock is behind). Quarantined; read again when it changes, the build changes, or the wall clock has
  /// caught up.
  clockDrift,

  /// Sealed with another wallet key: a `BWOP3` file whose key id is not this wallet's (a device of another wallet on
  /// the same relay, or one left on an old key after a key change). Nothing was decrypted; quarantined like [badKey].
  otherKey,

  /// Not a file: this device's state digest differed from a peer's twice within 7 days of a repair (V2), so automatic
  /// repair stopped. Device-local, kept until a later compare matches. [SyncProblem.device] is the peer's short id.
  devicesDisagree,
}

/// A file from another device that this run did not apply, for the UI ("1 file from device X could not be read").
class SyncProblem {
  /// The other device's short id ([shortId] of its folder name in the sync folder). Never a path or a file name.
  final String device;
  final SyncProblemReason reason;

  /// The file's size in bytes.
  final int bytes;

  /// Found in this run. False: refused in an earlier run and not read again, because it has not changed since.
  final bool isNew;

  /// A relay snapshot rather than a device's file ([device] is then empty): it could not be fetched or was refused,
  /// and is not fetched again until the relay names another snapshot (one that could not be fetched: after an hour).
  final bool snapshot;
  const SyncProblem(this.device, this.reason, {required this.bytes, this.isNew = true, this.snapshot = false});

  /// What of a device's folder name the UI gets: its first 8 characters (device ids are random hex, so a prefix tells
  /// devices apart as well as the whole id does).
  static String shortId(String folder) => folder.length <= 8 ? folder : folder.substring(0, 8);

  @override
  String toString() => 'SyncProblem(${snapshot ? 'snapshot, ' : ''}${reason.name}, $bytes bytes${isNew ? ', new' : ''})';
}

/// A refused file, kept on this device only (a local value, never synced) so it is not retried on every run.
///
/// It is read again only when it changes: by content hash where reads are cheap (a local folder); [size] and [stamp]
/// are kept for a transport that lists files without reading them (none yet: `SyncEngine` always hashes). Files
/// refused as [SyncProblemReason.unknownVersion] or [SyncProblemReason.applyFailed] are also read again once after
/// [build] (the reader, the schema or the app version, see `SyncEngine.build`) changes.
class BadFile {
  /// The device's folder name and the file's name: the quarantine key. Never logged or shown.
  final String device, file;
  final SyncProblemReason reason;
  final int size;
  final String? stamp;
  final String hash;
  final String build;

  /// [SyncProblemReason.clockDrift] only: the wall clock (ms since epoch) from which the file is no longer too far
  /// ahead (its newest clock − 1 h), so it is read again then.
  final int? retryAt;
  const BadFile(this.device, this.file, this.reason,
      {required this.size, this.stamp, required this.hash, required this.build, this.retryAt});

  String get key => keyOf(device, file);
  static String keyOf(String device, String file) => '$device/$file';

  /// Whether this build might read it now although the file has not changed.
  bool retryAfterUpgrade(String build) =>
      (reason == SyncProblemReason.unknownVersion || reason == SyncProblemReason.applyFailed || reason == SyncProblemReason.clockDrift) &&
      this.build != build;

  /// Whether to read it again now although neither the file nor [build] changed: a [SyncProblemReason.clockDrift]
  /// file once the wall clock [nowMs] reached [retryAt].
  bool retryNow(String build, int nowMs) => retryAfterUpgrade(build) || (retryAt != null && nowMs >= retryAt!);

  /// Whether a file listed with [size] and [stamp] (no content read) differs from the refused one.
  bool listedChanged(int? size, String? stamp) => size != this.size || stamp != this.stamp;

  SyncProblem problem({required bool isNew}) => SyncProblem(SyncProblem.shortId(device), reason, bytes: size, isNew: isNew);

  Map<String, Object?> toJson() =>
      {'d': device, 'f': file, 'r': reason.name, 'n': size, 's': stamp, 'h': hash, 'b': build, if (retryAt != null) 'u': retryAt};

  static BadFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final reason = SyncProblemReason.values.asNameMap()[j['r']];
    final (d, f, n, s, h, b, u) = (j['d'], j['f'], j['n'], j['s'], j['h'], j['b'], j['u']);
    if (reason == null ||
        d is! String ||
        f is! String ||
        n is! int ||
        (s != null && s is! String) ||
        h is! String ||
        b is! String ||
        (u != null && u is! int)) {
      return null;
    }
    return BadFile(d, f, reason, size: n, stamp: s as String?, hash: h, build: b, retryAt: u as int?);
  }
}

/// The quarantine list, stored as one device-local value of the repo ([WalletRepo.localValue]).
class BadFiles {
  static const localKey = 'syncBadFiles';
  final Map<String, BadFile> byKey;
  BadFiles._(this.byKey);

  static BadFiles load(WalletRepo repo) {
    final raw = repo.localValue(localKey);
    final out = <String, BadFile>{};
    if (raw != null) {
      try {
        for (final j in jsonDecode(raw) as List) {
          if (BadFile.fromJson(j) case final BadFile b) out[b.key] = b;
        }
      } on Object catch (e, st) {
        // Only this device's bookkeeping: start over, the files are simply checked again.
        logError(_log, 'sync.badFiles.unreadable', e, st);
      }
    }
    return BadFiles._(out);
  }

  void save(WalletRepo repo) => repo.setLocalValue(localKey, byKey.isEmpty ? null : jsonEncode([for (final b in byKey.values) b.toJson()]));
}

/// Short content hash of a sync file (hex), to tell a repaired copy from the refused one.
Future<String> fileHash(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes.sublist(0, 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
