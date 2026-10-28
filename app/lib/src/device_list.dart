// What Settings › Sync › Devices shows (stage DK), made from the relay's state. Pure Dart; the texts are here so tests pin them.
import 'package:wallet_sync/wallet_sync.dart';

/// Why this install no longer syncs: its key waits for approval, or was removed from the wallet.
enum DeviceStop { pending, revoked }

/// "Device approval needs the relay updated." (an older relay has no device keys).
const deviceOlderRelayText = 'Device approval needs the relay updated.';

const deviceRevokedText = 'This device was removed from the wallet. Its data stays here; it no longer syncs.';

/// Shown on a device whose key waits for approval, over its code.
const devicePendingTitle = 'Waiting for approval';
const devicePendingHelp = 'On a device you already use, open Settings › Sync › Devices and approve this code:';

const deviceRemovedAdviceText = "If the removed device may be in someone else's hands, change the wallet key.";

/// The steps behind "How to change the key" (docs/TECHNICAL_SPEC.md §9): a new key is a new wallet the old device cannot read.
const changeKeyTitle = 'Change the wallet key';
const changeKeySteps = [
  'On a device you trust: Settings › Backup, "Back up now" (sealed with the old key).',
  'Start fresh on that device: clear the app\'s data (Android: Settings › Apps › Budget Wallet › Clear storage; computer: remove the app\'s data folder; browser: "Forget this browser").',
  'Choose "Start a new wallet". That makes a new key. Save it.',
  'Settings › Backup, "Restore a backup made with another key…": pick the backup and enter the old key.',
  'Join every other device you still use with the new key.',
  'Delete the old wallet\'s folder on the relay.',
];
const changeKeyNote = 'The lost device keeps what it already had, but it sees nothing newer.';

/// The revoked device asks to be approved again with a new device key.
const useNewKeyTitle = 'Use a new device key?';
const useNewKeyText = 'This device will ask to be approved again on a device you already use.';

String rejectDeviceTitle(String fp) => 'Reject $fp?';
const rejectDeviceText = 'It is turned away. It can only join if it asks again.';

const deviceRemovedAlsoLocksText = 'Removing a device also turns on "Require approval for new devices".';

/// "Remove all other devices" (a lost or stolen phone): the confirm.
const removeOthersTitle = 'Remove all other devices?';
const removeOthersText =
    "Use this if a phone was lost or stolen. Every other device stops syncing; you'll approve them again one by one. $deviceRemovedAlsoLocksText";

/// Turning "Require approval" off while a removed device exists.
const lockOffWarningText = 'A removed device that still has the wallet key could join again.';

/// The relay ignores "off" for a few minutes after a removal: the switch stays on, and this says why.
const approvalStaysOnText = 'Approval stays on for a few minutes after removing a device.';

String removeDeviceTitle(String name) => 'Remove $name?';

String approveDeviceTitle(String fp) => 'Does the other device show $fp?';

/// One enrolled (or removed) device key.
class DeviceRow {
  final String fp;

  /// The short id of the device, plus nothing else; [self] marks this install.
  final String name;
  final bool self;
  final DateTime? added, lastSeen, revoked;

  /// Removing is offered for another, still enrolled device while at least one other enrolled device stays.
  final bool canRemove;
  const DeviceRow(this.fp, this.name, {this.self = false, this.added, this.lastSeen, this.revoked, this.canRemove = false});

  bool get isRevoked => revoked != null;
}

/// A key asking to join, waiting for an approver.
class PendingRow {
  final String fp;
  final String name;
  final DateTime? at;
  const PendingRow(this.fp, this.name, {this.at});
}

/// The device list of a relay that knows device keys (api 5): [rows] (enrolled first, removed last), [pending], and the
/// "Require approval" switch.
class DeviceList {
  final List<DeviceRow> rows;
  final List<PendingRow> pending;
  final bool locked;
  const DeviceList(this.rows, this.pending, {this.locked = false});

  int get active => rows.where((r) => !r.isRevoked).length;

  /// A removed key exists: turning approval off would let it join again.
  bool get anyRemoved => rows.any((r) => r.isRevoked);

  /// "Remove all other devices" has something to do: another enrolled key or a waiting one.
  bool get hasOthers => rows.any((r) => !r.self && !r.isRevoked) || pending.isNotEmpty;
}

String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// The device list in [s], or null when the relay has no device keys (older relay, or a request that did not name a device
/// key). [ownDeviceId] names this install's row.
DeviceList? deviceListOf(RelayState s, {String? ownDeviceId}) {
  final keys = s.keys;
  if (keys == null) return null;
  String name(String? stream, String? deviceId, {bool self = false}) {
    if (self && ownDeviceId != null) return _shortId(ownDeviceId);
    if (stream != null && stream.isNotEmpty) return _shortId(SyncEngine.streamBase(stream));
    if (deviceId != null && deviceId.isNotEmpty) return _shortId(deviceId);
    return 'New device';
  }

  final enrolled = keys.where((k) => !k.isRevoked).length;
  final rows = <DeviceRow>[
    for (final k in keys.where((k) => !k.isRevoked))
      DeviceRow(k.fp, name(k.device, k.deviceId, self: k.self),
          self: k.self,
          added: k.added,
          lastSeen: k.device == null ? null : s.devices[k.device]?.lastSeen,
          canRemove: !k.self && enrolled > 1),
    for (final k in keys.where((k) => k.isRevoked))
      DeviceRow(k.fp, name(k.device, k.deviceId, self: k.self),
          self: k.self, added: k.added, lastSeen: k.device == null ? null : s.devices[k.device]?.lastSeen, revoked: k.revoked),
  ];
  return DeviceList(rows, [for (final p in s.pending) PendingRow(p.fp, name(null, p.deviceId), at: p.at)], locked: s.locked ?? false);
}

/// A short plain message for a failed device action.
String deviceActionError(TransportException e) => switch (e.failure) {
      TransportFailure.lastDevice => "The last device can't be removed.",
      TransportFailure.olderApi => deviceOlderRelayText,
      TransportFailure.missing => 'That device is no longer waiting.',
      TransportFailure.conflict => 'That device was already removed.',
      TransportFailure.tooManyKeys => 'This wallet already has 16 devices. Remove one first.',
      TransportFailure.pendingFull => "Too many devices are waiting for approval. Remove the ones you don't know.",
      TransportFailure.unreachable => "Couldn't reach the relay. Try again.",
      TransportFailure.newerApi => 'The relay runs a newer version. Update the app.',
      _ => "Couldn't do that. Try again.",
    };

/// Which stop ended a sync run: the engine names the transport failure in [SyncException.failure]. `pendingFull` and `tooManyKeys`
/// are plain errors (never the approval-code screen).
DeviceStop? deviceStopOf(Object error) {
  if (error is! SyncException) return null;
  return switch (error.failure) {
    TransportFailure.revoked => DeviceStop.revoked,
    TransportFailure.pending => DeviceStop.pending,
    _ => null,
  };
}

DeviceStop? deviceStopOfTransport(TransportException e) => switch (e.failure) {
      TransportFailure.revoked => DeviceStop.revoked,
      TransportFailure.pending => DeviceStop.pending,
      _ => null,
    };
