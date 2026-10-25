// P12 app half (docs/context/P12_SPEC.md §3, §4): an unknown CSV opens Map columns, the preview, Save & import writes the layout and
// the rows, a second file of the same shape imports with no sheet, the saved layouts list, the accounts type list, and layout at
// 320/360 dp with text scale 2.0. Synthetic data only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/accounts_panel.dart';
import 'package:budget_wallet/src/screens/csv_layouts_panel.dart';
import 'package:budget_wallet/src/screens/import_flow.dart';
import 'package:budget_wallet/src/widgets/common.dart' show MoneyText;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

/// No header row at all.
const _csvNoHeader = '03.10.2026;Synthetic coffee;-3,50\n'
    '04.10.2026;Synthetic refund;12,00\n'
    '05.10.2026;Synthetic bakery;-9,99\n';

const _t = Timeout(Duration(seconds: 90));

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// A synthetic bank export no profile knows: semicolons, decimal comma, dates dd.mm.yyyy.
const _csvA = 'Datum;Opis;Iznos;Valuta\n'
    '03.10.2026;Synthetic coffee;-3,50;EUR\n'
    '04.10.2026;Synthetic refund;12,00;EUR\n'
    '05.10.2026;Synthetic bakery;-1.234,56;EUR\n';

/// The same columns, other rows: the same shape.
const _csvB = 'Datum;Opis;Iznos;Valuta\n'
    '10.10.2026;Synthetic kiosk;-2,00;EUR\n';

/// Debit and credit columns.
const _csvSplit = 'Date;Memo;Out;In\n'
    '2026-10-03;Synthetic one;5,00;\n'
    '2026-10-04;Synthetic two;;7,25\n';

class _Chooser extends FileChooser {
  List<PlatformFile> files;
  _Chooser(this.files);
  @override
  Future<List<PlatformFile>> pickBankFiles() async => files;
}

