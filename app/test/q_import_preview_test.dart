// Stage Q4 app half: the import preview sheet. Cancel writes nothing (rows and column layout), Skip leaves rows out, the counts equal the
// import, "Always show" off goes straight through, and the sheet fits 320 dp at text scale 2.0 in both themes. Synthetic data only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/import_flow.dart';
import 'package:budget_wallet/src/screens/import_preview_sheet.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

const _jan = 'Datum;Opis;Iznos;Valuta\n03.01.2026;Synthetic jan one;-1,00;EUR\n04.01.2026;Synthetic jan two;-2,00;EUR\n';
const _feb = 'Datum;Opis;Iznos;Valuta\n03.02.2026;Synthetic feb one;-3,00;EUR\n04.02.2026;Synthetic feb two;-4,00;EUR\n';

const _t = Timeout(Duration(seconds: 60));

const _csvA = 'Datum;Opis;Iznos;Valuta\n'
    '03.10.2026;Synthetic coffee;-3,50;EUR\n'
    '04.10.2026;Synthetic refund;12,00;EUR\n'
    '05.10.2026;Synthetic bakery;-1.234,56;EUR\n';
const _csvB = 'Datum;Opis;Iznos;Valuta\n'
    '03.10.2026;Synthetic coffee;-3,50;EUR\n'
    '10.10.2026;Synthetic kiosk;-2,00;EUR\n'
    '11.10.2026;Synthetic market;-7,00;EUR\n';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

class _Chooser extends FileChooser {
  final List<PickedFile> files;
  _Chooser(this.files);
  @override
  Future<List<PickedFile>> pickBankFiles() async => files;
}

class _Picked extends PickedFile {
  _Picked(String name, Uint8List data) : super(name, () async => data, length: () async => data.length);
}

CsvChoice _choiceFor(Uint8List bytes, {bool negate = false}) {
  final shape = csvShape(bytes);
  return CsvChoice(shape.shapeId, guessMapping(shape)!.copyWith(name: 'Erste (CSV)', headers: shape.headers, negate: negate));
}

Future<void> _openButton(WidgetTester t, WalletController wc, String csv, {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(
      t,
      Scaffold(
          body: Builder(
              builder: (context) => Center(
                  child: FilledButton(
                      key: const ValueKey('go'),
                      onPressed: () => pickAndImport(context, wc, _Chooser([_Picked('b.csv', _bytes(csv))])),
                      child: const Text('Import'))))),
      size: size,
      textScale: scale);
  await t.tap(find.byKey(const ValueKey('go')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _scrollTo(WidgetTester t, String key) async {
  await Scrollable.ensureVisible(t.element(_key(key)), alignment: 0.5);
  await t.pump();
}

/// Save & import on the Map columns sheet.
Future<void> _mapSave(WidgetTester t) async {
  await _scrollTo(t, 'csvMapSave');
  await t.tap(_key('csvMapSave'));
  await _settle(t);
}

Finder _skipButtons() => find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('previewSkip:'));

/// A wallet that already knows the CSV layout of [_csvA]/[_csvB] and holds [_csvA]'s rows.
Future<WalletController> _known() async {
  final wc = emptyWallet();
  await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, b) async => _choiceFor(b));
  return wc;
}

/// A widget test that lets the controller's 3 s sync debounce run out at the end (a pending timer fails the test).
void tw(String name, Future<void> Function(WidgetTester t) body, {Timeout? timeout}) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: timeout);

