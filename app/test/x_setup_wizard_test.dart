// Stage X: the "Set up my wallet" wizard (docs/context/X_SPEC.md). All data is SYNTHETIC (fixed clock 20 Oct 2026).
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/setup_wizard.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _csv = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
    'Card Payment,Current,2026-10-01 10:00:00,2026-10-02 10:00:00,Synthetic shop,-12.30,0.00,EUR,COMPLETED,100.00\n';

class _Picked extends PickedFile {
  _Picked(Uint8List data) : super('synthetic.csv', () async => data, length: () async => data.length);
}

class _Chooser extends FileChooser {
  @override
  Future<List<PickedFile>> pickBankFiles() async => [_Picked(Uint8List.fromList(utf8.encode(_csv)))];
}

/// habitsWallet (a gym bill candidate, budgets of 300 and 100) plus salary rows (plan suggestions), a monthly payout (income candidate)
/// and a payee with four payments nothing decides yet.
WalletController setupWallet() {
  final wc = habitsWallet();
  addTearDown(wc.dispose);
  wc.setImportPreviewAlways(false);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    for (final d in const ['2026-08-10', '2026-09-10', '2026-10-10']) syntheticTx(d, 120000, 'Plaća/Mirovina', 'Neto placa synthetic'),
    for (final d in const ['2026-07-20', '2026-08-20', '2026-09-20']) syntheticTx(d, 30000, 'Ostalo', 'Quorvant Payout 2026'),
    for (final d in const ['2026-09-02', '2026-09-09', '2026-09-16', '2026-10-01'])
      syntheticTx(d, -450, 'POS plaćanje', 'POS QUORVANTSHOP ZAGREB'),
  ]));
  wc.reload();
  wc.refreshRecurring();
  return wc;
}

/// A wallet as the create button leaves it (no disk).
WalletController freshWallet() {
  final wc = seamedController(WalletRepo.inMemory(), clock: () => budgetToday);
  wc.seams.keyWriter = (k, {passphrase}) async {};
  addTearDown(wc.dispose);
  return wc;
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4));

Future<void> go(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 600));
}

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  expect(f, findsOneWidget, reason: key);
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await go(t);
}

/// Opens the wizard on a page that has only a button for it.
Future<void> openWizard(WidgetTester t, WalletController wc,
    {bool restart = true, FileChooser chooser = const FileChooser(), Size size = const Size(400, 900), double textScale = 1}) async {
  await pumpApp(
      t,
      Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  key: const ValueKey('go'),
                  onPressed: () => openSetupWizard(context, wc, chooser: chooser, restart: restart),
                  child: const Text('Set up')))),
      size: size,
      textScale: textScale);
  await t.tap(find.byKey(const ValueKey('go')));
  await go(t);
}

/// From step 1: Next once (writes nothing), then Skip to step [n].
Future<void> toStep(WidgetTester t, int n) async {
  await tapKey(t, 'setupNext');
  for (var i = 2; i < n; i++) {
    await tapKey(t, 'setupSkip');
  }
}

bool onStep(int n) => find.byKey(ValueKey('setupStep:$n')).evaluate().isNotEmpty;

String textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

/// What a skipped step must leave untouched.
String snapshot(WalletController wc) => [
      wc.settings.toMap().toString(),
      wc.settings.categoryBudgets.toString(),
      [for (final b in wc.recurringBills()) '${b.id}:${b.status}'].toString(),
      wc.accountsAll().length,
      wc.categorizer.merchantRules.toString(),
    ].join('|');

