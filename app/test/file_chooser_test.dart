// The system file choosers can throw (Linux without xdg-desktop-portal: DBusServiceUnknownException). The screens must
// show a short message, log the failure without paths, and leave their buttons usable. All data is SYNTHETIC.
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/diagnostics.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

/// Stands in for the portal error; its text names a path, which must never reach the log.
class PortalMissing implements Exception {
  @override
  String toString() => 'PortalMissing: no portal for /home/someone/private-folder';
}

class FailingChooser extends FileChooser {
  int calls = 0;
  FailingChooser();
  @override
  Future<List<PlatformFile>> pickBankFiles() async {
    calls++;
    throw PortalMissing();
  }

  @override
  Future<String?> pickFolder({required String title}) async {
    calls++;
    throw PortalMissing();
  }

  @override
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    calls++;
    throw PortalMissing();
  }
}

Future<void> _tapText(WidgetTester t, String text) async {
  final f = find.text(text);
  await t.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await t.pump();
  await t.tap(f);
  await t.pump();
}

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  testWidgets('Choose files: a failing chooser shows a message, logs the type only and keeps the button usable', (t) async {
    final wc = demoWallet();
    final chooser = FailingChooser();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc, chooser: chooser)));
    await _tapText(t, 'Choose files');
    expect(chooser.calls, 1);
    expect(find.text(chooserFailedMessage), findsOneWidget);
    final button = find.ancestor(of: find.text('Choose files'), matching: find.bySubtype<ButtonStyleButton>());
    expect(t.widget<ButtonStyleButton>(button).onPressed, isNotNull, reason: 'not stuck in the importing state');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final logged = lines.where((l) => l.contains('import.pickerFailed')).toList();
    expect(logged, hasLength(1));
    expect(logged.single, contains('"type":"PortalMissing"'));
    expect(logged.single, isNot(contains('someone')));
    expect(logged.single, isNot(contains('private-folder')));
    // And it can be tried again.
    await t.pump(const Duration(seconds: 4));
    await _tapText(t, 'Choose files');
    expect(chooser.calls, 2);
  });

  testWidgets('Choose folder: a failing chooser shows a message and opens the type-a-path dialog', (t) async {
    final wc = demoWallet();
    final chooser = FailingChooser();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc, chooser: chooser)));
    await _tapText(t, 'Choose folder');
    await t.pump();
    expect(chooser.calls, 1);
    expect(find.text(chooserFailedMessage), findsOneWidget);
    expect(find.text('Sync folder path'), findsOneWidget, reason: 'the folder can be typed or pasted instead');
    expect(find.widgetWithText(FilledButton, 'Use folder'), findsOneWidget);
    expect(wc.syncFolder, isNull);
    final logged = lines.where((l) => l.contains('sync.pickerFailed')).toList();
    expect(logged, hasLength(1));
    expect(logged.single, contains('"type":"PortalMissing"'));
    expect(logged.single, isNot(contains('private-folder')));
  });

  testWidgets('Save logs: a failing save dialog falls back to the sync folder and the panel stays usable', (t) async {
    final wc = demoWallet();
    final dir = Directory.systemTemp.createTempSync('bw-chooser-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    wc.syncFolder = dir.path;
    final chooser = FailingChooser();
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: DiagnosticsPanel(wc: wc, chooser: chooser))));
    // Real file I/O: the tap and the wait run outside the fake clock.
    await t.runAsync(() async {
      await t.tap(find.text('Save logs…'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pump();
    expect(chooser.calls, 1);
    expect(find.textContaining('Saved to'), findsOneWidget);
    final button = find.ancestor(of: find.text('Save logs…'), matching: find.bySubtype<ButtonStyleButton>());
    expect(t.widget<ButtonStyleButton>(button).onPressed, isNotNull, reason: 'not stuck busy');
    final logged = lines.where((l) => l.contains('log.saveDialogFailed')).toList();
    expect(logged, hasLength(1));
    expect(logged.single, contains('"type":"PortalMissing"'));
  });
}
