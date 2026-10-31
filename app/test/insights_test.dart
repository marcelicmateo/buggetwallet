// Insights (stage N3): the range control, the four graphs and the biggest payments, the drill-down, the numbers staying equal to
// their rows, and the memoization. Synthetic wallet on 20 Oct 2026; no goldens.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/insight_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/detail.dart';
import 'support/wallet.dart';

/// 20 Oct 2026. Groceries (Lidl, Spar) and Eating out (Pizzeria, one row without a name) over Jul–Oct, Shopping, a salary,
/// one USD row. Budgets: Groceries 300, Eating out 100 (112 spent in October: over by 12).
WalletController insightsWallet({bool budgets = true}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  for (final m in const ['2026-07', '2026-08', '2026-09']) {
    wc.repo.addTransaction(date: '$m-10', amount: 29000, category: 'Groceries', note: 'Lidl');
    wc.repo.addTransaction(date: '$m-20', amount: 5000, category: 'Groceries', note: 'Spar');
    wc.repo.addTransaction(date: '$m-12', amount: 8500, category: 'Eating out');
  }
  wc.repo.addTransaction(date: '2026-10-03', amount: 15200, category: 'Groceries', note: 'Lidl');
  wc.repo.addTransaction(date: '2026-10-12', amount: 10000, category: 'Groceries', note: 'Spar');
  wc.repo.addTransaction(date: '2026-10-08', amount: 11200, category: 'Eating out', note: 'Pizzeria');
  wc.repo.addTransaction(date: '2026-10-09', amount: 6000, category: 'Shopping', note: 'Hardware');
  wc.repo.addTransaction(date: '2026-10-05', amount: 700, category: 'Shopping', note: 'Online shop', currency: 'USD');
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  if (budgets) {
    wc.repo.setCategoryBudget('Groceries', 30000);
    wc.repo.setCategoryBudget('Eating out', 10000);
  }
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    for (final m in const ['2026-07', '2026-08', '2026-09', '2026-10']) syntheticTx('$m-10', 150000, 'Plaća/Mirovina', 'Neto placa dio 1'),
  ]));
  wc.reload();
  return wc;
}

Future<void> pump(WidgetTester tester, Widget child,
    {Size size = const Size(400, 6000), double textScale = 1, Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: c!),
    home: child,
  ));
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String labelOf(WidgetTester tester, String id) {
  final b = tester.widget<TextButton>(find.byKey(ValueKey('rangeLabel_$id')));
  final row = b.child! as Row;
  return ((row.children.first as Flexible).child as Text).data!;
}

RangePicker picking(DateTimeRange? r) => (context, initial, first, last) async => r;

