// Web-safe platform checks (lib/src/platform.dart) and the rule that UI code does not import dart:io.
// All data is SYNTHETIC.
import 'dart:io';

import 'package:budget_wallet/src/platform.dart' as plat; // flutter_test has its own isWindows
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

void main() {
  group('platform checks follow defaultTargetPlatform', () {
    for (final (p, android, ios, windows, mobile, desktop) in const [
      (TargetPlatform.android, true, false, false, true, false),
      (TargetPlatform.iOS, false, true, false, true, false),
      (TargetPlatform.windows, false, false, true, false, true),
      (TargetPlatform.linux, false, false, false, false, true),
      (TargetPlatform.macOS, false, false, false, false, true),
    ]) {
      test(p.name, () {
        debugDefaultTargetPlatformOverride = p;
        try {
          expect((plat.isAndroid, plat.isIOS, plat.isWindows, plat.isMobile, plat.isDesktop), (android, ios, windows, mobile, desktop));
          expect(plat.hasKeyboard, desktop);
        } finally {
          debugDefaultTargetPlatformOverride = null; // flutter_test wants it unset before the test ends
        }
      });
    }
  });

  group('Plan › Sync text by platform', () {
    const iosText = 'On iPhone, sync the app folder';
    const otherText = 'Install Syncthing on each device';

    Future<void> pumpPlan(WidgetTester tester) async {
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: demoWallet())), size: const Size(400, 8000)); // all rows built
    }

    // The override must be unset before the test body ends (flutter_test checks it then, before any tearDown).
    Future<void> on(WidgetTester tester, TargetPlatform p, Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = p;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('iOS shows the app-folder button and the Möbius Sync text', (tester) async {
      await on(tester, TargetPlatform.iOS, () async {
        await pumpPlan(tester);
        expect(find.textContaining(iosText), findsOneWidget);
        expect(find.textContaining(otherText), findsNothing);
        expect(find.text('Use the app folder'), findsOneWidget);
        expect(find.text('Type path'), findsNothing);
        expect(find.text('Allow file access'), findsNothing);
      });
    });

    testWidgets('Android also offers file access', (tester) async {
      await on(tester, TargetPlatform.android, () async {
        await pumpPlan(tester);
        expect(find.textContaining(otherText), findsOneWidget);
        expect(find.text('Choose folder'), findsOneWidget);
        expect(find.text('Type path'), findsOneWidget);
        expect(find.text('Allow file access'), findsOneWidget);
      });
    });

    testWidgets('Linux has the folder chooser and typed path only', (tester) async {
      await on(tester, TargetPlatform.linux, () async {
        await pumpPlan(tester);
        expect(find.textContaining(otherText), findsOneWidget);
        expect(find.text('Choose folder'), findsOneWidget);
        expect(find.text('Allow file access'), findsNothing);
        expect(find.text('Use the app folder'), findsNothing);
      });
    });
  });

  test('main.dart, screens and widgets do not import dart:io (they must build for the web)', () {
    final files = [
      File('lib/main.dart'),
      for (final d in ['lib/src/screens', 'lib/src/widgets'])
        ...Directory(d).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')),
      File('lib/src/layout.dart'),
      File('lib/src/platform.dart'),
    ].where((f) => f.existsSync()).toList();
    expect(files.length, greaterThan(10));
    final bad = [
      for (final f in files)
        if (RegExp(r'''^\s*(import|export)\s+['"]dart:io['"]''', multiLine: true).hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(bad, isEmpty, reason: 'dart:io in UI code: move the file work into the controller or a native-only file');
  });
}
