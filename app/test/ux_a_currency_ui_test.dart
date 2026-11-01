// UX-A: the one currency picker (search, wallet currency and the ones in use on top), the wallet-currency choice in Settings › Accounts,
// the offer after an import, the rate form for a coin and a JPY payment row. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/accounts_panel.dart';
import 'package:budget_wallet/src/screens/currencies_panel.dart';
import 'package:budget_wallet/src/screens/currency_offer.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart' show pumpApp;

final day = DateTime(2026, 10, 20, 12);

WalletController wallet() => seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => day);

NormalizedTransaction row(String date, int cents, String currency, String desc) => NormalizedTransaction(
    id: transactionId(date, cents, '$currency$desc', 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: currency,
    bankType: 'POS',
    description: desc);

/// [n] rows in [currency] (1,000 units each, on different days), SYNTHETIC.
void addRows(WalletController wc, String currency, int n, {int start = 1}) {
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    for (var i = 0; i < n; i++) row('2026-10-${(start + i).toString().padLeft(2, '0')}', -100000, currency, 'SYNTHETIC SHOP $i'),
  ]));
  wc.reload();
}

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> pumpHome(WidgetTester t, Widget child, {Size size = const Size(400, 900), double scale = 1}) =>
    pumpApp(t, child, size: size, textScale: scale);

Widget panel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: AccountsPanel(wc: wc))));

Future<void> tap(WidgetTester t, String key) async {
  final f = k(key);
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4));

