// Stage Q9 UI: Settings › Sync › Recent changes. A local edit, an edit that arrived from another device, a deleted payment, "Show more", a
// tap that opens the payment, the layout and the log. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/recent_changes.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 60));

Finder k(String key) => find.byKey(ValueKey(key));

/// 20 Oct 2026 14:02 (local): the wallet's clock and the time every local write is stamped with.
final _at = DateTime(2026, 10, 20, 14, 2);

/// A wallet whose clock and repo clock are [_at], with one bank payment that another device then gave a main tag.
({WalletController wc, String txId}) changesWallet() {
  final repo = WalletRepo.inMemory(now: () => _at.millisecondsSinceEpoch);
  final wc = seamedController(repo, key: VaultKey.generate(), clock: () => _at);
  repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
  ]));
  final id = repo.transactions().single.id;
  repo.applyRemote([
    Op('tx', id, {'category': 'Eating out'}, Hlc(_at.millisecondsSinceEpoch + 60000, 0, 'peer1234').toString()),
  ]);
  wc.reload();
  return (wc: wc, txId: id);
}

Future<void> pumpList(WidgetTester t, WalletController wc, {Size size = const Size(400, 900), double textScale = 1}) async {
  await pumpApp(
      t, ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RecentChanges(wc: wc)))),
      size: size, textScale: textScale);
  await t.pump(const Duration(milliseconds: 100));
}

String lineOf(WidgetTester t, String key) => t.widget<Text>(find.descendant(of: k(key), matching: find.byType(Text))).data!;

String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

void main() {
  testWidgets('a payment edited on another device reads "Today time · other device id · Payment name · category"', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    await pumpList(t, c.wc);
    final line = lineOf(t, 'change:tx:${c.txId}');
    expect(line, startsWith('Today ${hm(_at.add(const Duration(minutes: 1)))} · other device peer · Payment '));
    expect(line, endsWith(' · category'));
    expect(line.toLowerCase(), contains('konzum'));
    expect(line, isNot(contains('eating')), reason: 'the field is named, not the new value');
  }, timeout: _timeout);

  testWidgets('a local change says this device, in owner words, and the newest comes first', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    c.wc.updateSettings({'paydayDay': 10});
    await pumpList(t, c.wc);
    final rows = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('change:'));
    expect(rows, findsWidgets);
    final line = lineOf(t, 'change:setting:paydayDay');
    expect(line, startsWith('Today '));
    expect(line, endsWith(' · this device · Setting paydayDay · value'));
    for (final w in ['kind_hint', 'bank_type', 'transfer_to', 'matched_to']) {
      expect(find.textContaining(w), findsNothing, reason: 'no column names');
    }
    // The local edit came last (the device clock follows what it has merged), so it is above the remote one.
    expect(t.getTopLeft(k('change:setting:paydayDay')).dy, lessThan(t.getTopLeft(k('change:tx:${c.txId}')).dy));
    await t.pump(const Duration(seconds: 4));
  }, timeout: _timeout);

  testWidgets('tapping a payment opens its sheet; other rows are not tappable', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    c.wc.updateSettings({'paydayDay': 10});
    await pumpApp(
        t, ListenableBuilder(listenable: c.wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RecentChanges(wc: c.wc)))));
    await t.tap(k('change:tx:${c.txId}'));
    await t.pumpAndSettle();
    expect(find.byType(TxSheet), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await t.tap(k('change:setting:paydayDay'));
    await t.pumpAndSettle();
    expect(find.byType(TxSheet), findsNothing);
    await t.pump(const Duration(seconds: 4));
  }, timeout: _timeout);

  testWidgets('a deleted payment reads "deleted" and does not open', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    final manual = c.wc.addExpense(amount: 500, category: 'Groceries', note: 'Synthetic bread', date: '2026-10-19');
    c.wc.deleteTransaction(c.wc.repo.transaction(manual)!);
    await pumpList(t, c.wc);
    final line = lineOf(t, 'change:tx:$manual');
    expect(line, endsWith(' · deleted'));
    await t.tap(k('change:tx:$manual'));
    await t.pumpAndSettle();
    expect(find.byType(TxSheet), findsNothing);
    await t.pump(const Duration(seconds: 4));
  }, timeout: _timeout);

  testWidgets('30 show first, Show more adds 30, and the button goes when there is no more', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    for (var i = 0; i < 40; i++) {
      c.wc.repo.addWish('Synthetic wish $i', 1000 + i);
    }
    c.wc.reload();
    await pumpList(t, c.wc, size: const Size(400, 3000));
    final rows = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('change:'));
    expect(rows, findsNWidgets(changesPage));
    await t.tap(k('changesMore'));
    await t.pump();
    final total = c.wc.repo.recentChanges(limit: 1000).length;
    expect(total, inInclusiveRange(41, changesPage * 2 - 1), reason: 'the second page is not full');
    expect(rows, findsNWidgets(total));
    expect(k('changesMore'), findsNothing);
  }, timeout: _timeout);

  testWidgets('an empty wallet says nothing changed yet', (t) async {
    final wc = emptyWallet();
    addTearDown(wc.dispose);
    await pumpList(t, wc);
    expect(k('changesEmpty'), findsOneWidget);
    expect(k('changesMore'), findsNothing);
  }, timeout: _timeout);

  testWidgets('it sits under Devices in Settings › Sync', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: c.wc, onShowKey: () {}))), size: const Size(400, 2400));
    await t.pump(const Duration(milliseconds: 100));
    expect(k('recentChanges'), findsOneWidget);
    expect(find.text('Recent changes'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  }, timeout: _timeout);

  testWidgets('fits 320 dp at text scale 2.0', (t) async {
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    c.wc.updateSettings({'paydayDay': 10});
    await pumpList(t, c.wc, size: const Size(320, 640), textScale: 2);
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 4));
  }, timeout: _timeout);

  testWidgets('the log never holds a label or a device id', (t) async {
    Logger.root.level = Level.ALL;
    final lines = <String>[];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
    final c = changesWallet();
    addTearDown(c.wc.dispose);
    await pumpList(t, c.wc);
    await t.tap(k('change:tx:${c.txId}'));
    await t.pumpAndSettle();
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    final all = lines.join('\n').toLowerCase();
    expect(all, contains('changes.open'));
    expect(all, isNot(contains('konzum')));
    expect(all, isNot(contains('peer1234')));
    await t.pump(const Duration(seconds: 4));
  }, timeout: _timeout);
}
