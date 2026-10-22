// Web-safe platform checks (lib/src/platform.dart) and the rule that UI code does not import dart:io.
// The web-path test below has an allow-list: every file in lib/src except `*_io.dart` is compiled for the browser, so it may not import
// dart:io or a native-only plugin (the `native` regex lists them: path_provider, flutter_secure_storage, flutter_local_notifications,
// device_calendar_plus, the camera / OCR / share plugins). `*_io.dart` files are the only ones allowed to; they are reached through a
// conditional-import barrel (`if (dart.library.js_interop) '..._web.dart'`). A new native plugin goes into that regex in the same commit.
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

  group('Plan › Sync is the same on every platform (relay address, no folder buttons)', () {
    // The override must be unset before the test body ends (flutter_test checks it then, before any tearDown).
    for (final p in [TargetPlatform.iOS, TargetPlatform.android, TargetPlatform.linux]) {
      testWidgets(p.name, (tester) async {
        debugDefaultTargetPlatformOverride = p;
        try {
          await pumpApp(tester, Scaffold(body: PlanScreen(wc: demoWallet())), size: const Size(400, 8000)); // all rows built
          expect(find.widgetWithText(TextField, 'Relay address'), findsOneWidget);
          expect(find.text('Test connection'), findsOneWidget);
          expect(find.text('Show wallet key'), findsOneWidget);
          for (final gone in ['Choose folder', 'Type path', 'Use the app folder', 'Allow file access']) {
            expect(find.text(gone), findsNothing);
          }
          expect(find.textContaining('Syncthing'), findsNothing);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
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

  test('files the web build loads import no dart:io, no native-only plugin and no *_io.dart except through a conditional import', () {
    // Everything in lib/src except the *_io.dart files (including the Android plugin ones: nudge_platform_io, bill_inputs_io,
    // calendar_source_io) is on the web path.
    final webPath = [
      for (final f in Directory('lib/src').listSync().whereType<File>())
        if (f.path.endsWith('.dart') && !f.path.endsWith('_io.dart')) f,
    ];
    expect(webPath.length, greaterThan(15));
    final statement = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]([^;]*);''', multiLine: true);
    final native = RegExp(
        r'^(dart:io|package:path_provider/.*|package:flutter_secure_storage/.*|package:flutter_local_notifications/.*|package:(mobile_scanner|google_mlkit_\w+|receive_sharing_intent|device_calendar_plus)/.*|.*_io\.dart)$');
    final bad = <String>[];
    for (final f in webPath) {
      for (final m in statement.allMatches(f.readAsStringSync())) {
        final uri = m.group(1)!;
        final conditional = m.group(2)!.contains('dart.library.js_interop');
        if (native.hasMatch(uri) && !conditional) bad.add('${f.path}: $uri');
      }
    }
    expect(bad, isEmpty, reason: 'web path files must not load native code directly');
  });

  test('only calendar_source_io.dart imports the calendar plugin', () {
    final plugin = RegExp(r'''^\s*(?:import|export)\s+['"]package:device_calendar_plus/''', multiLine: true);
    final importers = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && plugin.hasMatch(f.readAsStringSync())) f.path.split('/').last,
    ];
    expect(importers, ['calendar_source_io.dart']);
  });
}
