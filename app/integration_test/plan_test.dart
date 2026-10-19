// Tap-through on Plan: numbers (validation, save), start a new month, sync folder, wallet key, Diagnostics (level,
// log size, put logs in the sync folder, clear). Run: tools/emulator.sh test plan
import 'dart:io';

import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/diagnostics.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/harness.dart';

Finder inPlan(Finder f) => find.descendant(of: find.byType(PlanScreen), matching: f);
String fieldText(WidgetTester t, String label) => t.widget<TextField>(inPlan(field(label))).controller!.text;

Future<void> fill(WidgetTester t, Map<String, String> values) async {
  for (final e in values.entries) {
    await scrollTo(t, inPlan(field(e.key)), PlanScreen);
    await t.enterText(inPlan(field(e.key)), e.value);
  }
  await t.pumpAndSettle();
}

Future<void> save(WidgetTester t) async {
  await scrollTo(t, find.text('Save numbers'), PlanScreen);
  await tapVisible(t, find.text('Save numbers'));
  await t.pumpAndSettle();
}

/// The value of the "Log files" line: `files · size`.
String logFilesValue(WidgetTester t) {
  final texts = t.widgetList<Text>(find.descendant(of: find.widgetWithText(LineItem, 'Log files'), matching: find.byType(Text))).toList();
  return texts.last.data!;
}

