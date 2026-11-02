// RX6: the Save tab as a Paper Tiles dashboard. Empty Save, goals with and without a target and one below zero, a wish ready / cooling /
// decided, money owed both ways and in two currencies, exact cents everywhere, and layout (no overflow) at 320 dp x 2.0, 360, 411 and
// 1280, light and dark. SYNTHETIC wallets; the clock is the real one (wishes are stamped with it).

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/goals.dart' show goalPercent;
import 'package:budget_wallet/src/screens/save.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'support/fonts.dart';

Future<void> _loadFonts() async {
  await loadAppFonts();
}

WalletController _wallet() {
  final wc = WalletController.forTest(WalletRepo.inMemory(), clock: DateTime.now);
  addTearDown(wc.dispose);
  wc.repo.updateSettings(
      {'salary': 200000, 'salaryConfirmed': true, 'periodStart': isoDate(DateTime.now().subtract(const Duration(days: 3)))});
  wc.snoozeKeyBackup();
  wc.reload();
  return wc;
}

/// A wallet with every tile busy: four goals (one without a target, one below zero, one reached), a ready wish, two cooling, one
/// skipped and one bought, and IOUs both ways in the wallet currency plus one in USD.
WalletController _busy() {
  final wc = _wallet();
  wc.repo.saveGoal(name: 'Emergency fund', target: 300000, saved: 123456, monthly: 10000, sort: 1);
  wc.repo.saveGoal(name: 'Open ended', target: 0, saved: 5000, monthly: 0, sort: 2);
  wc.repo.saveGoal(name: 'Overdrawn', target: 100000, saved: -2550, monthly: 0, sort: 3);
  wc.repo.saveGoal(name: 'Done', target: 40000, saved: 40000, monthly: 0, sort: 4);
  final now = DateTime.now().millisecondsSinceEpoch;
  wc.repo.applyRemote([
    Op('wish', 'w-ready', {'name': 'Rain jacket', 'price': 8999, 'added': now - 100 * 3600000, 'status': 'waiting', 'deleted': 0},
        Hlc(now + 1000, 0, 'peer').toString()),
  ]);
  wc.repo.addWish('Running shoes', 12050);
  wc.repo.addWish('Desk lamp', 5075);
  wc.repo.decideWish(wc.repo.addWish('Skipped thing', 6001), 'skipped');
  wc.repo.decideWish(wc.repo.addWish('Bought thing', 9900), 'bought');
  wc.repo.addIou(person: 'Sam', direction: IouDirection.lent, amount: 4505, currency: 'EUR', date: '2026-10-10');
  wc.repo.addIou(person: 'Alex', direction: IouDirection.borrowed, amount: 3500, currency: 'EUR', date: '2026-10-11');
  wc.repo.addIou(person: 'Pat', direction: IouDirection.lent, amount: 3000, currency: 'USD', date: '2026-10-12');
  wc.reload();
  // The payday auto-save paid this period on reload; skipping it keeps the totals these tests were written with.
  for (final g in wc.goals) {
    if (g.monthly > 0) wc.repo.setGoalPeriodAmount(g.id, wc.effectiveSettings.periodStart!, 0);
  }
  wc.reload();
  return wc;
}

Future<void> _pump(WidgetTester tester, WalletController wc,
    {Size size = const Size(400, 3000), double scale = 1, Brightness mode = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: ListenableBuilder(listenable: wc, builder: (_, __) => SaveScreen(wc: wc))),
  ));
  await tester.pump();
}

Finder _k(String key) => find.byKey(ValueKey(key));
Finder _in(String key, String text) => find.descendant(of: _k(key), matching: find.text(text));

