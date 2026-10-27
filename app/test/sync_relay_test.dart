// Sync through the relay: the pure texts, the controller (address, runs, two devices through one MemoryTransport), Plan › Sync
// and joining with an address. The relay itself is a fake (health function, syncRunner). All data is SYNTHETIC.
import 'dart:async';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

final _relay = Uri.parse('http://homeserver.local:8787');

Finder get _address => find.byKey(const ValueKey('relayAddress'));
Finder get _save => find.byKey(const ValueKey('relaySave'));
Finder get _test => find.byKey(const ValueKey('relayTest'));
Finder get _syncNow => find.byKey(const ValueKey('syncNow'));
bool _enabled(WidgetTester t, Finder f) => t.widget<ButtonStyleButton>(f).onPressed != null;

Future<void> _pumpSync(WidgetTester t, WalletController wc, {Size size = const Size(400, 1200), double scale = 1}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: size, textScale: scale);

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  group('texts', () {
    test('status line: up to date, not caught up, waiting (one or more, readable or not)', () {
      expect(syncStatusLine(caughtUp: true, waiting: const []), (text: 'Up to date', good: true));
      expect(syncStatusLine(caughtUp: false, waiting: const []), (text: 'Not caught up yet: matching waits', good: false));
      expect(syncStatusLine(caughtUp: false, waiting: const [SyncWaiting('ab12f3', 12)]),
          (text: 'Waiting for file 12 from device ab12f3', good: false));
      expect(
          syncStatusLine(
              caughtUp: false,
              waiting: const [SyncWaiting('ab12f3', 12, reason: SyncProblemReason.corrupt), SyncWaiting('c9d8e7', 3)]).text,
          'Waiting for file 12 from device ab12f3, which could not be read (and 1 more)');
    });

    test('last seen and clock', () {
      final now = DateTime(2026, 10, 22, 14, 5);
      expect(lastSeenText(null, now), 'never');
      expect(lastSeenText(now.subtract(const Duration(seconds: 20)), now), 'just now');
      expect(lastSeenText(now.subtract(const Duration(minutes: 5)), now), '5 min ago');
      expect(lastSeenText(now.subtract(const Duration(hours: 3)), now), '3 h ago');
      expect(lastSeenText(now.subtract(const Duration(days: 1, hours: 2)), now), '1 day ago');
      expect(lastSeenText(now.subtract(const Duration(days: 9)), now), '9 days ago');
      expect(clockText(DateTime(2026, 1, 1, 7, 3)), '07:03');
    });

    test('relay address: http/https with a host; a bare host gets http; slash dropped; the rest refused', () {
      expect(WalletController.parseRelayAddress('http://homeserver:8787'), Uri.parse('http://homeserver:8787'));
      expect(WalletController.parseRelayAddress('  https://relay.example.org/ '), Uri.parse('https://relay.example.org'));
      expect(WalletController.parseRelayAddress('homeserver:8787'), Uri.parse('http://homeserver:8787'));
      expect(WalletController.parseRelayAddress('http://10.0.0.5:8787/bw/'), Uri.parse('http://10.0.0.5:8787/bw'));
      for (final bad in ['', '   ', 'ftp://host', 'http://', 'http:///x', 'http://a b', 'https://u:p@host', 'http://host?x=1']) {
        expect(WalletController.parseRelayAddress(bad), isNull, reason: bad);
      }
    });

    test('test-connection texts', () {
      expect(relayTestFailureText(TransportFailure.unreachable), "Can't reach the relay");
      expect(relayTestFailureText(TransportFailure.newerApi), 'This relay needs a newer app');
      expect(relayTestFailureText(TransportFailure.olderApi), contains('Update the relay'));
      expect(relayTestFailureText(TransportFailure.clockSkew), contains('date and time'));
      expect(relayTestFailureText(TransportFailure.other), isNot(contains("Can't reach")));
    });
  });

  group('controller', () {
    test('setRelay saves the address on this device, syncs once and logs only set/unset', () async {
      final wc = emptyWallet();
      var runs = 0;
      Uri? used;
      wc.seams.syncRunner = (relay, k, r) async {
        runs++;
        used = relay;
        return const SyncReport(0, 0, 0, caughtUp: true);
      };
      expect(wc.relayUrl, isNull);
      await wc.setRelay(_relay);
      expect(wc.relayUrl, _relay);
      expect(wc.repo.localValue('relayUrl'), _relay.toString());
      expect(used, _relay);
      expect(runs, 1);
      expect(wc.syncCaughtUp, isTrue);
      final log = lines.join('\n');
      expect(log, contains('sync.relay {"set":true}'));
      expect(log, isNot(contains('homeserver')));
      await wc.setRelay(null);
      expect(wc.relayUrl, isNull);
      expect(wc.repo.localValue('relayUrl'), isNull);
      expect(lines.join('\n'), contains('sync.relay {"set":false}'));
      expect(runs, 1, reason: 'clearing the address does not sync');
    });

    test('a bad address throws and changes nothing', () async {
      final wc = emptyWallet();
      await expectLater(wc.setRelay(Uri.parse('ftp://host')), throwsFormatException);
      expect(wc.relayUrl, isNull);
      expect(wc.repo.localValue('relayUrl'), isNull);
    });

    test('syncNow without an address does nothing; with one it keeps caughtUp, waiting and devices', () async {
      final wc = emptyWallet();
      var runs = 0;
      wc.seams.syncRunner = (relay, k, r) async {
        runs++;
        return SyncReport(0, 0, 0, waiting: const [
          SyncWaiting('ab12f3', 4)
        ], devices: [
          SyncDevice('ab12f3', lastSeen: DateTime(2026, 10, 22)),
          const SyncDevice('c9d8e7', isThis: true),
        ]);
      };
      await wc.syncNow();
      expect(runs, 0);
      expect(lines.join('\n'), contains('"reason":"noRelay"'));
      wc.relayUrl = _relay;
      await wc.syncNow();
      expect(runs, 1);
      expect(wc.syncCaughtUp, isFalse);
      expect(wc.syncWaiting.single.seq, 4);
      expect(wc.syncDevices.map((d) => d.device), ['ab12f3', 'c9d8e7']);
      expect(wc.lastSync, isNotNull);
      expect(lines.join('\n'), isNot(contains('homeserver')));
    });

    test('a SyncException shows its message, any other failure a short generic one (never the address)', () async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.seams.syncRunner = (relay, k, r) async => throw const SyncException('Cannot reach the relay.');
      await wc.syncNow();
      expect(wc.syncError, 'Cannot reach the relay.');
      wc.seams.syncRunner = (relay, k, r) async => throw StateError('boom');
      await wc.syncNow();
      expect(wc.syncError, isNot(contains('homeserver')));
      expect(wc.syncError, isNotNull);
      expect(lines.join('\n'), isNot(contains('homeserver')));
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true);
      await wc.syncNow();
      expect(wc.syncError, isNull);
    });

    test('setRelay while a sync runs: old status cleared at once, old result dropped, exactly one follow-up run for the new address',
        () async {
      final wc = emptyWallet();
      final other = Uri.parse('http://second.local:8787');
      final gates = <Completer<SyncReport>>[];
      final used = <Uri>[];
      wc.seams.syncRunner = (relay, k, r) {
        used.add(relay);
        final c = Completer<SyncReport>();
        gates.add(c);
        return c.future;
      };
      wc.relayUrl = _relay;
      final first = wc.syncNow(trigger: 'button');
      await Future<void>.delayed(Duration.zero);
      expect(wc.syncing, isTrue);
      wc.syncCaughtUp = true;
      wc.syncDevices = [SyncDevice('ab12f3', lastSeen: DateTime(2026, 1, 1))];
      wc.syncError = 'old problem';

      final set = wc.setRelay(other); // skipped as busy right now
      expect(wc.syncCaughtUp, isFalse);
      expect(wc.syncDevices, isEmpty);
      expect(wc.syncWaiting, isEmpty);
      expect(wc.syncError, isNull);
      await set;
      await wc.syncNow(quiet: true, trigger: 'change'); // another trigger skipped as busy: still only one follow-up
      expect(gates, hasLength(1));

      gates.single.complete(const SyncReport(0, 0, 0, caughtUp: true, devices: [])); // the OLD relay's answer
      await first;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(wc.syncCaughtUp, isFalse, reason: 'the old relay result is not shown for the new address');
      expect(gates, hasLength(2), reason: 'one follow-up run');
      expect(used, [_relay, other]);
      gates.last.complete(const SyncReport(0, 0, 0, caughtUp: true));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(wc.syncCaughtUp, isTrue);
      expect(wc.syncing, isFalse);
      expect(gates, hasLength(2), reason: 'no further runs');
    });

    test('testRelay passes the failure on and logs only its kind', () async {
      final wc = emptyWallet();
      wc.seams.healthCheck = (relay) async {};
      await wc.testRelay(_relay);
      wc.seams.healthCheck = (relay) async => throw const TransportException(TransportFailure.newerApi, 'api 9');
      await expectLater(wc.testRelay(_relay), throwsA(isA<TransportException>()));
      final log = lines.join('\n');
      expect(log, contains('sync.health {"ok":true}'));
      expect(log, contains('"failure":"newerApi"'));
      expect(log, isNot(contains('homeserver')));
    });

    test('two controllers with one key sync through one MemoryTransport', () async {
      final key = VaultKey.generate();
      final mem = MemoryTransport();
      Future<SyncReport> run(Uri relay, VaultKey k, WalletRepo repo) => SyncEngine(mem, k).run(repo);
      final a = seamedController(WalletRepo.inMemory(), key: key)
        ..seams.syncRunner = run
        ..relayUrl = _relay;
      final b = seamedController(WalletRepo.inMemory(), key: key)
        ..seams.syncRunner = run
        ..relayUrl = _relay;
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      a.repo.updateSettings({'salary': 123400});
      a.reload();
      await a.syncNow();
      expect(a.syncError, isNull);
      await b.syncNow();
      expect(b.syncError, isNull);
      expect(b.settings.salary, 123400);
      expect(b.syncDevices.length, 2);
      expect(b.syncDevices.where((d) => d.isThis), hasLength(1));
      await a.syncNow();
      expect(a.syncCaughtUp, isTrue);
      expect(b.syncCaughtUp, isTrue);
    });
  });

  group('Plan › Sync', () {
    testWidgets('no address: buttons that need one are off and the text says so', (t) async {
      final wc = emptyWallet();
      await _pumpSync(t, wc);
      expect(find.text('SYNC'), findsOneWidget);
      expect(find.text('Relay address'), findsOneWidget);
      expect(find.textContaining('No relay set'), findsOneWidget);
      expect(_enabled(t, _syncNow), isFalse);
      expect(find.byKey(const ValueKey('showKey')), findsOneWidget);
      expect(find.textContaining('Syncthing'), findsNothing);
    });

    testWidgets('a bad address is refused with a hint and nothing is saved', (t) async {
      final wc = emptyWallet();
      await _pumpSync(t, wc);
      for (final bad in ['ftp://host', 'http://', 'not an address']) {
        await t.enterText(_address, bad);
        await t.tap(_save);
        await t.pump();
        expect(find.textContaining('Enter an address like http://homeserver:8787'), findsOneWidget, reason: bad);
        expect(wc.relayUrl, isNull);
      }
      await t.enterText(_address, 'http://ok:8787'); // typing clears the error
      await t.pump();
      expect(find.textContaining('Enter an address like http://homeserver:8787'), findsNothing);
    });

    testWidgets('a good address is saved (trimmed), synced, and the status shows', (t) async {
      final wc = emptyWallet();
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, caughtUp: true);
      await _pumpSync(t, wc);
      await t.enterText(_address, '  http://homeserver.local:8787/ ');
      await t.tap(_save);
      await t.pumpAndSettle();
      expect(wc.relayUrl, _relay);
      expect(find.textContaining('Up to date'), findsOneWidget);
      expect(find.textContaining('Last sync '), findsOneWidget);
      expect(_enabled(t, _syncNow), isTrue);
    });

    testWidgets('an empty address clears the relay', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      await _pumpSync(t, wc);
      await t.enterText(_address, '');
      await t.tap(_save);
      await t.pump();
      expect(wc.relayUrl, isNull);
      expect(find.textContaining('No relay set'), findsOneWidget);
    });

    for (final (name, failure, text) in <(String, TransportFailure?, String)>[
      ('reachable', null, 'Relay reachable'),
      ('unreachable', TransportFailure.unreachable, "Can't reach the relay"),
      ('newer API', TransportFailure.newerApi, 'This relay needs a newer app'),
    ]) {
      testWidgets('Test connection: $name', (t) async {
        final wc = emptyWallet();
        Uri? asked;
        wc.seams.healthCheck = (relay) async {
          asked = relay;
          if (failure != null) throw TransportException(failure, 'x');
        };
        await _pumpSync(t, wc);
        await t.enterText(_address, 'homeserver.local:8787');
        await t.tap(_test);
        await t.pumpAndSettle();
        expect(find.textContaining(text), findsOneWidget);
        expect(asked, _relay, reason: 'a bare host gets http://');
        expect(wc.relayUrl, isNull, reason: 'testing does not save');
        await t.enterText(_address, 'homeserver.local:8788'); // editing clears the old answer
        await t.pump();
        expect(find.textContaining(text), findsNothing);
      });
    }

    testWidgets('Test connection with no address asks for one', (t) async {
      await _pumpSync(t, emptyWallet());
      await t.tap(_test);
      await t.pump();
      expect(find.textContaining('Enter the relay address first.'), findsOneWidget);
    });

    testWidgets('status: waiting for a file, not caught up, and the last sync time', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, waiting: [SyncWaiting('ab12f3', 12)]);
      await wc.syncNow();
      await _pumpSync(t, wc);
      expect(find.textContaining('Waiting for file 12 from device ab12f3'), findsOneWidget);
      expect(find.textContaining('Last sync '), findsOneWidget);
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0);
      await wc.syncNow();
      await t.pump();
      expect(find.textContaining('Not caught up yet: matching waits'), findsOneWidget);
    });

    testWidgets('the devices are listed with last seen and "this device"', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.seams.syncRunner = (relay, k, r) async => SyncReport(0, 0, 0, caughtUp: true, devices: [
            SyncDevice('ab12f3', lastSeen: DateTime.now().subtract(const Duration(hours: 3))),
            SyncDevice('c9d8e7', lastSeen: DateTime.now(), isThis: true),
          ]);
      await wc.syncNow();
      await _pumpSync(t, wc);
      expect(find.text('DEVICES'), findsNothing); // a sub-heading, not an eyebrow
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('ab12f3'), findsOneWidget);
      expect(find.text('c9d8e7 · this device'), findsOneWidget);
      expect(find.text('Last seen 3 h ago'), findsOneWidget);
      expect(find.text('Last seen just now'), findsOneWidget);
    });

    testWidgets('a sync error shows its message and the unreadable-files note', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.seams.syncRunner = (relay, k, r) async => throw const SyncException('This relay belongs to another wallet.');
      await wc.syncNow();
      await _pumpSync(t, wc);
      expect(find.textContaining('This relay belongs to another wallet.'), findsOneWidget);
      expect(find.textContaining('Up to date'), findsNothing);
      wc.seams.syncRunner = (relay, k, r) async => const SyncReport(0, 0, 0, problems: [
            SyncProblem('ab12f3', SyncProblemReason.corrupt, bytes: 10),
          ]);
      await wc.syncNow();
      await t.pump();
      expect(find.textContaining('1 sync file could not be read'), findsOneWidget);
    });

    testWidgets('Sync now runs a sync', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      var runs = 0;
      wc.seams.syncRunner = (relay, k, r) async {
        runs++;
        return const SyncReport(0, 0, 0, caughtUp: true);
      };
      await _pumpSync(t, wc);
      await t.tap(_syncNow);
      await t.pumpAndSettle();
      expect(runs, 1);
    });

    for (final (w, h, scale) in [(320.0, 700.0, 2.0), (360.0, 800.0, 1.0), (1280.0, 800.0, 1.0)]) {
      testWidgets('layout at ${w.toInt()} dp, text ${scale}x: no overflow with every row shown', (t) async {
        final wc = emptyWallet()..relayUrl = _relay;
        wc.seams.syncRunner = (relay, k, r) async => SyncReport(0, 0, 0, waiting: const [
              SyncWaiting('ab12f3', 123456, reason: SyncProblemReason.corrupt),
              SyncWaiting('c9d8e7', 4),
            ], problems: [
              const SyncProblem('ab12f3', SyncProblemReason.corrupt, bytes: 10)
            ], devices: [
              SyncDevice('ab12f3', lastSeen: DateTime.now().subtract(const Duration(days: 12))),
              const SyncDevice('c9d8e7', isThis: true),
            ]);
        await wc.syncNow();
        final errors = Errors();
        await _pumpSync(t, wc, size: Size(w, h), scale: scale);
        await t.enterText(_address, 'http://a-rather-long-host-name-for-the-home-server.local:8787');
        await t.ensureVisible(_test);
        await t.tap(_test);
        await t.pump();
        scanFlex(t);
        errors.check();
      });
    }
  });

  group('joining with an address', () {
    Future<WalletController> pumpJoin(WidgetTester t, {Size size = const Size(400, 1000), double scale = 1}) async {
      final wc = emptyWallet(withKey: false);
      wc.seams.keyWriter = (k, {passphrase}) async {};
      await pumpApp(t, OnboardingScreen(wc: wc), size: size, textScale: scale);
      await t.tap(find.byKey(const ValueKey('joinStart')));
      await t.pump();
      return wc;
    }

    testWidgets('key + address: the key is saved, the address kept, the first sync runs', (t) async {
      final key = VaultKey.generate();
      final wc = await pumpJoin(t);
      Uri? used;
      wc.seams.syncRunner = (relay, k, r) async {
        used = relay;
        return const SyncReport(0, 0, 0, caughtUp: true);
      };
      await t.enterText(find.widgetWithText(TextField, 'Wallet key'), await key.toText());
      await t.enterText(_address, 'homeserver.local:8787');
      await t.tap(find.byKey(const ValueKey('joinWallet')));
      await t.pumpAndSettle();
      expect(wc.hasWallet, isTrue);
      expect(wc.relayUrl, _relay);
      expect(used, _relay);
      expect(wc.repo.localValue('relayUrl'), _relay.toString());
      final log = lines.join('\n');
      expect(log, contains('wallet.join {"relay":true}'));
      expect(log, isNot(contains('homeserver')));
    });

    testWidgets('the address is optional: joining without one still works and no sync runs', (t) async {
      final key = VaultKey.generate();
      final wc = await pumpJoin(t);
      var runs = 0;
      wc.seams.syncRunner = (relay, k, r) async {
        runs++;
        return const SyncReport(0, 0, 0);
      };
      await t.enterText(find.widgetWithText(TextField, 'Wallet key'), await key.toText());
      await t.tap(find.byKey(const ValueKey('joinWallet')));
      await t.pumpAndSettle();
      expect(wc.hasWallet, isTrue);
      expect(wc.relayUrl, isNull);
      expect(runs, 0);
    });

    testWidgets('a bad address is refused before anything is joined', (t) async {
      final key = VaultKey.generate();
      final wc = await pumpJoin(t);
      await t.enterText(find.widgetWithText(TextField, 'Wallet key'), await key.toText());
      await t.enterText(_address, 'ftp://nope');
      await t.tap(find.byKey(const ValueKey('joinWallet')));
      await t.pump();
      expect(find.textContaining('Enter the relay address like http://homeserver:8787'), findsOneWidget);
      expect(wc.hasWallet, isFalse);
      expect(wc.relayUrl, isNull);
    });

    testWidgets('fits 320 dp at text scale 2.0', (t) async {
      await pumpJoin(t, size: const Size(320, 3000), scale: 2); // tall: every row is built, only the width is tested
      expect(t.takeException(), isNull);
      expect(_address, findsOneWidget);
    });
  });
}
