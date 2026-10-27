// Stage Q1 + Q6 UI: the main tag chips and the payee list under the Add expense note, and the payee-rule suggestions (the toast after a
// hand-set main tag, Plan › Rules › Suggested). Nothing is ever applied without a tap. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/rules_panel.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 60));

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> tapKey(WidgetTester t, String key) async {
  final f = k(key).last;
  await t.pumpAndSettle(); // a focused field's caret scroll must end before the target is scrolled into view
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// Lets the 3 s sync debounce and the toast time out.
Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4));

/// Hand-added payments worded "lunch ...", one per kind of main tag: eating out (twice), shopping, a fixed one, a hidden one, a bank fee.
Future<WalletController> typedWallet() async {
  final wc = emptyWallet();
  wc.repo.setLocalValue('lastExpenseCategory', 'Groceries');
  wc.repo.addTransaction(date: '2026-10-08', amount: 1200, category: 'Eating out', note: 'Lunch with Ana');
  wc.repo.addTransaction(date: '2026-10-09', amount: 900, category: 'Eating out', note: 'Lunch with Ana');
  wc.repo.addTransaction(date: '2026-10-03', amount: 700, category: 'Shopping', note: 'Lunch bag');
  wc.repo.addTransaction(date: '2026-10-04', amount: 5000, category: 'Rent', note: 'Lunch rent');
  wc.repo.addTransaction(date: '2026-10-05', amount: 300, category: 'Games & apps', note: 'Lunch game');
  wc.repo.addTransaction(date: '2026-10-06', amount: 100, category: 'Bank fees', note: 'Lunch fee');
  wc.reload();
  await wc.setCategoryHidden('Games & apps', true);
  return wc;
}

