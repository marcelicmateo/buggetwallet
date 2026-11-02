// Today's day dots (DD): one square per day of the pay period, Monday-first columns, counts line, spoken label, wrapping
// under the number on a narrow, large-text screen. SYNTHETIC wallets on the fixed clock of `budgetWallet` (Tuesday 20 Oct 2026).

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/fonts.dart';
import 'support/wallet.dart';

final _light = buildTheme(Brightness.light).extension<WalletColors>()!;

/// 1 Oct 2026 (a Thursday) for [length] days: [within] and [over] past days, then today (when [today]), the rest to come.
List<PeriodDay> _days({int length = 31, int within = 10, int over = 2, bool today = true}) {
  final out = <PeriodDay>[];
  for (var i = 0; i < length; i++) {
    final d = '2026-10-${(i + 1).toString().padLeft(2, '0')}';
    final DayMark m;
    if (i < within) {
      m = DayMark.within;
    } else if (i < within + over) {
      m = DayMark.over;
    } else if (i == within + over && today) {
      m = DayMark.today;
    } else {
      m = DayMark.toCome;
    }
    out.add(PeriodDay(date: d, mark: m));
  }
  return out;
}

Widget _dots(List<PeriodDay> days) => Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: DayDots(days: days)));

BoxDecoration _deco(WidgetTester tester, String date) {
  final box = find.descendant(of: find.byKey(ValueKey('dayDot:$date')), matching: find.byType(DecoratedBox));
  return tester.widget<DecoratedBox>(box.first).decoration as BoxDecoration;
}

Finder get _anyDot => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('dayDot:'));

Offset _at(WidgetTester tester, String date) => tester.getTopLeft(find.byKey(ValueKey('dayDot:$date')));

/// The real Manrope and JetBrains Mono fonts: the hero number's width decides beside or under, and the test font (Ahem) is far wider.
Future<void> _loadFonts() async {
  await loadAppFonts();
}

