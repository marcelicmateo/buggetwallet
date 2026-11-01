// RX3: Today as a Paper Tiles dashboard. The tile set per state (normal, over today, over the plan, period ended, empty wallet, setup
// pending), the hero to the exact cent, one state chip per fact, the Before payday tile, and layout (no overflow) at 320 dp x 2.0,
// 360, 411 and 1280, light and dark. SYNTHETIC wallets on the fixed clock of Sunday 25 Oct 2026 12:00 (period 15 Oct to 15 Nov).
import 'dart:io';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

final _at = DateTime(2026, 10, 25, 12);

/// Salary 2000, rent 500, loan 200, subs 50: flexible money 1250.00 for 15 Oct to 15 Nov (31 days); on the 25th 21 days are left.
WalletController _wallet({DateTime? now, int spentBefore = 0, int spentToday = 0, bool confirmed = true}) {
  final at = now ?? _at;
  final wc = WalletController.forTest(WalletRepo.inMemory(), clock: () => at);
  if (spentBefore > 0) wc.repo.addTransaction(date: '2026-10-20', amount: spentBefore, category: 'Groceries');
  if (spentToday > 0) wc.repo.addTransaction(date: isoDate(at), amount: spentToday, category: 'Groceries');
  wc.repo.updateSettings({
    'salary': 200000,
    'rent': 50000,
    'loan': 20000,
    'subs': 5000,
    'periodStart': '2026-10-15',
    'paydayDay': 15,
    'salaryConfirmed': confirmed,
  });
  wc.reload();
  wc.snoozeKeyBackup();
  return wc;
}

Future<void> _loadFonts() async {
  for (final (fam, prefix) in [('IBM Plex Sans', 'IBMPlexSans'), ('IBM Plex Mono', 'IBMPlexMono')]) {
    final l = FontLoader(fam);
    for (final w in ['Regular', 'Medium', 'SemiBold']) {
      l.addFont(File('assets/fonts/$prefix-$w.ttf').readAsBytes().then(ByteData.sublistView));
    }
    await l.load();
  }
}

Future<void> _pump(WidgetTester tester, WalletController wc,
    {Size size = const Size(400, 3000), double scale = 1, Brightness mode = Brightness.light, DateTime? now}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final at = now ?? _at;
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(
        body: ListenableBuilder(
            listenable: wc,
            builder: (_, __) => TodayScreen(view: TodayView(wc), openPlan: () {}, addExpense: () {}, openSearch: () {}, clock: () => at))),
  ));
  await tester.pump();
}

Finder _k(String key) => find.byKey(ValueKey(key));

/// The plain text under the widget with [key].
String _under(WidgetTester tester, String key) => [
      for (final t in tester.widgetList<Text>(find.descendant(of: _k(key), matching: find.byType(Text))))
        t.data ?? t.textSpan?.toPlainText() ?? '',
    ].join(' | ');

String _hero(WidgetTester tester) {
  final t = tester.widget<Text>(_k('safeToSpend'));
  return t.textSpan?.toPlainText() ?? t.data!; // a rich text: number, narrow gap, sign
}

/// The tiles of the page that are there, by the keys this test knows.
Set<String> _tiles() {
  const keys = [
    'heroTile',
    'leftTile',
    'paydayTile',
    'comingUpLine',
    'budgetLine',
    'heldLine',
    'expectedIncomeLine',
    'reviewed',
    'reviewCard',
    'periodEndedPanel',
    'setupPanel',
    'setupLine',
    'billsToReview',
    'billsLine',
    'deviceStopLine',
    'foreignNote',
    'addExpense',
    'todaySearch'
  ];
  return {
    for (final k in keys)
      if (_k(k).evaluate().isNotEmpty) k
  };
}