Future<void> openAdd(WidgetTester t, WalletController wc, {Size size = const Size(400, 900), double textScale = 1}) async {
  await pumpApp(
      t,
      Builder(
          builder: (ctx) => Scaffold(
                body: Center(
                    child: ElevatedButton(onPressed: () => showSheet<String>(ctx, AddExpenseSheet(wc: wc)), child: const Text('open'))),
              )),
      size: size,
      textScale: textScale);
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Future<void> typeNote(WidgetTester t, String text) async {
  await t.enterText(k('expenseNote'), text);
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

/// The category of the newest hand-added row ("added by the test" is not distinguishable: the note is).
String? ownCategoryOf(WalletController wc, String note) => wc.repo.transactions().firstWhere((t) => t.note == note).category;

void main() {
  group('Q1: chips under the note', () {
    testWidgets('they follow the typing after 250 ms, offer only the picker\'s tags, and never pick on their own', (t) async {
      final wc = await typedWallet();
      addTearDown(wc.dispose);
      await openAdd(t, wc);
      expect(k('suggestChips'), findsNothing);
      await t.enterText(k('expenseNote'), 'lunch');
      await t.pump(const Duration(milliseconds: 100));
      expect(k('suggestCat:Eating out'), findsNothing, reason: 'debounced');
      await t.pump(const Duration(milliseconds: 200));
      expect(k('suggestCat:Eating out'), findsOneWidget);
      expect(k('suggestCat:Shopping'), findsOneWidget);
      // Never offered: a fixed tag, a hidden one, a bank fee (none of them is in the picker).
      for (final id in ['Rent', 'Games & apps', 'Bank fees']) {
        expect(k('suggestCat:$id'), findsNothing, reason: id);
      }
      // The main tag is still the one the sheet started with.
      expect(t.widget<ChoiceChip>(k('cat:Groceries')).selected, isTrue);
      expect(t.widget<ChoiceChip>(k('suggestCat:Eating out')).selected, isFalse);
      await t.enterText(find.widgetWithText(TextField, 'Amount'), '5');
      await t.pump();
      await tapKey(t, 'addExpenseSave');
      expect(ownCategoryOf(wc, 'lunch'), 'Groceries', reason: 'typing alone changes nothing');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('a tap sets the main tag and nothing else', (t) async {
      final wc = await typedWallet();
      addTearDown(wc.dispose);
      await openAdd(t, wc);
      await typeNote(t, 'lunch');
      await tapKey(t, 'suggestCat:Eating out');
      expect(t.widget<ChoiceChip>(k('suggestCat:Eating out')).selected, isTrue);
      expect(t.widget<ChoiceChip>(k('cat:Groceries')).selected, isFalse);
      expect(t.widget<TextField>(k('expenseNote')).controller!.text, 'lunch');
      await t.enterText(find.widgetWithText(TextField, 'Amount'), '5');
      await t.pump();
      await tapKey(t, 'addExpenseSave');
      expect(ownCategoryOf(wc, 'lunch'), 'Eating out');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('a short or unknown note shows no chips, and clearing the note removes them', (t) async {
      final wc = await typedWallet();
      addTearDown(wc.dispose);
      await openAdd(t, wc);
      await typeNote(t, 'lu');
      expect(k('suggestChips'), findsNothing);
      await typeNote(t, 'zzzzz-unknown');
      expect(k('suggestChips'), findsNothing);
      await typeNote(t, 'lunch');
      expect(k('suggestChips'), findsOneWidget);
      await typeNote(t, '');
      expect(k('suggestChips'), findsNothing);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('a built-in rule suggests its tag, and a note passed in starts with chips', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      await pumpApp(
          t,
          Builder(
              builder: (ctx) => Scaffold(
                    body: Center(
                        child: ElevatedButton(
                            onPressed: () => showSheet<String>(ctx, AddExpenseSheet(wc: wc, note: 'Lidl')), child: const Text('open'))),
                  )));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(k('suggestCat:Groceries'), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('the payee list offers recent notes, and picking one fills the note and updates the chips', (t) async {
      final wc = await typedWallet();
      addTearDown(wc.dispose);
      await openAdd(t, wc);
      await t.enterText(k('expenseNote'), 'Lun');
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(k('payeeOption:0'), findsOneWidget);
      expect(find.descendant(of: k('payeeOptions'), matching: find.text('Lunch with Ana')), findsOneWidget);
      // Each name once, even with two payments.
      expect(find.descendant(of: k('payeeOptions'), matching: find.text('Lunch with Ana')), findsOneWidget);
      await t.tap(find.descendant(of: k('payeeOptions'), matching: find.text('Lunch with Ana')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(t.widget<TextField>(k('expenseNote')).controller!.text, 'Lunch with Ana');
      expect(k('suggestCat:Eating out'), findsOneWidget);
      expect(t.widget<ChoiceChip>(k('cat:Groceries')).selected, isTrue, reason: 'still the sheet\'s own tag');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('fits 320 dp at text scale 2.0', (t) async {
      final wc = await typedWallet();
      addTearDown(wc.dispose);
      await openAdd(t, wc, size: const Size(320, 640), textScale: 2);
      await typeNote(t, 'lunch');
      expect(k('suggestCat:Eating out'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.ensureVisible(k('addExpenseSave'));
      await t.pump();
      expect(t.takeException(), isNull);
      await settle(t);
    }, timeout: _timeout);

    test('suggestCategoriesFor is cached per data version and returns the picker\'s tags only', () async {
      final wc = await typedWallet();
      addTearDown(wc.dispose);
      final a = wc.suggestCategoriesFor('lunch');
      expect(identical(a, wc.suggestCategoriesFor('lunch')), isTrue);
      expect(a, ['Eating out', 'Shopping']);
      expect(wc.suggestCategoriesFor('  '), isEmpty);
      expect(wc.payeesFor('lun'), contains('Lunch with Ana'));
      expect(wc.payeesFor(''), isEmpty);
    });
  });

  group('Q6: rule suggestions', () {
    const konzum = 'konzum_zagreb';

    /// Three KONZUM rows (Groceries by the built-in rules); the owner put the first [chosen] of them in Eating out by hand.
    WalletController konzumWallet({int chosen = 2}) {
      final wc = emptyWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-08', -1200, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
      ]));
      final rows = wc.repo.transactions()..sort((a, b) => a.date.compareTo(b.date));
      for (final r in rows.take(chosen)) {
        wc.repo.setCategory(r.id, 'Eating out');
      }
      wc.reload();
      return wc;
    }

    Future<void> openRow(WidgetTester t, WalletController wc, {bool always = false, String pick = 'Eating out'}) async {
      final row = wc.wholeTxs.firstWhere((c) => c.tx.date == '2026-10-08');
      await pumpApp(
          t,
          Builder(
              builder: (ctx) => Scaffold(
                    body: Center(
                        child: ElevatedButton(
                            onPressed: () async {
                              final r = await showSheet<String>(ctx, TxSheet(wc: wc, t: row));
                              if (ctx.mounted) txSheetToast(ctx, wc, r);
                            },
                            child: const Text('open'))),
                  )));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await tapKey(t, 'txCategory');
      await t.tap(k('pick:$pick').last);
      await t.pumpAndSettle();
      if (!always) {
        await t.ensureVisible(find.byType(SwitchListTile));
        await t.tap(find.byType(SwitchListTile));
        await t.pump();
      }
      await t.tap(find.widgetWithText(FilledButton, 'Save'));
      await t.pumpAndSettle();
    }

    testWidgets('the third hand-set row of a payee offers a rule; Make rule makes it, Undo takes it back', (t) async {
      final wc = konzumWallet();
      addTearDown(wc.dispose);
      await openRow(t, wc);
      expect(find.textContaining('Always put'), findsOneWidget);
      expect(find.textContaining('Eating out?'), findsOneWidget);
      expect(wc.categorizer.merchantRules, isEmpty, reason: 'only a tap makes it');
      await t.tap(k('toastAction'));
      await t.pumpAndSettle();
      expect(wc.categorizer.merchantRules[konzum], 'Eating out');
      expect(wc.repo.transaction(wc.wholeTxs.firstWhere((c) => c.tx.date == '2026-10-08').tx.id)!.category, isNull,
          reason: 'the existing always path clears the row\'s own tag');
      expect(find.text('Rule made'), findsOneWidget);
      await t.tap(k('toastUndo'));
      await t.pumpAndSettle();
      expect(wc.categorizer.merchantRules, isEmpty);
      final third = wc.repo.transactions().firstWhere((r) => r.date == '2026-10-08');
      expect(third.category, 'Eating out', reason: 'Undo gives the row its own tag back');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('no offer when fewer than three of the payee agree', (t) async {
      final two = konzumWallet(chosen: 1); // the third pick is only the second
      addTearDown(two.dispose);
      await openRow(t, two);
      expect(find.textContaining('Always put'), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('the offer is not left over for a later save', (t) async {
      final wc = konzumWallet();
      addTearDown(wc.dispose);
      await openRow(t, wc);
      expect(find.textContaining('Always put'), findsOneWidget);
      expect(wc.takeRuleOffer(), isNull, reason: 'the toast read it once');
      await settle(t);
    }, timeout: _timeout);

    test('setCategory with "always" makes an offer to nobody', () {
      final wc = konzumWallet();
      addTearDown(wc.dispose);
      final row = wc.repo.transactions().firstWhere((r) => r.date == '2026-10-08');
      wc.setCategory(row, 'Eating out', always: true);
      expect(wc.takeRuleOffer(), isNull);
    });

    testWidgets('Rules › Suggested lists the payee; Make rule makes it with an Undo', (t) async {
      final wc = konzumWallet(chosen: 3);
      addTearDown(wc.dispose);
      await pumpApp(
          t, ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RulesPanel(wc: wc)))));
      expect(k('ruleSuggest:$konzum'), findsOneWidget);
      expect(find.text('Suggested'), findsOneWidget);
      await tapKey(t, 'ruleSuggestMake:$konzum');
      expect(wc.categorizer.merchantRules[konzum], 'Eating out');
      expect(k('ruleSuggest:$konzum'), findsNothing);
      await t.tap(k('toastUndo'));
      await t.pumpAndSettle();
      expect(wc.categorizer.merchantRules, isEmpty);
      expect(k('ruleSuggest:$konzum'), findsOneWidget, reason: 'back in the list');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Dismiss hides it, and it stays hidden after a reload and in a new controller on the same data', (t) async {
      final wc = konzumWallet(chosen: 3);
      addTearDown(wc.dispose);
      await pumpApp(
          t, ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RulesPanel(wc: wc)))));
      await tapKey(t, 'ruleSuggestDismiss:$konzum');
      expect(k('ruleSuggest:$konzum'), findsNothing);
      expect(wc.categorizer.merchantRules, isEmpty, reason: 'dismissing makes no rule');
      wc.reload();
      expect(wc.ruleSuggestionList, isEmpty);
      final again = seamedController(wc.repo, key: VaultKey.generate());
      addTearDown(again.dispose);
      expect(again.ruleSuggestOff, {konzum});
      expect(again.ruleSuggestionList, isEmpty);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('the suggested list fits 320 dp at text scale 2.0', (t) async {
      final wc = konzumWallet(chosen: 3);
      addTearDown(wc.dispose);
      await pumpApp(
          t, ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RulesPanel(wc: wc)))),
          size: const Size(320, 640), textScale: 2);
      expect(k('ruleSuggest:$konzum'), findsOneWidget);
      expect(t.takeException(), isNull);
      await settle(t);
    }, timeout: _timeout);
  });
}
