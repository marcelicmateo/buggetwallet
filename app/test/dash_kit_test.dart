// The dashboard kit (RX2, lib/src/widgets/dash.dart): no overflow at 320 dp x 2.0, 360 and 1280, light and dark; exact cents;
// states in icon + word; grid columns per width; semantics. SYNTHETIC numbers. Real Plex fonts (the test font is far wider).
import 'dart:io';

import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/dash_gallery.dart';
import 'support/layout.dart';

Future<void> _loadFonts() async {
  for (final (fam, prefix) in [('IBM Plex Sans', 'IBMPlexSans'), ('IBM Plex Mono', 'IBMPlexMono')]) {
    final l = FontLoader(fam);
    for (final w in ['Regular', 'Medium', 'SemiBold']) {
      l.addFont(File('assets/fonts/$prefix-$w.ttf').readAsBytes().then(ByteData.sublistView));
    }
    await l.load();
  }
}

Future<void> _pump(WidgetTester tester, Widget child,
    {Size size = const Size(360, 800), double scale = 1, Brightness mode = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: child),
  ));
  await tester.pump();
}

/// [n] one-number tiles (keys t0..), those in [wideAt] spanning 2 columns.
Widget _grid(int n, {Set<int> wideAt = const {}}) => Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: DashGrid(children: [
          for (var i = 0; i < n; i++)
            DashItem(
                span: wideAt.contains(i) ? 2 : 1,
                child: StatTile(key: ValueKey('t$i'), label: 'Tile $i', value: moneyExact(100 + i, 'EUR'))),
        ]),
      ),
    );

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

String _m(int cents) => moneyExact(cents, 'EUR');

