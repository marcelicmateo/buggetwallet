// Edge and failure cases for the adaptive layout (rail / bar, content width, two columns, dialogs, shortcuts).
// Written from the spec, not the implementation: widgets are found by type, text and type NAME, so only expectations fail.
// All data is SYNTHETIC.
import 'dart:io';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

const _tabLabels = ['Today', 'Spending', 'Wishlist', 'Goals', 'Plan'];

Future<void> _size(WidgetTester tester, double w, double h) async {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  await tester.pump();
}

Future<void> _pumpShell(WidgetTester tester, WalletController wc,
    {double w = 400, double h = 900, double scale = 1, bool dark = false}) async {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  if (dark) tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  await tester.pumpWidget(BudgetWalletApp(wc: wc));
  await tester.pump();
}

Finder get _bar => find.byType(NavigationBar);
Finder get _rail => find.byType(NavigationRail);
Finder get _stack => find.byWidgetPredicate((w) => w is IndexedStack && w.children.length == 5);
int _tab(WidgetTester tester) => tester.widget<IndexedStack>(_stack).index ?? 0;

Future<void> _goTab(WidgetTester tester, int i) async {
  final nav = _bar.evaluate().isNotEmpty ? _bar : _rail;
  final f = find.descendant(of: nav, matching: find.text(_tabLabels[i])).first;
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f, warnIfMissed: false);
  await tester.pump();
}

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Shortcuts need focus inside the shell body; tapping an inert spot of the page is what a user does first.
Future<void> _focusBody(WidgetTester tester) async {
  await tester.tapAt(Offset(tester.view.physicalSize.width - 3, tester.view.physicalSize.height / 2));
  await tester.pump();
}

/// True when the shallowest Flex under [root] is horizontal (two columns), false for a vertical one.
bool? _twoColumns(Finder root) {
  final start = root.evaluate().first;
  final queue = <Element>[start];
  while (queue.isNotEmpty) {
    final e = queue.removeAt(0);
    final r = e.renderObject;
    if (e != start && r is RenderFlex) return r.direction == Axis.horizontal;
    e.visitChildren(queue.add);
  }
  return null;
}

Finder _byName(String n) => find.byWidgetPredicate((w) => w.runtimeType.toString() == n, skipOffstage: false);
Finder _twoColOn(Type screen) =>
    find.descendant(of: find.byType(screen, skipOffstage: false), matching: _byName('TwoCol'), skipOffstage: false);

WalletController _hugeWallet() {
  final wc = emptyWallet();
  final today = wc.today();
  final txs = <NormalizedTransaction>[
    syntheticTx(addDays(today, -12), 150000, 'Plaća/Mirovina', 'Neto placa synthetic'),
    for (var i = 0; i < 600; i++)
      syntheticTx(addDays(today, -(i % 90)), -(500 + i * 7), 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB $i'),
  ];
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: txs));
  wc.repo.saveGoal(name: 'Synthetic goal', target: 300000, saved: 0, monthly: 10000, sort: 1);
  wc.repo.updateSettings({'salary': 150000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'periodStart': addDays(today, -12)});
  wc.reload();
  return wc;
}

/// Visits every tab and expects no exception (overflow included).
Future<void> _allTabsClean(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await _goTab(tester, i);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull, reason: 'tab ${_tabLabels[i]}');
  }
}

/// Matcher used for the dart:io source rule: a real import or export, not a mention in a comment or string.
bool importsDartIo(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final noLine = noBlock.split('\n').map((l) => l.replaceFirst(RegExp(r'//.*'), '')).join('\n');
  return RegExp('(import|export)\\s+[\'"]dart:io[\'"]').hasMatch(noLine);
}

/// A page with a button that opens [showSheet] with a child that pops 'done'.
class _SheetHost extends StatelessWidget {
  final void Function(Future<String?>) onOpen;
  const _SheetHost(this.onOpen);
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
            child: ElevatedButton(
                onPressed: () => onOpen(showSheet<String>(
                    context,
                    Builder(
                        builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
                              const Text('Synthetic sheet body'),
                              TextButton(onPressed: () => Navigator.of(ctx).pop('done'), child: const Text('Finish')),
                            ])))),
                child: const Text('Open'))),
      );
}

