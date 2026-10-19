// Import through the code the file picker calls (WalletController.importFiles) with the importer's SYNTHETIC fixtures
// and a generated current-month Revolut CSV: result lines, resulting screens, matching to added expenses, re-import.
// Run: tools/emulator.sh test import
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fixtures.dart';
import 'support/harness.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

String lastDate(Uint8List file) => importBankFile(file).transactions.map((n) => n.date).reduce((a, b) => a.compareTo(b) > 0 ? a : b);

void main() {
  Harness.init();
  Harness.private(
      texts: ['Izvod-renamed', 'notes-file', 'account-statement', 'Weekly shop', 'hello,world'],
      cents: [150000, 55000, 2340, 1450, 2050, 1230, 2345, 5499]);

  itest('PBZ .xls, Revolut .xlsx and .csv: result lines, transactions, re-import adds nothing', (t) async {
    final wc = await Harness.start(t);
    await goTab(t, 'Plan');
    final files = [
      ('pbz_synthetic.xls', pbzXls),
      ('revolut_synthetic.xlsx', revolutXlsx),
      ('revolut_synthetic.csv', revolutCsvFile),
      ('notes-file.csv', bytes('hello,world\n1,2\n')),
    ];
    final lines = await wc.importFiles(files);
    await t.pumpAndSettle();
    expect([
      for (final l in lines) (l.file, l.message, l.ok)
    ], [
      ('pbz_synthetic.xls', 'PBZ: 408 new, 0 already here.', true),
      ('revolut_synthetic.xlsx', 'Revolut: 6 new, 0 already here.', true),
      ('revolut_synthetic.csv', 'Revolut: 2 new, 0 already here.', true),
      ('notes-file.csv', 'This is not a PBZ or Revolut export I recognise.', false),
    ]);
    expect(wc.txs, hasLength(416));
    expect(wc.repo.transactions(), hasLength(416));

    await scrollTo(t, find.text('Import bank exports'), PlanScreen);
    for (final l in lines) {
      expect(status('${l.file}: ${l.message}'), findsOneWidget);
    }
    await Harness.shot(t, 'plan-import-lines');

    // Categories from the files.
    String catOf(String desc) => wc.txs.firstWhere((x) => x.tx.description == desc).category;
    expect(catOf('Neto plaća za 12/2025'), 'Salary');
    expect(catOf('PBZ ATM TEST ULICA ZAGREB'), 'Rent',
        reason: 'an ATM withdrawal at or above the rent threshold (default 500) is the rent');
    expect(catOf('POS Revolut**0000* Dublin'), 'Internal transfer');
    expect(catOf('Naplata kredita 0000000000'), 'Loan');
    expect(catOf('PBZ POS PBZ7LIDL HRVATSKA ZAGREB'), 'Groceries');
    expect(catOf('Wolt'), 'Food delivery');
    expect(catOf('Top-up by *0000'), 'Internal transfer');

    await goTab(t, 'Today');
    await scrollTo(t, find.text('Recent'), TodayScreen);
    final pbz = lastDate(pbzXls), rev = [lastDate(revolutXlsx), lastDate(revolutCsvFile)].reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    expect(find.text('PBZ ${shortDate(pbz)} · Revolut ${shortDate(rev)}'), findsOneWidget);
    expect(find.textContaining('Plaćanje po računu'), findsWidgets);

    // Again, and under another name: nothing new.
    final again = await wc.importFiles([...files.take(3), ('Izvod-renamed.xls', pbzXls)]);
    await t.pumpAndSettle();
    expect([
      for (final l in again) l.message
    ], [
      'PBZ: 0 new, 408 already here.',
      'Revolut: 0 new, 6 already here.',
      'Revolut: 0 new, 2 already here.',
      'PBZ: 0 new, 408 already here.',
    ]);
    expect(wc.txs, hasLength(416));
    expect(wc.repo.transactions(includeHidden: true), hasLength(416));
    await Harness.checkLog();
  });

  itest('A current-month Revolut CSV: Spending and Today show it; an added expense is matched, not doubled', (t) async {
    final today = todayIso();
    final yesterday = addDays(today, -1);
    final wc =
        await Harness.start(t, settings: {'salary': 200000, 'paydayDay': 28, 'periodStart': addDays(today, -3), 'salaryConfirmed': true});
    wc.addExpense(amount: 2345, category: 'Groceries', note: 'Weekly shop synthetic', date: yesterday);
    await t.pumpAndSettle();
    expect(wc.period().spent, 2345);

    final csv = revolutCsv([
      ('Card Payment', today, 'LIDL ZAGREB', '-23.45', 'COMPLETED'),
      ('Card Payment', today, 'MCDONALDS ZAGREB', '-8.90', 'COMPLETED'),
      ('Card Payment', today, 'DECATHLON ZAGREB', '-54.99', 'COMPLETED'),
      ('Topup', today, 'Top-up by *0000', '100.00', 'COMPLETED'),
      ('Card Payment', today, 'IKEA ZAGREB', '-15.00', 'PENDING'),
    ]);
    final lines = await wc.importFiles([('account-statement.csv', bytes(csv))]);
    await t.pumpAndSettle();
    expect(lines.single.message, 'Revolut: 4 new, 0 already here, 1 matched to expenses you added.');
    expect(lines.single.ok, isTrue);

    final manual = wc.repo.transactions(includeHidden: true).firstWhere((x) => x.manual);
    expect(manual.matchedTo, isNotNull, reason: 'the hand-added expense is replaced by the bank row');
    expect(wc.txs.where((x) => x.tx.manual), isEmpty);
    final lidl = wc.txs.firstWhere((x) => x.tx.description == 'LIDL ZAGREB');
    expect(lidl.category, 'Groceries');
    expect(manual.matchedTo, lidl.tx.id);
    expect(wc.period().spent, 2345 + 890 + 5499, reason: 'counted once; the top-up is a transfer, the pending row is skipped');
    expect(wc.txs.where((x) => x.tx.description == 'IKEA ZAGREB'), isEmpty);

    await goTab(t, 'Spending');
    expect(find.text('${monthLong(monthOf(today))}: 87\u00A0€ out'), findsOneWidget);
    await scrollTo(t, find.text('Top places in ${monthLong(monthOf(today))}'), SpendingScreen);
    expect(find.widgetWithText(LineItem, 'DECATHLON ZAGREB'), findsOneWidget);
    expect(find.widgetWithText(LineItem, '55\u00A0€'), findsWidgets);
    await scrollTo(t, find.widgetWithText(TxTile, 'LIDL ZAGREB'), SpendingScreen);
    expect(find.text('Weekly shop synthetic'), findsNothing);
    expect(find.text('Top-up by *0000'), findsNothing, reason: 'transfers are hidden');

    await goTab(t, 'Today');
    await scrollTo(t, find.widgetWithText(TxTile, 'DECATHLON ZAGREB'), TodayScreen);
    expect(find.widgetWithText(TxTile, 'Revolut'), findsNWidgets(3));
    expect(find.text('Top-up by *0000'), findsNothing);

    final again = await wc.importFiles([('account-statement.csv', bytes(csv))]);
    expect(again.single.message, 'Revolut: 0 new, 4 already here.');
    expect(wc.period().spent, 2345 + 890 + 5499);
    await Harness.checkLog();
  });
}
