import 'dart:async';

import 'package:budget_wallet/src/warm_up.dart';
import 'package:flutter_test/flutter_test.dart';

/// Applies to every test under app/test/ (not integration_test/, which has its own config): a widget test that
/// hangs fails after a minute instead of flutter_test's 10-minute backstop. The CLI `--timeout` cannot do this,
/// because testWidgets passes its own timeout. The slowest passing test takes ~8 s; a test that needs longer
/// passes `timeout:` explicitly.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // The idle warm-up and the staged page build are for the running app: a widget test would end with an idle task pending.
  // test/warm_up_test.dart and the tab-fade tests switch them on.
  WarmUp.enabled = false;
  if (binding is AutomatedTestWidgetsFlutterBinding) {
    binding.defaultTestTimeout = const Timeout(Duration(seconds: 60));
  }
  await testMain();
}
