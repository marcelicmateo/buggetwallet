// RX8: tag and category detail as Paper Tiles dashboards (hero total, compare tiles, per-month bars, merchants, payments), and the grid
// on wide windows: the column count per width, no overflow at 1024 / 1280 / 1920 (also at text scale 2.0) and the same reading order as
// the phone on every dashboard. SYNTHETIC wallets; the real fonts are loaded (the test font is far wider).

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/tag_detail.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart' show TxTile;
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/detail.dart';
import 'support/fonts.dart';
import 'support/layout.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 120));
const _quick = Timeout(Duration(seconds: 40));

/// A Wednesday at noon: Today shows no delivery-hour tile (14:00-19:00 or a Sunday), so its tile set is the same whenever the test runs.
final _wednesday = DateTime(2026, 10, 28, 12);

/// The demo wallet on a pinned day. `demoWallet()` follows the real clock, and Today's tile set follows the hour and the weekday.
WalletController _demo([DateTime? at]) => demoWallet(clock: () => at ?? _wednesday);

Future<void> _loadFonts() async {
  await loadAppFonts();
}

/// The budget wallet (20 Oct 2026) with named payees in Groceries and an extra tag on September's and October's Groceries rows.
Future<({WalletController wc, String tag})> _wallet({bool septemberToo = true}) async {
  final wc = budgetWallet(budgets: false);
  addTearDown(wc.dispose);
  wc.repo.addTransaction(date: '2026-10-05', amount: 2345, category: 'Groceries', note: 'Lidl');
  wc.repo.addTransaction(date: '2026-10-06', amount: 1999, category: 'Groceries', note: 'Spar');
  // Through the repo: the controller's tag methods start the 3 s sync debounce, a pending timer at the end of a widget test.
  final tag = await wc.repo.addTag('Holiday');
  wc.reload();
  for (final t in wc.txs) {
    if (t.category != 'Groceries' || t.amount >= 0) continue;
    if (t.date.startsWith('2026-10') || (septemberToo && t.date.startsWith('2026-09'))) await wc.repo.setTxTag(t.tx.id, tag, true);
  }
  wc.reload();
  return (wc: wc, tag: tag);
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {Size size = const Size(400, 4000), double scale = 1, Brightness mode = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: screen,
  ));
  await tester.pump();
}

Finder _k(String key) => find.byKey(ValueKey(key));

/// The tile boxes of the first visible [DashGrid], in widget order.
List<Rect> _boxes(WidgetTester tester, [int index = 0]) {
  final grid = tester.renderObject<RenderBox>(find.byType(DashGrid).at(index));
  final out = <Rect>[];
  grid.visitChildren((c) {
    final b = c as RenderBox;
    out.add((b.parentData! as BoxParentData).offset & b.size);
  });
  return out;
}

/// Tiles come in widget order (top, then left), never overlap and stay inside the grid.
void _expectOrdered(List<Rect> boxes, double width, String reason) {
  for (var i = 1; i < boxes.length; i++) {
    final a = boxes[i - 1], b = boxes[i];
    expect(b.top > a.top - 0.5 && (b.top > a.top + 0.5 || b.left >= a.left - 0.5), isTrue,
        reason: '$reason: tile $i comes before tile ${i - 1}');
  }
  for (var i = 0; i < boxes.length; i++) {
    expect(boxes[i].left, greaterThanOrEqualTo(-0.5), reason: reason);
    expect(boxes[i].right, lessThanOrEqualTo(width + 0.5), reason: reason);
    for (var j = i + 1; j < boxes.length; j++) {
      expect(boxes[i].deflate(1).overlaps(boxes[j].deflate(1)), isFalse, reason: '$reason: tiles $i and $j overlap');
    }
  }
}

