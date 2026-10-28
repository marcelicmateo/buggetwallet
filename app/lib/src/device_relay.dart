// The relay as the device screens use it (stage DK): read the device list, approve, remove, lock, and this install's own code.
// One short-lived object per action (opened, used, closed). The real one wraps a RelayTransport; tests wrap a MemoryDeviceTransport.
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

class DeviceRelay {
  DeviceRelay({required this.transport, required this.devices, required this.fingerprint, this.onClose});

  /// For `state()` (the list of keys and the streams' last-seen times).
  final SyncTransport transport;

  /// For approve, remove and the lock.
  final DeviceKeyTransport devices;

  /// This install's own code `ABCD-EFGH` (made from its device key, no request); null without a device key.
  final Future<String?> Function() fingerprint;
  final void Function()? onClose;

  void close() => onClose?.call();
}

/// Opens a [DeviceRelay] for the wallet's relay.
typedef DeviceRelayOpener = Future<DeviceRelay> Function(Uri relay, VaultKey key, WalletRepo repo);
