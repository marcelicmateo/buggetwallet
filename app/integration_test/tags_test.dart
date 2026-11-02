// Stage T1 on screen: extra tags on a payment (the tx sheet with chosen, suggested and rule tags), Plan › Tags with counts, the `#tag` chips on
// rows, and Insights › Tags with its drill-down. Synthetic demo data only. Screenshots at a desktop size and at a phone size.
import 'dart:async';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/insights.dart';
import 'package:budget_wallet/src/screens/tag_detail.dart';
import 'package:budget_wallet/src/screens/tags_window.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'demo_data.dart';
import 'support/harness.dart';

void main() {
  Harness.init();
  itest('Tags: the tx sheet, Plan › Tags, Insights › Tags, at a desktop and a phone size', (t) async {
    final today = todayIso();
    final wc = await Harness.start(t, batch: demoBatch(today), settings: {'salary': 100000, 'salaryConfirmed': true, 'paydayDay': 15});
    final spending = wc.txs.where((x) => x.tx.live && x.amount < 0 && (x.kind == BudgetKind.flex || x.kind == BudgetKind.fixed)).toList();
    expect(spending.length, greaterThan(6));
    final holiday = await wc.addTag('Holiday');
    final kids = await wc.addTag('Kids');
    final work = await wc.addTag('Work');
    // Several payments carry tags; one payee has a rule; one payment has more tags than a row shows.
    for (final r in spending.take(4)) {
      await wc.setPaymentTag(r.tx.id, holiday, true);
    }
    for (final r in spending.skip(2).take(3)) {
      await wc.setPaymentTag(r.tx.id, kids, true);
    }
    await wc.setPaymentTag(spending[2].tx.id, work, true);
    await wc.addTag('Garden');
    await wc.addTag('Gifts');
    final row = wc.txs.firstWhere((x) => x.tx.id == spending[2].tx.id);
    expect(row.tags.length, greaterThanOrEqualTo(3));

    for (final (name, size) in const [('wide', Size(1280, 800)), ('phone', Size(400, 860))]) {
      t.view.physicalSize = size * t.view.devicePixelRatio;
      await t.pumpAndSettle();
      final ctx = t.element(find.byType(Scaffold).first);

      unawaited(showSheet<String>(ctx, TxSheet(wc: wc, t: wc.txs.firstWhere((x) => x.tx.id == row.tx.id))));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('extraTags')), findsOneWidget);
      await Harness.shot(t, 'tx-sheet-tags-$name');
      await tapVisible(t, find.byKey(const ValueKey('tagAdd')));
      await t.pumpAndSettle();
      await Harness.shot(t, 'tx-sheet-tags-open-$name');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      if (find.byType(TxSheet).evaluate().isNotEmpty) {
        await tapVisible(t, find.byKey(const ValueKey('sheetClose')).last);
        await t.pumpAndSettle();
      }

      await goTags(t);
      await scrollTo(t, find.byKey(ValueKey('tag:$holiday')), TagsWindow);
      await Harness.shot(t, 'plan-tags-$name');

      await tapVisible(t, find.byKey(const ValueKey('budgetSpending')));
      await t.pumpAndSettle();
      await Harness.shot(t, 'spending-rows-$name');

      showInsights(t, wc);
      await t.pumpAndSettle();
      await scrollTo(t, find.byKey(const ValueKey('insightPanel_tags')), InsightsScreen);
      await Harness.shot(t, 'insights-tags-$name');
      await tapVisible(t, find.byKey(ValueKey('tagRow_$holiday')));
      await t.pumpAndSettle();
      expect(find.byType(TagDetailScreen), findsOneWidget);
      await Harness.shot(t, 'tag-detail-$name');
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sheetClose')).last);
      await t.pumpAndSettle();
      expect(find.byType(InsightsScreen), findsNothing);
    }
    await Harness.checkLog();
  });
}

void showInsights(WidgetTester t, WalletController wc) {
  final ctx = t.element(find.byType(Scaffold).first);
  unawaited(openInsights(ctx, wc));
}
