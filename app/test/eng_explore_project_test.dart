// ENG E4 + E5 UI: the Explore screen (query bar, chart, table, heatmap, move together, saved views, CSV) and the Project screen. All data is
// SYNTHETIC: a wallet with 94 months (2019-01 .. 2026-10, today 20 Oct 2026) of three spending tags, one tag with a few payments and four
// bank rows at one place. The chart is drawn from the same core rows as the table, so the tests pin the table to core's numbers to the cent.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/explore_text.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/budget.dart';
import 'package:budget_wallet/src/screens/explore.dart';
import 'package:budget_wallet/src/screens/project.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 120));

Finder k(String key) => find.byKey(ValueKey(key));

/// 2019-01 .. 2026-10. Eating out is the biggest and peaks in December every year; Groceries drifts; Transport is small.
Future<({WalletController wc, String reno, List<String> tagged})> exploreWallet() async {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  var i = 0;
  for (var y = 2019; y <= 2026; y++) {
    for (var m = 1; m <= 12; m++) {
      if (y == 2026 && m > 10) break;
      final ym = '$y-${m.toString().padLeft(2, '0')}';
      wc.repo.addTransaction(date: '$ym-10', amount: 20000 + i * 37 + (i % 5) * 111, category: 'Groceries', note: 'Spar');
      wc.repo.addTransaction(date: '$ym-12', amount: 50000 + (m == 12 ? 34000 : 0) + (i % 7) * 90, category: 'Eating out', note: 'Cafe');
      wc.repo.addTransaction(date: '$ym-15', amount: 9000 + (i % 3) * 700, category: 'Car & transport', note: 'Bus');
      i++;
    }
  }
  // Four bank rows at one place (the first two, oldest, carry the project tag, the later two do not) and one hand-added paint payment.
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2025-09-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2025-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2025-12-08', -1200, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-03', -3000, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
  ]));
  final paint = wc.repo.addTransaction(date: '2026-09-20', amount: 12000, category: 'Shopping', note: 'Paint shop');
  wc.reload();
  final reno = await wc.repo.addTag('Reno');
  wc.reload();
  final bank = wc.txs.where((t) => t.tx.description.contains('KONZUM')).toList()..sort((a, b) => a.date.compareTo(b.date));
  final tagged = [bank[0].tx.id, bank[1].tx.id, paint];
  for (final id in tagged) {
    await wc.repo.setTxTag(id, reno, true);
  }
  wc.reload();
  return (wc: wc, reno: reno, tagged: tagged);
}

Future<void> pumpScreen(WidgetTester tester, Widget screen,
    {Size size = const Size(1280, 3000), double scale = 1, Brightness mode = Brightness.dark}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: screen),
  ));
  await tester.pump();
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Future<void> tapKey(WidgetTester t, String key) async {
  final f = k(key);
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

class _Capture extends FileChooser {
  String? name;
  Uint8List? bytes;
  @override
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    name = fileName;
    this.bytes = bytes;
    return Uri.parse('file:///x');
  }
}

String _cell(WidgetTester t, String key) => (t.widget(k(key)) as Text).data!;

/// The table rows the screen shows, newest first: [(bucket start, [cell texts])].
List<String> _rowStarts(WidgetTester t) => [
      for (final e in find
          .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('exploreRow:'))
          .evaluate())
        (e.widget.key as ValueKey<String>).value.substring('exploreRow:'.length)
    ];

