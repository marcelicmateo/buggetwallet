// P11: the decimal style (Plan › Look) changes every amount at once, is kept per device, and typing either style saves the same
// cents. SYNTHETIC data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/recurring_sheet.dart' show billRangeShort;
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

void main() {
  tearDown(() => numberStyle = NumberStyle.point);

  // A 1,234.56 expense (shows grouped in Spending) and a salary large enough that the hero has a thousands separator on any
  // day of the period (the hero is money left / days left, so it depends on the real date).
  WalletController wallet() {
    final wc = demoWallet();
    wc.repo.updateSettings({'salary': 9000000, 'rent': 0, 'loan': 0, 'subs': 0});
    wc.reload();
    wc.addExpense(amount: 123456, category: 'Eating out', note: 'Synthetic big one', date: wc.today(), tags: const []);
    return wc;
  }

  Future<void> pickStyle(WidgetTester tester, String label) async {
    final seg = find.byKey(const ValueKey('numberStyle'));
    await tester.scrollUntilVisible(seg, 400, scrollable: find.byType(Scrollable).hitTestable().first);
    await Scrollable.ensureVisible(tester.element(seg), alignment: 0.5);
    await tester.pump();
    await tester.tap(find.descendant(of: seg, matching: find.text(label)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  String hero(WidgetTester tester) => _plain(tester.widget<Text>(find.byKey(const ValueKey('safeToSpend'))));

  /// The same figure in the other style: thousands and decimal marks swapped.
  String swapped(String v) => v.replaceAll(',', '\u0001').replaceAll('.', ',').replaceAll('\u0001', '.');

  testWidgets('Settings › Look switches Today and Budget, and a new controller on the same repo keeps it', (tester) async {
    final wc = wallet();
    await pumpFull(tester, wc, 1.0, size: const Size(400, 900));
    final before = hero(tester);
    expect(before, contains(','), reason: 'hero is grouped in the default style: $before');
    await tapTab(tester, 'Budget');
    expect(find.textContaining('1,234.56'), findsWidgets);

    await tapTab(tester, 'Settings');
    expect(wc.numberStyleName, 'point');
    await pickStyle(tester, '1.234,50');
    expect(wc.numberStyleName, 'comma');
    expect(numberStyle, NumberStyle.comma);
    await tapTab(tester, 'Today');
    expect(hero(tester), swapped(before));
    await tapTab(tester, 'Budget');
    expect(find.textContaining('1.234,56'), findsWidgets);
    expect(find.textContaining('1,234.56'), findsNothing);

    // Restart: a new controller on the same repo.
    numberStyle = NumberStyle.point;
    final wc2 = WalletController.forTest(wc.repo);
    expect(wc2.numberStyleName, 'comma');
    expect(numberStyle, NumberStyle.comma);

    // Back to the default.
    await tapTab(tester, 'Settings');
    await pickStyle(tester, '1,234.50');
    expect(wc.numberStyleName, 'point');
    await tapTab(tester, 'Today');
    expect(hero(tester), before);
  });

  test('an unknown style is ignored', () {
    final wc = emptyWallet();
    wc.setNumberStyle('purple');
    expect(wc.numberStyleName, 'point');
    expect(numberStyle, NumberStyle.point);
  });

  for (final style in ['point', 'comma']) {
    testWidgets('typing 12,50 in Add expense saves 1250 in the $style style', (tester) async {
      final wc = emptyWallet();
      wc.setNumberStyle(style);
      wc.repo.setLocalValue('lastExpenseCategory', 'Eating out');
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc))), size: const Size(400, 1600));
      await tester.enterText(find.descendant(of: find.byType(AddExpenseSheet), matching: find.byType(TextField)).first, '12,50');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('addExpenseSave')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4)); // the sync and save timers
      expect(wc.txs.map((t) => t.amount.abs()), [1250]);
    });
  }

  testWidgets('a preset amount is written in the chosen style in the Add expense field', (tester) async {
    final wc = emptyWallet()..setNumberStyle('comma');
    await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc, amount: 1250))), size: const Size(400, 1600));
    expect(find.text('12,50'), findsOneWidget);
  });

  test('a whole-unit range is grouped in the style', () {
    expect(billRangeShort(4000, 150000, 'EUR'), '40–1,500\u00A0€');
    numberStyle = NumberStyle.comma;
    expect(billRangeShort(150000, 250000, 'EUR'), '1.500–2.500\u00A0€');
    expect(billRangeShort(4050, 7000, 'EUR'), '40,50\u00A0€ to 70\u00A0€');
  });

  testWidgets('the empty amount field hints in the style', (tester) async {
    final wc = emptyWallet()..setNumberStyle('comma');
    await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: AddExpenseSheet(wc: wc))), size: const Size(400, 1600));
    expect(find.text('0,00'), findsOneWidget);
  });
}

/// The hero figure's text (a rich text: number, narrow gap, sign).
String _plain(Text t) => t.textSpan?.toPlainText() ?? t.data!;
