// Stage T1 UI: extra tags next to the main tag. The pickers (payee first, top 20, More), the tag editor in the transaction sheet (toggle,
// suggestion on tap only, from-rule removal for one row, new tag, payee rule), the add-expense sheet, Plan › Tags, the `#tag` chips on
// rows, Insights › Tags with its drill-down, search and the CSV column, and the layouts. All data is SYNTHETIC (budgetWallet, 20 Oct 2026).
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/screens/tag_detail.dart';
import 'package:budget_wallet/src/screens/tags_panel.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/category_picker.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 90));

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Finder k(String key) => find.byKey(ValueKey(key));

/// budgetWallet plus bank rows of two payees (three at KONZUM, one at LIDL) and three tags.
Future<({WalletController wc, String holiday, String kids, String work})> tagsWallet() async {
  final wc = budgetWallet(budgets: false);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-08', -1200, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-09', -3000, 'POS plaćanje', 'POS LIDL 0000 ZAGREB'),
  ]));
  final holiday = await wc.addTag('Holiday');
  final kids = await wc.addTag('Kids');
  final work = await wc.addTag('Work');
  wc.reload();
  return (wc: wc, holiday: holiday, kids: kids, work: work);
}

/// The bank rows of [word] in the payee's description, oldest first.
List<CategorizedTx> rowsOfPayee(WalletController wc, String word) =>
    wc.txs.where((x) => x.tx.description.contains(word)).toList()..sort((a, b) => a.date.compareTo(b.date));

CategorizedTx fresh(WalletController wc, CategorizedTx t) => wc.txs.firstWhere((x) => x.tx.id == t.tx.id);

Future<void> openSheet(WidgetTester t, WalletController wc, CategorizedTx row, {Size size = const Size(400, 3200)}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: size);

Widget tagsPanel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: TagsPanel(wc: wc))));

void remoteTag(WalletController wc, String id, String name) {
  final now = DateTime.now().millisecondsSinceEpoch;
  wc.repo.applyRemote([
    Op('tag', id, {'name': name, 'position': 0, 'hidden': 0, 'deleted': 0}, Hlc(now + 60000, 0, 'peer').toString())
  ]);
  wc.reload();
}

Future<void> pumpVariant(WidgetTester t, Widget child,
    {required Size size, double scale = 1, Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: child,
  ));
  await t.pump();
}

/// Scrolls Insights down to the Tags panel (the list builds panels as they come into view).
Future<void> reveal(WidgetTester t) async {
  await t.scrollUntilVisible(k('insightPanel_tags'), 300, scrollable: find.byType(Scrollable).first);
  await t.pump();
}