base class _Picked extends PlatformFile {
  @override
  final String name;
  final Uint8List data;
  _Picked(this.name, this.data);
  @override
  Uri get uri => Uri(path: name);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => data.length;
  @override
  Future<int?> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

PlatformFile _pf(String name, String csv) => _Picked(name, _bytes(csv));

CsvChoice _choiceFor(Uint8List bytes, {String name = 'Erste (CSV)'}) {
  final shape = csvShape(bytes);
  return CsvChoice(shape.shapeId, guessMapping(shape)!.copyWith(name: name, headers: shape.headers));
}

Future<void> _openImportButton(WidgetTester t, WalletController wc, _Chooser chooser,
    {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(
      t,
      Scaffold(
          body: Builder(
              builder: (context) => Center(
                  child: FilledButton(
                      key: const ValueKey('go'), onPressed: () => pickAndImport(context, wc, chooser), child: const Text('Import'))))),
      size: size,
      textScale: scale);
  await t.tap(find.byKey(const ValueKey('go')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// The controller's 3 s sync debounce and the toast.
Future<void> _settle(WidgetTester t) => t.pump(const Duration(seconds: 4));

String _previewAmount(WidgetTester t, int row) =>
    t.widget<MoneyText>(find.descendant(of: find.byKey(ValueKey('csvMapPreview:$row')), matching: find.byType(MoneyText))).text;

Future<void> _scrollTo(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
  await t.pump();
}

Future<void> _pick(WidgetTester t, String key, String item) async {
  await _scrollTo(t, key);
  await t.tap(find.byKey(ValueKey(key)));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.text(item).last);
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  group('controller', () {
    test('an unknown CSV asks once, saves the layout, imports, and names it in the result', () async {
      final wc = emptyWallet();
      var asked = 0;
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (need, bytes) async {
        asked++;
        return _choiceFor(bytes);
      });
      expect(asked, 1);
      expect(lines.single.ok, isTrue, reason: lines.single.message);
      expect(lines.single.message, startsWith('Erste (CSV): 3 new, 0 already here'));
      expect(wc.settings.csvMappings.values.single.name, 'Erste (CSV)');
      expect(wc.txs.length, 3);
      expect(wc.txs.map((t) => t.tx.amount), containsAll([-350, 1200, -123456]));
      // The same shape again: no question.
      final again = await wc.importFiles([('b.csv', _bytes(_csvB))], askMapping: (_, __) async => fail('must not ask'));
      expect(again.single.message, startsWith('Erste (CSV): 1 new'));
      expect(wc.txs.length, 4);
    });

    test('cancel imports nothing and saves nothing', () async {
      final wc = emptyWallet();
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, __) async => null);
      expect(lines.single.ok, isFalse);
      expect(lines.single.message, startsWith('Not imported'));
      expect(wc.txs, isEmpty);
      expect(wc.settings.csvMappings, isEmpty);
    });

    test('without a way to ask the file says it needs its columns mapped', () async {
      final wc = emptyWallet();
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))]);
      expect(lines.single.ok, isFalse);
      expect(lines.single.message, needsMappingMessage);
      expect(wc.txs, isEmpty);
    });

    test('a bank file keeps its bank name in the result', () async {
      final wc = emptyWallet();
      const revolut = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
          'CARD_PAYMENT,Current,2026-10-03 10:00:00,2026-10-03 10:00:00,Synthetic shop,-5.00,0.00,EUR,COMPLETED,95.00\n';
      final lines = await wc.importFiles([('r.csv', _bytes(revolut))]);
      expect(lines.single.message, startsWith('Revolut: 1 new'));
    });

    test('rename, delete and restore a layout', () async {
      final wc = emptyWallet();
      await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
      final id = wc.csvLayouts().single.key;
      wc.renameCsvLayout(id, 'My bank');
      expect(wc.settings.csvMappings[id]!.name, 'My bank');
      expect(() => wc.renameCsvLayout(id, '  '), throwsArgumentError);
      final m = wc.deleteCsvLayout(id)!;
      expect(wc.csvLayouts(), isEmpty);
      wc.restoreCsvLayout(id, m);
      expect(wc.csvLayouts().single.value.name, 'My bank');
    });
  });

  test('a forced edit then the same file again: every row back exactly once; Undo of the edit restores the old rows', () async {
    final wc = emptyWallet();
    await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
    final id = wc.csvLayouts().single.key;
    final old = wc.settings.csvMappings[id]!;
    expect(() => wc.saveCsvLayout(id, old.copyWith(negate: true)), throwsArgumentError);
    final removed = wc.saveCsvLayout(id, old.copyWith(negate: true), force: true);
    expect(removed.length, 3);
    expect(wc.txs, isEmpty);
    expect(wc.csvReviveIds(id).length, 3);
    final lines = await wc.importFiles([('a.csv', _bytes(_csvA))]);
    expect(lines.single.message, startsWith('Erste (CSV): 3 new'));
    expect(wc.txs.map((t) => t.tx.amount), unorderedEquals([350, -1200, 123456]));
    expect(wc.csvReviveIds(id), isEmpty);
    // Again: nothing doubled.
    final again = await wc.importFiles([('a.csv', _bytes(_csvA))]);
    expect(again.single.message, startsWith('Erste (CSV): 0 new, 3 already here'));
    expect(wc.txs.length, 3);
  });

  test('Undo of a forced edit puts the old layout and its rows back', () async {
    final wc = emptyWallet();
    await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
    final id = wc.csvLayouts().single.key;
    final old = wc.settings.csvMappings[id]!;
    final removed = wc.saveCsvLayout(id, old.copyWith(negate: true), force: true);
    wc.undoCsvLayoutEdit(id, old, removed);
    expect(wc.settings.csvMappings[id]!.negate, isFalse);
    expect(wc.txs.map((t) => t.tx.amount), unorderedEquals([-350, 1200, -123456]));
    expect(wc.csvReviveIds(id), isEmpty);
  });

  group('a removed layout read another way', () {
    Future<(WalletController, String)> removedLayout() async {
      final wc = emptyWallet();
      await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
      final id = wc.csvLayouts().single.key;
      wc.deleteCsvLayout(id);
      return (wc, id);
    }

    CsvChoice negated(Uint8List bytes) {
      final c = _choiceFor(bytes);
      return CsvChoice(c.shapeId, c.mapping.copyWith(negate: true));
    }

    test('confirmed: the earlier payments are removed, the file is read the new way, Undo puts it all back', () async {
      final (wc, id) = await removedLayout();
      var asked = 0;
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))],
          askMapping: (_, bytes) async => negated(bytes),
          confirmRemoval: (n) async {
            asked = n;
            return true;
          });
      expect(asked, 3);
      expect(lines.single.ok, isTrue, reason: lines.single.message);
      expect(lines.single.message, contains('3 earlier payments read again'));
      expect(wc.txs.map((t) => t.tx.amount), unorderedEquals([350, -1200, 123456]));
      expect(wc.csvReviveIds(id), isEmpty);
      lines.single.undo!();
      expect(wc.txs.map((t) => t.tx.amount), unorderedEquals([-350, 1200, -123456]));
      expect(wc.csvLayouts(), isEmpty);
    });

    test('declined: nothing changes', () async {
      final (wc, id) = await removedLayout();
      final lines = await wc
          .importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => negated(bytes), confirmRemoval: (_) async => false);
      expect(lines.single.ok, isFalse);
      expect(wc.txs.map((t) => t.tx.amount), unorderedEquals([-350, 1200, -123456]));
      expect(wc.csvLayouts(), isEmpty);
      expect(wc.csvReviveIds(id), isEmpty);
    });

    test('without a way to confirm the file is refused with core\'s text', () async {
      final (wc, _) = await removedLayout();
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => negated(bytes));
      expect(lines.single.ok, isFalse);
      expect(lines.single.message, contains('used for 3 payments'));
      expect(wc.txs.length, 3);
    });

    testWidgets('through the import button: Map columns, the question, then a toast with Undo', (t) async {
      final (wc, _) = await removedLayout();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]));
      await _scrollTo(t, 'csvMap:negate');
      await t.tap(find.byKey(const ValueKey('csvMap:negate')));
      await t.pump();
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvEditConfirm')), findsOneWidget);
      expect(find.textContaining('used for 3 payments'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('csvEditConfirmYes')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs.map((x) => x.tx.amount), unorderedEquals([350, -1200, 123456]));
      await t.tap(find.text('Undo'));
      await t.pump();
      expect(wc.txs.map((x) => x.tx.amount), unorderedEquals([-350, 1200, -123456]));
      await _settle(t);
    });
  });

  group('Map columns sheet', () {
    testWidgets('opens for an unknown CSV, shows a signed preview, Save & import writes the layout and the rows', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]));
      expect(find.byKey(const ValueKey('csvMapSheet')), findsOneWidget);
      // The guess is already filled in and the first rows are shown as they would be read.
      expect(find.byKey(const ValueKey('csvMapPreview')), findsOneWidget);
      expect(find.byKey(const ValueKey('csvMapPreview:1')), findsOneWidget);
      await _scrollTo(t, 'csvMapPreview');
      expect(find.textContaining('Synthetic coffee'), findsOneWidget);
      expect(_previewAmount(t, 1), moneyExactSigned(-350, 'EUR'));
      expect(_previewAmount(t, 2), moneyExactSigned(1200, 'EUR'));
      expect(_previewAmount(t, 3), moneyExactSigned(-123456, 'EUR'));
      expect(find.byKey(const ValueKey('csvMapProblems')), findsNothing);
      expect(wc.txs, isEmpty); // nothing before the owner confirms
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvMapSheet')), findsNothing);
      expect(wc.txs.length, 3);
      expect(wc.csvLayouts().single.value.name, 'CSV file');
      expect(wc.lastImport.single.message, startsWith('CSV file: 3 new'));
      await _settle(t);
    });

    testWidgets('Cancel imports nothing', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]));
      await _scrollTo(t, 'csvMapCancel');
      await t.tap(find.byKey(const ValueKey('csvMapCancel')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs, isEmpty);
      expect(wc.csvLayouts(), isEmpty);
      expect(wc.lastImport.single.ok, isFalse);
      await _settle(t);
    });

    testWidgets('a second file of the same shape imports with no sheet', (t) async {
      final wc = emptyWallet();
      await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
      await _openImportButton(t, wc, _Chooser([_pf('b.csv', _csvB)]));
      expect(find.byKey(const ValueKey('csvMapSheet')), findsNothing);
      expect(wc.txs.length, 4);
      expect(wc.lastImport.single.message, startsWith('Erste (CSV): 1 new'));
      await _settle(t);
    });

    testWidgets('a wrong date format lists the problem and blocks Save & import; the right one clears it', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]));
      await _pick(t, 'csvMap:dateFormat', '2026-12-31');
      await _scrollTo(t, 'csvMapProblems');
      expect(find.byKey(const ValueKey('csvMapProblems')), findsOneWidget);
      await _scrollTo(t, 'csvMapSave');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('csvMapSave'))).onPressed, isNull);
      await _pick(t, 'csvMap:dateFormat', '31.12.2026');
      expect(find.byKey(const ValueKey('csvMapProblems')), findsNothing);
      await _scrollTo(t, 'csvMapSave');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('csvMapSave'))).onPressed, isNotNull);
    });

    testWidgets('"Spending is shown as positive" flips the signs in the preview', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]));
      await _scrollTo(t, 'csvMapPreview:1');
      expect(_previewAmount(t, 1), moneyExactSigned(-350, 'EUR'));
      await _scrollTo(t, 'csvMap:negate');
      await t.tap(find.byKey(const ValueKey('csvMap:negate')));
      await t.pump();
      await _scrollTo(t, 'csvMapPreview:1');
      expect(_previewAmount(t, 1), moneyExactSigned(350, 'EUR'));
      expect(wc.txs, isEmpty);
    });

    testWidgets('debit and credit columns: both are asked for, then the preview shows signed amounts', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvSplit)]));
      await _scrollTo(t, 'csvMap:amountSplit');
      await t.tap(find.byKey(const ValueKey('csvMap:amountSplit')));
      await t.pump();
      expect(find.byKey(const ValueKey('csvMap:debit')), findsOneWidget);
      expect(find.byKey(const ValueKey('csvMap:credit')), findsOneWidget);
      await _scrollTo(t, 'csvMapSave');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('csvMapSave'))).onPressed, isNull);
      await _pick(t, 'csvMap:date', '1. Date');
      await _pick(t, 'csvMap:dateFormat', '2026-12-31');
      await _pick(t, 'csvMap:debit', '3. Out');
      await _pick(t, 'csvMap:credit', '4. In');
      await _scrollTo(t, 'csvMapSave');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('csvMapSave'))).onPressed, isNotNull);
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs.map((x) => x.tx.amount), unorderedEquals([-500, 725]));
      await _settle(t);
    });

    testWidgets('logs carry counts only: no headers, cells, problem texts, names or file names', (t) async {
      Logger.root.level = Level.ALL;
      final lines = <String>[];
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(sub.cancel);
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('secret-statement-name.csv', _csvA)]));
      await _pick(t, 'csvMap:dateFormat', '2026-12-31'); // a problem text that quotes a cell
      await _pick(t, 'csvMap:dateFormat', '31.12.2026');
      await t.enterText(find.byKey(const ValueKey('csvMap:name')), 'Secret layout name');
      await t.pump();
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs.length, 3);
      wc.renameCsvLayout(wc.csvLayouts().single.key, 'Another secret name');
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      final all = lines.join('\n');
      expect(all, isNotEmpty);
      for (final secret in [
        'Datum',
        'Iznos',
        'Opis',
        'Valuta',
        'Synthetic',
        '3,50',
        '1.234,56',
        '03.10.2026',
        'secret',
        'Secret',
        'statement',
        'Another'
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
      expect(all, contains('mapped'));
      await _settle(t);
    });

    testWidgets('a file with no header row starts blank, columns are numbered, and imports once mapped', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('plain.csv', _csvNoHeader)]));
      expect(find.byKey(const ValueKey('csvMapSheet')), findsOneWidget);
      await _scrollTo(t, 'csvMapPreviewEmpty');
      await _scrollTo(t, 'csvMapSave');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('csvMapSave'))).onPressed, isNull);
      await _pick(t, 'csvMap:date', '1. Column 1');
      await _pick(t, 'csvMap:amount', '3. Column 3');
      await _scrollTo(t, 'csvMapPreview:0');
      expect(_previewAmount(t, 0), moneyExactSigned(-350, 'EUR'));
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs.map((x) => x.tx.amount), unorderedEquals([-350, 1200, -999]));
      expect(wc.csvLayouts().single.value.headerRow, -1);
      await _settle(t);
    });

    testWidgets('the header row picker offers "No header row" and numbers the columns', (t) async {
      final wc = emptyWallet();
      await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]));
      await _pick(t, 'csvMap:headerRow', 'No header row (columns are numbered)');
      await _scrollTo(t, 'csvMap:date');
      expect(find.byKey(const ValueKey('csvMapPreviewEmpty')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('csvMap:date')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('1. Column 1'), findsWidgets);
      expect(find.text('1. Datum'), findsNothing);
      await t.tap(find.text('1. Column 1').last);
      await t.pump(const Duration(milliseconds: 300));
      await _settle(t);
    });

    for (final (w, scale) in [(320.0, 2.0), (360.0, 2.0), (360.0, 1.0), (1280.0, 1.0)]) {
      testWidgets('layout at $w dp, text scale $scale', (t) async {
        final errors = Errors();
        final wc = emptyWallet();
        await _openImportButton(t, wc, _Chooser([_pf('statement.csv', _csvA)]), size: Size(w, 900), scale: scale);
        expect(find.byKey(const ValueKey('csvMapSheet')), findsOneWidget);
        for (final k in [
          'csvMap:headerRow',
          'csvMap:name',
          'csvMap:date',
          'csvMap:amount',
          'csvMap:currency',
          'csvMapPreview',
          'csvMapSave'
        ]) {
          await _scrollTo(t, k);
        }
        errors.check();
        await _settle(t);
      }, timeout: _t);
    }
  });

  group('Plan › Saved file layouts', () {
    Future<WalletController> layoutWallet() async {
      final wc = emptyWallet();
      await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
      return wc;
    }

    testWidgets('nothing is shown without a layout', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, Scaffold(body: CsvLayoutsPanel(wc: wc)));
      expect(find.byKey(const ValueKey('csvLayoutsPanel')), findsNothing);
    });

    testWidgets('lists the layout, shows its columns, renames it', (t) async {
      final wc = await layoutWallet();
      final id = wc.csvLayouts().single.key;
      await pumpApp(
          t, Scaffold(body: SingleChildScrollView(child: AnimatedBuilder(animation: wc, builder: (_, __) => CsvLayoutsPanel(wc: wc)))));
      expect(find.text('Erste (CSV)'), findsOneWidget);
      await t.tap(find.byKey(ValueKey('csvLayoutColumns:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvLayoutColumnsSheet')), findsOneWidget);
      expect(find.text('Iznos'), findsOneWidget);
      await t.tap(find.byType(ModalBarrier).last, warnIfMissed: false); // close the bottom sheet
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(ValueKey('csvLayoutRename:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(find.byKey(const ValueKey('csvLayoutName')), 'Other name');
      await t.tap(find.byKey(const ValueKey('csvLayoutRenameSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.settings.csvMappings[id]!.name, 'Other name');
      expect(find.text('Other name'), findsOneWidget);
      await _settle(t);
    });

    testWidgets('an empty name is refused with core\'s text', (t) async {
      final wc = await layoutWallet();
      final id = wc.csvLayouts().single.key;
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: CsvLayoutsPanel(wc: wc))), size: const Size(400, 2400));
      await t.tap(find.byKey(ValueKey('csvLayoutRename:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(find.byKey(const ValueKey('csvLayoutName')), ' ');
      await t.tap(find.byKey(const ValueKey('csvLayoutRenameSave')));
      await t.pump();
      expect(find.text('Give the layout a name.'), findsOneWidget);
      expect(wc.settings.csvMappings[id]!.name, 'Erste (CSV)');
      await _settle(t);
    });

    testWidgets('delete shows Undo and Undo brings it back', (t) async {
      final wc = await layoutWallet();
      final id = wc.csvLayouts().single.key;
      await pumpApp(
          t, Scaffold(body: SingleChildScrollView(child: AnimatedBuilder(animation: wc, builder: (_, __) => CsvLayoutsPanel(wc: wc)))));
      await t.tap(find.byKey(ValueKey('csvLayoutDelete:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.csvLayouts(), isEmpty);
      expect(wc.txs.length, 3); // the imported rows stay
      await t.tap(find.text('Undo'));
      await t.pump();
      expect(wc.csvLayouts().single.value.name, 'Erste (CSV)');
      await _settle(t);
    });

    Future<void> openEdit(WidgetTester t, WalletController wc, String id) async {
      await pumpApp(
          t,
          Scaffold(
              body: SingleChildScrollView(
                  child: AnimatedBuilder(
                      animation: wc, builder: (_, __) => CsvLayoutsPanel(wc: wc, chooser: _Chooser([_pf('again.csv', _csvA)]))))),
          size: const Size(400, 2400));
      await t.tap(find.byKey(ValueKey('csvLayoutEdit:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvMapSheet')), findsOneWidget);
    }

    testWidgets('Change: a name-only edit needs no confirmation', (t) async {
      final wc = await layoutWallet();
      final id = wc.csvLayouts().single.key;
      await openEdit(t, wc, id);
      await t.enterText(find.byKey(const ValueKey('csvMap:name')), 'Renamed in sheet');
      await t.pump();
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvEditConfirm')), findsNothing);
      expect(wc.settings.csvMappings[id]!.name, 'Renamed in sheet');
      expect(wc.txs.length, 3);
      await _settle(t);
    });

    testWidgets('Change: a different reading asks first, removes the payments, and Undo brings them back', (t) async {
      final wc = await layoutWallet();
      final id = wc.csvLayouts().single.key;
      await openEdit(t, wc, id);
      await _scrollTo(t, 'csvMap:negate');
      await t.tap(find.byKey(const ValueKey('csvMap:negate')));
      await t.pump();
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvEditConfirm')), findsOneWidget);
      expect(find.textContaining('used for 3 payments'), findsOneWidget);
      // Cancel changes nothing.
      await t.tap(find.byKey(const ValueKey('csvEditCancel')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs.length, 3);
      expect(wc.settings.csvMappings[id]!.negate, isFalse);
      // Again, and confirm.
      await t.tap(find.byKey(ValueKey('csvLayoutEdit:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await _scrollTo(t, 'csvMap:negate');
      await t.tap(find.byKey(const ValueKey('csvMap:negate')));
      await t.pump();
      await _scrollTo(t, 'csvMapSave');
      await t.tap(find.byKey(const ValueKey('csvMapSave')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const ValueKey('csvEditConfirmYes')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs, isEmpty);
      expect(wc.settings.csvMappings[id]!.negate, isTrue);
      expect(wc.csvReviveIds(id).length, 3);
      await t.tap(find.text('Undo'));
      await t.pump();
      expect(wc.txs.length, 3);
      expect(wc.settings.csvMappings[id]!.negate, isFalse);
      expect(wc.csvReviveIds(id), isEmpty);
      await _settle(t);
    });

    testWidgets('Change: a file of another shape is refused', (t) async {
      final wc = await layoutWallet();
      final id = wc.csvLayouts().single.key;
      await pumpApp(
          t, Scaffold(body: SingleChildScrollView(child: CsvLayoutsPanel(wc: wc, chooser: _Chooser([_pf('other.csv', _csvSplit)])))),
          size: const Size(400, 2400));
      await t.tap(find.byKey(ValueKey('csvLayoutEdit:$id')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('csvMapSheet')), findsNothing);
      expect(find.text(layoutMismatchMessage), findsOneWidget);
      await _settle(t);
    });

    for (final (w, scale) in [(320.0, 2.0), (360.0, 2.0)]) {
      testWidgets('layout at $w dp, text scale $scale', (t) async {
        final errors = Errors();
        final wc = await layoutWallet();
        await pumpApp(t, Scaffold(body: SingleChildScrollView(child: CsvLayoutsPanel(wc: wc))), size: Size(w, 800), textScale: scale);
        errors.check();
        await _settle(t);
      });
    }
  });

  testWidgets('Add account offers a saved layout and names the account after it', (t) async {
    final wc = emptyWallet();
    await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, bytes) async => _choiceFor(bytes));
    final id = wc.csvLayouts().single.key;
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: AccountFormSheet(wc: wc))));
    await t.tap(find.byKey(const ValueKey('accountType')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(ValueKey('accountType:csv:$id')).last);
    await t.pump(const Duration(milliseconds: 300));
    expect(t.widget<TextField>(find.byKey(const ValueKey('accountName'))).controller!.text, 'Erste (CSV)');
    await t.enterText(find.byKey(const ValueKey('accountOpening')), '10');
    await t.tap(find.byKey(const ValueKey('accountSave')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final acc = wc.accountsAll().single;
    expect(acc.source, 'csv:$id');
    await _settle(t);
  });
}
