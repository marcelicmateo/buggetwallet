// Settings › Sync › Devices (stage DK): the relay's device keys with "Remove this device", the waiting ones with "Approve",
// "Require approval for new devices", and the notice a device shows while its own key waits for approval or was removed.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../device_list.dart';
import '../format.dart' show shortDateOrRaw;
import '../layout.dart';
import '../logging.dart';
import '../sync_status.dart';
import '../theme.dart';
import '../widgets/common.dart';

String _day(DateTime? t) => t == null ? '' : shortDateOrRaw(isoDate(t.toLocal()));

/// This device's own state: "Waiting for approval" with its code (large, and as a QR), or "removed". Nothing when it syncs normally.
class DeviceStopNotice extends StatelessWidget {
  final WalletController wc;
  const DeviceStopNotice({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final stop = wc.deviceStop;
    if (stop == null) return const SizedBox.shrink();
    if (stop == DeviceStop.revoked) {
      return const StatusLabel(key: ValueKey('deviceRevoked'), good: false, text: deviceRevokedText);
    }
    final code = wc.deviceCode;
    final c = context.c;
    return Column(key: const ValueKey('devicePending'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.hourglass_empty, size: 18, color: c.warnInk),
        const SizedBox(width: 6),
        const Expanded(child: Heading(devicePendingTitle, size: BwType.headingSize)),
      ]),
      const SizedBox(height: 4),
      const Muted(devicePendingHelp),
      if (code != null) ...[
        const SizedBox(height: 8),
        Center(
            child: Text(code,
                key: const ValueKey('deviceCode'),
                style: numStyle.copyWith(fontSize: 28, letterSpacing: 2, fontWeight: FontWeight.w600, color: c.ink))),
        const SizedBox(height: 8),
        Center(
            child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(key: const ValueKey('deviceCodeQr'), data: code, size: 150))),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('deviceCheckAgain'),
          icon: const Icon(Icons.refresh),
          label: const Text('Check again'),
          onPressed: wc.syncing
              ? null
              : () {
                  logNav('devices.checkAgain');
                  wc.syncNow();
                },
        ),
      ),
    ]);
  }
}

/// The Devices block of Settings › Sync. Reads the relay's device list when it opens.
class SyncDevicesBlock extends StatefulWidget {
  final WalletController wc;
  const SyncDevicesBlock({super.key, required this.wc});
  @override
  State<SyncDevicesBlock> createState() => _SyncDevicesBlockState();
}