void main() {
  group('range control', () {
    testWidgets('every chip selects its kind and shows core\'s label', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      for (final k in [RangeKind.payPeriod, RangeKind.month, RangeKind.months3, RangeKind.months6, RangeKind.months12]) {
        await tapKey(tester, 'rangeChip_spending_${k.name}');
        expect(wc.insightRange('spending').kind, k);
        expect(labelOf(tester, 'spending'), rangeLabel(wc.resolveRange(k)), reason: k.name);
        final chip = tester.widget<ChoiceChip>(find.byKey(ValueKey('rangeChip_spending_${k.name}')));
        expect(chip.selected, isTrue);
      }
      await tapKey(tester, 'rangeChip_spending_custom');
      expect(wc.insightRange('spending').kind, RangeKind.custom);
      // other graphs keep their own kind
      expect(wc.insightRange('share').kind, RangeKind.month);
      expect(wc.insightRange('income').kind, RangeKind.months6);
    });

    testWidgets('back and forward step by the kind; forward is off at the current range', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      await tapKey(tester, 'rangeChip_spending_months3');
      final now = wc.resolveRange(RangeKind.months3);
      IconButton fwd() => tester.widget<IconButton>(find.byKey(const ValueKey('rangeForward_spending')));
      expect(fwd().onPressed, isNull);
      await tapKey(tester, 'rangeBack_spending');
      final back = shiftRange(now, RangeKind.months3, -1, wc.effectiveSettings, txs: wc.txs, today: wc.today());
      expect(labelOf(tester, 'spending'), rangeLabel(back));
      expect(fwd().onPressed, isNotNull);
      await tapKey(tester, 'rangeBack_spending');
      await tapKey(tester, 'rangeForward_spending');
      await tapKey(tester, 'rangeForward_spending');
      expect(labelOf(tester, 'spending'), rangeLabel(now));
      expect(fwd().onPressed, isNull);
    });

    testWidgets('arrow keys on the dates step', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      final before = labelOf(tester, 'spending');
      // Tab to the dates button (six chips, the back arrow, then the dates)
      for (var i = 0; i < 12; i++) {
        final f = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>();
        if (f?.key == const ValueKey('rangeLabel_spending')) break;
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(labelOf(tester, 'spending'), isNot(before));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(labelOf(tester, 'spending'), before);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // already at the current range: nothing happens
      await tester.pump();
      expect(labelOf(tester, 'spending'), before);
    });

    testWidgets('the date label opens the picker and a picked range becomes custom', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc, picker: picking(DateTimeRange(start: DateTime(2026, 8, 5), end: DateTime(2026, 9, 20)))));
      await tapKey(tester, 'rangeLabel_spending');
      expect(wc.insightRange('spending').kind, RangeKind.custom);
      expect(labelOf(tester, 'spending'), rangeLabel(DateRange(start: '2026-08-05', end: '2026-09-20')));
      expect(find.byKey(const ValueKey('rangeError_spending')), findsNothing);
      // the bars follow the range: 47 days are weeks, from the 5th of August to the 20th of September, nothing in October
      expect(find.byKey(const ValueKey('barRow_spending_2026-08-05')), findsOneWidget);
      expect(find.byKey(const ValueKey('barRow_spending_2026-09-14')), findsOneWidget);
      expect(find.byKey(const ValueKey('barRow_spending_2026-10-05')), findsNothing);
    });

    testWidgets('the system date range picker opens from the label', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc), size: const Size(400, 900));
      await tapKey(tester, 'rangeLabel_spending');
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
    });

    testWidgets('a refused range shows core\'s message and changes nothing', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc, picker: picking(DateTimeRange(start: DateTime(2020, 1, 1), end: DateTime(2026, 10, 20)))));
      final before = labelOf(tester, 'spending');
      await tapKey(tester, 'rangeLabel_spending');
      final err = find.byKey(const ValueKey('rangeError_spending'));
      expect(err, findsOneWidget);
      expect(find.descendant(of: err, matching: find.textContaining('longer than 5 years')), findsOneWidget);
      expect(wc.insightRange('spending').kind, RangeKind.months6);
      expect(labelOf(tester, 'spending'), before);
      // the next good action clears it
      await tapKey(tester, 'rangeChip_spending_months3');
      expect(err, findsNothing);
    });

    testWidgets('a range after this month is refused', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc, picker: picking(DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 11, 5)))));
      await tapKey(tester, 'rangeLabel_spending');
      expect(find.byKey(const ValueKey('rangeError_spending')), findsOneWidget);
    });

    test('the kind is remembered per graph on this device', () {
      final wc = insightsWallet();
      wc.insightRange('spending').select(RangeKind.months12);
      wc.insightRange('share').setCustom('2026-08-01', '2026-09-15');
      expect(wc.repo.localValue('insightRange:spending'), 'months12');
      final again = InsightRange(wc, 'spending');
      expect(again.kind, RangeKind.months12);
      final custom = InsightRange(wc, 'share');
      expect(custom.kind, RangeKind.custom);
      expect(custom.range, DateRange(start: '2026-08-01', end: '2026-09-15'));
      expect(InsightRange(wc, 'income').kind, RangeKind.months6); // never set: the default
    });
  });

  group('graphs', () {
    testWidgets('spending per month: one bar and one exact amount per month, the running month marked so far', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      final r = wc.insightRange('spending').range;
      final bars = wc.spendingBars(r);
      expect(bars.length, 6);
      expect(find.byKey(const ValueKey('insightBars_spending')), findsOneWidget);
      for (final b in bars) {
        final row = find.byKey(ValueKey('barRow_spending_${b.month}'));
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(moneyExact(b.spent, 'EUR'))), findsOneWidget, reason: b.month);
      }
      final oct = find.byKey(const ValueKey('barRow_spending_2026-10'));
      expect(find.descendant(of: oct, matching: find.text('October 2026 · so far')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Spending per month\\.')), findsOneWidget);
    });

    testWidgets('category share: sorted rows, percentages from permille, amounts exact', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      final share = wc.shareFor(wc.insightRange('share').range);
      expect(share.slices.map((s) => s.category), ['Groceries', 'Eating out', 'Shopping']);
      expect(share.slices.fold<int>(0, (a, s) => a + s.permille), 1000);
      for (final s in share.slices) {
        final row = find.byKey(ValueKey('shareRow_${s.category}'));
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(permilleText(s.permille))), findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(moneyExact(s.spent, 'EUR'))), findsOneWidget);
      }
      expect(permilleText(123), '12.3 %');
      expect(permilleText(120), '12 %');
      expect(permilleText(1000), '100 %');
    });

    testWidgets('income against spending: a net per month', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      final bars = wc.incomeBars(wc.insightRange('income').range);
      expect(bars.length, 6);
      expect(find.byKey(const ValueKey('insightBars_income')), findsOneWidget);
      for (final b in bars) {
        final row = find.byKey(ValueKey('barRow_income_${b.month}'));
        expect(find.descendant(of: row, matching: find.text('Net ${moneyExactSigned(b.net, 'EUR')}')), findsOneWidget, reason: b.month);
      }
      expect(bars.last.income, 150000);
      expect(bars.last.net, 150000 - bars.last.spent);
    });

    testWidgets('budget against actual: the over amount is marked with an icon and words', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      final oct = wc.budgetBars(wc.insightRange('budget').range).last;
      expect(oct.month, '2026-10');
      expect(oct.over, 1200);
      final row = find.byKey(const ValueKey('barRow_budget_2026-10'));
      expect(find.descendant(of: row, matching: find.textContaining('over by ${moneyExact(1200, 'EUR')}')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.error_outline)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(moneyExact(oct.actual, 'EUR'))), findsOneWidget);
      // September's groceries were over too (340 of 300); a month with nothing spent carries no mark
      final sep = find.byKey(const ValueKey('barRow_budget_2026-09'));
      expect(find.descendant(of: sep, matching: find.byIcon(Icons.error_outline)), findsOneWidget);
      final may = find.byKey(const ValueKey('barRow_budget_2026-05'));
      expect(find.descendant(of: may, matching: find.byIcon(Icons.error_outline)), findsNothing);
    });

    testWidgets('no budgets: a plain note instead of the graph', (tester) async {
      final wc = insightsWallet(budgets: false);
      await pump(tester, InsightsScreen(wc: wc));
      expect(find.byKey(const ValueKey('insightBars_budget')), findsNothing);
      expect(find.text('No budgets set. Add them in Settings.'), findsOneWidget);
    });

    testWidgets('biggest payments: the largest first', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      final r = wc.insightRange('biggest').range;
      final rows = wc.biggestIn(r);
      final tiles =
          tester.widgetList<TxTile>(find.descendant(of: find.byKey(const ValueKey('biggestList')), matching: find.byType(TxTile)));
      expect(tiles.map((t) => t.t.tx.id), rows.map((t) => t.tx.id));
      expect(rows.first.amount, -15200);
    });

    testWidgets('other currencies are named, not counted', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      for (final id in ['spending', 'share', 'income', 'budget']) {
        expect(find.byKey(ValueKey('foreign_$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Other currencies, not counted: ${moneyExact(700, 'USD')} spent'), findsWidgets);
      // without a foreign row there is no line
      final plain = budgetWallet();
      await pump(tester, InsightsScreen(wc: plain));
      expect(find.byKey(const ValueKey('foreign_share')), findsNothing);
    });

    testWidgets('an empty wallet shows empty states, no errors', (tester) async {
      await pump(tester, InsightsScreen(wc: emptyWallet()));
      expect(find.text('No spending in this range.'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('drill-down', () {
    testWidgets('a share row opens the category: total, compare, trend, merchants', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc), size: const Size(400, 3000));
      await tapKey(tester, 'shareRow_Groceries');
      expect(find.byType(CategoryDetailScreen), findsOneWidget);
      final r = wc.insightRange('share').range;
      final total = wc.categoryTotal('Groceries', r);
      expect(total, 25200);
      expect(heroIs('detailTotal', moneyExact(total, 'EUR')), findsOneWidget);
      final cmp = wc.compareFor('Groceries', r);
      expect(cmp.thisMonth, 25200);
      expect(cmp.lastMonth, 34000);
      // The month is said once: when the hero already is this month there is no "this month" tile, only the chip against last month.
      final single = cmp.thisMonth == total && r.start.endsWith('-01');
      expect(find.byKey(const ValueKey('compareThis')), single ? findsNothing : findsOneWidget);
      expect(find.byKey(const ValueKey('compareDelta')), findsOneWidget);
      for (final (key, v) in [
        if (!single) ('compareThis', cmp.thisMonth),
        ('compareLast', cmp.lastMonth),
        ('compareAverage', cmp.average6)
      ]) {
        expect(inTile(key, moneyExact(v, 'EUR')), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('detailBars_category')), findsOneWidget);
      final merchants = wc.merchantsFor('Groceries', r);
      expect(merchants.map((m) => m.label), ['Lidl', 'Spar']);
      // the merchants add up to the category total
      expect(merchants.fold<int>(0, (a, m) => a + m.spent), total);
      for (final m in merchants) {
        final row = find.byKey(ValueKey('merchantRow_${m.key}'));
        expect(find.descendant(of: row, matching: find.text(moneyExact(m.spent, 'EUR'))), findsOneWidget);
      }
    });

    testWidgets('a merchant opens its rows, which add up to its total; back returns', (tester) async {
      final wc = insightsWallet();
      wc.insightRange('share').select(RangeKind.months6);
      await pump(tester, InsightsScreen(wc: wc), size: const Size(400, 3000));
      await tapKey(tester, 'shareRow_Groceries');
      final lidl = wc.merchantsFor('Groceries', wc.insightRange('share').range).firstWhere((m) => m.label == 'Lidl');
      await tester.ensureVisible(find.byKey(ValueKey('merchantRow_${lidl.key}')));
      await tapKey(tester, 'merchantRow_${lidl.key}');
      expect(find.byKey(const ValueKey('merchantRows')), findsOneWidget);
      final tiles =
          tester.widgetList<TxTile>(find.descendant(of: find.byKey(const ValueKey('merchantRows')), matching: find.byType(TxTile)));
      expect(tiles.length, lidl.count);
      expect(-tiles.fold<int>(0, (a, t) => a + t.t.amount), lidl.spent);
      expect(heroIs('detailTotal', moneyExact(lidl.spent, 'EUR')), findsOneWidget);
      expect(find.byKey(const ValueKey('detailBars_merchant')), findsOneWidget);
      await tapKey(tester, 'detailBack');
      expect(find.byKey(const ValueKey('merchantRows')), findsNothing);
      expect(find.byKey(const ValueKey('compareAverage')), findsOneWidget);
    });

    testWidgets('the category trend is the merchants\' trends added up', (tester) async {
      final wc = insightsWallet();
      final r = wc.resolveRange(RangeKind.months6);
      final cat = wc.categoryBars('Eating out', r);
      final parts = [for (final m in wc.merchantsFor('Eating out', r)) wc.merchantBars('Eating out', m.key, r)];
      expect(parts.length, 2); // Pizzeria and the row without a name
      for (var i = 0; i < cat.length; i++) {
        expect(cat[i].spent, parts.fold<int>(0, (a, p) => a + p[i].spent), reason: cat[i].month);
      }
      expect(wc.merchantsFor('Eating out', r).any((m) => m.label == 'Other'), isTrue);
    });

    testWidgets('Spending: a category row opens its detail for the shown month; Insights opens from its button', (tester) async {
      final wc = insightsWallet();
      await pump(tester, Scaffold(body: SpendingScreen(wc: wc)), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('categoryRow_Groceries')), findsOneWidget);
      await tapKey(tester, 'categoryRow_Groceries');
      expect(find.byType(CategoryDetailScreen), findsOneWidget);
      expect(heroIs('detailTotal', moneyExact(25200, 'EUR')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sheetClose')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tapKey(tester, 'insightsOpen');
      expect(find.byType(InsightsScreen), findsOneWidget);
    });

    testWidgets('editing a payment from the drill-down moves the totals', (tester) async {
      final wc = insightsWallet();
      await pump(tester, CategoryDetailScreen(wc: wc, category: 'Groceries', range: wc.monthRange('2026-10')), size: const Size(400, 3000));
      expect(heroIs('detailTotal', moneyExact(25200, 'EUR')), findsOneWidget);
      final id = wc.rowsOf('Groceries', null, wc.monthRange('2026-10')).first.tx.id;
      wc.repo.setCategory(id, 'Shopping');
      wc.reload();
      await tester.pump();
      expect(heroIs('detailTotal', moneyExact(wc.categoryTotal('Groceries', wc.monthRange('2026-10')), 'EUR')), findsOneWidget);
    });
  });

  group('memoization', () {
    test('the same range is computed once; a data change computes again', () {
      final wc = insightsWallet();
      final r = wc.resolveRange(RangeKind.months6);
      final again = DateRange(start: r.start, end: r.end); // an equal range, not the same object
      expect(identical(wc.spendingBars(r), wc.spendingBars(again)), isTrue);
      expect(identical(wc.shareFor(r), wc.shareFor(again)), isTrue);
      expect(identical(wc.incomeBars(r), wc.incomeBars(again)), isTrue);
      expect(identical(wc.budgetBars(r), wc.budgetBars(again)), isTrue);
      expect(identical(wc.merchantsFor('Groceries', r), wc.merchantsFor('Groceries', again)), isTrue);
      expect(identical(wc.biggestIn(r), wc.biggestIn(again)), isTrue);
      expect(identical(wc.resolveRange(RangeKind.months6), r), isTrue);
      final other = wc.resolveRange(RangeKind.months3);
      expect(identical(wc.spendingBars(other), wc.spendingBars(r)), isFalse);
      final old = wc.spendingBars(r);
      wc.reload();
      expect(identical(wc.spendingBars(r), old), isFalse);
      expect(wc.spendingBars(r).map((b) => b.spent), old.map((b) => b.spent)); // same data, same numbers
    });

    testWidgets('opening Insights again keeps the range chosen before', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      await tapKey(tester, 'rangeChip_spending_months12');
      await tapKey(tester, 'rangeBack_spending');
      final shown = labelOf(tester, 'spending');
      await pump(tester, const SizedBox());
      await pump(tester, InsightsScreen(wc: wc));
      expect(labelOf(tester, 'spending'), shown);
    });
  });

  group('layout', () {
    for (final (name, size, scale, brightness) in [
      ('320 dp at 2.0', const Size(320, 6000), 2.0, Brightness.light),
      ('400 dp dark', const Size(400, 6000), 1.0, Brightness.dark),
      ('1280 wide', const Size(1280, 6000), 1.0, Brightness.light),
    ]) {
      testWidgets('Insights fits at $name', (tester) async {
        final wc = insightsWallet();
        await pump(tester, InsightsScreen(wc: wc), size: size, textScale: scale, brightness: brightness);
        expect(tester.takeException(), isNull);
        for (final k in [RangeKind.months12, RangeKind.payPeriod, RangeKind.custom]) {
          await tapKey(tester, 'rangeChip_spending_${k.name}');
          expect(tester.takeException(), isNull, reason: k.name);
        }
      });

      testWidgets('the drill-down fits at $name', (tester) async {
        final wc = insightsWallet();
        await pump(tester, CategoryDetailScreen(wc: wc, category: 'Groceries', range: wc.resolveRange(RangeKind.months6)),
            size: size, textScale: scale, brightness: brightness);
        expect(tester.takeException(), isNull);
        final lidl = wc.merchantsFor('Groceries', wc.resolveRange(RangeKind.months6)).first;
        await tester.ensureVisible(find.byKey(ValueKey('merchantRow_${lidl.key}')));
        await tapKey(tester, 'merchantRow_${lidl.key}');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('range controls have 48 dp targets', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      for (final k in ['rangeBack_spending', 'rangeLabel_spending', 'rangeChip_spending_months3']) {
        final s = tester.getSize(find.byKey(ValueKey(k)));
        expect(s.height, greaterThanOrEqualTo(47.9), reason: k);
      }
      expect(tester.getSize(find.byKey(const ValueKey('rangeBack_spending'))).width, greaterThanOrEqualTo(47.9));
    });
  });
  group('review fixes', () {
    testWidgets('a refund-only category opens with its negative total, equal to its rows', (tester) async {
      final wc = insightsWallet();
      wc.repo.setCategoryBudget('Sport & fitness', 10000);
      wc.repo.addTransaction(date: '2026-10-07', amount: -500, category: 'Sport & fitness', note: 'Refund');
      wc.reload();
      final r = wc.monthRange('2026-10');
      final rows = wc.rowsOf('Sport & fitness', null, r);
      expect(rows.fold<int>(0, (a, t) => a + t.amount), 500);
      expect(wc.categoryTotal('Sport & fitness', r), -500);
      await pump(tester, CategoryDetailScreen(wc: wc, category: 'Sport & fitness', range: r), size: const Size(400, 3000));
      expect(heroIs('detailTotal', moneyExact(-500, 'EUR')), findsOneWidget);
    });

    test('the category bars and total equal the month summaries, per month', () {
      final wc = insightsWallet();
      final r = wc.resolveRange(RangeKind.months6);
      for (final cat in ['Groceries', 'Eating out', 'Shopping']) {
        final bars = wc.categoryBars(cat, r);
        for (final b in bars) {
          expect(b.spent, wc.txs.isEmpty ? 0 : (monthSummary(wc.txs, b.month, currency: 'EUR').byCategory[cat] ?? 0),
              reason: '$cat ${b.month}');
        }
        expect(bars.fold<int>(0, (a, b) => a + b.spent), wc.categoryTotal(cat, r), reason: cat);
      }
    });

    test('moneyExactSigned keeps the cents', () {
      expect(moneyExactSigned(123456, 'EUR'), '+1,234.56\u00A0€');
      expect(moneyExactSigned(-4000, 'EUR'), '−40\u00A0€');
      expect(moneyExactSigned(150000, 'EUR'), '+1,500\u00A0€');
    });

    testWidgets('Income vs spending shows the net with its cents in the row, the tip and the spoken text', (tester) async {
      final wc = insightsWallet();
      wc.repo.addTransaction(date: '2026-10-11', amount: 99, category: 'Shopping', note: 'Kiosk');
      wc.reload();
      await pump(tester, InsightsScreen(wc: wc), size: const Size(400, 6000));
      final bar = wc.incomeBars(wc.insightRange('income').range).firstWhere((b) => b.month == '2026-10');
      expect(bar.net % 100, isNot(0));
      final exact = moneyExactSigned(bar.net, 'EUR');
      final row = find.byKey(const ValueKey('barRow_income_2026-10'));
      await tester.ensureVisible(row);
      expect(find.descendant(of: row, matching: find.text('Net $exact')), findsOneWidget);
      final g = tester
          .widget<SeriesBars>(find.byKey(const ValueKey('insightBars_income')))
          .groups
          .firstWhere((g) => g.start.startsWith('2026-10'));
      expect(g.tip, contains('Net $exact'));
      expect(g.spoken, contains('net $exact'));
    });

    testWidgets('a share row and the dates label keep their tap action for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = insightsWallet();
      var picked = 0;
      await pump(
          tester,
          InsightsScreen(
              wc: wc,
              picker: (context, initial, first, last) async {
                picked++;
                return null;
              }),
          size: const Size(400, 3000));
      tester.semantics.tap(find.semantics.byLabel(RegExp('^Dates .*Opens the date picker')).first);
      await tester.pump();
      expect(picked, 1);
      tester.semantics.tap(find.semantics.byLabel(RegExp('^Groceries: ')).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CategoryDetailScreen), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Custom from a pay period that runs into next month is clamped to the end of this month', (tester) async {
      final wc = insightsWallet();
      await pump(tester, InsightsScreen(wc: wc));
      await tapKey(tester, 'rangeChip_spending_payPeriod');
      expect(wc.insightRange('spending').range.end.compareTo('2026-10-31'), greaterThan(0));
      await tapKey(tester, 'rangeChip_spending_custom');
      final m = wc.insightRange('spending');
      expect(m.error, isNull);
      expect(m.kind, RangeKind.custom);
      // The saved period start (1 Oct, 9 days before the 10 Oct salary) starts the pay period, as on Today (RX7b rule).
      expect(m.range.start, '2026-10-01');
      expect(m.range.end, '2026-10-31');
    });

    testWidgets('an edit that removes the shown merchant returns to the category, and Back leaves', (tester) async {
      final wc = insightsWallet();
      final r = wc.monthRange('2026-10');
      await pump(tester, CategoryDetailScreen(wc: wc, category: 'Eating out', range: r), size: const Size(400, 3000));
      final pizzeria = wc.merchantsFor('Eating out', r).firstWhere((m) => m.label == 'Pizzeria');
      await tapKey(tester, 'merchantRow_${pizzeria.key}');
      expect(find.byKey(const ValueKey('merchantRows')), findsOneWidget);
      PopScope scope() => tester
          .widget<PopScope>(find.descendant(of: find.byType(CategoryDetailScreen), matching: find.byWidgetPredicate((w) => w is PopScope)));
      expect(scope().canPop, isFalse);
      wc.repo.setCategory(wc.rowsOf('Eating out', pizzeria.key, r).first.tx.id, 'Shopping');
      wc.reload();
      await tester.pump();
      expect(find.byKey(const ValueKey('merchantRows')), findsNothing);
      expect(find.byKey(const ValueKey('compareLast')), findsOneWidget);
      expect(scope().canPop, isTrue);
    });
  });
}
