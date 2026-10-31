// ZC: the Insights graphs and the drill-down bars you can drag, pinch and zoom. Synthetic wallet on 20 Oct 2026 (insightsWallet);
// no goldens. Day and week bars must add up to the month the graph showed before.
import 'package:budget_wallet/src/chart_window.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/bucket_payments.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'insights_test.dart' show insightsWallet, labelOf, pump, tapKey;
import 'support/wallet.dart';

const _timeout = Timeout(Duration(minutes: 2));

Finder graph(String id) => find.byKey(ValueKey('chartGestures_$id'));

bool chipOn(WidgetTester t, String id, RangeKind k) => t.widget<ChoiceChip>(find.byKey(ValueKey('rangeChip_${id}_${k.name}'))).selected;

Future<void> show(WidgetTester t, String key) async {
  // in the middle of the view: at its edge a tap would land on the app bar
  await Scrollable.ensureVisible(t.element(find.byKey(ValueKey(key))), alignment: 0.5);
  await t.pump();
}

/// A drag in small steps (a single jump gives the gesture no movement to follow).
Future<void> swipe(WidgetTester t, Finder f, double dx) async {
  final g = await t.startGesture(t.getCenter(f));
  final steps = (dx.abs() / 8).ceil();
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(dx.sign * 8, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await t.pumpAndSettle();
}

int rowCount(WidgetTester t, String id) => find
    .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('barRow_${id}_'))
    .evaluate()
    .length;

int total(Iterable<SeriesBar> bars) => bars.fold<int>(0, (a, b) => a + b.spent);

