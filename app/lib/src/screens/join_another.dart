import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'key_backup.dart';
import 'onboarding.dart';

/// Plan › "Join another wallet…" (not on the web): the warning, then the join page over the open wallet.
/// Nothing changes until the join itself: "Cancel" in either step leaves the open wallet as it is. Continue is offered only once
/// this wallet's own key was saved (last-four check, `keyBackupConfirmed`): the old key is kept with the set-aside copy.
class JoinAnotherSheet extends StatelessWidget {
  final WalletController wc;
  const JoinAnotherSheet({super.key, required this.wc});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ...gapped([
            const Heading('Join another wallet?', size: BwType.headingSize),
            const Text(
                'Joining sets this wallet aside on this device. It is not deleted. Its data then stays only here, unless it was synced to another device or backed up.',
                key: ValueKey('joinAnotherWarning')),
            const Muted('The old wallet\'s data is kept on this device with its key; reopening it is not in the app yet.'),
            if (wc.keyBackupConfirmed)
              TextButton.icon(
                key: const ValueKey('joinAnotherShowKey'),
                icon: const Icon(Icons.key),
                label: const Text('Show this wallet\'s key'),
                onPressed: () => showWalletKey(context, wc),
              )
            else ...[
              const Muted('First save this wallet\'s key: type its last 4 characters to confirm.', key: ValueKey('joinAnotherSaveNote')),
              FilledButton.icon(
                key: const ValueKey('joinAnotherSaveKey'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
                icon: const Icon(Icons.key),
                label: const Text('Save this wallet\'s key'),
                onPressed: () => openKeyBackup(context, wc),
              ),
            ],
            if (wc.keyBackupConfirmed)
              FilledButton(
                key: const ValueKey('joinAnotherConfirm'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue to join'),
              ),
            OutlinedButton(
              key: const ValueKey('joinAnotherCancel'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ]),
        ]),
      );
}

/// Shows the warning; on "Continue" opens the join page ([OnboardingScreen] with `replaceCurrent`).
Future<void> joinAnotherWallet(BuildContext context, WalletController wc) async {
  logNav('joinAnother.pressed');
  final go = await showSheet<bool>(context, JoinAnotherSheet(wc: wc));
  if (go != true || !context.mounted) return;
  logNav('joinAnother.continue');
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    settings: const RouteSettings(name: 'joinAnother'),
    builder: (_) => OnboardingScreen(wc: wc, replaceCurrent: true),
  ));
}
