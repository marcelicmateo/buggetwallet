// ENG E6 screens for eyes (docs/context/ENG_UI_SPEC.md §5.5): the goal planner, its ready card, "I bought it", the Loan screen and "Turn into a
// loan", light and dark, at 320 dp x 2.0, 390 and 1280 dp. Desktop only. Run: make desktop-test N=goal_loans
// -> dist/screens/linux/goal_loans/*.png. SYNTHETIC data only.
import 'dart:async';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/platform.dart';
import 'package:budget_wallet/src/screens/goal_planner.dart';
import 'package:budget_wallet/src/screens/loan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'demo_data.dart';
import 'support/harness.dart';

void main() {
  if (isAndroid) {
    test('goal loans screens: desktop windows only', () {}, skip: 'run with make desktop-test N=goal_loans');
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Harness.init();
  Harness.private(texts: ['Synthetic Boat', 'LENDER SYNTHETIC']);

  itest('planner, ready card, bought sheet, loan screen and loan form', (t) async {
    final wc = await Harness.start(t, batch: demoBatch(isoDate(DateTime.now())), settings: {'loan': 25000}, noGoals: true);
    final id = wc.addBigGoal(name: 'Synthetic Boat', price: 18000000, financed: true, property: true)!;
    wc.saveGoalDraft(
        id,
        GoalDraft.of(wc.goalOf(id)!)
          ..monthly = 65000
          ..rateBp = 360);
    wc.repo.saveGoal(id: id, name: 'Synthetic Boat', target: 0, saved: 1840000, monthly: 65000);
    final loan = wc.addLoan(Loan(
        id: '',
        name: 'Synthetic loan',
        principal: 4500000,
        rateBp: 480,
        months: 120,
        firstDue: addDays(isoDate(DateTime.now()), -75),
        payeeKey: wc.payeeKeyOf('LENDER SYNTHETIC')))!;
    wc.reload();
    await t.pumpAndSettle();
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    var converted = false;
    Future<void> shot(String name) async {
      if (!converted) {
        converted = true;
        await binding.convertFlutterSurfaceToImage();
      }
      await t.pump();
      expect(t.takeException(), isNull);
      await binding.takeScreenshot(name);
    }

    BuildContext ctx() => t.element(find.byType(Scaffold).first);
    for (final (mode, w, h, scale) in [
      (Brightness.dark, 390.0, 2200.0, 1.0),
      (Brightness.light, 390.0, 2200.0, 1.0),
      (Brightness.dark, 320.0, 3600.0, 2.0),
      (Brightness.dark, 1280.0, 1000.0, 1.0),
    ]) {
      t.view.physicalSize = Size(w, h);
      t.platformDispatcher.platformBrightnessTestValue = mode;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      final tag = '${mode.name}-${w.toInt()}';
      await t.pumpAndSettle();
      unawaited(openGoalPlanner(ctx(), wc, id));
      await t.pumpAndSettle();
      await shot('planner-$tag');
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
      unawaited(openLoan(ctx(), wc, loan));
      await t.pumpAndSettle();
      await shot('loan-$tag');
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
    }

    // The ready card and "I bought it".
    t.view.physicalSize = const Size(390, 2200);
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    t.platformDispatcher.textScaleFactorTestValue = 1;
    wc.repo.saveGoal(id: id, name: 'Synthetic Boat', target: 0, saved: goalTarget(wc.goalOf(id)!), monthly: 65000);
    wc.reload();
    unawaited(openGoalPlanner(ctx(), wc, id));
    await t.pumpAndSettle();
    await shot('planner-ready');
    await t.tap(find.byKey(const ValueKey('plannerIBought')));
    await t.pumpAndSettle();
    await shot('bought-sheet');
    await Harness.checkLog();
  });
}
