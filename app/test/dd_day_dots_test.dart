// Today's day dots (DD): one square per day of the pay period, Monday-first columns, counts line, spoken label, wrapping
// under the number on a narrow, large-text screen. SYNTHETIC wallets on the fixed clock of `budgetWallet` (Tuesday 20 Oct 2026).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/dd_standin.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    out.add(PeriodDay(d, m, 0, 0));
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

void main() {
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
      await pumpApp(
          tester, _dots([for (var i = 0; i < 14; i++) PeriodDay('2026-06-${(i + 1).toString().padLeft(2, '0')}', DayMark.toCome, 0, 0)]));
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

    testWidgets('an ended period: every day has its verdict, no today square', (tester) async {
      final h = tester.ensureSemantics();
      final days = [
        for (var i = 0; i < 30; i++)
          PeriodDay('2026-09-${(i + 1).toString().padLeft(2, '0')}', i % 5 == 0 ? DayMark.over : DayMark.within, 0, 0)
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

    testWidgets('320 dp at text scale 1.0 fits without overflow', (tester) async {
      await pumpApp(tester, screen(budgetWallet(budgets: false)), size: const Size(320, 3000));
      expect(find.byKey(const ValueKey('dayDots')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