void main() {
  setUpAll(_loadFonts);

  group('tile set per state', () {
    testWidgets('normal: hero, Left, Payday, Add expense, Recent; no sentences', (tester) async {
      await _pump(tester, _wallet(spentBefore: 12345));
      expect(_tiles(), containsAll(['heroTile', 'leftTile', 'paydayTile', 'addExpense', 'todaySearch']));
      expect(_tiles(), isNot(contains('periodEndedPanel')));
      expect(_tiles(), isNot(contains('setupPanel')));
      // One chip for the state, said in icon + word.
      expect(find.text('On pace'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsWidgets);
      for (final gone in ['Due by payday', 'Coming up', "Today's allowance", 'plan per day', 'left until payday', 'Spend less today']) {
        expect(find.textContaining(gone), findsNothing, reason: gone);
      }
      expect(_under(tester, 'leftTile'), contains('LEFT'));
    });

    testWidgets('over today: label, red amount, one chip, tomorrow in the sub line', (tester) async {
      // Spent 80.00 today; allowance today 59.52, so over by 20.48; tomorrow (125000 - 8000) / 20 = 58.50.
      await _pump(tester, _wallet(spentToday: 8000));
      expect(find.text('OVER TODAY BY'), findsOneWidget);
      expect(_hero(tester), moneyExact(2048, 'EUR'));
      expect(_k('overSentence'), findsOneWidget);
      expect(find.text('Nothing more today'), findsOneWidget);
      expect(find.text('Over today'), findsNothing, reason: 'the label says it');
      expect(_k('overBudget'), findsNothing);
      expect(find.text('Tomorrow ${moneyExact(5850, 'EUR')}'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
    });

    testWidgets('over the plan: the chip names how far over, once; Left is zero', (tester) async {
      // Spent 1500 of 1250: over the plan by 250.
      await _pump(tester, _wallet(spentBefore: 150000));
      expect(find.text('${moneyExact(25000, 'EUR')} over plan'), findsOneWidget);
      expect(_k('overBudget'), findsOneWidget);
      expect(_k('overSentence'), findsOneWidget);
      expect(find.textContaining('over the plan'), findsNothing, reason: 'no sentence restating the number');
      expect(_under(tester, 'leftTile'), contains(moneyExact(0, 'EUR')));
    });

    testWidgets('period ended: each fact once (hero chip, the Start button), no Left or Payday tile repeating the hero', (tester) async {
      final now = DateTime(2026, 11, 20, 12);
      final wc = _wallet(now: now);
      await _pump(tester, wc, now: now);
      expect(_k('periodEnded'), findsOneWidget);
      expect(find.text('Pay period ended'), findsOneWidget);
      expect(_k('periodEndedPanel'), findsOneWidget);
      expect(_k('startNewPeriod'), findsOneWidget);
      expect(find.text('LEFT THIS PAY PERIOD'), findsOneWidget, reason: 'the hero says what is left');
      expect(_k('leftTile'), findsNothing);
      expect(_k('paydayTile'), findsNothing);
      expect(find.text('Passed'), findsNothing);
    });

    testWidgets('no money in plan: flexible budget exactly 0 and nothing spent gives the overBudget chip, no pace meter', (tester) async {
      // Rent + loan + subs = the whole salary (2000), so the plan leaves exactly 0.
      final wc = _wallet();
      wc.repo.updateSettings({'rent': 175000});
      wc.reload();
      final p = wc.period();
      expect(p.flexBudget, 0);
      expect(p.overBy, 0);
      expect(p.overBudget, isTrue);
      await _pump(tester, wc);
      expect(find.text('No money in plan'), findsOneWidget);
      expect(_k('overBudget'), findsOneWidget);
      expect(_k('overSentence'), findsNothing);
      expect(find.text('On pace'), findsNothing);
      expect(find.byType(PaceMeter), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
    });

    testWidgets('behind pace: spending before today over the pace and none today gives the Behind pace chip', (tester) async {
      // 600 spent on the 20th, none on the 25th: the day's allowance is fine, the pace (10 of 31 days gone) is not.
      final wc = _wallet(spentBefore: 60000);
      final p = wc.period();
      expect(p.spentToday, 0);
      expect(p.overToday, 0);
      expect(p.overBy, 0);
      expect(p.aheadOfPace, lessThan(0));
      await _pump(tester, wc);
      expect(find.text('Behind pace'), findsOneWidget);
      expect(find.text('On pace'), findsNothing);
      expect(_k('overBudget'), findsNothing);
      expect(find.descendant(of: _k('heroTile'), matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
      expect(find.byType(PaceMeter), findsOneWidget);
    });

    testWidgets('empty wallet: hero and Add expense, an empty Recent note, no number tiles it cannot fill', (tester) async {
      final wc = emptyWallet();
      wc.snoozeKeyBackup();
      await _pump(tester, wc);
      expect(_tiles(), containsAll(['heroTile', 'addExpense']));
      expect(_tiles(), isNot(contains('heldLine')));
      expect(_tiles(), isNot(contains('comingUpLine')));
      expect(_tiles(), isNot(contains('budgetLine')));
      expect(find.textContaining('No transactions yet'), findsOneWidget);
    });

    testWidgets('setup pending: one attention tile with the steps; hide collapses it to a line', (tester) async {
      await _pump(tester, _wallet(confirmed: false));
      expect(_k('setupPanel'), findsOneWidget);
      final tile = tester.widget<Tile>(_k('setupPanel'));
      expect(tile.attention, isTrue);
      expect(find.text('Looks right'), findsOneWidget);
      await tester.tap(_k('setupHide'));
      await tester.pump();
      expect(_k('setupLine'), findsOneWidget);
      expect(_k('setupPanel'), findsNothing);
    });

    testWidgets('Before payday is one tile with core\'s number and count', (tester) async {
      final wc = futureWallet();
      addTearDown(wc.dispose);
      await _pump(tester, wc, now: wc.now);
      final p = wc.period();
      expect(p.beforePayday, greaterThan(0));
      final text = _under(tester, 'comingUpLine');
      expect(text, contains('BEFORE PAYDAY'));
      expect(text, contains(moneyExact(p.beforePayday, wc.currency)));
      expect(text, contains('${p.beforePaydayCount} ${p.beforePaydayCount == 1 ? 'cost' : 'costs'}'));
      expect(find.textContaining('Due by payday'), findsNothing);
    });
  });

  group('exact cents', () {
    testWidgets('hero, Left and the daily plan show cents, never rounded', (tester) async {
      // 123.45 spent on the 20th: remaining 1250.00 - 123.45 = 1126.55.
      final wc = _wallet(spentBefore: 12345);
      await _pump(tester, wc);
      final p = wc.period();
      expect(_hero(tester), moneyExact(p.safeToday, 'EUR'));
      expect(_under(tester, 'leftTile'), contains(moneyExact(p.remaining, 'EUR')));
      expect(_under(tester, 'leftTile'), contains('${moneyExact(p.planDaily, 'EUR')} a day'));
      expect(p.remaining, 112655);
      expect(_under(tester, 'leftTile'), contains('1,126.55'));
    });

    testWidgets('a number scales down in its tile, it never wraps or rounds', (tester) async {
      final wc = _wallet(spentBefore: 12345);
      await _pump(tester, wc, size: const Size(320, 3000), scale: 2.0);
      expect(tester.takeException(), isNull);
      expect(_hero(tester), moneyExact(wc.period().safeToday, 'EUR'));
      expect(find.descendant(of: _k('heroTile'), matching: find.byType(FittedBox)), findsWidgets);
    });
  });

  group('layout', () {
    for (final mode in Brightness.values) {
      for (final (name, size, scale) in [
        ('320 x 2.0', const Size(320, 4000), 2.0),
        ('360', const Size(360, 3000), 1.0),
        ('411', const Size(411, 3000), 1.0),
        ('1280', const Size(1280, 1000), 1.0),
      ]) {
        testWidgets('$name ${mode.name}: no overflow with every tile busy', (tester) async {
          final wc = futureWallet();
          addTearDown(wc.dispose);
          await _pump(tester, wc, size: size, scale: scale, mode: mode, now: wc.now);
          expect(tester.takeException(), isNull);
          expect(_tiles(), containsAll(['heroTile', 'leftTile', 'paydayTile', 'addExpense']));
          // Every tile sits inside the page width.
          final right = size.width;
          for (final k in _tiles()) {
            final r = tester.getRect(_k(k).first);
            expect(r.left, greaterThanOrEqualTo(-0.5), reason: k);
            expect(r.right, lessThanOrEqualTo(right + 0.5), reason: k);
          }
        });
      }
    }

    testWidgets('1280: the hero is one short row across all four columns, Recent shows eight rows', (tester) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      await _pump(tester, wc, size: const Size(1280, 1000), now: wc.now);
      final hero = tester.getRect(_k('heroTile'));
      final left = tester.getRect(_k('leftTile'));
      expect(hero.width, greaterThan(left.width * 1.9), reason: 'a whole row, the other tiles are narrower');
      expect(hero.height, lessThan(hero.width / 3), reason: 'one short row');
      expect(left.top, greaterThanOrEqualTo(hero.bottom - 1), reason: 'the other tiles flow below it');
      expect(tester.getRect(_k('dayDots')).left, greaterThan(hero.center.dx), reason: 'the day dots are on the right');
      expect(tester.getRect(_k('safeToSpend')).left, lessThan(hero.center.dx), reason: 'the figure is on the left');
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: Add expense, then the last three payments', (tester) async {
      final wc = demoWallet();
      addTearDown(wc.dispose);
      await _pump(tester, wc, size: const Size(400, 3000), now: wc.now);
      final add = tester.getRect(_k('addExpense'));
      expect(tester.getRect(_k('todaySearch')).top, greaterThan(add.bottom), reason: 'Recent sits under Add expense');
      expect(find.byType(TxTile), findsNWidgets(3));
    });
  });
}
