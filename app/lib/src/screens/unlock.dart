import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../key_store.dart' show WrongPassphrase;
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'forget_browser.dart';

final _log = Logger('bw.app');

/// Web: the wallet key is stored in this browser, wrapped with a passphrase. Type it once per tab session to open the wallet.
class UnlockScreen extends StatefulWidget {
  final WalletController wc;
  const UnlockScreen({super.key, required this.wc});
  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppLog.setScreen('unlock');
    logNav('unlock.show');
  }

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    logNav('unlock.pressed');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.wc.unlock(_pass.text);
    } on WrongPassphrase {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Wrong passphrase. Try again.';
        });
      }
    } catch (e, st) {
      // Never the passphrase; the type says what went wrong.
      logError(_log, 'unlock.failed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't open the wallet key stored in this browser.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => GatePage(children: [
        const Muted('Your wallet is locked. Type your passphrase to open it in this browser.', size: BwType.bodySize),
        TextField(
          key: const ValueKey('unlockPassphrase'),
          controller: _pass,
          obscureText: true,
          autofocus: true,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _unlock(),
          decoration: const InputDecoration(labelText: 'Passphrase'),
        ),
        if (_error != null) StatusLabel(good: false, text: _error!),
        FilledButton(
          key: const ValueKey('unlockButton'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
          onPressed: _busy ? null : _unlock,
          child: Text(_busy ? 'Opening…' : 'Unlock', style: const TextStyle(fontSize: BwType.headingSize)),
        ),
        TextButton(
          key: const ValueKey('unlockForget'),
          onPressed: _busy ? null : () => confirmForgetBrowser(context, widget.wc),
          child: const Text('Forget this browser'),
        ),
      ]);
}
