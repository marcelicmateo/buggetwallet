import 'package:flutter/foundation.dart';
import 'package:wallet_core/wallet_core.dart';

/// A part of the controller's state that is a [Listenable] of its own. Its setters only mark it changed ([touch]); the controller
/// calls [flush] right after it notified its own listeners, so this state tells its listeners at most once per controller
/// notification, and only when something in it changed. The controller never listens to a sub-state: its own notifications are
/// exactly the ones it makes itself.
abstract class SubState extends ChangeNotifier {
  bool _dirty = false;

  /// Marks the state changed; the next [flush] tells the listeners.
  @protected
  void touch() => _dirty = true;

  /// Tells the listeners if the state changed since the last call.
  void flush() {
    if (!_dirty) return;
    _dirty = false;
    notifyListeners();
  }
}

/// The sync status the screens show: the last run's result, devices, problems and errors (see `WalletController.syncNow`).
class SyncState extends SubState {
  bool _running = false;
  DateTime? _lastSync;
  String? _error;
  bool _caughtUp = false;
  List<SyncWaiting> _waiting = const [];
  int _blobsWaiting = 0;
  bool _blobsUnsupported = false;
  List<SyncDevice> _devices = const [];
  int _badFiles = 0;
  String? _relayInstance;
  int? _relayBytes, _relayMaxBytes;
  List<SyncProblem> _problems = const [];

  /// A run is in flight.
  bool get running => _running;
  set running(bool v) => _set(_running, v, () => _running = v);

  DateTime? get lastSync => _lastSync;
  set lastSync(DateTime? v) => _set(_lastSync, v, () => _lastSync = v);

  /// A plain message when the last run failed.
  String? get error => _error;
  set error(String? v) => _set(_error, v, () => _error = v);

  /// From the last successful sync: every device applied through its last file (matching only runs then).
  bool get caughtUp => _caughtUp;
  set caughtUp(bool v) => _set(_caughtUp, v, () => _caughtUp = v);

  /// From the last successful sync: devices whose later files wait for a missing or refused file.
  List<SyncWaiting> get waiting => _waiting;
  set waiting(List<SyncWaiting> v) => _set(_waiting, v, () => _waiting = v);

  /// Bill photos and files the last sync could not upload yet (they stay queued and are tried again).
  int get blobsWaiting => _blobsWaiting;
  set blobsWaiting(int v) => _set(_blobsWaiting, v, () => _blobsWaiting = v);

  /// The relay is older than bill files: it answers 404 to every upload.
  bool get blobsUnsupported => _blobsUnsupported;
  set blobsUnsupported(bool v) => _set(_blobsUnsupported, v, () => _blobsUnsupported = v);

  /// From the last successful sync: the devices the relay knows (short ids), this one included.
  List<SyncDevice> get devices => _devices;
  set devices(List<SyncDevice> v) => _set(_devices, v, () => _devices = v);

  /// Files from other devices the last sync could not read (damaged or half-synced); retried on every sync.
  int get badFiles => _badFiles;
  set badFiles(int v) => _set(_badFiles, v, () => _badFiles = v);

  /// The relay's instance id (shown only as a fingerprint).
  String? get relayInstance => _relayInstance;
  set relayInstance(String? v) => _set(_relayInstance, v, () => _relayInstance = v);

  /// What the relay holds for this wallet and its limit (null: not known, e.g. an older relay).
  int? get relayBytes => _relayBytes;
  set relayBytes(int? v) => _set(_relayBytes, v, () => _relayBytes = v);
  int? get relayMaxBytes => _relayMaxBytes;
  set relayMaxBytes(int? v) => _set(_relayMaxBytes, v, () => _relayMaxBytes = v);

  /// Files not applied (a device whose clock is ahead; this device's own id in use).
  List<SyncProblem> get problems => _problems;
  set problems(List<SyncProblem> v) => _set(_problems, v, () => _problems = v);

  void _set<T>(T old, T v, void Function() assign) {
    if (identical(old, v) || old == v) return;
    assign();
    touch();
  }

  /// Nothing of the old status, devices or errors stays: a new wallet, another relay, a forgotten browser. [keepLastSync] leaves
  /// the time of the last run (a new relay address). A run in flight ([running]) is not touched.
  void reset({bool keepLastSync = false}) {
    if (!keepLastSync) lastSync = null;
    error = null;
    caughtUp = false;
    waiting = const [];
    blobsWaiting = 0;
    blobsUnsupported = false;
    devices = const [];
    badFiles = 0;
    relayInstance = null;
    relayBytes = null;
    relayMaxBytes = null;
    problems = const [];
  }
}