/// No empty cell above the last row of grid [index]: every row but the last is full (a tall tile fills the cells under it). The last row may
/// end short, that is how a grid of tiles ends.
void _expectNoHoles(WidgetTester tester, double scale, String reason, [int index = 0]) {
  final boxes = _boxes(tester, index);
  if (boxes.isEmpty) return;
  final gridW = tester.getSize(find.byType(DashGrid).at(index)).width;
  final cols = DashGrid.columnsFor(gridW, tester.view.physicalSize.width, minColumn: DashGrid.minColumnFor(TextScaler.linear(scale)));
  final colW = (gridW - 10 * (cols - 1)) / cols;
  final tops = {for (final b in boxes) b.top.round()}.toList()..sort();
  final filled = <(int, int)>{};
  for (final b in boxes) {
    final c0 = ((b.left + 1) / (colW + 10)).floor(), span = ((b.width + 10) / (colW + 10)).round();
    for (var r = 0; r < tops.length; r++) {
      if (tops[r] >= b.top.round() && tops[r] < b.bottom - 1) {
        for (var c = c0; c < c0 + span; c++) {
          filled.add((r, c));
        }
      }
    }
  }
  for (var r = 0; r < tops.length - 1; r++) {
    for (var c = 0; c < cols; c++) {
      expect(filled.contains((r, c)), isTrue, reason: '$reason: an empty cell at row $r, column $c of $cols (a hole above the last row)');
    }
  }
}