void main() {
  Harness.init();
  Harness.private(cents: [250000, 60050, 25000, 4599, 8000, 70000, 40000, 260000]);

  itest('Plan numbers: bad input is refused, good input is saved and used everywhere', (t) async {
    final wc = await Harness.start(t);
    await goTab(t, 'Plan');
    await fill(t, {'Salary per month': '2500', 'Rent': '600,50', 'Loan': 'abc'});
    await save(t);
    expect(find.text('Enter numbers only, like 1500 or 1500.50.'), findsOneWidget);
    expect(inPlan(find.text('Numbers only')), findsOneWidget, reason: 'the wrong field says why');
    expect(wc.settings.salary, 0, reason: 'nothing is saved while a field is wrong');
    await fill(t, {'Loan': '-5'});
    await save(t);
    expect(find.text('Enter numbers only, like 1500 or 1500.50.'), findsOneWidget);
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
    expect(fieldText(t, 'Latest payday'), '28', reason: 'the field shows what was saved');
    expect(s.paydayDay, 28, reason: 'the payday is kept within 1-28');
    expect(s.salaryConfirmed, isTrue, reason: 'typing a salary confirms it');
    final p = wc.period();
    // 2500 - 600.50 - 250 - 45.99 - 200 (default goals) = 1403.51
    expect(p.flexBudget, 140351);
    await scrollTo(t, find.text('PAYDAY PLAN'), PlanScreen, delta: -250);
    expect(find.text('${money(140351, 'EUR', decimals: 0)} to spend · ${money(p.planDaily, 'EUR', decimals: 0)}/day'), findsOneWidget);
    await goTab(t, 'Wishlist');
    expect(find.text('Anything over €80 waits 48 hours on the wishlist first.'), findsOneWidget);
    await goTab(t, 'Today');
    expect(find.textContaining('Planning on'), findsNothing);

    // A wait below zero is refused like the other numbers; nothing is saved.
    await goTab(t, 'Plan');
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
    await scrollTo(t, inPlan(find.byType(DropdownButtonFormField<String>)), PlanScreen);
    await pickDropdown(t, inPlan(find.byType(DropdownButtonFormField<String>)), 'USD');
    await save(t);
    expect(wc.settings.currency, 'USD');
    await goTab(t, 'Today');
    expect(find.textContaining(r'$'), findsWidgets);
    expect(find.textContaining('€'), findsNothing);

    // A change from elsewhere (sync from another device, "Looks right" on Today) while Plan is open.
    wc.updateSettings({'rent': 70000});
    await t.pumpAndSettle();
    await goTab(t, 'Plan');
    await scrollTo(t, inPlan(field('Rent')), PlanScreen);
    expect(fieldText(t, 'Rent'), '700', reason: 'Plan fields follow changes made elsewhere');
    await save(t);
    expect(find.text('Nothing to save'), findsOneWidget);
    expect(wc.settings.rent, 70000, reason: 'Save numbers keeps a change made elsewhere');

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

  itest('Start new month from Plan: cancel, today, another day', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, settings: {'salary': 200000, 'salaryConfirmed': true, 'periodStart': addDays(today, -10)});
    await goTab(t, 'Plan');
    final button = find.text('Salary landed: start new month');
    await scrollTo(t, button, PlanScreen);
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

  itest('Sync folder, wallet key, Diagnostics: level, log size, logs to the sync folder, clear', (t) async {
    final wc = await Harness.start(t);
    final key = await wc.keyText();
    final tmp = await getTemporaryDirectory();
    final sync = '${tmp.path}${Platform.pathSeparator}bw-it-sync-${DateTime.now().millisecondsSinceEpoch}';
    Harness.private(texts: [sync, 'bw-it-sync', tmp.path]);
    await goTab(t, 'Plan');

    // Log level.
    await scrollTo(t, find.text('Clear logs'), PlanScreen);
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

    // Sync folder by typed path: the folder is created and synced into.
    await scrollTo(t, find.text('Type path'), PlanScreen, delta: -250);
    expect(find.text('Put in sync folder'), findsNothing);
    await tapVisible(t, find.text('Type path'));
    await t.pumpAndSettle();
    await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), sync);
    await tapVisible(t, find.text('Use folder'));
    await waitFor(t, () => wc.lastSync != null || wc.syncError != null, what: 'the first sync');
    expect(wc.syncError, isNull);
    expect(wc.syncFolder, sync);
    expect(wc.repo.localValue('syncFolder'), sync);
    expect(Directory(sync).listSync(recursive: true).whereType<File>(), isNotEmpty, reason: 'sync wrote its files');
    expect(find.textContaining('Synced at '), findsOneWidget);
    expect(find.text(sync), findsOneWidget, reason: 'the folder is shown');

    await tapVisible(t, find.text('Sync now'));
    await waitFor(t, () => !wc.syncing, what: 'sync now');
    expect(await AppLog.combined(), contains('sync.done {"trigger":"button"'));

    // Wallet key dialog and copy.
    await scrollTo(t, find.text('Show wallet key'), PlanScreen);
    await tapVisible(t, find.text('Show wallet key'));
    await t.pumpAndSettle();
    expect(t.widget<SelectableText>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(SelectableText))).data, key);
    await tapVisible(t, find.text('Copy'));
    await t.pumpAndSettle();
    expect(find.text('Key copied'), findsOneWidget);
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, key);
    await Clipboard.setData(const ClipboardData(text: ''));

    // Logs into the sync folder's diagnostics/.
    await scrollTo(t, find.text('Put in sync folder'), PlanScreen);
    await tapVisible(t, find.text('Put in sync folder'));
    final want = '$sync${Platform.pathSeparator}diagnostics${Platform.pathSeparator}${wc.logFileName()}';
    await waitFor(t, () => find.text('Saved to $want').evaluate().isNotEmpty, what: 'logs saved');
    final saved = File(want).readAsStringSync();
    expect(saved, contains('app.start'));
    expect(saved, isNot(contains(key)));
    expect(await AppLog.combined(), contains('log.saved {"to":"syncFolder"'));

    // Without a sync folder: the fallback behind "Save logs…" writes to the app documents folder.
    await wc.setSyncFolder(null);
    await t.pumpAndSettle();
    expect(find.text('Put in sync folder'), findsNothing);
    Directory? docs;
    try {
      docs = await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      // Linux finds it with the xdg-user-dir tool, which a bare build container may not have.
      if (!Platform.isLinux) rethrow;
      debugPrint('SKIPPED documents-folder fallback: no documents folder on this Linux (xdg-user-dir missing)');
    }
    if (docs != null) {
      Harness.private(texts: [docs.path]);
      final path = await wc.saveLogsToFolder();
      expect(path, '${docs.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}${wc.logFileName()}');
      expect(File(path).existsSync(), isTrue);
      File(path).deleteSync();
      expect(await AppLog.combined(), contains('log.saved {"to":"documents"'));
    }

    await Harness.checkLog();

    // Clear logs: one fresh file that starts with log.cleared.
    await scrollTo(t, find.text('Clear logs'), PlanScreen);
    await tapVisible(t, find.text('Clear logs'));
    await waitFor(t, () => find.text('Logs cleared.').evaluate().isNotEmpty, what: 'logs cleared');
    final stats = await wc.logStats();
    expect(stats.files, 1);
    expect(logFilesValue(t), startsWith('1 · '));
    expect(await AppLog.combined(), contains('log.cleared'));
    expect(find.byType(DiagnosticsPanel), findsOneWidget);
    Directory(sync).deleteSync(recursive: true);
    await Harness.checkLog();
  });
}