void main() {
  group('the numbers: day and week bars add up to the month shown', () {
    test('spending: every month of the default window, in days and in weeks (a partial week counted once)', () {
      final wc = insightsWallet();
      final r = wc.insightRange('spending').range;
      for (final m in wc.spendingBars(r)) {
        final month = wc.monthRange(m.month);
        final bars = wc.spendingSeriesFor(month, Bucket.month);
        expect(bars.single.spent, m.spent, reason: m.month);
        expect(total(wc.spendingSeriesFor(month, Bucket.day)), m.spent, reason: 'days ${m.month}');
        expect(total(wc.spendingSeriesFor(month, Bucket.week)), m.spent, reason: 'weeks ${m.month}');
      }
    });

    test('income and budget: the same, and a budget week is a share that adds up', () {
      final wc = insightsWallet();
      final month = wc.monthRange('2026-09');
      final inc = wc.incomeBars(month).single;
      for (final b in [Bucket.day, Bucket.week]) {
        final bars = wc.incomeSeriesFor(month, b);
        expect(bars.fold<int>(0, (a, x) => a + x.income), inc.income, reason: b.name);
        expect(bars.fold<int>(0, (a, x) => a + x.spent), inc.spent, reason: b.name);
      }
      final bud = wc.budgetBars(month).single;
      final days = wc.budgetSeriesFor(month, Bucket.day);
      expect(days.fold<int>(0, (a, x) => a + x.budgeted), bud.budgeted);
      expect(days.fold<int>(0, (a, x) => a + x.actual), bud.actual);
      expect(days.every((x) => x.prorated), isTrue);
      final whole = wc.budgetSeriesFor(month, Bucket.month).single;
      expect((whole.budgeted, whole.actual, whole.over, whole.prorated), (bud.budgeted, bud.actual, bud.over, false));
    });

    test('a month that starts mid-week: the week bars cut at the month edge and still add up; a week over New Year', () {
      final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => DateTime(2026, 1, 20));
      wc.repo.addTransaction(date: '2025-12-31', amount: 1000, category: 'Groceries');
      wc.repo.addTransaction(date: '2026-01-01', amount: 2500, category: 'Groceries');
      wc.repo.addTransaction(date: '2026-01-04', amount: 300, category: 'Groceries');
      wc.reload();
      final w = DateRange(start: '2025-12-29', end: '2026-01-11');
      final weeks = wc.spendingSeriesFor(w, Bucket.week);
      expect(weeks.map((b) => b.span.start), ['2025-12-29', '2026-01-05']);
      expect(weeks.first.spent, 3800); // Mon 29 Dec to Sun 4 Jan: both sides of New Year in one bar
      expect(total(weeks), 3800);
      expect(bucketLabel(weeks.first.span, Bucket.week), '29 Dec 25 – 4 Jan 26');
    });
  });

  group('Insights graphs', () {
    testWidgets('zoom in: finer bars, no chip ticked, rows follow, Reset ticks the chip again; the kind is still remembered', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      final m = wc.insightRange('spending');
      final before = m.range;
      expect(chipOn(t, 'spending', RangeKind.months6), isTrue);
      expect(rowCount(t, 'spending'), 6);
      await show(t, 'chartZoomIn_spending');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      expect(m.isFree, isTrue);
      expect(m.range.days, lessThan(before.days));
      expect(chipOn(t, 'spending', RangeKind.months6), isFalse);
      for (final k in RangeKind.values) {
        expect(chipOn(t, 'spending', k), isFalse, reason: k.name);
      }
      // About three months are weeks: a row per week bar, keyed by its first day, and they add up to the window.
      final bars = wc.spendingSeriesFor(m.range, bucketFor(m.range));
      expect(bars.first.bucket, Bucket.week);
      expect(rowCount(t, 'spending'), bars.length);
      for (final b in bars) {
        expect(find.byKey(ValueKey('barRow_spending_${b.span.start}')), findsOneWidget);
        expect(
            find.descendant(of: find.byKey(ValueKey('barRow_spending_${b.span.start}')), matching: find.text(moneyExact(b.spent, 'EUR'))),
            findsOneWidget);
      }
      expect(wc.repo.localValue('insightRange:spending'), anyOf(isNull, 'months6'), reason: 'the kind stays, the window is not remembered');
      expect(labelOf(t, 'spending'), rangeLabel(m.range));
      await show(t, 'chartReset_spending');
      await t.tap(find.byKey(const ValueKey('chartReset_spending')));
      await t.pump();
      expect(m.isFree, isFalse);
      expect(m.range, before);
      expect(chipOn(t, 'spending', RangeKind.months6), isTrue);
      expect(rowCount(t, 'spending'), 6);
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a drag moves through time (also with a fling), clamped at the first payment; dragging forward stops at today', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      final m = wc.insightRange('spending');
      await show(t, 'chartZoomIn_spending');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      final zoomed = m.range;
      await show(t, 'chartGestures_spending');
      await swipe(t, graph('spending'), -80); // left: later
      await t.pumpAndSettle();
      expect(m.range.days, zoomed.days);
      expect(m.range.start.compareTo(zoomed.start), greaterThan(0));
      expect(m.isFree, isTrue);
      expect(chipOn(t, 'spending', RangeKind.months6), isFalse);
      // a long fling forward stops with the window's end on today (20 Oct), not after
      await t.fling(graph('spending'), const Offset(-600, 0), 3000);
      await t.pumpAndSettle();
      expect(m.range.end, '2026-10-20');
      expect(m.range.days, zoomed.days);
      // a long fling back in time stops at the first day with data (10 Jul 2026)
      await t.fling(graph('spending'), const Offset(600, 0), 3000);
      await t.pumpAndSettle();
      expect(m.range.start, '2026-07-10');
      expect(m.range.days, zoomed.days);
      expect(wc.repo.localValue('insightRange:spending'), anyOf(isNull, 'months6'));
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a pinch zooms in and out, and never below 7 days', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      final m = wc.insightRange('spending');
      await show(t, 'chartGestures_spending');
      final centre = t.getCenter(graph('spending'));
      Future<void> pinch(double spread, int steps, {double gap = 20}) async {
        final a = await t.startGesture(centre - Offset(gap, 0), pointer: 1);
        final b = await t.startGesture(centre + Offset(gap, 0), pointer: 2);
        for (var i = 0; i < steps; i++) {
          await a.moveBy(Offset(-spread * 10, 0));
          await b.moveBy(Offset(spread * 10, 0));
          await t.pump(const Duration(milliseconds: 16));
        }
        await a.up();
        await b.up();
        await t.pumpAndSettle();
      }

      final before = m.range.days;
      await pinch(1, 4);
      expect(m.isFree, isTrue);
      expect(m.range.days, lessThan(before));
      for (var i = 0; i < 4; i++) {
        await pinch(1, 40); // far past what is allowed
      }
      expect(m.range.days, chartMinDays);
      expect(t.widget<IconButton>(find.byKey(const ValueKey('chartZoomIn_spending'))).onPressed, isNull, reason: 'the + stops at 7 days');
      final days = wc.spendingSeriesFor(m.range, bucketFor(m.range));
      expect(days.first.bucket, Bucket.day);
      expect(days, hasLength(7));
      await pinch(-1, 12, gap: 150);
      expect(m.range.days, greaterThan(chartMinDays));
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a committed window logs insights.view with the graph and the bar size only: no dates, no amounts', (t) async {
      final seen = <LogEvent>[];
      final sub = Logger.root.onRecord.listen((r) {
        if (r.object is LogEvent) seen.add(r.object! as LogEvent);
      });
      addTearDown(sub.cancel);
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      await show(t, 'chartZoomIn_spending');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      final views = seen.where((e) => e.event == 'insights.view').toList();
      expect(views, hasLength(1));
      expect(views.single.fields.keys.toSet(), {'graph', 'bucket'});
      expect(views.single.fields['graph'], 'spending');
      expect(views.single.fields['bucket'], 'week');
    }, timeout: _timeout);

    testWidgets('double tap zooms in one step', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      final m = wc.insightRange('spending');
      await show(t, 'chartGestures_spending');
      final before = m.range.days;
      final at = t.getCenter(graph('spending'));
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 50));
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 400));
      expect(m.isFree, isTrue);
      expect((m.range.days - before / 2).abs() <= 1, isTrue);
    }, timeout: _timeout);

    testWidgets('keys: the arrows move, + and − zoom, when the graph has the focus; Ctrl + wheel zooms, Shift + wheel moves', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      final m = wc.insightRange('spending');
      await show(t, 'chartGestures_spending');
      Focus.of(t.element(graph('spending'))).requestFocus(); // what a press on the graph does
      await t.pump();
      final before = m.range.days;
      await t.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await t.pump();
      expect(m.range.days, lessThan(before));
      final zoomed = m.range;
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(m.range.start.compareTo(zoomed.start), greaterThan(0));
      await t.sendKeyEvent(LogicalKeyboardKey.numpadSubtract);
      await t.pump();
      expect(m.range.days, greaterThan(zoomed.days));
      // the wheel with Ctrl
      final w1 = m.range.days;
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(pointer.hover(t.getCenter(graph('spending'))));
      await t.sendEventToBinding(pointer.scroll(const Offset(0, -300)));
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump(const Duration(milliseconds: 400));
      expect(m.range.days, lessThan(w1));
      final w2 = m.range;
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump(const Duration(milliseconds: 400));
      expect(m.range.days, w2.days);
      expect(m.range.start, isNot(w2.start));
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a row opens the payments of that bar; they add up to its amount', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc), size: const Size(400, 3000));
      final oct = wc.spendingSeriesFor(wc.insightRange('spending').range, Bucket.month).last;
      await show(t, 'barRow_spending_2026-10');
      await t.tap(find.byKey(const ValueKey('barRow_spending_2026-10')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(BucketPaymentsScreen), findsOneWidget);
      final rows = t.widgetList<TxTile>(find.descendant(of: find.byKey(const ValueKey('bucketRows')), matching: find.byType(TxTile)));
      expect(rows.fold<int>(0, (a, x) => a - x.t.amount), oct.spent);
      expect(rows, isNotEmpty);
    }, timeout: _timeout);

    testWidgets('a tap on a bar opens its payments', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc), size: const Size(400, 3000));
      await show(t, 'chartGestures_spending');
      final box = t.getRect(graph('spending'));
      // the last of the six bars (October)
      await t.tapAt(Offset(box.left + box.width * (5.5 / 6), box.top + 60));
      await t.pump(const Duration(milliseconds: 350)); // the double tap waits for a second tap first
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(BucketPaymentsScreen), findsOneWidget);
      final oct = wc.spendingSeriesFor(wc.insightRange('spending').range, Bucket.month).last;
      final rows = t.widgetList<TxTile>(find.descendant(of: find.byKey(const ValueKey('bucketRows')), matching: find.byType(TxTile)));
      expect(rows.fold<int>(0, (a, x) => a - x.t.amount), oct.spent);
    }, timeout: _timeout);

    testWidgets('chips still jump: a chip after a drag ticks and clears the window', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      await show(t, 'chartZoomIn_spending');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      expect(wc.insightRange('spending').isFree, isTrue);
      await show(t, 'rangeChip_spending_months12');
      await tapKey(t, 'rangeChip_spending_months12');
      expect(wc.insightRange('spending').isFree, isFalse);
      expect(chipOn(t, 'spending', RangeKind.months12), isTrue);
      // 12 months are months again
      expect(rowCount(t, 'spending'), 12);
    }, timeout: _timeout);

    testWidgets('‹ › on a free window move it by its own length', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc));
      final m = wc.insightRange('spending');
      await show(t, 'chartZoomIn_spending');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      final w = m.range;
      await show(t, 'rangeForward_spending');
      await tapKey(t, 'rangeForward_spending');
      expect(m.range.days, w.days);
      expect(m.range.start.compareTo(w.start), greaterThan(0));
      expect(m.range.end.compareTo('2026-10-20') <= 0, isTrue, reason: 'never past today');
      expect(m.isFree, isTrue);
    }, timeout: _timeout);

    testWidgets('income and budget graphs have the same controls; a budget bar below a month says it is a share', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc), size: const Size(400, 9000));
      for (final id in ['income', 'budget']) {
        for (final k in ['chartZoomIn_', 'chartZoomOut_', 'chartReset_']) {
          expect(find.byKey(ValueKey('$k$id')), findsOneWidget, reason: '$k$id');
        }
      }
      expect(find.text('Budget'), findsWidgets);
      await show(t, 'chartZoomIn_budget');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_budget')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('chartZoomIn_budget')));
      await t.pump();
      expect(find.text('Budget share'), findsOneWidget, reason: 'the legend');
      final bars = wc.budgetSeriesFor(wc.insightRange('budget').range, bucketFor(wc.insightRange('budget').range));
      expect(bars.every((b) => b.prorated), isTrue);
      expect(find.textContaining('Budget share '), findsWidgets);
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('no budgets: still just the note; an empty wallet: no errors, buttons there, a drag does nothing', (t) async {
      await pump(t, InsightsScreen(wc: insightsWallet(budgets: false)));
      expect(find.byKey(const ValueKey('insightBars_budget')), findsNothing);
      expect(find.byKey(const ValueKey('chartZoomIn_budget')), findsNothing);
      final wc = emptyWallet();
      await pump(t, InsightsScreen(wc: wc));
      expect(wc.dayIndex.first, isNull);
      final m = wc.insightRange('spending');
      final w = m.range;
      await show(t, 'chartGestures_spending');
      await swipe(t, graph('spending'), 120);
      await t.pumpAndSettle();
      expect(m.range, w, reason: 'nothing earlier to show');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      expect(m.range.days, lessThan(w.days));
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('320 dp at text scale 2.0: no overflow with the buttons and the rows, zoomed in and out', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc), size: const Size(320, 9000), textScale: 2.0);
      await show(t, 'chartZoomIn_spending');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pump();
      expect(find.byKey(const ValueKey('chartReset_spending')), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('chartReset_spending')));
      await t.pump();
      expect(t.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('lists: − / + make the range shorter / longer, a swipe on the dates moves it', (t) async {
      final wc = insightsWallet();
      await pump(t, InsightsScreen(wc: wc), size: const Size(400, 9000));
      final m = wc.insightRange('share');
      expect(m.range, wc.monthRange('2026-10'));
      await show(t, 'chartZoomIn_share');
      await t.tap(find.byKey(const ValueKey('chartZoomIn_share')));
      await t.pump();
      expect(m.isFree, isTrue);
      expect(m.range.days, lessThan(31));
      expect(chipOn(t, 'share', RangeKind.month), isFalse);
      await t.tap(find.byKey(const ValueKey('chartZoomOut_share')));
      await t.pump();
      expect(m.range.days, greaterThan(14));
      final w = m.range;
      await t.fling(find.byKey(const ValueKey('rangeSwipe_share')), const Offset(300, 0), 2000); // swipe right: earlier
      await t.pumpAndSettle();
      expect(m.range.end.compareTo(w.start) < 0 || m.range.start.compareTo(w.start) < 0, isTrue);
      await t.tap(find.byKey(const ValueKey('chartReset_share')));
      await t.pump();
      expect(m.range, wc.monthRange('2026-10'));
      expect(chipOn(t, 'share', RangeKind.month), isTrue);
    }, timeout: _timeout);
  });

  group('drill-down bars', () {
    testWidgets('a category over one month: day bars, no rows until the window moves; zoom out shows weeks or months with rows', (t) async {
      final wc = insightsWallet();
      final r = wc.monthRange('2026-10');
      await pump(t, CategoryDetailScreen(wc: wc, category: 'Groceries', range: r), size: const Size(1280, 3000));
      expect(find.byKey(const ValueKey('detailBars_category')), findsOneWidget);
      expect(rowCountOf(t, 'detailRow_category_'), 0);
      expect(find.byKey(const ValueKey('chartDates_category')), findsOneWidget);
      await show(t, 'chartZoomOut_category');
      await t.tap(find.byKey(const ValueKey('chartZoomOut_category')));
      await t.pump();
      // 62 days: weeks, one row each, adding up to the category in those days
      final w = wc.spendingSeriesFor(DateRange(start: '2026-09-01', end: '2026-10-31'), Bucket.week, category: 'Groceries');
      expect(rowCountOf(t, 'detailRow_category_'), greaterThan(0));
      expect(w.fold<int>(0, (a, b) => a + b.spent), wc.categoryTotal('Groceries', DateRange(start: '2026-09-01', end: '2026-10-31')));
      await show(t, 'chartReset_category');
      await t.tap(find.byKey(const ValueKey('chartReset_category')));
      await t.pump();
      expect(rowCountOf(t, 'detailRow_category_'), 0);
      expect(t.takeException(), isNull);
    }, timeout: _timeout);
  });

  group('forecast', () {
    const points = [
      ForecastPoint('2026-10-20', 100000, null),
      ForecastPoint('2026-10-25', 70000, 'Rent', delta: -30000),
      ForecastPoint('2026-11-02', -5000, 'Loan', delta: -75000),
    ];
    testWidgets('zoom in shows a part of the days, its end label has the balance on that day; Reset shows all', (t) async {
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(
              body: SingleChildScrollView(child: ForecastStepChart(points: points, payday: '2026-11-10', currency: 'EUR')))));
      String endLabel() => t.widget<Text>(find.byKey(const ValueKey('forecastEndLabel'))).data!;
      expect(endLabel(), contains(shortDateOrRaw('2026-11-10')));
      await t.tap(find.byKey(const ValueKey('chartZoomIn_forecast')));
      await t.pump();
      expect(endLabel(), isNot(contains(shortDateOrRaw('2026-11-10'))));
      await swipe(t, find.byKey(const ValueKey('chartGestures_forecast')), -700);
      await t.pumpAndSettle();
      expect(endLabel(), contains(shortDateOrRaw('2026-11-10')), reason: 'dragged to the end: never past payday');
      await t.tap(find.byKey(const ValueKey('chartReset_forecast')));
      await t.pump();
      expect(find.text('Today'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, timeout: _timeout);
  });
}

int rowCountOf(WidgetTester t, String prefix) =>
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix)).evaluate().length;
