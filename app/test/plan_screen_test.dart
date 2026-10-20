// Plan screen: the numbers form. All data is SYNTHETIC.
import 'dart:io';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

Finder _field(String label) => find.widgetWithText(TextField, label);

Future<void> _tapSave(WidgetTester tester) async {
  final btn = find.widgetWithText(FilledButton, 'Save numbers');
  await Scrollable.ensureVisible(tester.element(btn), alignment: 0.5);
  await tester.pump();
  await tester.tap(btn);
}

Future<void> _save(WidgetTester tester) async {
  await _tapSave(tester);
  await tester.pump();
  await tester.pump(const Duration(seconds: 4)); // toast and the controller's sync debounce
}

void main() {
  testWidgets('rent cash threshold is editable in Plan and changes categorisation', (tester) async {
    final wc = demoWallet();
    await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
    expect(wc.txs.where((t) => t.amount == -55000).single.category, 'Rent');
    final f = _field('Cash withdrawal counts as rent from');
    await tester.ensureVisible(f);
    expect(tester.widget<TextField>(f).controller!.text, '500');
    await tester.enterText(f, '600');
    await _save(tester);
    expect(wc.settings.rentCashThreshold, 60000);
    expect(wc.txs.where((t) => t.amount == -55000).single.category, 'Cash');
  });

  group('fields follow the latest settings and Save keeps changes made elsewhere (bug B)', () {
    String text(WidgetTester tester, String label) => tester.widget<TextField>(_field(label)).controller!.text;

    testWidgets('a setting changed by sync shows in its field', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
      expect(text(tester, 'Rent'), '550');
      remoteSetting(wc, 'rent', 61000);
      await tester.pump();
      expect(text(tester, 'Rent'), '610');
    });

    testWidgets('editing one field and saving keeps settings changed elsewhere', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
      remoteSetting(wc, 'rent', 61000); // another device
      wc.updateSettings({'subs': 2500, 'coolHours': 48}); // another screen
      await tester.pump();
      await tester.enterText(_field('Loan'), '300');
      await _save(tester);
      final s = wc.settings;
      expect(s.loan, 30000);
      expect(s.rent, 61000);
      expect(s.subs, 2500);
      expect(s.coolHours, 48);
      expect(s.salary, 150000);
    });

    testWidgets('an edit in progress is not overwritten by sync, and Save writes only that field', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
      await tester.enterText(_field('Rent'), '570');
      remoteSetting(wc, 'rent', 61000);
      remoteSetting(wc, 'salary', 160000);
      await tester.pump();
      expect(text(tester, 'Rent'), '570', reason: 'the user is typing here');
      expect(text(tester, 'Salary per month'), '1600');
      await _save(tester);
      expect(wc.settings.rent, 57000);
      expect(wc.settings.salary, 160000);
      expect(wc.settings.salaryConfirmed, isFalse, reason: 'salary was not edited here');
    });

    testWidgets('Save with nothing edited writes nothing', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
      final before = wc.repo.pendingOps().length;
      await _tapSave(tester);
      await tester.pump();
      expect(find.text('Nothing to save'), findsOneWidget);
      expect(wc.repo.pendingOps().length, before);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('negative wait hours are rejected (bug C)', () {
    for (final input in ['-1', '-72', ' -5 ']) {
      testWidgets('"$input" shows a message and saves nothing', (tester) async {
        final wc = demoWallet();
        await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
        final before = wc.repo.pendingOps().length;
        await tester.enterText(_field('Wait (hours)'), input);
        await tester.enterText(_field('Loan'), '300');
        await _tapSave(tester);
        await tester.pump();
        expect(find.text("Wait (hours) can't be negative."), findsOneWidget);
        expect(find.text("Can't be negative"), findsOneWidget);
        expect(wc.repo.pendingOps().length, before, reason: 'nothing saved, not even the valid loan');
        expect(wc.settings.coolHours, 72);
        expect(wc.settings.loan, 25000);
        await tester.pump(const Duration(seconds: 4));
      });
    }

    testWidgets('fixing the value clears the error and saves', (tester) async {
      final wc = demoWallet();
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
      await tester.enterText(_field('Wait (hours)'), '-3');
      await _tapSave(tester);
      await tester.pump();
      await tester.enterText(_field('Wait (hours)'), '0');
      await tester.pump();
      expect(find.text("Can't be negative"), findsNothing);
      await _save(tester);
      expect(wc.settings.coolHours, 0);
    });
  });

  group('typed sync folder path', () {
    Future<WalletController> open(WidgetTester tester) async {
      final wc = demoWallet();
      wc.syncRunner = (folder, key, repo) async => const SyncReport(0, 0, 0);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)));
      final btn = find.widgetWithText(OutlinedButton, 'Type path');
      await tester.scrollUntilVisible(btn, 300, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(btn);
      await tester.pump();
      await tester.tap(btn);
      await tester.pumpAndSettle();
      return wc;
    }

    Future<void> use(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.tap(find.widgetWithText(FilledButton, 'Use folder'));
      await tester.pumpAndSettle();
    }

    testWidgets('a relative path is refused with a hint and nothing is saved', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux; // flutter_test reports android; the hint differs by platform
      try {
        final wc = await open(tester);
        await use(tester, 'Sync/folder');
        expect(find.text('Enter a full folder path, like /home/you/Sync'), findsOneWidget);
        expect(wc.syncFolder, isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('empty or blank input is refused', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux; // flutter_test reports android; the hint differs by platform
      try {
        final wc = await open(tester);
        await use(tester, '   ');
        expect(find.text('Enter a full folder path, like /home/you/Sync'), findsOneWidget);
        expect(wc.syncFolder, isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a missing folder is refused and not created', (tester) async {
      final wc = await open(tester);
      final tmp = Directory.systemTemp.createTempSync('bw_sync_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final missing = '${tmp.path}/nope';
      await use(tester, missing);
      expect(find.text("This folder doesn't exist."), findsOneWidget);
      expect(wc.syncFolder, isNull);
      expect(Directory(missing).existsSync(), isFalse);
    });

    testWidgets('an existing folder is saved, trimmed', (tester) async {
      final wc = await open(tester);
      final tmp = Directory.systemTemp.createTempSync('bw_sync_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      await use(tester, '  ${tmp.path}  ');
      expect(wc.syncFolder, tmp.path);
      expect(find.text('Sync folder path'), findsNothing);
    });

    test('checkSyncPath expands ~ from HOME and gives the reason it refused', () {
      final tmp = Directory.systemTemp.createTempSync('bw_sync_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      Directory('${tmp.path}/Sync').createSync();
      expect(checkSyncPath('~/Sync', home: tmp.path).path, '${tmp.path}/Sync');
      expect(checkSyncPath('~', home: tmp.path).path, tmp.path);
      expect(checkSyncPath('~/Nope', home: tmp.path).reason, 'missing');
      expect(checkSyncPath('~/Sync', home: '').reason, 'relative');
      expect(checkSyncPath('Sync', home: tmp.path).reason, 'relative');
      expect(checkSyncPath('').reason, 'empty');
    });
  });
}
