// Stage P15 UI: other currencies counted at an owner-set rate. Plan › Currencies (rows, rate sheet, Edit / Remove + Undo), the totals
// and rows after a rate is set, ForeignNote's tap, rate parsing in both number styles. SYNTHETIC data on the fixed clock of
// `budgetWallet` (Tuesday 20 Oct 2026).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/currencies_panel.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart' show CategorizedTx, merchantKey;
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

NormalizedTransaction usd(String date, int cents) => NormalizedTransaction(
    id: transactionId(date, cents, 'SYNTHETIC USD SHOP', 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: 'USD',
    bankType: 'POS plaćanje',
    description: 'SYNTHETIC USD SHOP');

/// The budget wallet plus one 12.00 USD payment on 10 Oct.
WalletController fxWallet() {
  final wc = budgetWallet(budgets: false);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [usd('2026-10-10', -1200)]));
  wc.reload();
  return wc;
}

Widget panel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: CurrenciesPanel(wc: wc))));

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  tearDown(() => numberStyle = NumberStyle.point);

  group('rate text', () {
    test('both separators read the same, exactly from the digits', () {
      expect(parseFxRate('0,9240'), 924000);
      expect(parseFxRate('0.924'), 924000);
      expect(parseFxRate(' 0.9240 '), 924000);
      expect(parseFxRate('.5'), 500000);
      expect(parseFxRate('1'), 1000000);
      expect(parseFxRate('1.08'), 1080000);
      expect(parseFxRate('0.000001'), 1);
      expect(parseFxRate('1000'), 1000000000);
      expect(parseFxRate('1,234.5'), 1234500000, reason: 'the last separator is the decimal mark');
      expect(parseFxRate('0.1234567'), isNull, reason: 'a 7th decimal is refused, not rounded');
      expect(parseFxRate(''), isNull);
      expect(parseFxRate('abc'), isNull);
      expect(parseFxRate('1e3'), isNull);
      expect(parseFxRate('-1'), isNull);
    });

    test('shown with at least four decimals in the number style', () {
      expect(rateText(924000), '0.9240');
      expect(rateText(1234567), '1.234567');
      expect(rateText(1080000), '1.0800');
      expect(rateText(1), '0.000001');
      numberStyle = NumberStyle.comma;
      expect(rateText(924000), '0,9240');
    });
  });

  group('Plan › Currencies', () {
    testWidgets('hidden without other currencies; lists the one seen in the rows as "Not counted"', (t) async {
      await pumpApp(t, panel(budgetWallet(budgets: false)));
      expect(find.byKey(const ValueKey('currenciesPanel')), findsOneWidget);
      expect(find.byType(SectionHead), findsNothing);
      final wc = fxWallet();
      await pumpApp(t, panel(wc));
      expect(find.byType(SectionHead), findsOneWidget);
      expect(find.text('USD — Not counted'), findsOneWidget);
      expect(find.text('1 payment'), findsOneWidget);
      expect(find.byKey(const ValueKey('fxSet:USD')), findsOneWidget);
      expect(find.byKey(const ValueKey('fxEdit:USD')), findsNothing);
    });

    testWidgets('set a rate with a comma: totals change by the converted amount, the note drops the currency', (t) async {
      final wc = fxWallet();
      final before = wc.period();
      expect(before.foreignByCurrency, {'USD': -1200});
      await pumpApp(t, panel(wc), size: const Size(400, 1200));
      await tapKey(t, 'fxSet:USD');
      expect(find.byKey(const ValueKey('fxSheet')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('fxRateField')), '0,9240');
      await tapKey(t, 'fxSave');
      await settle(t);
      expect(wc.settings.fxRates['USD']!.rate, 924000);
      final after = wc.period();
      expect(after.spent, before.spent + 1109, reason: '12.00 USD at 0.9240 = 11.088 -> 11.09');
      expect(after.foreignByCurrency, isEmpty);
      expect(find.text('USD — ${rateSentence('USD', 924000, 'EUR')}, set ${shortDate(wc.settings.fxRates['USD']!.date)}'), findsOneWidget);
      expect(find.byKey(const ValueKey('fxEdit:USD')), findsOneWidget);
      expect(find.byKey(const ValueKey('fxRemove:USD')), findsOneWidget);
    });

    testWidgets('Today: the note drops the currency once it has a rate and its total counts', (t) async {
      final wc = fxWallet();
      Widget today() => ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: TodayScreen(wc: wc, openPlan: () {})));
      await pumpApp(t, today(), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('foreignNote')), findsOneWidget);
      wc.setFxRate('USD', 924000);
      await settle(t);
      expect(find.byKey(const ValueKey('foreignNote')), findsNothing);
      expect(find.textContaining('not counted'), findsNothing);
    });

    testWidgets('the same sheet in the comma style shows and reads the comma', (t) async {
      final wc = fxWallet();
      wc.setFxRate('USD', 924000);
      numberStyle = NumberStyle.comma;
      await pumpApp(t, panel(wc), size: const Size(400, 1200));
      expect(find.textContaining('1 \$ = 0,9240 €'), findsOneWidget);
      await tapKey(t, 'fxEdit:USD');
      expect(tester(t).controller.text, '0,9240', reason: 'the field starts with the saved rate');
      await t.enterText(find.byKey(const ValueKey('fxRateField')), '1,05');
      await tapKey(t, 'fxSave');
      await settle(t);
      expect(wc.settings.fxRates['USD']!.rate, 1050000);
    });

    testWidgets('Remove stops counting and Undo brings the rate back', (t) async {
      final wc = fxWallet();
      final before = wc.period().spent;
      wc.setFxRate('USD', 924000, date: '2026-10-10');
      await pumpApp(t, panel(wc), size: const Size(400, 1200));
      expect(wc.period().spent, before + 1109);
      await tapKey(t, 'fxRemove:USD');
      expect(wc.settings.fxRates, isEmpty);
      expect(wc.period().spent, before);
      expect(wc.period().foreignByCurrency, {'USD': -1200});
      expect(find.text('USD — Not counted'), findsOneWidget, reason: 'the currency is still seen in the rows');
      await t.tap(find.text('Undo'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.settings.fxRates['USD']!.rate, 924000);
      expect(wc.settings.fxRates['USD']!.date, '2026-10-10', reason: 'Undo keeps the date the rate was set');
      expect(wc.period().spent, before + 1109);
      await settle(t);
    });

    testWidgets('a currency with a rate and no payments still has a row; Remove drops it', (t) async {
      final wc = budgetWallet(budgets: false);
      wc.setFxRate('GBP', 1150000);
      await pumpApp(t, panel(wc), size: const Size(400, 1200));
      expect(find.text('GBP — ${rateSentence('GBP', 1150000, 'EUR')}, set ${shortDate(wc.settings.fxRates['GBP']!.date)}'), findsOneWidget);
      expect(find.text('no payments now'), findsOneWidget);
      await tapKey(t, 'fxRemove:GBP');
      expect(find.byKey(const ValueKey('fx:GBP')), findsNothing);
      await settle(t);
    });
  });

  group('the rate sheet refuses', () {
    Widget sheet(WalletController wc, String code) => Scaffold(body: SingleChildScrollView(child: FxSheet(wc: wc, code: code)));

    testWidgets('the wallet currency with core\'s text, and writes nothing', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, sheet(wc, 'EUR'));
      await t.enterText(find.byKey(const ValueKey('fxRateField')), '1');
      await t.tap(find.byKey(const ValueKey('fxSave')));
      await t.pump();
      expect(find.byKey(const ValueKey('fxError')), findsOneWidget);
      expect(find.textContaining('wallet currency', findRichText: true), findsOneWidget);
      expect(wc.settings.fxRates, isEmpty);
    });

    testWidgets('empty, a 7th decimal, zero and above 100 are refused; 100 itself is accepted', (t) async {
      final wc = fxWallet();
      await pumpApp(t, sheet(wc, 'USD'));
      for (final text in ['', 'abc', '0.1234567', '0', '100.000001', '5000']) {
        await t.enterText(find.byKey(const ValueKey('fxRateField')), text);
        await t.tap(find.byKey(const ValueKey('fxSave')));
        await t.pump();
        expect(find.byKey(const ValueKey('fxError')), findsOneWidget, reason: '"$text"');
        expect(wc.settings.fxRates, isEmpty, reason: '"$text"');
      }
      // Typing clears the message; a good value saves.
      await t.enterText(find.byKey(const ValueKey('fxRateField')), '100');
      await t.pump();
      expect(find.byKey(const ValueKey('fxError')), findsNothing);
      await t.tap(find.byKey(const ValueKey('fxSave')));
      await t.pump();
      expect(wc.settings.fxRates['USD']!.rate, 100000000, reason: 'the largest rate, 100 per unit');
      await settle(t);
    });
  });

  group('rows and notes', () {
    testWidgets('a converted payment shows both amounts on Spending', (t) async {
      final wc = fxWallet();
      wc.setFxRate('USD', 924000);
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 4000));
      expect(find.byKey(const ValueKey('txOriginal')), findsOneWidget);
      expect(find.text('${money(-1200, 'USD', decimals: 2, signed: true)} at 0.9240'), findsOneWidget);
      expect(find.text(money(-1109, 'EUR', decimals: 2, signed: true)), findsOneWidget);
      expect(find.byKey(const ValueKey('foreignNote')), findsNothing);
      await settle(t);
    });

    testWidgets('a payment without a rate has no second amount and keeps the note', (t) async {
      final wc = fxWallet();
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 4000));
      expect(find.byKey(const ValueKey('txOriginal')), findsNothing);
      expect(find.byKey(const ValueKey('foreignNote')), findsOneWidget);
      expect(find.text('Other currencies, not counted: ${moneyExact(1200, 'USD')} spent'), findsOneWidget);
    });

    testWidgets('the note is a tap to Settings › Currencies', (t) async {
      final wc = fxWallet();
      final opened = <int>[];
      wc.tabHook = (tab, via) => opened.add(tab);
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 4000));
      expect(find.text('Set a rate in Settings › Accounts'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('foreignSetRate')));
      await t.tap(find.byKey(const ValueKey('foreignSetRate')));
      await t.pump();
      expect(opened, [Tabs.settings]);
      expect(wc.settingsRequest.value, SettingsSection.currencies);
    });

    testWidgets('ForeignNote without a callback is the plain line', (t) async {
      await pumpApp(t, const Scaffold(body: ForeignNote({'USD': -500})));
      expect(find.byKey(const ValueKey('foreignSetRate')), findsNothing);
      expect(find.text('Other currencies, not counted: ${moneyExact(500, 'USD')} spent'), findsOneWidget);
    });
  });

  group('review fixes', () {
    testWidgets('a rate set against another wallet currency is listed as stale and setFxRate replaces it', (t) async {
      final wc = fxWallet();
      wc.setFxRate('USD', 924000);
      wc.repo.updateSettings({'currency': 'CHF'});
      wc.reload();
      expect(wc.settings.fxRates, isEmpty);
      expect(wc.settings.fxStale.keys, ['USD']);
      await pumpApp(t, panel(wc), size: const Size(400, 1200));
      expect(find.text('USD — Not counted'), findsOneWidget);
      expect(find.byKey(const ValueKey('fxStale:USD')), findsOneWidget);
      expect(find.text('Rate was set for EUR (set it again)'), findsOneWidget);
      expect(find.byKey(const ValueKey('fxSet:USD')), findsOneWidget);
      expect(find.byKey(const ValueKey('fxEdit:USD')), findsNothing);
      await tapKey(t, 'fxSet:USD');
      await t.enterText(find.byKey(const ValueKey('fxRateField')), '1.01');
      await tapKey(t, 'fxSave');
      await settle(t);
      expect(wc.settings.fxRates['USD']!.rate, 1010000);
      expect(wc.settings.fxStale, isEmpty);
      expect(find.byKey(const ValueKey('fxStale:USD')), findsNothing);
      expect(find.byKey(const ValueKey('fxEdit:USD')), findsOneWidget);
    });

    testWidgets('an unrated foreign row shows its own symbol, never the wallet\'s', (t) async {
      final wc = fxWallet();
      await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 4000));
      final tile = find.byWidgetPredicate((w) => w is TxTile && w.t.tx.currency == 'USD');
      expect(tile, findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text(money(-1200, 'USD', decimals: 2, signed: true))), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.textContaining('€')), findsNothing);
      await settle(t);
    });

    test('a converted payment never pays a bill: the period matches on the raw rows', () {
      final wc = budgetWallet(budgets: false);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        NormalizedTransaction(
            id: transactionId('2026-10-18', -6000, 'SYNTH POWER', 0),
            source: 'pbz',
            date: '2026-10-18',
            amountMinor: -6000,
            currency: 'USD',
            bankType: 'POS plaćanje',
            description: 'SYNTH POWER'),
      ]));
      wc.reload();
      final payee = merchantKey(wc.wholeTxs.firstWhere((c) => c.tx.currency == 'USD').tx);
      wc.addRecurringBill(
          label: 'Synth power', category: 'Bills & one-offs', amount: 3000, intervalDays: 365, firstDue: '2026-10-30', payee: payee);
      final before = wc.period();
      wc.setFxRate('USD', 500000); // 60.00 USD -> 30.00 EUR: the bill's amount
      final after = wc.period();
      expect(after.spent, before.spent + 3000, reason: 'the money counts at the converted amount');
      expect(after.reservedBills, before.reservedBills, reason: 'the USD row does not pay the EUR bill');
      expect(after.dueBills.map((b) => b.id), before.dueBills.map((b) => b.id));
      expect(before.dueBills, isNotEmpty);
    });
  });

  group('sheets work from the raw payment', () {
    Widget opener(WalletController wc, CategorizedTx t) => Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                key: const ValueKey('openTx'),
                onPressed: () => showSheet<String>(context, TxSheet(wc: wc, t: t)),
                child: const Text('open'))));

    testWidgets('Split from a converted row offers the bank amount and saves against it', (t) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [usd('2026-10-12', -10000)]));
      wc.reload();
      wc.setFxRate('USD', 924000);
      final converted = wc.txs.firstWhere((c) => c.originalAmount != null);
      expect(converted.amount, -9240, reason: 'the list row is the converted one');
      await pumpApp(t, opener(wc, converted), size: const Size(400, 2400));
      await tapKey(t, 'openTx');
      expect(find.text(money(-10000, 'USD', decimals: 2, signed: true)), findsOneWidget, reason: 'the header shows the bank amount, in \$');
      expect(find.byKey(const ValueKey('txCounted')), findsOneWidget);
      expect(find.text('Counts as ${money(-9240, 'EUR', decimals: 2, signed: true)} at 0.9240'), findsOneWidget);
      await tapKey(t, 'splitOpen');
      expect(t.widget<TextField>(find.byKey(const ValueKey('splitAmount:0'))).controller!.text, '100',
          reason: 'the bank amount, not 92.40');
      await t.enterText(find.byKey(const ValueKey('splitAmount:0')), '40');
      await t.enterText(find.byKey(const ValueKey('splitAmount:1')), '60');
      await t.pump();
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('splitSave'))).onPressed, isNotNull);
      await t.ensureVisible(find.byKey(const ValueKey('splitSave')));
      await t.tap(find.byKey(const ValueKey('splitSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final id = converted.tx.id;
      expect(wc.splitCount(id), 2);
      expect(wc.splitIsBroken(id), isFalse);
      expect(wc.storedSplit(id)!.fold<int>(0, (a, p) => a + p.amount), -10000);
      // The money counts the parts at the rate, adding up to the converted whole.
      expect(wc.partsOf(id).fold<int>(0, (a, p) => a + p.amount), -9240);
      await settle(t);
    });

    testWidgets('search shows a converted hit with its original line, an unrated one in its own currency', (t) async {
      final wc = fxWallet();
      Future<void> search() async {
        await pumpApp(t, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})),
            size: const Size(400, 1500));
        await t.enterText(find.byType(TextField).first, 'SYNTHETIC USD');
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
      }

      await search();
      var hit = find.byWidgetPredicate((w) => w is TxTile && w.t.tx.description.contains('SYNTHETIC USD'));
      expect(hit, findsOneWidget);
      expect(find.descendant(of: hit, matching: find.text(money(-1200, 'USD', decimals: 2, signed: true))), findsOneWidget);
      expect(find.byKey(const ValueKey('txOriginal')), findsNothing);
      wc.setFxRate('USD', 924000);
      await search();
      hit = find.byWidgetPredicate((w) => w is TxTile && w.t.tx.description.contains('SYNTHETIC USD'));
      expect(find.descendant(of: hit, matching: find.text(money(-1109, 'EUR', decimals: 2, signed: true))), findsOneWidget);
      expect(find.text('${money(-1200, 'USD', decimals: 2, signed: true)} at 0.9240'), findsOneWidget);
      await settle(t);
    });
  });

  group('layout', () {
    for (final (w, scale) in [(360.0, 1.0), (320.0, 2.0)]) {
      testWidgets('panel, sheet and rows fit at ${w.toInt()} dp, text ${scale}x', (t) async {
        final wc = fxWallet();
        wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
          NormalizedTransaction(
              id: transactionId('2026-10-12', -3050, 'SYNTHETIC GBP SHOP', 0),
              source: 'pbz',
              date: '2026-10-12',
              amountMinor: -3050,
              currency: 'GBP',
              bankType: 'POS plaćanje',
              description: 'SYNTHETIC GBP SHOP'),
        ]));
        wc.reload();
        wc.setFxRate('USD', 924000);
        await pumpApp(t, panel(wc), size: Size(w, 2000), textScale: scale);
        expect(find.text('GBP — Not counted'), findsOneWidget);
        expect(t.takeException(), isNull);
        await tapKey(t, 'fxEdit:USD');
        expect(t.takeException(), isNull);
        await t.enterText(find.byKey(const ValueKey('fxRateField')), '0');
        await t.tap(find.byKey(const ValueKey('fxSave')));
        await t.pump();
        expect(find.byKey(const ValueKey('fxError')), findsOneWidget);
        expect(t.takeException(), isNull);
        await settle(t);
      });

      testWidgets('Spending rows with both amounts fit at ${w.toInt()} dp, text ${scale}x', (t) async {
        final wc = fxWallet();
        wc.setFxRate('USD', 924000);
        await pumpApp(t, Scaffold(body: SpendingScreen(wc: wc)), size: Size(w, 4000), textScale: scale);
        expect(find.byKey(const ValueKey('txOriginal')), findsOneWidget);
        expect(t.takeException(), isNull);
        await settle(t);
      });
    }
  });
}

/// The rate field of the open sheet.
({TextField field, TextEditingController controller}) tester(WidgetTester t) {
  final f = t.widget<TextField>(find.byKey(const ValueKey('fxRateField')));
  return (field: f, controller: f.controller!);
}