void main() {
  group('navigation at exact boundaries', () {
    for (final w in [320.0, 599.0, 599.5]) {
      testWidgets('width $w: bottom bar, no rail', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        expect(_bar, findsOneWidget);
        expect(_rail, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
    for (final w in [600.0, 601.0, 1000.0, 1023.0]) {
      testWidgets('width $w: rail with labels, not extended', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        expect(_bar, findsNothing);
        final r = tester.widget<NavigationRail>(_rail);
        expect(r.extended, isFalse);
        expect(r.labelType, isNot(NavigationRailLabelType.none));
        expect(tester.takeException(), isNull);
      });
    }
    for (final w in [1024.0, 1025.0, 1500.0, 3840.0]) {
      testWidgets('width $w: extended rail', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        expect(_bar, findsNothing);
        expect(tester.widget<NavigationRail>(_rail).extended, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('selected tab is shown in the nav and kept by resizing across every boundary', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 400, h: 800);
      await _goTab(tester, 3);
      expect(_tab(tester), 3);
      for (final w in [600.0, 1024.0, 599.0, 1300.0, 320.0]) {
        await _size(tester, w, 800);
        expect(_tab(tester), 3, reason: 'at $w');
        final sel = _bar.evaluate().isNotEmpty
            ? tester.widget<NavigationBar>(_bar).selectedIndex
            : tester.widget<NavigationRail>(_rail).selectedIndex;
        expect(sel, 3, reason: 'nav at $w');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('content width', () {
    double todayWidth(WidgetTester tester) => tester.getSize(find.byType(TodayScreen)).width;
    testWidgets('compact: content uses the full width', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 360, h: 800);
      expect(todayWidth(tester), 360);
    });
    for (final w in [600.0, 800.0, 1023.0]) {
      testWidgets('medium $w: content at most 720, centered', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        final box = tester.getRect(find.byType(TodayScreen));
        expect(box.width, lessThanOrEqualTo(720.0));
        final railRight = tester.getRect(_rail).right;
        expect(box.left - railRight, closeTo(w - box.right, 1.0), reason: 'equal gaps left and right');
      });
    }
    testWidgets('medium 1000: content is exactly 720 (room enough)', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1000, h: 800);
      expect(todayWidth(tester), 720);
    });
    for (final w in [1024.0, 1500.0, 1920.0, 3840.0]) {
      testWidgets('expanded $w: content at most 1040, centered', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        final box = tester.getRect(find.byType(TodayScreen));
        expect(box.width, lessThanOrEqualTo(1040.0));
        final railRight = tester.getRect(_rail).right;
        expect(box.left - railRight, closeTo(w - box.right, 1.0));
      });
    }
    testWidgets('expanded 1920: content is exactly 1040', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1920, h: 800);
      expect(todayWidth(tester), 1040);
    });
  });

  group('two columns depend on the content width, not the window width', () {
    testWidgets('Today: one column at content 1039, two at 1040 and 1041', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 1500, h: 900);
      final rail = tester.getSize(_rail).width;
      for (final c in [1039.0, 1040.0, 1041.0]) {
        await _size(tester, rail + c, 900);
        expect(tester.getSize(find.byType(TodayScreen)).width, closeTo(c > 1040 ? 1040 : c, 1.0), reason: 'content width at $c');
        expect(_twoColumns(_twoColOn(TodayScreen)), c >= 1040, reason: 'Today at content $c');
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('Spending: one column at content 1039, two at 1040 and 1041', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 1500, h: 900);
      final rail = tester.getSize(_rail).width;
      await _goTab(tester, 1);
      for (final c in [1039.0, 1040.0, 1041.0]) {
        await _size(tester, rail + c, 900);
        expect(_twoColumns(_twoColOn(SpendingScreen)), c >= 1040, reason: 'Spending at content $c');
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('a window of 1024..1295 is wide but its content is not: one column', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 1024, h: 900);
      expect(_twoColumns(_twoColOn(TodayScreen)), isFalse);
      await _size(tester, 1100, 900);
      expect(_twoColumns(_twoColOn(TodayScreen)), isFalse);
    });
    testWidgets('huge window: content capped at 1040 still gives two columns', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 3840, h: 1080);
      expect(_twoColumns(_twoColOn(TodayScreen)), isTrue);
    });
    testWidgets('compact and medium never use two columns', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 360, h: 800);
      expect(_twoColumns(_twoColOn(TodayScreen)), isNot(isTrue));
      await _size(tester, 800, 800);
      expect(_twoColumns(_twoColOn(TodayScreen)), isNot(isTrue));
    });
  });

  group('odd window sizes: no overflow or exception on any tab', () {
    final sizes = <(double, double)>[
      (320, 480),
      (600, 400),
      (360, 2000),
      (3840, 1080),
      (1024, 300),
      (599, 300),
      (600, 480),
      (1040, 479),
      (1024, 1024),
    ];
    for (final (w, h) in sizes) {
      testWidgets('demo wallet ${w.toInt()}x${h.toInt()}', (tester) async {
        await _pumpShell(tester, demoWallet(), w: w, h: h);
        await _allTabsClean(tester);
      });
    }
    testWidgets('rail scrolls when the window is 300 tall', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1024, h: 300);
      expect(tester.takeException(), isNull);
      final scrolls = find.ancestor(of: _rail, matching: find.byType(Scrollable));
      final inside = find.descendant(of: _rail, matching: find.byType(Scrollable));
      expect(scrolls.evaluate().length + inside.evaluate().length, greaterThan(0), reason: 'the rail sits in a scroll view');
      for (var i = 0; i < 5; i++) {
        await _goTab(tester, i);
        expect(_tab(tester), i);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('text scale 2.0', () {
    for (final w in [360.0, 600.0, 1024.0, 1400.0]) {
      testWidgets('demo wallet at $w', (tester) async {
        await _pumpShell(tester, demoWallet(), w: w, h: 800, scale: 2.0);
        expect(tester.takeException(), isNull);
        if (w >= 600) {
          for (final l in _tabLabels) {
            expect(find.descendant(of: _rail, matching: find.text(l)), findsOneWidget);
          }
        }
        expect(find.byType(Chip), findsOneWidget, reason: 'the AppBar period chip');
        await _allTabsClean(tester);
      });
    }
    testWidgets('rail at 600x400, scale 2.0', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 600, h: 400, scale: 2.0);
      await _allTabsClean(tester);
    });
  });

  group('resizing', () {
    testWidgets('compact -> expanded -> compact with a sheet open: no crash, pop result delivered', (tester) async {
      Future<String?>? result;
      await pumpApp(tester, _SheetHost((f) => result = f), size: const Size(400, 800));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic sheet body'), findsOneWidget);
      await _size(tester, 1300, 800);
      expect(find.text('Synthetic sheet body'), findsOneWidget);
      await _size(tester, 400, 800);
      expect(find.text('Synthetic sheet body'), findsOneWidget);
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(await result, 'done');
      expect(tester.takeException(), isNull);
    });
    testWidgets('expanded -> compact -> expanded with a dialog open: result delivered', (tester) async {
      Future<String?>? result;
      await pumpApp(tester, _SheetHost((f) => result = f), size: const Size(1300, 800));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _size(tester, 360, 800);
      await _size(tester, 1300, 800);
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(await result, 'done');
      expect(tester.takeException(), isNull);
    });
    testWidgets('sheet below 600, dialog from 600 up, same result', (tester) async {
      for (final (w, dialog) in [(599.0, false), (600.0, true), (601.0, true)]) {
        Future<String?>? result;
        await pumpApp(tester, _SheetHost((f) => result = f), size: Size(w, 800));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), dialog ? findsOneWidget : findsNothing, reason: 'Dialog at $w');
        expect(find.byType(BottomSheet), dialog ? findsNothing : findsOneWidget, reason: 'BottomSheet at $w');
        await tester.tap(find.text('Finish'));
        await tester.pumpAndSettle();
        expect(await result, 'done', reason: 'at $w');
      }
    });
    testWidgets('dialog is at most 480 wide and has a close button, also in a huge window', (tester) async {
      Future<String?>? result;
      await pumpApp(tester, _SheetHost((f) => result = f), size: const Size(3840, 1080));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Dialog)).width, lessThanOrEqualTo(480.5));
      final close = find.descendant(of: find.byType(Dialog), matching: find.byIcon(Icons.close));
      expect(close, findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(await result, isNull, reason: 'closing with the button returns null, like dismissing a bottom sheet');
    });
    testWidgets('typed text and focus in a Plan field survive compact -> expanded -> compact', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 400, h: 800);
      await _goTab(tester, 4);
      final field = find.widgetWithText(TextField, 'Salary per month');
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.enterText(field, '1234.5');
      await tester.pump();
      for (final w in [1300.0, 400.0, 700.0]) {
        await _size(tester, w, 800);
        expect(tester.widget<TextField>(field).controller!.text, '1234.5', reason: 'at $w');
        expect(tester.widget<TextField>(field).focusNode?.hasFocus ?? true, isTrue);
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('rapid resizes across boundaries keep the State of the pages', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 400, h: 800);
      final plan = tester.state(find.byType(PlanScreen, skipOffstage: false));
      final planWidget = tester.widget(find.byType(PlanScreen, skipOffstage: false));
      final spending = tester.state(find.byType(SpendingScreen, skipOffstage: false));
      final today = tester.widget(find.byType(TodayScreen, skipOffstage: false));
      final widths = [599.0, 600.0, 1023.0, 1024.0, 1039.0, 1296.0, 599.0, 1024.0, 320.0, 3840.0, 600.0, 400.0];
      for (var i = 0; i < 3; i++) {
        for (final w in widths) {
          await _size(tester, w, 800);
        }
      }
      expect(identical(tester.state(find.byType(PlanScreen, skipOffstage: false)), plan), isTrue, reason: 'Plan State');
      expect(identical(tester.widget(find.byType(PlanScreen, skipOffstage: false)), planWidget), isTrue, reason: 'Plan not rebuilt');
      expect(identical(tester.state(find.byType(SpendingScreen, skipOffstage: false)), spending), isTrue, reason: 'Spending State');
      expect(identical(tester.widget(find.byType(TodayScreen, skipOffstage: false)), today), isTrue, reason: 'Today not rebuilt');
      expect(tester.takeException(), isNull);
    });
    testWidgets('tab switches at any width keep the Plan and Spending pages (not rebuilt)', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 1300, h: 800);
      final plan = tester.widget(find.byType(PlanScreen, skipOffstage: false));
      final spending = tester.widget(find.byType(SpendingScreen, skipOffstage: false));
      for (final i in [4, 1, 3, 0, 2, 4]) {
        await _goTab(tester, i);
      }
      await _size(tester, 400, 800);
      for (final i in [1, 4, 0]) {
        await _goTab(tester, i);
      }
      expect(identical(tester.widget(find.byType(PlanScreen, skipOffstage: false)), plan), isTrue);
      expect(identical(tester.widget(find.byType(SpendingScreen, skipOffstage: false)), spending), isTrue);
    });
  });

  group('keyboard shortcuts', () {
    for (final w in [400.0, 800.0, 1300.0]) {
      testWidgets('Ctrl+1..5 switch tabs at $w', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        await _focusBody(tester);
        final keys = [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit5,
        ];
        for (final i in [4, 2, 0, 3, 1]) {
          await _ctrl(tester, keys[i]);
          expect(_tab(tester), i, reason: 'Ctrl+${i + 1}');
        }
        expect(tester.takeException(), isNull);
      });
      testWidgets('Ctrl+, opens Plan at $w', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        await _focusBody(tester);
        await _ctrl(tester, LogicalKeyboardKey.comma);
        expect(_tab(tester), 4);
      });
      testWidgets('Ctrl+N opens Add expense once, even when pressed again, at $w', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        await _focusBody(tester);
        await _ctrl(tester, LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        expect(find.byType(AddExpenseSheet), findsOneWidget);
        await _ctrl(tester, LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        await _ctrl(tester, LogicalKeyboardKey.keyN);
        await tester.pumpAndSettle();
        expect(find.byType(AddExpenseSheet), findsOneWidget, reason: 'no second Add expense');
        expect(find.byType(Dialog).evaluate().length + find.byType(BottomSheet).evaluate().length, 1);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('PINNED: Ctrl+1..5 while a dialog is open leave it open and do not switch the tab behind it', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1300, h: 800);
      await _focusBody(tester);
      await _ctrl(tester, LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.byType(AddExpenseSheet), findsOneWidget);
      for (final k in [LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit5, LogicalKeyboardKey.comma]) {
        await _ctrl(tester, k);
        await tester.pumpAndSettle();
        expect(find.byType(AddExpenseSheet), findsOneWidget, reason: 'dialog stays open');
        expect(_tab(tester), 0, reason: 'tab behind the dialog does not change');
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('plain digits and letters in a focused text field do not switch tabs or open sheets', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1300, h: 800);
      await _goTab(tester, 4);
      final field = find.widgetWithText(TextField, 'Salary per month');
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pump();
      for (final (k, ch) in [
        (LogicalKeyboardKey.digit1, '1'),
        (LogicalKeyboardKey.digit2, '2'),
        (LogicalKeyboardKey.digit5, '5'),
        (LogicalKeyboardKey.keyN, 'n'),
        (LogicalKeyboardKey.keyR, 'r'),
        (LogicalKeyboardKey.comma, ','),
      ]) {
        await tester.sendKeyEvent(k, character: ch);
        await tester.pump();
        expect(_tab(tester), 4, reason: 'plain "$ch"');
        expect(find.byType(AddExpenseSheet), findsNothing, reason: 'plain "$ch"');
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('plain "1" and "n" in the Add expense amount field do not switch tabs', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1300, h: 800);
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN, character: 'n');
      await tester.enterText(find.descendant(of: find.byType(AddExpenseSheet), matching: find.byType(TextField)).first, '12.50');
      await tester.pumpAndSettle();
      expect(_tab(tester), 0);
      expect(find.byType(AddExpenseSheet), findsOneWidget);
      expect(find.text('12.50'), findsOneWidget);
    });
    for (final w in [400.0, 1300.0]) {
      testWidgets('F5 and Ctrl+R with no sync folder do nothing harmful at $w', (tester) async {
        final wc = emptyWallet();
        await _pumpShell(tester, wc, w: w, h: 800);
        await _focusBody(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.f5);
        await tester.pump();
        await _ctrl(tester, LogicalKeyboardKey.keyR);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(_tab(tester), 0);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(wc.syncing, isFalse);
        expect(wc.txs, isEmpty);
      });
    }
  });

  group('empty and huge wallets', () {
    for (final w in [360.0, 700.0, 1300.0]) {
      testWidgets('empty wallet at $w', (tester) async {
        await _pumpShell(tester, emptyWallet(), w: w, h: 800);
        await _allTabsClean(tester);
      });
      testWidgets('huge wallet at $w', (tester) async {
        await _pumpShell(tester, _hugeWallet(), w: w, h: 800);
        await _allTabsClean(tester);
        await _size(tester, w == 1300 ? 360 : 1300, 800);
        await _allTabsClean(tester);
      });
    }
  });

  group('dark theme', () {
    testWidgets('1280x800: every tab, demo wallet', (tester) async {
      await _pumpShell(tester, demoWallet(), w: 1280, h: 800, dark: true);
      expect(Theme.of(tester.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
      await _allTabsClean(tester);
    });
    testWidgets('dialog in dark theme at 1280x800', (tester) async {
      await _pumpShell(tester, emptyWallet(), w: 1280, h: 800, dark: true);
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('dart:io source rule', () {
    test('matcher: real imports and exports count', () {
      expect(importsDartIo("import 'dart:io';"), isTrue);
      expect(importsDartIo('import "dart:io" show File;'), isTrue);
      expect(importsDartIo("import 'a.dart';\nimport 'dart:io' as io;\n"), isTrue);
      expect(importsDartIo("export 'dart:io';"), isTrue);
    });
    test('matcher: mentions in comments or other libraries do not count', () {
      expect(importsDartIo("// import 'dart:io';"), isFalse);
      expect(importsDartIo("/// No dart:io here, see platform.dart.\nimport 'platform.dart';"), isFalse);
      expect(importsDartIo("/* import 'dart:io'; */ import 'dart:async';"), isFalse);
      expect(importsDartIo("/*\n import 'dart:io';\n*/\nvoid f() {}"), isFalse);
      expect(importsDartIo("import 'dart:ioz';\nimport 'package:x/dart:io.dart';"), isFalse);
      expect(importsDartIo(''), isFalse);
    });
    test('main.dart, screens and widgets do not import dart:io', () {
      final files = <File>[
        File('lib/main.dart'),
        ...Directory('lib/src/screens').listSync(recursive: true).whereType<File>(),
        ...Directory('lib/src/widgets').listSync(recursive: true).whereType<File>(),
      ].where((f) => f.path.endsWith('.dart'));
      expect(files, isNotEmpty);
      final bad = [
        for (final f in files)
          if (importsDartIo(f.readAsStringSync())) f.path
      ];
      expect(bad, isEmpty, reason: 'use lib/src/platform.dart instead of dart:io');
    });
    test('platform.dart exposes the helpers', () {
      final src = File('lib/src/platform.dart').readAsStringSync();
      for (final n in ['isAndroid', 'isIOS', 'isWindows', 'isMobile', 'isDesktop']) {
        expect(src, contains(n));
      }
      expect(src, contains('defaultTargetPlatform'));
      expect(src, contains('kIsWeb'));
      expect(importsDartIo(src), isFalse);
    });
  });
}
