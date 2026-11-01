// The dashboard kit (RX2, lib/src/widgets/dash.dart): no overflow at 320 dp x 2.0, 360 and 1280, light and dark; exact cents;
// states in icon + word; grid columns per width; semantics. SYNTHETIC numbers. Real Plex fonts (the test font is far wider).
import 'dart:io';

import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/dash_gallery.dart';
import 'support/layout.dart';

Future<void> _loadFonts() async {
  for (final (fam, prefix) in [('Inter', 'Inter'), ('IBM Plex Mono', 'IBMPlexMono')]) {
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
          await withErrors((errors) async {
            await _pump(tester, const DashGallery(), size: e.value.$1, scale: e.value.$2, mode: mode);
            await scrollThrough(tester);
            expect(tester.takeException(), isNull);
            errors.check();
          });
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
      await withErrors((errors) async {
        await _pump(tester, _gridOf(const StatTile(label: 'Held', value: '123,456,789.01 €')), size: const Size(320, 600), scale: 2);
        final tile = tester.getRect(find.byType(Tile));
        final fit = tester.getRect(find.byType(FittedBox));
        expect(fit.right, lessThanOrEqualTo(tile.right));
        expect(find.text('123,456,789.01 €'), findsOneWidget);
        errors.check();
      });
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
        (Icons.error_outline, '12 % vs avg'), // a bad direction has a second cue
        (Icons.arrow_drop_up, '4 %'),
        (Icons.check_circle_outline, '4 %'), // a good one too
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
        expect(find.text(w), findsNWidgets(2)); // the strip and the weekday calendar
      }
      expect(find.byIcon(Icons.flag), findsNWidgets(2)); // the payday cells
    });
  });

  group('DashGrid', () {
    testWidgets('1 column at 320 x 2.0, 2 at 360, 2 at 700 (medium), 4 at 1280', (tester) async {
      Future<int> columns(Size size, double scale) async {
        await _pump(tester, _grid(8), size: size, scale: scale);
        return {for (var i = 0; i < 8; i++) _rect(tester, 't$i').left.round()}.length;
      }

      expect(await columns(const Size(320, 700), 2.0), 1);
      expect(await columns(const Size(320, 700), 1.0), 2);
      expect(await columns(const Size(360, 800), 2.0), 1);
      expect(await columns(const Size(360, 800), 1.0), 2);
      expect(await columns(const Size(700, 800), 1.0), 2);
      expect(await columns(const Size(1280, 800), 1.0), 4);
    });

    test('columnsFor table: the minimum scales with the text', () {
      int cols(double width, double window, double scale) =>
          DashGrid.columnsFor(width, window, minColumn: DashGrid.minColumnFor(TextScaler.linear(scale)));
      expect(cols(288, 320, 1), 2); // 139 dp each
      expect(cols(288, 320, 2), 1); // 260 dp needed
      expect(cols(328, 360, 1), 2);
      expect(cols(328, 360, 2), 1);
      expect(cols(568, 600, 2), 2); // 279 dp each
      expect(cols(1008, 1040, 1), 4);
      expect(cols(520, 1040, 1), 2); // an expanded window with a narrow pane drops to 2
      expect(cols(200, 1040, 1), 1);
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
    testWidgets('14 dp radius, no border, surface ground, soft shadow', (tester) async {
      await _pump(tester, _grid(1));
      final mat = tester.widget<Material>(find.descendant(of: find.byType(Tile), matching: find.byType(Material)).first);
      final shape = mat.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(14));
      expect(shape.side, BorderSide.none);
      expect(mat.color, WalletColors.light.surface);
      expect(mat.elevation, 0);
      final deco = tester.widget<DecoratedBox>(find
          .descendant(of: find.byType(Tile), matching: find.byWidgetPredicate((w) => w is DecoratedBox && w.decoration is BoxDecoration))
          .first);
      expect((deco.decoration as BoxDecoration).boxShadow, isNotEmpty);
    });

    testWidgets('a tap calls onTap; the gallery hero, goal and add tiles answer', (tester) async {
      final taps = <String>[];
      await _pump(tester, DashGallery(onTap: taps.add), size: const Size(1280, 2800));
      await tester.tap(find.byKey(const ValueKey('hero')));
      await tester.tap(find.text('HOLIDAY'));
      await tester.tap(find.text('Goal'));
      expect(taps, ['hero', 'goal', 'add']);
    });
  });

  group('semantics', () {
    testWidgets('a stat tile reads as one sentence: label, figure, sub, state', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const DashGallery(), size: const Size(1280, 2800));
      final node = tester.getSemantics(find.byKey(const ValueKey('hero')));
      expect(node.label,
          'Left to spend, 1,320.47 €, ${_m(4126)} a day for 32 days, On pace, 20 days within, 4 over, 52 % of the money used, 68 % of the period gone');
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('chips are spoken with the tile; plain tiles are not buttons', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const DashGallery(), size: const Size(1280, 2800));
      final spent = tester.getSemantics(find.ancestor(of: find.text('SPENT TODAY'), matching: find.byType(Tile)).first);
      expect(spent.label, 'Spent today, ${_m(3890)}, Most: groceries, 30 Oct, up 12 % vs avg, worse');
      expect(spent.flagsCollection.isButton, isFalse);
      handle.dispose();
    });

    testWidgets('ring, split bar, donut, net bars, calendar and add tile have spoken labels', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const DashGallery(), size: const Size(1280, 2800));
      expect(find.bySemanticsLabel(RegExp('Fixed .*, Saved .*, Spending .*')), findsNWidgets(2)); // donut and split bar
      expect(find.bySemanticsLabel(RegExp(r'Oct kept .* so far')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Until payday: bills')), findsOneWidget);
      expect(find.bySemanticsLabel('Add Goal'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Holiday, 62 %')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Eating out, .*, Over by')), findsOneWidget);
      handle.dispose();
    });
  });

  group('RX2b additions', () {
    testWidgets('DeltaChip: a second cue and a spoken better/worse, neutral has none', (tester) async {
      const good = DeltaChip(trend: Trend.down, text: '5 %', good: true);
      const bad = DeltaChip(trend: Trend.up, text: '5 %', good: false);
      const flat = DeltaChip(trend: Trend.flat, text: 'same');
      expect(good.spoken, 'down 5 %, better');
      expect(bad.spoken, 'up 5 %, worse');
      expect(flat.spoken, 'unchanged same');
      await _pump(tester, const Column(children: [good, bad, flat]));
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsOneWidget);
    });

    testWidgets('StatTile: the visual is spoken and not tappable; the tile answers a tap on it', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await _pump(
        tester,
        _gridOf(StatTile(
          label: 'Left',
          value: '5.00 €',
          visual: const Sparkline(values: [1, 2, 3]),
          visualSpoken: 'Rising',
          onTap: () => taps++,
        )),
      );
      await tester.tap(find.byType(Sparkline));
      expect(taps, 1);
      expect(tester.getSemantics(find.byType(Tile)).label, 'Left, 5.00 €, Rising');
      handle.dispose();
    });

    testWidgets('DashRows: a tappable row is at least 48 dp high', (tester) async {
      await _pump(tester, DashRows(rows: [DashRowData(title: 'Rent', onTap: () {}), const DashRowData(title: 'Phone')]));
      expect(tester.getSize(find.byType(InkWell).first).height, greaterThanOrEqualTo(48));
    });

    testWidgets('StatTile.trailing sits in the label row and is spoken; a TileAction is a button of its own', (tester) async {
      var edits = 0;
      await _pump(
        tester,
        _gridOf(StatTile(label: 'Plan', value: '1 €', trailing: TileAction(label: 'Edit', onTap: () => edits++))),
      );
      expect(tester.getCenter(find.text('PLAN')).dy, closeTo(tester.getCenter(find.text('Edit')).dy, 30));
      await tester.tap(find.text('Edit'));
      expect(edits, 1);

      final handle = tester.ensureSemantics();
      await _pump(tester, _gridOf(const StatTile(label: 'Spent', value: '2 €', trailing: TileNote('30 Oct'))));
      expect(find.text('30 Oct'), findsOneWidget);
      expect(tester.getSemantics(find.byType(Tile)).label, 'Spent, 2 €, 30 Oct');
      handle.dispose();
    });

    testWidgets('RingTile.compact: a 44 dp ring beside the value and a shorter tile', (tester) async {
      Future<double> height(bool compact) async {
        await _pump(
          tester,
          _gridOf(RingTile(
            key: const ValueKey('r'),
            label: 'Goal',
            center: '40 %',
            value: '400.00 €',
            sub: 'of 1,000 €',
            progress: 0.4,
            compact: compact,
          )),
          size: const Size(360, 800),
        );
        return tester.getSize(find.byKey(const ValueKey('r'))).height;
      }

      final big = await height(false);
      final small = await height(true);
      expect(small, lessThan(big - 30));
      expect(tester.getSize(find.byType(Ring)).width, 44);
      expect(find.text('400.00 €'), findsOneWidget);
    });

    testWidgets('Tile.attention: a 2 px accent border and "Needs action" for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const Padding(padding: EdgeInsets.all(16), child: Tile(attention: true, semanticLabel: 'Laptop goal', child: Text('x'))),
      );
      final material = tester.widget<Material>(find.descendant(of: find.byType(Tile), matching: find.byType(Material)).first);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.width, 2);
      expect(shape.side.color, WalletColors.light.accent);
      expect(tester.getSemantics(find.byType(Tile)).label, 'Needs action: Laptop goal');
      handle.dispose();
    });

    testWidgets('CalendarStrip in weekday columns: Monday first, amounts under the number', (tester) async {
      await _pump(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: CalendarStrip(startWeekday: 5, days: [
            CalDay('30', today: true),
            CalDay('31', kind: CalKind.bill, amount: '550'),
            CalDay('1'),
            CalDay('2', kind: CalKind.bill, amount: '84.20'),
          ]),
        ),
      );
      expect(find.text('M'), findsOneWidget);
      expect(find.text('S'), findsNWidgets(2));
      final friday = tester.getCenter(find.text('30')), sat = tester.getCenter(find.text('31')), mon = tester.getCenter(find.text('2'));
      expect(sat.dx, greaterThan(friday.dx));
      expect(mon.dx, lessThan(friday.dx)); // a new row, back at the first column
      expect(mon.dy, greaterThan(friday.dy));
      expect(find.text('550'), findsOneWidget);
      expect(tester.getCenter(find.text('550')).dy, greaterThan(sat.dy));
    });

    testWidgets('DashItem.rowSpan: a 2x2 hero on four columns, the next tiles fill beside it; ignored where it fills the row',
        (tester) async {
      Widget grid() => Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: DashGrid(children: [
                const DashItem(span: 2, rowSpan: 2, child: StatTile(key: ValueKey('hero'), label: 'Hero', value: '1 €')),
                for (var i = 1; i <= 5; i++) StatTile(key: ValueKey('t$i'), label: 'Tile $i', value: '$i €'),
              ]),
            ),
          );
      await _pump(tester, grid(), size: const Size(1280, 800));
      final hero = _rect(tester, 'hero'), t1 = _rect(tester, 't1'), t3 = _rect(tester, 't3'), t5 = _rect(tester, 't5');
      expect(t1.left, greaterThan(hero.right - 1));
      expect(_rect(tester, 't2').top, t1.top);
      expect(t3.top, greaterThan(t1.bottom)); // the second row beside the hero
      expect(t3.left, t1.left);
      expect(hero.height, closeTo(t3.bottom - t1.top, 0.5));
      expect(t5.top, greaterThan(hero.bottom)); // below the hero

      await _pump(tester, grid(), size: const Size(360, 800)); // two columns: the hero fills its row, one row high
      expect(_rect(tester, 't1').top, greaterThan(_rect(tester, 'hero').bottom));
    });

    testWidgets('HeroTile: exact figure in a FittedBox, chip, dots slot and a pace meter, one spoken sentence', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: HeroTile(
            key: ValueKey('h'),
            label: 'Left',
            value: '1,320.47 €',
            chip: StateChip.over(),
            dots: SizedBox(key: ValueKey('dotsSlot'), height: 20, width: 40),
            dotsWidth: 40,
            dotsSpoken: '3 over',
            paceUsed: 0.8,
            paceExpected: 0.5,
            paceOver: true,
            paceSpoken: '80 % used',
          ),
        ),
        size: const Size(320, 700),
        scale: 2,
      );
      expect(find.text('1,320.47 €'), findsOneWidget);
      expect(find.ancestor(of: find.text('1,320.47 €'), matching: find.byType(FittedBox)), findsOneWidget);
      expect(find.byKey(const ValueKey('dotsSlot')), findsOneWidget);
      expect(find.byType(PaceMeter), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const ValueKey('h'))).label, 'Left, 1,320.47 €, Over, 3 over, 80 % used');
      // 320 dp at text scale 2.0: the slot does not fit beside the figure, so it sits under it.
      final slot = tester.getRect(find.byKey(const ValueKey('dotsSlot')));
      expect(slot.top, greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('h'))).top + 40));
      handle.dispose();
    });

    testWidgets('HeroTile: the dots slot sits beside the figure when it fits (360 dp), under it when it does not (320 dp at 2.0)',
        (tester) async {
      Widget hero() => const Padding(
            padding: EdgeInsets.all(16),
            child: HeroTile(
              label: 'Left',
              value: '132.04 €',
              valueKey: ValueKey('v'),
              dots: SizedBox(key: ValueKey('dotsSlot'), height: 20, width: 100),
              dotsWidth: 100,
            ),
          );
      await _pump(tester, hero(), size: const Size(360, 700));
      expect(tester.getRect(find.byKey(const ValueKey('dotsSlot'))).left,
          greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('v'))).right));
      await _pump(tester, hero(), size: const Size(320, 700), scale: 2);
      expect(tester.getRect(find.byKey(const ValueKey('dotsSlot'))).top,
          greaterThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('v'))).bottom));
      expect(tester.takeException(), isNull);
    });

    test('HeroTile: dots without a width is refused', () {
      expect(() => HeroTile(label: 'a', value: 'b', dots: const SizedBox()), throwsAssertionError);
      expect(() => HeroTile(label: 'a', value: 'b', dots: const SizedBox(), dotsWidth: 10, dotsCompact: const SizedBox()),
          throwsAssertionError);
    });

    test('BarRow: over comes from the fraction; a number that is not finite counts as 0', () {
      expect(const BarRow(label: 'a', value: '1', note: 'n', fraction: 1.24).over, isTrue);
      expect(const BarRow(label: 'a', value: '1', note: 'n', fraction: 1).over, isFalse);
      for (final f in <double>[double.nan, double.infinity, double.negativeInfinity, -2]) {
        final r = BarRow(label: 'a', value: '1', note: 'n', fraction: f);
        expect(r.ratio, 0, reason: '$f');
        expect(r.over, isFalse, reason: '$f');
      }
      expect(const DashSegment(label: 'a', value: '1', weight: double.nan, color: Colors.red).share, 0);
      expect(const DashSegment(label: 'a', value: '1', weight: -3, color: Colors.red).share, 0);
    });

    testWidgets('an over meter is hatched beyond the budget mark and carries the warning icon', (tester) async {
      await _pump(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: BarList(rows: [BarRow(label: 'a', value: '1', note: 'Over by 1', fraction: 1.25)]),
        ),
      );
      final hatch = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HatchPainter);
      expect(find.descendant(of: find.byType(BarList), matching: hatch), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      // The hatch starts at 1/1.25 = 80 % of the bar.
      final bar = tester.getRect(find.descendant(of: find.byType(BarList), matching: find.byType(ClipRRect)));
      final hatchRect = tester.getRect(hatch);
      expect(hatchRect.left, closeTo(bar.left + bar.width * 0.8, 1));
    });

    testWidgets('NetBars shows the preformatted value of every bar', (tester) async {
      await _pump(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: NetBars(bars: [NetBar(label: 'Jun', value: '210.50 €', cents: 21050), NetBar(label: 'Jul', value: '−80 €', cents: -8000)]),
        ),
      );
      expect(find.text('210.50 €'), findsOneWidget);
      expect(find.text('−80 €'), findsOneWidget);
    });

    testWidgets('non-finite numbers never break a drawing', (tester) async {
      await withErrors((errors) async {
        await _pump(
          tester,
          const SingleChildScrollView(
            child: Column(children: [
              Ring(progress: double.nan),
              SplitBar(segments: [
                DashSegment(label: 'A', value: '1', weight: double.nan, color: Colors.red),
                DashSegment(label: 'B', value: '2', weight: 2, color: Colors.blue),
              ]),
              Donut(segments: [DashSegment(label: 'A', value: '1', weight: double.infinity, color: Colors.red)]),
              BarList(rows: [
                BarRow(label: 'a', value: '1', note: 'n', fraction: double.nan),
                BarRow(label: 'b', value: '1', note: 'n', fraction: double.infinity),
              ]),
              PaceMeter(used: double.nan, expected: double.infinity),
              CalendarStrip(days: [], startWeekday: 3),
            ]),
          ),
        );
        expect(tester.takeException(), isNull);
        errors.check();
      });
    });
  });

  group('edge cases', () {
    testWidgets('empty and zero data draw nothing wrong', (tester) async {
      await withErrors((errors) async {
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
              NetBars(bars: []),
              NetBars(bars: [NetBar(label: 'Jan', value: '0 €', cents: 0), NetBar(label: 'Feb', value: '0 €', cents: 0)]),
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
    });

    testWidgets('long labels and a long row title wrap, they do not overflow', (tester) async {
      await withErrors((errors) async {
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

    testWidgets('TileInfo can be activated by a screen reader: a tap action on its node', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await _pump(tester, Center(child: TileInfo(onTap: () => taps++)));
      final node = find.semantics.byLabel('What is this?');
      expect(node, findsOneWidget);
      expect(node.evaluate().single.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(node);
      await tester.pump();
      expect(taps, 1);
      handle.dispose();
    });
  });
}

Widget _gridOf(Widget tile) => Padding(padding: const EdgeInsets.all(16), child: DashGrid(children: [tile]));
