// Screenshots of every tab with the synthetic demo wallet, then the app's log. Run on the emulator: make emulator-screens
// -> dist/screens/*.png and dist/logs/app-emulator.log (written by test_driver/integration_test.dart).
import 'dart:async';
import 'dart:convert';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/account_question.dart' show askWhichAccount;
import 'package:budget_wallet/src/screens/accounts_panel.dart' show askBankBalance;
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/budget.dart' show BudgetScreen;
import 'package:budget_wallet/src/screens/import_preview_sheet.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/plan_screen.dart' show PlanScreen;
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/tag_detail.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../test/support/seams.dart';
import 'demo_data.dart';
import 'support/harness.dart' show Harness, goTab, navTab, pageList, settingsSection;

/// Distinctive texts of the synthetic data: none of them may reach the log.
const _private = [
  'LIDL', 'KONZUM', 'IKEA', 'MCDONALDS', 'WOLT', 'NETFLIX', 'Neto plaća', 'ATM TEST ULICA', 'Naplata kredita', 'POVRAT POREZA', //
  'Demo Water Utility', 'Demo Review Shop', 'Demo Electronics', 'Kettle', 'HR1210010051863000160', '1234-5678', '54.32', '71.23', '99.99',
  '11111111-2222', 'porezna', //
  'Revolut**', 'Desk lamp note', 'Gift card wish', 'Holiday fund', 'statement-secret', '€',
  '1400.00', '550.00', '12.99', '480.00', '98.76', '43.21', '1,400', '1.400,00',
];

/// The same amounts in cents (as whole numbers, so ms and byte counts can't match by accident).
final _cents = RegExp(r'(?<![\d.])(140000|100000|55000|25000|1299|48000|9876|4321|5432|7123|9999)(?![\d.])');

