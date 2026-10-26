// Tap-through on Plan: numbers (validation, save), start a new month, Sync (relay address), wallet key, Diagnostics (level,
// log size, clear). Run: tools/emulator.sh test plan
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/diagnostics.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'demo_data.dart';
import 'support/harness.dart';

/// The payday plan sits on the Budget tab.
Finder inPlan(Finder f) => find.descendant(of: find.byType(SpendingScreen), matching: f);
String fieldText(WidgetTester t, String label) => t.widget<TextField>(inPlan(field(label))).controller!.text;

/// Payday plan lists the ledger lines until Edit is tapped (then it has the fields); no-op when the fields are already showing.
Future<void> edit(WidgetTester t) async {
  await scrollTo(t, find.text('PAYDAY PLAN'), SpendingScreen, delta: -250);
  final button = inPlan(find.byKey(const ValueKey('planEdit')));
  if (button.evaluate().isEmpty) return;
  await tapVisible(t, button);
  await t.pumpAndSettle();
}

Future<void> fill(WidgetTester t, Map<String, String> values) async {
  await edit(t);
  for (final e in values.entries) {
    await scrollTo(t, inPlan(field(e.key)), SpendingScreen);
    await t.enterText(inPlan(field(e.key)), e.value);
  }
  await t.pumpAndSettle();
}

Future<void> save(WidgetTester t) async {
  await scrollTo(t, find.byKey(const ValueKey('planSave')), SpendingScreen);
  await tapVisible(t, find.byKey(const ValueKey('planSave')));
  await t.pumpAndSettle();
}

/// The value of the "Log files" line: `files · size`.
String logFilesValue(WidgetTester t) {
  final texts = t.widgetList<Text>(find.descendant(of: find.widgetWithText(LineItem, 'Log files'), matching: find.byType(Text))).toList();
  return texts.last.data!;
}