class _SyncDevicesBlockState extends State<SyncDevicesBlock> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.wc.relayUrl != null && widget.wc.deviceStop == null) widget.wc.refreshDevices();
  }

  Future<void> _act(Future<String?> Function() call, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await call();
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, error ?? done);
  }

  Future<bool> _confirm(String title, String body, {required Key okKey, required Key cancelKey, required String ok}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(key: cancelKey, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: okKey, onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    );
    return r == true && mounted;
  }

  Future<void> _remove(DeviceRow d) async {
    logNav('devices.removeAsk');
    final seen = d.lastSeen == null ? 'It has not synced yet.' : 'Its last sync was ${lastSeenText(d.lastSeen, widget.wc.now)}.';
    final ok = await _confirm(removeDeviceTitle(d.name), '$seen $deviceRemovedAlsoLocksText',
        okKey: const ValueKey('removeConfirm'), cancelKey: const ValueKey('removeCancel'), ok: 'Remove');
    if (ok) await _act(() => widget.wc.removeDevice(d.fp), 'Device removed.');
  }

  Future<void> _approve(PendingRow p) async {
    logNav('devices.approveAsk');
    final ok = await _confirm(approveDeviceTitle(p.fp), 'Approve only if the code on the other device is the same.',
        okKey: const ValueKey('approveConfirm'), cancelKey: const ValueKey('approveCancel'), ok: 'Approve');
    if (ok) await _act(() => widget.wc.approveDevice(p.fp), 'Device approved.');
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final now = wc.now;
    final list = wc.deviceList;
    final c = context.c;
    if (list == null) {
      if (wc.syncDevices.isEmpty && !wc.deviceOlderRelay) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Heading('Devices', size: BwType.headingSize),
        if (wc.deviceOlderRelay) const Muted(deviceOlderRelayText, key: ValueKey('deviceOlderRelay')),
        for (final d in wc.syncDevices)
          LineItem(d.isThis ? '${d.device} · this device' : d.device, '', sub: 'Last seen ${lastSeenText(d.lastSeen, now)}'),
      ]);
    }
    return Column(key: const ValueKey('deviceList'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Devices', size: BwType.headingSize),
      for (final d in list.rows) _row(context, d, now),
      if (list.pending.isNotEmpty) ...[
        const SizedBox(height: 8),
        const Eyebrow('Waiting for approval'),
        for (final p in list.pending) _pendingRow(context, p),
      ],
      SwitchListTile(
        key: const ValueKey('requireApproval'),
        contentPadding: EdgeInsets.zero,
        value: list.locked,
        onChanged: _busy ? null : (on) => _toggleLock(on, list),
        title: const Text('Require approval for new devices', style: TextStyle(fontSize: BwType.bodySize)),
        subtitle: const Text('A new device waits until you approve its code here.'),
      ),
      if (list.hasOthers)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('removeOthers'),
            icon: const Icon(Icons.phonelink_erase),
            label: const Text('Remove all other devices'),
            onPressed: _busy ? null : _removeOthers,
          ),
        ),
      if (wc.deviceRemovedNote)
        Column(key: const ValueKey('deviceRemovedNote'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(
            TextSpan(children: [
              WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(padding: const EdgeInsets.only(right: 5), child: Icon(Icons.info_outline, size: 16, color: c.muted))),
              const TextSpan(text: deviceRemovedAdviceText),
            ]),
            style: TextStyle(fontSize: BwType.metaSize, color: c.muted, height: 1.4),
          ),
          TextButton(key: const ValueKey('deviceRemovedOk'), onPressed: wc.dismissDeviceRemovedNote, child: const Text('OK')),
        ]),
    ]);
  }

  Future<void> _toggleLock(bool on, DeviceList list) async {
    logNav('devices.lockSwitch', {'on': on});
    // Off while a removed device exists: that device could join again if it still has the wallet key.
    if (!on && list.anyRemoved) {
      final ok = await _confirm('Turn off approval?', lockOffWarningText,
          okKey: const ValueKey('lockOffConfirm'), cancelKey: const ValueKey('lockOffCancel'), ok: 'Turn off');
      if (!ok) return;
    }
    await _act(() => widget.wc.setRequireApproval(on), on ? 'Approval is required.' : 'Approval is not required.');
  }

  Future<void> _removeOthers() async {
    logNav('devices.removeOthersAsk');
    final ok = await _confirm(removeOthersTitle, removeOthersText,
        okKey: const ValueKey('removeOthersConfirm'), cancelKey: const ValueKey('removeOthersCancel'), ok: 'Remove all');
    if (ok) await _act(() => widget.wc.removeOtherDevices(), 'Other devices removed.');
  }

  Widget _row(BuildContext context, DeviceRow d, DateTime now) {
    final c = context.c;
    final style = TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w500, color: d.isRevoked ? c.muted : c.ink);
    return Container(
      key: ValueKey('device:${d.fp}'),
      constraints: const BoxConstraints(minHeight: rowMin),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (d.isRevoked) Padding(padding: const EdgeInsets.only(right: 6, top: 2), child: Icon(Icons.block, size: 16, color: c.muted)),
          Expanded(child: Text(d.self ? '${d.name} · this device' : d.name, style: style)),
        ]),
        Muted('Code ${d.fp}'),
        Muted([
          if (d.isRevoked) 'Removed ${_day(d.revoked)}' else if (d.added != null) 'Added ${_day(d.added)}',
          if (!d.isRevoked) 'Last seen ${lastSeenText(d.lastSeen, now)}',
        ].join(' · ')),
        if (d.canRemove)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('removeDevice:${d.fp}'),
              icon: const Icon(Icons.person_remove_outlined),
              label: const Text('Remove this device'),
              onPressed: _busy ? null : () => _remove(d),
            ),
          ),
      ]),
    );
  }

  Widget _pendingRow(BuildContext context, PendingRow p) {
    return Container(
      key: ValueKey('pending:${p.fp}'),
      constraints: const BoxConstraints(minHeight: rowMin),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.hourglass_empty, size: 16, color: context.c.warnInk),
          const SizedBox(width: 6),
          Expanded(child: Text(p.fp, style: numStyle.copyWith(fontSize: BwType.bodySize, letterSpacing: 1, color: context.c.ink))),
        ]),
        Muted('Device ${p.name}${p.at == null ? '' : ' · asked ${_day(p.at)}'}'),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: ValueKey('approveDevice:${p.fp}'),
            onPressed: _busy ? null : () => _approve(p),
            child: const Text('Approve'),
          ),
        ),
      ]),
    );
  }
}
