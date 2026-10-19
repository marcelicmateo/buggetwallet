// Host side of `flutter drive`: saves the test's screenshots and its app log.
//   tools/emulator.sh screens: dist/screens/<shot>.png and dist/logs/app-emulator.log
//   tools/emulator.sh test (BW_TEST_NAME=<name>): dist/screens/<name>/<shot>.png, dist/logs/app-<name>.log and the
//   rest of the test's report data (perf numbers, known bugs) as dist/logs/report-<name>.json
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() {
  final name = Platform.environment['BW_TEST_NAME'] ?? '';
  final shots = name.isEmpty ? '../dist/screens' : '../dist/screens/$name';
  final logFile = name.isEmpty ? '../dist/logs/app-emulator.log' : '../dist/logs/app-$name.log';
  return integrationDriver(
    onScreenshot: (shot, bytes, [args]) async {
      final f = File('$shots/$shot.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      return true;
    },
    // Also on failure: the log is what explains a failed run.
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      if (data == null) return;
      final log = data['log'];
      if (log is String) {
        final f = File(logFile);
        await f.parent.create(recursive: true);
        await f.writeAsString(log);
      }
      final rest = {...data}
        ..remove('log')
        ..remove('screenshots'); // saved as PNGs above
      if (name.isNotEmpty && rest.isNotEmpty) {
        final f = File('../dist/logs/report-$name.json');
        await f.parent.create(recursive: true);
        await f.writeAsString(const JsonEncoder.withIndent('  ').convert(rest));
      }
    },
  );
}
