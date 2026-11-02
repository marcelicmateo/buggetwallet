// Text scale 2.0 at 320 and 360 dp with the real fonts loaded: no error or overflow on any tab. SYNTHETIC data only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';
import 'support/layout.dart';
import 'support/wallet.dart';

const _tabs = ['Today', 'Budget', 'Bills', 'Save', 'Settings'];
void main() {
  setUpAll(() async {
    await loadAppFonts();
  });

  group('text scale 2.0 with real fonts', () {
    for (final w in [320.0, 360.0]) {
      for (final b in Brightness.values) {
        testWidgets('${w.toInt()} wide ${b.name}: every tab scrolls through', (tester) async {
          tester.platformDispatcher.platformBrightnessTestValue = b;
          addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
          await withErrors((errors) async {
            await pumpFull(tester, demoWallet(clock: pinnedNoon), 2.0, size: Size(w, 700));
            await scrollThrough(tester);
            for (final tab in _tabs) {
              await tapTab(tester, tab);
              await scrollThrough(tester);
              expect(tester.takeException(), isNull, reason: tab);
            }
            errors.check();
          });
        });
      }
    }
  });
}
