// Stage N2 UI: Plan › Accounts (balances, totals, add / rename / correct / delete + Undo, the duplicate line), Today's "Held" line and the
// welcome cash step. All data is SYNTHETIC (fixed clock, made-up amounts).
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/accounts_panel.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/welcome_balance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/plan_page.dart';
import 'support/wallet.dart';

final day = DateTime(2026, 10, 20, 12);

WalletController wallet() => WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => day);

NormalizedTransaction bankRow(String source, String date, int cents, {String currency = 'EUR', String desc = 'SYNTHETIC SHOP'}) =>
    NormalizedTransaction(
        id: transactionId(date, cents, '$source$desc', 0),
        source: source,
        date: date,
        amountMinor: cents,
        currency: currency,
        bankType: 'POS',
        description: desc);

/// A bank account (PBZ, EUR 1,000.00 on 1 Oct), cash (EUR 50.00), a Revolut USD account (80 USD) and one PBZ row after the opening.
Future<({String bank, String cash, String usd})> seed(WalletController wc) async {
  final bank = await wc.repo.addAccount(name: 'Bank 1', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-10-01');
  final cash = await wc.repo.addAccount(name: 'Cash', currency: 'EUR', opening: 5000, openingDate: '2026-10-01');
  final usd = await wc.repo.addAccount(name: 'Travel', source: 'revolut', currency: 'USD', opening: 8000, openingDate: '2026-10-01');
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [bankRow('pbz', '2026-10-05', -2550)]));
  wc.reload();
  return (bank: bank, cash: cash, usd: usd);
}

Widget panel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: AccountsPanel(wc: wc))));

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump(); // a sheet or dialog is built now
  await t.pump(const Duration(milliseconds: 400)); // and has slid in
}

