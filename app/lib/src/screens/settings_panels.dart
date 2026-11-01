// Small Settings panels that used to be inline in the Plan tab (P5): Import, Weekly review day, Another wallet, This browser.
// Behaviour and keys are unchanged.
import 'package:flutter/material.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'forget_browser.dart';
import 'habits_panels.dart';
import 'import_flow.dart';
import 'join_another.dart';
import 'key_backup.dart';

/// Settings › Import: choose bank files; the result of the last import under the button.
class ImportPanel extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  const ImportPanel({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<ImportPanel> createState() => _ImportPanelState();
}

class _ImportPanelState extends State<ImportPanel> {
  bool importing = false;

  Future<void> _import() async {
    setState(() => importing = true);
    try {
      await pickAndImport(context, widget.wc, widget.chooser);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Panel(children: [
        const SectionHead('Import'),
        const Heading('Import bank exports', size: BwType.headingSize),
        const Muted(
            'PBZ: Excel export of the current account. Revolut: account statement as Excel or CSV. Any other CSV: say what its columns are once. Importing the same dates twice is safe; nothing gets doubled. Expenses you added by hand are matched to the bank rows.'),
        OutlinedButton.icon(
          style: accentOutlined(context),
          icon: importing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_file),
          key: const ValueKey('planImport'),
          label: const Text('Choose files'),
          onPressed: importing ? null : _import,
        ),
        SwitchListTile(
          key: const ValueKey('importPreviewAlways'),
          contentPadding: EdgeInsets.zero,
          value: widget.wc.importPreviewAlways,
          onChanged: (v) => setState(() => widget.wc.setImportPreviewAlways(v)),
          title: const Text('Always show', style: TextStyle(fontSize: BwType.bodySize)),
          subtitle: const Text('See what a file will add before it is imported. Off: files go straight in.'),
        ),
        for (final l in widget.wc.lastImport) StatusLabel(good: l.ok, text: '${l.file}: ${l.message}'),
      ]);
}

/// Settings › Weekly review day.
class ReviewDayPanel extends StatelessWidget {
  final WalletController wc;
  const ReviewDayPanel({super.key, required this.wc});
  @override
  Widget build(BuildContext context) => Panel(children: [
        const SectionHead('Weekly review'),
        ReviewDayRow(wc: wc),
      ]);
}

/// Settings › Sync › Another wallet (not on the web).
class AnotherWalletPanel extends StatelessWidget {
  final WalletController wc;
  const AnotherWalletPanel({super.key, required this.wc});
  @override
  Widget build(BuildContext context) => Panel(children: [
        const SectionHead('Another wallet'),
        const Muted('Have a wallet on another device? Join it here. This wallet is set aside on this device first, not deleted.'),
        OutlinedButton.icon(
          key: const ValueKey('joinAnother'),
          icon: const Icon(Icons.login),
          label: const Text('Join another wallet…'),
          onPressed: () => joinAnotherWallet(context, wc),
        ),
      ]);
}

/// Web only: the wallet key, and "Forget this browser".
class BrowserPanel extends StatelessWidget {
  final WalletController wc;
  const BrowserPanel({super.key, required this.wc});
  @override
  Widget build(BuildContext context) => Panel(children: [
        const SectionHead('This browser'),
        const Muted('The wallet is stored in this browser, on this computer only. Sync keeps it in step with your other devices; '
            'Backup moves it as a file. Clearing the browser data deletes it.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              key: const ValueKey('showKey'),
              icon: const Icon(Icons.key),
              label: const Text('Show wallet key'),
              onPressed: () => showWalletKey(context, wc)),
          OutlinedButton.icon(
              key: const ValueKey('forgetBrowser'),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Forget this browser'),
              onPressed: () => confirmForgetBrowser(context, wc)),
        ]),
      ]);
}
