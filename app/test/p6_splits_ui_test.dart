// Stage P6 app half: the split editor, the Spending list with its parts, the detail lists and the broken-split message.
// All data is SYNTHETIC. Structural checks only (keys, texts, counts), no golden files.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:budget_wallet/src/widgets/split_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

/// A wallet with one hand-added 50.00 groceries payment in October 2026 (the test clock is 20 Oct 2026).
(WalletController, String) _wallet() {
  final wc = budgetWallet(budgets: false);
  final id = wc.repo.addTransaction(date: '2026-10-14', amount: 5000, category: 'Groceries', note: 'Synthetic mart');
  wc.reload();
  return (wc, id);
}

Future<void> _spending(WidgetTester tester, WalletController wc, {Size size = const Size(400, 3000), double textScale = 1}) async {
  // HomeShell rebuilds the page per data version; so does this wrapper.
  await pumpApp(tester,
      Scaffold(body: ListenableBuilder(listenable: wc, builder: (ctx, child) => SpendingScreen(key: ValueKey(wc.dataVersion), wc: wc))),
      size: size, textScale: textScale);
  await tester.pumpAndSettle();
}

/// Lets the controller's 3 s sync debounce fire so no timer is left pending.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 4));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.enterText(f, text);
  await tester.pumpAndSettle();
}

String _left(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('splitLeft'))).data!;
bool _saveOn(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const ValueKey('splitSave'))).onPressed != null;

/// The payment's tile (the name also shows under Top places).
Finder get _tile => find.widgetWithText(TxTile, 'Synthetic mart');

/// Opens the payment's sheet from the Spending list and the split editor from it.
Future<void> _openEditor(WidgetTester tester, {String key = 'splitOpen'}) async {
  await _tap(tester, _tile);
  await _tap(tester, find.byKey(ValueKey(key)));
}

/// Fills the editor: 30.00 on Groceries and 20.00 on Eating out (part 1).
Future<void> _fillTwoParts(WidgetTester tester) async {
  await _type(tester, 'splitAmount:0', '30');
  await _type(tester, 'splitAmount:1', '20');
  await _tap(tester, find.byKey(const ValueKey('splitCategory:1')));
  await _tap(tester, find.byKey(const ValueKey('pick:Eating out')).last);
}