void main() {
  group('balances and totals', () {
    testWidgets('a balance per account in its own currency, "as of" the last row or the opening, a total per currency', (t) async {
      final wc = wallet();
      final ids = await seed(wc);
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      Finder row(String id) => find.byKey(ValueKey('account:$id'));
      expect(find.descendant(of: row(ids.bank), matching: find.text(moneyExact(97450, 'EUR'))), findsOneWidget, reason: '1,000.00 - 25.50');
      expect(find.descendant(of: row(ids.bank), matching: find.textContaining('as of ${shortDate('2026-10-05')}')), findsOneWidget);
      expect(find.descendant(of: row(ids.cash), matching: find.text(moneyExact(5000, 'EUR'))), findsOneWidget);
      expect(find.descendant(of: row(ids.cash), matching: find.textContaining('as of ${shortDate('2026-10-01')}')), findsOneWidget,
          reason: 'no rows: the opening date');
      expect(find.descendant(of: row(ids.usd), matching: find.text(moneyExact(8000, 'USD'))), findsOneWidget);
      // One total per currency, never mixed.
      expect(find.descendant(of: find.byKey(const ValueKey('accountTotal:EUR')), matching: find.text(moneyExact(102450, 'EUR'))),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('accountTotal:USD')), matching: find.text(moneyExact(8000, 'USD'))),
          findsOneWidget);
      await settle(t);
    });

    testWidgets('no accounts: a plain note, no totals', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      expect(find.textContaining('No accounts yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('accountTotal:EUR')), findsNothing);
      await settle(t);
    });

    testWidgets('a sync duplicate shows the muted line and is not counted; Delete removes it', (t) async {
      final wc = wallet();
      final id = await wc.repo.addAccount(name: 'Cash', currency: 'EUR', opening: 5000, openingDate: '2026-10-01');
      wc.repo.applyRemote([
        Op(
            'account',
            'zzz-dup',
            {'name': 'Cash 2', 'source': null, 'currency': 'EUR', 'opening': 7000, 'opening_date': '2026-10-02', 'deleted': 0},
            Hlc(DateTime.now().millisecondsSinceEpoch + 60000, 0, 'peer').toString()),
      ]);
      wc.reload();
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      expect(find.byKey(ValueKey('account:$id')), findsOneWidget);
      expect(find.byKey(const ValueKey('accountDuplicate:zzz-dup')), findsOneWidget);
      expect(find.text('Cash 2: duplicate of Cash, not counted'), findsOneWidget);
      expect(
          find.descendant(of: find.byKey(const ValueKey('accountTotal:EUR')), matching: find.text(moneyExact(5000, 'EUR'))), findsOneWidget,
          reason: 'the duplicate adds nothing');
      await tapKey(t, 'accountDelete:zzz-dup');
      expect(find.byKey(const ValueKey('accountDuplicate:zzz-dup')), findsNothing);
      expect(wc.accountsAll().map((a) => a.id), [id]);
      expect(find.text('Removed'), findsOneWidget);
      expect(find.byKey(const ValueKey('toastUndo')), findsNothing, reason: 'a duplicate was never counted: no Undo');
      await settle(t);
    });
  });

  group('add', () {
    testWidgets('cash: name follows the type, the balance and date are saved exactly', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountAdd');
      expect(t.widget<TextField>(find.byKey(const ValueKey('accountName'))).controller!.text, 'Cash');
      await t.enterText(find.byKey(const ValueKey('accountOpening')), '12,34');
      await tapKey(t, 'accountSave');
      await t.pump(const Duration(milliseconds: 400));
      final a = wc.accountsAll().single;
      expect((a.name, a.source, a.currency, a.opening, a.openingDate), ('Cash', null, 'EUR', 1234, '2026-10-20'));
      expect(find.byKey(ValueKey('account:${a.id}')), findsOneWidget);
      expect(find.byKey(const ValueKey('accountSave')), findsNothing, reason: 'the sheet closed');
      await settle(t);
    });

    testWidgets('a bank: the type list holds the importer profiles and the name follows until edited', (t) async {
      final wc = wallet();
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountAdd');
      await tapKey(t, 'accountType');
      expect(find.text('PBZ'), findsOneWidget);
      expect(find.text('Revolut'), findsOneWidget);
      await t.tap(find.text('Revolut').last);
      await t.pump(const Duration(milliseconds: 400));
      expect(t.widget<TextField>(find.byKey(const ValueKey('accountName'))).controller!.text, 'Revolut');
      await t.enterText(find.byKey(const ValueKey('accountOpening')), '100');
      await tapKey(t, 'accountNegative'); // overdrawn
      await tapKey(t, 'accountSave');
      final a = wc.accountsAll().single;
      expect((a.source, a.opening), ('revolut', -10000));
      await settle(t);
    });

    testWidgets('refused values are said under the field and nothing is saved', (t) async {
      final wc = wallet();
      await wc.repo.addAccount(name: 'Cash', currency: 'EUR', opening: 100, openingDate: '2026-10-01');
      wc.reload();
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountAdd');
      // No amount.
      await tapKey(t, 'accountSave');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      // An empty name.
      await t.enterText(find.byKey(const ValueKey('accountOpening')), '5');
      await t.enterText(find.byKey(const ValueKey('accountName')), '   ');
      await tapKey(t, 'accountSave');
      expect(find.text('Give the account a name.'), findsOneWidget);
      // A 61-character name.
      await t.enterText(find.byKey(const ValueKey('accountName')), 'x' * 61);
      await tapKey(t, 'accountSave');
      expect(find.textContaining('limited to 60 characters'), findsOneWidget);
      // A second cash account in the same currency.
      await t.enterText(find.byKey(const ValueKey('accountName')), 'Cash again');
      await tapKey(t, 'accountSave');
      expect(find.textContaining('There is already a cash account in EUR.'), findsOneWidget);
      expect(find.byKey(const ValueKey('accountError')), findsOneWidget);
      // An amount over the limit is not a number here.
      await t.enterText(find.byKey(const ValueKey('accountOpening')), '99999999999999');
      await tapKey(t, 'accountSave');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      expect(wc.accountsAll().length, 1);
      await settle(t);
    });
  });

  group('rename, correct, delete', () {
    testWidgets('rename keeps the balance; an empty name is refused', (t) async {
      final wc = wallet();
      final ids = await seed(wc);
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountRename:${ids.cash}');
      await t.enterText(find.byKey(const ValueKey('accountName')), '');
      await tapKey(t, 'accountSave');
      expect(find.text('Give the account a name.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('accountName')), 'Wallet');
      await tapKey(t, 'accountSave');
      expect(wc.accountsAll().map((a) => a.name), contains('Wallet'));
      expect(wc.accountBalanceList().firstWhere((b) => b.account.id == ids.cash).balance, 5000);
      await settle(t);
    });

    testWidgets('Correct balance: the real balance today becomes the new opening and later rows add to it', (t) async {
      final wc = wallet();
      final ids = await seed(wc);
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountCorrect:${ids.bank}');
      expect(find.text('The real balance today is…'), findsOneWidget);
      expect(t.widget<TextField>(find.byKey(const ValueKey('accountCorrectAmount'))).controller!.text, '974.50', reason: 'prefilled');
      await t.enterText(find.byKey(const ValueKey('accountCorrectAmount')), '900,10');
      await tapKey(t, 'accountCorrectSave');
      final b = wc.accountBalanceList().firstWhere((b) => b.account.id == ids.bank);
      expect(b.balance, 90010);
      expect(b.account.openingDate, '2026-10-20');
      expect(
          find.descendant(of: find.byKey(ValueKey('account:${ids.bank}')), matching: find.text(moneyExact(90010, 'EUR'))), findsOneWidget);
      await settle(t);
    });

    testWidgets('Correct balance with a bad amount says so and changes nothing', (t) async {
      final wc = wallet();
      final ids = await seed(wc);
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountCorrect:${ids.bank}');
      await t.enterText(find.byKey(const ValueKey('accountCorrectAmount')), 'abc');
      await tapKey(t, 'accountCorrectSave');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      expect(wc.accountBalanceList().firstWhere((b) => b.account.id == ids.bank).balance, 97450);
      await settle(t);
    });

    testWidgets('Delete removes the row and the toast Undo brings it back', (t) async {
      final wc = wallet();
      final ids = await seed(wc);
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountDelete:${ids.cash}');
      expect(find.byKey(ValueKey('account:${ids.cash}')), findsNothing);
      expect(find.text('Account removed'), findsOneWidget);
      expect(wc.heldTotals()['EUR'], 97450, reason: 'the bank account only');
      await t.tap(find.byKey(const ValueKey('toastUndo')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(ValueKey('account:${ids.cash}')), findsOneWidget);
      expect(wc.heldTotals()['EUR'], 102450);
      await settle(t);
    });

    testWidgets('Undo of the last-sorted row still says why it failed (the row is gone by then)', (t) async {
      final wc = wallet();
      final ids = await seed(wc); // Bank 1, Cash, Travel: Travel sorts last
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountDelete:${ids.usd}');
      expect(find.byKey(ValueKey('account:${ids.usd}')), findsNothing);
      await wc.addAccount(name: 'Travel 2', source: 'revolut', currency: 'USD', opening: 1, openingDate: '2026-10-20');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('toastUndo')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('There is already an account for this bank in USD.'), findsOneWidget);
      await settle(t);
    });

    testWidgets('Undo says why when another cash account was added meanwhile', (t) async {
      final wc = wallet();
      final ids = await seed(wc);
      await pumpApp(t, panel(wc), size: const Size(400, 2400));
      await tapKey(t, 'accountDelete:${ids.cash}');
      await wc.addAccount(name: 'Cash 2', currency: 'EUR', opening: 1, openingDate: '2026-10-20');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('toastUndo')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('There is already a cash account in EUR.'), findsOneWidget);
      expect(find.byKey(ValueKey('account:${ids.cash}')), findsNothing);
      await settle(t);
    });
  });

  group('Today: Held line', () {
    Widget todayOf(WalletController wc, VoidCallback open) => ListenableBuilder(
        listenable: wc,
        builder: (_, __) =>
            Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {}, openAccounts: open, clock: () => day)));

    testWidgets('one figure per currency, tap opens Plan › Accounts; absent without accounts', (t) async {
      final wc = wallet();
      wc.snoozeKeyBackup();
      await pumpApp(t, todayOf(wc, () {}), size: const Size(400, 2400));
      expect(find.byKey(const ValueKey('heldLine')), findsNothing);

      await seed(wc);
      var opened = 0;
      await pumpApp(t, todayOf(wc, () => opened++), size: const Size(400, 2400));
      expect(find.text('Held: ${moneyExact(102450, 'EUR')} · ${moneyExact(8000, 'USD')}'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('heldLine')));
      await t.tap(find.byKey(const ValueKey('heldLine')));
      expect(opened, 1);
      await settle(t);
    });
  });

  group('welcome cash step', () {
    ({WalletController wc}) fresh() {
      final wc = WalletController.forTest(WalletRepo.inMemory(), clock: () => day);
      wc.keyWriter = (k, {passphrase}) async {};
      return (wc: wc);
    }

    testWidgets('after the save-key prompt: Add cash makes a Cash account in the wallet currency dated today', (t) async {
      final f = fresh();
      await f.wc.createWallet();
      await pumpApp(t, HomeShell(wc: f.wc), size: const Size(400, 2400));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(KeyBackupSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('welcomeHeading')), findsNothing, reason: 'the key comes first');
      await tapKey(t, 'keyLater');
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(KeyBackupSheet), findsNothing);
      expect(find.text('How much cash do you have right now?'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('welcomeCash')), '123.45');
      await tapKey(t, 'welcomeAdd');
      await t.pump(const Duration(milliseconds: 600));
      final a = f.wc.accountsAll().single;
      expect((a.name, a.source, a.currency, a.opening, a.openingDate), ('Cash', null, 'EUR', 12345, '2026-10-20'));
      expect(find.byKey(const ValueKey('welcomeCash')), findsNothing);
      await settle(t);
    });

    testWidgets('Skip adds nothing, and a bad amount is refused under the field', (t) async {
      final f = fresh();
      await f.wc.createWallet();
      await pumpApp(t, HomeShell(wc: f.wc), size: const Size(400, 2400));
      await t.pump(const Duration(milliseconds: 600));
      await tapKey(t, 'keyLater');
      await t.pump(const Duration(milliseconds: 600));
      await t.enterText(find.byKey(const ValueKey('welcomeCash')), 'lots');
      await tapKey(t, 'welcomeAdd');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      expect(f.wc.accountsAll(), isEmpty);
      await tapKey(t, 'welcomeSkip');
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('welcomeCash')), findsNothing);
      expect(f.wc.accountsAll(), isEmpty);
      await settle(t);
    });

    testWidgets('the step is not shown for a wallet that was not just created', (t) async {
      final wc = wallet();
      await pumpApp(t, HomeShell(wc: wc), size: const Size(400, 2400));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(WelcomeBalanceSheet), findsNothing);
      await settle(t);
    });
  });

  testWidgets('Plan holds the Accounts panel', (t) async {
    final wc = wallet();
    await seed(wc);
    await pumpApp(t, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 6000));
    expect(find.text('ACCOUNTS'), findsOneWidget);
    await settle(t);
  });

  group('layout', () {
    for (final (w, s) in [(320.0, 2.0), (360.0, 1.0), (1280.0, 1.0)]) {
      testWidgets('panel and sheets fit at ${w.toInt()} dp, text ${s}x', (t) async {
        final wc = wallet();
        final ids = await seed(wc);
        wc.repo.applyRemote([
          Op(
              'account',
              'zzz-dup',
              {
                'name': 'Cash with a rather long synthetic name',
                'source': null,
                'currency': 'EUR',
                'opening': 1,
                'opening_date': '2026-10-02',
                'deleted': 0
              },
              Hlc(DateTime.now().millisecondsSinceEpoch + 60000, 0, 'peer').toString()),
        ]);
        wc.reload();
        await pumpApp(t, panel(wc), size: Size(w, 900), textScale: s);
        expect(t.takeException(), isNull);
        for (final k in ['accountAdd', 'accountRename:${ids.bank}', 'accountCorrect:${ids.bank}', 'accountDelete:${ids.bank}']) {
          expect(t.getSize(find.byKey(ValueKey(k))).height, greaterThanOrEqualTo(48), reason: k);
        }
        await tapKey(t, 'accountAdd');
        expect(t.takeException(), isNull);
        expect(find.byKey(const ValueKey('accountSave')), findsOneWidget);
        await settle(t);
      });
    }
  });
}