void main() {
  group('main tag order: the payee first, the top 20, then More', () {
    test('the payee\'s own main tag comes first; another payee goes by overall use', () async {
      final wc = budgetWallet(budgets: false);
      wc.repo.addTransaction(date: '2026-10-10', amount: 500, category: 'Shopping', note: 'Bakery run');
      wc.repo.addTransaction(date: '2026-10-11', amount: 700, category: 'Shopping', note: 'Bakery run');
      wc.repo.addTransaction(date: '2026-10-12', amount: 900, category: 'Shopping', note: 'Bakery run');
      wc.reload();
      final bakery = wc.txs.firstWhere((x) => x.tx.note == 'Bakery run');
      expect(wc.recommendedMainFor(bakery.tx).first, 'Shopping');
      final other = wc.txs.firstWhere((x) => (x.tx.note ?? '').isEmpty && x.tx.source == 'manual' && x.category == 'Groceries');
      expect(wc.recommendedMainFor(other.tx).first, 'Groceries', reason: 'the most used overall');
      expect(wc.recommendedMainFor(bakery.tx), containsAll(wc.categoryTable.pickable()));
      wc.dispose();
    });

    test('the ordering is cached per data version (not recomputed per call)', () async {
      final wc = budgetWallet(budgets: false);
      final row = wc.txs.first;
      final a = wc.recommendedMainFor(row.tx);
      expect(identical(wc.recommendedMainFor(row.tx), a), isTrue);
      wc.reload();
      expect(identical(wc.recommendedMainFor(row.tx), a), isFalse);
      wc.dispose();
    });

    testWidgets('chips: 20 show, More opens the rest, the chosen one is always shown', (t) async {
      final wc = budgetWallet(budgets: false);
      for (var i = 0; i < 6; i++) {
        await wc.addOwnCategory(name: 'Own $i', kind: BudgetKind.flex);
      }
      final ids = wc.recommendedMainFor(null);
      expect(ids.length, greaterThan(mainTagTop));
      final last = ids.last;
      await pumpApp(
          t, Scaffold(body: SingleChildScrollView(child: MainTagPicker(table: wc.categoryTable, ids: ids, selected: last, onPick: (_) {}))),
          size: const Size(400, 2400));
      int chips() => find.byWidgetPredicate((w) => w is ChoiceChip).evaluate().length;
      expect(chips(), mainTagTop + 1, reason: 'the top 20 and the chosen one');
      expect(k('cat:$last'), findsOneWidget);
      expect(k('mainTagMore'), findsOneWidget);
      await tapKey(t, 'mainTagMore');
      expect(chips(), ids.length);
      expect(k('mainTagMore'), findsNothing);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('the sheet\'s menu lists the payee\'s main tag first and has a More… entry', (t) async {
      final wc = budgetWallet(budgets: false);
      for (var i = 0; i < 6; i++) {
        await wc.addOwnCategory(name: 'Own $i', kind: BudgetKind.flex);
      }
      wc.repo.addTransaction(date: '2026-10-10', amount: 500, category: 'Shopping', note: 'Bakery run');
      wc.repo.addTransaction(date: '2026-10-11', amount: 700, category: 'Shopping', note: 'Bakery run');
      wc.reload();
      final row = wc.txs.firstWhere((x) => x.tx.note == 'Bakery run');
      await openSheet(t, wc, row, size: const Size(400, 3600));
      await tapKey(t, 'txCategory');
      final first = t.getTopLeft(k('pick:Shopping').last).dy;
      expect(first, lessThan(t.getTopLeft(k('pick:Groceries').last).dy), reason: 'the payee\'s own first');
      expect(k('mainTagMore'), findsOneWidget);
      await t.tap(k('mainTagMore'));
      await t.pump(const Duration(milliseconds: 400));
      await tapKey(t, 'txCategory');
      expect(k('mainTagMore'), findsNothing);
      expect(k('pick:${wc.recommendedMainFor(row.tx).last}'), findsWidgets);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('the tag editor in the transaction sheet', () {
    testWidgets('a tag toggles on and off from the list and writes the payment\'s link', (t) async {
      final (:wc, :holiday, :kids, work: _) = await tagsWallet();
      final row = rowsOfPayee(wc, 'LIDL').single;
      await openSheet(t, wc, row);
      expect(k('noTags'), findsOneWidget);
      await tapKey(t, 'tagAdd');
      await tapKey(t, 'tagPick:$holiday');
      expect(fresh(wc, row).tags, [holiday]);
      expect(k('tagOn:$holiday'), findsOneWidget);
      expect(k('tagPick:$holiday'), findsNothing, reason: 'it moved to the chosen tags');
      await tapKey(t, 'tagPick:$kids');
      expect(fresh(wc, row).tags.toSet(), {holiday, kids});
      await tapKey(t, 'tagOn:$holiday');
      expect(fresh(wc, row).tags, [kids]);
      expect(k('tagOn:$holiday'), findsNothing);
      expect(k('tagPick:$holiday'), findsOneWidget, reason: 'back in the list');
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a suggestion is only a faded chip: nothing is applied until it is tapped', (t) async {
      final (:wc, :holiday, :kids, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await wc.setPaymentTag(konzum[0].tx.id, kids, true);
      await wc.setPaymentTag(konzum[1].tx.id, kids, true);
      await wc.setPaymentTag(konzum[1].tx.id, holiday, true); // once: below the threshold of two
      final row = fresh(wc, konzum[2]);
      expect(row.tags, isEmpty);
      await openSheet(t, wc, row);
      expect(k('tagSuggest:$kids'), findsOneWidget);
      expect(k('tagSuggest:$holiday'), findsNothing, reason: 'used once only');
      expect(fresh(wc, row).tags, isEmpty, reason: 'shown, not applied');
      expect(find.descendant(of: k('tagSuggest:$kids'), matching: find.byIcon(Icons.add)), findsOneWidget);
      await tapKey(t, 'tagSuggest:$kids');
      expect(fresh(wc, row).tags, [kids]);
      expect(k('tagSuggest:$kids'), findsNothing);
      expect(k('tagOn:$kids'), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a tag a rule gives is marked, and removing it is for this payment only', (t) async {
      final (:wc, :holiday, kids: _, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await wc.setPayeeTag(konzum[0].tx, holiday, true);
      expect(konzum.map((r) => fresh(wc, r).tags), everyElement([holiday]));
      await openSheet(t, wc, fresh(wc, konzum[0]));
      expect(find.descendant(of: k('tagOn:$holiday'), matching: find.textContaining('from rule')), findsOneWidget);
      expect(k('ruleOffNote'), findsNothing);
      await tapKey(t, 'tagOn:$holiday');
      expect(k('ruleOffNote'), findsOneWidget);
      expect(find.textContaining('this payment only'), findsOneWidget);
      expect(fresh(wc, konzum[0]).tags, isEmpty);
      expect(fresh(wc, konzum[1]).tags, [holiday], reason: 'the other payments keep it');
      expect(fresh(wc, konzum[2]).tags, [holiday]);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a new tag is created and applied; a taken name shows core\'s message', (t) async {
      final (:wc, holiday: _, kids: _, work: _) = await tagsWallet();
      final row = rowsOfPayee(wc, 'LIDL').single;
      await openSheet(t, wc, row);
      await tapKey(t, 'tagAdd');
      await t.enterText(k('tagNew'), 'Garden');
      await tapKey(t, 'tagNewGo');
      final garden = wc.tagTable.ids.firstWhere((id) => wc.tagTable.label(id) == 'Garden');
      expect(fresh(wc, row).tags, [garden]);
      expect(k('tagOn:$garden'), findsOneWidget);
      // The same name again (any case) is refused and nothing new is made.
      final before = wc.tagTable.ids.length;
      await t.enterText(k('tagNew'), 'garden');
      await tapKey(t, 'tagNewGo');
      expect(wc.tagTable.ids.length, before);
      expect(t.widget<TextField>(k('tagNew')).decoration!.errorText, isNotNull);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('"Also tag every payment from this payee with…" writes a rule for all of its payments', (t) async {
      final (:wc, :holiday, kids: _, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await openSheet(t, wc, konzum[0]);
      expect(find.textContaining('Also tag every payment from'), findsOneWidget);
      expect(k('payeeRuleEmpty'), findsOneWidget, reason: 'nothing to pick before this payment has a tag');
      await tapKey(t, 'tagAdd');
      await tapKey(t, 'tagPick:$holiday');
      expect(fresh(wc, konzum[1]).tags, isEmpty);
      await tapKey(t, 'ruleTag:$holiday');
      expect(fresh(wc, konzum[1]).tags, [holiday]);
      expect(fresh(wc, konzum[2]).tags, [holiday]);
      expect(fresh(wc, rowsOfPayee(wc, 'LIDL').single).tags, isEmpty, reason: 'another payee');
      await tapKey(t, 'ruleTag:$holiday');
      expect(fresh(wc, konzum[2]).tags.contains(holiday), isFalse);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a hand-added payment has no payee rule', (t) async {
      final (:wc, holiday: _, kids: _, work: _) = await tagsWallet();
      final row = wc.txs.firstWhere((x) => x.tx.source == 'manual' && (x.tx.note ?? '').isEmpty);
      await openSheet(t, wc, row);
      expect(find.textContaining('Also tag every payment from'), findsNothing);
      expect(k('tagAdd'), findsOneWidget);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('the add-expense sheet', () {
    testWidgets('picks a main tag and extra tags; they are written with the payment', (t) async {
      final (:wc, :holiday, :kids, work: _) = await tagsWallet();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc, skipImpulse: true))),
          size: const Size(400, 2400));
      expect(find.textContaining('Main tag'), findsWidgets);
      await t.enterText(find.byType(TextField).first, '12.50');
      await tapKey(t, 'cat:Shopping');
      await tapKey(t, 'tagAdd');
      await tapKey(t, 'tagPick:$holiday');
      await tapKey(t, 'tagPick:$kids');
      await tapKey(t, 'tagOn:$kids'); // changed its mind
      await t.tap(k('addExpenseSave'));
      await settle(t);
      final added = wc.txs.firstWhere((x) => x.amount == -1250);
      expect(added.category, 'Shopping');
      expect(added.tags, [holiday]);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a new tag made here is applied to the new payment', (t) async {
      final (:wc, holiday: _, kids: _, work: _) = await tagsWallet();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc, skipImpulse: true))),
          size: const Size(400, 2400));
      await t.enterText(find.byType(TextField).first, '3');
      await tapKey(t, 'cat:Shopping');
      await tapKey(t, 'tagAdd');
      await t.enterText(k('tagNew'), 'Gifts');
      await tapKey(t, 'tagNewGo');
      await t.tap(k('addExpenseSave'));
      await settle(t);
      final gifts = wc.tagTable.ids.firstWhere((id) => wc.tagTable.label(id) == 'Gifts');
      expect(wc.txs.firstWhere((x) => x.amount == -300).tags, [gifts]);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('Plan › Tags', () {
    testWidgets('empty first; add a tag with a name rule message; the row shows its payment count', (t) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(t, tagsPanel(wc), size: const Size(400, 3000));
      expect(k('tagsEmpty'), findsOneWidget);
      await tapKey(t, 'tagsAdd');
      await t.enterText(k('tagName'), 'Garden');
      await tapKey(t, 'tagSave');
      final id = wc.tagTable.ids.single;
      expect(wc.tagTable.label(id), 'Garden');
      expect(k('tagsEmpty'), findsNothing);
      expect(find.text('#Garden'), findsOneWidget);
      expect(find.text('0 payments'), findsOneWidget);
      // A main tag's name is taken: core's message shows under the field and the sheet stays open.
      await tapKey(t, 'tagsAdd');
      await t.enterText(k('tagName'), 'Groceries');
      await tapKey(t, 'tagSave');
      expect(t.widget<TextField>(k('tagName')).decoration!.errorText, isNotNull);
      expect(wc.tagTable.ids.length, 1);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('counts, rename, hide and show', (t) async {
      final (:wc, :holiday, kids: _, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await wc.setPaymentTag(konzum[0].tx.id, holiday, true);
      await wc.setPaymentTag(konzum[1].tx.id, holiday, true);
      await pumpApp(t, tagsPanel(wc), size: const Size(400, 3000));
      expect(find.descendant(of: k('tag:$holiday'), matching: find.text('2 payments')), findsOneWidget);
      await tapKey(t, 'tagMenu:$holiday');
      await tapKey(t, 'tagRename:$holiday');
      expect(find.widgetWithText(TextField, 'Holiday'), findsOneWidget, reason: 'prefilled');
      await t.enterText(k('tagName'), 'Trips');
      await tapKey(t, 'tagSave');
      expect(wc.tagTable.label(holiday), 'Trips');
      expect(find.text('#Trips'), findsOneWidget);
      await tapKey(t, 'tagMenu:$holiday');
      await tapKey(t, 'tagHide:$holiday');
      expect(k('tagHidden:$holiday'), findsOneWidget);
      expect(wc.tagTable.pickable(), isNot(contains(holiday)));
      expect(find.descendant(of: k('tag:$holiday'), matching: find.text('2 payments')), findsOneWidget,
          reason: 'its payments keep the tag');
      await tapKey(t, 'tagMenu:$holiday');
      await tapKey(t, 'tagHide:$holiday');
      expect(k('tagHidden:$holiday'), findsNothing);
      expect(wc.tagTable.pickable(), contains(holiday));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('move up and down; the first cannot go up and the last cannot go down', (t) async {
      final (:wc, :holiday, :kids, :work) = await tagsWallet();
      expect(wc.tagTable.ids, [holiday, kids, work], reason: 'no positions yet: by name');
      await pumpApp(t, tagsPanel(wc), size: const Size(400, 3000));
      await tapKey(t, 'tagMenu:$work');
      await tapKey(t, 'tagUp:$work');
      expect(wc.tagTable.ids, [holiday, work, kids]);
      await tapKey(t, 'tagMenu:$holiday');
      await tapKey(t, 'tagDown:$holiday');
      expect(wc.tagTable.ids, [work, holiday, kids]);
      // The list on screen follows.
      expect(t.getTopLeft(k('tag:$work')).dy, lessThan(t.getTopLeft(k('tag:$holiday')).dy));
      expect(t.getTopLeft(k('tag:$holiday')).dy, lessThan(t.getTopLeft(k('tag:$kids')).dy));
      // Edges: the menu entries are disabled and nothing is written.
      final v = wc.dataVersion;
      await wc.moveTag(work, -1);
      await wc.moveTag(kids, 1);
      expect(wc.dataVersion, v);
      await tapKey(t, 'tagMenu:$work');
      expect(t.widget<PopupMenuItem<dynamic>>(k('tagUp:$work')).enabled, isFalse);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('delete shows Undo and Undo brings the tag and its links back', (t) async {
      final (:wc, :holiday, kids: _, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await wc.setPaymentTag(konzum[0].tx.id, holiday, true);
      await pumpApp(t, tagsPanel(wc), size: const Size(400, 3000));
      await tapKey(t, 'tagMenu:$holiday');
      await tapKey(t, 'tagDeleteItem:$holiday');
      expect(find.text('Tag removed'), findsOneWidget);
      expect(k('tag:$holiday'), findsNothing);
      expect(fresh(wc, konzum[0]).tags, isEmpty);
      await t.tap(k('toastUndo'));
      await t.pump(const Duration(milliseconds: 400));
      expect(k('tag:$holiday'), findsOneWidget);
      expect(fresh(wc, konzum[0]).tags, [holiday]);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a sync duplicate says "same name as X, merged", counts once, and can be deleted', (t) async {
      final wc = budgetWallet(budgets: false);
      remoteTag(wc, 'taaaaaaaaaaaa', 'Pets');
      remoteTag(wc, 'tbbbbbbbbbbbb', 'pets');
      await pumpApp(t, tagsPanel(wc), size: const Size(400, 3000));
      expect(k('tagDuplicate:tbbbbbbbbbbbb'), findsOneWidget);
      expect(find.textContaining('same name as Pets, merged'), findsOneWidget);
      expect(k('tag:taaaaaaaaaaaa'), findsOneWidget);
      expect(wc.tagTable.pickable(), isNot(contains('tbbbbbbbbbbbb')));
      await tapKey(t, 'tagDelete:tbbbbbbbbbbbb');
      expect(k('tagDuplicate:tbbbbbbbbbbbb'), findsNothing);
      expect(k('tag:taaaaaaaaaaaa'), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('Plan › Main tags has no subcategory action', (t) async {
      final wc = budgetWallet(budgets: false);
      expect(() => wc.repo.addCategory(name: 'Sub', kind: BudgetKind.flex, parent: 'Groceries'), throwsA(isA<ArgumentError>()));
      wc.dispose();
    });
  });

  group('rows', () {
    testWidgets('a row shows up to 3 extra tags as #chips, then +N', (t) async {
      final wc = budgetWallet(budgets: false);
      final ids = [
        for (final n in ['Alpha', 'Beta', 'Gamma', 'Delta', 'Eps']) await wc.addTag(n)
      ];
      final row = wc.txs.firstWhere((x) => (x.tx.note ?? '').isEmpty && x.category == 'Shopping');
      for (final id in ids) {
        await wc.setPaymentTag(row.tx.id, id, true);
      }
      final tagged = fresh(wc, row);
      expect(tagged.tags, hasLength(5));
      await pumpApp(t, Scaffold(body: TxTile(t: tagged, currency: 'EUR', table: wc.categoryTable, tagTable: wc.tagTable)));
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('rowTag:')),
          findsNWidgets(3));
      expect(find.text('#Alpha'), findsOneWidget);
      expect(find.text('#Gamma'), findsOneWidget);
      expect(find.text('#Delta'), findsNothing);
      expect(find.text('+2'), findsOneWidget);
      // Exactly 3 shows no "+N".
      await wc.setPaymentTag(row.tx.id, ids[4], false);
      await wc.setPaymentTag(row.tx.id, ids[3], false);
      await pumpApp(t, Scaffold(body: TxTile(t: fresh(wc, row), currency: 'EUR', table: wc.categoryTable, tagTable: wc.tagTable)));
      expect(k('rowTagsMore'), findsNothing);
      expect(find.text('#Gamma'), findsOneWidget);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a row without tags shows no chips; a row fits at 320 dp and text 2.0 with long tag names', (t) async {
      final wc = budgetWallet(budgets: false);
      final ids = [
        for (final n in ['A long tag name for a small phone', 'Second long name that may not overflow', 'Third', 'Fourth'])
          await wc.addTag(n)
      ];
      final row = wc.txs.firstWhere((x) => (x.tx.note ?? '').isEmpty && x.category == 'Shopping');
      await pumpApp(t, Scaffold(body: TxTile(t: row, currency: 'EUR', table: wc.categoryTable, tagTable: wc.tagTable)),
          size: const Size(320, 700), textScale: 2);
      expect(k('rowTagsMore'), findsNothing);
      for (final id in ids) {
        await wc.setPaymentTag(row.tx.id, id, true);
      }
      await pumpApp(
          t,
          Scaffold(
              body:
                  SingleChildScrollView(child: TxTile(t: fresh(wc, row), currency: 'EUR', table: wc.categoryTable, tagTable: wc.tagTable))),
          size: const Size(320, 700),
          textScale: 2);
      expect(t.takeException(), isNull);
      expect(find.text('+1'), findsOneWidget);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('Insights › Tags', () {
    Future<({WalletController wc, String holiday, String kids})> tagged() async {
      final (:wc, :holiday, :kids, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await wc.setPaymentTag(konzum[0].tx.id, holiday, true); // 18.50
      await wc.setPaymentTag(konzum[1].tx.id, holiday, true); // 9.40
      await wc.setPaymentTag(konzum[1].tx.id, kids, true); // the same 9.40 again: tags overlap
      await wc.setPaymentTag(rowsOfPayee(wc, 'LIDL').single.tx.id, kids, true); // 30.00
      return (wc: wc, holiday: holiday, kids: kids);
    }

    Future<void> showPanel(WidgetTester t, WalletController wc, {Size size = const Size(400, 900)}) async {
      await pumpApp(t, InsightsScreen(wc: wc), size: size);
      await reveal(t);
    }

    testWidgets('tags with what they cost, the overlap note, and "No extra tag"', (t) async {
      final (:wc, :holiday, :kids) = await tagged();
      await showPanel(t, wc);
      expect(k('tagsOverlapNote'), findsOneWidget);
      expect(find.text('A payment can have several tags, so these overlap.'), findsOneWidget);
      final r = wc.monthRange('2026-10');
      final share = wc.tagShareFor(r);
      expect(share.slices.map((s) => s.tag).toSet(), {holiday, kids});
      expect(share.slices.firstWhere((s) => s.tag == holiday).spent, 2790);
      expect(share.slices.firstWhere((s) => s.tag == kids).spent, 3940);
      expect(share.slices.fold<int>(0, (a, s) => a + s.spent), 2790 + 3940, reason: 'the 9.40 payment counts under both tags');
      expect(find.descendant(of: k('tagRow_$holiday'), matching: find.text(moneyExact(2790, 'EUR'))), findsOneWidget);
      expect(find.descendant(of: k('tagRow_$kids'), matching: find.text(moneyExact(3940, 'EUR'))), findsOneWidget);
      // The rest: spending with no extra tag, computed from the rows here.
      final untagged = wc.txs
          .where((x) =>
              x.tx.live &&
              x.date.startsWith('2026-10') &&
              x.tags.isEmpty &&
              (x.kind == BudgetKind.fixed || x.kind == BudgetKind.flex) &&
              x.tx.currency == 'EUR')
          .fold<int>(0, (a, x) => a - x.amount);
      expect(share.untaggedSpent, untagged);
      await t.ensureVisible(k('tagsUntagged'));
      expect(find.descendant(of: k('tagsUntagged'), matching: find.text(moneyExact(untagged, 'EUR'))), findsOneWidget);
      expect(find.descendant(of: k('tagsUntagged'), matching: find.text('No extra tag')), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('a tag opens its payments and per-month bars; the total equals the rows', (t) async {
      final (:wc, :holiday, kids: _) = await tagged();
      await showPanel(t, wc);
      await tapKey(t, 'tagRow_$holiday');
      expect(find.byType(TagDetailScreen), findsOneWidget);
      final r = wc.monthRange('2026-10');
      final rows = wc.rowsOfTag(holiday, r);
      expect(rows, hasLength(2));
      final sum = -rows.fold<int>(0, (a, x) => a + x.amount);
      expect(sum, 2790);
      expect(t.widget<Text>(find.descendant(of: k('tagDetailTotal'), matching: find.byType(Text))).data, moneyExact(sum, 'EUR'));
      expect(find.descendant(of: k('tagRows'), matching: find.byType(TxTile)), findsNWidgets(2));
      expect(wc.tagBars(holiday, r).fold<int>(0, (a, b) => a + b.spent), sum, reason: 'the per-month bars add up to the same total');
      expect(k('tagDetailBars'), findsOneWidget);
      await settle(t);
      wc.dispose();
    }, timeout: _timeout);

    testWidgets('nothing tagged: an empty note and no overlap rows', (t) async {
      final wc = budgetWallet(budgets: false);
      await showPanel(t, wc);
      expect(find.text('No tagged spending in this range.'), findsOneWidget);
      expect(k('tagsOverlapNote'), findsOneWidget);
      wc.dispose();
    }, timeout: _timeout);
  });

  group('search and CSV', () {
    test('search finds payments by tag label; the CSV has a tags column after the main tag', () async {
      final (:wc, :holiday, :kids, work: _) = await tagsWallet();
      final konzum = rowsOfPayee(wc, 'KONZUM');
      await wc.setPaymentTag(konzum[0].tx.id, holiday, true);
      await wc.setPaymentTag(konzum[0].tx.id, kids, true);
      await wc.setPaymentTag(konzum[1].tx.id, holiday, true);
      expect(wc.search('holiday').txs.map((x) => x.tx.id).toSet(), {konzum[0].tx.id, konzum[1].tx.id});
      expect(wc.search('kids').txs.map((x) => x.tx.id), [konzum[0].tx.id]);
      await wc.renameTag(holiday, 'Trips');
      expect(wc.search('holiday').txs, isEmpty);
      expect(wc.search('trips').txs, hasLength(2));
      final csv = utf8.decode(wc.exportTransactions(ExportRange.all).bytes.sublist(3)).trim().split('\n');
      expect(csv.first, 'date,amount,category,tags,description,source,note');
      final both = csv.firstWhere((l) => l.contains('Kids') && l.startsWith('2026-10-02'));
      expect(both.split(',')[3], 'Trips; Kids', reason: 'table order, joined with "; "');
      expect(csv.firstWhere((l) => l.startsWith('2026-10-09')).split(',')[3], '', reason: 'no tags: an empty column');
      expect(both.split(',')[2], isNot(contains('Trips')), reason: 'category stays the main tag');
      wc.dispose();
    });
  });

  group('layouts', () {
    for (final (name, size, scale, brightness) in [
      ('320 dp at text 2.0', const Size(320, 4200), 2.0, Brightness.light),
      ('400 dp dark', const Size(400, 3200), 1.0, Brightness.dark),
      ('1280 wide', const Size(1280, 2000), 1.0, Brightness.light),
    ]) {
      testWidgets('the tag editor, the Tags panel and the Insights panel fit at $name', (t) async {
        final (:wc, :holiday, :kids, work: _) = await tagsWallet();
        final konzum = rowsOfPayee(wc, 'KONZUM');
        await wc.setPaymentTag(konzum[0].tx.id, kids, true);
        await wc.setPaymentTag(konzum[1].tx.id, kids, true);
        await wc.setPayeeTag(konzum[0].tx, holiday, true);
        await wc.addTag('A long tag name for a small phone');
        final row = fresh(wc, konzum[2]);
        await pumpVariant(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))),
            size: size, scale: scale, brightness: brightness);
        expect(t.takeException(), isNull);
        await tapKey(t, 'tagAdd');
        expect(t.takeException(), isNull);
        expect(k('tagSuggest:$kids'), findsOneWidget);
        await pumpVariant(t, tagsPanel(wc), size: size, scale: scale, brightness: brightness);
        expect(t.takeException(), isNull);
        await tapKey(t, 'tagMenu:$kids');
        expect(t.takeException(), isNull);
        await t.tapAt(const Offset(2, 2));
        await t.pump(const Duration(milliseconds: 400));
        await pumpVariant(t, InsightsScreen(wc: wc), size: size, scale: scale, brightness: brightness);
        await reveal(t);
        expect(t.takeException(), isNull);
        expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, brightness);
        await settle(t);
        wc.dispose();
      }, timeout: _timeout);
    }
  });
}
