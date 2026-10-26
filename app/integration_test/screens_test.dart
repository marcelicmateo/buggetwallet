// Screenshots of every tab with the synthetic demo wallet, then the app's log. Run on the emulator: tools/emulator.sh screens
// -> dist/screens/*.png and dist/logs/app-emulator.log (written by test_driver/integration_test.dart).
import 'dart:convert';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'demo_data.dart';
import 'support/harness.dart' show navTab, pageList, settingsSection;

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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every tab with a synthetic wallet', (tester) async {
    final wc = await bootstrap(catchErrors: false);
    if (!wc.hasWallet) await wc.createWallet();
    wc.takeKeyBackupPrompt(); // opened below from Today's row
    wc.repo.importBatch(demoBatch(wc.today()));
    wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
    wc.saveCategoryBudgets(demoBudgets);
    seedDemoPlanned(wc.repo, wc.today(), wc.period().end);
    seedDemoBills(wc.repo, wc.today());
    seedDemoSplit(wc.repo);
    await seedDemoAccounts(wc.repo, wc.today());
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

    for (final (i, tab) in ['Budget', 'Bills', 'Save', 'Settings'].indexed) {
      await tester.tap(navTab(tab));
      await tester.pumpAndSettle();
      await binding.takeScreenshot('${i + 2}-${tab.toLowerCase()}');
    }

    // Bills tab (B4, P5): Coming up, To review, Expected bills, then the bills database: To review, Unpaid and Paid, and the sheet of the
    // one waiting for review.
    await tester.tap(navTab('Bills'));
    await tester.pumpAndSettle();
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
    Navigator.of(tester.element(find.byType(BillSheet))).pop();
    await tester.pumpAndSettle();

    // Settings (P5): one page on a phone, two panes on a wide window (a section is then picked in the list). The page that holds
    // the panels is looked up again each time: it is another list after a section is picked.
    await tester.tap(navTab('Settings'));
    await tester.pumpAndSettle();
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

    // Settings › Budgets per category (new in E1): the editor with the saved budgets.
    await settings(SettingsSection.budgets, find.text('Suggest from the last 6 months'), '5-settings-budgets');

    // Settings › Calendars (F3).
    await settings(SettingsSection.calendars, find.text('Import .ics file'), '5-settings-calendars');

    // Settings › Nudges, then the Weekly review day under them (M4; Expected bills is on the Bills tab). Calendars, Nudges and Review
    // day are in this order on the page, so scroll down to each in turn (the list only scrolls forward).
    await tester.scrollUntilVisible(find.textContaining('Remind me at'), 300, scrollable: pageList(SettingsScreen));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-settings-nudges');
    await tester.scrollUntilVisible(find.text('Review day'), 300, scrollable: pageList(SettingsScreen));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-settings-habits');

    // Settings › Sync (relay address, status, devices), then Backup and Export (M5). The relay is a fake run: no network.
    wc.syncRunner = (relay, key, repo) async => SyncReport(0, 0, 0, caughtUp: true, devices: [
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
    await tester.tap(navTab('Budget'));
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

    // The weekly review (M4): the Today card opens it; one row is confirmed, then it closes and Done is left for the real flow.
    await tester.tap(navTab('Today'));
    await tester.pumpAndSettle();
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
    await tester.tap(navTab('Today'));
    await tester.pumpAndSettle();

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
