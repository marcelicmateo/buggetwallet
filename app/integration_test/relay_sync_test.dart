// Relay sync end to end on a desktop: a real relay (relay/ package) runs in this process on 127.0.0.1, device A is the
// app under test (Plan › Sync), device B is a second controller with the same key. SYNTHETIC data only.
// Run: tools/build.sh desktop-test relay_sync. Skipped on Android (the relay would have to run on the host).
import 'dart:io';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/relay.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/harness.dart';

Finder get _address => find.byKey(const ValueKey('relayAddress'));

int _count(WalletController wc, int cents) => wc.txs.where((x) => x.amount.abs() == cents).length;

void main() {
  Harness.init();
  Harness.private(texts: ['127.0.0.1', 'Zebra note', 'Giraffe note', 'Offline note'], cents: [3777, 1250, 1999]);

  testWidgets(
    'two devices sync through a real relay; an outage loses nothing and sync recovers',
    (t) => Harness.guard(() async {
      HttpOverrides.global = null; // flutter_test answers every HttpClient request with 400; this test needs real sockets
      final dataDir = Directory.systemTemp.createTempSync('bw-relay-it');
      addTearDown(() => dataDir.deleteSync(recursive: true));
      var relay = Relay(data: dataDir, log: (_) {});
      final server = (await t.runAsync(() => relay.serve(host: '127.0.0.1', port: 0)))!;
      final port = server.port;
      final addr = 'http://127.0.0.1:$port';
      var relayUp = true;
      addTearDown(() async {
        if (relayUp) await relay.close();
      });

      // Device A: the app, with one expense of its own.
      final a = await Harness.start(t);
      a.addExpense(amount: 1250, category: 'Groceries', note: 'Giraffe note', date: todayIso());
      await t.pumpAndSettle();

      // Device B: same key, own database, the default runner (RelayTransport + SyncEngine).
      final b = WalletController.forTest(WalletRepo.inMemory(), key: a.key);
      addTearDown(b.dispose);
      b.relayUrl = Uri.parse(addr);
      Future<void> syncB() async {
        await t.runAsync(b.syncNow);
        expect(b.syncError, isNull, reason: 'B sync');
      }

      // A: Settings › Sync: type the address, test it, save (the first sync runs).
      await goSettings(t, SettingsSection.sync);
      await scrollTo(t, _address, SettingsScreen);
      await t.enterText(_address, addr);
      await tapVisible(t, find.text('Test connection'));
      await waitFor(t, () => status('Relay reachable').evaluate().isNotEmpty, what: 'Relay reachable');
      await tapVisible(t, find.text('Save address'));
      await waitFor(t, () => a.lastSync != null || a.syncError != null, what: 'the first sync');
      expect(a.syncError, isNull);
      expect(a.relayUrl, Uri.parse(addr));
      expect(status('Up to date'), findsOneWidget);

      // B sees A's expense.
      await syncB();
      expect(_count(b, 1250), 1, reason: "A's expense reached B");
      expect(b.syncDevices.length, 2);

      // B adds an expense; A syncs with the button and shows it.
      b.addExpense(amount: 3777, category: 'Groceries', note: 'Zebra note', date: todayIso());
      await syncB();
      final before = a.lastSync;
      await scrollTo(t, find.text('Sync now'), SettingsScreen);
      await tapVisible(t, find.text('Sync now'));
      await waitFor(t, () => a.lastSync != before, what: 'Sync now');
      expect(a.syncError, isNull);
      expect(status('Up to date'), findsOneWidget);
      expect(a.syncDevices.length, 2);
      expect(find.textContaining('Last seen'), findsNWidgets(2));
      // The device list's own row ("<id> · this device"); Recent changes rows also mention this device (Q9).
      expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').endsWith(' · this device')), findsOneWidget);
      await Harness.shot(t, 'relay_sync/plan-sync');
      await goTab(t, 'Budget');
      await scrollTo(t, find.widgetWithText(TxTile, '−37.77 €'), SpendingScreen);
      expect(find.widgetWithText(TxTile, 'Zebra note'), findsOneWidget);

      // Outage: the relay stops; A keeps its local change and says it cannot reach the relay.
      await t.runAsync(() => relay.close());
      relayUp = false;
      a.addExpense(amount: 1999, category: 'Groceries', note: 'Offline note', date: todayIso());
      await t.pumpAndSettle();
      await goSettings(t, SettingsSection.sync);
      await scrollTo(t, find.text('Sync now'), SettingsScreen);
      await tapVisible(t, find.text('Sync now'));
      await waitFor(t, () => a.syncError != null, what: 'the outage message');
      expect(find.byKey(const ValueKey('syncError')), findsOneWidget);
      expect(status('Up to date'), findsNothing);
      expect(_count(a, 1999), 1, reason: 'the local expense is kept');

      // Recovery: a relay on the same folder and port; the next sync sends what was waiting.
      relay = Relay(data: dataDir, log: (_) {});
      await t.runAsync(() => relay.serve(host: '127.0.0.1', port: port));
      relayUp = true;
      await tapVisible(t, find.text('Sync now'));
      await waitFor(t, () => a.syncError == null && !a.syncing, what: 'recovery');
      expect(status('Up to date'), findsOneWidget);
      await syncB();
      expect(_count(b, 1999), 1, reason: 'the offline expense reached B');

      await Harness.checkLog(allowSevere: true);
    }),
    // The relay runs in the test process: on the emulator the host could not reach it.
    skip: Platform.isAndroid,
  );
}