void main() {
  group('explore text', () {
    test('strength and words', () {
      expect(strengthText(620), '0.62');
      expect(strengthText(-705), '−0.71');
      expect(strengthText(1000), '1.00');
      expect(strengthText(4), '0.00');
      MoveTogether m(int s) => MoveTogether(strength: s, months: 46, from: '2023-01-01', to: '2026-10-31');
      expect(moveWords(m(700)), 'strong · 46 months');
      expect(moveWords(m(699)), 'fairly strong · 46 months');
      expect(moveWords(m(500)), 'fairly strong · 46 months');
      expect(moveWords(m(499)), 'weak · 46 months');
      expect(moveWords(m(120)), 'hardly any link · 46 months');
      expect(moveWords(m(-720)), 'strong, when one goes up the other goes down · 46 months');
      expect(moveWords(null), 'not enough shared months');
    });

    test('the top month needs the same month on top in 3 years', () {
      List<HeatCell> year(int y, int topMonth) =>
          [for (var m = 1; m <= 12; m++) HeatCell(year: y, month: m, cents: m == topMonth ? 900 : 100 + m, level: 1)];
      expect(topMonthSentence([...year(2022, 12), ...year(2023, 12), ...year(2024, 12)], 2026, Measure.spent),
          'December is your priciest month every year.');
      expect(topMonthSentence([...year(2022, 12), ...year(2023, 12), ...year(2024, 12), ...year(2025, 3)], 2026, Measure.spent),
          'December is your priciest month in 3 of 4 years.');
      expect(topMonthSentence([...year(2022, 12), ...year(2023, 12), ...year(2024, 3)], 2026, Measure.spent), isNull);
      // the running year is skipped, a tie for the top counts for nobody
      expect(topMonthSentence([...year(2024, 12), ...year(2025, 12), ...year(2026, 12)], 2026, Measure.spent), isNull);
      final tie = [for (var m = 1; m <= 12; m++) HeatCell(year: 2021, month: m, cents: m >= 11 ? 900 : 5, level: 1)];
      expect(topMonthSentence([...tie, ...year(2022, 12), ...year(2023, 12)], 2026, Measure.spent), isNull);
    });

    test('share and hours', () {
      expect(permilleText(72), '7.2 %');
      expect(hoursText(8320), '832 h');
      expect(hoursText(125), '12.5 h');
    });
  });

  group('explore screen', () {
    testWidgets('the table equals core to the cent and the existing spending totals; All runs over more than 5 years', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ExploreScreen(wc: wc));
      // default: the three biggest spending tags, 3 years, by month
      final keys = wc.exploreDefaultKeys();
      expect(keys.map((k) => k.id).toSet(), {'Groceries', 'Eating out', 'Car & transport'});
      await tapKey(tester, 'exploreRange:All');
      final ix = wc.exploreIndex;
      final window = DateRange(start: ix.first!, end: wc.today());
      expect(window.days, greaterThan(5 * 366), reason: 'All is the whole history');
      final starts = _rowStarts(tester);
      expect(starts, isNotEmpty);
      // the default bucket for All is quarter or year, never a month over 5 years
      final bucket = bucketFor(window, maxBars: 72);
      expect(bucket.index, greaterThanOrEqualTo(Bucket.quarter.index));
      final rows = wc.exploreRows(SeriesQuery(measure: Measure.spent, keys: keys, bucket: bucket, window: window));
      final shown = starts.length;
      expect(shown, tableRows.clamp(0, rows.length));
      final cur = wc.currency;
      for (final r in rows.reversed.take(shown)) {
        for (var i = 0; i < keys.length; i++) {
          final v = r.cents[keys[i]]!;
          expect(_cell(tester, 'exploreCell:${r.bucket.start}:$i'), moneyExact(v, cur), reason: 'cell ${r.bucket.start} #$i');
          // the existing spending totals for the same window and bar
          final bar = wc.spendingSeriesFor(r.bucket, bucket, category: keys[i].id).single;
          expect(bar.spent, v);
        }
        expect(_cell(tester, 'exploreCell:${r.bucket.start}:together'), moneyExact(r.together, cur));
        expect(r.together, r.cents.values.fold<int>(0, (a, b) => a + b), reason: 'main tags never overlap');
      }
      // the running quarter is marked
      expect(find.textContaining('so far'), findsWidgets);
      expect(tester.takeException(), isNull);
    }, timeout: _timeout);

    testWidgets('the tooltip lists the same values as the table row of that bucket', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ExploreScreen(wc: wc));
      final area = k('exploreChartArea');
      final tl = tester.getTopLeft(area);
      await tester.tapAt(tl + const Offset(500, 120));
      await tester.pump();
      expect(k('exploreTip'), findsOneWidget);
      final title = (tester.widget(k('exploreTipTitle')) as Text).data!.replaceAll(' · so far', '');
      final q = SeriesQuery(
          measure: Measure.spent,
          keys: wc.exploreDefaultKeys(),
          bucket: Bucket.month,
          window: DateRange(start: '2023-10-21', end: '2026-10-20'));
      final row = wc.exploreRows(q).firstWhere((r) => exploreBucketLabel(r.bucket, Bucket.month) == title);
      for (var i = 0; i < q.keys.length; i++) {
        final tip = (tester.widget(k('exploreTipValue:$i')) as Text).data!;
        expect(tip, moneyExact(row.cents[q.keys[i]]!, wc.currency));
        expect(_cell(tester, 'exploreCell:${row.bucket.start}:$i'), tip, reason: 'tooltip and table agree');
      }
    }, timeout: _timeout);

    testWidgets('measure, bucket and series change the table; more than 4 series become small multiples', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ExploreScreen(wc: wc));
      expect(find.byType(CustomPaint), findsWidgets);
      // count of payments
      await tapKey(tester, 'exploreMeasure');
      await tester.tap(k('measure:count'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_cell(tester, 'exploreCell:${_rowStarts(tester).first}:0'), '1');
      // yearly bars
      await tapKey(tester, 'exploreBucket');
      await tester.tap(k('bucket:year'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_rowStarts(tester).first, startsWith('2026-01-01'));
      // add a tag series, then main tags until there are 5: small multiples
      for (final id in ['Shopping', 'Bills & subscriptions']) {
        await tapKey(tester, 'exploreAdd');
        await tester.tap(k('seriesPick:mainTag:$id'));
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(k('series:4'), findsOneWidget);
      expect(find.byKey(const ValueKey('exploreChartArea')), findsNWidgets(5), reason: 'one small chart per series');
      // remove one: back to a single chart
      await tester.tap(find.descendant(of: k('series:4'), matching: k('seriesRemove')));
      await tester.pump();
      expect(find.byKey(const ValueKey('exploreChartArea')), findsOneWidget);
    }, timeout: _timeout);

    testWidgets('a tag series with an overlap: together is counted once and the column says so', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ExploreScreen(wc: wc));
      await tapKey(tester, 'exploreAdd');
      await tester.tap(k('seriesKind:tag'));
      await tester.pump();
      await tester.tap(k('seriesPick:tag:${w.reno}'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('overlaps counted once'), findsOneWidget);
      final q = SeriesQuery(
          measure: Measure.spent,
          keys: [...wc.exploreDefaultKeys(), SeriesKey(SeriesKind.tag, w.reno)],
          bucket: Bucket.month,
          window: DateRange(start: '2023-10-21', end: '2026-10-20'));
      final r = wc.exploreRows(q).firstWhere((r) => r.cents[q.keys.last]! > 0);
      expect(r.together, lessThan(r.cents.values.fold<int>(0, (a, b) => a + b)));
      expect(_cell(tester, 'exploreCell:${r.bucket.start}:together'), moneyExact(r.together, wc.currency));
    }, timeout: _timeout);

    testWidgets('heatmap, top-month sentence and exact cell value', (tester) async {
      final w = await exploreWallet();
      await pumpScreen(tester, ExploreScreen(wc: w.wc));
      final first = w.wc.exploreDefaultKeys().first;
      final cells = w.wc.exploreHeat(first, Measure.spent);
      expect(find.byKey(const ValueKey('exploreHeat')), findsOneWidget);
      await tapKey(tester, 'heat:2025-12');
      final c = cells.firstWhere((c) => c.year == 2025 && c.month == 12);
      expect((tester.widget(k('heatReadout')) as Text).data, 'December 2025 · ${moneyExact(c.cents, w.wc.currency)}');
      // remove the other series so Eating out is the heatmap's series: December is the top month in all complete years
      for (final name in ['Groceries', 'Car & transport']) {
        await tester.tap(find.descendant(of: k('series:${_seriesIndexOf(tester, name)}'), matching: k('seriesRemove')));
        await tester.pump();
      }
      expect((tester.widget(k('heatSentence')) as Text).data, 'December is your priciest month every year.');
    }, timeout: _timeout);

    testWidgets('move together: number, words and months come from core', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ExploreScreen(wc: wc));
      final keys = wc.exploreDefaultKeys();
      final q =
          SeriesQuery(measure: Measure.spent, keys: keys, bucket: Bucket.month, window: DateRange(start: '2023-10-21', end: '2026-10-20'));
      final m = wc.exploreMove(keys[0], keys[1], q.window);
      expect(m, isNotNull);
      expect((tester.widget(k('moveStrength')) as Text).data, strengthText(m!.strength));
      expect((tester.widget(k('moveWords')) as Text).data, moveWords(m));
      // two series that share no month with spending: words say so
      await tapKey(tester, 'moveB');
      await tester.tap(k('seriesKind:payee'));
      await tester.pump();
      await tester.tap(find
          .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('seriesPick:payee:'))
          .first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('moveWords')), findsOneWidget);
    }, timeout: _timeout);

    testWidgets('saved views: save, pin, rename, delete with Undo, load', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ExploreScreen(wc: wc));
      await tapKey(tester, 'exploreSave');
      await tester.enterText(k('viewName'), 'My question');
      await tester.tap(k('viewNameSave'));
      await tester.pump(const Duration(milliseconds: 400));
      final views = wc.exploreViews();
      expect(views.single.name, 'My question');
      expect(views.single.parsed!.keys, wc.exploreDefaultKeys());
      final id = views.single.id;
      expect(find.descendant(of: k('exploreViews'), matching: find.text('My question')), findsOneWidget);
      // pin
      await tapKey(tester, 'viewMenu:$id');
      await tester.tap(k('viewPin'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(wc.exploreViews().single.pinned, isTrue);
      // rename
      await tapKey(tester, 'viewMenu:$id');
      await tester.tap(k('viewRename'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(k('viewName'), 'Renamed');
      await tester.tap(k('viewNameSave'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(wc.exploreViews().single.name, 'Renamed');
      // delete, Undo (the earlier toasts have gone by then)
      await tester.pump(const Duration(seconds: 4));
      await tapKey(tester, 'viewMenu:$id');
      await tester.tap(k('viewDelete'));
      await tester.pump(const Duration(seconds: 1));
      expect(wc.exploreViews(), isEmpty);
      tester.widget<SnackBarAction>(k('toastUndo')).onPressed(); // the test font makes the toast wider than 400 dp: the button is clipped
      await tester.pump(const Duration(milliseconds: 400));
      expect(wc.exploreViews().single.name, 'Renamed');
      // load: remove a series, then open the view
      await tester.tap(find.descendant(of: k('series:0'), matching: k('seriesRemove')));
      await tester.pump();
      expect(k('series:2'), findsNothing);
      await tapKey(tester, 'view:$id');
      expect(k('series:2'), findsOneWidget);
      await settle(tester);
    }, timeout: _timeout);

    testWidgets('export CSV: one line per bucket of the query, exact decimals', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      final cap = _Capture();
      await pumpScreen(tester, ExploreScreen(wc: wc, chooser: cap));
      await tapKey(tester, 'exploreExport');
      expect(cap.bytes, isNotNull);
      final text = utf8.decode(cap.bytes!.sublist(3)); // BOM
      final lines = text.trim().split('\n');
      final keys = wc.exploreDefaultKeys();
      final q =
          SeriesQuery(measure: Measure.spent, keys: keys, bucket: Bucket.month, window: DateRange(start: '2023-10-21', end: '2026-10-20'));
      final rows = wc.exploreRows(q);
      expect(lines.length, rows.length + 1);
      expect(lines.first, 'from,to,${keys.map(wc.seriesLabel).map(csvField).join(',')},together');
      final r = rows.last;
      expect(lines.last,
          '${r.bucket.start},${r.bucket.end},${keys.map((k) => centsToDecimal(r.cents[k]!)).join(',')},${centsToDecimal(r.together)}');
      expect(cap.name, 'bw-explore-2023-10-21-2026-10-20.csv');
    }, timeout: _timeout);

    testWidgets('the Explore tab opens Explore; the old Spending page and Tags stay behind the switch', (tester) async {
      final w = await exploreWallet();
      await pumpScreen(tester, BudgetScreen(wc: w.wc));
      expect(find.byType(ExploreScreen), findsOneWidget);
      expect(k('insightsOpen'), findsOneWidget);
      expect(k('searchOpen'), findsOneWidget);
      await tapKey(tester, 'budgetSpending');
      expect(w.wc.budgetView, 'spending');
      await tapKey(tester, 'budgetTags');
      expect(w.wc.budgetView, 'tags');
      await tapKey(tester, 'budgetExplore');
      expect(w.wc.budgetView, 'explore');
      await settle(tester);
    }, timeout: _timeout);

    for (final mode in Brightness.values) {
      for (final (w, scale) in [(320.0, 2.0), (360.0, 1.0), (1280.0, 1.0)]) {
        testWidgets('layout ${mode.name} $w dp at text $scale', (tester) async {
          final x = await exploreWallet();
          await pumpScreen(tester, ExploreScreen(wc: x.wc), size: Size(w, 14000), scale: scale, mode: mode);
          await tapKey(tester, 'exploreRange:All');
          await tester.tapAt(tester.getTopLeft(k('exploreChartArea')) + Offset(w / 2, 100));
          await tester.pump();
          expect(k('exploreChart'), findsOneWidget);
          expect(k('exploreTable'), findsOneWidget);
          expect(k('exploreHeat'), findsOneWidget);
          expect(k('exploreViews'), findsOneWidget);
          if (w >= 980) {
            // the side panel sits beside the chart
            expect(tester.getTopLeft(k('exploreHeat')).dx, greaterThan(tester.getTopRight(k('exploreChart')).dx));
          } else {
            expect(tester.getTopLeft(k('exploreHeat')).dy, greaterThan(tester.getBottomLeft(k('exploreTable')).dy - 1));
          }
          expect(tester.takeException(), isNull);
          await settle(tester);
        }, timeout: _timeout);
      }
    }
  });

  group('project screen', () {
    testWidgets('total = rows = by main tag = by year; the nudge counts untagged payments at the same places', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      final s = wc.projectOf(w.reno);
      expect(s.isEmpty, isFalse);
      // the tagged rows are two bank rows and the paint payment
      final rows = wc.txs.where((t) => w.tagged.contains(t.tx.id)).toList();
      final sum = rows.fold<int>(0, (a, t) => a - t.amount);
      expect(s.total, sum);
      expect(s.byMainTag.fold<int>(0, (a, p) => a + p.$2), sum);
      expect(s.byYear.fold<int>(0, (a, p) => a + p.$2), sum);
      expect(s.running.last.$2, sum);
      // candidates: the untagged KONZUM rows only; none carries the tag, none is a transfer
      final candidateIds = s.candidates.map((t) => t.id).toSet();
      expect(candidateIds.intersection(w.tagged.toSet()), isEmpty);
      expect(s.candidates.length, 2);
      await pumpScreen(tester, ProjectScreen(wc: wc, tag: w.reno), size: const Size(900, 3000));
      expect((tester.widget(k('projectTotal')) as Text).data, moneyExact(sum, wc.currency));
      expect(find.textContaining('3 payments'), findsOneWidget);
      // the year chip shows that year's total
      final y = s.byYear.firstWhere((y) => y.$2 > 0);
      await tapKey(tester, 'projectYear:${y.$1}');
      expect((tester.widget(k('projectYearText')) as Text).data, '${y.$1}: ${moneyExact(y.$2, wc.currency)}');
      // the split rows add up to the total
      var parts = 0;
      for (var i = 0; i < s.byMainTag.length; i++) {
        final text = tester
            .widgetList<Text>(find.descendant(of: k('projectPart:$i'), matching: find.byType(Text)))
            .map((t) => t.data)
            .whereType<String>()
            .last;
        expect(text, moneyExact(s.byMainTag[i].$2, wc.currency));
        parts += s.byMainTag[i].$2;
      }
      expect(parts, s.total);
      expect(find.text("2 payments at the same places aren't tagged yet."), findsOneWidget);
    }, timeout: _timeout);

    testWidgets('review: Skip and Tag per row, Tag all with Undo', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      await pumpScreen(tester, ProjectScreen(wc: wc, tag: w.reno), size: const Size(900, 3000));
      await tapKey(tester, 'projectReview');
      final c = wc.projectOf(w.reno).candidates;
      expect(k('candidate:${c[0].id}'), findsOneWidget);
      // Skip the first: it leaves the list for now and is not tagged
      await tapKey(tester, 'projectSkip:${c[0].id}');
      expect(wc.txs.firstWhere((t) => t.tx.id == c[0].id).tags, isEmpty);
      expect(k('candidate:${c[0].id}'), findsNothing);
      expect(find.text("1 payment at the same places isn't tagged yet."), findsOneWidget);
      await settle(tester);
      // Tag the other with Tag all
      final before = wc.projectOf(w.reno).total;
      await tapKey(tester, 'projectTagAll');
      expect(wc.projectOf(w.reno).candidates.map((t) => t.id), [c[0].id], reason: 'only the skipped one is still untagged');
      expect(wc.projectOf(w.reno).total, before - c[1].amount, reason: 'the tagged payment now counts');
      expect(wc.txs.firstWhere((t) => t.tx.id == c[1].id).tags, contains(w.reno));
      // Undo takes the tag off again
      await tester.tap(k('toastUndo'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(wc.txs.firstWhere((t) => t.tx.id == c[1].id).tags, isNot(contains(w.reno)));
      await settle(tester);
    }, timeout: _timeout);

    testWidgets('an empty project and an overlap note', (tester) async {
      final w = await exploreWallet();
      final wc = w.wc;
      final other = await wc.repo.addTag('Gift');
      wc.reload();
      await pumpScreen(tester, ProjectScreen(wc: wc, tag: other), size: const Size(900, 1200));
      expect(k('projectEmpty'), findsOneWidget);
      // Gift on one of Reno's payments: Reno shows the overlap
      await wc.repo.setTxTag(w.tagged.last, other, true);
      wc.reload();
      await pumpScreen(tester, ProjectScreen(wc: wc, tag: w.reno), size: const Size(900, 3000));
      expect(find.textContaining('Also tagged #Gift on 1 payment.'), findsOneWidget);
    }, timeout: _timeout);

    for (final mode in Brightness.values) {
      for (final (w, scale) in [(320.0, 2.0), (360.0, 1.0), (840.0, 1.0)]) {
        testWidgets('layout ${mode.name} $w dp at text $scale', (tester) async {
          final x = await exploreWallet();
          await pumpScreen(tester, ProjectScreen(wc: x.wc, tag: x.reno), size: Size(w, 5000), scale: scale, mode: mode);
          await tapKey(tester, 'projectReview');
          expect(k('projectCandidates'), findsOneWidget);
          expect(k('projectRunning'), findsOneWidget);
          expect(k('projectSplit'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }, timeout: _timeout);
      }
    }
  });
}

/// The index of the series chip whose label is [name].
int _seriesIndexOf(WidgetTester t, String name) {
  for (var i = 0; i < 6; i++) {
    final f = find.descendant(of: find.byKey(ValueKey('series:$i')), matching: find.text(name));
    if (f.evaluate().isNotEmpty) return i;
  }
  return 0;
}
