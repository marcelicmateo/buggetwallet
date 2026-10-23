import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

final _log = Logger('bw.app');

/// "Forget this browser" (web only): confirms, then deletes the wallet database and the stored key in this browser.
/// The app then shows the first screen again. Pops with `'forgotten'`, or null when cancelled.
class ForgetBrowserSheet extends StatefulWidget {
  final WalletController wc;
  const ForgetBrowserSheet({super.key, required this.wc});
  @override
  State<ForgetBrowserSheet> createState() => _ForgetBrowserSheetState();
}

class _ForgetBrowserSheetState extends State<ForgetBrowserSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _forget() async {
    logNav('forget.confirm');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.wc.forgetBrowser();
      if (mounted) Navigator.pop(context, 'forgotten');
    } catch (e, st) {
      logError(_log, 'forget.failed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't clear everything in this browser. Close other tabs of this app and try again.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...gapped([
          const Heading('Forget this browser?', size: BwType.headingSize),
          const Text('This deletes the wallet and the key stored in this browser. A backup file or another device is not touched.'),
          const Muted('Without a backup file, the data in this browser is gone for good. Older wallet copies kept aside stay.'),
          if (_error != null) StatusLabel(good: false, text: _error!),
          FilledButton(
            key: const ValueKey('forgetConfirm'),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin), backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: _busy ? null : _forget,
            child: Text(_busy ? 'Deleting…' : 'Delete everything here'),
          ),
          OutlinedButton(
            key: const ValueKey('forgetCancel'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ]),
      ]);
}

/// Opens [ForgetBrowserSheet]; true when the browser was forgotten.
Future<bool> confirmForgetBrowser(BuildContext context, WalletController wc) async {
  logNav('forget.pressed');
  final r = await showSheet<String>(context, ForgetBrowserSheet(wc: wc));
  return r == 'forgotten';
}
