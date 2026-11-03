import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../controller.dart';
import '../device_list.dart';
import '../logging.dart';
import '../platform.dart';
import '../sync_status.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'recent_changes.dart';
import 'sync_conflicts.dart';
import 'sync_devices.dart';

final _log = Logger('bw.sync');

/// Plan › Sync: the relay address and creation token with one Save (it checks the relay first), "Sync now", the state of the last
/// sync, the devices the relay knows and the wallet key. The address and the token are never logged (only set / unset).
String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).round()} KB'
    : (bytes < 1073741824 ? '${(bytes / 1048576).round()} MB' : '${(bytes / 1073741824).toStringAsFixed(1)} GB');

class SyncPanel extends StatefulWidget {
  final WalletController wc;

  /// Opens the wallet key dialog (it lives in Plan).
  final VoidCallback onShowKey;
  const SyncPanel({super.key, required this.wc, required this.onShowKey});
  @override
  State<SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends State<SyncPanel> {
  late final TextEditingController _address = TextEditingController(text: widget.wc.relayUrl?.toString() ?? '');
  late final TextEditingController _token = TextEditingController(text: widget.wc.relayCreateToken);
  String? _addressError;
  bool _saving = false;

  /// Whether the creation token is shown as text (a long mixed-case token cannot be checked otherwise); hidden again on Save.
  bool _showToken = false;

  /// The last Save answer: text, whether it was good, and (when the sync after saving failed) that sync error's text, so the
  /// panel does not print it twice; cleared when a field is edited.
  ({String text, bool good, String? syncError})? _result;

  @override
  void initState() {
    super.initState();
    widget.wc.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// The typed address as a [Uri]; null (and the error shown) when it is not one. Empty is valid and means "no relay".
  (bool ok, Uri? url) _read() {
    final t = _address.text.trim();
    if (t.isEmpty) return (true, null);
    final issue = WalletController.relayAddressIssue(t);
    if (issue != null) {
      setState(() => _addressError = issue == RelayAddressIssue.needsHttps ? addressNeedsHttpsText : addressNotAnAddressText);
      logNav('sync.addressRejected', {'reason': issue.name});
      return (false, null);
    }
    return (true, WalletController.parseRelayAddress(t));
  }

  /// One Save for both fields. A bad address is refused under the field; with an address the relay is checked first (nothing is
  /// saved when it is unreachable or speaks another API); then token and address are saved and the sync after it says whether the
  /// relay accepts the token. An empty address removes the relay (the token stays on this device).
  Future<void> _save() async {
    final (ok, url) = _read();
    if (!ok) return;
    setState(() {
      _addressError = null;
      _result = null;
      _saving = true;
    });
    logNav('sync.relaySave', {'set': url != null, 'token': _token.text.trim().isNotEmpty}); // never the address or the token
    ({String text, bool good, String? syncError}) result;
    try {
      if (url != null) await widget.wc.testRelay(url);
      await widget.wc.setRelayCreateToken(_token.text, sync: false); // setRelay syncs once for both
      await widget.wc.setRelay(url);
      final err = widget.wc.syncError;
      result = url == null
          ? (text: 'Saved.', good: true, syncError: null)
          : err == null
              ? (text: 'Saved. Relay reachable.', good: true, syncError: null)
              : (text: 'Saved. $err', good: false, syncError: err);
    } on TransportException catch (e) {
      result = (text: 'Not saved. ${relayTestFailureText(e.failure)}', good: false, syncError: null);
    } catch (e, st) {
      logError(_log, 'sync.saveFailed', e, st, fields: {'type': e.runtimeType.toString()});
      result = (text: "Not saved. Can't reach the relay", good: false, syncError: null);
    }
    if (!mounted) return;
    if (url != null && widget.wc.relayUrl != null) _address.text = widget.wc.relayUrl.toString();
    setState(() {
      _saving = false;
      _showToken = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final hasRelay = wc.relayUrl != null;
    final last = wc.lastSync;
    final status = syncStatusLine(caughtUp: wc.syncCaughtUp, waiting: wc.syncWaiting);
    return Panel(children: [
      const SectionHead('Sync'),
      Explainer(wc, 'sync',
          'Changes are encrypted on this device and sent through your own relay, a small server at home. Only devices with your wallet key can read them.'),
      TextField(
        key: const ValueKey('relayAddress'),
        controller: _address,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onChanged: (_) => setState(() {
          _addressError = null;
          _result = null;
        }),
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: 'Relay address',
          hintText: 'http://homeserver:8787',
          errorText: _addressError,
          errorMaxLines: 3,
        ),
      ),
      TextField(
        key: const ValueKey('relayCreateToken'),
        controller: _token,
        obscureText: !_showToken,
        enableSuggestions: false,
        autocorrect: false,
        onChanged: (_) => setState(() => _result = null),
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: 'Creation token (only if the relay asks)',
          helperText: 'Kept on this device only. Never synced.',
          helperMaxLines: 2,
          suffixIcon: IconButton(
            key: const ValueKey('relayCreateTokenReveal'),
            tooltip: _showToken ? 'Hide token' : 'Show token',
            icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showToken = !_showToken),
          ),
        ),
      ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton(
            key: const ValueKey('relaySave'),
            onPressed: wc.syncing || _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save relay')),
        Tooltip(
          message: hasKeyboard ? 'Sync now (F5)' : '',
          child: OutlinedButton(
              key: const ValueKey('syncNow'),
              style: accentOutlined(context),
              onPressed: !hasRelay || wc.syncing || wc.deviceStop == DeviceStop.revoked
                  ? null
                  : () {
                      logNav('sync.pressed');
                      wc.syncNow();
                    },
              child: Text(wc.syncing ? 'Syncing…' : 'Sync now')),
        ),
      ]),
      if (wc.relayFingerprintText != null)
        Muted('Relay fingerprint ${wc.relayFingerprintText}. It should read the same on every device.',
            key: const ValueKey('relayFingerprint')),
      if (_result != null) StatusLabel(key: const ValueKey('relaySaveResult'), good: _result!.good, text: _result!.text),
      if (hasRelay && WalletController.relayAddressIssue(wc.relayUrl.toString()) == RelayAddressIssue.needsHttps)
        const StatusLabel(key: ValueKey('relayNeedsHttps'), good: false, text: storedAddressNeedsHttpsText),
      if (!hasRelay)
        const Muted('No relay set: nothing is sent or received. The wallet works without it.')
      else ...[
        DeviceStopNotice(wc: wc),
        if (wc.syncError != null && wc.syncError != _result?.syncError)
          StatusLabel(key: const ValueKey('syncError'), good: false, text: wc.syncError!)
        else if (wc.syncError == null && last != null)
          StatusLabel(key: const ValueKey('syncStatus'), good: status.good, text: status.text),
        if (last != null) Muted('Last sync ${clockText(last)}'),
        if (wc.syncRelayBytes != null && wc.syncRelayMaxBytes != null)
          Muted('${_size(wc.syncRelayBytes!)} of ${_size(wc.syncRelayMaxBytes!)} used on the relay', key: const ValueKey('relayUsage')),
        if (wc.syncRelayChanged)
          _Info(
              key: const ValueKey('relayChanged'),
              text: relayChangedText,
              okKey: const ValueKey('relayChangedOk'),
              onOk: () => wc.dismissSyncNotice(relayChanged: true)),
        if (wc.syncDeviceIdInUse)
          _Info(
              key: const ValueKey('deviceIdInUse'),
              text: deviceIdInUseText,
              okKey: const ValueKey('deviceIdInUseOk'),
              onOk: () => wc.dismissSyncNotice(relayChanged: false)),
        if (wc.syncClockDrift) const StatusLabel(key: ValueKey('clockDrift'), good: false, text: clockDriftText),
        if (wc.syncOtherKey) const StatusLabel(key: ValueKey('syncOtherKey'), good: false, text: otherKeyFileText),
        if (wc.syncConflictCount > 0) ...[
          StatusLabel(key: const ValueKey('syncDevicesDisagree'), good: false, text: devicesConflictText(wc.syncConflictCount)),
          OutlinedButton(
              key: const ValueKey('syncChooseValues'),
              onPressed: () => openConflicts(context, wc),
              child: const Text('Choose the right values')),
        ] else if (wc.syncDevicesDisagree) ...[
          const StatusLabel(key: ValueKey('syncDevicesDisagree'), good: false, text: devicesDisagreeText),
          OutlinedButton(
              key: const ValueKey('syncDisagreeLogs'),
              onPressed: () => wc.openSettings(SettingsSection.diagnostics, via: 'syncDisagree'),
              child: const Text('Open Diagnostics')),
        ],
        if (wc.syncBlobsUnsupported)
          const StatusLabel(key: ValueKey('blobsUnsupported'), good: false, text: blobsUnsupportedText)
        else if (wc.syncBlobsWaiting > 0)
          StatusLabel(key: const ValueKey('blobsWaiting'), good: false, text: blobsWaitingText(wc.syncBlobsWaiting)),
        for (final f in wc.syncBlockedFiles) _BlockedFileRow(wc: wc, row: blockedRowOf(f, wc.now)),
        if (wc.syncBadFiles > wc.syncBlockedFiles.length)
          StatusLabel(
              good: false,
              text: wc.syncBadFiles - wc.syncBlockedFiles.length == 1
                  ? '1 sync file could not be read. It was skipped and will be tried again.'
                  : '${wc.syncBadFiles - wc.syncBlockedFiles.length} sync files could not be read. They were skipped and will be tried again.'),
      ],
      if (hasRelay) SyncDevicesBlock(wc: wc),
      RecentChanges(wc: wc),
      if (!isWeb)
        OutlinedButton.icon(
            key: const ValueKey('showKey'), icon: const Icon(Icons.key), label: const Text('Show wallet key'), onPressed: widget.onShowKey),
    ]);
  }
}

/// A neutral line with an info icon (state is never colour alone), optionally with a small OK that dismisses it.
class _Info extends StatelessWidget {
  final String text;
  final Key? okKey;
  final VoidCallback? onOk;
  const _Info({super.key, required this.text, this.okKey, this.onOk});
  @override
  Widget build(BuildContext context) {
    final line = Text.rich(
      TextSpan(children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(padding: const EdgeInsets.only(right: 5), child: Icon(Icons.info_outline, size: 16, color: context.c.muted)),
        ),
        TextSpan(text: text),
      ]),
      style: TextStyle(fontSize: BwType.metaSize, color: context.c.muted, height: 1.4),
    );
    if (onOk == null) return line;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      line,
      TextButton(key: okKey, onPressed: onOk, child: const Text('OK')),
    ]);
  }
}

