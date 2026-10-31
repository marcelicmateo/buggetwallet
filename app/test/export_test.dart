// Plan › Export: range chooser, file names, CSV bytes, cancel, a failing chooser, empty ranges. SYNTHETIC data only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/export_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

/// Records what would be saved; [saved] false stands for a cancelled dialog, [fail] for a missing portal.
class FakeSaver extends FileChooser {
  final bool saved;
  final bool fail;
  final names = <String>[];
  final files = <Uint8List>[];
  FakeSaver({this.saved = true, this.fail = false});
  @override
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    if (fail) throw PortalMissing();
    names.add(fileName);
    files.add(bytes);
    return saved ? Uri.file('/tmp/ignored') : null;
  }
}

class PortalMissing implements Exception {
  @override
  String toString() => 'PortalMissing: no portal for /home/someone/private-folder';
}

WalletController wallet({bool empty = false}) {
  final wc = empty ? emptyWallet() : habitsWallet();
  addTearDown(wc.dispose);
  return wc;
}

Future<void> pumpPanel(WidgetTester t, WalletController wc, FileChooser chooser, {Size size = const Size(400, 900), double scale = 1}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: ExportPanel(wc: wc, chooser: chooser))), size: size, textScale: scale);

Finder get txBtn => find.byKey(const ValueKey('exportTx'));
Finder get sumBtn => find.byKey(const ValueKey('exportSummary'));

String text(Uint8List b) => utf8.decode(b.sublist(3)); // without the byte order mark

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  testWidgets('the panel shows the range chooser, both buttons and the plain-files note', (t) async {
    await pumpPanel(t, wallet(), FakeSaver());
    expect(find.text('EXPORT'), findsOneWidget);
    for (final s in [
      'This period',
      'This year',
      'Everything',
      'Export transactions (CSV)',
      'Export monthly summary (CSV)',
      'Plain files, not encrypted.'
    ]) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('range:period'))).selected, isTrue);
  });

  group('transactions', () {
    testWidgets('This period saves bw-transactions-<from>-<to>.csv with the period rows only', (t) async {
      final wc = wallet();
      final saver = FakeSaver();
      await pumpPanel(t, wc, saver);
      await t.tap(txBtn);
      await t.pump();
      final p = wc.period();
      expect(saver.names, ['bw-transactions-${p.start}-${addDays(p.end, -1)}.csv']);
      final csv = text(saver.files.single);
      expect(saver.files.single.take(3), [0xEF, 0xBB, 0xBF], reason: 'a byte order mark, so spreadsheets read accents');
      final inPeriod = wc.txs.where((x) => x.date.compareTo(p.start) >= 0 && x.date.compareTo(addDays(p.end, -1)) <= 0).length;
      expect(inPeriod, greaterThan(0));
      expect(csv.trim().split('\n').length, inPeriod + 1, reason: 'a header and one line per transaction');
      expect(csv, isNot(contains('2026-07-25')), reason: 'older rows stay out of this period');
      expect(find.text('Saved ${saver.names.single}'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('This year runs from 1 Jan to today', (t) async {
      final wc = wallet();
      final saver = FakeSaver();
      await pumpPanel(t, wc, saver);
      await t.tap(find.byKey(const ValueKey('range:year')));
      await t.pump();
      await t.tap(txBtn);
      await t.pump();
      expect(saver.names.single, 'bw-transactions-2026-01-01-2026-10-20.csv');
      expect(text(saver.files.single), contains('2026-07-25'));
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Everything runs from the oldest to the newest transaction and has every row', (t) async {
      final wc = wallet();
      final saver = FakeSaver();
      await pumpPanel(t, wc, saver);
      await t.tap(find.byKey(const ValueKey('range:all')));
      await t.pump();
      await t.tap(txBtn);
      await t.pump();
      expect(saver.names.single, 'bw-transactions-${wc.txs.last.date}-${wc.txs.first.date}.csv');
      expect(text(saver.files.single).trim().split('\n').length, wc.txs.length + 1);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('the log carries the range word and counts, never the file name', (t) async {
      final wc = wallet();
      await pumpPanel(t, wc, FakeSaver());
      await t.tap(txBtn);
      await t.pump();
      final log = lines.where((l) => l.contains('export.')).join('\n');
      expect(log, contains('export.transactions'));
      expect(log, contains('"range":"period"'));
      expect(log, contains('export.saved'));
      expect(log, isNot(contains('bw-transactions')));
      expect(log, isNot(contains('SYNTHGYM')));
      await t.pump(const Duration(seconds: 4));
    });
  });

  testWidgets('a wallet with only income has no summary to export', (t) async {
    final wc = wallet(empty: true);
    wc.repo.importBatch(
        ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-05', 140000, 'Plaća/Mirovina', 'Neto placa synthetic')]));
    wc.reload();
    final saver = FakeSaver();
    await pumpPanel(t, wc, saver);
    await t.tap(sumBtn);
    await t.pump();
    expect(saver.names, isEmpty);
    expect(find.text('Nothing to export in this range'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('the monthly summary saves bw-summary.csv', (t) async {
    final wc = wallet();
    final saver = FakeSaver();
    await pumpPanel(t, wc, saver);
    await t.tap(sumBtn);
    await t.pump();
    expect(saver.names, ['bw-summary.csv']);
    final csv = text(saver.files.single);
    expect(csv, contains('2026-10'));
    expect(csv, contains('Groceries'));
    expect(find.text('Saved bw-summary.csv'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('a cancelled save dialog shows nothing and leaves the buttons usable', (t) async {
    final saver = FakeSaver(saved: false);
    await pumpPanel(t, wallet(), saver);
    await t.tap(txBtn);
    await t.pump();
    expect(saver.names, hasLength(1));
    expect(find.textContaining('Saved'), findsNothing);
    expect(t.widget<ButtonStyleButton>(txBtn).onPressed, isNotNull);
    expect(t.widget<ButtonStyleButton>(sumBtn).onPressed, isNotNull);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('a failing chooser shows the chooser message, logs the type only and can be tried again', (t) async {
    final saver = FakeSaver(fail: true);
    await pumpPanel(t, wallet(), saver);
    await t.tap(sumBtn);
    await t.pump();
    expect(find.text(chooserFailedMessage), findsOneWidget);
    final logged = lines.where((l) => l.contains('export.saveFailed')).toList();
    expect(logged, hasLength(1));
    expect(logged.single, contains('"type":"PortalMissing"'));
    expect(logged.single, isNot(contains('someone')));
    expect(t.widget<ButtonStyleButton>(sumBtn).onPressed, isNotNull);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('an empty wallet has nothing to export: a short message, no dialog', (t) async {
    final saver = FakeSaver();
    await pumpPanel(t, wallet(empty: true), saver);
    await t.tap(txBtn);
    await t.pump();
    expect(find.text('Nothing to export in this range'), findsOneWidget);
    await t.tap(sumBtn);
    await t.pump();
    expect(saver.names, isEmpty);
    await t.pump(const Duration(seconds: 4));
  });

  for (final (w, h, scale) in [(320.0, 640.0, 2.0), (360.0, 800.0, 1.0), (1280.0, 800.0, 1.0)]) {
    testWidgets('layout at ${w.toInt()} dp, text ${scale}x: no overflow', (t) async {
      await withErrors((errors) async {
        await pumpPanel(t, wallet(), FakeSaver(), size: Size(w, h), scale: scale);
        await t.ensureVisible(find.text('Plain files, not encrypted.'));
        scanFlex(t);
        errors.check();
      });
    });
  }
}
