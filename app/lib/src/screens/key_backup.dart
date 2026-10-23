import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../secure_window.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The key as a QR code first (what another device scans); the text sits behind "Show as text" so it is not on screen
/// by default. Keys: `keyQr`, `keyShowText` (button), `keyText` (the text, only while shown).
class KeyDisplay extends StatefulWidget {
  final String text;
  final double qrSize;

  /// Plan › Show wallet key lets the text be selected; the save-key sheet does not (its Copy key clears the clipboard later).
  final bool selectable;
  const KeyDisplay({super.key, required this.text, this.qrSize = 180, this.selectable = false});
  @override
  State<KeyDisplay> createState() => _KeyDisplayState();
}

class _KeyDisplayState extends State<KeyDisplay> {
  bool _text = false;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
          child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(key: const ValueKey('keyQr'), data: widget.text, size: widget.qrSize))),
      TextButton.icon(
        key: const ValueKey('keyShowText'),
        icon: Icon(_text ? Icons.visibility_off_outlined : Icons.visibility_outlined),
        label: Text(_text ? 'Hide text' : 'Show as text'),
        onPressed: () {
          logNav('key.text', {'shown': !_text});
          setState(() => _text = !_text);
        },
      ),
      if (_text && widget.selectable)
        SelectableText(widget.text,
            key: const ValueKey('keyText'), textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: 14, color: context.c.ink))
      else if (_text)
        Text(widget.text,
            key: const ValueKey('keyText'), textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: 14, color: context.c.ink)),
    ]);
  }
}

/// Plan › Show wallet key: the QR, the text behind a button, Copy and Done. On Android the window is secure while it is open.
Future<void> showWalletKey(BuildContext context, WalletController wc) async {
  logNav('dialog.open', {'dialog': 'walletKey'}); // the key itself is never logged
  final text = await wc.keyText();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => SecureWindow(
      child: AlertDialog(
        title: const Text('Wallet key'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Anyone with this key can read your wallet. Use it only to add your own devices.', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              KeyDisplay(text: text, selectable: true),
            ]),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('walletKeyCopy'),
            onPressed: () async {
              logNav('key.copied');
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) toast(context, 'Key copied');
            },
            child: const Text('Copy'),
          ),
          FilledButton(key: const ValueKey('walletKeyDone'), onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    ),
  );
}

/// "Save your wallet key": why, the key as QR (the text behind "Show as text"), Copy key, "I saved it" (type the last 4 characters) and Later.
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
    return SecureWindow(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...gapped([
        const Heading('Save your wallet key', size: 18),
        const Text('Without this key, this wallet cannot be opened again on any device.'),
        if (isWeb) const Muted('The passphrase only unlocks this browser.'),
        if (key != null) ...[
          KeyDisplay(text: key, qrSize: 160),
        ] else
          const SizedBox(height: 160),
        OutlinedButton.icon(
          key: const ValueKey('keyCopy'),
          icon: Icon(_copied ? Icons.check : Icons.copy),
          label: Text(_copied ? 'Key copied' : 'Copy key'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: key == null ? null : _copy,
        ),
        if (_copied) const Muted('Copy key clears the clipboard after 60 seconds. Clipboard history on some phones may keep it.'),
        if (!_asking)
          FilledButton(
            key: const ValueKey('keySaved'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
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
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _confirm,
            child: const Text('Confirm'),
          ),
        ],
        TextButton(key: const ValueKey('keyLater'), onPressed: _later, child: const Text('Later')),
      ]),
    ]));
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