void main() {
  group('entry', () {
    testWidgets('createWallet starts it (device-local), join does not, and the P13 sheet is off then', (t) async {
      final f = freshWallet();
      expect(f.setupWizardState, isNull);
      await f.createWallet();
      expect(f.setupWizardState, 'pending');
      expect(f.setupWizardOpen, isTrue);
      expect(f.shouldOfferFirstPlan(), isFalse, reason: 'the wizard offers the plan itself');
      final j = freshWallet();
      await j.joinWallet(await VaultKey.generate().toText());
      expect(j.setupWizardState, isNull);
      expect(j.setupWizardOpen, isFalse);
      await settle(t);
    });

    testWidgets('after the save-key sheet the wizard opens at step 1 and keeps the step', (t) async {
      final wc = freshWallet();
      await wc.createWallet();
      await pumpApp(t, HomeShell(wc: wc), size: const Size(400, 2400));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('setupWizard')), findsNothing, reason: 'the key comes first');
      await tapKey(t, 'keyLater');
      expect(find.byKey(const ValueKey('setupWizard')), findsOneWidget);
      expect(onStep(1), isTrue);
      expect(find.text('Step 1 of 8'.toUpperCase()), findsOneWidget);
      expect(wc.setupWizardState, 'step:1');
      await settle(t);
    });

    testWidgets('a joined wallet never opens it', (t) async {
      final wc = freshWallet();
      await wc.joinWallet(await VaultKey.generate().toText());
      await pumpApp(t, HomeShell(wc: wc), size: const Size(400, 2400));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('setupWizard')), findsNothing);
      await settle(t);
    });
  });

  group('steps', () {
    testWidgets('1 Import: files go through the import flow, the result shows, no "Looks right?" sheet; Next goes on', (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'pending');
      // The file names its pocket ("Current"): an account already claims it, so "Which account is this?" (UX-ACC) is not asked.
      await t.runAsync(() async => wc.repo.addAccount(
          name: 'Revolut',
          source: 'revolut',
          currency: 'EUR',
          opening: 0,
          openingDate: '2026-09-01',
          matchKey: await accountMatchKey(wc.key!, 'Current')));
      wc.reload();
      final before = wc.setupSummary().payments;
      await openWizard(t, wc, chooser: _Chooser());
      expect(onStep(1), isTrue);
      await tapKey(t, 'setupImport');
      expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing);
      expect(find.textContaining('synthetic.csv'), findsOneWidget);
      expect(wc.setupSummary().payments, before + 1);
      await tapKey(t, 'setupNext');
      expect(onStep(2), isTrue);
      expect(wc.setupWizardState, 'step:2');
      await settle(t);
    });

    testWidgets('skipping every step writes nothing; Skip on step 1 jumps to the end', (t) async {
      final wc = setupWallet();
      final before = snapshot(wc);
      await openWizard(t, wc);
      await tapKey(t, 'setupNext'); // 1 -> 2, writes nothing
      for (var n = 2; n <= 7; n++) {
        expect(onStep(n), isTrue, reason: 'step $n');
        await tapKey(t, 'setupSkip');
      }
      expect(onStep(8), isTrue);
      expect(snapshot(wc), before);
      for (final n in [2, 3, 4, 5, 6, 7]) {
        expect(find.byKey(ValueKey('setupGoto:$n')), findsOneWidget);
      }
      await tapKey(t, 'setupBack');
      expect(onStep(7), isTrue);
      await tapKey(t, 'setupBack');
      expect(onStep(6), isTrue);
      await settle(t);
    });

    testWidgets('Skip on step 1 ("I\'ll add payments by hand") jumps to the end and writes nothing', (t) async {
      final wc = setupWallet();
      final before = snapshot(wc);
      await openWizard(t, wc);
      expect(find.text("Skip, I'll add payments by hand"), findsOneWidget);
      await tapKey(t, 'setupSkip');
      expect(onStep(8), isTrue);
      expect(snapshot(wc), before);
      await settle(t);
    });

    testWidgets('2 Accounts: cash is added only with a tap; a bad amount is refused; Skip adds nothing', (t) async {
      final wc = setupWallet();
      await openWizard(t, wc);
      await tapKey(t, 'setupNext');
      expect(onStep(2), isTrue);
      expect(wc.accountsAll(), isEmpty);
      await t.enterText(find.byKey(const ValueKey('setupCash')), 'lots');
      await tapKey(t, 'setupCashAdd');
      expect(find.text(invalidAmountMessage), findsOneWidget);
      expect(wc.accountsAll(), isEmpty);
      await t.enterText(find.byKey(const ValueKey('setupCash')), '123.45');
      await tapKey(t, 'setupCashAdd');
      final a = wc.accountsAll().single;
      expect((a.name, a.source, a.currency, a.opening, a.openingDate), ('Cash', null, 'EUR', 12345, '2026-10-20'));
      expect(find.byKey(const ValueKey('setupCash')), findsNothing, reason: 'one cash account is enough');
      expect(find.byKey(ValueKey('setupAccount:${a.id}')), findsOneWidget);
      await tapKey(t, 'setupSkip');
      expect(onStep(3), isTrue);
      expect(wc.accountsAll().length, 1);
      await settle(t);
    });

    testWidgets('3 Payday plan: current → suggested with the basis; one Accept writes only that key; Accept all writes the rest',
        (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'pending');
      await openWizard(t, wc);
      await tapKey(t, 'setupNext');
      await tapKey(t, 'setupSkip');
      expect(onStep(3), isTrue);
      final keys = [for (final p in wc.planProposalList()) p.key];
      expect(keys, containsAll(['salary', 'paydayDay']));
      expect(textOf(t, 'setupProposalValue:salary'), '${moneyExact(150000, 'EUR')} → ${moneyExact(120000, 'EUR')}');
      expect(find.text('From your last salary payments.'), findsOneWidget);
      expect(wc.settings.salary, 150000, reason: 'looking writes nothing');
      final day = wc.settings.paydayDay;
      await tapKey(t, 'setupProposalAccept:salary');
      expect(wc.settings.salary, 120000);
      expect(wc.settings.paydayDay, day, reason: 'only that row');
      expect(onStep(3), isTrue);
      expect(find.byKey(const ValueKey('setupProposal:salary')), findsNothing);
      await tapKey(t, 'setupAccept');
      expect(onStep(4), isTrue);
      expect(wc.planProposalList(), isEmpty);
      expect(wc.setupWizardState, 'step:4');
      await settle(t);
    });

    testWidgets('3 with nothing to suggest says so and offers Next', (t) async {
      final wc = emptyWallet();
      await openWizard(t, wc);
      await tapKey(t, 'setupNext');
      await tapKey(t, 'setupSkip');
      expect(onStep(3), isTrue);
      expect(find.textContaining('Nothing to suggest'), findsOneWidget);
      expect(find.byKey(const ValueKey('setupNext')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupAccept')), findsNothing);
      await settle(t);
    });

    testWidgets('4 Bills: the month/year total, Confirm / Not a bill per row, Confirm all', (t) async {
      final wc = setupWallet();
      final ids = [
        for (final b in wc.expectedBills())
          if (b.status == 'candidate') b.id
      ];
      expect(ids, isNotEmpty);
      await openWizard(t, wc);
      await toStep(t, 4);
      expect(onStep(4), isTrue);
      expect(find.byKey(const ValueKey('setupBillsCost')), findsNothing, reason: 'the total counts confirmed bills');
      final status = {for (final b in wc.expectedBills()) b.id: b.status};
      await tapKey(t, 'confirm:${ids.first}');
      expect(wc.expectedBills().firstWhere((b) => b.id == ids.first).status, 'confirmed');
      expect(textOf(t, 'setupBillsCost'), startsWith('Bills and subscriptions:'));
      expect(textOf(t, 'setupBillsCost'), contains('a month'));
      for (final b in wc.expectedBills()) {
        if (b.id != ids.first) expect(b.status, status[b.id], reason: 'only the tapped row');
      }
      if (ids.length > 1) {
        await tapKey(t, 'dismiss:${ids[1]}');
        expect(wc.recurringBills().where((b) => b.id == ids[1]), isEmpty, reason: 'dismissed bills are not listed');
      }
      expect(onStep(4), isTrue);
      await settle(t);
    });

    testWidgets('4 Confirm all confirms every candidate and goes on', (t) async {
      final wc = setupWallet();
      await openWizard(t, wc);
      await toStep(t, 4);
      expect(find.byKey(const ValueKey('setupAccept')), findsOneWidget);
      await tapKey(t, 'setupAccept');
      expect(onStep(5), isTrue);
      expect(wc.expectedBills().where((b) => b.status == 'candidate'), isEmpty);
      await settle(t);
    });

    testWidgets('5 Extra income: Confirm writes that income; Skip leaves it a candidate', (t) async {
      final wc = setupWallet();
      final inc = wc.expectedIncomes().firstWhere((b) => b.status == 'candidate');
      await openWizard(t, wc);
      await toStep(t, 5);
      expect(onStep(5), isTrue);
      expect(find.byKey(ValueKey('setupIncome:${inc.id}')), findsOneWidget);
      await tapKey(t, 'setupSkip');
      expect(wc.expectedIncomes().firstWhere((b) => b.id == inc.id).status, 'candidate');
      await tapKey(t, 'setupBack');
      await tapKey(t, 'incomeConfirm:${inc.id}');
      expect(wc.expectedIncomes().firstWhere((b) => b.id == inc.id).status, 'confirmed');
      await settle(t);
    });

    testWidgets('6 Payees: top payees by count; picking a main tag makes the rule with an Undo; nothing without a pick', (t) async {
      final wc = setupWallet();
      final payees = wc.uncategorisedPayeeList();
      expect(payees.first.count, 4);
      final key = payees.first.merchantKey;
      final rules = wc.categorizer.merchantRules.toString();
      await openWizard(t, wc);
      await toStep(t, 6);
      expect(onStep(6), isTrue);
      expect(find.byKey(ValueKey('setupPayee:$key')), findsOneWidget);
      expect(find.text('4 payments'), findsOneWidget);
      expect(wc.categorizer.merchantRules.toString(), rules, reason: 'looking writes nothing');
      await t.ensureVisible(find.byKey(ValueKey('setupPayeeTag:$key')));
      await t.tap(find.byKey(ValueKey('setupPayeeTag:$key')));
      await go(t);
      await t.tap(find.byKey(const ValueKey('pick:Eating out')).last);
      await go(t);
      expect(wc.categorizer.merchantRules[key], 'Eating out');
      expect(find.byKey(ValueKey('setupPayeeRule:$key')), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      await t.tap(find.text('Undo'));
      await go(t);
      expect(wc.categorizer.merchantRules.toString(), rules);
      expect(find.byKey(ValueKey('setupPayeeRule:$key')), findsNothing);
      await settle(t);
    });

    testWidgets('6 with no payee to tag says so', (t) async {
      final wc = emptyWallet();
      await openWizard(t, wc);
      await toStep(t, 6);
      expect(onStep(6), isTrue);
      expect(find.textContaining('already'), findsOneWidget);
      await settle(t);
    });

    testWidgets('7 Budgets: current → suggested; one Accept writes only that category; Accept all the rest', (t) async {
      final wc = setupWallet();
      final proposals = wc.setupBudgetProposals();
      expect(proposals, isNotEmpty);
      final first = proposals.first.category;
      final others = {...wc.settings.categoryBudgets}..remove(first);
      await openWizard(t, wc);
      await toStep(t, 7);
      expect(onStep(7), isTrue);
      expect(find.byKey(ValueKey('setupBudget:$first')), findsOneWidget);
      await tapKey(t, 'setupBudgetAccept:$first');
      expect(wc.settings.categoryBudgets[first], proposals.first.suggested);
      for (final e in others.entries) {
        expect(wc.settings.categoryBudgets[e.key], e.value, reason: 'only ${proposals.first.category}');
      }
      if (proposals.length > 1) {
        await tapKey(t, 'setupAccept');
        expect(onStep(8), isTrue);
        expect(wc.setupBudgetProposals(), isEmpty);
      }
      await settle(t);
    });

    testWidgets('8 Done: the numbers are Today\'s, a button per skipped step, Done ends it', (t) async {
      final wc = setupWallet();
      await openWizard(t, wc);
      await toStep(t, 8);
      expect(onStep(8), isTrue);
      final safe = t.widget<MoneyText>(find.byKey(const ValueKey('setupSafe'))).text;
      expect(find.byKey(const ValueKey('setupPayday')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupBillsHeld')), findsOneWidget);
      await tapKey(t, 'setupGoto:3');
      expect(onStep(3), isTrue);
      for (var i = 0; i < 5; i++) {
        await tapKey(t, 'setupSkip');
      }
      await tapKey(t, 'setupDone');
      expect(wc.setupWizardState, 'done');
      expect(wc.setupWizardOpen, isFalse);
      expect(find.byKey(const ValueKey('setupWizard')), findsNothing);
      await pumpApp(t, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
          size: const Size(400, 2400));
      final heroText = t.widget<Text>(find.byKey(const ValueKey('safeToSpend')));
      expect(heroText.textSpan?.toPlainText() ?? heroText.data, safe);
      await settle(t);
    });
  });

  group('resume and again', () {
    testWidgets('closing at step 4 keeps it: Needs you says Finish setting up and reopens step 4; Done removes the line', (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'pending');
      await openWizard(t, wc, restart: false);
      expect(onStep(1), isTrue);
      await toStep(t, 4);
      expect(onStep(4), isTrue);
      await tapKey(t, 'sheetClose');
      expect(find.byKey(const ValueKey('setupWizard')), findsNothing);
      expect(wc.setupWizardState, 'step:4');
      await pumpApp(t, ListenableBuilder(listenable: wc, builder: (c, _) => needsYouOf(wc)), size: const Size(400, 2400));
      expect(find.byKey(const ValueKey('needs:wizard')), findsOneWidget);
      expect(find.text('Step 4 of 8. Every step can be skipped.'), findsOneWidget);
      await tapKey(t, 'needsPrimary:wizard');
      expect(onStep(4), isTrue);
      for (var i = 0; i < 4; i++) {
        await tapKey(t, 'setupSkip');
      }
      await tapKey(t, 'setupDone');
      await t.pump(const Duration(milliseconds: 100));
      expect(wc.setupWizardState, 'done');
      expect(find.byKey(const ValueKey('needs:wizard')), findsNothing);
      await settle(t);
    });

    testWidgets('"No thanks" in Needs you ends the offer', (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'step:3');
      wc.reload();
      await pumpApp(t, needsYouOf(wc), size: const Size(400, 2400));
      await tapKey(t, 'needsAlt:wizard');
      expect(wc.setupWizardState, 'skipped');
      expect(wc.setupWizardOpen, isFalse);
      await settle(t);
    });

    testWidgets('Settings › Set up my wallet again opens step 1; the plan step shows the current values', (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'done');
      await pumpApp(t, Scaffold(body: SettingsScreen(wc: wc)), size: const Size(400, 900));
      await t.pump(const Duration(milliseconds: 300));
      await t.scrollUntilVisible(find.byKey(const ValueKey('setupAgain')), 400,
          scrollable: find.byType(Scrollable).first); // the last row of the page
      await tapKey(t, 'setupAgain');
      expect(onStep(1), isTrue);
      final bars = find.descendant(of: find.byKey(const ValueKey('setupProgress')), matching: find.byType(Expanded));
      expect(bars, findsNWidgets(setupWizardSteps), reason: 'one bar per step');
      await tapKey(t, 'setupNext');
      await tapKey(t, 'setupSkip');
      expect(onStep(3), isTrue);
      expect(textOf(t, 'setupProposalValue:salary'), startsWith(moneyExact(150000, 'EUR')));
      await settle(t);
    });
  });

  group('review fixes', () {
    testWidgets('P13 stays off only while the wizard is under way: "No thanks" brings it back, a restore ends the wizard', (t) async {
      final wc = setupWallet();
      expect(wc.planProposalList(), isNotEmpty);
      wc.repo.setLocalValue('setupWizard', 'step:2');
      expect(wc.shouldOfferFirstPlan(), isFalse);
      wc.declineSetupWizard();
      expect(wc.shouldOfferFirstPlan(), isTrue, reason: 'step 3 was never seen');
      wc.repo.setLocalValue('setupWizard', 'step:1');
      wc.seams.backupBytesReader = (repo, b, key) async => 5;
      await wc.restoreBackupFile(Uint8List.fromList([1]));
      expect(wc.setupWizardState, 'done');
      expect(wc.setupWizardOpen, isFalse);
      expect(wc.shouldOfferFirstPlan(), isTrue);
      final other = setupWallet();
      other.seams.backupBytesReader = (repo, b, key) async => 5;
      await other.restoreBackupFile(Uint8List.fromList([1]));
      expect(other.setupWizardState, isNull, reason: 'a wallet that never had the wizard stays without');
      await settle(t);
    });

    testWidgets('skipped steps are kept with the progress; a step with something written in it is not skipped', (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'pending');
      await openWizard(t, wc, restart: false);
      await tapKey(t, 'setupNext'); // 1 -> 2
      await t.enterText(find.byKey(const ValueKey('setupCash')), '10');
      await tapKey(t, 'setupCashAdd');
      await tapKey(t, 'setupSkip'); // 2 -> 3: cash was added, so not skipped
      await tapKey(t, 'setupSkip'); // 3 -> 4: skipped
      await tapKey(t, 'sheetClose');
      expect(wc.setupWizardState, 'step:4');
      expect(wc.setupSkippedSteps, {3});
      await openWizard(t, wc, restart: false);
      expect(onStep(4), isTrue);
      for (var i = 0; i < 4; i++) {
        await tapKey(t, 'setupSkip');
      }
      expect(onStep(8), isTrue);
      expect(find.byKey(const ValueKey('setupGoto:3')), findsOneWidget, reason: 'kept from the first run');
      expect(find.byKey(const ValueKey('setupGoto:4')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupGoto:2')), findsNothing, reason: 'cash was added there');
      await settle(t);
    });

    testWidgets('restarted from Settings on a finished wallet, closing early keeps it finished', (t) async {
      final wc = setupWallet();
      wc.repo.setLocalValue('setupWizard', 'done');
      await openWizard(t, wc);
      await tapKey(t, 'setupNext');
      await tapKey(t, 'setupSkip');
      expect(onStep(3), isTrue);
      await tapKey(t, 'sheetClose');
      expect(wc.setupWizardState, 'done');
      expect(wc.setupSkippedSteps, isEmpty);
      expect(wc.setupWizardOpen, isFalse);
      await settle(t);
    });

    testWidgets('6 pick A, then B, then Undo: the rule is A again', (t) async {
      final wc = setupWallet();
      final key = wc.uncategorisedPayeeList().first.merchantKey;
      await openWizard(t, wc);
      await toStep(t, 6);
      Future<void> pick(String id) async {
        await t.ensureVisible(find.byKey(ValueKey('setupPayeeTag:$key')));
        await t.tap(find.byKey(ValueKey('setupPayeeTag:$key')));
        await go(t);
        await t.tap(find.byKey(ValueKey('pick:$id')).last);
        await go(t);
      }

      await pick('Eating out');
      await pick('Groceries');
      expect(wc.categorizer.merchantRules[key], 'Groceries');
      await t.pump(const Duration(seconds: 1)); // the second toast slides in after the first one left
      await t.tap(find.text('Undo'));
      await go(t);
      expect(wc.categorizer.merchantRules[key], 'Eating out');
      await settle(t);
    });

    testWidgets('8 after payday the line says Payday was, like Today', (t) async {
      final wc = setupWallet();
      wc.repo.updateSettings({'paydayDay': 1, 'periodStart': '2026-09-01'});
      wc.reload();
      expect(wc.period().paydayPassed, isTrue);
      await openWizard(t, wc);
      await toStep(t, 8);
      expect(find.text('Payday was'), findsOneWidget);
      expect(find.text('Next payday'), findsNothing);
      expect(find.text('Left this pay period'.toUpperCase()), findsOneWidget);
      await settle(t);
    });
  });

  group('layout', () {
    for (final (w, h, scale, dark) in [(320.0, 700.0, 2.0, false), (360.0, 740.0, 1.0, true), (1280.0, 800.0, 1.0, false)]) {
      testWidgets('every step fits at ${w.toInt()} dp, text $scale x${dark ? ', dark' : ''}', (t) async {
        final wc = setupWallet();
        for (var n = 1; n <= 8; n++) {
          t.view.physicalSize = Size(w, h);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          await t.pumpWidget(MaterialApp(
            key: ValueKey(n),
            theme: buildTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
            home: SetupWizard(wc: wc, start: n),
          ));
          await t.pump(const Duration(milliseconds: 300));
          expect(onStep(n), isTrue);
          expect(t.takeException(), isNull, reason: 'step $n');
          expect(find.byKey(const ValueKey('setupBack')).evaluate().isNotEmpty, n > 1);
        }
        await settle(t);
      });
    }

    testWidgets('on a wide window it is a dialog', (t) async {
      final wc = setupWallet();
      await openWizard(t, wc, size: const Size(1280, 800));
      expect(find.byType(Dialog), findsOneWidget);
      expect(onStep(1), isTrue);
      expect(t.takeException(), isNull);
      await settle(t);
    });
  });
}
