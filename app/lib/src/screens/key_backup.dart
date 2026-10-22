import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controller.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// "Save your wallet key": why, the key as text and QR, Copy key, "I saved it" (type the last 4 characters) and Later.
/// Pops `'confirmed'` or `'later'` (null when closed another way). The key and the typed characters are never logged.
class KeyBackupSheet extends StatefulWidget {
  final WalletController wc;
  const KeyBackupSheet({super.key, required this.wc});
  @override
  State<KeyBackupSheet> createState() => _KeyBackupSheetState();
}

class _KeyBackupSheetState extends State<KeyBackupSheet> {
  String? _key;
  bool _asking = false;
  bool _wrong = false;
  bool _copied = false;
  final _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.wc.keyBackupShown();
    widget.wc.keyText().then((t) {
      if (mounted) setState(() => _key = t);
    });
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await widget.wc.copyKeyBackup();
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _confirm() async {
    final ok = await widget.wc.confirmKeyBackup(_typed.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, 'confirmed');
    } else {
      setState(() => _wrong = true);
    }
  }

  void _later() {
    widget.wc.snoozeKeyBackup();
    Navigator.pop(context, 'later');
  }

  @override
  Widget build(BuildContext context) {
    final key = _key;
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...gapped([
        const Heading('Save your wallet key', size: 18),
        const Text('Without this key, this wallet cannot be opened again on any device.'),
        if (isWeb) const Muted('The passphrase only unlocks this browser.'),
        if (key != null) ...[
          Center(
              child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(key: const ValueKey('keyQr'), data: key, size: 160))),
          SelectableText(key,
              key: const ValueKey('keyText'), textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: 14, color: c.ink)),
        ] else
          const SizedBox(height: 160),
        OutlinedButton.icon(
          key: const ValueKey('keyCopy'),
          icon: Icon(_copied ? Icons.check : Icons.copy),
          label: Text(_copied ? 'Key copied' : 'Copy key'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: key == null ? null : _copy,
        ),
        if (_copied) const Muted('The clipboard is cleared in 60 seconds.'),
        if (!_asking)
          FilledButton(
            key: const ValueKey('keySaved'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: key == null ? null : () => setState(() => _asking = true),
            child: const Text('I saved it'),
          )
        else ...[
          const Text('Type the last 4 characters of the key to confirm.'),
          TextField(
            key: const ValueKey('keyLast4'),
            controller: _typed,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            style: numStyle,
            onChanged: (_) {
              if (_wrong) setState(() => _wrong = false);
            },
            onSubmitted: (_) => _confirm(),
            decoration: const InputDecoration(labelText: 'Last 4 characters'),
          ),
          if (_wrong) const StatusLabel(good: false, text: "That doesn't match the end of your key."),
          FilledButton(
            key: const ValueKey('keyConfirm'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _confirm,
            child: const Text('Confirm'),
          ),
        ],
        TextButton(key: const ValueKey('keyLater'), onPressed: _later, child: const Text('Later')),
      ]),
    ]);
  }
}

/// Opens [KeyBackupSheet]; true when the owner confirmed the key.
Future<bool> openKeyBackup(BuildContext context, WalletController wc) async {
  logNav('keyBackup.open');
  final r = await showSheet<String>(context, KeyBackupSheet(wc: wc));
  return r == 'confirmed';
}

/// Today's notice row until the key is confirmed (the controller hides it while "Later" is in force).
class KeyBackupRow extends StatelessWidget {
  final WalletController wc;
  const KeyBackupRow({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Panel(key: const ValueKey('keyBackupRow'), color: c.warnBg, children: [
      Row(children: [
        Icon(Icons.key, size: 18, color: c.warnInk),
        const SizedBox(width: 8),
        Expanded(child: Text('Save your wallet key', style: TextStyle(fontWeight: FontWeight.w600, color: c.warnInk))),
      ]),
      Text('Without it, this wallet cannot be opened again.', style: TextStyle(color: c.warnInk, fontSize: 13)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton(key: const ValueKey('keySaveNow'), onPressed: () => openKeyBackup(context, wc), child: const Text('Save now')),
        TextButton(key: const ValueKey('keyRowLater'), onPressed: wc.snoozeKeyBackup, child: const Text('Later')),
      ]),
    ]);
  }
}
