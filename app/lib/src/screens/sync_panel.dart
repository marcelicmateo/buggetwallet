import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../logging.dart';
import '../platform.dart';
import '../sync_status.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _log = Logger('bw.sync');

/// Plan › Sync: the relay address, "Test connection", "Sync now", the state of the last sync, the devices the relay knows and
/// the wallet key. The address is never logged (only set / unset).
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
  bool _testing = false;

  /// The last "Test connection" answer: text and whether it was good; cleared when the address is edited.
  ({String text, bool good})? _testResult;

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

  Future<void> _save() async {
    final (ok, url) = _read();
    if (!ok) return;
    setState(() {
      _addressError = null;
      _testResult = null;
    });
    logNav('sync.relaySave', {'set': url != null}); // never the address
    await widget.wc.setRelay(url);
    if (mounted && url != null) _address.text = widget.wc.relayUrl.toString();
  }

  Future<void> _saveToken() async {
    logNav('sync.tokenSave', {'set': _token.text.trim().isNotEmpty}); // never the token
    await widget.wc.setRelayCreateToken(_token.text);
  }

  Future<void> _test() async {
    final (ok, typed) = _read();
    if (!ok) return;
    final url = typed ?? widget.wc.relayUrl;
    if (url == null) {
      setState(() => _addressError = 'Enter the relay address first.');
      return;
    }
    logNav('sync.test');
    setState(() {
      _addressError = null;
      _testing = true;
      _testResult = null;
    });
    ({String text, bool good}) result;
    try {
      await widget.wc.testRelay(url);
      result = (text: 'Relay reachable', good: true);
    } on TransportException catch (e) {
      result = (text: relayTestFailureText(e.failure), good: false);
    } catch (e, st) {
      logError(_log, 'sync.testFailed', e, st, fields: {'type': e.runtimeType.toString()});
      result = (text: "Can't reach the relay", good: false);
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final hasRelay = wc.relayUrl != null;
    final last = wc.lastSync;
    final status = syncStatusLine(caughtUp: wc.syncCaughtUp, waiting: wc.syncWaiting);
    final now = wc.now;
    return Panel(children: [
      const SectionHead('Sync'),
      const Muted(
          'Changes are encrypted on this device and sent through your own relay, a small server at home. Only devices with your wallet key can read them.'),
      TextField(
        key: const ValueKey('relayAddress'),
        controller: _address,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onChanged: (_) => setState(() {
          _addressError = null;
          _testResult = null;
        }),
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: 'Relay address',
          hintText: 'http://homeserver:8787',
          errorText: _addressError,
          errorMaxLines: 3,
        ),
      ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton(key: const ValueKey('relaySave'), onPressed: wc.syncing ? null : _save, child: const Text('Save address')),
        OutlinedButton(
            key: const ValueKey('relayTest'), onPressed: _testing ? null : _test, child: Text(_testing ? 'Testing…' : 'Test connection')),
        Tooltip(
          message: hasKeyboard ? 'Sync now (F5)' : '',
          child: OutlinedButton(
              key: const ValueKey('syncNow'),
              style: accentOutlined(context),
              onPressed: !hasRelay || wc.syncing
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
      if (_testResult != null) StatusLabel(key: const ValueKey('relayTestResult'), good: _testResult!.good, text: _testResult!.text),
      if (!hasRelay)
        const Muted('No relay set: nothing is sent or received. The wallet works without it.')
      else ...[
        if (wc.syncError != null)
          StatusLabel(key: const ValueKey('syncError'), good: false, text: wc.syncError!)
        else if (last != null)
          StatusLabel(key: const ValueKey('syncStatus'), good: status.good, text: status.text),
        if (last != null) Muted('Last sync ${clockText(last)}'),
        if (wc.syncRelayChanged) const _Info(key: ValueKey('relayChanged'), text: relayChangedText),
        if (wc.syncDeviceIdInUse) const _Info(key: ValueKey('deviceIdInUse'), text: deviceIdInUseText),
        if (wc.syncClockDrift) const StatusLabel(key: ValueKey('clockDrift'), good: false, text: clockDriftText),
        if (wc.syncBlobsUnsupported)
          const StatusLabel(key: ValueKey('blobsUnsupported'), good: false, text: blobsUnsupportedText)
        else if (wc.syncBlobsWaiting > 0)
          StatusLabel(key: const ValueKey('blobsWaiting'), good: false, text: blobsWaitingText(wc.syncBlobsWaiting)),
        if (wc.syncBadFiles > 0)
          StatusLabel(
              good: false,
              text: wc.syncBadFiles == 1
                  ? '1 sync file could not be read. It was skipped and will be tried again.'
                  : '${wc.syncBadFiles} sync files could not be read. They were skipped and will be tried again.'),
      ],
      TextField(
        key: const ValueKey('relayCreateToken'),
        controller: _token,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        onSubmitted: (_) => _saveToken(),
        decoration: const InputDecoration(
          labelText: 'Creation token (only if the relay asks)',
          helperText: 'Kept on this device only. Never synced.',
          helperMaxLines: 2,
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(key: const ValueKey('relayCreateTokenSave'), onPressed: _saveToken, child: const Text('Save token')),
      ),
      if (wc.syncDevices.isNotEmpty) ...[
        const Heading('Devices', size: 15),
        for (final d in wc.syncDevices)
          LineItem(
            d.isThis ? '${d.device} · this device' : d.device,
            '',
            sub: 'Last seen ${lastSeenText(d.lastSeen, now)}',
          ),
      ],
      if (!isWeb)
        OutlinedButton.icon(
            key: const ValueKey('showKey'), icon: const Icon(Icons.key), label: const Text('Show wallet key'), onPressed: widget.onShowKey),
    ]);
  }
}

/// A neutral line with an info icon (state is never colour alone).
class _Info extends StatelessWidget {
  final String text;
  const _Info({super.key, required this.text});
  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(padding: const EdgeInsets.only(right: 5), child: Icon(Icons.info_outline, size: 16, color: context.c.muted)),
          ),
          TextSpan(text: text),
        ]),
        style: TextStyle(fontSize: 13, color: context.c.muted, height: 1.4),
      );
}
