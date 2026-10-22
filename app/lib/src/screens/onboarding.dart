import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../key_store.dart' show minPassphraseLength;
import '../logging.dart';
import '../platform.dart';
import '../widgets/common.dart';

final _log = Logger('bw.app');

/// First run: create a new wallet (new key) or join an existing one with its key. In a browser a passphrase step follows:
/// the key is stored in this browser wrapped with it.
class OnboardingScreen extends StatefulWidget {
  final WalletController wc;
  const OnboardingScreen({super.key, required this.wc});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final keyText = TextEditingController();
  final relayText = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool joining = false;

  /// Web: choosing the passphrase for a new wallet (`create`) or for the key just typed (`join`); null = not on that step.
  String? _passphraseFor;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    AppLog.setScreen('onboarding');
    logNav('onboarding.show');
  }

  @override
  void dispose() {
    keyText.dispose();
    relayText.dispose();
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
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
                  Muted(
                      isWeb
                          ? 'Your money, kept in this browser. It syncs only with your own relay, encrypted with a key only your devices have. Save a backup file from Plan now and then.'
                          : 'Your money, on your devices. Everything is stored here first and works offline. Sync goes through your own relay, encrypted with a key only your devices have.',
                      size: 14.5),
                  if (widget.wc.hasUnopenedDb)
                    const Row(key: ValueKey('olderWalletNotice'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.info_outline, size: 18),
                      SizedBox(width: 8),
                      Expanded(child: Muted('An older wallet is on this device. Join with its key to open it.', size: 14.5)),
                    ]),
                  if (_passphraseFor != null)
                    ..._passphraseStep()
                  else if (!joining) ...[
                    if (error != null) StatusLabel(good: false, text: error!),
                    FilledButton(
                      key: const ValueKey('startWallet'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: busy ? null : (isWeb ? () => _askPassphrase('create') : _create),
                      child: const Text('Start a new wallet', style: TextStyle(fontSize: 16)),
                    ),
                    OutlinedButton(
                      key: const ValueKey('joinStart'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: () {
                        logNav('onboarding.join');
                        setState(() => joining = true);
                      },
                      child: Text(isWeb ? 'Use my wallet key' : 'Join my wallet from another device'),
                    ),
                  ] else ...[
                    Muted(isWeb
                        ? 'On a device that already has your wallet, open Plan › Show wallet key, then type or paste the key here. You can then restore a backup file in Plan.'
                        : 'On a device that already has your wallet, open Plan › Show wallet key, then type or paste the key here.'),
                    TextField(
                        controller: keyText,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(labelText: 'Wallet key', hintText: 'BW1-…')),
                    TextField(
                        key: const ValueKey('relayAddress'),
                        controller: relayText,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                            labelText: 'Relay address (optional)',
                            hintText: 'http://homeserver:8787',
                            helperText: 'You can also set it later in Plan › Sync.',
                            helperMaxLines: 2)),
                    if (error != null) StatusLabel(good: false, text: error!),
                    FilledButton(
                      key: const ValueKey('joinWallet'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: busy ? null : (isWeb ? _checkKeyThenAsk : _join),
                      child: const Text('Join wallet', style: TextStyle(fontSize: 16)),
                    ),
                    TextButton(
                        key: const ValueKey('joinBack'), onPressed: () => setState(() => joining = false), child: const Text('Back')),
                  ],
                ])),
          ),
        ),
      ),
    );
  }

  /// Web: two fields and a short explanation. The passphrase protects the key in this browser only.
  List<Widget> _passphraseStep() => [
        const Heading(key: ValueKey('passphraseHeading'), 'Choose a passphrase', size: 18),
        const Muted('It protects your wallet key in this browser only. You type it once each time you open the app in a new tab. '
            'If you lose it, you can only start over here; a backup file or another device still has your data.'),
        TextField(
          key: const ValueKey('passphrase'),
          controller: _pass,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Passphrase', helperText: 'At least $minPassphraseLength characters'),
        ),
        TextField(
          key: const ValueKey('passphrase2'),
          controller: _pass2,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          onSubmitted: (_) => _savePassphrase(),
          decoration: const InputDecoration(labelText: 'Type it again'),
        ),
        if (error != null) StatusLabel(good: false, text: error!),
        FilledButton(
          key: const ValueKey('passphraseContinue'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: busy ? null : _savePassphrase,
          child: Text(_passphraseFor == 'create' ? 'Create wallet' : 'Join wallet', style: const TextStyle(fontSize: 16)),
        ),
        TextButton(
            key: const ValueKey('passphraseBack'),
            onPressed: busy
                ? null
                : () => setState(() {
                      _passphraseFor = null;
                      error = null;
                    }),
            child: const Text('Back')),
      ];

  void _askPassphrase(String forWhat) {
    logNav('onboarding.passphrase', {'for': forWhat});
    setState(() {
      _passphraseFor = forWhat;
      error = null;
    });
  }

  /// Web join: a typo in the key shows at once, before the passphrase is asked for.
  Future<void> _checkKeyThenAsk() async {
    if (_relayInvalid) {
      setState(() => error = _relayError);
      return;
    }
    try {
      await VaultKey.parse(keyText.text);
    } catch (e, st) {
      logError(_log, 'wallet.join.failed', e, st, fields: {'chars': keyText.text.length});
      if (mounted) setState(() => error = e.toString());
      return;
    }
    if (mounted) _askPassphrase('join');
  }

  Future<void> _savePassphrase() async {
    final p = _pass.text;
    if (p.length < minPassphraseLength) {
      setState(() => error = 'The passphrase needs at least $minPassphraseLength characters.');
      return;
    }
    if (p != _pass2.text) {
      setState(() => error = "The two passphrases don't match.");
      return;
    }
    setState(() => error = null);
    if (_passphraseFor == 'join') {
      await _join(passphrase: p);
    } else {
      await _create(passphrase: p);
    }
  }

  Future<void> _create({String? passphrase}) async {
    logNav('onboarding.create');
    setState(() => busy = true);
    try {
      await widget.wc.createWallet(passphrase: passphrase);
    } catch (e, st) {
      logError(_log, 'wallet.create.failed', e, st, level: Level.SEVERE);
      if (mounted) {
        setState(() {
          busy = false;
          error = isWeb ? "Couldn't save the wallet key in this browser." : "Couldn't save the wallet key on this device: $e";
        });
      }
    }
  }

  /// The typed relay address: null when the field is empty or not an address (see [_relayInvalid]).
  Uri? _relay() => WalletController.parseRelayAddress(relayText.text);

  bool get _relayInvalid => relayText.text.trim().isNotEmpty && _relay() == null;

  static const _relayError = 'Enter the relay address like http://homeserver:8787, or leave it empty.';

  Future<void> _join({String? passphrase}) async {
    if (_relayInvalid) {
      setState(() => error = _relayError);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.wc.joinWallet(keyText.text, passphrase: passphrase, relay: _relay());
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
