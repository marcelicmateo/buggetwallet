// Edge cases and failure paths of the bottom sheets (add expense, transaction details, goal): bad input, odd text,
// double taps, cancel, narrow screens and large text. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

class _Opened {
  String? result;
  bool done = false;
}

/// Opens [sheet] the way the screens do (showSheet from a button) and returns what it popped.
Future<_Opened> _open(WidgetTester tester, Widget sheet, {Size size = const Size(400, 900), double textScale = 1}) async {
  final o = _Opened();
  await pumpApp(
      tester,
      Builder(
          builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      o.result = await showSheet<String>(ctx, sheet);
                      o.done = true;
                    },
                    child: const Text('open'),
                  ),
                ),
              )),
      size: size,
      textScale: textScale);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return o;
}

/// Lets the controller's 3 s sync debounce fire so no timer is left pending.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 4));
}

Finder get _primary => find.byWidgetPredicate((w) => w is FilledButton);
Finder _field(String label) => find.widgetWithText(TextField, label);

/// Waits for caret-scroll and sheet animations, scrolls [f] into view and waits again, so the tap lands on it.
Future<void> _ready(WidgetTester tester, Finder f) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

/// The system back gesture / button: closes the top sheet.
Future<void> _dismiss(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await _ready(tester, f);
  await tester.tap(f);
  await tester.pump();
}

const _invalidAmount = 'Enter an amount, like 12.50.';

