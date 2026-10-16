// Host side of `flutter drive`: saves the test's screenshots to dist/screens/.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(onScreenshot: (name, bytes, [args]) async {
      final f = File('../dist/screens/$name.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      return true;
    });
