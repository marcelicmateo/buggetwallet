// Stage DK (per-device keys): Settings › Sync › Devices (list, Remove this device, Approve, Require approval), the screen of a
// device that waits for approval or was removed, the older-relay line. The relay's rules come from MemoryTransport.device.
// All data and keys are SYNTHETIC.
import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/calendar_source.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/controller_deps.dart';
import 'package:budget_wallet/src/device_list.dart';
import 'package:budget_wallet/src/device_relay.dart';
import 'package:budget_wallet/src/home_widget.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/sync_status.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

final _relay = Uri.parse('http://homeserver.local:8787');

/// One install: its controller, its view of the relay and how many sync runs it made.
class _Install {
  _Install(this.mem, VaultKey key, String devKey) : repo = WalletRepo.inMemory() {
    t = mem.device(devKey, deviceId: repo.deviceId);
    final deps = WalletControllerDeps.platform(
            nudges: const NoNudges(), calendars: const NoCalendars(), homeWidget: const NoHomeWidget(), billInputs: const BillInputs.none())
        .copyWith(deviceRelayOpener: (relay, k, r) async => DeviceRelay(transport: t, devices: t, fingerprint: () async => t.fingerprint));
    wc = seamedController(repo, key: key, deps: deps)..relayUrl = _relay;
    wc.seams.syncRunner = (relay, k, r) {
      runs++;
      return SyncEngine(t, k).run(r);
    };
  }

  final MemoryTransport mem;
  final WalletRepo repo;
  late final MemoryDeviceTransport t;
  late final WalletController wc;
  int runs = 0;

  String get fp => t.fingerprint;

  /// What the lists call this install: the first 8 characters of its device id.
  String get name => repo.deviceId.substring(0, 8);
}

Future<void> _pump(WidgetTester t, WalletController wc, {Size size = const Size(400, 1600), double scale = 1, bool dark = false}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(dark ? Brightness.dark : Brightness.light),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))),
  ));
  await t.pump();
  await t.pump();
}

Finder _k(String key) => find.byKey(ValueKey(key));

