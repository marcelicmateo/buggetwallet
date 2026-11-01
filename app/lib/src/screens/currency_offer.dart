// Changing the wallet currency (UX-A): the offer after an import ("Most payments are in X") and the choice in Settings › Accounts both end
// here. The sheet says plainly what a switch does: only the setting changes; every earlier payment keeps its own currency and counts in the
// totals only at a rate the owner sets. The rate form can be opened right after the switch; the switch itself needs no rate.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart' show Logger, logError;

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../widgets/common.dart';
import '../widgets/currency_picker.dart' show currencyLabel;
import '../widgets/sheets.dart';
import 'currencies_panel.dart' show openFxSheet;

/// What the owner chose in the sheet.
enum SwitchChoice { switchOnly, switchAndRate, notNow }

/// The sentence about the payments that stay in [old]: "Your 12 payments in EUR keep their currency. They count in your totals only
/// with a EUR→JPY rate."
/// "Your rate for USD needs setting again." / "Your rates for USD, GBP need setting again.": the rates set against the old wallet currency.
String ratesNote(List<String> codes) =>
    codes.length == 1 ? 'Your rate for ${codes.single} needs setting again.' : 'Your rates for ${codes.join(', ')} need setting again.';

String switchNote(int n, String old, String code) => switch (n) {
      0 => 'Payments you add from now on are in $code.',
      1 => 'Your 1 payment in $old keeps its currency. It counts in your totals only with a $old→$code rate.',
      _ => 'Your $n payments in $old keep their currency. They count in your totals only with a $old→$code rate.',
    };

/// After an import: shows the offer once per currency when core's `prevalentCurrency` names one. Returns after it is settled.
Future<void> offerWalletCurrency(BuildContext context, WalletController wc) async {
  final code = wc.walletCurrencyOffer();
  if (code == null) return;
  logNav('currency.offer.show');
  await switchWalletCurrency(context, wc, code, offered: true);
}

/// Asks, then makes [code] the wallet currency; "Switch and set the rate" opens the rate form of the old currency afterwards.
/// [offered]: it came from the import offer, so "Not now" is remembered for [code] on this device.
Future<void> switchWalletCurrency(BuildContext context, WalletController wc, String code, {bool offered = false}) async {
  if (code == wc.currency) return;
  final old = wc.currency;
  final choice = await showSheet<SwitchChoice>(context, CurrencySwitchSheet(wc: wc, code: code, offered: offered));
  if (choice == null || choice == SwitchChoice.notNow) {
    if (offered && choice == SwitchChoice.notNow) wc.dismissWalletCurrencyOffer(code);
    return;
  }
  try {
    wc.setWalletCurrency(code);
  } catch (e, st) {
    logError(Logger('bw.accounts'), 'accounts.walletCurrency.failed', e, st);
    if (context.mounted) toast(context, e is ArgumentError ? e.message.toString() : 'Could not save. Try again.');
    return;
  }
  if (!context.mounted) return;
  if (choice == SwitchChoice.switchAndRate) {
    await openFxSheet(context, wc, old);
  } else {
    toast(context, 'Wallet currency is now $code');
  }
}

class CurrencySwitchSheet extends StatelessWidget {
  final WalletController wc;
  final String code;
  final bool offered;
  const CurrencySwitchSheet({super.key, required this.wc, required this.code, this.offered = false});

  @override
  Widget build(BuildContext context) {
    final old = wc.currency, n = wc.paymentCountIn(old);
    // Rates the owner set against the old wallet currency stop counting (core's fxStale): they need setting again.
    final rates = [
      for (final c in wc.settings.fxRates.keys)
        if (c != code) c
    ]..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Heading(offered ? "Most payments are in $code. Use $code as your wallet's currency?" : "Use $code as your wallet's currency?",
          key: const ValueKey('currencyOffer')),
      const SizedBox(height: 8),
      Muted(currencyLabel(code)),
      const SizedBox(height: 6),
      Text(switchNote(n, old, code), key: const ValueKey('currencySwitchNote')),
      if (rates.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(ratesNote(rates), key: const ValueKey('currencySwitchRates')),
      ],
      const SizedBox(height: 14),
      if (n > 0) ...[
        FilledButton(
            key: const ValueKey('currencySwitchRate'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: () => Navigator.pop(context, SwitchChoice.switchAndRate),
            child: Text('Switch and set the $old→$code rate')),
        const SizedBox(height: 8),
      ],
      if (n > 0)
        OutlinedButton(
            key: const ValueKey('currencyOfferYes'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: () => Navigator.pop(context, SwitchChoice.switchOnly),
            child: const Text('Switch without a rate'))
      else
        FilledButton(
            key: const ValueKey('currencyOfferYes'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: () => Navigator.pop(context, SwitchChoice.switchOnly),
            child: Text('Switch to $code')),
      const SizedBox(height: 8),
      TextButton(
          key: const ValueKey('currencyOfferNo'),
          onPressed: () => Navigator.pop(context, SwitchChoice.notNow),
          child: Text(offered ? 'Not now' : 'Cancel')),
    ]);
  }
}