void main() {
  setUpAll(_loadFonts);

  group('columns per window width', () {
    test('4 from an expanded window, 2 below, 1 when a column would be too narrow', () {
      // width of the grid, width of the window, scaled minimum column
      expect(DashGrid.columnsFor(1000, 1024), 4);
      expect(DashGrid.columnsFor(808, 1024), 4, reason: 'the 840 dp dialog on a 1024 window');
      expect(DashGrid.columnsFor(1016, 1280), 4);
      expect(DashGrid.columnsFor(1016, 1920), 4);
      expect(DashGrid.columnsFor(776, 800), 2);
      expect(DashGrid.columnsFor(600, 1000), 2, reason: 'a medium window stays at 2');
      expect(DashGrid.columnsFor(336, 360), 2);
      expect(DashGrid.columnsFor(296, 320), 2);
      // 2.0 text: a column is 260 dp at least.
      expect(DashGrid.columnsFor(296, 320, minColumn: 260), 1);
      expect(DashGrid.columnsFor(336, 360, minColumn: 260), 1);
      expect(DashGrid.columnsFor(387, 411, minColumn: 260), 1);
      expect(DashGrid.columnsFor(1016, 1280, minColumn: 260), 2, reason: 'four 252 dp columns are too narrow at 2.0');
      expect(DashGrid.columnsFor(1016, 1920, minColumn: 260), 2);
      expect(DashGrid.columnsFor(1016, 1920, minColumn: 150), 4, reason: '1.15 text still has four');
    });

    testWidgets('a detail page measured: 4 columns at 1024 / 1280 / 1920, 2 at 800 and 360, 1 at 320 with text 2.0', (tester) async {
      final (:wc, :tag) = await _wallet();
      final r = wc.monthRange('2026-10');
      for (final (w, scale, cols) in const [
        (1024.0, 1.0, 4),
        (1280.0, 1.0, 4),
        (1920.0, 1.0, 4),
        (800.0, 1.0, 2),
        (360.0, 1.0, 2),
        (320.0, 2.0, 1),
        (1024.0, 2.0, 2),
      ]) {
        await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: Size(w, 4000), scale: scale);
        final boxes = _boxes(tester);
        final narrowest = boxes.map((b) => b.width).reduce((a, b) => a < b ? a : b);
        final gridW = tester.getSize(find.byType(DashGrid)).width;
        // The compare tiles are one cell wide, so the narrowest tile is a column.
        final measured = ((gridW + 10) / (narrowest + 10)).round();
        expect(measured, cols, reason: '$w dp at text $scale');
        _expectOrdered(boxes, gridW, '$w dp at text $scale');
        expect(tester.takeException(), isNull);
      }
    }, timeout: _timeout);
  });

  group('tag detail', () {
    testWidgets('hero total, month chip against last month, last month, average, bars and payments - all core numbers', (tester) async {
      final (:wc, :tag) = await _wallet();
      final r = wc.monthRange('2026-10');
      await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: const Size(1280, 3000));
      // 152 + 100 + 23.45 + 19.99 = 295.44 in October; September 290.
      expect(wc.tagTotalFor(tag, r), (spent: 29544, count: 4));
      expect(heroIs('tagDetailTotal', moneyExact(29544, 'EUR')), findsOneWidget);
      expect(wc.rowsOfTag(tag, r), hasLength(4));
      final cmp = wc.compareTagFor(tag, r);
      expect((cmp.thisMonth, cmp.lastMonth), (29544, 29000));
      // The hero is October: no "this month" tile, the chip sits on the hero and says up (worse), 1.9 % -> 2 %.
      expect(_k('compareThis'), findsNothing);
      expect(find.descendant(of: _k('compareDelta'), matching: find.text('2 % vs Sep')), findsOneWidget);
      expect(inTile('compareLast', moneyExact(29000, 'EUR')), findsOneWidget);
      expect(inTile('compareAverage', moneyExact(cmp.average6, 'EUR')), findsOneWidget);
      expect(cmp.average6, (29000 / 6).round());
      expect(_k('tagDetailBars'), findsOneWidget);
      // One month is ~30 day bars: the rows follow them (they are hidden only when there is a single bar), and add up to the hero.
      final days = wc.spendingSeriesFor(r, bucketFor(r), tag: tag);
      expect(days, hasLength(31));
      for (final b in days) {
        expect(_k('tagDetailRow_${b.span.start}'), findsOneWidget);
      }
      expect(days.fold<int>(0, (a, b) => a + b.spent), 29544);
      // The hero label does not repeat the title.
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('#${wc.tagTable.label(tag)}')), findsOneWidget);
      expect(find.text('TOTAL'), findsOneWidget, reason: 'the hero says Total, not the title again');
      expect(find.descendant(of: _k('tagRows'), matching: find.byType(TxTile)), findsNWidgets(4));
      // The sentence is behind the (i).
      expect(find.textContaining('other tags too'), findsNothing);
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a range that starts mid-month: the hero is the range, so October gets its own tile with the chip', (tester) async {
      final (:wc, :tag) = await _wallet();
      final r = DateRange(start: '2026-10-03', end: '2026-10-31');
      await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: const Size(1280, 3000));
      final cmp = wc.compareTagFor(tag, r);
      expect(inTile('compareThis', moneyExact(cmp.thisMonth, 'EUR')), findsOneWidget);
      expect(find.descendant(of: _k('compareThis'), matching: find.byKey(const ValueKey('compareDelta'))), findsOneWidget);
      expect(inTile('compareLast', moneyExact(cmp.lastMonth, 'EUR')), findsOneWidget, reason: 'September is not a row of this range');
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a range that shows month rows with both months: the This month and Last month tiles would repeat them, only Average stays',
        (tester) async {
      final (:wc, :tag) = await _wallet();
      final r = DateRange(start: '2026-04-01', end: '2026-10-31'); // 214 days: a bar per month
      await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: const Size(1280, 3000));
      final cmp = wc.compareTagFor(tag, r);
      expect(heroIs('tagDetailTotal', moneyExact(29000 + 29544, 'EUR')), findsOneWidget);
      final months = wc.spendingSeriesFor(r, bucketFor(r), tag: tag);
      expect(months.first.bucket, Bucket.month);
      for (final b in months) {
        expect(_k('tagDetailRow_${monthOf(b.span.start)}'), findsOneWidget);
      }
      expect(_k('tagDetailRow_2026-10'), findsOneWidget);
      expect(_k('tagDetailRow_2026-09'), findsOneWidget);
      expect(_k('compareThis'), findsNothing);
      expect(_k('compareLast'), findsNothing);
      expect(inTile('compareAverage', moneyExact(cmp.average6, 'EUR')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('a range shown as weeks does not hold the months as rows: This month and Last month stay, the weeks add up to the hero',
        (tester) async {
      final (:wc, :tag) = await _wallet();
      final r = DateRange(start: '2026-08-01', end: '2026-10-31'); // 92 days: a bar per week
      await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: const Size(1280, 3000));
      final cmp = wc.compareTagFor(tag, r);
      final weeks = wc.spendingSeriesFor(r, bucketFor(r), tag: tag);
      expect(weeks.first.bucket, Bucket.week);
      for (final b in weeks) {
        expect(_k('tagDetailRow_${b.span.start}'), findsOneWidget);
      }
      expect(weeks.fold<int>(0, (a, b) => a + b.spent), 29000 + 29544);
      expect(inTile('compareThis', moneyExact(cmp.thisMonth, 'EUR')), findsOneWidget);
      expect(inTile('compareLast', moneyExact(cmp.lastMonth, 'EUR')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('no spending last month: no chip, the figure is 0 exactly; no payments: the empty note', (tester) async {
      final (:wc, :tag) = await _wallet(septemberToo: false);
      final r = wc.monthRange('2026-10');
      await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: const Size(400, 3000));
      expect(_k('compareDelta'), findsNothing);
      expect(inTile('compareLast', moneyExact(0, 'EUR')), findsOneWidget);
      final other = wc.monthRange('2026-05');
      await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: other), size: const Size(400, 3000));
      expect(heroIs('tagDetailTotal', moneyExact(0, 'EUR')), findsOneWidget);
      expect(find.text('Nothing spent with this tag in this range.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);
  });

  group('category detail', () {
    testWidgets('hero, compare tiles, bars, merchants as bars that drill in, payments of one merchant', (tester) async {
      final (:wc, tag: _) = await _wallet();
      final r = wc.monthRange('2026-10');
      await _pump(tester, CategoryDetailScreen(wc: wc, category: 'Groceries', range: r), size: const Size(1280, 3000));
      final total = wc.categoryTotal('Groceries', r);
      expect(total, 29544);
      expect(heroIs('detailTotal', moneyExact(total, 'EUR')), findsOneWidget);
      expect(_k('compareThis'), findsNothing);
      expect(_k('compareDelta'), findsOneWidget);
      expect(_k('detailBars_category'), findsOneWidget);
      // One month is ~30 day bars: a row each, adding up to the hero; the hero label is not the title again.
      final days = wc.spendingSeriesFor(r, bucketFor(r), category: 'Groceries');
      for (final b in days) {
        expect(_k('detailRow_category_${b.span.start}'), findsOneWidget);
      }
      expect(days.fold<int>(0, (a, b) => a + b.spent), total);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(wc.categoryTable.label('Groceries'))), findsOneWidget);
      expect(find.text('TOTAL'), findsOneWidget, reason: 'the hero says Total, not the title again');
      final merchants = wc.merchantsFor('Groceries', r);
      expect(merchants.fold<int>(0, (a, m) => a + m.spent), total);
      expect(find.descendant(of: _k('merchantsTile'), matching: find.byType(BarList)), findsOneWidget);
      for (final m in merchants) {
        expect(_k('merchantRow_${m.key}'), findsOneWidget);
        expect(find.descendant(of: _k('merchantRow_${m.key}'), matching: find.text(moneyExact(m.spent, 'EUR'))), findsOneWidget);
      }
      final lidl = merchants.firstWhere((m) => m.label == 'Lidl');
      await tester.tap(_k('merchantRow_${lidl.key}'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_k('merchantRows'), findsOneWidget);
      expect(heroIs('detailTotal', moneyExact(lidl.spent, 'EUR')), findsOneWidget);
      expect(_k('detailBack'), findsOneWidget);
      await tester.tap(_k('detailBack'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_k('merchantRows'), findsNothing);
      expect(_k('merchantsTile'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);
  });

  group('layout: no overflow, light and dark', () {
    for (final (name, size, scale) in const [
      ('320 x 2.0', Size(320, 6000), 2.0),
      ('360', Size(360, 4000), 1.0),
      ('411', Size(411, 4000), 1.0),
      ('1024', Size(1024, 3000), 1.0),
      ('1280', Size(1280, 3000), 1.0),
      ('1280 x 2.0', Size(1280, 5000), 2.0),
      ('1920', Size(1920, 3000), 1.0),
    ]) {
      for (final mode in Brightness.values) {
        testWidgets('tag, category and merchant pages at $name, ${mode.name}', (tester) async {
          final errors = Errors();
          final (:wc, :tag) = await _wallet();
          final r = wc.monthRange('2026-10');
          await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: r), size: size, scale: scale, mode: mode);
          scanFlex(tester);
          _expectOrdered(_boxes(tester), tester.getSize(find.byType(DashGrid)).width, 'tag $name');
          _expectNoHoles(tester, scale, 'tag $name');
          // Several months: the hero is the range, so "this month" is a tile of its own and the rows fill differently.
          final months = DateRange(start: '2026-08-01', end: '2026-10-31');
          await _pump(tester, TagDetailScreen(wc: wc, tag: tag, range: months), size: size, scale: scale, mode: mode);
          scanFlex(tester);
          _expectOrdered(_boxes(tester), tester.getSize(find.byType(DashGrid)).width, 'tag months $name');
          _expectNoHoles(tester, scale, 'tag months $name');
          await _pump(tester, CategoryDetailScreen(wc: wc, category: 'Groceries', range: months), size: size, scale: scale, mode: mode);
          _expectNoHoles(tester, scale, 'category months $name');
          await _pump(tester, CategoryDetailScreen(wc: wc, category: 'Groceries', range: r), size: size, scale: scale, mode: mode);
          scanFlex(tester);
          _expectOrdered(_boxes(tester), tester.getSize(find.byType(DashGrid)).width, 'category $name');
          _expectNoHoles(tester, scale, 'category $name');
          final lidl = wc.merchantsFor('Groceries', r).firstWhere((m) => m.label == 'Lidl');
          await tester.tap(_k('merchantRow_${lidl.key}'));
          await tester.pump(const Duration(milliseconds: 400));
          scanFlex(tester);
          _expectOrdered(_boxes(tester), tester.getSize(find.byType(DashGrid)).width, 'merchant $name');
          errors.check();
          expect(overflowing, isEmpty);
          expect(tester.takeException(), isNull);
        }, timeout: _timeout);
      }
    }
  });

  group('every dashboard on a wide window', () {
    for (final (name, size, scale) in const [
      ('1024', Size(1024, 800), 1.0),
      ('1280', Size(1280, 800), 1.0),
      ('1920', Size(1920, 1080), 1.0),
      ('1024 x 2.0', Size(1024, 800), 2.0),
      ('1280 x 2.0', Size(1280, 800), 2.0),
      ('1920 x 2.0', Size(1920, 1080), 2.0),
    ]) {
      testWidgets('$name: Today, Spending, Plan, Bills, Save and the period report keep their order, overlap nothing, overflow nothing',
          (tester) async {
        overflowing.clear();
        await withErrors((errors) async {
          await pumpFull(tester, _demo(), scale, size: size);
          void check(String what) {
            final grids = find.byType(DashGrid).evaluate().length;
            expect(grids, greaterThan(0), reason: '$name $what has a grid');
            for (var i = 0; i < grids; i++) {
              _expectOrdered(_boxes(tester, i), tester.getSize(find.byType(DashGrid).at(i)).width, '$name $what grid $i');
              // Bills and Save hold their tiles in rows that fill (the others end in what the wallet has: see their own tests).
              if (what == 'Today' || what == 'Bills' || what == 'Save') _expectNoHoles(tester, scale, '$name $what grid $i', i);
            }
          }

          await pumpIdle(tester);
          check('Today');
          for (final tab in const ['Budget', 'Bills', 'Save']) {
            await tapTab(tester, tab);
            await pumpIdle(tester);
            check(tab);
            await scrollThrough(tester);
          }
          await tapTab(tester, 'Plan');
          await tester.tap(_k('planPayday'));
          await pumpIdle(tester);
          check('Plan');
          await scrollThrough(tester);
          final badge = find.byKey(const ValueKey('periodBadgeTap'));
          await tester.tap(badge);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(_k('reportKept'), findsOneWidget);
          check('Period report');
          await scrollThrough(tester);
          errors.check();
          expect(overflowing, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }, timeout: _timeout);
    }

    testWidgets(
        'Today follows the wallet clock, not the real one: the delivery-hour tile on a Sunday and at 15:00, not on a Wednesday noon',
        (tester) async {
      Future<bool> deliveryTile(DateTime at) async {
        await pumpFull(tester, _demo(at), 1.0, size: const Size(1280, 800));
        await pumpIdle(tester);
        final shown = find.textContaining('delivery hour', findRichText: true).evaluate().isNotEmpty;
        await tester.pumpWidget(const SizedBox());
        return shown;
      }

      expect(await deliveryTile(DateTime(2026, 10, 28, 12)), isFalse, reason: 'Wednesday 12:00');
      expect(await deliveryTile(DateTime(2026, 10, 28, 15)), isTrue, reason: 'Wednesday 15:00');
      expect(await deliveryTile(DateTime(2026, 11, 1, 12)), isTrue, reason: 'Sunday 12:00');
      expect(await deliveryTile(DateTime(2026, 11, 2, 12)), isFalse, reason: 'Monday 12:00');
    }, timeout: _quick);

    testWidgets('Today at 1280 keeps four full columns across a month boundary (no hole above the last row)', (tester) async {
      for (final day in [DateTime(2026, 10, 29), DateTime(2026, 10, 31), DateTime(2026, 11, 2), DateTime(2026, 11, 3)]) {
        await pumpFull(tester, _demo(DateTime(day.year, day.month, day.day, 12)), 1.0, size: const Size(1280, 800));
        await pumpIdle(tester);
        _expectOrdered(_boxes(tester), tester.getSize(find.byType(DashGrid)).width, 'Today on ${isoDate(day)}');
        _expectNoHoles(tester, 1.0, 'Today on ${isoDate(day)}');
        await tester.pumpWidget(const SizedBox());
      }
    }, timeout: _quick);

    testWidgets('Today: at 1200 the hero is one short row across all four columns, two columns at 800, one at 320 with text 2.0',
        (tester) async {
      Future<List<Rect>> boxes(Size size, double scale) async {
        await pumpFull(tester, _demo(), scale, size: size);
        await pumpIdle(tester);
        return _boxes(tester);
      }

      final wide = await boxes(const Size(1200, 800), 1.0);
      final gridW = tester.getSize(find.byType(DashGrid).first).width;
      expect(wide.first.width, closeTo(gridW, 1), reason: 'the hero spans the whole row');
      expect(wide.first.height, lessThan(wide.first.width / 3), reason: 'one short row: no block of empty paper under the figure');
      expect(wide[1].top, greaterThanOrEqualTo(wide.first.bottom), reason: 'the next tile flows below the hero');
      final phone = await boxes(const Size(360, 800), 1.0);
      expect(phone[1].top, greaterThanOrEqualTo(phone.first.bottom), reason: 'under the hero on two columns');
      final big = await boxes(const Size(320, 800), 2.0);
      expect(big.map((b) => b.left).toSet(), hasLength(1), reason: 'one column');
    }, timeout: _timeout);
  });
}

/// Lets the idle page builds and fades finish without `pumpAndSettle` (timers and animations keep running).
Future<void> pumpIdle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
