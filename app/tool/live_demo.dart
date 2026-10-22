// Live-mode entry point with the SYNTHETIC demo wallet: `tools/live.sh start --demo`. Same start-up as lib/main.dart,
// plus the screenshot tests' demo data (integration_test/demo_data.dart) when the wallet folder is empty.
// Live mode keeps that folder in dist/live/demo/; BW_LIVE_DEMO=1 (set by tools/live.sh) guards against seeding
// anything else.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:flutter/widgets.dart';

import '../integration_test/demo_data.dart';

Future<void> main() async {
  if (Platform.environment['BW_LIVE_DEMO'] != '1') throw StateError('tool/live_demo.dart only runs from tools/live.sh start --demo');
  final total = Stopwatch()..start();
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final wc = await bootstrap();
    if (!wc.hasWallet) {
      await wc.createWallet();
      wc.takeKeyBackupPrompt(); // live mode drives no taps: show Today with its "Save your wallet key" row instead
      wc.repo.importBatch(demoBatch(wc.today()));
      wc.updateSettings({'salary': 140000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
      wc.saveCategoryBudgets(demoBudgets);
      seedDemoPlanned(wc.repo, wc.today(), wc.period().end);
      seedDemoBills(wc.repo, wc.today());
      await wc.importIcsFile('demo.ics', Uint8List.fromList(utf8.encode(demoIcs(wc.today()))));
    }
    final sinceRunApp = Stopwatch()..start();
    runApp(BudgetWalletApp(wc: wc));
    AppLog.startMonitors();
    unawaited(logFirstFrame(sinceRunApp, total));
  }, AppLog.zoneError);
}
