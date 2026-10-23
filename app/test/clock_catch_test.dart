// HUbb 1: a refused write (the device clock is behind) used to be swallowed by the catch-alls around a bank import, a bill import
// and "skip a bill" (wrong message, a SEVERE log or silence). Each now raises the clock dialog and, where there is a message,
// says the clock sentence. SYNTHETIC data.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/bill_inputs.dart' show CodeKind, ScannedCode;
import 'package:budget_wallet/src/clock_notice.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;

import 'support/bills.dart';
import 'support/layout.dart';
import 'support/wallet.dart';

const _revolutCsv = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
    'Card Payment,Current,2026-10-01 10:00:00,2026-10-02 10:00:00,Synthetic shop,-12.30,0.00,EUR,COMPLETED,100.00\n';

void main() {
  late List<String> lines;
  late int wall;
  setUp(() {
    wall = DateTime(2026, 10, 20, 12).millisecondsSinceEpoch;
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });
  String log() => lines.join('\n');

  /// A wallet whose repo reads [wall]; one write sets its high-water mark, then [behind] sets the clock back.
  WalletController wallet() {
    final repo = WalletRepo.inMemory(now: () => wall);
    final wc = WalletController.forTest(repo,
        key: VaultKey.generate(), clock: () => DateTime(2026, 10, 20, 12), billInputs: FakeBillInputs().inputs);
    wc.pdfParser = inlinePdfParser;
    wc.snoozeKeyBackup();
    addTearDown(wc.dispose);
    repo.updateSettings({'reviewDay': 3});
    return wc;
  }

  void behind() => wall -= 3 * 3600 * 1000;

  Future<void> expectDialogThenClose(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('clockBehindDialog')), findsOneWidget);
    expect(find.text(clockBehindText), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('clockBehindOk')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('clockBehindDialog')), findsNothing);
  }

  testWidgets('a bank import with the clock behind shows the dialog and the clock sentence, not "Couldn\'t read this file"', (t) async {
    final wc = wallet();
    await pumpFull(t, wc, 1, size: const Size(400, 900));
    behind();
    late List<ImportLine> result;
    await t.runAsync(() async => result = await wc.importFiles([('synthetic.csv', Uint8List.fromList(utf8.encode(_revolutCsv)))]));
    expect(result.single.message, clockBehindText);
    expect(result.single.ok, isFalse);
    expect(wc.txs, isEmpty);
    expect(log(), isNot(contains('import.failed')));
    expect(log(), isNot(contains('SEVERE')));
    await expectDialogThenClose(t);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('a bill file (and a scanned code) with the clock behind: the dialog and the clock sentence, not "Couldn\'t add"', (t) async {
    final wc = wallet();
    await pumpFull(t, wc, 1, size: const Size(400, 900));
    behind();
    late BillImport r;
    await t.runAsync(() async => r = await wc.importBillFile(smallPdf(['Ukupno: 99,99 EUR']), 'pdf'));
    expect(r.kind, BillImportKind.clockBehind);
    expect(r.message, clockBehindText);
    expect(r.ok, isFalse);
    expect(log(), isNot(contains('bills.importFailed')));
    await expectDialogThenClose(t);

    // the same for a code the camera read
    late BillImport c;
    await t.runAsync(() async => c = await wc.importScannedCode(const ScannedCode(CodeKind.pdf417, hub3Slip)));
    expect(c.kind, BillImportKind.clockBehind);
    expect(log(), isNot(contains('bills.importFailed')));
    await expectDialogThenClose(t);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('skipping a bill with the clock behind shows the dialog (it used to be silent) and changes nothing', (t) async {
    final wc = wallet();
    for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) {
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [syntheticTx(d, -2999, 'POS plaćanje', 'POS SYNTHGYM ZAGREB')]));
    }
    wc.refreshRecurring();
    wc.confirmRecurring(wc.recurringBills().first.id);
    final before = wc.recurringBills().first.nextDue;
    await pumpFull(t, wc, 1, size: const Size(400, 900));
    behind();
    await t.runAsync(() => wc.skipRecurring(wc.recurringBills().first.id));
    expect(wc.recurringBills().first.nextDue, before);
    expect(log(), isNot(contains('recurring.skipFailed')));
    await expectDialogThenClose(t);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('with the clock right the same calls work as before', (t) async {
    final wc = wallet();
    await pumpFull(t, wc, 1, size: const Size(400, 900));
    late List<ImportLine> result;
    await t.runAsync(() async => result = await wc.importFiles([('synthetic.csv', Uint8List.fromList(utf8.encode(_revolutCsv)))]));
    expect(result.single.ok, isTrue);
    expect(find.byKey(const ValueKey('clockBehindDialog')), findsNothing);
    await t.pump(const Duration(seconds: 5));
  });
}