void main() {
  tearDown(() {
    walletCurrencyCode = 'EUR';
    numberStyle = NumberStyle.point;
  });

  test('a JPY wallet reads yen from its first frame: the controller sets the wallet currency when it is built and reloads', () {
    final repo = WalletRepo.inMemory();
    repo.setWalletCurrency('JPY');
    expect(walletCurrencyCode, 'EUR');
    final wc = seamedController(repo, key: VaultKey.generate(), clock: () => day);
    expect(walletCurrencyCode, 'JPY', reason: 'before any notification');
    expect(parseMoney('10.5'), isNull);
    expect(parseMoney('1000'), 100000);
    wc.repo.setWalletCurrency('USD'); // another device changed it, then a reload
    wc.reload();
    expect(walletCurrencyCode, 'USD');
    expect(parseMoney('10.5'), 1050);
    wc.dispose();
  });

  group('picker', () {
    testWidgets('the wallet currency is on top, then the ones in use, then all; each with code and name', (t) async {
      final wc = wallet();
      addRows(wc, 'USD', 3);
      await wc.addAccount(name: 'Travel', currency: 'GBP', opening: 100, openingDate: '2026-10-01');
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      expect(find.text('Choose a currency'), findsOneWidget);
      expect(find.text('YOUR CURRENCY'), findsOneWidget);
      expect(find.text('IN USE'), findsOneWidget);
      expect(find.text('ALL CURRENCIES'), findsOneWidget);
      double y(String c) => t.getTopLeft(k('currency:$c')).dy;
      expect(y('EUR'), lessThan(y('USD')));
      expect(y('USD'), lessThan(y('GBP')), reason: 'three payments beat one account');
      expect(find.descendant(of: k('currency:EUR'), matching: find.text('Euro')), findsOneWidget);
      expect(find.descendant(of: k('currency:EUR'), matching: find.byIcon(Icons.check)), findsOneWidget,
          reason: 'the chosen one is marked');
      await t.tapAt(const Offset(5, 5));
      await settle(t);
    });

    testWidgets('search by code or name, and a text nothing matches', (t) async {
      final wc = wallet();
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'yen');
      await t.pump();
      expect(k('currency:JPY'), findsOneWidget);
      expect(k('currency:EUR'), findsNothing);
      await t.enterText(k('currencySearch'), 'chf');
      await t.pump();
      expect(k('currency:CHF'), findsOneWidget);
      expect(find.text('YOUR CURRENCY'), findsNothing, reason: 'a search shows one list');
      await t.enterText(k('currencySearch'), 'qqqq');
      await t.pump();
      expect(k('currencyNone'), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
    });

    testWidgets('the wallet currency is fiat only: a coin is not offered', (t) async {
      final wc = wallet();
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'bitcoin');
      await t.pump();
      expect(k('currency:BTC'), findsNothing);
      expect(k('currencyNone'), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
    });

    testWidgets('fits at 320 dp with text 2.0', (t) async {
      final wc = wallet();
      await pumpHome(t, panel(wc), size: const Size(320, 700), scale: 2);
      await tap(t, 'walletCurrency');
      expect(t.takeException(), isNull);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
    });
  });

  group('wallet currency', () {
    testWidgets('choosing one sets it, says existing payments keep theirs, and numbers follow', (t) async {
      final wc = wallet();
      addRows(wc, 'EUR', 1, start: 18);
      await pumpHome(t, panel(wc));
      expect(find.textContaining('keep their own currency'), findsOneWidget);
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'jpy');
      await t.pump();
      await t.tap(k('currency:JPY'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      // Nothing changed yet: the sheet says what a switch does.
      expect(wc.settings.currency, 'EUR');
      expect(find.text('Your 1 payment in EUR keeps its currency. It counts in your totals only with a EUR→JPY rate.'), findsOneWidget);
      await tap(t, 'currencyOfferYes');
      expect(wc.settings.currency, 'JPY');
      expect(wc.currency, 'JPY');
      expect(walletCurrencyCode, 'JPY', reason: 'plain money fields now read yen');
      expect(find.descendant(of: k('walletCurrency'), matching: find.text('JPY · Yen')), findsOneWidget);
      // The old EUR payment is still EUR, and stays out of the totals until a rate is set.
      expect(wc.wholeTxs.single.tx.currency, 'EUR');
      expect(wc.period().foreignByCurrency.keys, ['EUR']);
      expect(wc.fxCurrencies().single.rate, isNull);
      await settle(t);
    });

    testWidgets('Switch and set the rate: the wallet changes, then the rate form of the old currency opens', (t) async {
      final wc = wallet();
      addRows(wc, 'EUR', 3, start: 16);
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'usd');
      await t.pump();
      await t.tap(k('currency:USD'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Your 3 payments in EUR keep their currency. They count in your totals only with a EUR→USD rate.'), findsOneWidget);
      await tap(t, 'currencySwitchRate');
      expect(wc.settings.currency, 'USD');
      expect(find.text('Rate for EUR'), findsOneWidget);
      await t.enterText(k('fxRateField'), '1.08');
      await tap(t, 'fxSave');
      expect(wc.settings.fxRates['EUR']!.rate, 1080000);
      expect(wc.period().foreignByCurrency, isEmpty, reason: 'counted now');
      await settle(t);
    });

    testWidgets('the sheet lists the rates that need setting again; none when there are none', (t) async {
      final wc = wallet();
      addRows(wc, 'EUR', 2, start: 16);
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'jpy');
      await t.pump();
      await t.tap(k('currency:JPY'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(k('currencySwitchRates'), findsNothing);
      await tap(t, 'currencyOfferNo');
      wc.setFxRate('USD', 920000);
      wc.setFxRate('GBP', 1150000);
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'jpy');
      await t.pump();
      await t.tap(k('currency:JPY'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Your rates for GBP, USD need setting again.'), findsOneWidget);
      await tap(t, 'currencyOfferNo');
      await settle(t);
    });

    testWidgets('Cancel in the sheet changes nothing', (t) async {
      final wc = wallet();
      addRows(wc, 'EUR', 3, start: 16);
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      await t.enterText(k('currencySearch'), 'usd');
      await t.pump();
      await t.tap(k('currency:USD'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await tap(t, 'currencyOfferNo');
      expect(wc.settings.currency, 'EUR');
      expect(wc.walletCurrencyOffer(), isNull);
      await settle(t);
    });

    testWidgets('closing the picker changes nothing', (t) async {
      final wc = wallet();
      await pumpHome(t, panel(wc));
      await tap(t, 'walletCurrency');
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.settings.currency, 'EUR');
      await settle(t);
    });
  });

  group('offer after an import', () {
    Widget host(WalletController wc) => Scaffold(
        body: Builder(
            builder: (context) =>
                TextButton(key: const ValueKey('go'), onPressed: () => offerWalletCurrency(context, wc), child: const Text('go'))));

    testWidgets('10 payments, 8 in JPY: the offer shows; Yes sets the wallet currency', (t) async {
      final wc = wallet();
      addRows(wc, 'JPY', 8);
      addRows(wc, 'EUR', 2, start: 18);
      expect(wc.walletCurrencyOffer(), 'JPY');
      await pumpHome(t, host(wc));
      await tap(t, 'go');
      expect(find.text("Most payments are in JPY. Use JPY as your wallet's currency?"), findsOneWidget);
      expect(find.text('Your 2 payments in EUR keep their currency. They count in your totals only with a EUR→JPY rate.'), findsOneWidget);
      await tap(t, 'currencyOfferYes');
      expect(wc.settings.currency, 'JPY');
      expect(wc.period().foreignByCurrency.keys, ['EUR'],
          reason: 'the 2 EUR payments are "Other currencies, not counted" until a rate is set');
      expect(wc.walletCurrencyOffer(), isNull, reason: 'it is the wallet currency now');
      await settle(t);
    });

    testWidgets('Not now is remembered for that currency', (t) async {
      final wc = wallet();
      addRows(wc, 'JPY', 10);
      await pumpHome(t, host(wc));
      await tap(t, 'go');
      await tap(t, 'currencyOfferNo');
      expect(wc.settings.currency, 'EUR');
      expect(wc.walletCurrencyOffer(), isNull);
      await tap(t, 'go');
      expect(k('currencyOffer'), findsNothing, reason: 'nothing to show a second time');
      await settle(t);
    });

    testWidgets('too few payments or a mixed wallet: no offer, nothing shown', (t) async {
      final wc = wallet();
      addRows(wc, 'JPY', 9);
      expect(wc.walletCurrencyOffer(), isNull, reason: 'fewer than 10 payments');
      addRows(wc, 'EUR', 4, start: 20);
      expect(wc.walletCurrencyOffer(), isNull, reason: '9 of 13 is below 80 %');
      await pumpHome(t, host(wc));
      await tap(t, 'go');
      expect(k('currencyOffer'), findsNothing);
      await settle(t);
    });
  });

  group('rate form', () {
    testWidgets('Add a rate: pick a currency, then the rate sheet; a coin takes a big rate', (t) async {
      final wc = wallet();
      wc.setFxRate('USD', 920000);
      await pumpHome(
          t, Scaffold(body: SingleChildScrollView(child: ListenableBuilder(listenable: wc, builder: (_, __) => CurrenciesPanel(wc: wc)))));
      await tap(t, 'fxAdd');
      await t.enterText(k('currencySearch'), 'btc');
      await t.pump();
      await t.tap(k('currency:BTC'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(k('fxSheet'), findsOneWidget);
      expect(find.text('Rate for BTC'), findsOneWidget);
      await t.enterText(k('fxRateField'), '2000000000');
      await tap(t, 'fxSave');
      expect(find.descendant(of: k('fxError'), matching: find.textContaining('at most 1,000,000,000')), findsOneWidget);
      await t.enterText(k('fxRateField'), '62000.5');
      await tap(t, 'fxSave');
      expect(wc.settings.fxRates['BTC']!.rate, 62000500000);
      await t.pump(const Duration(milliseconds: 400));
      expect(t.widget<Text>(k('fxLine:BTC')).data, contains('62,000.5000'));
      await settle(t);
    });

    testWidgets('a currency keeps its low limit and the wallet currency is not offered', (t) async {
      final wc = wallet();
      wc.setFxRate('USD', 920000);
      await pumpHome(
          t, Scaffold(body: SingleChildScrollView(child: ListenableBuilder(listenable: wc, builder: (_, __) => CurrenciesPanel(wc: wc)))));
      await tap(t, 'fxAdd');
      await t.enterText(k('currencySearch'), 'eur');
      await t.pump();
      expect(k('currency:EUR'), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 400));
      await tap(t, 'fxEdit:USD');
      await t.enterText(k('fxRateField'), '2000000');
      await tap(t, 'fxSave');
      expect(find.descendant(of: k('fxError'), matching: find.textContaining('at most 1,000,000.')), findsOneWidget);
      await settle(t);
    });
  });

  group('JPY payment row', () {
    test('a row in another currency without a rate is not a "top place" of the wallet currency', () {
      final wc = wallet();
      addRows(wc, 'JPY', 2, start: 10);
      expect(wc.spending('2026-10').topPlaces, isEmpty, reason: 'it is "not counted", so it is not listed as euros either');
      wc.setFxRate('JPY', 6500);
      expect(wc.spending('2026-10').topPlaces, isNotEmpty, reason: 'with a rate it counts, converted');
    });

    testWidgets('no decimals, yen sign, signed', (t) async {
      final wc = wallet();
      addRows(wc, 'JPY', 1);
      await pumpHome(t, Scaffold(body: TxTile(t: wc.txs.single, currency: 'EUR')));
      expect(find.text('−1,000 ¥'), findsOneWidget);
      expect(find.textContaining('.00'), findsNothing);
      await settle(t);
    });
  });
}
