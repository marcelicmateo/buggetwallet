// UX-A: the account form by kind (add and edit), a coin account's value, built-in rules in the Rules panel, and the reasons rows of a
// bank file were left out. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/accounts_panel.dart';
import 'package:budget_wallet/src/screens/import_preview_sheet.dart';
import 'package:budget_wallet/src/screens/rules_panel.dart';
import 'package:budget_wallet/src/widgets/import_problems.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

final day = DateTime(2026, 10, 20, 12);

WalletController wallet() => seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => day);

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> tap(WidgetTester t, String key) async {
  final f = k(key);
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4));

Widget panel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: AccountsPanel(wc: wc))));

void main() {
  tearDown(() {
    walletCurrencyCode = 'EUR';
    numberStyle = NumberStyle.point;
  });

  group('account form: kind first, then only that kind\'s fields', () {
    testWidgets('cash: name, currency, balance, date; no bank fields', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountAdd');
      for (final kind in AccountKind.values) {
        expect(k('accountKind:${kind.name}'), findsOneWidget);
      }
      for (final text in ['Cash', 'Bank', 'Card / e-money', 'Savings', 'Investment', 'Crypto', 'Other']) {
        expect(find.text(text), findsWidgets);
      }
      expect(t.widget<ChoiceChip>(k('accountKind:cash')).selected, isTrue);
      expect(k('accountName'), findsOneWidget);
      expect(k('accountCurrency'), findsOneWidget);
      expect(k('accountOpening'), findsOneWidget);
      expect(k('accountDate'), findsOneWidget);
      expect(k('accountInstitution'), findsNothing);
      expect(k('accountSource'), findsNothing);
      expect(k('accountRate'), findsNothing);
      await settle(t);
    });

    testWidgets('bank, card and savings: institution and import format; investment and other: neither', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountAdd');
      for (final kind in ['bank', 'card', 'savings']) {
        await tap(t, 'accountKind:$kind');
        expect(k('accountInstitution'), findsOneWidget, reason: kind);
        expect(k('accountSource'), findsOneWidget, reason: kind);
      }
      for (final kind in ['investment', 'other', 'cash']) {
        await tap(t, 'accountKind:$kind');
        expect(k('accountInstitution'), findsNothing, reason: kind);
        expect(k('accountSource'), findsNothing, reason: kind);
      }
      await settle(t);
    });

    testWidgets('a savings account with an institution is saved with its kind', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountAdd');
      await tap(t, 'accountKind:savings');
      expect(t.widget<TextField>(k('accountName')).controller!.text, 'Savings', reason: 'the name follows the kind until edited');
      await t.enterText(k('accountInstitution'), 'Synthetic Bank');
      await t.enterText(k('accountOpening'), '250');
      await tap(t, 'accountSave');
      final a = wc.accountsAll().single;
      expect((a.kind, a.institution, a.source, a.opening), (AccountKind.savings, 'Synthetic Bank', null, 25000));
      expect(find.textContaining('Synthetic Bank'), findsWidgets, reason: 'the row names the institution');
      await settle(t);
    });

    testWidgets('crypto: coin (crypto only), its rate, balance in satoshis; the row shows its value in the wallet currency', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 2000));
      await tap(t, 'accountAdd');
      await tap(t, 'accountKind:crypto');
      expect(find.descendant(of: k('accountCurrency'), matching: find.text('BTC · Bitcoin')), findsOneWidget);
      expect(find.text('Coin'), findsOneWidget);
      expect(k('accountRate'), findsOneWidget);
      expect(k('accountSource'), findsNothing);
      // The coin picker offers coins only.
      await tap(t, 'accountCurrency');
      expect(k('currency:BTC'), findsOneWidget);
      expect(k('currency:EUR'), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(k('accountOpening'), '0.5');
      await t.enterText(k('accountRate'), '60000');
      await tap(t, 'accountSave');
      final a = wc.accountsAll().single;
      expect((a.kind, a.currency, a.opening), (AccountKind.crypto, 'BTC', 50000000));
      expect(wc.settings.fxRates['BTC']!.rate, 60000000000);
      expect(t.widget<Text>(k('accountHome:${a.id}')).data, contains('30,000'));
      expect(find.textContaining('0.50'), findsWidgets);
      await settle(t);
    });

    testWidgets('a crypto account without a rate says "Set a rate"', (t) async {
      final wc = wallet();
      final id =
          await wc.addAccount(name: 'Coins', kind: AccountKind.crypto, currency: 'BTC', opening: 10000000, openingDate: '2026-10-01');
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      expect(k('accountHome:$id'), findsNothing);
      expect(k('accountSetRate:$id'), findsOneWidget);
      await tap(t, 'accountSetRate:$id');
      await t.enterText(k('fxRateField'), '50000');
      await tap(t, 'fxSave');
      expect(t.widget<Text>(k('accountHome:$id')).data, contains('5,000'));
      await settle(t);
    });

    testWidgets('a coin balance with too many decimals is refused', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 2000));
      await tap(t, 'accountAdd');
      await tap(t, 'accountKind:crypto');
      await t.enterText(k('accountOpening'), '0.123456789');
      await tap(t, 'accountSave');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      expect(wc.accountsAll(), isEmpty);
      await t.enterText(k('accountOpening'), '1');
      await t.enterText(k('accountRate'), '1000000000000');
      await tap(t, 'accountSave');
      expect(find.textContaining('Enter a rate'), findsOneWidget);
      expect(wc.accountsAll(), isEmpty, reason: 'a bad rate saves nothing');
      await settle(t);
    });

    testWidgets('a JPY account is typed without decimals', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountAdd');
      await tap(t, 'accountCurrency');
      await t.enterText(k('currencySearch'), 'jpy');
      await t.pump();
      await t.tap(k('currency:JPY'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(t.widget<TextField>(k('accountOpening')).decoration!.hintText, '0');
      await t.enterText(k('accountOpening'), '10.5');
      await tap(t, 'accountSave');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      await t.enterText(k('accountOpening'), '15000');
      await tap(t, 'accountSave');
      expect(wc.accountsAll().single.opening, 1500000);
      await settle(t);
    });
  });

  group('account form: edit', () {
    testWidgets('kind, name, institution and import format change; the balance and currency do not', (t) async {
      final wc = wallet();
      final id = await wc.addAccount(name: 'Main', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-10-01');
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountEdit:$id');
      expect(find.text('Edit account'), findsOneWidget);
      expect(k('accountOpening'), findsNothing, reason: 'Correct balance changes the balance');
      expect(k('accountDate'), findsNothing);
      expect(t.widget<ChoiceChip>(k('accountKind:bank')).selected, isTrue, reason: 'a source without a kind reads as a bank');
      await tap(t, 'accountKind:savings');
      await t.enterText(k('accountName'), 'Rainy day');
      await t.enterText(k('accountInstitution'), 'Synthetic Bank');
      await tap(t, 'accountSave');
      final a = wc.accountsAll().single;
      expect((a.name, a.kind, a.institution, a.source, a.opening, a.currency),
          ('Rainy day', AccountKind.savings, 'Synthetic Bank', 'pbz', 10000, 'EUR'));
      await settle(t);
    });

    testWidgets('changing to cash drops the import format and the institution', (t) async {
      final wc = wallet();
      final id = await wc.addAccount(
          name: 'Main', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-10-01', institution: 'Synthetic Bank');
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountEdit:$id');
      await tap(t, 'accountKind:cash');
      await tap(t, 'accountSave');
      final a = wc.accountsAll().single;
      expect((a.kind, a.source, a.institution), (AccountKind.cash, null, null));
      await settle(t);
    });

    testWidgets('core\'s refusal shows in the form: a second cash account in the same currency', (t) async {
      final wc = wallet();
      await wc.addAccount(name: 'Cash', currency: 'EUR', opening: 100, openingDate: '2026-10-01');
      final id = await wc.addAccount(name: 'Other', kind: AccountKind.other, currency: 'EUR', opening: 100, openingDate: '2026-10-01');
      await pumpApp(t, panel(wc), size: const Size(400, 1600));
      await tap(t, 'accountEdit:$id');
      await tap(t, 'accountKind:cash');
      await tap(t, 'accountSave');
      expect(find.textContaining('There is already a cash account in EUR.'), findsOneWidget);
      expect(wc.accountsAll().firstWhere((a) => a.id == id).kind, AccountKind.other);
      await settle(t);
    });

    testWidgets('fits at 320 dp, text 2.0, for the crypto form', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(320, 900), textScale: 2);
      await tap(t, 'accountAdd');
      await tap(t, 'accountKind:crypto');
      expect(t.takeException(), isNull);
      await settle(t);
    });
  });

  group('rules: built-ins have the same menu as your own', () {
    Widget rulesPanel(WalletController wc) =>
        ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RulesPanel(wc: wc))));

    Future<void> menu(WidgetTester t, String id, String item) async {
      await tap(t, 'ruleMenu:$id');
      await t.tap(k(item));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
    }

    const wolt = 'builtIn:wolt';

    testWidgets('listed without "read-only"; the menu has Edit and Turn off, no Reset until edited', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 3000));
      expect(find.textContaining('read-only'), findsNothing);
      await tap(t, 'builtInToggle');
      expect(find.textContaining('Built in ·'), findsOneWidget);
      await tap(t, 'ruleMenu:$wolt');
      expect(k('ruleEdit:$wolt'), findsOneWidget);
      expect(k('ruleTurnOff:$wolt'), findsOneWidget);
      expect(k('ruleReset:$wolt'), findsNothing);
      expect(k('ruleUp:$wolt'), findsNothing);
      expect(k('ruleDelete:$wolt'), findsNothing);
      expect(k('ruleEdited:$wolt'), findsNothing);
      expect(k('ruleOff:$wolt'), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
      wc.dispose();
    });

    testWidgets('Turn off shows an "off" badge and Turn on; Undo puts it back', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 3000));
      await tap(t, 'builtInToggle');
      await menu(t, wolt, 'ruleTurnOff:$wolt');
      expect(wc.settings.builtInRuleOverrides[wolt]!.off, isTrue);
      expect(k('ruleOff:$wolt'), findsOneWidget);
      expect(find.descendant(of: k('ruleOff:$wolt'), matching: find.text('off')), findsOneWidget);
      await tap(t, 'ruleMenu:$wolt');
      expect(k('ruleOn:$wolt'), findsOneWidget);
      expect(k('ruleReset:$wolt'), findsNothing, reason: 'off only: Turn on is enough');
      await t.tap(k('ruleOn:$wolt'));
      await t.pump(const Duration(milliseconds: 400));
      expect(k('ruleOff:$wolt'), findsNothing);
      expect(wc.settings.builtInRuleOverrides[wolt], isNull);
      await settle(t);
      wc.dispose();
    });

    testWidgets('Edit: pattern and main tag; "edited" badge; Reset puts the original back', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 3000));
      await tap(t, 'builtInToggle');
      final original = wc.rulesList.firstWhere((r) => r.id == wolt);
      await menu(t, wolt, 'ruleEdit:$wolt');
      expect(k('builtInRuleHeading'), findsOneWidget);
      expect(t.widget<TextField>(k('builtInPattern')).controller!.text, original.text);
      await t.enterText(k('builtInPattern'), 'wolt|synthetic');
      await tap(t, 'builtInRuleSave');
      expect(k('builtInRuleHeading'), findsNothing, reason: 'the sheet closed');
      expect(wc.rulesList.firstWhere((r) => r.id == wolt).text, 'wolt|synthetic');
      expect(k('ruleEdited:$wolt'), findsOneWidget);
      await tap(t, 'ruleMenu:$wolt');
      expect(k('ruleReset:$wolt'), findsOneWidget);
      await t.tap(k('ruleReset:$wolt'));
      await t.pump(const Duration(milliseconds: 400));
      expect(k('ruleEdited:$wolt'), findsNothing);
      expect(wc.rulesList.firstWhere((r) => r.id == wolt).text, original.text);
      await settle(t);
      wc.dispose();
    });

    testWidgets('a pattern core refuses is said in the form and nothing is saved', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 3000));
      await tap(t, 'builtInToggle');
      await menu(t, wolt, 'ruleEdit:$wolt');
      await t.enterText(k('builtInPattern'), '(');
      await tap(t, 'builtInRuleSave');
      expect(k('builtInRuleError'), findsOneWidget);
      await t.enterText(k('builtInPattern'), '.*');
      await tap(t, 'builtInRuleSave');
      expect(find.textContaining('matches every payment'), findsOneWidget);
      await t.enterText(k('builtInPattern'), '');
      await tap(t, 'builtInRuleSave');
      expect(find.textContaining('Enter a pattern'), findsOneWidget);
      expect(wc.settings.builtInRuleOverrides, isEmpty);
      await settle(t);
      wc.dispose();
    });
  });

  group('rows left out of a file', () {
    final many = [for (var i = 0; i < 7; i++) 'Row ${i + 2}: the amount "-1$i.345" has more than 2 decimals'];

    testWidgets('few reasons show at once, with the count', (t) async {
      await pumpApp(t, Scaffold(body: ImportProblems(problems: many.take(2).toList(), invalid: 2)));
      expect(find.textContaining('2 rows left out', findRichText: true), findsOneWidget);
      expect(find.text(many[0]), findsOneWidget);
      expect(find.text(many[1]), findsOneWidget);
      expect(k('importProblemsToggle'), findsNothing);
    });

    testWidgets('a long list is collapsed behind one button', (t) async {
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: ImportProblems(problems: many, invalid: 9))));
      expect(find.textContaining('9 rows left out', findRichText: true), findsOneWidget, reason: 'two rows have no reason but are counted');
      expect(find.text(many[0]), findsNothing);
      expect(find.text('Show the reasons (7)'), findsOneWidget);
      await t.tap(k('importProblemsToggle'));
      await t.pump();
      expect(find.text(many[0]), findsOneWidget);
      expect(find.text(many[6]), findsOneWidget);
      await t.tap(k('importProblemsToggle'));
      await t.pump();
      expect(find.text(many[0]), findsNothing);
    });

    testWidgets('nothing to say: nothing shown; and it fits at 320 dp, text 2.0', (t) async {
      await pumpApp(t, const Scaffold(body: ImportProblems(problems: [], invalid: 0)));
      expect(k('importProblems'), findsNothing);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: ImportProblems(problems: many, invalid: 7))),
          size: const Size(320, 800), textScale: 2);
      expect(t.takeException(), isNull);
    });

    test('a bank file with a third decimal: the row is left out and the line carries the reason', () async {
      final wc = emptyWallet();
      const revolut = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
          'CARD_PAYMENT,Current,2026-10-03 10:00:00,2026-10-03 10:00:00,Synthetic shop,-5.00,0.00,EUR,COMPLETED,95.00\n'
          'CARD_PAYMENT,Current,2026-10-04 10:00:00,2026-10-04 10:00:00,Synthetic cafe,-12.345,0.00,EUR,COMPLETED,82.65\n';
      final lines = await wc.importFiles([('r.csv', Uint8List.fromList(utf8.encode(revolut)))]);
      final l = lines.single;
      expect(l.added, 1);
      expect(l.invalid, 1);
      expect(l.problems.single, contains('Row 3'));
      expect(l.problems.single, contains('more than 2 decimals'));
      expect(l.message, contains('1 unreadable row left out'));
    });

    testWidgets('the preview shows the reasons above the groups', (t) async {
      final wc = emptyWallet();
      const revolut = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
          'CARD_PAYMENT,Current,2026-10-03 10:00:00,2026-10-03 10:00:00,Synthetic shop,-5.00,0.00,EUR,COMPLETED,95.00\n'
          'CARD_PAYMENT,Current,2026-10-04 10:00:00,2026-10-04 10:00:00,Synthetic cafe,-12.345,0.00,EUR,COMPLETED,82.65\n';
      await wc.importFiles([('r.csv', Uint8List.fromList(utf8.encode(revolut)))], confirmPreview: (preview, bank) async {
        expect(wc.previewInvalid, 1);
        expect(wc.previewProblems.single, contains('Row 3'));
        await pumpApp(
            t,
            Scaffold(
                body: SingleChildScrollView(
                    child: ImportPreviewSheet(preview: preview, bank: bank, problems: wc.previewProblems, invalid: wc.previewInvalid))));
        expect(find.textContaining('1 row left out', findRichText: true), findsOneWidget);
        expect(find.textContaining('Row 3'), findsOneWidget);
        return <String>{};
      });
      expect(wc.previewProblems, isEmpty, reason: 'cleared once the preview is answered');
      await settle(t);
    });
  });
}
