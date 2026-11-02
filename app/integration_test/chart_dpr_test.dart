// The Spending chart at several device pixel ratios (laptop screens use 1.25 and 1.5): screenshots for a look by eye.
// Desktop only. Run: make desktop-test N=chart_dpr -> dist/screens/linux/chart_dpr/dpr-<ratio>.png
import 'package:budget_wallet/src/platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'demo_data.dart';
import 'support/harness.dart';

void main() {
  if (isAndroid) {
    test('chart_dpr: desktop windows only', () {}, skip: 'a resized phone view hangs the screenshot');
    return;
  }
  Harness.init();

  itest('chart at device pixel ratios 1, 1.25, 1.5 and 2', (t) async {
    final wc = await Harness.start(t);
    wc.repo.importBatch(demoBatch(wc.today()));
    wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10, 'salaryConfirmed': true});
    for (final dpr in const [1.0, 1.25, 1.5, 2.0]) {
      t.view.devicePixelRatio = dpr;
      t.view.physicalSize = const Size(1280, 800) * dpr;
      await t.pumpAndSettle();
      await goTab(t, 'Budget');
      await Harness.shot(t, 'dpr-$dpr');
    }
    await Harness.checkLog();
  });
}
