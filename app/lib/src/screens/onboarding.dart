import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../logging.dart';
import '../widgets/common.dart';

final _log = Logger('bw.app');

/// First run: create a new wallet (new key) or join an existing one with its key.
class OnboardingScreen extends StatefulWidget {
  final WalletController wc;
  const OnboardingScreen({super.key, required this.wc});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final keyText = TextEditingController();
  bool joining = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    AppLog.setScreen('onboarding');
    logNav('onboarding.show');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
                padding: const EdgeInsets.all(20),
                shrinkWrap: true,
                children: gapped([
                  const Row(children: [
                    LedgerLogo(),
                    SizedBox(width: 10),
                    Flexible(child: Heading('Budget Wallet', size: 24)),
                  ]),
                  const Muted(
                      'Your money, on your devices. Everything is stored here first and works offline. Sync between your phone and computer is encrypted with a key only your devices have.',
                      size: 14.5),
                  if (!joining) ...[
                    if (error != null) StatusLabel(good: false, text: error!),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: busy ? null : _create,
                      child: const Text('Start a new wallet', style: TextStyle(fontSize: 16)),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: () {
                        logNav('onboarding.join');
                        setState(() => joining = true);
                      },
                      child: const Text('Join my wallet from another device'),
                    ),
                  ] else ...[
                    const Muted('On a device that already has your wallet, open Plan › Show wallet key, then type or paste the key here.'),
                    TextField(
                        controller: keyText,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(labelText: 'Wallet key', hintText: 'BW1-…')),
                    if (error != null) StatusLabel(good: false, text: error!),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: busy ? null : _join,
                      child: const Text('Join wallet', style: TextStyle(fontSize: 16)),
                    ),
                    TextButton(onPressed: () => setState(() => joining = false), child: const Text('Back')),
                  ],
                ])),
          ),
        ),
      ),
    );
  }

  Future<void> _create() async {
    logNav('onboarding.create');
    setState(() => busy = true);
    try {
      await widget.wc.createWallet();
    } catch (e, st) {
      logError(_log, 'wallet.create.failed', e, st, level: Level.SEVERE);
      if (mounted) {
        setState(() {
          busy = false;
          error = "Couldn't save the wallet key on this device: $e";
        });
      }
    }
  }

  Future<void> _join() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.wc.joinWallet(keyText.text);
    } catch (e, st) {
      // Key errors are fixed texts (typo, too short, …); the typed key is never logged.
      logError(_log, 'wallet.join.failed', e, st, fields: {'chars': keyText.text.length});
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString();
        });
      }
    }
  }
}
