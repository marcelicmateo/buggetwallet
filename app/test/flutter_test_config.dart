import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Applies to every test under app/test/ (not integration_test/, which has its own config): a widget test that
/// hangs fails after a minute instead of flutter_test's 10-minute backstop. The CLI `--timeout` cannot do this,
/// because testWidgets passes its own timeout. The slowest passing test takes ~8 s; a test that needs longer
/// passes `timeout:` explicitly.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    binding.defaultTestTimeout = const Timeout(Duration(seconds: 60));
  }
  await testMain();
}
