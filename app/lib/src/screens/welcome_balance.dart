import 'package:flutter/material.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The one optional step after a new wallet (and its save-key prompt): "How much cash do you have right now?". Add makes a Cash
/// account in the wallet's currency dated today; Skip (or closing the sheet) does nothing. Plan › Accounts adds it later.
Future<void> openWelcomeBalance(BuildContext context, WalletController wc) async {
  logNav('welcome.cash.show');
  final added = await showSheet<bool>(context, WelcomeBalanceSheet(wc: wc));
  logNav('welcome.cash.done', {'added': added == true});
}

class WelcomeBalanceSheet extends StatefulWidget {
  final WalletController wc;
  const WelcomeBalanceSheet({super.key, required this.wc});
  @override
  State<WelcomeBalanceSheet> createState() => _WelcomeBalanceSheetState();
}

class _WelcomeBalanceSheetState extends State<WelcomeBalanceSheet> {
  final _amount = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final cents = parseMoney(_amount.text);
    if (cents == null) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    final wc = widget.wc;
    try {
      await wc.addAccount(name: 'Cash', currency: wc.currency, opening: cents, openingDate: wc.today());
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('How much cash do you have right now?', key: ValueKey('welcomeHeading')),
      const SizedBox(height: 6),
      const Muted(
          'Optional. It starts a Cash account, so the app can show what you hold. You can add or change accounts later in Settings.'),
      const SizedBox(height: 12),
      MoneyField(
        fieldKey: const ValueKey('welcomeCash'),
        controller: _amount,
        autofocus: true,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
        decoration:
            InputDecoration(labelText: 'Cash', suffixText: currencySymbol(cur), hintText: amountHint, errorText: _error, errorMaxLines: 3),
      ),
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('welcomeAdd'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _add,
          child: const Text('Add cash')),
      const SizedBox(height: 4),
      TextButton(
          key: const ValueKey('welcomeSkip'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Skip')),
    ]);
  }
}
