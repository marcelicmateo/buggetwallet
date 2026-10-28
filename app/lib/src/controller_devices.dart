// Device keys in the controller (stage DK): the relay's device list, approving and removing devices, "Require approval for new
// devices", and what this install shows when its own key waits for approval or was removed. A `part` of controller.dart.
//
// Privacy: logs carry action words and counts only, never a fingerprint, a device id or the key.
part of 'controller.dart';

const _noticeDeviceRemoved = 'noticeDeviceRemoved';

/// Set once the Devices block was opened: from then on each successful sync run reads the device list again.
final _devicesWanted = Expando<bool>('devicesWanted');

extension DeviceKeys on WalletController {
  /// This install's key waits for approval or was removed ([DeviceStop]); null while it syncs normally. Cleared by a new relay
  /// address or key (`SyncState.reset`) and by a run that worked.
  DeviceStop? get deviceStop => sync.deviceStop;

  /// This install's own code `ABCD-EFGH` while it waits for approval.
  String? get deviceCode => sync.deviceCode;

  /// The relay's device keys; null until read, or on a relay without them.
  DeviceList? get deviceList => sync.deviceList;

  /// The relay answered and has no device keys: "Device approval needs the relay updated."
  bool get deviceOlderRelay => sync.deviceOlderRelay;

  /// A device was removed on this install: the advice to change the wallet key stays until OK.
  bool get deviceRemovedNote => repo.localValue(_noticeDeviceRemoved) != null;

  /// The Devices block closed: sync runs stop reading the device list again.
  void stopWatchingDevices() => _devicesWanted[this] = false;

  /// This device was removed and the owner chose "Use a new device key": the old key is deleted, the stop and the sync status are
  /// cleared as for a new relay (the run is not held back any more) and one run follows with trigger `relay`: it asks to be approved
  /// again, so it ends `pending` with its new code. Returns a message when the key could not be replaced, else null.
  Future<String?> useNewDeviceKey() async {
    final delete = deps.deviceKeyDeleter;
    if (delete == null) return "Couldn't do that. Try again.";
    // A run in flight still uses the old key, and the run below would skip as busy: let it end first.
    final running = _syncRun;
    if (running != null) await running.future;
    try {
      await delete();
    } catch (e, st) {
      logError(_sync, 'devices.newKeyFailed', e, st);
      return "Couldn't do that. Try again.";
    }
    logEvent(_sync, Level.INFO, 'devices.newKey', const {});
    sync.reset(keepLastSync: true);
    notifyListeners();
    await syncNow(trigger: 'relay');
    return null;
  }

  void dismissDeviceRemovedNote() {
    repo.setLocalValue(_noticeDeviceRemoved, null);
    logNav('sync.noticeDismissed', {'which': 'deviceRemoved'});
    notifyListeners();
  }

  /// A sync run (or a device call) ended because this key waits or was removed: remember it, show the code when waiting.
  Future<void> _noteDeviceStop(DeviceStop stop) async {
    sync.deviceStop = stop;
    logEvent(_sync, Level.WARNING, 'devices.stop', {'stop': stop.name});
    if (stop == DeviceStop.pending && sync.deviceCode == null) {
      final relay = relayUrl, k = key, open = deps.deviceRelayOpener;
      if (relay != null && k != null && open != null) {
        DeviceRelay? dr;
        try {
          dr = await open(relay, k, repo);
          sync.deviceCode = await dr.fingerprint();
        } catch (e, st) {
          logError(_sync, 'devices.codeFailed', e, st);
        } finally {
          dr?.close();
        }
      }
    }
  }

  /// A run worked: this key is enrolled. Reads the device list again when the Devices block was opened.
  void _deviceRunOk(SyncReport r) {
    sync.deviceStop = null;
    sync.deviceCode = null;
    if (_devicesWanted[this] == true && (r.relayApi ?? 0) >= 5) unawaited(refreshDevices());
  }

