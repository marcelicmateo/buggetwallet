// Desktop support for every integration test (make desktop-test). `flutter test` runs this around each
// file in this folder. On Linux, `binding.takeScreenshot(name)` has no platform side (the integration_test plugin is
// Android/iOS only), so the screenshot is taken from the render tree instead and saved as $BW_SCREENS_DIR/<name>.png.
// Does nothing on Android and iOS, and `flutter drive` (make emulator-test) doesn't load this file.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:budget_wallet/src/warm_up.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Set per file by the generated combined entry (CI): screenshots go to `$BW_SCREENS_DIR/<this>/`.
String? screensSubdir;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    // `flutter test` has no rasterizer to report the first frame: the background work (HomeShell) must not wait for it.
    WarmUp.waitForFirstRaster = false;
    final dir = Platform.environment['BW_SCREENS_DIR'];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/integration_test'), (call) async {
      if (call.method != 'captureScreenshot') return null;
      final bytes = await _capture(binding);
      final name = (call.arguments as Map<Object?, Object?>)['name']! as String;
      if (dir != null && dir.isNotEmpty) {
        final f = File(screensSubdir == null ? '$dir/$name.png' : '$dir/$screensSubdir/$name.png');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
      }
      return bytes;
    });
  }
  await testMain();
}

/// PNG of the app's window at physical resolution, from the last painted frame.
Future<Uint8List> _capture(RendererBinding binding) async {
  final view = binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.flutterView.physicalSize;
  final image = await layer.toImage(Offset.zero & size);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