void main() {
  group('controller', () {
    test('Cancel writes nothing: no rows and no column layout', () async {
      final wc = emptyWallet();
      var asked = 0;
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))],
          askMapping: (_, b) async => _choiceFor(b),
          confirmPreview: (p, bank) async {
            asked++;
            expect(p.fresh, 3);
            return null;
          });
      expect(asked, 1);
      expect(wc.txs, isEmpty);
      expect(wc.csvLayouts(), isEmpty);
      expect(lines.single.ok, isFalse);
      expect(lines.single.message, contains('Cancel'));
    });

    test('Import saves the layout and the rows, and the preview counts equal the import', () async {
      final wc = emptyWallet();
      late ImportPreview seen;
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))],
          askMapping: (_, b) async => _choiceFor(b),
          confirmPreview: (p, bank) async {
            seen = p;
            return <String>{};
          });
      expect(wc.csvLayouts(), hasLength(1));
      expect(wc.txs, hasLength(3));
      expect(lines.single.added, seen.added);
      expect(lines.single.message, startsWith('Erste (CSV): ${seen.fresh} new, ${seen.duplicates} already here'));
    });

    test('a second file: duplicates are counted as already here, equal to the import', () async {
      final wc = await _known();
      late ImportPreview seen;
      final lines = await wc.importFiles([('b.csv', _bytes(_csvB))], confirmPreview: (p, bank) async {
        seen = p;
        return <String>{};
      });
      expect(seen.fresh, 2);
      expect(seen.duplicates, 1);
      expect(lines.single.message, startsWith('Erste (CSV): 2 new, 1 already here'));
      expect(wc.txs, hasLength(5));
    });

    test('Skip leaves exactly those rows out', () async {
      final wc = await _known();
      late String skipId;
      final lines = await wc.importFiles([('b.csv', _bytes(_csvB))], confirmPreview: (p, bank) async {
        skipId = p.rows.firstWhere((r) => r.status == PreviewStatus.fresh).tx.id;
        return {skipId};
      });
      expect(lines.single.added, 1);
      expect(lines.single.message, contains('1 left out by you'));
      expect(wc.txs.any((x) => x.tx.id == skipId), isFalse);
      expect(wc.txs, hasLength(4));
    });

    test('Cancel after a forced remap puts back the earlier payments, the removed layout and the waiting list', () async {
      final wc = await _known();
      final shape = csvShape(_bytes(_csvA)).shapeId;
      final before = wc.txs.map((x) => x.tx.amount).toList()..sort();
      final original = wc.csvLayouts().single.value;
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      wc.repo.setLocalValue('csvRevive:$shape', '["earlier-wait"]'); // another file's rows already wait
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))],
          askMapping: (_, b) async => _choiceFor(b, negate: true),
          confirmRemoval: (_) async => true,
          confirmPreview: (p, bank) async => null);
      expect(lines.single.ok, isFalse);
      expect((wc.txs.map((x) => x.tx.amount).toList()..sort()), before);
      expect(wc.csvLayouts(), isEmpty);
      expect(wc.repo.removedCsvMapping(shape), original, reason: 'the removed layout keeps its own reading');
      expect(wc.repo.localValue('csvRevive:$shape'), '["earlier-wait"]');
    });

    test('Cancel after a layout that only changed its name (saved early, nothing removed) writes the earlier record back', () async {
      final wc = await _known();
      final shape = csvShape(_bytes(_csvA)).shapeId;
      final original = wc.csvLayouts().single.value;
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))],
          askMapping: (_, b) async {
            final c = _choiceFor(b);
            return CsvChoice(c.shapeId, c.mapping.copyWith(name: 'Renamed'));
          },
          confirmPreview: (p, bank) async => null);
      expect(lines.single.ok, isFalse);
      expect(wc.csvLayouts(), isEmpty);
      expect(wc.repo.removedCsvMapping(shape), original, reason: 'not left holding the new name');
    });

    test('a refused layout shows its own line after the preview and no rows are written', () async {
      final wc = emptyWallet();
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))],
          askMapping: (_, b) async {
            final c = _choiceFor(b);
            return CsvChoice(c.shapeId, c.mapping.copyWith(name: ''));
          },
          confirmPreview: (p, bank) async => <String>{});
      expect(lines.single.ok, isFalse);
      expect(lines.single.message, 'Give the layout a name.');
      expect(wc.txs, isEmpty);
      expect(wc.csvLayouts(), isEmpty);
    });

    test('a skipped "Read again" row stays waiting and comes back the next time', () async {
      final wc = await _known();
      final shape = csvShape(_bytes(_csvA)).shapeId;
      Future<List<ImportLine>> again({Set<String> Function(ImportPreview)? skipOf, bool negate = false}) =>
          wc.importFiles([('a.csv', _bytes(_csvA))],
              askMapping: (_, b) async => _choiceFor(b, negate: negate),
              confirmRemoval: (_) async => true,
              confirmPreview: (p, bank) async => skipOf == null ? <String>{} : skipOf(p));
      // Read it the other way, then back: the first rows are deleted, then brought back through the waiting list.
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      await again(negate: true);
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      late String skipped;
      late int readAgain;
      await again(skipOf: (p) {
        readAgain = p.revivable;
        skipped = p.rows.firstWhere((r) => r.status == PreviewStatus.revivable).tx.id;
        return {skipped};
      });
      expect(readAgain, 3);
      expect(wc.txs.any((x) => x.tx.id == skipped), isFalse);
      expect(jsonDecode(wc.repo.localValue('csvRevive:$shape')!), contains(skipped));
      late ImportPreview next;
      await wc.importFiles([('a.csv', _bytes(_csvA))], confirmPreview: (p, bank) async {
        next = p;
        return <String>{};
      });
      expect(next.revivable, 1, reason: 'the skipped row comes back as Read again');
      expect(wc.txs.any((x) => x.tx.id == skipped), isTrue);
      expect(jsonDecode(wc.repo.localValue('csvRevive:$shape') ?? '[]'), isNot(contains(skipped)));
    });

    test('Undo of a remap keeps the rows that were already waiting: Feb comes back when Feb is read again', () async {
      final wc = emptyWallet();
      CsvChoice normal(Uint8List b) => _choiceFor(b);
      await wc.importFiles([('jan.csv', _bytes(_jan))], askMapping: (_, b) async => normal(b));
      await wc.importFiles([('feb.csv', _bytes(_feb))]);
      List<int> amounts() => wc.txs.map((x) => x.tx.amount).toList()..sort();
      expect(amounts(), [-400, -300, -200, -100]);
      // Read Jan the other way: Jan and Feb are removed and wait to be read again.
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      await wc.importFiles([('jan.csv', _bytes(_jan))],
          askMapping: (_, b) async => _choiceFor(b, negate: true), confirmRemoval: (_) async => true);
      // Back to the first reading: only Jan is read, so Feb still waits; then that second change is undone.
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      final lines =
          await wc.importFiles([('jan.csv', _bytes(_jan))], askMapping: (_, b) async => normal(b), confirmRemoval: (_) async => true);
      lines.single.undo!();
      // Reading Feb the first way again must bring Feb's rows back.
      await wc.importFiles([('feb.csv', _bytes(_feb))], askMapping: (_, b) async => normal(b), confirmRemoval: (_) async => true);
      expect(amounts(), containsAll([-400, -300]), reason: 'Feb was waiting and is not lost by the Undo');
    });

    test('without a preview callback the file goes straight in (today)', () async {
      final wc = emptyWallet();
      final lines = await wc.importFiles([('a.csv', _bytes(_csvA))], askMapping: (_, b) async => _choiceFor(b));
      expect(lines.single.added, 3);
    });

    test('"Always show" is device-local, default on', () {
      final wc = emptyWallet();
      expect(wc.importPreviewAlways, isTrue);
      wc.setImportPreviewAlways(false);
      expect(wc.importPreviewAlways, isFalse);
      wc.setImportPreviewAlways(true);
      expect(wc.importPreviewAlways, isTrue);
    });
  });

  group('sheet', () {
    tw('shows the summary, expands a group, Skip toggles, Import writes without the skipped row', (t) async {
      final wc = await _known();
      await _openButton(t, wc, _csvB);
      expect(_key('importPreview'), findsOneWidget);
      expect(find.text('2 new · 1 already here'), findsOneWidget);
      expect(_key('previewSkip:x'), findsNothing);
      expect(_skipButtons(), findsNothing, reason: 'groups start folded');
      await t.tap(_key('previewGroup:fresh'));
      await t.pump();
      expect(_skipButtons(), findsNWidgets(2));
      await t.tap(_skipButtons().first);
      await t.pump();
      expect(find.text('1 new · 1 already here · 1 skipped'), findsOneWidget);
      await t.tap(_key('importPreviewImport'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs, hasLength(4));
      expect(wc.lastImport.single.message, contains('1 new'));
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('Cancel writes nothing', (t) async {
      final wc = await _known();
      await _openButton(t, wc, _csvB);
      await t.tap(_key('importPreviewCancel'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(wc.txs, hasLength(3));
      expect(wc.lastImport.single.ok, isFalse);
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('Always show off: no sheet, the rows go straight in', (t) async {
      final wc = await _known();
      wc.setImportPreviewAlways(false);
      await _openButton(t, wc, _csvB);
      expect(_key('importPreview'), findsNothing);
      expect(wc.txs, hasLength(5));
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('the summary hides zero parts and counts transfers as pairs of rows that will be written', (t) async {
      NormalizedTransaction n(String id) => NormalizedTransaction(
          id: id, source: 'pbz', date: '2026-10-12', amountMinor: -1000, currency: 'EUR', bankType: 'x', description: 'SYNTHETIC $id');
      final preview = ImportPreview.of([
        PreviewRow(tx: n('a'), status: PreviewStatus.fresh, transferPairId: 'b'),
        PreviewRow(tx: n('b'), status: PreviewStatus.fresh, transferPairId: 'a'), // the same pair, its other row is in the file too
        PreviewRow(tx: n('c'), status: PreviewStatus.fresh, transferPairId: 'stored-1'), // the other row is already stored
        PreviewRow(tx: n('d'), status: PreviewStatus.duplicate, transferPairId: 'stored-2'), // not written: not counted
      ]);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: ImportPreviewSheet(preview: preview, bank: 'PBZ'))));
      expect(find.text('3 new · 1 already here · 2 transfers'), findsOneWidget);
      await t.tap(_key('previewGroup:fresh'));
      await t.pump();
      await t.tap(_key('previewSkip:a'));
      await t.pump();
      expect(find.text('2 new · 1 already here · 1 transfer · 1 skipped'), findsOneWidget, reason: 'a skipped row ends its pair');
    }, timeout: _t);

    tw('Map columns, then the preview: Cancel leaves no rows and no layout', (t) async {
      final wc = emptyWallet();
      await _openButton(t, wc, _csvA);
      expect(_key('csvMapSheet'), findsOneWidget);
      await _mapSave(t);
      expect(_key('importPreview'), findsOneWidget);
      expect(find.text('3 new'), findsOneWidget);
      expect(wc.csvLayouts(), isEmpty, reason: 'the layout waits for Import');
      await t.tap(_key('importPreviewCancel'));
      await _settle(t);
      expect(wc.txs, isEmpty);
      expect(wc.csvLayouts(), isEmpty);
    }, timeout: _t);

    tw('Map columns, then the preview: Import writes the layout and the rows', (t) async {
      final wc = emptyWallet();
      await _openButton(t, wc, _csvA);
      await _mapSave(t);
      await t.tap(_key('importPreviewImport'));
      await _settle(t);
      expect(wc.txs, hasLength(3));
      expect(wc.csvLayouts(), hasLength(1));
    }, timeout: _t);

    tw('a removed layout read another way: the question, the preview, Import, then the toast Undo puts the earlier payments back',
        (t) async {
      final wc = await _known();
      final before = wc.txs.map((x) => x.tx.amount).toList()..sort();
      wc.deleteCsvLayout(wc.csvLayouts().single.key);
      await _openButton(t, wc, _csvA);
      await _scrollTo(t, 'csvMap:negate');
      await t.tap(_key('csvMap:negate'));
      await t.pump();
      await _mapSave(t);
      expect(_key('csvEditConfirm'), findsOneWidget);
      await t.tap(_key('csvEditConfirmYes'));
      await _settle(t);
      expect(_key('importPreview'), findsOneWidget);
      await t.tap(_key('importPreviewImport'));
      await _settle(t);
      expect((wc.txs.map((x) => x.tx.amount).toList()..sort()), isNot(before));
      await t.tap(find.text('Undo'));
      await t.pump();
      expect((wc.txs.map((x) => x.tx.amount).toList()..sort()), before);
    }, timeout: _t);

    tw('the weekly review import shows the preview too', (t) async {
      final wc = await _known();
      await pumpApp(t, ReviewScreen(wc: wc, chooser: _Chooser([_Picked('b.csv', _bytes(_csvB))])), size: const Size(400, 3000));
      await t.tap(_key('reviewImport'));
      await _settle(t);
      expect(_key('importPreview'), findsOneWidget);
      await t.tap(_key('importPreviewImport'));
      await _settle(t);
      expect(wc.txs, hasLength(5));
    }, timeout: _t);

    tw('bank questions: one per account, the newest date', (t) async {
      BankQuestion q(String account, String date) => BankQuestion(accountId: account, name: 'x', currency: 'EUR', date: date, appCents: 1);
      final out = newestPerAccount([q('a', '2026-10-01'), q('b', '2026-10-05'), q('a', '2026-10-09'), q('a', '2026-10-03')]);
      expect(out.map((e) => (e.accountId, e.date)).toSet(), {('a', '2026-10-09'), ('b', '2026-10-05')});
    }, timeout: _t);

    for (final dark in [false, true]) {
      tw('320 dp at text 2.0 ${dark ? 'dark' : 'light'}: every group open, no overflow', (t) async {
        final repo = WalletRepo.inMemory();
        addTearDown(repo.close);
        final manual = repo.addTransaction(date: '2026-10-10', amount: -1500, category: 'Groceries');
        expect(manual, isNotEmpty);
        NormalizedTransaction n(String id, String date, int cents, String d) =>
            NormalizedTransaction(id: id, source: 'pbz', date: date, amountMinor: cents, currency: 'EUR', bankType: 'POS', description: d);
        repo.importBatch(ImportBatch(source: 'pbz', transactions: [n('known-1', '2026-10-02', -500, 'SYNTHETIC KNOWN')]));
        final preview = repo.previewImport(ImportBatch(source: 'pbz', transactions: [
          n('known-1', '2026-10-02', -500, 'SYNTHETIC KNOWN'),
          n('new-1', '2026-10-11', -2500, 'SYNTHETIC NEW ROW WITH A LONG DESCRIPTION THAT WRAPS ON A NARROW PHONE'),
          n('new-2', '2026-10-12', 150000, 'SYNTHETIC SALARY'),
          n('match-1', '2026-10-10', -1500, 'SYNTHETIC MATCH'),
          n('big-1', '2026-10-12', 900000000000000, 'SYNTHETIC TOO LARGE'),
        ]));
        t.view.physicalSize = const Size(320, 640);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(dark ? Brightness.dark : Brightness.light),
          builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: c!),
          home: Scaffold(body: SingleChildScrollView(child: ImportPreviewSheet(preview: preview, bank: 'PBZ'))),
        ));
        for (final g in PreviewStatus.values) {
          final f = _key('previewGroup:${g.name}');
          if (f.evaluate().isEmpty) continue;
          await t.ensureVisible(f);
          await t.tap(f);
          await t.pump();
        }
        expect(t.takeException(), isNull);
        expect(_key('importPreviewSummary'), findsOneWidget);
        expect(preview.tooLarge, 1);
      }, timeout: _t);
    }
  });
}