  /// Reads the relay's device list (Settings › Sync › Devices opens it, and after each action). Failures are logged and leave the
  /// old list; a removed or waiting key sets [deviceStop].
  Future<void> refreshDevices() async {
    _devicesWanted[this] = true;
    final relay = relayUrl, k = key, open = deps.deviceRelayOpener;
    if (relay == null || k == null || open == null) return;
    DeviceRelay? dr;
    try {
      dr = await open(relay, k, repo);
      await _readDevices(dr, relay);
    } on TransportException catch (e) {
      await _deviceFailure(e, 'refresh');
    } catch (e, st) {
      logError(_sync, 'devices.refreshFailed', e, st);
    } finally {
      dr?.close();
    }
  }

  Future<void> _readDevices(DeviceRelay dr, Uri relay) async {
    final s = await dr.transport.state();
    if (relay != relayUrl) return; // the address changed meanwhile: that answer belongs to the old relay
    final list = deviceListOf(s, ownDeviceId: repo.deviceId);
    sync.deviceList = list;
    sync.deviceOlderRelay = list == null && s.api != null && s.api! < 5;
    sync.deviceStop = null;
    logEvent(_sync, Level.FINE, 'devices.read', {
      'keys': list?.rows.length ?? 0,
      'pending': list?.pending.length ?? 0,
      'locked': list?.locked ?? false,
      'older': sync.deviceOlderRelay
    });
    notifyListeners();
  }

  Future<void> _deviceFailure(TransportException e, String action) async {
    logEvent(_sync, Level.INFO, 'devices.failed', {'action': action, 'failure': e.failure.name});
    final stop = deviceStopOfTransport(e);
    if (stop != null) {
      await _noteDeviceStop(stop);
      notifyListeners();
    }
  }

  /// Approves the waiting key [fp] (the owner compared the code with the other device's screen). Returns an owner-readable
  /// message when it failed, else null.
  Future<String?> approveDevice(String fp) => _deviceAction('approve', (d) => d.approveDevice(fp));

  /// Removes the enrolled key [fp] (or turns a waiting one away). Never this device's own key and never the last one; the relay also
  /// turns on "Require approval". Returns a message when it failed, else null.
  Future<String?> removeDevice(String fp) {
    final row = deviceList?.rows.where((r) => r.fp == fp).firstOrNull;
    if (row != null && (row.self || row.isRevoked || !row.canRemove)) return Future.value("This device can't be removed.");
    return _deviceAction('remove', (d) => d.revokeDevice(fp), onDone: () => repo.setLocalValue(_noticeDeviceRemoved, '1'));
  }

  /// "Require approval for new devices" on or off. Returns a message when it failed, else null.
  /// "Remove all other devices" (a lost or stolen phone): every other key is removed and every waiting one turned away; the relay
  /// also turns on "Require approval". Returns a message when it failed, else null.
  Future<String?> removeOtherDevices() =>
      _deviceAction('removeOthers', (d) => d.revokeOthers(), onDone: () => repo.setLocalValue(_noticeDeviceRemoved, '1'));

  /// An "off" the relay answered with "still on" (it ignores it for a few minutes after a removal) returns [approvalStaysOnText].
  Future<String?> setRequireApproval(bool on) async {
    var stayed = false;
    final error = await _deviceAction(on ? 'lock' : 'unlock', (d) async {
      final now = await d.setLocked(on);
      stayed = !on && now;
      return now;
    });
    return error ?? (stayed ? approvalStaysOnText : null);
  }

  Future<String?> _deviceAction(String action, Future<Object?> Function(DeviceKeyTransport d) call, {VoidCallback? onDone}) async {
    final relay = relayUrl, k = key, open = deps.deviceRelayOpener;
    if (relay == null || k == null || open == null) return deviceOlderRelayText;
    DeviceRelay? dr;
    try {
      dr = await open(relay, k, repo);
      final result = await call(dr.devices);
      logEvent(_sync, Level.INFO, 'devices.$action', {if (result is int) 'count': result});
      onDone?.call();
      try {
        await _readDevices(dr, relay); // the action worked: a failed read-back is not its failure
      } on TransportException catch (e) {
        await _deviceFailure(e, 'refresh');
      }
      notifyListeners();
      return null;
    } on TransportException catch (e) {
      await _deviceFailure(e, action);
      return deviceActionError(e);
    } catch (e, st) {
      logError(_sync, 'devices.$action.failed', e, st);
      return "Couldn't do that. Try again.";
    } finally {
      dr?.close();
    }
  }
}
