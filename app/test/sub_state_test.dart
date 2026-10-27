// The controller's sub-states (SyncState, CalendarState) are Listenables of their own, but the controller notifies its own
// listeners exactly as it did before they existed: the counts below were measured before the sub-states were wired in.
// SYNTHETIC wallet; no device.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

final _relay = Uri.parse('http://relay.local:8787');

void main() {
  late WalletController wc;
  late int controllerCalls, syncCalls, calCalls;

  setUp(() {
    wc = emptyWallet();
    wc.relayUrl = _relay;
    controllerCalls = syncCalls = calCalls = 0;
    wc.addListener(() => controllerCalls++);
    wc.sync.addListener(() => syncCalls++);
    wc.cal.addListener(() => calCalls++);
  });
  tearDown(() => wc.dispose());

  test('a successful sync: the controller notifies as before (start, end); SyncState tells its own listeners once', () async {
    wc.seams.syncRunner = (r, k, repo) async => const SyncReport(0, 0, 0, caughtUp: true);
    await wc.syncNow();
    expect(controllerCalls, 2);
    expect(syncCalls, greaterThanOrEqualTo(1));
    expect(syncCalls, lessThanOrEqualTo(controllerCalls), reason: 'never more often than the controller');
    expect((wc.sync.caughtUp, wc.syncCaughtUp, wc.sync.error, wc.syncing), (true, true, null, false));
    expect(wc.sync.lastSync, isNotNull);
  });

  test('a failed sync: the controller notifies as before; the error is in SyncState', () async {
    wc.seams.syncRunner = (r, k, repo) async => throw const SyncException('offline');
    await wc.syncNow();
    expect(controllerCalls, 2);
    expect(wc.sync.error, 'offline');
    expect(wc.syncError, 'offline');
    expect(syncCalls, inInclusiveRange(1, controllerCalls));
  });

  test('a quiet sync notifies once, at the end', () async {
    wc.seams.syncRunner = (r, k, repo) async => const SyncReport(0, 0, 0);
    await wc.syncNow(quiet: true);
    expect(controllerCalls, 1);
  });

  test('a change that touches no sync status does not tell SyncState listeners', () {
    wc.dismissSyncNotice(relayChanged: true);
    expect(controllerCalls, 1);
    expect(syncCalls, 0);
    expect(calCalls, 0);
  });

  test('setRelay clears the status of the old relay in one step and notifies once', () async {
    wc.sync.caughtUp = true;
    wc.sync.error = 'old problem';
    wc.sync.badFiles = 2;
    controllerCalls = syncCalls = 0;
    await wc.setRelay(null);
    expect(controllerCalls, 1);
    expect((wc.sync.caughtUp, wc.sync.error, wc.sync.badFiles), (false, null, 0));
    expect(syncCalls, 1);
  });

  test('reading a calendar: the controller notifies as before; CalendarState tells its own listeners about the new events', () async {
    final text = fakeIcs([('u1', wc.today(), 'Dentist')]);
    controllerCalls = calCalls = 0;
    await wc.importIcsFile('a.ics', Uint8List.fromList(utf8.encode(text)));
    expect(wc.cal.events, hasLength(1));
    expect(controllerCalls, greaterThan(0));
    expect(calCalls, inInclusiveRange(1, controllerCalls));
  });
}
