// Sync types the app reads (compile for the web). The engine and its transports are in `sync_engine.dart`.
import 'package:wallet_core/wallet_core.dart' show LogSafeError;

import 'sync_problems.dart';

export 'sync_problems.dart' show SyncProblem, SyncProblemReason, syncReaderVersion;

class SyncException implements Exception, LogSafeError {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

/// A device whose later files wait: [seq] is the next file this device needs from it, and it could not be applied.
class SyncWaiting {
  /// The other device's short id ([SyncProblem.shortId]).
  final String device;

  /// The relay sequence number of the file that is missing or refused.
  final int seq;

  /// Why the file was refused (quarantined); null when it could not be fetched (relay unreachable for that file, gone,
  /// not stored, or pruned with no readable snapshot).
  final SyncProblemReason? reason;
  const SyncWaiting(this.device, this.seq, {this.reason});

  @override
  String toString() => 'SyncWaiting($device, $seq, ${reason?.name ?? 'not fetched'})';
}

/// A device the relay knows (it stored a file or sent an ack).
class SyncDevice {
  /// Short id ([SyncProblem.shortId]).
  final String device;

  /// When the relay last heard from it (a file or an ack); for this device the end of this run.
  final DateTime? lastSeen;

  /// This device.
  final bool isThis;
  const SyncDevice(this.device, {this.lastSeen, this.isThis = false});

  @override
  String toString() => 'SyncDevice($device${isThis ? ', this' : ''})';
}

class SyncReport {
  /// Ops uploaded, fields changed here by other devices' ops, files (and snapshots) applied.
  final int sent, received, filesRead;

  /// Files from other devices that were not applied: refused in this run, or refused earlier and unchanged since
  /// (those are not read again; for a newer format an app update retries them), and files that could not be fetched.
  final List<SyncProblem> problems;

  /// Every device the relay lists applied through its last file, nothing quarantined or waiting: only then do matching
  /// and own-transfer pairing run (`WalletRepo.runPendingMatch`); otherwise they wait for a later run.
  final bool caughtUp;

  /// Devices whose later files wait for a missing or refused file (files apply strictly in order per device).
  final List<SyncWaiting> waiting;

  /// The devices the relay knows, this one included (sorted by id; short ids only).
  final List<SyncDevice> devices;

  /// Bill files uploaded in this run, and those still waiting (refused or not reachable; an older relay that cannot
  /// keep bill files answers 404 to every one: the app says "this relay can't keep bill photos yet").
  final int blobsSent, blobsWaiting;

  /// The relay answered 404 to a bill file upload although it knows this wallet (this device's files are on it): an
  /// older relay without blob storage. The app says "This relay can't keep bill photos yet. Update the relay on the
  /// home server." A 404 before this device's first file reached the relay is expected (the relay creates the wallet
  /// with it; the upload is retried in the same run) and counts only when that retry is refused again.
  final bool blobsUnsupported;

  /// The relay's instance id for this wallet (`RelayState.instance`; null from an older relay or before the wallet
  /// exists there). The app shows [relayFingerprint] of it.
  final String? relayInstance;

  /// The relay names another instance than the one this device last synced with (stored device-locally as
  /// `syncInstance`): a wiped, restored or replaced relay. This run was then a first connect (whole state uploaded,
  /// every device's files read from the start). False on the very first sync and with an older relay.
  final bool relayChanged;

  /// Relay usage from this run's `GET state` (`RelayState.bytes` / `maxBytes`): this wallet's stored bytes on the relay
  /// and the relay's limit for it. Null from an older relay that does not send them. Read at the start of the run (or
  /// again after an upload that created the wallet), so this run's own upload may not be in [relayBytes] yet.
  final int? relayBytes, relayMaxBytes;

  /// The relay's api as this run's state named it (`RelayState.api`; null when unknown). From 4 on the relay cleans
  /// up bill files no kept snapshot declares (P14), so the app can say "Old bill files are cleaned up on the relay."
  final int? relayApi;

  /// Whether the relay collects old bill files ([relayApi] ≥ 4).
  bool get relayCollectsBlobs => (relayApi ?? 0) >= 4;

  const SyncReport(this.sent, this.received, this.filesRead,
      {this.problems = const [],
      this.caughtUp = false,
      this.waiting = const [],
      this.devices = const [],
      this.blobsSent = 0,
      this.blobsWaiting = 0,
      this.blobsUnsupported = false,
      this.relayInstance,
      this.relayChanged = false,
      this.relayBytes,
      this.relayMaxBytes,
      this.relayApi});

  /// How many files were not applied ([problems]).
  int get badFiles => problems.length;

  /// Files not applied, per other device id.
  Map<String, int> get problemsByDevice {
    final out = <String, int>{};
    for (final p in problems) {
      out[p.device] = (out[p.device] ?? 0) + 1;
    }
    return out;
  }
}

/// The relay fingerprint the app shows: the first 8 hex characters of [instance] as `xxxx-xxxx` (shorter input as it
/// is, lower case).
String relayFingerprint(String instance) {
  final h = instance.toLowerCase();
  if (h.length < 8) return h;
  return '${h.substring(0, 4)}-${h.substring(4, 8)}';
}