/// The Budget tab opens on Explore since ENG E4; selects the Spending page when it is there.
Future<void> showSpending(WidgetTester t) async {
  final spending = find.byKey(const ValueKey('budgetSpending'));
  if (spending.evaluate().isNotEmpty) {
    await t.tap(spending);
    await t.pumpAndSettle();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every tab with a synthetic wallet', (tester) async {
    await AppLog.init(catchErrors: false);
    await Harness.wipe(); // a fresh wallet, also when another test file ran before in this process
    await AppLog.clear();
    final wc = await seamedBoot((deps) => bootstrap(catchErrors: false, deps: deps));
    if (!wc.hasWallet) await wc.createWallet();
    wc.takeKeyBackupPrompt(); // opened below from Today's row
    wc.repo.importBatch(demoBatch(wc.today()));
    wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
    wc.saveCategoryBudgets(demoBudgets);
    seedDemoPlanned(wc.repo, wc.today(), wc.period().end);
    seedDemoBills(wc.repo, wc.today());
    seedDemoSplit(wc.repo);
    await seedDemoAccounts(wc.repo, wc.today());
    seedDemoIous(wc.repo, wc.today());
    seedDemoPin(wc.repo, wc.today());
    wc.reload();
    await wc.importIcsFile('demo.ics', Uint8List.fromList(utf8.encode(demoIcs(wc.today()))));

    await tester.pumpWidget(BudgetWalletApp(wc: wc));
    AppLog.startMonitors();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-today');
    // The save-key step sits in the one setup panel under the hero; the button may be below the fold.
    await tester.ensureVisible(find.text('Save now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save now'));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-today-key');
    Navigator.of(tester.element(find.byType(KeyBackupSheet))).pop();
    await tester.pumpAndSettle();
    // Hide the setup panel (it becomes one line) so the next shots show Today as it is after setup.
    await tester.ensureVisible(find.byKey(const ValueKey('setupHide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setupHide')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setupLine')), findsOneWidget);

    // Today's Coming up and heads-up lines, then the Upcoming screen (F3).
    await tester.scrollUntilVisible(find.byKey(const ValueKey('comingUpLine')), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-today-coming-up');
    await tester.tap(find.byKey(const ValueKey('comingUpLine')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-upcoming');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // Overview (ENG E2): found and pinned, the hours switch, and the Findings screen (E3).
    await tester.ensureVisible(find.byKey(const ValueKey('foundSection')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-overview-found');
    await tester.ensureVisible(find.byKey(const ValueKey('amountsHours')));
    await tester.tap(find.byKey(const ValueKey('amountsHours')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-overview-hours');
    await tester.tap(find.byKey(const ValueKey('amountsMoney')));
    await tester.pumpAndSettle();
    await tester.drag(find.ancestor(of: find.byKey(const ValueKey('foundSection')), matching: find.byType(Scrollable)).first,
        const Offset(0, 3000)); // back to the top
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('foundAll')));
    await tester.tap(find.byKey(const ValueKey('foundAll')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-findings');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    for (final (i, tab) in ['Budget', 'Bills', 'Save', 'Settings'].indexed) {
      await goTab(tester, tab);
      await binding.takeScreenshot('${i + 2}-${tab.toLowerCase()}');
      if (tab == 'Budget') {
        // ENG E4: the Explore page (the Budget tab's first page) and a project (E5).
        await tester.tap(find.byKey(const ValueKey('budgetExplore')));
        await tester.pumpAndSettle();
        await binding.takeScreenshot('2-explore');
        await tester.tap(find.byKey(const ValueKey('exploreRange:All')));
        await tester.pumpAndSettle();
        await binding.takeScreenshot('2-explore-all');
      }
    }
    // ENG E1: Plan has two pages, Payday plan and Saving (the choice is remembered).
    await goTab(tester, 'Plan');
    await tester.tap(find.byKey(const ValueKey('planPayday')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('2-budget-plan');

    // Stage Q: the payday forecast under the plan, the bills cost header, the Owed panel with its IOU sheet, the import preview and the
    // bank balance question.
    await goTab(tester, 'Bills');
    await binding.takeScreenshot('3-bills-top');
    await tester.ensureVisible(find.byKey(const ValueKey('recurringCost')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('3-bills-cost');
    await goTab(tester, 'Save');
    await tester.ensureVisible(find.byKey(const ValueKey('owedPanel')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('4-save-owed');
    await tester.tap(find.byKey(ValueKey('iou:${wc.iousOpen().first.iou.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('iouSheet')), findsOneWidget);
    await binding.takeScreenshot('4-save-iou');
    await tester.tap(find.byKey(const ValueKey('sheetClose')));
    await tester.pumpAndSettle();
    final ctx = tester.element(find.byType(Scaffold).first);
    NormalizedTransaction row(String id, String date, int cents, String d) => NormalizedTransaction(
        id: id, source: 'pbz', date: date, amountMinor: cents, currency: 'EUR', bankType: 'POS plaćanje', description: d);
    final known = demoBatch(wc.today()).transactions.take(3);
    final preview = wc.repo.previewImport(ImportBatch(source: 'pbz', transactions: [
      ...known,
      row('demo-new-1', addDays(wc.today(), -1), -2150, 'POS KONZUM 0000 ZAGREB'),
      row('demo-new-2', wc.today(), -980, 'POS WOLT ZAGREB'),
      row('demo-new-3', wc.today(), 12000, 'UPLATA DEMO SIDE JOB'),
    ]));
    unawaited(openImportPreview(ctx, preview, 'PBZ'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('previewGroup:fresh')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('8-import-preview');
    await tester.tap(find.byKey(const ValueKey('importPreviewCancel')));
    await tester.pumpAndSettle();
    final pbz = wc.accountsAll().firstWhere((a) => a.source == 'pbz');
    unawaited(askBankBalance(
        ctx,
        wc,
        BankQuestion(
            accountId: pbz.id, name: pbz.name, currency: pbz.currency, date: wc.today(), appCents: wc.appBalanceOn(pbz.id, wc.today())),
        fromImport: true));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('8-bank-question');
    await tester.tap(find.byKey(const ValueKey('bankCheckSkip')));
    await tester.pumpAndSettle();

    // Bills tab (B4, P5): Coming up, To review, Expected bills, then the bills database: To review, Unpaid and Paid, and the sheet of the
    // one waiting for review.
    await goTab(tester, 'Bills');
    final bills = find.descendant(of: find.byType(BillsScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Import bill file'), 300, scrollable: bills);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('3-bills-slips');
    final review = wc.billLists().review.first;
    final reviewRow = find.byKey(ValueKey('bill:${review.id}'));
    await tester.scrollUntilVisible(reviewRow, 300, scrollable: bills, duration: const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    // The "To review" heading must be in the shot: put it near the top, the rows are right under it.
    await Scrollable.ensureVisible(tester.element(find.text('TO REVIEW')), alignment: 0.1);
    await tester.pumpAndSettle();
    expect(find.text('TO REVIEW'), findsOneWidget);
    await binding.takeScreenshot('3-bills-rows');
    // The row must be on screen before the tap (Android's taller bars hid it once), then wait (bounded) until the sheet is up.
    await tester.ensureVisible(reviewRow);
    await tester.pumpAndSettle();
    await tester.tap(reviewRow);
    for (var i = 0; i < 40 && find.text('Bill to review').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('Bill to review'), findsOneWidget);
    await binding.takeScreenshot('3-bill-sheet');
    // UX-A: a quick length sets the warranty date, and the reminder line then shows under it.
    final warrantyChip = find.byKey(const ValueKey('warranty:chip:1y'));
    await tester.ensureVisible(warrantyChip);
    await Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('warrantyDate'))), alignment: 0.1);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('3-bill-dates-empty');
    await tester.tap(warrantyChip);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('warrantyDate'))), alignment: 0.1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('warranty:reminder')), findsOneWidget);
    await binding.takeScreenshot('3-bill-warranty');
    Navigator.of(tester.element(find.byType(BillSheet))).pop();
    await tester.pumpAndSettle();

    // Settings (P5): one page on a phone, two panes on a wide window (a section is then picked in the list). The page that holds
    // the panels is looked up again each time: it is another list after a section is picked.
    await goTab(tester, 'Settings');
    Future<void> settings(SettingsSection section, Finder target, String shot) async {
      await settingsSection(tester, section);
      // The list only scrolls forward, and on a phone's one page the sections follow each other in page order (Sync and Backup come
      // before Calendars): start each look from the top.
      tester.state<ScrollableState>(pageList(SettingsScreen)).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(target, 300, scrollable: pageList(SettingsScreen));
      await tester.pumpAndSettle();
      await binding.takeScreenshot(shot);
    }

    // Budget › Plan › Budgets per category (E1; UX-B1 moved it here from Settings): the editor with the saved budgets.
    wc.setPlanView('payday');
    await goTab(tester, 'Plan');
    await tester.scrollUntilVisible(find.text('Suggest from the last 6 months'), 300, scrollable: pageList(PlanScreen));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-budgets');
    // The Plan page keeps its scroll, and its lazy list builds nothing far from the window: back to the top for the forecast below.
    tester.state<ScrollableState>(pageList(PlanScreen)).position.jumpTo(0);
    await tester.pumpAndSettle();
    await goTab(tester, 'Settings');

    // Settings › Calendars (F3).
    await settings(SettingsSection.calendars, find.text('Import .ics file'), '5-settings-calendars');

    // Settings › Nudges, then the Weekly review day under them (M4; Expected bills is on the Bills tab). Calendars, Nudges and Review
    // day are in this order on the page, so scroll down to each in turn (the list only scrolls forward).
    await tester.scrollUntilVisible(find.textContaining('Remind me at'), 300, scrollable: pageList(SettingsScreen));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-settings-nudges');
    await tester.scrollUntilVisible(find.text('WEEKLY REVIEW'), 300, scrollable: pageList(SettingsScreen));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-settings-habits');

    // Settings › Sync (relay address, status, devices), then Backup and Export (M5). The relay is a fake run: no network.
    wc.seams.syncRunner = (relay, key, repo) async => SyncReport(0, 0, 0, caughtUp: true, devices: [
          SyncDevice('ab12f3', lastSeen: DateTime.now().subtract(const Duration(minutes: 5)), isThis: true),
          SyncDevice('c9d8e7', lastSeen: DateTime.now().subtract(const Duration(hours: 3))),
        ]);
    await wc.setRelay(Uri.parse('http://homeserver:8787'));
    await tester.pumpAndSettle();
    await settings(SettingsSection.sync, find.text('Test connection'), '5-settings-sync');
    await settings(SettingsSection.backup, find.text('Back up now'), '5-settings-backup');
    // "Back up now" opens the system save dialog (no portal or activity to drive here), so run the part before it: it logs backup.done.
    await wc.backupDownload();
    await tester.scrollUntilVisible(find.text('Plain files, not encrypted.'), 300, scrollable: pageList(SettingsScreen));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-settings-export');

    // Settings › Diagnostics; switch the level there and back.
    await settings(SettingsSection.diagnostics, find.text('Clear logs'), '6-settings-diagnostics');
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();

    // Search (M5): the icon on Budget, a query, the ruled results, Esc closes.
    await goTab(tester, 'Budget');
    await tester.tap(find.byKey(const ValueKey('budgetSpending')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('searchOpen')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('searchField')), 'lidl');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('2-budget-search');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('searchField')), findsNothing);

    // Stage Q: the payday forecast under the plan (last on Budget: it scrolls the page).
    await goTab(tester, 'Plan');
    await tester.tap(find.byKey(const ValueKey('planPayday')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('forecastPanel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('forecastChart')), findsOneWidget);
    await binding.takeScreenshot('2-budget-forecast');

    // The weekly review (M4): the Today card opens it; one row is confirmed, then it closes and Done is left for the real flow.
    await goTab(tester, 'Today');
    await tester.scrollUntilVisible(find.text('Start review'), 300,
        scrollable: find.descendant(of: find.byType(TodayScreen), matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(find.text('Start review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start review'));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);
    await binding.takeScreenshot('7-review');
    if (find.text('Looks right').evaluate().isNotEmpty) {
      await tester.tap(find.text('Looks right').first);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // The Pay-period report (RX7): the chip in the app bar (phone) or the badge in the rail opens it; one step back to a finished period.
    final chip = find.byKey(const ValueKey('periodChip')), badge = find.byKey(const ValueKey('periodBadgeTap'));
    await tester.tap(chip.evaluate().isNotEmpty ? chip : badge);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reportKept')), findsOneWidget);
    await binding.takeScreenshot('9-period-report');
    await tester.tap(find.byKey(const ValueKey('reportPrev')));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('9-period-report-previous');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // Category and tag detail (RX8): a category row on Budget opens the category dashboard; a tag on the newest spending rows opens the tag's.
    await tester.tap(navTab('Budget'));
    // The review changed data: the Budget page is rebuilt while the app is idle, a frame at a time.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await showSpending(tester); // the Budget tab opens on Explore (E4); these steps look at the Spending page

    final catRow =
        find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('categoryRow_'));
    await tester.ensureVisible(catRow.first);
    await tester.pumpAndSettle();
    await tester.tap(catRow.first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detailTotal')), findsOneWidget);
    await binding.takeScreenshot('9-category-detail');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    final tag = await wc.addTag('Synthetic trip');
    final newest = wc.txs.where((x) => x.amount < 0 && x.kind != BudgetKind.transfer).toList()..sort((a, b) => b.date.compareTo(a.date));
    for (final x in newest.take(5)) {
      await wc.setPaymentTag(x.tx.id, tag, true);
    }
    unawaited(openTag(tester.element(find.byType(Scaffold).first), wc, tag));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('projectTotal')), findsOneWidget);
    await binding.takeScreenshot('9-project');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // UX-A: a payment in yen (no decimals), the account form for a coin, the currency picker, and the built-in rules with their menu.
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      NormalizedTransaction(
          id: transactionId(wc.today(), -150000, 'JPY SYNTHETIC RAMEN', 0),
          source: 'pbz',
          date: wc.today(),
          amountMinor: -150000,
          currency: 'JPY',
          bankType: 'POS',
          description: 'JPY SYNTHETIC RAMEN'),
    ]));
    wc.reload();
    await tester.tap(navTab('Budget'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await showSpending(tester); // the Budget tab opens on Explore (E4); these steps look at the Spending page
    final spendingSwitch = find.byKey(const ValueKey('budgetSpending')); // Spending may be scrolled down
    if (spendingSwitch.evaluate().isNotEmpty) await tester.tap(spendingSwitch);
    await tester.pumpAndSettle();
    tester.state<ScrollableState>(pageList(BudgetScreen)).position.jumpTo(0);
    await tester.pumpAndSettle();
    final yenRow = find.textContaining('JPY SYNTHETIC RAMEN');
    // The payments list is lazy: on a phone the row is below the tiles and not built until it is scrolled to.
    await tester.scrollUntilVisible(yenRow, 300, scrollable: pageList(BudgetScreen), maxScrolls: 60);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('10-yen-row');
    await goTab(tester, 'Settings');
    await settings(SettingsSection.accounts, find.byKey(const ValueKey('walletCurrency')), '10-settings-accounts');
    Future<void> tapKey(String key) async {
      final f = find.byKey(ValueKey(key));
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tester.ensureVisible(find.byKey(const ValueKey('accountAdd')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('accountAdd')));
    await tester.pumpAndSettle();
    await tapKey('accountKind:bank');
    await binding.takeScreenshot('10-account-form-bank');
    await tapKey('accountKind:crypto');
    await binding.takeScreenshot('10-account-form-crypto');
    await tapKey('accountCurrency');
    await binding.takeScreenshot('10-currency-picker');
    await tester.tapAt(const Offset(5, 5)); // the barrier closes the picker, then the form
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    // UX-ACC: "Which account is this?" for a pocket no account claims yet.
    final usd = wc.accountsAll().firstWhere((a) => a.currency == 'USD');
    final unknown = wc.repo.unknownImportAccounts(ImportBatch(source: 'revolut', transactions: [
      NormalizedTransaction(
          id: 'demo-pocket-1',
          source: 'revolut',
          date: wc.today(),
          amountMinor: -500,
          currency: 'USD',
          bankType: 'Card Payment',
          description: 'DEMO POCKET SHOP',
          account: 'Pocket 2',
          accountKey: 'ak:0123456789abcdef'),
    ]));
    unawaited(askWhichAccount(tester.element(find.byType(Scaffold).first), wc, unknown.single));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('11-account-question');
    await tester.tap(find.byKey(const ValueKey('accountPickCancel')));
    await tester.pumpAndSettle();
    // UX-FX: ECB rates came in (a hand rate for yen wins), then a download failed: the panel says so plainly.
    final ecbCsv = 'Date,USD,JPY,\n${[for (var i = 0; i < 40; i++) '${addDays(wc.today(), -i)},1.0900,160.00,'].join('\n')}\n';
    wc.seams.ecbFetcher = (_) async => utf8.encode(ecbCsv);
    await wc.getRatesNow();
    wc.setFxRate('JPY', 6000);
    wc.seams.ecbFetcher = (_) async => throw const EcbFetchException(EcbFetchFailure.unreachable, 'x');
    await wc.getRatesNow();
    await settings(SettingsSection.accounts, find.byKey(const ValueKey('ecbGetNow')), '11-settings-currencies');
    await settings(SettingsSection.accounts, find.byKey(ValueKey('accountHome:${usd.id}')), '11-account-foreign');
    // The Rules shots return with the Tags window (UX-B2).
    await tester.pumpAndSettle();

    // After the screenshots: logged actions with private-looking synthetic values, to prove they stay out of the log.
    wc.addExpense(amount: 9876, category: 'Home & tools', note: 'Desk lamp note', date: wc.today());
    wc.addWish('Gift card wish', 4321);
    wc.saveGoal(name: 'Holiday fund', target: 48000, saved: 0, monthly: 9876);
    final csv = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
        'CARD_PAYMENT,Current,${wc.today()} 10:00:00,${wc.today()} 11:00:00,IKEA ZAGREB,-98.76,0,EUR,COMPLETED,43.21\n';
    await wc.importFiles([('statement-secret-name.csv', Uint8List.fromList(utf8.encode(csv)))]);
    await wc.importScannedCode(
        const ScannedCode(CodeKind.qr, 'https://porezna.gov.hr/rn?jir=11111111-2222-4333-8444-555555555555&datv=20260101_1000&izn=9999'));
    final t = wc.txs.firstWhere((x) => x.tx.description.contains('IKEA ZAGREB'));
    wc.setCategory(t.tx, 'Shopping', always: true);
    await goTab(tester, 'Today');

    // Let the engine report frame timings (batched), then close the frame window.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    AppLog.logFrameWindow();
    AppLog.logMemory();
    AppLog.stopMonitors();

    final log = await AppLog.combined();
    await AppLog.close();
    (binding.reportData ??= <String, dynamic>{})['log'] = log;

    expect(log, contains('app.start'));
    expect(log, contains('app.info'));
    expect(log, contains('frames.window'));
    expect(log, contains('import.file'));
    expect(log, contains('nav.tab'));
    expect(log, contains('backup.done'));
    expect(log, contains('search.run'));
    expect(log, contains('bills.import'));
    expect(log, contains('review.open'));
    expect(log, contains('log.level {"from":"info","to":"all"}'));
    // Each line starts with an ISO timestamp ("…T05:36:12.993+00:00"); its seconds can spell a demo amount by chance.
    final body = log.replaceAll(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+[+-]\d\d:\d\d ', multiLine: true), '');
    for (final p in _private) {
      expect(body, isNot(contains(p)), reason: 'private text "$p" in the log');
    }
    expect(_cents.firstMatch(body)?.group(0), isNull, reason: 'an amount in cents in the log');
    expect(log, isNot(contains(await wc.keyText())));
  });
}
