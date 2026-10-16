// Host side of `flutter drive`: saves the test's screenshots to dist/screens/ and its log to dist/logs/app-emulator.log.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        final f = File('../dist/screens/$name.png');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
        return true;
      },
      // Also on failure: the log is what explains a failed run.
      writeResponseOnFailure: true,
      responseDataCallback: (data) async {
        final log = data?['log'];
        if (log is! String) return;
        final f = File('../dist/logs/app-emulator.log');
        await f.parent.create(recursive: true);
        await f.writeAsString(log);
      },
    );