void main() {
  setUpAll(_loadFonts);

  group('Above plan (core aboveSalary)', () {
    testWidgets('income above the salary shows the exact excess; no salary set shows no tile', (tester) async {
      final wc = _wallet();
      // addTransaction takes money spent as positive, so income is negative.
      wc.repo.addTransaction(date: wc.today(), amount: -212345, category: 'Salary');
      wc.reload();
      await _pump(tester, wc);
      expect(_k('goalsAbovePlan'), findsOneWidget);
      expect(_in('goalsAbovePlan', moneyExact(12345, 'EUR')), findsOneWidget);

      wc.repo.updateSettings({'salary': 0});
      wc.reload();
      await tester.pump();
      expect(_k('goalsAbovePlan'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('empty Save', () {
    testWidgets('a zero total, the add tiles and an empty tile per wishlist part; no sentences', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      expect(find.text('GOALS'), findsOneWidget);
      expect(find.text('WISHLIST'), findsOneWidget);
      expect(find.text('OWED'), findsOneWidget);
      expect(_in('goalsTotal', moneyExact(0, 'EUR')), findsOneWidget);
      expect(_in('goalsTotal', 'No goals yet'), findsOneWidget);
      expect(_k('addGoal'), findsOneWidget);
      expect(_in('emptySection:Wishlist', 'None yet'), findsOneWidget);
      for (final k in ['emptySection:Ready to decide', 'emptySection:Cooling off', 'emptySection:Decided']) {
        expect(_k(k), findsNothing, reason: '$k: one tile says it once');
      }
      expect(_k('owedAdd'), findsOneWidget);
      expect(find.text('Nothing owed'), findsOneWidget);
      for (final gone in ['Each goal takes its monthly amount', 'Check before you buy', 'Anything over', 'Your wishlist is empty']) {
        expect(find.textContaining(gone), findsNothing, reason: gone);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ Goal opens the goal sheet', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      await tester.ensureVisible(_k('addGoal'));
      await tester.tap(_k('addGoal'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GoalSheet), findsOneWidget);
    });
  });

  group('goals', () {
    testWidgets('exact cents, percent rounded down, no target, below zero, reached', (tester) async {
      final wc = _busy();
      await _pump(tester, wc);
      final byName = {for (final g in wc.goals) g.name: g};
      String key(String n) => 'goal:${byName[n]!.id}';

      // 1,234.56 of 3,000: 41 % (41.15), never rounded to whole euros.
      expect(_in(key('Emergency fund'), '1,234.56 €'), findsOneWidget);
      expect(find.descendant(of: _k(key('Emergency fund')), matching: find.textContaining('41% of 3,000')), findsOneWidget);
      // No target: no percent, says so.
      expect(_in(key('Open ended'), 'No target'), findsOneWidget);
      // Below zero: the exact negative figure, an empty ring and a word.
      expect(find.descendant(of: _k(key('Overdrawn')), matching: find.textContaining('25.50')), findsOneWidget);
      expect(_in(key('Overdrawn'), 'Below zero'), findsOneWidget);
      expect(find.descendant(of: _k(key('Overdrawn')), matching: find.textContaining('0% of 1,000\u00A0€')), findsOneWidget);
      // Reached.
      expect(_in(key('Done'), 'Reached'), findsOneWidget, reason: 'said once, in the chip');
      expect(find.descendant(of: _k(key('Done')), matching: find.textContaining('100% of 400\u00A0€')), findsOneWidget);
      // The total: core's sum 1,234.56 + 50 - 25.50 + 400 = 1,659.06 of 3,000 + 0 + 1,000 + 400 = 4,400.
      expect(_in('goalsTotal', '1,659.06 €'), findsOneWidget);
      expect(find.descendant(of: _k('goalsTotal'), matching: find.textContaining('of 4,400 €')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('goalPercent: integer maths, rounded down, clamped', () {
      expect(goalPercent(29000, 100000), 29, reason: '290 of 1000 is 29, a double says 28');
      expect(goalPercent(57000, 100000), 57);
      expect(goalPercent(14000, 100000), 14);
      expect(goalPercent(99999, 100000), 99, reason: 'rounded down: 100 means reached');
      expect(goalPercent(100000, 100000), 100);
      expect(goalPercent(150000, 100000), 100, reason: 'more than the target');
      expect(goalPercent(-2550, 100000), 0, reason: 'below zero');
      expect(goalPercent(5000, 0), 0, reason: 'no target');
      expect(goalPercent(5000, -1), 0);
    });

    testWidgets('the shown percent is exact: 29, 57 and 14, not 28, 56 and 13', (tester) async {
      final wc = _wallet();
      wc.repo.saveGoal(name: 'Aaa', target: 100000, saved: 29000, monthly: 0, sort: 1);
      wc.repo.saveGoal(name: 'Bbb', target: 100000, saved: 57000, monthly: 0, sort: 2);
      wc.repo.saveGoal(name: 'Ccc', target: 100000, saved: 14000, monthly: 0, sort: 3);
      wc.reload();
      await _pump(tester, wc);
      for (final (n, pc) in [('Aaa', 29), ('Bbb', 57), ('Ccc', 14)]) {
        final g = wc.goals.firstWhere((g) => g.name == n);
        expect(find.descendant(of: _k('goal:${g.id}'), matching: find.textContaining('$pc% of 1,000')), findsOneWidget, reason: n);
      }
    });

    testWidgets('a goal ring is spoken without an empty part', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = _busy();
      await _pump(tester, wc);
      final g = wc.goals.firstWhere((g) => g.name == 'Emergency fund');
      final label = tester.getSemantics(_k('goal:${g.id}')).label;
      expect(label, isNot(contains(', ,')));
      expect(label, startsWith('Emergency fund, 1,234.56'));
      handle.dispose();
    });

    testWidgets('a tap on a goal opens its sheet', (tester) async {
      final wc = _busy();
      await _pump(tester, wc);
      await tester.ensureVisible(_k('goal:${wc.goals.first.id}'));
      await tester.tap(_k('goal:${wc.goals.first.id}'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(GoalSheet), findsOneWidget);
    });
  });

  group('wishlist', () {
    testWidgets('ready is an attention tile with Buy it / Skip; cooling shows the exact total and rows; saved by waiting; decided',
        (tester) async {
      final wc = _busy();
      await _pump(tester, wc);
      expect(_k('emptySection:Ready to decide'), findsNothing);
      expect(find.text('READY TO DECIDE'), findsOneWidget);
      expect(find.text('Rain jacket'), findsOneWidget);
      expect(find.text('Buy it'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      final attention = tester.widgetList<Tile>(find.byType(Tile)).where((t) => t.attention);
      expect(attention, hasLength(1), reason: 'only the ready wish needs the owner');
      // Cooling: 120.50 + 50.75 = 171.25 exactly.
      expect(find.text('COOLING OFF'), findsOneWidget);
      expect(find.text(moneyExact(17125, 'EUR')), findsOneWidget);
      expect(find.text('2 wishes'), findsOneWidget);
      expect(find.text("Don't need it"), findsNWidgets(2));
      // Saved by waiting: the skipped wish, 60.01 exactly.
      expect(_in('savedByWaiting', moneyExact(6001, 'EUR')), findsOneWidget);
      expect(_in('savedByWaiting', '1 skipped'), findsOneWidget);
      expect(find.text('DECIDED'), findsOneWidget);
      expect(find.text('Bought'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
    });

    testWidgets('one wish ready and none cooling: the tile beside does not say the wishlist is empty', (tester) async {
      final wc = _wallet();
      final now = DateTime.now().millisecondsSinceEpoch;
      wc.repo.applyRemote([
        Op('wish', 'w-r', {'name': 'Rain jacket', 'price': 8999, 'added': now - 100 * 3600000, 'status': 'waiting', 'deleted': 0},
            Hlc(now + 1000, 0, 'peer').toString()),
      ]);
      wc.reload();
      await _pump(tester, wc);
      expect(_k('readyToDecide'), findsOneWidget);
      expect(_in('emptySection:Cooling off', 'Nothing cooling off'), findsOneWidget);
      expect(find.text('Wishlist is empty'), findsNothing);
      expect(_k('emptySection:Wishlist'), findsNothing);
    });

    for (final (status, hoursAgo) in [('waiting', 1), ('skipped', 100)]) {
      testWidgets('only $status wishes: the one empty tile is absent', (tester) async {
        final wc = _wallet();
        final now = DateTime.now().millisecondsSinceEpoch;
        wc.repo.applyRemote([
          Op('wish', 'w-$status', {'name': 'Rain jacket', 'price': 8999, 'added': now - hoursAgo * 3600000, 'status': status, 'deleted': 0},
              Hlc(now + 1000, 0, 'peer').toString()),
        ]);
        wc.reload();
        await _pump(tester, wc);
        expect(_k('emptySection:Wishlist'), findsNothing);
        expect(find.text('None yet'), findsNothing);
      });
    }

    testWidgets('an empty wishlist says so once, in one tile', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      expect(_in('emptySection:Wishlist', 'None yet'), findsOneWidget);
      expect(find.text('Wishlist is empty'), findsNothing);
      expect(_k('savedByWaiting'), findsNothing);
    });

    testWidgets('the ready tile is spoken as needing action and keeps Buy it / Skip reachable', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = _busy();
      await _pump(tester, wc);
      expect(tester.getSemantics(_k('readyToDecide')).label, startsWith('Needs action: Ready to decide, 1 wish'));
      expect(find.bySemanticsLabel('Buy it'), findsOneWidget);
      expect(find.bySemanticsLabel('Skip'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Skip moves a ready wish out of the attention tile', (tester) async {
      final wc = _busy();
      await _pump(tester, wc);
      await tester.ensureVisible(find.text('Skip'));
      await tester.tap(find.text('Skip'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(wc.wish.firstWhere((w) => w.id == 'w-ready').status, 'skipped');
      expect(_k('emptySection:Ready to decide'), findsOneWidget);
      expect(_in('savedByWaiting', moneyExact(6001 + 8999, 'EUR')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('the check field still gives a verdict', (tester) async {
      final wc = _busy();
      await _pump(tester, wc);
      await tester.enterText(find.byType(TextField).first, 'Boots');
      await tester.enterText(find.byType(TextField).last, '30');
      await tester.pump();
      expect(find.byType(StatusLabel), findsOneWidget);
      expect(find.text('Save for it'), findsOneWidget);
      expect(find.textContaining('no wait needed'), findsNothing, reason: 'the tile note already says "Over 50 € waits 72 h"');
      expect(find.textContaining('waits 72 h'), findsOneWidget);
    });
  });

  group('wishlist form', () {
    for (final (name, size) in [('phone', const Size(400, 700)), ('desktop', const Size(1280, 720))]) {
      testWidgets('$name: Put on wishlist is reachable and adds a waiting wish', (tester) async {
        final wc = _wallet();
        await _pump(tester, wc, size: size);
        await tester.enterText(find.byType(TextField).first, 'Boots');
        await tester.enterText(find.byType(TextField).last, '120');
        await tester.pump();
        final button = find.text('Put on wishlist (72h)');
        await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
        await tester.pump();
        // The tile grew with the verdict: the grid made room for it (its box holds the button).
        final tile = find.ancestor(of: button, matching: find.byType(Tile)).first;
        expect(tester.getRect(tile).bottom, greaterThanOrEqualTo(tester.getRect(button).bottom));
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 100));
        expect(wc.wish.single.name, 'Boots');
        expect(wc.wish.single.price, 12000);
        await tester.pump(const Duration(seconds: 6));
      });
    }
  });

  group('owed', () {
    testWidgets('both ways as two numbers, a USD pair of its own, rows with a word and an exact amount', (tester) async {
      final wc = _busy();
      await _pump(tester, wc);
      expect(tester.widget<Tile>(_k('owedSummary')).semanticLabel,
          'People owe you ${moneyExact(4505, 'EUR')}, you owe ${moneyExact(3500, 'EUR')}');
      expect(_in('owedSummary', '45.05 €'), findsOneWidget);
      expect(_in('owedSummary', '35 €'), findsOneWidget);
      expect(_in('owedSummary:USD', 'In USD'), findsOneWidget);
      expect(_in('owedSummary:USD', moneyExact(3000, 'USD')), findsOneWidget);
      for (final v in wc.iousOpen()) {
        final row = _k('iou:${v.iou.id}');
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(moneyExact(v.outstanding, v.iou.currency))), findsOneWidget);
        expect(
            find.descendant(of: row, matching: find.text(v.iou.direction == IouDirection.lent ? 'owes you' : 'you owe')), findsOneWidget);
      }
    });
  });

  group('layout', () {
    for (final mode in Brightness.values) {
      for (final (name, size, scale) in [
        ('320 x 2.0', const Size(320, 9000), 2.0),
        ('360', const Size(360, 4000), 1.0),
        ('411', const Size(411, 4000), 1.0),
        ('1280', const Size(1280, 2500), 1.0),
      ]) {
        testWidgets('$name ${mode.name}: no overflow with every tile busy', (tester) async {
          final wc = _busy();
          await _pump(tester, wc, size: size, scale: scale, mode: mode);
          expect(tester.takeException(), isNull);
          final tiles = find.byType(Tile);
          for (var i = 0; i < tiles.evaluate().length; i++) {
            final r = tester.getRect(tiles.at(i));
            expect(r.left, greaterThanOrEqualTo(-0.5), reason: 'tile $i');
            expect(r.right, lessThanOrEqualTo(size.width + 0.5), reason: 'tile $i');
          }
          for (final k in ['goalsTotal', 'owedSummary', 'owedSummary:USD', 'addGoal', 'owedAdd']) {
            final r = tester.getRect(_k(k));
            expect(r.left, greaterThanOrEqualTo(-0.5), reason: k);
            expect(r.right, lessThanOrEqualTo(size.width + 0.5), reason: k);
          }
        });
      }
    }

    testWidgets('1280: four columns, goal tiles side by side', (tester) async {
      final wc = _busy();
      await _pump(tester, wc, size: const Size(1280, 2500));
      final a = tester.getRect(_k('goal:${wc.goals[0].id}')), b = tester.getRect(_k('goal:${wc.goals[1].id}'));
      expect(b.left, greaterThan(a.right - 1));
      expect((b.top - a.top).abs(), lessThan(1));
    });
  });
}