void main() {
  group('split editor', () {
    testWidgets('opens with two parts: the whole amount on the main tag, then an empty one', (tester) async {
      final (wc, _) = _wallet();
      await _spending(tester, wc);
      await _openEditor(tester);
      expect(find.byKey(const ValueKey('splitSheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('splitPart:0')), findsOneWidget);
      expect(find.byKey(const ValueKey('splitPart:1')), findsOneWidget);
      expect(find.byKey(const ValueKey('splitPart:2')), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('splitAmount:0'))).controller!.text, '50');
      expect(tester.widget<TextField>(find.byKey(const ValueKey('splitAmount:1'))).controller!.text, '');
      expect(_left(tester), contains('Left to split'));
      expect(_left(tester), contains('0.00'));
      // The empty second part keeps Save off and says why.
      expect(_saveOn(tester), isFalse);
      expect(find.text('Every part needs an amount.'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('Left to split follows the amounts; Save is off until it is 0.00', (tester) async {
      final (wc, _) = _wallet();
      await _spending(tester, wc);
      await _openEditor(tester);
      await _type(tester, 'splitAmount:0', '30');
      expect(_left(tester), contains('20.00'));
      await _type(tester, 'splitAmount:1', '12.50');
      expect(_left(tester), contains('7.50'));
      expect(_saveOn(tester), isFalse);
      expect(find.byKey(const ValueKey('splitReason')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('splitAddPart')));
      expect(find.byKey(const ValueKey('splitPart:2')), findsOneWidget);
      await _type(tester, 'splitAmount:2', '7.50');
      expect(_left(tester), contains('0.00'));
      expect(_saveOn(tester), isTrue);
      // Over by a cent turns the line into "Over by" and Save off again.
      await _type(tester, 'splitAmount:2', '7.51');
      expect(_left(tester), startsWith('Over by'));
      expect(_saveOn(tester), isFalse);
      await _settle(tester);
    });

    testWidgets('a part can be removed down to two; Add part stops at 20', (tester) async {
      final (wc, _) = _wallet();
      await _spending(tester, wc, size: const Size(400, 20000));
      await _openEditor(tester);
      expect(find.byKey(const ValueKey('splitPartRemove:0')), findsNothing); // only two parts: none can go
      await _tap(tester, find.byKey(const ValueKey('splitAddPart')));
      expect(find.byKey(const ValueKey('splitPart:2')), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('splitPartRemove:2')));
      expect(find.byKey(const ValueKey('splitPart:2')), findsNothing);
      for (var i = 0; i < 18; i++) {
        await tester.tap(find.byKey(const ValueKey('splitAddPart')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('splitPart:19')), findsOneWidget);
      expect(find.byKey(const ValueKey('splitAddPart')), findsNothing);
      await _settle(tester);
    });

    testWidgets('Save writes the split: one tile with "Split · 2" and the parts under it', (tester) async {
      final (wc, id) = _wallet();
      await _spending(tester, wc);
      expect(_tile, findsOneWidget);
      await _openEditor(tester);
      await _fillTwoParts(tester);
      await _type(tester, 'splitNote:1', 'Takeaway');
      expect(_saveOn(tester), isTrue);
      await _tap(tester, find.byKey(const ValueKey('splitSave')));

      expect(wc.splitCount(id), 2);
      final stored = wc.repo.splitOf(id)!;
      expect(stored.map((p) => p.amount), [-3000, -2000]); // the payment's sign
      expect(stored.map((p) => p.category), ['Groceries', 'Eating out']);
      expect(stored[1].note, 'Takeaway');
      expect(find.text('Split saved'), findsOneWidget);
      // One tile for the payment, the parts listed under it.
      expect(_tile, findsOneWidget);
      expect(find.text('Split · 2'), findsOneWidget);
      expect(find.byType(PartTile), findsNWidgets(2));
      expect(find.text('Takeaway'), findsOneWidget);
      // Money counts the parts, never the payment with them.
      final b = wc.spending('2026-10').summary.byCategory;
      expect(b['Eating out'], 11200 + 2000);
      await _settle(tester);
    });

    testWidgets('core refuses: its text shows and nothing is saved', (tester) async {
      final (wc, id) = _wallet();
      await _spending(tester, wc);
      await _openEditor(tester);
      await _fillTwoParts(tester);
      // The payment changed on another device meanwhile (the amount edit arrives as a sync op).
      wc.repo.applyRemote([
        Op('tx', id, {'amount': -6000}, Hlc(DateTime.now().millisecondsSinceEpoch + 5000, 0, 'peer').toString())
      ]);
      await _tap(tester, find.byKey(const ValueKey('splitSave')));
      expect(find.byKey(const ValueKey('splitSheet')), findsOneWidget);
      expect(find.text("The parts don't add up to the payment."), findsOneWidget);
      expect(wc.repo.splitOf(id), isNull);
      await _settle(tester);
    });

    testWidgets('fits 320 dp at text scale 2.0 and 360 dp, with three parts', (tester) async {
      for (final (w, scale) in [(320.0, 2.0), (360.0, 1.0)]) {
        final (wc, _) = _wallet();
        await pumpApp(
            tester,
            Builder(
                builder: (ctx) => Scaffold(
                    body: Center(
                        child: ElevatedButton(
                            onPressed: () => showSheet<String>(
                                ctx, SplitSheet(wc: wc, row: wc.wholeTxs.firstWhere((t) => t.tx.manual && t.amount == -5000))),
                            child: const Text('open'))))),
            size: Size(w, 1800),
            textScale: scale);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('splitAddPart')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'overflow at $w dp x$scale');
        expect(find.byKey(const ValueKey('splitPart:2')), findsOneWidget);
        await _settle(tester);
      }
    });
  });

  group('after a split', () {
    (WalletController, String) split() {
      final (wc, id) = _wallet();
      wc.repo.setSplit(id, const [
        SplitPart(amount: -3000, category: 'Groceries', tags: [], note: null),
        SplitPart(amount: -2000, category: 'Eating out', tags: [], note: 'Takeaway'),
      ]);
      wc.reload();
      return (wc, id);
    }

    testWidgets('the category detail lists the part, "part of" the payment', (tester) async {
      final (wc, _) = split();
      await pumpApp(tester, Scaffold(body: CategoryDetailScreen(wc: wc, category: 'Eating out', range: wc.monthRange('2026-10'))),
          size: const Size(400, 3000));
      await tester.pumpAndSettle();
      await _tap(
          tester, find.byKey(ValueKey('merchantRow_${merchantKey(wc.wholeTxs.firstWhere((t) => t.tx.note == 'Synthetic mart').tx)}')));
      expect(find.widgetWithText(TxTile, 'Synthetic mart'), findsOneWidget);
      expect(find.textContaining('part of'), findsOneWidget);
      expect(find.text('Takeaway'), findsNothing); // the note shows in the part list under Spending, not here
      await _settle(tester);
    });

    testWidgets('Remove split asks nothing, counts the payment whole again and Undo puts it back', (tester) async {
      final (wc, id) = split();
      await _spending(tester, wc);
      expect(find.text('Split · 2'), findsOneWidget);
      await _openEditor(tester);
      expect(find.byKey(const ValueKey('splitPart:1')), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('splitAmount:0'))).controller!.text, '30');
      await _tap(tester, find.byKey(const ValueKey('splitRemove')));
      expect(wc.splitCount(id), 0);
      expect(find.text('Split · 2'), findsNothing);
      expect(find.byType(PartTile), findsNothing);
      expect(find.text('Split removed'), findsOneWidget);
      await _tap(tester, find.text('Undo'));
      expect(wc.splitCount(id), 2);
      expect(find.text('Split · 2'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('tapping a part opens the payment sheet', (tester) async {
      final (wc, _) = split();
      await _spending(tester, wc);
      await _tap(tester, find.byType(PartTile).last);
      expect(find.byKey(const ValueKey('splitOpen')), findsOneWidget);
      expect(find.text('Split in 2 parts'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('a split that no longer adds up says so and Fix opens the editor', (tester) async {
      final (wc, id) = split();
      wc.repo.applyRemote([
        Op('tx', id, {'amount': -6000}, Hlc(DateTime.now().millisecondsSinceEpoch + 5000, 0, 'peer').toString())
      ]);
      wc.reload();
      await _spending(tester, wc);
      expect(find.text("Split doesn't add up"), findsOneWidget);
      expect(find.byType(PartTile), findsNothing); // counted whole
      await _tap(tester, _tile);
      expect(find.text("Split doesn't add up"), findsNWidgets(2)); // the tile and the sheet
      expect(find.widgetWithText(TextButton, 'Fix split'), findsOneWidget);
      expect(find.byKey(const ValueKey('splitFix')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('splitOpen')));
      expect(find.byKey(const ValueKey('splitSheet')), findsOneWidget);
      expect(_left(tester), contains('10.00')); // 60 - (30 + 20)
      expect(_saveOn(tester), isFalse);
      await _settle(tester);
    });
  });

  group('who can be split', () {
    testWidgets('a transfer has no Split button', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.addTransaction(date: '2026-10-14', amount: 5000, category: 'Internal transfer', note: 'Synthetic move');
      wc.reload();
      await _spending(tester, wc);
      // Transfers are hidden from the list: open the sheet directly.
      final row = wc.wholeTxs.firstWhere((t) => t.tx.note == 'Synthetic move');
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 2000));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('splitOpen')), findsNothing);
      await _settle(tester);
    });

    testWidgets('income can be split', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-15', 20000, 'Uplata', 'SYNTHETIC REFUND')]));
      wc.reload();
      final row = wc.wholeTxs.firstWhere((t) => t.tx.description == 'SYNTHETIC REFUND');
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 2000));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('splitOpen')), findsOneWidget);
      await _settle(tester);
    });
  });

  group('review findings', () {
    final threeParts = [
      const SplitPart(amount: -2000, category: 'Groceries', tags: [], note: null),
      const SplitPart(amount: -2000, category: 'Eating out', tags: [], note: 'Synthetic takeaway'),
      const SplitPart(amount: -1000, category: 'Shopping', tags: [], note: null),
    ];

    test('search: one split payment in 3 parts is one result; a part-only hit names the part', () {
      final (wc, id) = _wallet();
      wc.repo.setSplit(id, threeParts);
      wc.reload();
      expect(wc.search('mart').txs.where((t) => t.tx.id == id), hasLength(1));
      expect(wc.search('mart').txs.firstWhere((t) => t.tx.id == id).amount, -5000); // the whole amount
      final r = wc.search('takeaway');
      expect(r.txs.map((t) => t.tx.id), [id]);
      expect(r.matchedPart[id], 1);
    });

    testWidgets('search results show a split payment once, with the part that matched', (tester) async {
      final (wc, id) = _wallet();
      wc.repo.setSplit(id, threeParts);
      wc.reload();
      await pumpApp(tester, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})),
          size: const Size(400, 1500));
      await tester.enterText(find.byType(TextField).first, 'takeaway');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('hit:$id')), findsOneWidget);
      expect(find.text('Part 2 matches'), findsOneWidget);
      expect(find.text('Split · 3'), findsOneWidget);
      await _settle(tester);
    });

    test('tag counts: a payment counts once per tag, however many parts carry it', () async {
      final (wc, id) = _wallet();
      final tag = await wc.addTag('Synthetic trip');
      wc.repo.setSplit(id, [
        SplitPart(amount: -3000, category: 'Groceries', tags: [tag], note: null),
        SplitPart(amount: -2000, category: 'Eating out', tags: [tag], note: null),
      ]);
      wc.reload();
      expect(wc.tagUseCounts()[tag], 1);
    });

    test('a refused save is logged without text and rethrown; a refused restore says false', () {
      final (wc, id) = _wallet();
      wc.repo.setSplit(id, threeParts);
      wc.reload();
      final tx = wc.wholeTxs.firstWhere((t) => t.tx.id == id).tx;
      expect(() => wc.saveSplit(tx, [threeParts[0], threeParts[1]]), throwsArgumentError); // 40 of 50
      final old = wc.removeSplitOf(tx)!;
      wc.repo.applyRemote([
        Op('tx', id, {'amount': -6000}, Hlc(DateTime.now().millisecondsSinceEpoch + 5000, 0, 'peer').toString())
      ]);
      wc.reload();
      expect(wc.restoreSplitOf(wc.wholeTxs.firstWhere((t) => t.tx.id == id).tx, old), isFalse);
      expect(wc.splitCount(id), 0);
    });

    testWidgets('Undo says so when the split cannot be put back', (tester) async {
      final (wc, id) = _wallet();
      wc.repo.setSplit(id, threeParts);
      wc.reload();
      await _spending(tester, wc);
      await _openEditor(tester);
      await _tap(tester, find.byKey(const ValueKey('splitRemove')));
      wc.repo.applyRemote([
        Op('tx', id, {'amount': -6000}, Hlc(DateTime.now().millisecondsSinceEpoch + 5000, 0, 'peer').toString())
      ]);
      await _tap(tester, find.text('Undo'));
      expect(find.text("Couldn't put the split back"), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('Undo restores amounts, main tags, tags and notes exactly', (tester) async {
      final (wc, id) = _wallet();
      final tag = await tester.runAsync(() => wc.addTag('Synthetic trip'));
      wc.repo.setSplit(id, [
        SplitPart(amount: -3000, category: 'Groceries', tags: [tag!], note: 'Weekly'),
        const SplitPart(amount: -2000, category: 'Eating out', tags: [], note: 'Takeaway'),
      ]);
      wc.reload();
      List<List<Object?>> shape() => [
            for (final p in wc.storedSplit(id)!) [p.amount, p.category, p.tags, p.note]
          ];
      final before = shape();
      await _spending(tester, wc);
      await _openEditor(tester);
      await _tap(tester, find.byKey(const ValueKey('splitRemove')));
      expect(wc.storedSplit(id), isNull);
      await _tap(tester, find.text('Undo'));
      expect(shape(), before);
      await _settle(tester);
    });

    testWidgets('a comma amount ("12,50") is read', (tester) async {
      final (wc, id) = _wallet();
      await _spending(tester, wc);
      await _openEditor(tester);
      await _type(tester, 'splitAmount:0', '37,50');
      await _type(tester, 'splitAmount:1', '12,50');
      expect(_saveOn(tester), isTrue);
      await _tap(tester, find.byKey(const ValueKey('splitSave')));
      expect(wc.storedSplit(id)!.map((p) => p.amount), [-3750, -1250]);
      await _settle(tester);
    });

    testWidgets('a main tag picked on the payment sheet and not saved starts the first part', (tester) async {
      final (wc, id) = _wallet();
      await _spending(tester, wc);
      await _tap(tester, _tile);
      await _tap(tester, find.byKey(const ValueKey('txCategory')));
      await _tap(tester, find.byKey(const ValueKey('pick:Eating out')).last);
      await _tap(tester, find.byKey(const ValueKey('splitOpen')));
      for (final i in [0, 1]) {
        expect(tester.widget<DropdownButton<String>>(find.byKey(ValueKey('splitCategory:$i'))).value, 'Eating out');
      }
      expect(wc.repo.splitOf(id), isNull);
      await _settle(tester);
    });

    testWidgets('Today\'s recent rows carry the split mark', (tester) async {
      final (wc, id) = _wallet();
      wc.repo.setSplit(id, threeParts);
      wc.reload();
      await pumpApp(tester, Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday)), size: const Size(400, 3000));
      await tester.pumpAndSettle();
      expect(find.text('Split · 3'), findsOneWidget);
      await _settle(tester);
    });
  });

  group('controller lists', () {
    testWidgets('txs holds the parts, wholeTxs the payments; totals use the parts', (tester) async {
      final (wc, id) = _wallet();
      final before = wc.txs.length;
      wc.repo.setSplit(id, const [
        SplitPart(amount: -3000, category: 'Groceries', tags: [], note: null),
        SplitPart(amount: -2000, category: 'Eating out', tags: [], note: null),
      ]);
      wc.reload();
      expect(wc.txs.length, before + 1);
      expect(wc.wholeTxs.length, before);
      expect(wc.txs.where((t) => t.tx.id == id).map((t) => t.amount), [-3000, -2000]);
      expect(wc.wholeTxs.where((t) => t.tx.id == id).single.amount, -5000);
      expect(wc.partsOf(id).length, 2);
      expect(wc.splitIsBroken(id), isFalse);
      await _settle(tester);
    });
  });
}
