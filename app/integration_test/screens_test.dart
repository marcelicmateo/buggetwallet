// Screenshots of every tab with the synthetic demo wallet, then the app's log. Run on the emulator: tools/emulator.sh screens
// -> dist/screens/*.png and dist/logs/app-emulator.log (written by test_driver/integration_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'demo_data.dart';
import 'support/harness.dart' show navTab;

/// Distinctive texts of the synthetic data: none of them may reach the log.
const _private = [
  'LIDL', 'KONZUM', 'IKEA', 'MCDONALDS', 'WOLT', 'NETFLIX', 'Neto plaća', 'ATM TEST ULICA', 'Naplata kredita', 'POVRAT POREZA', //
  'Revolut**', 'Desk lamp note', 'Gift card wish', 'Holiday fund', 'statement-secret', '€',
  '1400.00', '550.00', '12.99', '480.00', '98.76', '43.21', '1,400', '1.400,00',
];

/// The same amounts in cents (as whole numbers, so ms and byte counts can't match by accident).
final _cents = RegExp(r'(?<![\d.])(140000|100000|55000|25000|1299|48000|9876|4321)(?![\d.])');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every tab with a synthetic wallet', (tester) async {
    final wc = await bootstrap(catchErrors: false);
    if (!wc.hasWallet) await wc.createWallet();
    wc.repo.importBatch(demoBatch(wc.today()));
    wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
    wc.saveCategoryBudgets(demoBudgets);

    await tester.pumpWidget(BudgetWalletApp(wc: wc));
    AppLog.startMonitors();
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('1-today');

    for (final (i, tab) in ['Spending', 'Wishlist', 'Goals', 'Plan'].indexed) {
      await tester.tap(navTab(tab));
      await tester.pumpAndSettle();
      await binding.takeScreenshot('${i + 2}-${tab.toLowerCase()}');
    }

    // Plan › Budgets per category (new in E1): the editor with the saved budgets.
    final plan = find.descendant(of: find.byType(PlanScreen), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Suggest from the last 6 months'), 300, scrollable: plan);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-budgets');

    // Plan › Weekly review day, Expected bills and Nudges (M4).
    await tester.scrollUntilVisible(find.text('Review day'), 300, scrollable: plan);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-habits');
    await tester.scrollUntilVisible(find.textContaining('Remind me at'), 300, scrollable: plan);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-nudges');

    // Plan › Backup and Export (M5): a throwaway sync folder, one backup, then the Export panel.
    final folder = await Directory.systemTemp.createTemp('bw-screens-sync');
    addTearDown(() => folder.delete(recursive: true));
    await wc.setSyncFolder(folder.path);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Back up now'), 300, scrollable: plan);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-backup');
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Last backup'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4)); // the toast goes away, so it does not cover the next screenshots
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-backup-done');
    await tester.scrollUntilVisible(find.text('Plain files, not encrypted.'), 300, scrollable: plan);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('5-plan-export');

    // Plan › Diagnostics at the bottom of the Plan tab; switch the level there and back.
    await tester.scrollUntilVisible(find.text('Clear logs'), 400, scrollable: plan);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('6-plan-diagnostics');
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();

    // Search (M5): the icon on Spending, a query, the ruled results, Esc closes.
    await tester.tap(navTab('Spending'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('searchOpen')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('searchField')), 'lidl');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('2-spending-search');
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
    expect(log, contains('review.open'));
    expect(log, contains('log.level {"from":"info","to":"all"}'));
    for (final p in _private) {
      expect(log, isNot(contains(p)), reason: 'private text "$p" in the log');
    }
    expect(_cents.firstMatch(log)?.group(0), isNull, reason: 'an amount in cents in the log');
    expect(log, isNot(contains(await wc.keyText())));
  });
}