void main() {
  setUpAll(_loadFonts);

  const sizes = {'320 dp x 2.0': (Size(320, 700), 2.0), '360 dp x 1.0': (Size(360, 800), 1.0), '1280 dp x 1.0': (Size(1280, 800), 1.0)};

  group('layout: every component fits', () {
    for (final mode in Brightness.values) {
      for (final e in sizes.entries) {
        testWidgets('${mode.name}, ${e.key}', (tester) async {
          final errors = Errors();
          await _pump(tester, const DashGallery(), size: e.value.$1, scale: e.value.$2, mode: mode);
          await scrollThrough(tester);
          expect(tester.takeException(), isNull);
          errors.check();
          // Nothing is wider than the window (a tile that overflows sideways).
          for (final w in find.byType(Tile).evaluate()) {
            final r = tester.getRect(find.byElementPredicate((x) => x == w));
            expect(r.right, lessThanOrEqualTo(e.value.$1.width + 0.5));
          }
        });
      }
    }
  });

  group('exact cents', () {
    testWidgets('the hero shows 1,320.47 € whole at every size, scaled and never rounded', (tester) async {
      for (final e in sizes.entries) {
        await _pump(tester, const DashGallery(), size: e.value.$1, scale: e.value.$2);
        expect(find.text('1,320.47 €'), findsOneWidget, reason: e.key);
        expect(find.text('1,320 €'), findsNothing, reason: e.key);
        expect(find.text('4,210.05 €'), findsOneWidget, reason: e.key);
        // A FittedBox holds the figure: it never wraps.
        final fit = find.ancestor(of: find.text('1,320.47 €'), matching: find.byType(FittedBox));
        expect(fit, findsOneWidget);
        expect(find.descendant(of: fit, matching: find.byType(Text)), findsOneWidget);
      }
    });

    testWidgets('a huge amount scales down inside its tile instead of overflowing', (tester) async {
      final errors = Errors();
      await _pump(tester, _gridOf(const StatTile(label: 'Held', value: '123,456,789.01 €')), size: const Size(320, 600), scale: 2);
      final tile = tester.getRect(find.byType(Tile));
      final fit = tester.getRect(find.byType(FittedBox));
      expect(fit.right, lessThanOrEqualTo(tile.right));
      expect(find.text('123,456,789.01 €'), findsOneWidget);
      errors.check();
    });
  });

  group('states are icon + word', () {
    testWidgets('chips', (tester) async {
      await _pump(tester, const DashGallery(), size: const Size(1280, 800));
      for (final (icon, word) in [
        (Icons.check, 'On pace'),
        (Icons.warning_amber_rounded, 'Over'),
        (Icons.schedule, '10 Nov'),
        (Icons.lock_outline, 'Held'),
        (Icons.arrow_drop_up, '12 % vs avg'),
        (Icons.arrow_drop_down, '4 % vs last'),
        (Icons.remove, 'same as last'),
      ]) {
        final chip = find.ancestor(of: find.text(word), matching: find.byType(Row)).first;
        expect(find.descendant(of: chip, matching: find.byIcon(icon)), findsOneWidget, reason: word);
      }
    });

    testWidgets('an over budget meter says it with an icon and words, not only red', (tester) async {
      await _pump(tester, const DashGallery(), size: const Size(1280, 800));
      final note = find.text('Over by ${_m(2205)}');
      expect(note, findsOneWidget);
      expect(
          find.descendant(
              of: find.ancestor(of: note, matching: find.byType(Row)).first, matching: find.byIcon(Icons.warning_amber_rounded)),
          findsOneWidget);
      // Within budget: no warning icon on that row.
      final ok = find.text('${_m(4800)} left');
      expect(
          find.descendant(of: find.ancestor(of: ok, matching: find.byType(Row)).first, matching: find.byIcon(Icons.warning_amber_rounded)),
          findsNothing);
    });

    testWidgets('the calendar key names bill, planned and payday', (tester) async {
      await _pump(tester, const DashGallery(), size: const Size(1280, 800));
      for (final w in ['Bill', 'Planned', 'Payday']) {
        expect(find.text(w), findsOneWidget);
      }
      expect(find.byIcon(Icons.flag), findsOneWidget); // the payday cell
    });
  });

  group('DashGrid', () {
    testWidgets('1 column at 320 x 2.0, 2 at 360, 2 at 700 (medium), 4 at 1280', (tester) async {
      Future<int> columns(Size size, double scale) async {
        await _pump(tester, _grid(8), size: size, scale: scale);
        return {for (var i = 0; i < 8; i++) _rect(tester, 't$i').left.round()}.length;
      }

      expect(await columns(const Size(320, 700), 2.0), 1);
      expect(await columns(const Size(360, 800), 1.0), 2);
      expect(await columns(const Size(700, 800), 1.0), 2);
      expect(await columns(const Size(1280, 800), 1.0), 4);
    });

    test('columnsFor table', () {
      expect(DashGrid.columnsFor(288, 320), 1);
      expect(DashGrid.columnsFor(328, 360), 2);
      expect(DashGrid.columnsFor(568, 600), 2);
      expect(DashGrid.columnsFor(1008, 1040), 4);
      expect(DashGrid.columnsFor(520, 1040), 2); // an expanded window with a narrow pane drops to 2
      expect(DashGrid.columnsFor(200, 1040), 1);
    });

    testWidgets('same order at every size: row by row, left to right', (tester) async {
      for (final size in const [Size(320, 700), Size(360, 800), Size(1280, 800)]) {
        await _pump(tester, _grid(9), size: size, scale: size.width == 320 ? 2 : 1);
        final rects = [for (var i = 0; i < 9; i++) _rect(tester, 't$i')];
        for (var i = 1; i < 9; i++) {
          final a = rects[i - 1], b = rects[i];
          expect(b.top > a.top - 0.5 && (b.top > a.bottom - 0.5 || b.left > a.left), isTrue, reason: 'tile $i at ${size.width}');
        }
      }
    });

    testWidgets('a wide tile spans 2 columns (and 1 where there is one column); a row is as tall as its tallest tile', (tester) async {
      await _pump(tester, _grid(5, wideAt: {0}), size: const Size(360, 800));
      final wide = _rect(tester, 't0'), a = _rect(tester, 't1'), b = _rect(tester, 't2');
      expect(wide.width, closeTo(a.width * 2 + 10, 0.5));
      expect(a.top, greaterThan(wide.bottom));
      expect(b.left, greaterThan(a.left));
      expect(a.height, b.height);

      await _pump(tester, _grid(5, wideAt: {0}), size: const Size(320, 700), scale: 2);
      expect(_rect(tester, 't0').width, closeTo(_rect(tester, 't1').width, 0.5));

      // 4 columns: the wide tile and two small ones share the first row.
      await _pump(tester, _grid(5, wideAt: {0}), size: const Size(1280, 800));
      final w4 = _rect(tester, 't0');
      expect(_rect(tester, 't1').top, w4.top);
      expect(_rect(tester, 't2').top, w4.top);
      expect(_rect(tester, 't3').top, greaterThan(w4.top));

      // Tiles with different content: stretched to the same height.
      await _pump(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: DashGrid(children: [
            StatTile(key: ValueKey('a'), label: 'One', value: '1 €'),
            StatTile(key: ValueKey('b'), label: 'Two', value: '2 €', sub: 'A longer line that wraps on a narrow tile for sure'),
          ]),
        ),
        size: const Size(360, 800),
      );
      expect(tester.getSize(find.byKey(const ValueKey('a'))).height, tester.getSize(find.byKey(const ValueKey('b'))).height);
    });

    testWidgets('an empty grid and one tile do not fail', (tester) async {
      await _pump(tester, const DashGrid());
      expect(tester.takeException(), isNull);
      await _pump(tester, _grid(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('Tile', () {
    testWidgets('12 dp radius, line border, surface ground, no shadow', (tester) async {
      await _pump(tester, _grid(1));
      final mat = tester.widget<Material>(find.descendant(of: find.byType(Tile), matching: find.byType(Material)).first);
      final shape = mat.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(12));
      expect(shape.side.color, WalletColors.light.line);
      expect(shape.side.width, 1);
      expect(mat.color, WalletColors.light.surface);
      expect(mat.elevation, 0);
    });

    testWidgets('a tap calls onTap; the gallery hero, goal and add tiles answer', (tester) async {
      final taps = <String>[];
      await _pump(tester, DashGallery(onTap: taps.add), size: const Size(1280, 1400));
      await tester.tap(find.byKey(const ValueKey('hero')));
      await tester.tap(find.text('HOLIDAY'));
      await tester.tap(find.text('Goal'));
      expect(taps, ['hero', 'goal', 'add']);
    });
  });

  group('semantics', () {
    testWidgets('a stat tile reads as one sentence: label, figure, sub, state', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const DashGallery(), size: const Size(1280, 1400));
      final node = tester.getSemantics(find.byKey(const ValueKey('hero')));
      expect(node.label, 'Left to spend, 1,320.47 €, ${_m(4126)} a day for 32 days, On pace');
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('chips are spoken with the tile; plain tiles are not buttons', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const DashGallery(), size: const Size(1280, 1400));
      final spent = tester.getSemantics(find.ancestor(of: find.text('SPENT TODAY'), matching: find.byType(Tile)).first);
      expect(spent.label, 'Spent today, ${_m(3890)}, Most: groceries, up 12 % vs avg');
      expect(spent.flagsCollection.isButton, isFalse);
      handle.dispose();
    });

    testWidgets('ring, split bar, donut, net bars, calendar and add tile have spoken labels', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const DashGallery(), size: const Size(1280, 1400));
      expect(find.bySemanticsLabel(RegExp('Fixed .*, Saved .*, Spending .*')), findsNWidgets(2)); // donut and split bar
      expect(find.bySemanticsLabel(RegExp(r'Oct kept .* so far')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Until payday: bills')), findsOneWidget);
      expect(find.bySemanticsLabel('Add Goal'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Holiday, 62 %')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Eating out, .*, Over by')), findsOneWidget);
      handle.dispose();
    });
  });

  group('edge cases', () {
    testWidgets('empty and zero data draw nothing wrong', (tester) async {
      final errors = Errors();
      await _pump(
        tester,
        const SingleChildScrollView(
          child: Column(children: [
            Sparkline(values: []),
            Sparkline(values: [5]),
            Sparkline(values: [3, 3, 3]),
            Ring(progress: 0, child: Text('0 %')),
            Ring(progress: 1.7, child: Text('170 %')),
            Ring(progress: -1),
            SplitBar(segments: []),
            SplitBar(segments: [DashSegment(label: 'A', value: '0 €', weight: 0, color: Colors.red)]),
            Donut(segments: []),
            Donut(segments: [DashSegment(label: 'A', value: '0 €', weight: 0, color: Colors.red)]),
            NetBars(bars: [], currency: 'EUR'),
            NetBars(bars: [NetBar(label: 'Jan', cents: 0), NetBar(label: 'Feb', cents: 0)], currency: 'EUR'),
            CalendarStrip(days: []),
            DashRows(rows: []),
            BarList(rows: []),
          ]),
        ),
        size: const Size(320, 900),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      errors.check();
    });

    testWidgets('long labels and a long row title wrap, they do not overflow', (tester) async {
      final errors = Errors();
      await _pump(
        tester,
        Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: DashGrid(children: [
              const StatTile(
                  label: 'A very long label for a tile',
                  value: '1.00 €',
                  sub: 'And a long sub line that wants three lines or more of room'),
              DashItem(
                span: 2,
                child: Tile(
                  child: DashRows(rows: [
                    DashRowData(
                        title: 'A rather long name of a bill that does not fit on one line',
                        amount: _m(123456),
                        chip: const StateChip.date('1 Nov')),
                  ]),
                ),
              ),
              const AddTile(label: 'A long add label that wraps'),
            ]),
          ),
        ),
        size: const Size(320, 900),
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      errors.check();
    });
  });
}

Widget _gridOf(Widget tile) => Padding(padding: const EdgeInsets.all(16), child: DashGrid(children: [tile]));
