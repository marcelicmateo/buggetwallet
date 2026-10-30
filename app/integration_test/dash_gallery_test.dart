// Screenshots of the dashboard kit (RX2), for eyes only: every component with synthetic numbers, light and dark, at 360 and
// 1280 dp wide (+ 320 dp at text scale 2.0). Desktop only. Run: tools/build.sh desktop-test dash_gallery
// -> dist/screens/linux/dash_gallery/<mode>-<width>.png
import 'package:budget_wallet/src/platform.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/dash_gallery.dart';

void main() {
  if (isAndroid) {
    test('dash gallery: desktop windows only', () {}, skip: 'run with tools/build.sh desktop-test dash_gallery');
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var converted = false;

  for (final mode in Brightness.values) {
    for (final (w, h, scale) in const [(360.0, 2300.0, 1.0), (1280.0, 1500.0, 1.0), (320.0, 3600.0, 2.0)]) {
      testWidgets('kit gallery ${mode.name} ${w.toInt()} dp x $scale', (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(w, h);
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(mode),
          home: const Scaffold(body: DashGallery()),
        ));
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        expect(t.takeException(), isNull);
        if (!converted) {
          converted = true;
          await binding.convertFlutterSurfaceToImage();
          await t.pump();
        }
        await binding.takeScreenshot('${mode.name}-${w.toInt()}${scale == 1 ? '' : 'x2'}');
      });
    }
  }
}