/// One blocked peer file (KL): what is wrong, when its device last synced, and (only when the device is gone) "Skip damaged file".
class _BlockedFileRow extends StatelessWidget {
  const _BlockedFileRow({required this.wc, required this.row});
  final WalletController wc;
  final BlockedRow row;

  Future<void> _skip(BuildContext context) async {
    final short = row.file.short;
    logNav('sync.skipAsk');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(blockedSkipTitle),
        content: Text(blockedSkipConfirmText(short)),
        actions: [
          TextButton(key: const ValueKey('skipBlockedCancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('skipBlockedConfirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip file')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final problem = wc.skipBlocked(row.file);
    if (problem != null) {
      toast(context, problem);
      return;
    }
    toast(context, blockedSkippedToast);
    await wc.syncNow(trigger: 'skip');
  }

  @override
  Widget build(BuildContext context) {
    final f = row.file;
    return Column(
      key: ValueKey('blocked:${f.short}-${f.file}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatusLabel(good: false, text: blockedFileText(f.short)),
        if (row.seen != null) Muted(row.seen!),
        if (row.hint != null) Muted(row.hint!),
        if (row.canSkip)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: OutlinedButton(
                key: ValueKey('skipBlocked:${f.short}-${f.file}'), onPressed: () => _skip(context), child: const Text('Skip damaged file')),
          ),
      ],
    );
  }
}
