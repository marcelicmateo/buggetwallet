// Stage ZC on screen: the Insights graphs and the category bars zoomed in and out, dragged and pinched, at a desktop and a phone size.
// Synthetic demo data only. Screenshots `zoom-*` in dist/screens/linux/zoom_graphs/.
import 'dart:async';

import 'package:budget_wallet/src/screens/category_detail.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_data.dart';
import 'support/harness.dart';

void main() {
  Harness.init();
  itest('Zoomable graphs: weeks, days, a drag, a pinch, the budget share and the category bars', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, batch: demoBatch(today), settings: {'salary': 100000, 'salaryConfirmed': true, 'paydayDay': 15});
    for (final (name, size) in const [('wide', Size(1280, 900)), ('phone', Size(400, 860))]) {
      t.view.physicalSize = size * t.view.devicePixelRatio;
      await t.pumpAndSettle();
      for (final id in ['spending', 'share', 'income', 'budget']) {
        wc.insightRange(id).reset(); // every size starts from the chips' ranges
      }
      final ctx = t.element(find.byType(Scaffold).first);
      unawaited(openInsights(ctx, wc));
      await t.pumpAndSettle();
      await Harness.shot(t, 'zoom-1-default-$name');

      // + once: about three months, a bar per week
      await tapVisible(t, find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pumpAndSettle();
      expect(wc.insightRange('spending').isFree, isTrue);
      await Harness.shot(t, 'zoom-2-weeks-$name');

      // + twice more: five weeks or less, a bar per day
      await tapVisible(t, find.byKey(const ValueKey('chartZoomIn_spending')));
      await tapVisible(t, find.byKey(const ValueKey('chartZoomIn_spending')));
      await t.pumpAndSettle();
      await Harness.shot(t, 'zoom-3-days-$name');

      // drag back in time
      final graph = find.byKey(const ValueKey('chartGestures_spending'));
      final g = await t.startGesture(t.getCenter(graph));
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(8, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();
      await Harness.shot(t, 'zoom-4-dragged-$name');

      // a list: the share panel, shorter
      await scrollTo(t, find.byKey(const ValueKey('insightPanel_share')), InsightsScreen);
      await tapVisible(t, find.byKey(const ValueKey('chartZoomIn_share')));
      await t.pumpAndSettle();
      await Harness.shot(t, 'zoom-6-share-shorter-$name');

      // a category's bars
      final shareRow =
          find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('shareRow_')).first;
      await tapVisible(t, shareRow);
      expect(find.byType(CategoryDetailScreen), findsOneWidget);
      await Harness.shot(t, 'zoom-7-category-$name');
      await tapVisible(t, find.byKey(const ValueKey('chartZoomOut_category')));
      await t.pumpAndSettle();
      await Harness.shot(t, 'zoom-8-category-out-$name');
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      // the budget graph below a month: a pro-rated share
      await scrollTo(t, find.byKey(const ValueKey('insightPanel_budget')), InsightsScreen);
      if (find.byKey(const ValueKey('chartZoomIn_budget')).evaluate().isNotEmpty) {
        await tapVisible(t, find.byKey(const ValueKey('chartZoomIn_budget')));
        await tapVisible(t, find.byKey(const ValueKey('chartZoomIn_budget')));
        await t.pumpAndSettle();
        await Harness.shot(t, 'zoom-5-budget-share-$name');
      }

      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      expect(find.byType(InsightsScreen), findsNothing);
    }
    await Harness.checkLog();
  });
}