void main() {
  final key = VaultKey.generate();

  /// The relay's clock (the memory relay keeps approval on for 5 minutes after a removal).
  var relayNow = DateTime.now();

  /// Two enrolled installs: A made the wallet, B joined while it was open.
  Future<(_Install, _Install)> twoDevices({bool lockedAfter = false}) async {
    final mem = MemoryTransport(now: () => relayNow);
    final a = _Install(mem, key, 'device-a');
    final b = _Install(mem, key, 'device-b');
    addTearDown(a.wc.dispose);
    addTearDown(b.wc.dispose);
    a.wc.repo.updateSettings({'salary': 111100});
    a.wc.reload();
    await a.wc.syncNow();
    expect(mem.locked, isTrue, reason: 'a new wallet starts with approval required');
    mem.locked = false; // the owner let the second device in without approval
    await b.wc.syncNow();
    expect(mem.enrolledKeys, {a.fp, b.fp});
    if (lockedAfter) mem.locked = true;
    return (a, b);
  }

  group('device list', () {
    testWidgets('each key with its code, this device marked, Remove only on the others', (t) async {
      final (a, b) = await twoDevices();
      await _pump(t, a.wc);
      await t.pump();
      expect(a.wc.deviceList, isNotNull);
      expect(_k('device:${a.fp}'), findsOneWidget);
      expect(_k('device:${b.fp}'), findsOneWidget);
      expect(find.text('${a.name} · this device'), findsOneWidget);
      expect(find.text(b.name), findsOneWidget);
      expect(find.text('Code ${a.fp}'), findsOneWidget);
      expect(find.textContaining('Last seen'), findsWidgets);
      expect(_k('removeDevice:${a.fp}'), findsNothing, reason: 'never this device');
      expect(_k('removeDevice:${b.fp}'), findsOneWidget);
      expect(find.text('Remove this device'), findsOneWidget);
    });

    testWidgets('the only enrolled device cannot be removed', (t) async {
      final mem = MemoryTransport();
      final a = _Install(mem, key, 'device-a');
      addTearDown(a.wc.dispose);
      await a.wc.syncNow();
      await _pump(t, a.wc);
      await t.pump();
      expect(_k('device:${a.fp}'), findsOneWidget);
      expect(find.text('Remove this device'), findsNothing);
      expect(await a.wc.removeDevice(a.fp), isNotNull, reason: 'the controller refuses too');
      expect(mem.revokedKeys, isEmpty);
    });

    testWidgets('a removed key is greyed with its date, without a Remove button', (t) async {
      final (a, b) = await twoDevices();
      expect(await a.wc.removeDevice(b.fp), isNull);
      await _pump(t, a.wc);
      await t.pump();
      expect(find.textContaining('Removed'), findsOneWidget);
      expect(find.byIcon(Icons.block), findsOneWidget);
      expect(_k('removeDevice:${b.fp}'), findsNothing);
    });
  });

  group('remove', () {
    testWidgets('confirm names the device and says approval turns on; Cancel changes nothing; Remove revokes and locks', (t) async {
      final (a, b) = await twoDevices();
      await _pump(t, a.wc);
      await t.pump();
      await t.tap(_k('removeDevice:${b.fp}'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Remove ${b.name}?'), findsOneWidget);
      expect(find.textContaining('Removing a device also turns on'), findsOneWidget);
      await t.tap(_k('removeCancel'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(b.mem.revokedKeys, isEmpty);
      expect(b.mem.locked, isFalse);

      await t.tap(_k('removeDevice:${b.fp}'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      await t.tap(_k('removeConfirm'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(b.mem.revokedKeys, {b.fp});
      expect(b.mem.locked, isTrue);
      expect(t.widget<SwitchListTile>(_k('requireApproval')).value, isTrue, reason: 'the list is read again after the removal');
      expect(_k('deviceRemovedNote'), findsOneWidget);
      expect(find.textContaining('change the wallet key'), findsOneWidget);
      expect(find.textContaining('key rotation steps'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });

    test('the advice stays until OK', () async {
      final (a, b) = await twoDevices();
      await a.wc.removeDevice(b.fp);
      expect(a.wc.deviceRemovedNote, isTrue);
      a.wc.dismissDeviceRemovedNote();
      expect(a.wc.deviceRemovedNote, isFalse);
    });
  });

  group('approve and the switch', () {
    testWidgets('a waiting key shows its code; Approve asks "Does the other device show …?" and enrols it', (t) async {
      final (a, _) = await twoDevices(lockedAfter: true);
      final mem = a.mem;
      final c = _Install(mem, key, 'device-c');
      addTearDown(c.wc.dispose);
      await c.wc.syncNow();
      expect(mem.pendingKeys, {c.fp});
      await _pump(t, a.wc);
      await t.pump();
      expect(find.text('WAITING FOR APPROVAL'), findsOneWidget);
      expect(find.text(c.fp), findsOneWidget);
      await t.tap(_k('approveDevice:${c.fp}'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Does the other device show ${c.fp}?'), findsOneWidget);
      await t.tap(_k('approveCancel'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(mem.pendingKeys, {c.fp});
      await t.tap(_k('approveDevice:${c.fp}'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      await t.tap(_k('approveConfirm'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(mem.enrolledKeys, contains(c.fp));
      expect(_k('approveDevice:${c.fp}'), findsNothing);
      expect(_k('device:${c.fp}'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('Require approval switch turns the relay setting on and off', (t) async {
      final (a, _) = await twoDevices();
      await _pump(t, a.wc);
      await t.pump();
      expect(t.widget<SwitchListTile>(_k('requireApproval')).value, isFalse);
      await t.tap(_k('requireApproval'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(a.mem.locked, isTrue);
      expect(t.widget<SwitchListTile>(_k('requireApproval')).value, isTrue);
      await t.tap(_k('requireApproval'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(a.mem.locked, isFalse);
      await t.pump(const Duration(seconds: 5));
    });

    test('a failed action returns a plain message and leaves the list', () async {
      final (a, b) = await twoDevices();
      a.mem.offline = true;
      expect(await a.wc.setRequireApproval(true), "Couldn't reach the relay. Try again.");
      a.mem.offline = false;
      expect(await a.wc.approveDevice('ABCD-EFGH'), 'That device is no longer waiting.');
      expect(b.mem.locked, isFalse);
    });
  });

  group('this device waits or was removed', () {
    testWidgets('waiting: the code large with a QR; the sync error line stays quiet; approval ends it', (t) async {
      final (a, _) = await twoDevices(lockedAfter: true);
      final c = _Install(a.mem, key, 'device-c');
      addTearDown(c.wc.dispose);
      await c.wc.syncNow();
      expect(c.wc.deviceStop, DeviceStop.pending);
      expect(c.wc.deviceCode, c.fp);
      expect(c.wc.syncError, isNull);
      await _pump(t, c.wc);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.textContaining('On a device you already use, open Settings › Sync › Devices'), findsOneWidget);
      expect(t.widget<Text>(_k('deviceCode')).data, c.fp);
      expect(_k('deviceCodeQr'), findsOneWidget);
      expect(_k('syncError'), findsNothing);

      await a.wc.approveDevice(c.fp);
      await t.tap(_k('deviceCheckAgain'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(c.wc.deviceStop, isNull);
      expect(c.wc.syncError, isNull);
      expect(_k('devicePending'), findsNothing);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('removed: the message, no Sync now, no run by the timer or after a change; a new relay address starts again', (t) async {
      final (a, b) = await twoDevices();
      await a.wc.removeDevice(b.fp);
      await b.wc.syncNow();
      expect(b.wc.deviceStop, DeviceStop.revoked);
      expect(b.wc.syncError, isNull);
      await _pump(t, b.wc);
      expect(find.textContaining(deviceRevokedText, findRichText: true), findsOneWidget);
      expect(t.widget<ButtonStyleButton>(_k('syncNow')).onPressed, isNull);

      final runs = b.runs;
      await b.wc.syncNow(quiet: true, trigger: 'timer');
      await b.wc.syncNow(quiet: true, trigger: 'change');
      await b.wc.syncNow(quiet: true, trigger: 'startup');
      await b.wc.syncNow();
      expect(b.runs, runs, reason: 'a removed device does not try again');

      await b.wc.setRelay(Uri.parse('http://other.local:8787'));
      expect(b.runs, runs + 1, reason: 'a new address is tried once');
      await t.pump(const Duration(seconds: 5));
    });

    test('the stop is read from the engine\'s messages', () async {
      final (a, b) = await twoDevices();
      expect(b.wc.deviceStop, isNull);
      await a.wc.removeDevice(b.fp);
      await b.wc.syncNow();
      expect(b.wc.deviceStop, DeviceStop.revoked);
      expect(deviceStopOf(const SyncException('This device was removed from the wallet.')), DeviceStop.revoked);
      expect(deviceStopOf(const SyncException('The relay is full.')), isNull);
    });

    testWidgets('Today shows one line with the code while waiting, and one when removed', (t) async {
      final (a, b) = await twoDevices();
      a.mem.locked = true;
      final c = _Install(a.mem, key, 'device-c');
      addTearDown(c.wc.dispose);
      await c.wc.syncNow();
      t.view.physicalSize = const Size(400, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      Future<void> pumpToday(WalletController wc) async {
        await t.pumpWidget(MaterialApp(
            theme: buildTheme(Brightness.light),
            home:
                ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {})))));
        await t.pump();
      }

      await pumpToday(c.wc);
      expect(find.text('Waiting for approval: ${c.fp}. Tap for the QR code.'), findsOneWidget);
      await pumpToday(a.wc);
      expect(_k('deviceStopLine'), findsNothing);
      await a.wc.removeDevice(b.fp);
      await b.wc.syncNow();
      await pumpToday(b.wc);
      expect(find.text('This device was removed from the wallet.'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('security review', () {
    test('a new wallet starts locked: the second device waits with its code, and Check again enrols it after approval', () async {
      final mem = MemoryTransport();
      final a = _Install(mem, key, 'device-a');
      final b = _Install(mem, key, 'device-b');
      addTearDown(a.wc.dispose);
      addTearDown(b.wc.dispose);
      a.wc.repo.updateSettings({'salary': 111100});
      a.wc.reload();
      await a.wc.syncNow();
      await b.wc.syncNow();
      expect(b.wc.deviceStop, DeviceStop.pending);
      expect(b.wc.deviceCode, b.fp);
      expect(mem.pendingKeys, {b.fp});
      expect(await a.wc.approveDevice(b.fp), isNull);
      await b.wc.syncNow();
      expect(b.wc.deviceStop, isNull);
      expect(mem.enrolledKeys, {a.fp, b.fp});
    });

    testWidgets('Remove all other devices: strong confirm, every other device removed, approval on, advice shown', (t) async {
      final (a, b) = await twoDevices();
      final c = _Install(a.mem, key, 'device-c');
      addTearDown(c.wc.dispose);
      await c.wc.syncNow();
      expect(a.mem.enrolledKeys, {a.fp, b.fp, c.fp});
      await _pump(t, a.wc);
      await t.pump();
      await t.tap(_k('removeOthers'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text(removeOthersTitle), findsOneWidget);
      expect(find.textContaining('Use this if a phone was lost or stolen'), findsOneWidget);
      expect(find.textContaining("you'll approve them again one by one"), findsOneWidget);
      await t.tap(_k('removeOthersCancel'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(a.mem.enrolledKeys, {a.fp, b.fp, c.fp});
      await t.tap(_k('removeOthers'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      await t.tap(_k('removeOthersConfirm'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(a.mem.enrolledKeys, {a.fp});
      expect(a.mem.revokedKeys, {b.fp, c.fp});
      expect(a.mem.locked, isTrue);
      expect(_k('deviceRemovedNote'), findsOneWidget);
      expect(_k('removeOthers'), findsNothing, reason: 'nothing left to remove');
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('turning approval off with a removed device asks first; with none removed it does not', (t) async {
      final (a, b) = await twoDevices();
      a.mem.locked = true;
      await _pump(t, a.wc);
      await t.pump();
      await t.tap(_k('requireApproval'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(a.mem.locked, isFalse, reason: 'nobody was removed: no question');
      await t.tap(_k('requireApproval'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(a.mem.locked, isTrue);

      await a.wc.removeDevice(b.fp);
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(_k('requireApproval'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text(lockOffWarningText), findsOneWidget);
      await t.tap(_k('lockOffCancel'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(a.mem.locked, isTrue);
      await t.tap(_k('requireApproval'));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      relayNow = relayNow.add(const Duration(minutes: 6)); // past the relay's 5 minutes of approval after a removal
      await t.tap(_k('lockOffConfirm'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(a.mem.locked, isFalse);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('an "off" the relay ignores right after a removal leaves the switch on and says why; later it works', (t) async {
      final (a, b) = await twoDevices();
      await a.wc.removeDevice(b.fp);
      expect(await a.wc.setRequireApproval(false), approvalStaysOnText);
      expect(a.mem.locked, isTrue);
      await _pump(t, a.wc);
      await t.pump();
      expect(t.widget<SwitchListTile>(_k('requireApproval')).value, isTrue);
      relayNow = relayNow.add(const Duration(minutes: 6));
      expect(await a.wc.setRequireApproval(false), isNull);
      expect(a.mem.locked, isFalse);
      await t.pump(const Duration(seconds: 5));
    });

    test('16 devices and a full waiting list have their own messages; neither shows the approval code', () {
      expect(deviceActionError(const TransportException(TransportFailure.tooManyKeys)),
          'This wallet already has 16 devices. Remove one first.');
      expect(deviceActionError(const TransportException(TransportFailure.pendingFull)), contains('Too many devices are waiting'));
      expect(deviceStopOfTransport(const TransportException(TransportFailure.pendingFull)), isNull);
      expect(deviceStopOfTransport(const TransportException(TransportFailure.tooManyKeys)), isNull);
      expect(
          deviceStopOf(const SyncException(
              "Too many devices are waiting for approval. On a device you already use, reject the ones you don't know.")),
          isNull);
      expect(deviceStopOf(const SyncException('This device waits for approval. On a device you already use, open …')), DeviceStop.pending);
    });

    test('the lowest accepted relay api is kept per normalised address, device-local, and passed to every transport', () {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      final other = Uri.parse('http://other.local:8787');
      final first = WalletController.relayTransport(_relay, key, wc.repo);
      addTearDown(first.close);
      final before = first.minApi;
      expect(before, lessThan(5));
      first.onMinApi!(5, 'relayinst1');
      expect(WalletController.minApiFor(wc.repo, _relay), 5);
      // The same address written another way is the same address; another address has no floor.
      final same = WalletController.relayTransport(Uri.parse('http://HomeServer.local:8787/'), key, wc.repo);
      addTearDown(same.close);
      expect(same.minApi, 5);
      final elsewhere = WalletController.relayTransport(other, key, wc.repo);
      addTearDown(elsewhere.close);
      expect(elsewhere.minApi, before);
      expect(WalletController.minApiFor(wc.repo, other), isNull);
    });

    test('a run that fails with an older relay while the floor is 5 says so; the floor stays until the owner enters the address', () async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      wc.relayUrl = _relay;
      const older = SyncException('The relay runs an older version. Update the relay on the home server.');
      wc.seams.syncRunner = (relay, k, r) async => throw older;
      await wc.syncNow();
      expect(wc.syncError, older.message, reason: 'no floor yet: the plain text');

      wc.repo.setLocalValue(WalletController.minApiKey(_relay), '5');
      await wc.syncNow();
      expect(wc.syncError, relayOlderThanBeforeText);
      expect(wc.syncError, contains('enter its address again'));
      // A health check that says a lower api, and more failing runs, never lower the floor.
      wc.seams.healthCheck = (relay) async {};
      await wc.testRelay(_relay);
      await wc.syncNow();
      expect(WalletController.minApiFor(wc.repo, _relay), 5);

      // Entering the address again (here: the same one) is the owner's decision: the floor goes, the plain text comes back.
      await wc.setRelay(_relay);
      expect(WalletController.minApiFor(wc.repo, _relay), isNull);
      expect(wc.syncError, older.message);
    });

    test('a different error is not turned into the older-relay text, floor or not', () async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      wc.relayUrl = _relay;
      wc.repo.setLocalValue(WalletController.minApiKey(_relay), '5');
      wc.seams.syncRunner = (relay, k, r) async => throw const SyncException('The relay is full. Free space on the home server.');
      await wc.syncNow();
      expect(wc.syncError, startsWith('The relay is full'));
    });
  });

  group('older relay', () {
    testWidgets('one line says the relay needs an update, and the plain device list stays', (t) async {
      final mem = MemoryTransport(); // the wallet key alone: no device keys in its state
      final dev = mem.device('device-a');
      final deps = WalletControllerDeps.platform(
              nudges: const NoNudges(),
              calendars: const NoCalendars(),
              homeWidget: const NoHomeWidget(),
              billInputs: const BillInputs.none())
          .copyWith(deviceRelayOpener: (relay, k, repo) async => DeviceRelay(transport: mem, devices: dev, fingerprint: () async => null));
      final wc = seamedController(WalletRepo.inMemory(), key: key, deps: deps)..relayUrl = _relay;
      addTearDown(wc.dispose);
      wc.seams.syncRunner = (relay, k, repo) => SyncEngine(mem, k).run(repo);
      await wc.syncNow();
      await _pump(t, wc);
      await t.pump();
      expect(wc.deviceList, isNull);
      expect(find.text(deviceOlderRelayText), findsOneWidget);
      expect(_k('requireApproval'), findsNothing);
      expect(find.textContaining('· this device'), findsOneWidget);
    });
  });

  group('layout', () {
    for (final dark in [false, true]) {
      testWidgets('320 dp at text scale 2 with a waiting key and a removed one (${dark ? 'dark' : 'light'})', (t) async {
        final (a, b) = await twoDevices();
        final c = _Install(a.mem, key, 'device-c');
        addTearDown(c.wc.dispose);
        await a.wc.removeDevice(b.fp);
        await c.wc.syncNow();
        await _pump(t, a.wc, size: const Size(320, 3200), scale: 2, dark: dark);
        await t.pump();
        expect(find.text('WAITING FOR APPROVAL'), findsOneWidget);
        expect(_k('approveDevice:${c.fp}'), findsOneWidget);
        expect(t.takeException(), isNull);

        await _pump(t, c.wc, size: const Size(320, 3200), scale: 2, dark: dark);
        expect(_k('deviceCodeQr'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pump(const Duration(seconds: 5));
      });
    }
  });
}