void main() {
  Harness.init();
  Harness.private(cents: [250000, 60050, 25000, 4599, 8000, 70000, 40000, 260000, 123456, 7500]);

  itest('Payday plan numbers: bad input is refused, good input is saved and used everywhere', (t) async {
    final wc = await Harness.start(t);
    await goTab(t, 'Budget');
    await fill(t, {'Salary per month': '2500', 'Rent': '600,50', 'Loan': 'abc'});
    await save(t);
    expect(find.text('Enter an amount, like 12.50.'), findsOneWidget);
    expect(inPlan(find.text('Numbers only')), findsOneWidget, reason: 'the wrong field says why');
    expect(wc.settings.salary, 0, reason: 'nothing is saved while a field is wrong');
    await fill(t, {'Loan': '-5'});
    await save(t);
    expect(find.text('Enter an amount, like 12.50.'), findsOneWidget);
    expect(wc.settings.salary, 0);

    await fill(t, {
      'Loan': '250',
      'Bills & subs': '45.99',
      'Wishlist above': '80',
      'Wait (hours)': '48',
      'Latest payday': '45',
      'Cash withdrawal counts as rent from': '400',
    });
    await save(t);
    expect(find.text('Plan saved'), findsOneWidget);
    expect(inPlan(find.text('Numbers only')), findsNothing);
    final s = wc.settings;
    expect((s.salary, s.rent, s.loan, s.subs, s.impulse, s.coolHours), (250000, 60050, 25000, 4599, 8000, 48));
    expect(s.rentCashThreshold, 40000);
    await edit(t);
    expect(fieldText(t, 'Latest payday'), '28', reason: 'the field shows what was saved');
    await t.tap(inPlan(find.byKey(const ValueKey('planCancel'))));
    await t.pumpAndSettle();
    expect(s.paydayDay, 28, reason: 'the payday is kept within 1-28');
    expect(s.salaryConfirmed, isTrue, reason: 'typing a salary confirms it');
    final p = wc.period();
    // 2500 - 600.50 - 250 - 45.99 - 200 (default goals) = 1403.51
    expect(p.flexBudget, 140351);
    await scrollTo(t, find.text('PAYDAY PLAN'), SpendingScreen, delta: -250);
    expect(find.text('${moneyExact(140351, 'EUR')} to spend · ${moneyExact(p.planDaily, 'EUR')}/day'), findsOneWidget);
    await goTab(t, 'Save');
    expect(find.text('Anything over 80\u00A0€ waits 48 hours on the wishlist first.'), findsOneWidget);
    await goTab(t, 'Today');
    expect(find.textContaining('Planning on'), findsNothing);

    // A wait below zero is refused like the other numbers; nothing is saved.
    await goTab(t, 'Budget');
    await fill(t, {'Wait (hours)': '-3', 'Bills & subs': '50'});
    await save(t);
    expect(find.text("Wait (hours) can't be negative."), findsOneWidget);
    expect(inPlan(find.text("Can't be negative")), findsOneWidget);
    expect((wc.settings.coolHours, wc.settings.subs), (48, 4599));
    await fill(t, {'Wait (hours)': '48', 'Bills & subs': '45.99'});
    await save(t);
    expect(find.text('Nothing to save'), findsOneWidget, reason: 'the fields are back to the saved numbers');
    expect(inPlan(find.text("Can't be negative")), findsNothing);

    // Currency.
    await edit(t);
    await scrollTo(t, inPlan(find.byType(DropdownButtonFormField<String>)), SpendingScreen);
    await pickDropdown(t, inPlan(find.byType(DropdownButtonFormField<String>)), 'USD');
    await save(t);
    expect(wc.settings.currency, 'USD');
    await goTab(t, 'Today');
    expect(find.textContaining(r'$'), findsWidgets);
    expect(find.textContaining('€'), findsNothing);

    // A change from elsewhere (sync from another device, "Looks right" on Today) while Plan is open.
    wc.updateSettings({'rent': 70000});
    await t.pumpAndSettle();
    await goTab(t, 'Budget');
    await edit(t);
    await scrollTo(t, inPlan(field('Rent')), SpendingScreen);
    expect(fieldText(t, 'Rent'), '700', reason: 'Plan fields follow changes made elsewhere');
    await save(t);
    expect(find.text('Nothing to save'), findsOneWidget);
    expect(wc.settings.rent, 70000, reason: 'Save keeps a change made elsewhere');

    // An edit in progress is kept when another setting changes elsewhere, and Save writes only the edited field.
    await fill(t, {'Loan': '300'});
    wc.updateSettings({'subs': 5000});
    await t.pumpAndSettle();
    expect(fieldText(t, 'Loan'), '300');
    expect(fieldText(t, 'Bills & subs'), '50');
    wc.updateSettings({'salary': 260000});
    await t.pumpAndSettle();
    await save(t);
    expect(find.text('Plan saved'), findsOneWidget);
    expect((wc.settings.loan, wc.settings.subs, wc.settings.salary, wc.settings.rent), (30000, 5000, 260000, 70000));
    await Harness.checkLog();
  });

  itest('Accounts and plan suggestions: shown, accepted, added, corrected, deleted with Undo', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t,
        batch: demoBatch(today), settings: {'salary': 100000, 'salaryConfirmed': true, 'paydayDay': 15, 'rent': 0, 'loan': 0});
    await wc.addAccount(name: 'Bank 1', source: 'pbz', currency: 'EUR', opening: 123456, openingDate: addDays(today, -30));
    final cash = await wc.addAccount(name: 'Cash', currency: 'EUR', opening: 7500, openingDate: addDays(today, -30));
    await goTab(t, 'Budget');

    // Suggestions from the imports: nothing is written until a tap; Not now hides one, Accept writes one key.
    await scrollTo(t, find.text('SUGGESTIONS FROM YOUR IMPORTS'), SpendingScreen);
    expect(find.byKey(const ValueKey('proposal:salary')), findsOneWidget);
    expect(find.byKey(const ValueKey('proposal:paydayDay')), findsOneWidget);
    expect(wc.settings.salary, 100000);
    await Harness.shot(t, 'plan-suggestions');
    await tapVisible(t, find.byKey(const ValueKey('proposalLater:salary')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('proposal:salary')), findsNothing);
    expect(wc.settings.salary, 100000);
    await tapVisible(t, find.byKey(const ValueKey('proposalAccept:paydayDay')));
    await t.pumpAndSettle();
    expect(wc.settings.paydayDay, 10);

    // Accounts: balances, correct, delete + Undo.
    await goSettings(t, SettingsSection.accounts);
    await scrollTo(t, find.byKey(const ValueKey('accountAdd')), SettingsScreen);
    expect(find.byKey(ValueKey('account:$cash')), findsOneWidget);
    await Harness.shot(t, 'plan-accounts');
    await tapVisible(t, find.byKey(ValueKey('accountCorrect:$cash')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('accountCorrectAmount')), '80');
    await t.tap(find.byKey(const ValueKey('accountCorrectSave')));
    await t.pumpAndSettle();
    expect(wc.accountBalanceList().firstWhere((b) => b.account.id == cash).balance, 8000);
    await tapVisible(t, find.byKey(ValueKey('accountDelete:$cash')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('account:$cash')), findsNothing);
    await tapVisible(t, find.byKey(const ValueKey('toastUndo')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('account:$cash')), findsOneWidget);

    await goTab(t, 'Today');
    expect(find.byKey(const ValueKey('heldLine')), findsOneWidget);
    await Harness.shot(t, 'today-held');
    await Harness.checkLog();
  });

  itest('Main tags and Tags: add one, rename, delete with Undo; the picker and Spending follow', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, batch: demoBatch(today), settings: {'salary': 100000, 'salaryConfirmed': true, 'paydayDay': 15});
    final pets = await wc.addOwnCategory(name: 'Pets', kind: BudgetKind.flex);
    final vet = await wc.addOwnCategory(name: 'Vet', kind: BudgetKind.flex);
    await goSettings(t, SettingsSection.tags);
    await scrollTo(t, find.byKey(const ValueKey('categoryAdd')), SettingsScreen);
    expect(find.byKey(ValueKey('category:$pets')), findsOneWidget);
    expect(find.byKey(ValueKey('category:$vet')), findsOneWidget);
    await Harness.shot(t, 'plan-categories');
    await tapVisible(t, find.byKey(ValueKey('categoryMenu:$vet')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('categoryRename:$vet')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('categoryName')), 'Vet visits');
    await t.tap(find.byKey(const ValueKey('categorySave')));
    await t.pumpAndSettle();
    expect(wc.categoryTable.label(vet), 'Vet visits');
    await tapVisible(t, find.byKey(ValueKey('categoryMenu:$vet')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('categoryDeleteItem:$vet')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('category:$vet')), findsNothing);
    await tapVisible(t, find.byKey(const ValueKey('toastUndo')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('category:$vet')), findsOneWidget);
    // Plan › Tags: add a tag, see it in the list, rename it, delete it with Undo.
    final tag = await wc.addTag('Holiday');
    await t.pumpAndSettle();
    await scrollTo(t, find.byKey(ValueKey('tag:$tag')), SettingsScreen);
    await Harness.shot(t, 'plan-tags');
    await tapVisible(t, find.byKey(ValueKey('tagMenu:$tag')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('tagDeleteItem:$tag')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('tag:$tag')), findsNothing);
    await tapVisible(t, find.byKey(const ValueKey('toastUndo')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('tag:$tag')), findsOneWidget);
    await Harness.checkLog();
  });

  itest('Rules: the list, Add rule with a range, delete with Undo', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, batch: demoBatch(today), settings: {'salary': 100000, 'salaryConfirmed': true, 'paydayDay': 15});
    wc.repo.setMerchantPattern('Shopping', 'webshop', match: 'contains', minCents: 1200, maxCents: 3000);
    wc.repo.setMerchantPattern('Cash', r'^atm\b');
    wc.reload();
    await goSettings(t, SettingsSection.rules);
    await scrollTo(t, find.byKey(const ValueKey('rulesAdd')), SettingsScreen);
    final id = wc.settings.patternRules.first.id;
    expect(find.byKey(ValueKey('rule:$id')), findsOneWidget);
    await Harness.shot(t, 'plan-rules');
    await tapVisible(t, find.byKey(const ValueKey('rulesAdd')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ruleText')), 'bakery');
    await t.enterText(find.byKey(const ValueKey('ruleMin')), '5');
    await Harness.shot(t, 'plan-rules-add');
    await t.tap(find.byKey(const ValueKey('txCategory')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pick:Groceries')).last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('ruleSave')));
    await t.pumpAndSettle();
    expect(wc.settings.patternRules.map((p) => p.pattern), contains('bakery'));
    await tapVisible(t, find.byKey(ValueKey('ruleMenu:$id')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey('ruleDelete:$id')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('rule:$id')), findsNothing);
    await tapVisible(t, find.byKey(const ValueKey('toastUndo')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('rule:$id')), findsOneWidget);
    await Harness.checkLog();
  });

  itest('Bill history: a confirmed bill lists its months; a month opens to its payment and bill', (t) async {
    final now = DateTime.now();
    String on(int back) {
      final d = DateTime(now.year, now.month - back, 15);
      return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-15';
    }

    NormalizedTransaction gym(int back) {
      final date = on(back);
      return NormalizedTransaction(
          id: transactionId(date, -2999, 'POS SYNTHGYM ZAGREB', 0),
          source: 'pbz',
          date: date,
          amountMinor: -2999,
          currency: 'EUR',
          bankType: 'POS plaćanje',
          description: 'POS SYNTHGYM ZAGREB');
    }

    final wc = await Harness.start(t,
        batch: ImportBatch(source: 'pbz', transactions: [
          for (final b in [1, 2, 3]) gym(b)
        ]),
        settings: {'salary': 150000, 'salaryConfirmed': true});
    wc.refreshRecurring();
    final bill = wc.recurringBills().firstWhere((b) => b.payee.contains('synthgym'));
    wc.confirmRecurring(bill.id);
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [gym(5)]));
    wc.repo.importBill(
        NormalizedBill(source: BillSource.manual, externalId: 'gym-slip', date: on(2), total: 3050, payee: 'POS SYNTHGYM ZAGREB'));
    wc.reload();
    await goTab(t, 'Bills');
    await scrollTo(t, find.byKey(ValueKey('billHistory_${bill.id}')), BillsScreen);
    await Harness.shot(t, 'plan-bill-row');
    await tapVisible(t, find.byKey(ValueKey('billHistory_${bill.id}')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('historyMonth_${on(0).substring(0, 7)}')), findsOneWidget);
    expect(find.text('Coming up'), findsOneWidget);
    expect(find.text('Missing (no payment or bill found)'), findsOneWidget);
    await Harness.shot(t, 'bill-history');
    await tapVisible(t, find.byKey(ValueKey('historyToggle_${on(2).substring(0, 7)}')));
    await t.pumpAndSettle();
    await Harness.shot(t, 'bill-history-open');
    await Harness.checkLog();
  });

  itest('Start new month from Plan: cancel, today, another day', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, settings: {'salary': 200000, 'salaryConfirmed': true, 'periodStart': addDays(today, -10)});
    await goSettings(t, SettingsSection.month);
    final button = find.text('Salary landed: start new month');
    await scrollTo(t, button, SettingsScreen);
    await tapVisible(t, button);
    await t.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tapVisible(t, find.text('Cancel'));
    await t.pumpAndSettle();
    expect(wc.settings.periodStart, addDays(today, -10));

    await tapVisible(t, button);
    await t.pumpAndSettle();
    await tapVisible(t, find.text('OK'));
    await t.pumpAndSettle();
    expect(wc.settings.periodStart, today);
    expect(wc.settings.incomeMode, 'planned');
    expect(find.text('New month started ${shortDate(today)}'), findsOneWidget);
    expect(find.textContaining('Started ${shortDate(today)}; next payday expected by ${shortDate(wc.period().end)}.'), findsOneWidget);

    final first = '${today.substring(0, 8)}01';
    if (first != today) {
      await tapVisible(t, button);
      await t.pumpAndSettle();
      await tapVisible(t, find.descendant(of: find.byType(DatePickerDialog), matching: find.text('1')));
      await t.pumpAndSettle();
      await tapVisible(t, find.text('OK'));
      await t.pumpAndSettle();
      expect(wc.settings.periodStart, first);
      expect(wc.period().start, first);
    }
    await Harness.checkLog();
  });

  itest('Sync (relay), wallet key, Diagnostics: level, log size, clear', (t) async {
    final wc = await Harness.start(t);
    final key = await wc.keyText();
    Harness.private(texts: ['it-relay.local']);
    await goSettings(t, SettingsSection.diagnostics);

    // Log level.
    await scrollTo(t, find.text('Clear logs'), SettingsScreen);
    expect(wc.logLevel, 'all');
    expect(logFilesValue(t), matches(RegExp(r'^\d+ · \d+ (B|KB|MB)$')));
    await tapVisible(t, find.text('Warnings'));
    await t.pumpAndSettle();
    expect(wc.logLevel, 'warning');
    expect(wc.repo.localValue('logLevel'), 'warning');
    expect(Logger.root.level, Level.WARNING);
    final n0 = 'expense.add'.allMatches(await AppLog.combined()).length;
    wc.addExpense(amount: 1111, category: 'Groceries', note: '', date: todayIso());
    await t.pumpAndSettle();
    expect('expense.add'.allMatches(await AppLog.combined()).length, n0, reason: 'INFO is not logged at Warnings');
    await tapVisible(t, find.text('Info'));
    await t.pumpAndSettle();
    expect(await AppLog.combined(), contains('log.level {"from":"warning","to":"info"}'));
    await tapVisible(t, find.text('Debug'));
    await t.pumpAndSettle();
    expect(wc.logLevel, 'all');
    expect(Logger.root.level, Level.ALL);

    // Relay address: a bad one is refused, a good one is saved device-locally and synced (a fake run: no network).
    wc.syncRunner = (relay, k, repo) async =>
        SyncReport(0, 0, 0, caughtUp: true, devices: [SyncDevice('ab12f3', lastSeen: DateTime.now(), isThis: true)]);
    wc.healthCheck = (relay) async {};
    await settingsSection(t, SettingsSection.sync);
    await scrollTo(t, find.text('Test connection'), SettingsScreen, delta: -250);
    final field = find.byKey(const ValueKey('relayAddress'));
    await t.enterText(field, 'gopher://nope');
    await tapVisible(t, find.text('Save address'));
    await t.pumpAndSettle();
    expect(find.text('Enter an address like http://homeserver:8787'), findsOneWidget);
    expect(wc.relayUrl, isNull);
    await t.enterText(field, 'http://it-relay.local:8787');
    await tapVisible(t, find.text('Test connection'));
    await t.pumpAndSettle();
    expect(status('Relay reachable'), findsOneWidget);
    await tapVisible(t, find.text('Save address'));
    await waitFor(t, () => wc.lastSync != null || wc.syncError != null, what: 'the first sync');
    expect(wc.syncError, isNull);
    expect(wc.relayUrl, Uri.parse('http://it-relay.local:8787'));
    expect(wc.repo.localValue('relayUrl'), 'http://it-relay.local:8787');
    expect(status('Up to date'), findsOneWidget);
    expect(find.textContaining('Last sync '), findsOneWidget);

    await tapVisible(t, find.text('Sync now'));
    await waitFor(t, () => !wc.syncing, what: 'sync now');
    expect(await AppLog.combined(), contains('sync.done {"trigger":"button"'));

    // Wallet key dialog and copy.
    await scrollTo(t, find.text('Show wallet key'), SettingsScreen);
    await tapVisible(t, find.text('Show wallet key'));
    await t.pumpAndSettle();
    // QR first (H10): the text shows only after "Show as text".
    expect(find.byKey(const ValueKey('keyQr')), findsOneWidget);
    expect(find.byKey(const ValueKey('keyText')), findsNothing);
    await tapVisible(t, find.byKey(const ValueKey('keyShowText')));
    await t.pumpAndSettle();
    expect(t.widget<SelectableText>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(SelectableText))).data, key);
    await tapVisible(t, find.text('Copy'));
    await t.pumpAndSettle();
    expect(find.text('Key copied'), findsOneWidget);
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, key);
    await Clipboard.setData(const ClipboardData(text: ''));

    await Harness.checkLog();

    // Clear logs: one fresh file that starts with log.cleared.
    await settingsSection(t, SettingsSection.diagnostics);
    await scrollTo(t, find.text('Clear logs'), SettingsScreen);
    await tapVisible(t, find.text('Clear logs'));
    await waitFor(t, () => find.text('Logs cleared.').evaluate().isNotEmpty, what: 'logs cleared');
    final stats = await wc.logStats();
    expect(stats.files, 1);
    expect(logFilesValue(t), startsWith('1 · '));
    expect(await AppLog.combined(), contains('log.cleared'));
    expect(find.byType(DiagnosticsPanel), findsOneWidget);
    await Harness.checkLog();
  });
}
