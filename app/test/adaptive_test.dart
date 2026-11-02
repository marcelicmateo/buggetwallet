// Adaptive layout at four window sizes (phone, tablet, laptop, big desktop) and two text scales: the bar or the rail,
// content width, no overflow on any tab, page State kept across tab switches and resizes, Today's columns, sheets as
// dialogs and the keyboard shortcuts. More edge cases: adaptive_edge_test.dart. All data is SYNTHETIC.
import 'package:budget_wallet/src/layout.dart';
import 'package:budget_wallet/src/screens/plan_screen.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

const _sizes = <Size>[Size(360, 800), Size(800, 1280), Size(1280, 800), Size(1920, 1080)];
const _tabs = ['Budget', 'Bills', 'Save', 'Settings', 'Today'];

LayoutSize _kind(Size s) => sizeFor(s.width);

void main() {
  test('sizeFor: 600 and 1024 are the boundaries', () {
    expect(<double>[0, 320, 599.9].map(sizeFor), everyElement(LayoutSize.compact));
    expect(<double>[600, 800, 1023.9].map(sizeFor), everyElement(LayoutSize.medium));
    expect(<double>[1024, 1920, 4000].map(sizeFor), everyElement(LayoutSize.expanded));
  });

  for (final size in _sizes) {
    for (final scale in [1.0, 1.5]) {
      final name = '${size.width.toInt()}x${size.height.toInt()} text $scale';

      testWidgets('$name: the right navigation and a centered content column', (tester) async {
        await pumpFull(tester, demoWallet(clock: pinnedNoon), scale, size: size);
        final kind = _kind(size);
        expect(find.byKey(const ValueKey('navBar')), kind == LayoutSize.compact ? findsOneWidget : findsNothing);
        expect(find.byKey(const ValueKey('rail')), kind == LayoutSize.compact ? findsNothing : findsOneWidget);
        if (kind != LayoutSize.compact) {
          expect(tester.getSize(find.byKey(const ValueKey('rail'))).width > 200, kind == LayoutSize.expanded);
        }
        final box = tester.getRect(find.byType(TodayScreen));
        final railRight = kind == LayoutSize.compact ? 0.0 : tester.getRect(find.byKey(const ValueKey('rail'))).right;
        expect(box.width, lessThanOrEqualTo(maxContentWidth(kind)));
        expect(box.left - railRight, closeTo(size.width - box.right, 1.0), reason: 'centered');
        // The labels are there (perf_test and screens find tabs by label).
        for (final t in ['Overview', 'Money', 'Explore', 'Plan']) {
          expect(find.descendant(of: find.byKey(ValueKey(kind == LayoutSize.compact ? 'navBar' : 'rail')), matching: find.text(t)),
              findsOneWidget);
        }
      });

      testWidgets('$name: every tab scrolls through without an error', (tester) async {
        await withErrors((errors) async {
          await pumpFull(tester, demoWallet(clock: pinnedNoon), scale, size: size);
          await scrollThrough(tester);
          for (final tab in _tabs) {
            await tapTab(tester, tab);
            await scrollThrough(tester);
          }
          // The Pay-period report (RX7), opened from the period chip (bar) or badge (rail).
          final chip = find.byKey(const ValueKey('periodChip')), badge = find.byKey(const ValueKey('periodBadgeTap'));
          await tester.tap(chip.evaluate().isNotEmpty ? chip : badge);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byKey(const ValueKey('reportKept')), findsOneWidget);
          await scrollThrough(tester);
          errors.check();
        });
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name: a tap shows the page and the other pages keep their State', (tester) async {
        await pumpFull(tester, demoWallet(clock: pinnedNoon), scale, size: size);
        final plan = tester.state(find.byType(SettingsScreen, skipOffstage: false));
        final spending = tester.state(find.byType(SpendingScreen, skipOffstage: false));
        for (final tab in ['Settings', 'Budget', 'Settings', 'Today']) {
          await tapTab(tester, tab);
        }
        expect(find.byType(TodayScreen), findsOneWidget); // onstage
        await tapTab(tester, 'Settings');
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(find.byType(TodayScreen), findsNothing);
        expect(identical(tester.state(find.byType(SettingsScreen, skipOffstage: false)), plan), isTrue);
        expect(identical(tester.state(find.byType(SpendingScreen, skipOffstage: false)), spending), isTrue);
      });
    }
  }

  testWidgets('resizing 360 -> 1280 -> 360 keeps the pages and their State', (tester) async {
    await pumpFull(tester, demoWallet(clock: pinnedNoon), 1.0, size: const Size(360, 800));
    final plan = tester.state(find.byType(SettingsScreen, skipOffstage: false));
    final spending = tester.state(find.byType(SpendingScreen, skipOffstage: false));
    final todayWidget = tester.widget(find.byType(TodayScreen, skipOffstage: false));
    for (final s in const [Size(1280, 800), Size(800, 1280), Size(360, 800)]) {
      tester.view.physicalSize = s;
      await tester.pump();
      expect(identical(tester.state(find.byType(SettingsScreen, skipOffstage: false)), plan), isTrue, reason: 'Settings at $s');
      expect(identical(tester.state(find.byType(SpendingScreen, skipOffstage: false)), spending), isTrue, reason: 'Spending at $s');
      expect(identical(tester.widget(find.byType(TodayScreen, skipOffstage: false)), todayWidget), isTrue, reason: 'Today at $s');
    }
    expect(tester.takeException(), isNull);
  });

  group('Today columns', () {
    Rect rectOf(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

    testWidgets('1200: four tile columns, the hero is one short row across all of them', (tester) async {
      await pumpFull(tester, demoWallet(clock: pinnedNoon), 1.0, size: const Size(1200, 800));
      final hero = rectOf(tester, 'heroTile');
      final tiles = find.byType(Tile);
      final rects = [for (var i = 0; i < tiles.evaluate().length; i++) tester.getRect(tiles.at(i))];
      // A two-cell tile (setup) is half the hero, which spans four cells. (Number tiles can be stretched to fill a row.)
      expect(rectOf(tester, 'setupPanel').width, lessThan(hero.width * 0.6), reason: 'four columns');
      expect(rects.where((r) => r != hero && r.top < hero.bottom - 1), isEmpty, reason: 'nothing beside the hero');
      expect(hero.height, lessThan(hero.width / 3));
    });

    testWidgets('800: two tile columns, the hero spans both and the number tiles sit below it', (tester) async {
      await pumpFull(tester, demoWallet(clock: pinnedNoon), 1.0, size: const Size(800, 1280));
      final hero = rectOf(tester, 'heroTile'), left = rectOf(tester, 'leftTile'), pay = rectOf(tester, 'paydayTile');
      expect(left.top, greaterThanOrEqualTo(hero.bottom - 1));
      expect((left.top - pay.top).abs(), lessThan(2), reason: 'two tiles side by side');
      expect(pay.left, greaterThan(left.right - 1));
    });
  });

  group('showSheet', () {
    Future<void> open(WidgetTester tester, Size size, void Function(Future<String?>) got) async {
      await pumpApp(
          tester,
          Builder(
              builder: (context) => Scaffold(
                  body: Center(
                      child: ElevatedButton(
                          onPressed: () => got(showSheet<String>(
                              context,
                              Builder(
                                  builder: (ctx) =>
                                      TextButton(onPressed: () => Navigator.of(ctx).pop('done'), child: const Text('Finish'))))),
                          child: const Text('Open'))))),
          size: size);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('360: a bottom sheet that pops its result', (tester) async {
      Future<String?>? r;
      await open(tester, const Size(360, 800), (f) => r = f);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(await r, 'done');
    });

    testWidgets('800: a dialog with a close button that pops its result, or null', (tester) async {
      Future<String?>? r;
      await open(tester, const Size(800, 1280), (f) => r = f);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byTooltip('Close'), findsOneWidget);
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(await r, 'done');

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(await r, isNull);
    });
  });

  group('keyboard', () {
    Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('Ctrl+1..4 switch destinations, Ctrl+, Settings, Ctrl+N opens Add expense', (tester) async {
      await pumpFull(tester, demoWallet(clock: pinnedNoon), 1.0, size: const Size(1280, 800));
      await tester.pump();
      await ctrl(tester, LogicalKeyboardKey.digit4);
      expect(find.byType(PlanScreen), findsOneWidget);
      await ctrl(tester, LogicalKeyboardKey.digit3);
      expect(find.byType(SpendingScreen), findsOneWidget);
      await ctrl(tester, LogicalKeyboardKey.comma);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await ctrl(tester, LogicalKeyboardKey.digit1);
      expect(find.byType(TodayScreen), findsOneWidget);
      await ctrl(tester, LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.byType(AddExpenseSheet), findsOneWidget);
    });

    testWidgets('a plain "1" is not a shortcut: the Plan field keeps its focus and the tab stays', (tester) async {
      await pumpFull(tester, demoWallet(clock: pinnedNoon), 1.0, size: const Size(1280, 800));
      await tapTab(tester, 'Plan'); // the payday plan is on Plan
      await openPlanEdit(tester, 'rent');
      final field = find.widgetWithText(TextField, 'Rent');
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.enterText(field, '1');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(find.byType(PlanScreen), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, '1');
    });
  });
}