void main() {
  setUpAll(_loadFonts);

  group('DayDots', () {
    testWidgets('one square per day, none smaller than 10 dp', (tester) async {
      await pumpApp(tester, _dots(_days()));
      expect(_anyDot, findsNWidgets(31));
      for (final i in [1, 15, 31]) {
        final d = '2026-10-${i.toString().padLeft(2, '0')}';
        expect(tester.getSize(find.byKey(ValueKey('dayDot:$d'))).shortestSide, greaterThanOrEqualTo(10));
      }
    });

    testWidgets('Monday-first weekday columns: 1 Oct (Thursday) sits in the fourth column, 5 Oct (Monday) in the first', (tester) async {
      await pumpApp(tester, _dots(_days()));
      final mon = _at(tester, '2026-10-05'), thu = _at(tester, '2026-10-01');
      expect(_at(tester, '2026-10-12').dx, mon.dx);
      expect(_at(tester, '2026-10-08').dx, thu.dx);
      expect(thu.dx - mon.dx, 3 * (DayDots.square + DayDots.gap));
      expect(thu.dy, lessThan(mon.dy), reason: '1 Oct is on the first row, 5 Oct on the second');
      expect(_at(tester, '2026-10-12').dy - mon.dy, DayDots.square + DayDots.gap);
      // The other columns: Tuesday 6 Oct is right of Monday 5 Oct by one step.
      expect(_at(tester, '2026-10-06').dx - mon.dx, DayDots.square + DayDots.gap);
    });

    testWidgets('a month starting on Monday begins in the first column', (tester) async {
      await pumpApp(tester,
          _dots([for (var i = 0; i < 14; i++) PeriodDay(date: '2026-06-${(i + 1).toString().padLeft(2, '0')}', mark: DayMark.toCome)]));
      expect(_at(tester, '2026-06-01').dx, _at(tester, '2026-06-08').dx);
      expect(_at(tester, '2026-06-08').dy - _at(tester, '2026-06-01').dy, DayDots.square + DayDots.gap);
    });

    testWidgets('colours per state: within accent, over bad, today outlined thick, to come thin outline', (tester) async {
      await pumpApp(tester, _dots(_days()));
      expect(_deco(tester, '2026-10-01').color, _light.accent);
      expect(_deco(tester, '2026-10-10').color, _light.accent);
      expect(_deco(tester, '2026-10-11').color, _light.bad);
      expect(_deco(tester, '2026-10-12').color, _light.bad);
      final today = _deco(tester, '2026-10-13');
      expect(today.color, _light.surface, reason: 'today has no verdict: not filled');
      expect((today.border! as Border).top.color, _light.accent);
      expect((today.border! as Border).top.width, greaterThanOrEqualTo(2));
      final later = _deco(tester, '2026-10-14');
      expect(later.color, _light.surface);
      expect((later.border! as Border).top.color, _light.lineStrong);
      expect((later.border! as Border).top.width, lessThan((today.border! as Border).top.width));
      // "over" is also readable without colour: a hatch is painted in it.
      expect(find.descendant(of: find.byKey(const ValueKey('dayDot:2026-10-11')), matching: find.byType(CustomPaint)), findsWidgets);
      expect(find.descendant(of: find.byKey(const ValueKey('dayDot:2026-10-01')), matching: find.byType(CustomPaint)), findsNothing);
    });

    testWidgets('dark theme: within accent, over bad, today outlined, to come thin outline (night colours)', (tester) async {
      final dark = buildTheme(Brightness.dark);
      final w = dark.extension<WalletColors>()!;
      await tester.pumpWidget(MaterialApp(theme: dark, home: _dots(_days())));
      expect(_deco(tester, '2026-10-01').color, w.accent);
      expect(_deco(tester, '2026-10-11').color, w.bad);
      expect((_deco(tester, '2026-10-13').border! as Border).top.color, w.accent);
      expect((_deco(tester, '2026-10-14').border! as Border).top.color, w.lineStrong);
      expect(w.accent, isNot(_light.accent), reason: 'the night palette is really in use');
    });

    testWidgets('counts line: "10 within · 2 over"; absent while both are 0', (tester) async {
      await pumpApp(tester, _dots(_days()));
      expect(tester.widget<Text>(find.byKey(const ValueKey('dayDotsCounts'))).data, '10 within · 2 over');
      await pumpApp(tester, _dots(_days(within: 0, over: 0)));
      expect(find.byKey(const ValueKey('dayDotsCounts')), findsNothing);
      expect(_anyDot, findsNWidgets(31));
    });

    testWidgets('one spoken label for the whole grid', (tester) async {
      final h = tester.ensureSemantics();
      await pumpApp(tester, _dots(_days()));
      expect(tester.getSemantics(find.byKey(const ValueKey('dayDots'))).label,
          'Pay period, 31 days: 10 within the day\'s money, 2 over, today, 18 to come.');
      // The squares and the counts line add nothing of their own.
      expect(find.bySemanticsLabel(RegExp('within')), findsOneWidget);
      h.dispose();
    });

    testWidgets('no saved period start: today first, the rest to come; a start after today: all to come', (tester) async {
      final h = tester.ensureSemantics();
      await pumpApp(tester, _dots(_days(length: 20, within: 0, over: 0)));
      expect(_anyDot, findsNWidgets(20));
      expect(find.byKey(const ValueKey('dayDotsCounts')), findsNothing);
      expect(tester.getSemantics(find.byKey(const ValueKey('dayDots'))).label,
          'Pay period, 20 days: 0 within the day\'s money, 0 over, today, 19 to come.');
      await pumpApp(tester, _dots([for (final d in _days(length: 20, within: 0, over: 0)) PeriodDay(date: d.date, mark: DayMark.toCome)]));
      expect(tester.getSemantics(find.byKey(const ValueKey('dayDots'))).label,
          'Pay period, 20 days: 0 within the day\'s money, 0 over, 20 to come.');
      expect(tester.takeException(), isNull);
      h.dispose();
    });

    testWidgets('an ended period: every day has its verdict, no today square', (tester) async {
      final h = tester.ensureSemantics();
      final days = [
        for (var i = 0; i < 30; i++)
          PeriodDay(date: '2026-09-${(i + 1).toString().padLeft(2, '0')}', mark: i % 5 == 0 ? DayMark.over : DayMark.within)
      ];
      await pumpApp(tester, _dots(days));
      expect(_anyDot, findsNWidgets(30));
      expect(tester.widget<Text>(find.byKey(const ValueKey('dayDotsCounts'))).data, '24 within · 6 over');
      expect(tester.getSemantics(find.byKey(const ValueKey('dayDots'))).label, 'Pay period, 30 days: 24 within the day\'s money, 6 over.');
      h.dispose();
    });
  });

  group('Today hero', () {
    testWidgets('dots count = period length, the past days have a verdict, today is outlined, no pace bar', (tester) async {
      final wc = budgetWallet(budgets: false);
      final p = wc.period();
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => DateTime(2026, 10, 20, 10))),
          size: const Size(400, 3000));
      expect(_anyDot, findsNWidgets(p.length));
      final days = wc.periodDays();
      expect(days.map((d) => d.date), [for (final d in days) d.date]..sort());
      for (final d in days) {
        final deco = _deco(tester, d.date);
        switch (d.mark) {
          case DayMark.within:
            expect(deco.color, _light.accent, reason: d.date);
          case DayMark.over:
            expect(deco.color, _light.bad, reason: d.date);
          case DayMark.today:
            expect(d.date, '2026-10-20');
            expect((deco.border! as Border).top.color, _light.accent);
          case DayMark.toCome:
            expect((deco.border! as Border).top.color, _light.lineStrong, reason: d.date);
        }
      }
      expect(days.where((d) => d.mark == DayMark.today), hasLength(1));
      expect(
          days.where((d) => d.date.compareTo('2026-10-20') < 0).every((d) => d.mark == DayMark.within || d.mark == DayMark.over), isTrue);
      expect(find.byType(PaceBar), findsNothing);
      // The line under the dots is the only mention of the counts; the pace line stays.
      expect(find.byKey(const ValueKey('dayDotsCounts')), findsOneWidget);
    });

    testWidgets('over the plan: the dots stay; days with spending are over, days without are within', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'salary': 0, 'rent': 10000});
      wc.reload();
      expect(wc.period().planDaily, lessThanOrEqualTo(0));
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => DateTime(2026, 10, 20, 10))),
          size: const Size(400, 3000));
      expect(_anyDot, findsNWidgets(wc.period().length));
      for (final d in ['2026-10-03', '2026-10-08', '2026-10-09', '2026-10-12']) {
        expect(_deco(tester, d).color, _light.bad, reason: d);
      }
      expect(_deco(tester, '2026-10-04').color, _light.accent);
    });

    testWidgets('payday passed: every day has a verdict, no today square, no to-come square', (tester) async {
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'paydayDay': 1, 'periodStart': '2026-09-01'});
      wc.reload();
      expect(wc.period().paydayPassed, isTrue);
      await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => DateTime(2026, 10, 20, 10))),
          size: const Size(400, 3000));
      expect(_anyDot, findsNWidgets(wc.period().length));
      expect(wc.periodDays().every((d) => d.mark == DayMark.within || d.mark == DayMark.over), isTrue);
      for (final d in wc.periodDays()) {
        final c = _deco(tester, d.date).color;
        expect(c == _light.accent || c == _light.bad, isTrue, reason: d.date);
      }
    });

    Widget screen(WalletController wc) =>
        Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => DateTime(2026, 10, 20, 10)));

    testWidgets('wide window: the dots sit right of the number', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, screen(wc), size: const Size(900, 1400));
      final number = tester.getRect(find.byKey(const ValueKey('safeToSpend')));
      final grid = tester.getRect(find.byKey(const ValueKey('dayDots')));
      expect(grid.left, greaterThanOrEqualTo(number.right));
      expect(grid.top, lessThan(number.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('320 dp at text scale 2.0: the grid wraps under the number, squares keep their size, nothing overflows', (tester) async {
      final wc = budgetWallet(budgets: false);
      await pumpApp(tester, screen(wc), size: const Size(320, 3000), textScale: 2.0);
      final number = tester.getRect(find.byKey(const ValueKey('safeToSpend')));
      final grid = tester.getRect(find.byKey(const ValueKey('dayDots')));
      expect(grid.top, greaterThanOrEqualTo(number.bottom));
      expect(grid.left, lessThan(number.left + 4), reason: 'left-aligned under the number');
      expect(tester.getSize(find.byKey(const ValueKey('dayDot:2026-10-20'))).shortestSide, greaterThanOrEqualTo(10));
      expect(grid.right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    });

    /// A wallet whose safe-to-spend today is about [cents] (the salary is fitted from two probes: the figure is affine in it).
    WalletController heroOf(int cents) {
      int safe(int salary) {
        final w = budgetWallet(budgets: false);
        w.repo.updateSettings({'salary': salary});
        w.reload();
        return w.period().safeToday;
      }

      final a = safe(100000), b = safe(300000);
      final salary = 100000 + ((cents - a) * 200000 / (b - a)).round();
      final wc = budgetWallet(budgets: false);
      wc.repo.updateSettings({'salary': salary});
      wc.reload();
      expect(wc.period().safeToday, closeTo(cents, cents * 0.05), reason: 'the fitted wallet');
      return wc;
    }

    for (final width in [360.0, 411.0]) {
      for (final cents in [5200, 67100, 180300]) {
        testWidgets('phone ${width.round()} dp, hero about ${cents ~/ 100}: the dots sit beside the number, no overflow', (tester) async {
          final wc = heroOf(cents);
          await pumpApp(tester, screen(wc), size: Size(width, 3000));
          final number = tester.getRect(find.byKey(const ValueKey('safeToSpend')));
          final grid = tester.getRect(find.byKey(const ValueKey('dayDots')));
          expect(grid.left, greaterThanOrEqualTo(number.right), reason: 'beside, not under');
          expect(grid.top, lessThan(number.bottom));
          expect(grid.right, lessThanOrEqualTo(width));
          final side = tester.getSize(find.byKey(const ValueKey('dayDot:2026-10-20'))).shortestSide;
          expect(side, greaterThanOrEqualTo(10));
          expect([DayDots.square, DayDots.compactSquare], contains(side), reason: 'full or compact squares, nothing in between');
          if (width == 360 && cents == 180300) expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('a huge amount does not fit beside the dots: they go under it', (tester) async {
      await pumpApp(tester, screen(heroOf(999999900)), size: const Size(360, 3000), textScale: 1.3);
      final number = tester.getRect(find.byKey(const ValueKey('safeToSpend')));
      expect(tester.getRect(find.byKey(const ValueKey('dayDots'))).top, greaterThanOrEqualTo(number.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('320 dp at text scale 1.0 fits without overflow', (tester) async {
      await pumpApp(tester, screen(budgetWallet(budgets: false)), size: const Size(320, 3000));
      expect(find.byKey(const ValueKey('dayDots')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
