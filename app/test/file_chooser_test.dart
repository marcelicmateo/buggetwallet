// The system file choosers can throw (Linux without xdg-desktop-portal: DBusServiceUnknownException). The screens must
// show a short message, log the failure without paths, and leave their buttons usable. All data is SYNTHETIC.
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
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    calls++;
    throw PortalMissing();
  }
}

Future<void> _tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
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
    await _tapKey(t, 'planImport');
    expect(chooser.calls, 1);
    expect(find.text(chooserFailedMessage), findsOneWidget);
    final button = find.byKey(const ValueKey('planImport'));
    expect(t.widget<ButtonStyleButton>(button).onPressed, isNotNull, reason: 'not stuck in the importing state');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final logged = lines.where((l) => l.contains('import.pickerFailed')).toList();
    expect(logged, hasLength(1));
    expect(logged.single, contains('"type":"PortalMissing"'));
    expect(logged.single, isNot(contains('someone')));
    expect(logged.single, isNot(contains('private-folder')));
    // And it can be tried again.
    await t.pump(const Duration(seconds: 4));
    await _tapKey(t, 'planImport');
    expect(chooser.calls, 2);
  });

  testWidgets('Save logs: a failing save dialog says so and the panel stays usable', (t) async {
    final wc = demoWallet();
    final chooser = FailingChooser();
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: DiagnosticsPanel(wc: wc, chooser: chooser))));
    // The log files are real I/O: the tap and the wait run outside the fake clock.
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('logsSave')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await t.pump();
    expect(chooser.calls, 1);
    expect(find.text("Couldn't save the logs."), findsOneWidget);
    final button = find.byKey(const ValueKey('logsSave'));
    expect(t.widget<ButtonStyleButton>(button).onPressed, isNotNull, reason: 'not stuck busy');
    final logged = lines.where((l) => l.contains('log.saveDialogFailed')).toList();
    expect(logged, hasLength(1));
    expect(logged.single, contains('"type":"PortalMissing"'));
  });
}