NormalizedTransaction _bank(String date, int cents, String desc, {String type = 'POS plaćanje'}) => NormalizedTransaction(
    id: transactionId(date, cents, desc, 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: 'EUR',
    bankType: type,
    description: desc);

void main() {
  group('AddExpenseSheet: invalid amounts show one message and save nothing', () {
    for (final input in ['', ' ', '   ', '0', '0.00', '0,00', '-0', '-5', '-0,01', 'abc', '€', '.', ',', '12abc', '1.2.3', '--1']) {
      testWidgets('"$input"', (tester) async {
        final wc = emptyWallet();
        final o = await _open(tester, AddExpenseSheet(wc: wc));
        await tester.enterText(find.byType(TextField).first, input);
        await _tap(tester, _primary);
        await tester.pump();
        expect(find.textContaining(_invalidAmount), findsOneWidget);
        expect(wc.txs, isEmpty);
        expect(o.done, isFalse, reason: 'the sheet stays open');
        // Tapping again does not stack messages.
        await _tap(tester, _primary);
        expect(find.textContaining(_invalidAmount), findsOneWidget);
        expect(wc.txs, isEmpty);
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });
    }
  });

  group('AddExpenseSheet: saving', () {
    testWidgets('decimal comma, default category, trimmed note: one expense with the typed cents', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '12,50');
      await tester.enterText(_field('Note'), '  coffee  ');
      await _tap(tester, _primary);
      await _settle(tester);
      expect(o.result, 'added');
      expect(wc.txs, hasLength(1));
      expect(wc.txs.single.amount, -1250);
      expect(wc.txs.single.category, 'Groceries');
      expect(wc.txs.single.tx.note, 'coffee');
    });

    testWidgets('a whitespace-only note is stored as empty and the row shows the category', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '3');
      await tester.enterText(_field('Note'), '   \n ');
      await _tap(tester, _primary);
      await _settle(tester);
      expect(wc.txs.single.tx.note ?? '', isEmpty);
      expect(merchantName(wc.txs.single.tx), 'Groceries');
    });

    testWidgets('1.234,56 above the impulse limit asks first, then saves 123456 once', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '1.234,56');
      await _tap(tester, _primary);
      expect(wc.txs, isEmpty);
      expect(find.textContaining('wishlist first?'), findsOneWidget);
      expect(o.done, isFalse);
      await _tap(tester, _primary);
      await _settle(tester);
      expect(wc.txs, hasLength(1));
      expect(wc.txs.single.amount, -123456);
      expect(o.result, 'added');
    });

    testWidgets('exactly the impulse limit (50.00) saves at once; 50.01 asks first', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '50.01');
      await _tap(tester, _primary);
      expect(wc.txs, isEmpty);
      expect(find.textContaining('Over €50'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.pump();
      await _tap(tester, _primary);
      await _settle(tester);
      expect(wc.txs.single.amount, -5000);
    });

    testWidgets('the "wishlist first?" warning disappears when the amount is lowered to the limit', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '50.01');
      await _tap(tester, _primary);
      expect(find.textContaining('wishlist first?'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.pump();
      expect(find.textContaining('wishlist first?'), findsNothing);
    });

    testWidgets('an amount beyond 10 billion is refused like any other bad amount', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '10000000001');
      await _tap(tester, _primary);
      expect(find.textContaining(_invalidAmount), findsOneWidget);
      expect(wc.txs, isEmpty);
      await _settle(tester);
    });

    testWidgets('a limit changed by sync (20.00) is respected at the boundary', (tester) async {
      final wc = emptyWallet();
      remoteSetting(wc, 'impulse', 2000);
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '20.01');
      await _tap(tester, _primary);
      expect(wc.txs, isEmpty);
      expect(find.textContaining('Over €20'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '20');
      await _tap(tester, _primary);
      await _settle(tester);
      expect(wc.txs.single.amount, -2000);
    });

    testWidgets('after the warning, an invalid amount shows the message and no warning', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '99');
      await _tap(tester, _primary);
      expect(find.textContaining('wishlist first?'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '');
      await _tap(tester, _primary);
      expect(find.textContaining(_invalidAmount), findsOneWidget);
      expect(find.textContaining('wishlist first?'), findsNothing);
      expect(wc.txs, isEmpty);
      await _settle(tester);
    });

    testWidgets('"Put on wishlist" with a blank note names the wish after the category; no expense is saved', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '120');
      await tester.enterText(_field('Note'), '   ');
      await _tap(tester, _primary);
      await _tap(tester, find.text('Put on wishlist'));
      await _settle(tester);
      expect(o.result, 'wish');
      expect(wc.txs, isEmpty);
      expect(wc.wish, hasLength(1));
      expect(wc.wish.single.name, 'Groceries');
      expect(wc.wish.single.price, 12000);
    });

    testWidgets('a chosen category and an emoji / right-to-left / long note are saved unchanged', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      const note = '🍕 Pizza ‏مطعم ‏שלום 日本語 é';
      await tester.enterText(find.byType(TextField).first, '8');
      await tester.enterText(_field('Note'), note);
      await _tap(tester, find.widgetWithText(ChoiceChip, 'Eating out'));
      await _tap(tester, _primary);
      await _settle(tester);
      expect(wc.txs.single.category, 'Eating out');
      expect(wc.txs.single.tx.note, note);
    });

    testWidgets('a 5,000-character note is saved whole and the app keeps working', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      final note = List.filled(5000, 'x').join();
      await tester.enterText(find.byType(TextField).first, '8');
      await tester.enterText(_field('Note'), note);
      await _tap(tester, _primary);
      await _settle(tester);
      expect(wc.txs.single.tx.note, note);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Bank fees category is not offered for hand-added expenses', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      expect(find.widgetWithText(ChoiceChip, 'Bank fees'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Groceries'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Salary'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Internal transfer'), findsNothing);
    });

    testWidgets('a double tap on Add expense saves once', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '7.25');
      await _ready(tester, _primary);
      await tester.tap(_primary);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(_primary, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(_primary, warnIfMissed: false);
      await _settle(tester);
      expect(wc.txs, hasLength(1));
      expect(wc.txs.single.amount, -725);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a double tap on the warning step saves once', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '75');
      await _tap(tester, _primary); // warning
      await _ready(tester, _primary);
      await tester.tap(_primary);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(_primary, warnIfMissed: false);
      await _settle(tester);
      expect(wc.txs, hasLength(1));
      expect(wc.txs.single.amount, -7500);
    });

    testWidgets('a double tap on Put on wishlist adds one wish', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '75');
      await _tap(tester, _primary);
      final b = find.text('Put on wishlist');
      await _ready(tester, b);
      await tester.tap(b);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(b, warnIfMissed: false);
      await _settle(tester);
      expect(wc.wish, hasLength(1));
      expect(wc.txs, isEmpty);
    });

    testWidgets('closing by tapping outside discards what was typed', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '12');
      await tester.enterText(_field('Note'), 'draft');
      await _dismiss(tester);
      expect(o.done, isTrue);
      expect(o.result, isNull);
      expect(wc.txs, isEmpty);
      expect(wc.wish, isEmpty);
      // Opening again starts empty.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, '', reason: 'a reopened sheet starts empty');
      expect(tester.widget<TextField>(_field('Note')).controller!.text, '');
      await _settle(tester);
    });

    testWidgets('closing while the warning is showing saves nothing', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, AddExpenseSheet(wc: wc));
      await tester.enterText(find.byType(TextField).first, '500');
      await _tap(tester, _primary);
      await _dismiss(tester);
      expect(o.done, isTrue);
      expect(o.result, isNull);
      expect(wc.txs, isEmpty);
      expect(wc.wish, isEmpty);
    });
  });

  group('AddExpenseSheet: prefilled from the wishlist', () {
    testWidgets('amount and note are filled; no warning even above the limit; saved amount is the wish price', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, AddExpenseSheet(wc: wc, amount: 123456, note: 'Synthetic lamp', skipImpulse: true));
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, '1234.56');
      expect(tester.widget<TextField>(_field('Note')).controller!.text, 'Synthetic lamp');
      await _tap(tester, _primary);
      await _settle(tester);
      expect(o.result, 'added');
      expect(wc.txs.single.amount, -123456);
      expect(wc.txs.single.tx.note, 'Synthetic lamp');
    });

    for (final (cents, text) in [(1, '0.01'), (5, '0.05'), (99, '0.99'), (100, '1.00'), (1999, '19.99'), (10000000, '100000.00')]) {
      testWidgets('prefill $cents cents shows $text and saves $cents again', (tester) async {
        final wc = emptyWallet();
        await _open(tester, AddExpenseSheet(wc: wc, amount: cents, skipImpulse: true));
        expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, text);
        await _tap(tester, _primary);
        await _settle(tester);
        expect(wc.txs.single.amount, -cents);
      });
    }

    testWidgets('a zero-price wish prefills 0.00 and is refused like any zero amount', (tester) async {
      final wc = emptyWallet();
      await _open(tester, AddExpenseSheet(wc: wc, amount: 0, skipImpulse: true));
      await _tap(tester, _primary);
      expect(find.textContaining(_invalidAmount), findsOneWidget);
      expect(wc.txs, isEmpty);
      await _settle(tester);
    });
  });

  group('AddExpenseSheet: narrow and large text', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('fits 320 dp at text scale $scale, with an error, and with the warning', (tester) async {
        final wc = emptyWallet();
        await _open(tester, AddExpenseSheet(wc: wc), size: const Size(320, 640), textScale: scale);
        await tester.enterText(_field('Note'), 'A long synthetic note ' * 20);
        await _tap(tester, _primary);
        expect(find.textContaining(_invalidAmount), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, '99999');
        await _tap(tester, _primary);
        expect(find.textContaining('wishlist first?'), findsOneWidget);
        await tester.ensureVisible(find.text('Put on wishlist'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });
    }
  });

  group('TxSheet', () {
    WalletController two() {
      final wc = emptyWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        _bank('2026-10-01', -2500, 'PBZ POS PBZ7TESTSHOPA ZAGREB'),
        _bank('2026-10-03', -1200, 'PBZ POS PBZ7TESTSHOPA ZAGREB'),
        _bank('2026-10-04', -900, 'PBZ POS PBZ7OTHERPLACE ZAGREB'),
      ]));
      wc.reload();
      return wc;
    }

    CategorizedTx find2(WalletController wc, int cents) => wc.txs.firstWhere((t) => t.amount == cents);

    Future<void> pick(WidgetTester tester, String category) async {
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(category).last);
      await tester.pumpAndSettle();
    }

    testWidgets('"Always" on (default): the merchant rule recategorizes the other row of the same shop, not other shops', (tester) async {
      final wc = two();
      final o = await _open(tester, TxSheet(wc: wc, t: find2(wc, -2500)));
      await pick(tester, 'Sport & fitness');
      await _tap(tester, find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);
      expect(o.result, 'saved');
      expect(find2(wc, -2500).category, 'Sport & fitness');
      expect(find2(wc, -1200).category, 'Sport & fitness');
      expect(find2(wc, -900).category, isNot('Sport & fitness'));
    });

    testWidgets('"Always" switched off changes only this row', (tester) async {
      final wc = two();
      await _open(tester, TxSheet(wc: wc, t: find2(wc, -2500)));
      await _tap(tester, find.byType(Switch));
      await pick(tester, 'Sport & fitness');
      await _tap(tester, find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);
      expect(find2(wc, -2500).category, 'Sport & fitness');
      expect(find2(wc, -1200).category, isNot('Sport & fitness'));
    });

    testWidgets('Save without choosing anything keeps the category and writes no wrong value', (tester) async {
      final wc = two();
      final before = find2(wc, -2500).category;
      await _open(tester, TxSheet(wc: wc, t: find2(wc, -2500)));
      await _tap(tester, find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);
      expect(find2(wc, -2500).category, before);
      expect(find2(wc, -2500).amount, -2500);
    });

    testWidgets('a bank row has no Delete button; an income row shows a plus sign', (tester) async {
      final wc = emptyWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('2026-10-10', 150000, 'Synthetic payer', type: 'Uplata')]));
      wc.reload();
      await _open(tester, TxSheet(wc: wc, t: wc.txs.single));
      expect(find.text('Delete'), findsNothing);
      expect(find.text('+€1,500.00'), findsOneWidget);
      expect(find.textContaining('Saturday, 10 October 2026'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('a row with an impossible date (e.g. synced from elsewhere) opens and shows the date as stored', (tester) async {
      final wc = emptyWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('2026-02-30', -700, 'PBZ POS PBZ7TESTSHOPA ZAGREB')]));
      wc.reload();
      await _open(tester, TxSheet(wc: wc, t: wc.txs.single));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('2026-02-30'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('the list row of a transaction with an impossible date shows the date as stored', (tester) async {
      final wc = emptyWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('2026-13-01', -700, 'PBZ POS PBZ7TESTSHOPA ZAGREB')]));
      wc.reload();
      await pumpApp(tester, Scaffold(body: TxTile(t: wc.txs.single, currency: 'EUR')));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('2026-13-01'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('a zero-amount row and an empty description do not crash', (tester) async {
      final wc = emptyWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('2026-10-10', 0, '', type: '')]));
      wc.reload();
      expect(wc.txs, hasLength(1));
      await _open(tester, TxSheet(wc: wc, t: wc.txs.single));
      expect(find.text('(no description)'), findsWidgets);
      expect(find.text('€0.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _settle(tester);
    });

    testWidgets('a hand-added expense: no "always" switch; Delete removes it once, even on a double tap', (tester) async {
      final wc = emptyWallet();
      wc.addExpense(amount: 450, category: 'Eating out', note: 'Lunch', date: wc.today());
      final t = wc.txs.single;
      final o = await _open(tester, TxSheet(wc: wc, t: t));
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Added by you'), findsNothing, reason: 'it is inside a longer line');
      expect(find.textContaining('Added by you'), findsOneWidget);
      final del = find.text('Delete');
      await _ready(tester, del);
      await tester.tap(del);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(del, warnIfMissed: false);
      await _settle(tester);
      expect(o.result, 'deleted');
      expect(wc.txs, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('changing a hand-added expense category does not create a merchant rule', (tester) async {
      final wc = emptyWallet();
      wc.addExpense(amount: 450, category: 'Eating out', note: 'Lunch', date: wc.today());
      wc.addExpense(amount: 650, category: 'Eating out', note: 'Lunch', date: wc.today());
      final target = wc.txs.firstWhere((t) => t.amount == -450);
      await _open(tester, TxSheet(wc: wc, t: target));
      await pick(tester, 'Shopping');
      await _tap(tester, find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);
      expect(wc.txs.firstWhere((t) => t.amount == -450).category, 'Shopping');
      expect(wc.txs.firstWhere((t) => t.amount == -650).category, 'Eating out');
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('a hand-added expense sheet (Save + Delete) fits 320 dp at text scale $scale', (tester) async {
        final wc = emptyWallet();
        wc.addExpense(amount: 12345678, category: 'Sport & fitness', note: 'Synthetic note ' * 20, date: '2028-02-29');
        await _open(tester, TxSheet(wc: wc, t: wc.txs.single), size: const Size(320, 640), textScale: scale);
        await tester.ensureVisible(find.text('Delete'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('a very long description and merchant fit 320 dp at text scale $scale', (tester) async {
        final wc = emptyWallet();
        final desc = 'PBZ POS PBZ7${'VERYLONGSYNTHETICSHOPNAME ' * 12}ZAGREB 🍕 ‏مطعم';
        wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('2026-02-28', -12345678, desc)]));
        wc.reload();
        await _open(tester, TxSheet(wc: wc, t: wc.txs.single), size: const Size(320, 640), textScale: scale);
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });
    }
  });

  group('GoalSheet', () {
    Future<void> save(WidgetTester tester) => _tap(tester, find.widgetWithText(FilledButton, 'Save goal'));

    testWidgets('a new goal starts with an empty name and target and 50 a month', (tester) async {
      final wc = emptyWallet();
      await _open(tester, GoalSheet(wc: wc));
      expect(find.text('New goal'), findsOneWidget);
      expect(tester.widget<TextField>(_field('Name')).controller!.text, '');
      expect(tester.widget<TextField>(_field('Target')).controller!.text, '');
      expect(tester.widget<TextField>(_field('Each month')).controller!.text, '50');
      expect(tester.widget<TextField>(_field('Put aside so far')).controller!.text, '');
      expect(_field('Add money now'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      await _settle(tester);
    });

    testWidgets('typed amounts in either format are saved as the typed cents', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, GoalSheet(wc: wc));
      await tester.enterText(_field('Name'), '  Trip  ');
      await tester.enterText(_field('Target'), '1.234,56');
      await tester.enterText(_field('Each month'), '25,5');
      await tester.enterText(_field('Put aside so far'), '10');
      await save(tester);
      await _settle(tester);
      expect(o.result, 'saved');
      final g = wc.goals.single;
      expect((g.name, g.target, g.monthly, g.saved), ('Trip', 123456, 2550, 1000));
    });

    testWidgets('a whitespace-only name is saved as "Goal"', (tester) async {
      final wc = emptyWallet();
      await _open(tester, GoalSheet(wc: wc));
      await tester.enterText(_field('Name'), '   ');
      await tester.enterText(_field('Target'), '100');
      await save(tester);
      await _settle(tester);
      expect(wc.goals.single.name, 'Goal');
    });

    testWidgets('emoji, right-to-left and 300-character names are kept as typed', (tester) async {
      final wc = emptyWallet();
      await _open(tester, GoalSheet(wc: wc));
      final name = '🏖️ חופשה ‏رحلة ${'x' * 300}';
      await tester.enterText(_field('Name'), name);
      await tester.enterText(_field('Target'), '100');
      await save(tester);
      await _settle(tester);
      expect(wc.goals.single.name, name);
    });

    testWidgets('a double tap on Save goal creates one goal', (tester) async {
      final wc = emptyWallet();
      await _open(tester, GoalSheet(wc: wc));
      await tester.enterText(_field('Name'), 'Trip');
      await tester.enterText(_field('Target'), '100');
      final b = find.widgetWithText(FilledButton, 'Save goal');
      await _ready(tester, b);
      await tester.tap(b);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(b, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(b, warnIfMissed: false);
      await _settle(tester);
      expect(wc.goals, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancel (tap outside) saves nothing', (tester) async {
      final wc = emptyWallet();
      final o = await _open(tester, GoalSheet(wc: wc));
      await tester.enterText(_field('Name'), 'Trip');
      await tester.enterText(_field('Target'), '100');
      await _dismiss(tester);
      expect(o.done, isTrue);
      expect(o.result, isNull);
      expect(wc.goals, isEmpty);
    });

    testWidgets('a goal opened from the Goals tab by name and target is prefilled', (tester) async {
      final wc = emptyWallet();
      await _open(tester, GoalSheet(wc: wc, name: 'Laptop', target: 99999));
      expect(tester.widget<TextField>(_field('Name')).controller!.text, 'Laptop');
      expect(tester.widget<TextField>(_field('Target')).controller!.text, '999.99');
      await _settle(tester);
    });

    group('editing', () {
      Goal makeGoal(WalletController wc, {int target = 100000, int saved = 5000, int monthly = 2000}) {
        wc.repo.saveGoal(name: 'Trip', target: target, saved: saved, monthly: monthly, sort: 3);
        wc.reload();
        return wc.goals.single;
      }

      testWidgets('fields show whole units without decimals and cents with two', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc, target: 100000, saved: 1005, monthly: 1)));
        expect(find.text('Edit goal'), findsOneWidget);
        expect(tester.widget<TextField>(_field('Target')).controller!.text, '1000');
        expect(tester.widget<TextField>(_field('Put aside so far')).controller!.text, '10.05');
        expect(tester.widget<TextField>(_field('Each month')).controller!.text, '0.01');
        await _settle(tester);
      });

      testWidgets('Save with nothing changed keeps every value, the id and the order', (tester) async {
        final wc = emptyWallet();
        final g0 = makeGoal(wc, target: 123457, saved: 1999, monthly: 2501);
        await _open(tester, GoalSheet(wc: wc, goal: g0));
        await save(tester);
        await _settle(tester);
        final g = wc.goals.single;
        expect((g.id, g.name, g.target, g.saved, g.monthly, g.sort), (g0.id, 'Trip', 123457, 1999, 2501, 3));
      });

      testWidgets('an old goal saved without a target can be saved with Target left empty', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc, target: 0)));
        expect(tester.widget<TextField>(_field('Target')).controller!.text, '');
        await tester.enterText(_field('Add money now'), '50');
        await save(tester);
        await _settle(tester);
        expect((wc.goals.single.target, wc.goals.single.saved), (0, 5000 + 5000));
      });

      testWidgets('"Add money now" is added to what is put aside', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc)));
        await tester.enterText(_field('Add money now'), '10,50');
        await save(tester);
        await _settle(tester);
        expect(wc.goals.single.saved, 5000 + 1050);
      });

      testWidgets('Add money now and a changed "so far" combine without double counting', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc)));
        await tester.enterText(_field('Put aside so far'), '100');
        await tester.enterText(_field('Add money now'), '1');
        await save(tester);
        await _settle(tester);
        expect(wc.goals.single.saved, 10100);
      });

      testWidgets('Delete removes the goal once, even on a double tap', (tester) async {
        final wc = emptyWallet();
        final o = await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc)));
        final d = find.text('Delete');
        await _ready(tester, d);
        await tester.tap(d);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(d, warnIfMissed: false);
        await _settle(tester);
        expect(o.result, 'deleted');
        expect(wc.goals, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a goal deleted on another device while the sheet is open: Save does not crash', (tester) async {
        final wc = emptyWallet();
        final g = makeGoal(wc);
        await _open(tester, GoalSheet(wc: wc, goal: g));
        wc.repo.deleteGoal(g.id);
        wc.reload();
        await tester.enterText(_field('Name'), 'Renamed');
        await save(tester);
        await _settle(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a garbled "Put aside so far" does not wipe the saved money', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc)));
        await tester.enterText(_field('Put aside so far'), '1O0');
        await save(tester);
        await _settle(tester);
        expect(wc.goals.single.saved, isNot(0));
        expect(find.textContaining('Put aside so far: enter an amount, like 500.'), findsOneWidget);
      });

      testWidgets('an amount beyond 10 billion is refused, and typing clears the message', (tester) async {
        final wc = emptyWallet();
        final o = await _open(tester, GoalSheet(wc: wc, goal: makeGoal(wc)));
        await tester.enterText(_field('Target'), '10000000001');
        await save(tester);
        expect(wc.goals.single.target, 100000);
        expect(find.textContaining('Target: enter an amount'), findsOneWidget);
        expect(o.done, isFalse);
        await tester.enterText(_field('Target'), '10000000000');
        await tester.pump();
        expect(find.textContaining('Target: enter an amount'), findsNothing);
        await tester.enterText(_field('Put aside so far'), '10000000000');
        await tester.enterText(_field('Add money now'), '1');
        await save(tester);
        expect(find.textContaining('Put aside so far: enter an amount'), findsOneWidget);
        expect(wc.goals.single.saved, 5000);
        await _settle(tester);
      });

      testWidgets('a garbled or empty target is refused, not saved as 0', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc));
        await tester.enterText(_field('Name'), 'Trip');
        await tester.enterText(_field('Target'), 'abc');
        await save(tester);
        await tester.pumpAndSettle();
        expect(wc.goals, isEmpty);
        expect(find.textContaining('Target: enter an amount, like 500.'), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
      });

      testWidgets('a negative target is refused, not saved as 0', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc));
        await tester.enterText(_field('Target'), '-100');
        await save(tester);
        await tester.pumpAndSettle();
        expect(wc.goals, isEmpty);
        await tester.pump(const Duration(seconds: 4));
      });
    });

    group('the months hint', () {
      testWidgets('rounds months up and mentions the monthly amount', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc));
        await tester.enterText(_field('Target'), '1001');
        await tester.pump();
        expect(find.textContaining('At €50 a month you reach it in 21 months'), findsOneWidget);
        await tester.enterText(_field('Target'), '1000');
        await tester.pump();
        expect(find.textContaining('in 20 months'), findsOneWidget);
        await tester.enterText(_field('Put aside so far'), '950');
        await tester.pump();
        expect(find.textContaining('in 1 months'), findsOneWidget, reason: 'documents current wording');
        await _settle(tester);
      });

      testWidgets('no hint when monthly is 0 or empty, when the target is reached, or when the target is empty', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc));
        await tester.enterText(_field('Target'), '500');
        await tester.enterText(_field('Each month'), '0');
        await tester.pump();
        expect(find.textContaining('you reach it'), findsNothing);
        await tester.enterText(_field('Each month'), '');
        await tester.pump();
        expect(find.textContaining('you reach it'), findsNothing);
        await tester.enterText(_field('Each month'), '10');
        await tester.enterText(_field('Put aside so far'), '500');
        await tester.pump();
        expect(find.textContaining('you reach it'), findsNothing, reason: 'saved equals target');
        await tester.enterText(_field('Put aside so far'), '900');
        await tester.pump();
        expect(find.textContaining('you reach it'), findsNothing, reason: 'saved above target');
        await tester.enterText(_field('Target'), '');
        await tester.pump();
        expect(find.textContaining('you reach it'), findsNothing);
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });

      testWidgets('Infinity or 1e999 typed in a goal field must not throw (parseMoney)', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc));
        for (final v in ['abc', '-5', '1e999', 'Infinity', '0,005', '99999999999999999999']) {
          await tester.enterText(_field('Target'), v);
          await tester.pump();
        }
        expect(find.textContaining(RegExp('NaN|Infinity|null')), findsNothing);
        await _settle(tester);
      });
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('a new goal sheet with a long name fits 320 dp at text scale $scale', (tester) async {
        final wc = emptyWallet();
        await _open(tester, GoalSheet(wc: wc, name: 'A long synthetic goal name ' * 6, target: 98765432199),
            size: const Size(320, 640), textScale: scale);
        await tester.enterText(_field('Each month'), '99999999');
        await tester.pump();
        await tester.ensureVisible(find.text('Save goal'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });
    }

    testWidgets('an edit goal sheet fits 320 dp at text scale 1.0', (tester) async {
      final wc = emptyWallet();
      wc.repo.saveGoal(name: 'A long synthetic goal name ' * 6, target: 123456789, saved: 1, monthly: 99999, sort: 1);
      wc.reload();
      await _open(tester, GoalSheet(wc: wc, goal: wc.goals.single), size: const Size(320, 640));
      await tester.enterText(_field('Target'), '987654321.99');
      await tester.pump();
      await tester.ensureVisible(find.text('Delete'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _settle(tester);
    });

    testWidgets('an edit goal sheet fits 320 dp at text scale 2.0', (tester) async {
      final wc = emptyWallet();
      wc.repo.saveGoal(name: 'Trip', target: 123456, saved: 1, monthly: 5000, sort: 1);
      wc.reload();
      await _open(tester, GoalSheet(wc: wc, goal: wc.goals.single), size: const Size(320, 640), textScale: 2);
      await tester.ensureVisible(find.text('Delete'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _settle(tester);
    });
  });
}
