// Stage I, I2 (wish naming + toast Open), I4 (toasts: 2.5 s, cleared on navigation, Undo) and I5 (forms). Spec:
// scratchpad I-spec.md "App, part B". SYNTHETIC data, fixed clocks.
//
// Behaviour not built on v2 carries a FIXED skip string `BUG: I<n> - ...`; the lead lifts them at merge.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

// BUG: I2 - wishName field, wish named from the note, toast Open (testWidgets takes a bool skip; the lead lifts it at merge)
const _skipWish = false;
// BUG: I4 - toast 2.5 s, cleared on navigation, toastUndo (testWidgets takes a bool skip; the lead lifts it at merge)
const _skipToast = false;
// BUG: I5 - forms: sheetClose, last-used category, filled expected action (testWidgets takes a bool skip; the lead lifts it at merge)
const _skipForms = false;
// BUG: I5 - the Add expense sheet still shows its muted explainer below the CTA (spec: above the CTA or behind an info icon)
const _skipExplainer = true;

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 4));
}

Future<void> _openSheet(WidgetTester tester, Widget sheet, {Size size = const Size(400, 1400)}) async {
  await pumpApp(
      tester,
      Builder(
          builder: (ctx) =>
              Scaffold(body: Center(child: ElevatedButton(onPressed: () => showSheet<String>(ctx, sheet), child: const Text('open'))))),
      size: size);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Types an amount above the impulse limit so the sheet offers the wishlist.
Future<void> _toWishPanel(WidgetTester tester, {String note = ''}) async {
  await tester.enterText(find.byType(TextField).first, '1.234,56');
  // I5: a new expense has no category until one is picked (unless a last-used one exists).
  if (find.byWidgetPredicate((w) => w is ChoiceChip && w.selected).evaluate().isEmpty) {
    await tester.tap(find.widgetWithText(ChoiceChip, 'Groceries'));
    await tester.pump();
  }
  if (note.isNotEmpty) await tester.enterText(find.widgetWithText(TextField, 'Note'), note);
  await tester.tap(find.byType(FilledButton).last);
  await tester.pumpAndSettle();
}

/// A wallet with one hand-added expense (the only kind with a Delete button) and a clean Today.
WalletController _manualWallet() {
  final wc = demoWallet();
  wc.snoozeKeyBackup();
  wc.repo.addTransaction(date: wc.today(), amount: 450, category: 'Eating out', note: 'Synthetic tea room');
  wc.reload();
  return wc;
}

Future<void> _pumpHome(WidgetTester tester, WalletController wc) => pumpFull(tester, wc, 1.0, size: const Size(400, 2400));

void main() {
  group('I2: wish naming', () {
    testWidgets('with a note the wish takes the note, never the category', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      await _toWishPanel(tester, note: 'Synthetic headphones');
      expect(find.byKey(const ValueKey('wishName')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('putOnWishlist')));
      await _settle(tester);
      expect(wc.wish.map((w) => w.name), ['Synthetic headphones']);
      expect(wc.wish.single.price, 123456);
    }, skip: _skipWish);

    testWidgets('without a note the sheet asks for a name; the CTA stays disabled until it is filled', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      await _toWishPanel(tester);
      expect(find.byKey(const ValueKey('wishName')), findsOneWidget);
      OutlinedButton cta() => tester.widget<OutlinedButton>(find.byKey(const ValueKey('putOnWishlist')));
      expect(cta().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('wishName')), '   ');
      await tester.pump();
      expect(cta().onPressed, isNull, reason: 'blank is not a name');
      await tester.enterText(find.byKey(const ValueKey('wishName')), 'Desk lamp');
      await tester.pump();
      expect(cta().onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('putOnWishlist')));
      await _settle(tester);
      expect(wc.wish.map((w) => w.name), ['Desk lamp']);
    }, skip: _skipWish);

    testWidgets('the wish is never named after the category', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      await _toWishPanel(tester);
      await tester.enterText(find.byKey(const ValueKey('wishName')), 'Desk lamp');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('putOnWishlist')));
      await _settle(tester);
      expect(wc.wish.where((w) => w.name == 'Groceries'), isEmpty);
    }, skip: _skipWish);

    testWidgets('the "On the wishlist" toast has an Open action that opens the Wishlist tab on that item', (tester) async {
      final wc = demoWallet();
      wc.snoozeKeyBackup();
      await _pumpHome(tester, wc);
      await tester.tap(find.byKey(const ValueKey('addExpense')));
      await tester.pumpAndSettle();
      await _toWishPanel(tester, note: 'Synthetic bookshelf');
      await tester.tap(find.byKey(const ValueKey('putOnWishlist')));
      await tester.pumpAndSettle();
      expect(find.textContaining('On the wishlist'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toastAction')));
      await tester.pumpAndSettle();
      expect(find.byType(WishlistScreen), findsOneWidget);
      expect(find.text('Synthetic bookshelf'), findsOneWidget);
      await tester.pump(const Duration(minutes: 6));
    }, skip: _skipWish);
  });

  group('I4: toasts', () {
    Future<void> showToast(WidgetTester tester, {String? action}) async {
      await pumpApp(
          tester,
          Builder(
              builder: (ctx) => Scaffold(
                  body: Center(
                      child: ElevatedButton(
                          onPressed: () => toast(ctx, 'Saved', actionLabel: action, onAction: action == null ? null : () {}),
                          child: const Text('go'))))));
      await tester.tap(find.text('go'));
      await tester.pump();
    }

    testWidgets('lasts 2.5 s, with or without an action', (tester) async {
      await showToast(tester);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, const Duration(milliseconds: 2500));
      await tester.pumpWidget(const SizedBox.shrink());
      await showToast(tester, action: 'Undo');
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, const Duration(milliseconds: 2500));
    }, skip: _skipToast);

    testWidgets('it is gone after 2.5 s and still there at 2 s', (tester) async {
      await showToast(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Saved'), findsOneWidget);
      // the dismiss timer only starts once a frame has seen the entrance animation finish, so give it a few extra seconds
      // (the duration itself is pinned to 2500 ms in the test above); the toast must be gone by 5 s.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsNothing);
    }, skip: _skipToast);

    testWidgets('a tab change clears it', (tester) async {
      final wc = _manualWallet();
      await _pumpHome(tester, wc);
      await tester.tap(find.text('Synthetic tea room').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('txDelete')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget, reason: 'the toast is up after the delete');
      await tapTab(tester, 'Goals');
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(minutes: 6));
    }, skip: _skipToast);

    testWidgets('opening a sheet (a route push) clears it', (tester) async {
      final wc = _manualWallet();
      await _pumpHome(tester, wc);
      await tester.tap(find.text('Synthetic tea room').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('txDelete')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('addExpense')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(minutes: 6));
    }, skip: _skipToast);

    testWidgets('Undo after deleting a hand-added expense restores it and hides the toast', (tester) async {
      final wc = _manualWallet();
      await _pumpHome(tester, wc);
      expect(wc.txs.where((t) => t.tx.note == 'Synthetic tea room'), hasLength(1));
      await tester.tap(find.text('Synthetic tea room').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('txDelete')));
      await tester.pumpAndSettle();
      expect(wc.txs.where((t) => t.tx.note == 'Synthetic tea room'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('toastUndo')));
      await tester.pumpAndSettle();
      expect(wc.txs.where((t) => t.tx.note == 'Synthetic tea room'), hasLength(1));
      expect(find.byKey(const ValueKey('toastUndo')), findsNothing);
      await tester.pump(const Duration(minutes: 6));
    }, skip: _skipToast);

    testWidgets('Undo after deleting a goal brings the goal back with its saved amount', (tester) async {
      final wc = demoWallet();
      wc.snoozeKeyBackup();
      final id = wc.goals.first.id;
      wc.repo.addGoalContribution(id, 5000);
      wc.reload();
      final name = wc.goals.first.name;
      final saved = wc.goals.first.saved;
      await _pumpHome(tester, wc);
      await tapTab(tester, 'Goals');
      await tester.tap(find.text(name).first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('goalDelete')));
      await tester.tap(find.byKey(const ValueKey('goalDelete')));
      await tester.pumpAndSettle();
      expect(wc.goals.where((g) => g.id == id), isEmpty);
      await tester.tap(find.byKey(const ValueKey('toastUndo')));
      await tester.pumpAndSettle();
      expect(wc.goals.singleWhere((g) => g.id == id).saved, saved);
      await tester.pump(const Duration(minutes: 6));
    }, skip: _skipToast);

    testWidgets('control: toast() today shows a SnackBar with the message and an action label', (tester) async {
      await showToast(tester, action: 'Undo');
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });
  });

  group('I5: forms', () {
    testWidgets('a phone sheet has an X close button (sheetClose) that closes it', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      expect(find.byType(AddExpenseSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sheetClose')));
      await tester.pumpAndSettle();
      expect(find.byType(AddExpenseSheet), findsNothing);
    }, skip: _skipForms);

    testWidgets('a wide window dialog needs no extra X (sheetClose appears once at most)', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc), size: const Size(1280, 800));
      expect(find.byKey(const ValueKey('sheetClose')).evaluate().length, lessThanOrEqualTo(1));
    }, skip: _skipForms);

    testWidgets('a new expense has no category until one is picked or one was used last; the CTA is disabled', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '5');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('addExpenseSave'))).onPressed, isNull);
      expect(tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).where((c) => c.selected), isEmpty);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Eating out'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('addExpenseSave'))).onPressed, isNotNull);
    }, skip: _skipForms);

    testWidgets('the default category is the last one used', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '5');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Eating out'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('addExpenseSave')));
      await _settle(tester);
      expect(wc.txs.single.category, 'Eating out');
      await tester.pumpWidget(const SizedBox.shrink());
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      final selected = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).where((c) => c.selected).toList();
      expect(selected, hasLength(1));
      expect((selected.single.label as Text).data, 'Eating out');
      // the choice survives a restart of the controller (it is a device-local convenience)
      await tester.pumpWidget(const SizedBox.shrink());
      final again = WalletController.forTest(wc.repo, key: wc.key);
      await _openSheet(tester, AddExpenseSheet(wc: again));
      expect(tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).where((c) => c.selected), hasLength(1));
    }, skip: _skipForms);

    testWidgets('the sheet\'s explainer is above the CTA, or behind an info icon', (tester) async {
      final wc = emptyWallet();
      await _openSheet(tester, AddExpenseSheet(wc: wc));
      final cta = tester.getTopLeft(find.byKey(const ValueKey('addExpenseSave'))).dy;
      final muted = find.byType(Muted);
      for (final m in muted.evaluate()) {
        final y = tester.getTopLeft(find.byElementPredicate((e) => e == m)).dy;
        // an explainer is allowed below the CTA only when it sits behind an info icon (not shown as text)
        expect(y, lessThan(cta), reason: 'a muted explainer below the CTA');
      }
    }, skip: _skipExplainer);
  });
}
