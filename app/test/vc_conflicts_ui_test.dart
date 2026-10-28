// Stage V (VC) UI: Settings › Sync › "Choose the right values". Equal-clock conflicts list both values in the owner's words, the two
// buttons report the choice, money follows the number style, and the page fits 320 dp at text scale 2.0 and the dark theme.
// All data is SYNTHETIC. The core half (`repo.syncConflicts`) is not wired yet: these tests drive the page with its own lines.
import 'package:budget_wallet/src/conflict_text.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/sync_conflicts.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/sync_status.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/wallet.dart';

Finder k(String key) => find.byKey(ValueKey(key));

const _lines = [
  ConflictLine(id: 'c1', what: 'Payment 5 Oct · SHOP', field: 'amount', mine: '1.234,50 €', theirs: '12,50 €'),
  ConflictLine(id: 'c2', what: 'Payday', field: 'value', mine: '10', theirs: '25'),
  ConflictLine(id: 'c3', what: 'Payment 6 Oct', field: 'deleted', mine: 'not deleted', theirs: 'deleted'),
];

Future<void> _pump(WidgetTester t, Widget child,
    {Size size = const Size(400, 1400), double scale = 1, Brightness b = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(b),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: child,
  ));
  await t.pump();
}

void main() {
  tearDown(() => numberStyle = NumberStyle.point);

  group('the page', () {
    testWidgets('lists each conflict with both values and the two buttons', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      await _pump(t, ConflictsPage(wc: wc, lines: () => _lines, onChoose: (_, __) {}));
      expect(find.text('Choose the right values'), findsOneWidget);
      for (final l in _lines) {
        expect(k('conflict-${l.id}'), findsOneWidget);
        expect(find.text(l.what), findsOneWidget);
        expect(find.text(l.mine), findsOneWidget);
        expect(find.text(l.theirs), findsOneWidget);
        expect(k('conflictMine-${l.id}'), findsOneWidget);
        expect(k('conflictTheirs-${l.id}'), findsOneWidget);
      }
      expect(find.text('Field: amount'), findsOneWidget);
      expect(find.text('This device'), findsNWidgets(3));
      expect(find.text('Other device'), findsNWidgets(3));
      expect(k('conflictsDone'), findsNothing);
    });

    testWidgets('both choices report the id and keepMine; the row goes; an empty list says all settled', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      final open = [..._lines];
      final chosen = <(String, bool)>[];
      await _pump(
          t,
          ConflictsPage(
              wc: wc,
              lines: () => open,
              onChoose: (id, keepMine) {
                chosen.add((id, keepMine));
                open.removeWhere((l) => l.id == id);
                wc.reload();
              }));
      await t.ensureVisible(k('conflictMine-c1'));
      await t.tap(k('conflictMine-c1'));
      await t.pump();
      expect(chosen, [('c1', true)]);
      expect(k('conflict-c1'), findsNothing);
      await t.ensureVisible(k('conflictTheirs-c2'));
      await t.tap(k('conflictTheirs-c2'));
      await t.pump();
      expect(chosen.last, ('c2', false));
      await t.ensureVisible(k('conflictTheirs-c3'));
      await t.tap(k('conflictTheirs-c3'));
      await t.pump();
      expect(chosen.last, ('c3', false));
      expect(k('conflictsDone'), findsOneWidget);
      expect(find.text('All settled. They sync on the next run.'), findsOneWidget);
      await t.pump(const Duration(seconds: 4)); // the controller's sync debounce
    });

    for (final (name, size, scale, b) in [
      ('320 dp at text scale 2.0', const Size(320, 3000), 2.0, Brightness.light),
      ('dark', const Size(400, 1400), 1.0, Brightness.dark),
      ('wide', const Size(1280, 800), 1.0, Brightness.light),
    ]) {
      testWidgets('fits at $name', (t) async {
        final wc = emptyWallet();
        addTearDown(wc.dispose);
        await _pump(t, ConflictsPage(wc: wc, lines: () => _lines, onChoose: (_, __) {}), size: size, scale: scale, b: b);
        expect(t.takeException(), isNull);
        expect(k('conflictMine-c1'), findsOneWidget);
      });
    }
  });

  group('words and values', () {
    test('money follows the number style; dates, deleted and empty read plainly', () {
      numberStyle = NumberStyle.comma;
      expect(conflictValueText('tx', 'x', 'amount', 123450, 'EUR'), '1.234,50 €');
      numberStyle = NumberStyle.point;
      expect(conflictValueText('tx', 'x', 'amount', 123450, 'EUR'), '1,234.50 €');
      expect(conflictValueText('tx', 'x', 'date', '2026-10-05', 'EUR'), shortDate('2026-10-05'));
      expect(conflictValueText('tx', 'x', 'deleted', 1, 'EUR'), 'deleted');
      expect(conflictValueText('tx', 'x', 'deleted', 0, 'EUR'), 'not deleted');
      expect(conflictValueText('tx', 'x', 'note', null, 'EUR'), 'empty');
      expect(conflictValueText('tx', 'x', 'note', '', 'EUR'), 'empty');
      expect(conflictValueText('tx', 'x', 'note', 'lunch', 'EUR'), 'lunch');
    });

    test('a setting value is stored as JSON text: salary is money, payday is a number', () {
      numberStyle = NumberStyle.comma;
      expect(conflictValueText('setting', 'salary', 'value', '150000', 'EUR'), '1.500 €');
      expect(conflictValueText('setting', 'paydayDay', 'value', '10', 'EUR'), '10');
      expect(conflictValueText('setting', 'paydayDay', 'value', null, 'EUR'), 'empty');
    });

    test('fields in plain words', () {
      expect(conflictFieldWord('tx', 'amount'), 'amount');
      expect(conflictFieldWord('tx', 'category'), 'main tag');
      expect(conflictFieldWord('tx', 'deleted'), 'deleted');
      expect(conflictFieldWord('tx', 'note'), 'note');
      expect(conflictFieldWord('setting', 'value'), 'value');
      expect(conflictFieldWord('recurring', 'next_due'), 'next date');
    });

    test('a payment is named by date and description, a setting by its plain name', () {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB')]));
      wc.reload();
      final id = wc.repo.transactions().single.id;
      final what = conflictWhatText(wc, 'tx', id);
      expect(what, startsWith('Payment ${shortDate('2026-10-05')}'));
      expect(what.toLowerCase(), contains('konzum'));
      expect(conflictWhatText(wc, 'setting', 'paydayDay'), 'Payday');
      expect(conflictWhatText(wc, 'goal', 'g1'), 'Goal');
      expect(conflictWhatText(wc, 'tx', 'gone'), 'Payment');
    });

    test('conflictLineOf formats both sides', () {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      numberStyle = NumberStyle.comma; // after the wallet: opening one sets the style from its settings
      final l = conflictLineOf(wc, id: 'c', entity: 'setting', rowId: 'salary', field: 'value', mine: '123450', theirs: '99000');
      expect(l.what, 'Salary');
      expect(l.mine, '1.234,50 €');
      expect(l.theirs, '990 €');
    });
  });

  group('Settings › Sync', () {
    SyncPanel panel(WalletController wc) => SyncPanel(wc: wc, onShowKey: () {});

    testWidgets('with conflicts: the count text and the Choose button (no Diagnostics button)', (t) async {
      final wc = emptyWallet()..relayUrl = Uri.parse('http://homeserver.local:8787');
      addTearDown(wc.dispose);
      wc.syncProblems = const [SyncProblem('abcd1234', SyncProblemReason.devicesDisagree, bytes: 0)];
      wc.syncConflictCount = 3;
      await _pump(t, Scaffold(body: SingleChildScrollView(child: panel(wc))), size: const Size(320, 3000), scale: 2);
      expect(t.takeException(), isNull);
      expect(find.textContaining('Your devices have 3 different values. Choose the right ones.', findRichText: true), findsOneWidget);
      expect(k('syncChooseValues'), findsOneWidget);
      expect(k('syncDisagreeLogs'), findsNothing);
      expect(find.textContaining(devicesDisagreeText, findRichText: true), findsNothing);
      await t.ensureVisible(k('syncChooseValues'));
      await t.tap(k('syncChooseValues'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Choose the right values'), findsWidgets);
      expect(k('conflictsDone'), findsOneWidget, reason: 'the controller has no lines until core lands');
    });

    testWidgets('without conflicts: today\'s text with the Diagnostics button', (t) async {
      final wc = emptyWallet()..relayUrl = Uri.parse('http://homeserver.local:8787');
      addTearDown(wc.dispose);
      wc.syncProblems = const [SyncProblem('abcd1234', SyncProblemReason.devicesDisagree, bytes: 0)];
      await _pump(t, Scaffold(body: SingleChildScrollView(child: panel(wc))));
      expect(find.textContaining(devicesDisagreeText, findRichText: true), findsOneWidget);
      expect(k('syncDisagreeLogs'), findsOneWidget);
      expect(k('syncChooseValues'), findsNothing);
    });

    test('one conflict reads in the singular', () {
      expect(devicesConflictText(1), 'Your devices have 1 different value. Choose the right one.');
    });
  });
}
