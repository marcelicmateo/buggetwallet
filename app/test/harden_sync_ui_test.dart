// Stage H, app half (HU 8-10): Plan › Sync shows the relay fingerprint and the new problem texts, the create token is
// device-local and never logged, a refused write (clock behind) says one sentence, and a public http:// relay address is refused.
// The relay is a fake or a loopback socket. All data is SYNTHETIC.
import 'dart:io';

import 'package:budget_wallet/src/clock_notice.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/sync_panel.dart';
import 'package:budget_wallet/src/sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

final _relay = Uri.parse('http://homeserver.local:8787');
const _token = 'tok-SYNTHETIC-123';

Finder get _address => find.byKey(const ValueKey('relayAddress'));
Finder get _save => find.byKey(const ValueKey('relaySave'));
Finder get _tokenField => find.byKey(const ValueKey('relayCreateToken'));
Finder get _tokenSave => find.byKey(const ValueKey('relayCreateTokenSave'));

Future<void> _pumpSync(WidgetTester t, WalletController wc, {Size size = const Size(400, 2000), double scale = 1}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: SyncPanel(wc: wc, onShowKey: () {}))), size: size, textScale: scale);

SyncReport _report({String? instance, bool changed = false, List<SyncProblem> problems = const []}) =>
    SyncReport(0, 0, 0, caughtUp: true, relayInstance: instance, relayChanged: changed, problems: problems);

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });
  String log() => lines.join('\n');

  group('relay address (item 10)', () {
    const ok = [
      'https://relay.example.org',
      'https://203.0.113.5:8787',
      'http://localhost:8787',
      'http://127.0.0.1:8787',
      'http://127.1.2.3',
      'http://[::1]:8787',
      'http://10.0.0.5:8787',
      'http://10.255.255.255',
      'http://172.16.0.1',
      'http://172.20.4.4:8787',
      'http://172.31.255.255',
      'http://192.168.1.20:8787',
      'http://10.0.2.2:8787',
      'http://homeserver.local:8787',
      'http://HomeServer.LOCAL',
      'http://homeserver:8787', // no dot: a home-network name
      'homeserver:8787', // a bare host gets http
      '192.168.0.9:8787',
    ];
    const publicHttp = [
      'http://relay.example.org',
      'http://203.0.113.5:8787',
      'http://8.8.8.8',
      'http://172.15.0.1',
      'http://172.32.0.1',
      'http://192.169.1.1',
      'http://11.0.0.1',
      'http://192.168.1.1.example.org', // looks private, is a public name
      'http://notlocal.example.com',
      'relay.example.org:8787', // a bare host gets http, which a public host may not use
    ];
    test('https and every private, loopback or .local http address is accepted', () {
      for (final a in ok) {
        expect(WalletController.relayAddressIssue(a), isNull, reason: a);
        expect(WalletController.parseRelayAddress(a), isNotNull, reason: a);
      }
    });

    test('public http:// is refused with its own reason; junk keeps the old one', () {
      for (final a in publicHttp) {
        expect(WalletController.relayAddressIssue(a), RelayAddressIssue.needsHttps, reason: a);
        expect(WalletController.parseRelayAddress(a), isNull, reason: a);
      }
      for (final a in ['ftp://host', 'http://', 'not an address', '']) {
        expect(WalletController.relayAddressIssue(a), RelayAddressIssue.notAnAddress, reason: a);
      }
    });

    test('setRelay and joinWallet refuse a public http address too; nothing is saved', () async {
      final wc = emptyWallet();
      await expectLater(wc.setRelay(Uri.parse('http://relay.example.org:8787')), throwsFormatException);
      expect(wc.relayUrl, isNull);
      expect(wc.repo.localValue('relayUrl'), isNull);
      await wc.setRelay(Uri.parse('https://relay.example.org'));
      expect(wc.relayUrl, Uri.parse('https://relay.example.org'));
      expect(log(), isNot(contains('example.org')));
    });

    testWidgets('Plan › Sync says to use the https address and saves nothing', (t) async {
      final wc = emptyWallet();
      await _pumpSync(t, wc);
      await t.enterText(_address, 'http://relay.example.org:8787');
      await t.tap(_save);
      await t.pump();
      expect(find.text(addressNeedsHttpsText), findsOneWidget);
      expect(addressNeedsHttpsText, contains('https://'));
      expect(wc.relayUrl, isNull);
      await t.enterText(_address, 'https://relay.example.org');
      await t.pump();
      expect(find.text(addressNeedsHttpsText), findsNothing);
      expect(log(), isNot(contains('example.org')));
    });

    testWidgets('joining with a public http address is refused with the same text', (t) async {
      final wc = emptyWallet(withKey: false);
      await pumpApp(t, OnboardingScreen(wc: wc), size: const Size(400, 1400));
      await t.tap(find.byKey(const ValueKey('joinStart')));
      await t.pump();
      await t.enterText(find.widgetWithText(TextField, 'Wallet key'), await VaultKey.generate().toText());
      await t.enterText(find.byKey(const ValueKey('relayAddress')), 'http://relay.example.org');
      await t.tap(find.byKey(const ValueKey('joinWallet')));
      await t.pump();
      expect(find.textContaining(addressNeedsHttpsText), findsOneWidget);
      expect(wc.hasWallet, isFalse);
    });
  });

  group('Plan › Sync texts (item 8)', () {
    test('the three new texts are the plain sentences', () {
      expect(relayChangedText, 'This relay is new or was reset; this device sent everything again.');
      expect(deviceIdInUseText, 'Another install used this device id; this device now syncs under a new stream.');
      expect(clockDriftText, "A device's clock is ahead; its changes wait until the clocks agree.");
      expect(createTokenText, 'The relay needs its creation token.');
      expect(relayTestFailureText(TransportFailure.createToken), createTokenText);
    });

    testWidgets('fingerprint under the address; relayChanged line only for the run that saw the change', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      await _pumpSync(t, wc);
      expect(find.byKey(const ValueKey('relayFingerprint')), findsNothing);
      wc.syncRunner = (r, k, repo) async => _report(instance: 'A1B2C3D4E5F60718', changed: true);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(wc.relayFingerprintText, relayFingerprint('A1B2C3D4E5F60718'));
      expect(find.textContaining('a1b2-c3d4'), findsOneWidget);
      expect(find.textContaining(relayChangedText, findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('relayChanged')), findsOneWidget);
      wc.syncRunner = (r, k, repo) async => _report(instance: 'A1B2C3D4E5F60718');
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(find.textContaining(relayChangedText, findRichText: true), findsNothing);
      expect(find.textContaining('a1b2-c3d4'), findsOneWidget);
      expect(log(), isNot(contains('a1b2')));
    });

    testWidgets('an older relay (no instance): no fingerprint line', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.syncRunner = (r, k, repo) async => _report();
      await _pumpSync(t, wc);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(find.byKey(const ValueKey('relayFingerprint')), findsNothing);
    });

    testWidgets('deviceIdInUse is information only (no button); clockDrift is a warning line', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.syncRunner = (r, k, repo) async => _report(problems: const [
            SyncProblem('abcd1234', SyncProblemReason.deviceIdInUse, bytes: 0),
            SyncProblem('ef567890', SyncProblemReason.clockDrift, bytes: 120),
          ]);
      await _pumpSync(t, wc);
      expect(find.textContaining(deviceIdInUseText, findRichText: true), findsNothing);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(find.textContaining(deviceIdInUseText, findRichText: true), findsOneWidget);
      expect(find.textContaining(clockDriftText, findRichText: true), findsOneWidget);
      expect(find.textContaining('new device id', findRichText: true), findsNothing);
      expect(find.byIcon(Icons.info_outline), findsWidgets);
      expect(log(), isNot(contains('abcd1234')));
      expect(log(), isNot(contains('ef567890')));
    });

    testWidgets('changing the address clears the fingerprint and the notes of the old relay', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.syncRunner = (r, k, repo) async => _report(instance: 'A1B2C3D4E5F60718', changed: true);
      await _pumpSync(t, wc);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(find.textContaining(relayChangedText, findRichText: true), findsOneWidget);
      wc.syncRunner = (r, k, repo) async => throw const SyncException('x');
      await t.runAsync(() => wc.setRelay(Uri.parse('http://other.local:8787')));
      await t.pump();
      expect(find.textContaining(relayChangedText, findRichText: true), findsNothing);
      expect(wc.relayFingerprintText, isNull);
    });

    testWidgets('fits 320 dp at text scale 2.0 with every line showing', (t) async {
      final wc = emptyWallet()..relayUrl = _relay;
      wc.syncRunner = (r, k, repo) async => _report(instance: 'A1B2C3D4E5F60718', changed: true, problems: const [
            SyncProblem('abcd1234', SyncProblemReason.deviceIdInUse, bytes: 0),
            SyncProblem('ef567890', SyncProblemReason.clockDrift, bytes: 120),
          ]);
      await _pumpSync(t, wc, size: const Size(320, 4000), scale: 2);
      await t.runAsync(wc.syncNow);
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.textContaining(relayChangedText, findRichText: true), findsOneWidget);
      expect(_tokenField, findsOneWidget);
    });
  });

  group('create token (item 8)', () {
    testWidgets('obscured field; saving keeps it on this device only and never logs it', (t) async {
      final wc = emptyWallet();
      await _pumpSync(t, wc);
      expect(t.widget<TextField>(_tokenField).obscureText, isTrue);
      await t.enterText(_tokenField, '  $_token ');
      await t.tap(_tokenSave);
      await t.pump();
      expect(wc.relayCreateToken, _token);
      expect(wc.repo.localValue(relayCreateTokenKey), _token);
      // never synced, never in a backup or the outbox
      expect(wc.repo.snapshotOps().map((o) => o.toString()).join(), isNot(contains(_token)));
      expect(wc.repo.db.select('SELECT * FROM outbox').toString(), isNot(contains(_token)));
      expect(log(), isNot(contains(_token)));
      expect(log(), contains('sync.createToken'));
      await t.enterText(_tokenField, '');
      await t.tap(_tokenSave);
      await t.pump();
      expect(wc.relayCreateToken, '');
      expect(wc.repo.localValue(relayCreateTokenKey), isNull);
    });

    testWidgets('submitting from the keyboard saves too, and the saved value is shown again on the next visit', (t) async {
      final wc = emptyWallet();
      await _pumpSync(t, wc);
      await t.enterText(_tokenField, _token);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(wc.relayCreateToken, _token);
      await _pumpSync(t, wc);
      expect(t.widget<TextField>(_tokenField).controller!.text, _token);
    });

    test('the real sync sends it as X-BW-Create-Token on the first file, and an empty token sends no header', () async {
      final seen = <String, String?>{};
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null; // flutter_test answers every request with 400; this test needs the loopback socket
      addTearDown(() => HttpOverrides.global = overrides);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        if (req.method == 'PUT') seen[req.uri.pathSegments.last] = req.headers.value('x-bw-create-token');
        await req.drain<void>();
        req.response.statusCode = 404; // the run fails after the first upload: the header is all this test reads
        await req.response.close();
      });
      for (final token in [_token, '']) {
        final wc = emptyWallet();
        wc.repo.addTransaction(date: wc.today(), amount: -1000, category: 'Groceries');
        await wc.setRelayCreateToken(token); // before the address: with an address it would sync at once
        wc.relayUrl = Uri.parse('http://127.0.0.1:${server.port}');
        seen.clear();
        await wc.syncNow(trigger: 'test');
        expect(seen['1'], token.isEmpty ? isNull : _token, reason: 'token "$token"; saw $seen');
        expect(log(), isNot(contains(_token)));
      }
    });
  });

  group('clock behind (item 9)', () {
    test('the sentence has no values', () {
      expect(clockBehindText, "This device's clock is behind. Set the date and time, then try again.");
      expect(clockBehindText, isNot(matches(RegExp(r'\d'))));
    });

    testWidgets('a refused write from any screen shows the sentence once; OK closes it; nothing else breaks', (t) async {
      // The app's real error hooks (logging.dart); the test binding's handler stays behind them.
      final prev = FlutterError.onError;
      await t.runAsync(AppLog.init);
      addTearDown(() => FlutterError.onError = prev);

      var wall = DateTime(2026, 10, 20, 12).millisecondsSinceEpoch;
      final repo = WalletRepo.inMemory(now: () => wall);
      final wc = WalletController.forTest(repo, key: VaultKey.generate(), clock: () => DateTime(2026, 10, 20, 12));
      wc.snoozeKeyBackup();
      repo.updateSettings({'reviewDay': 3}); // a write at 12:00 sets the device's highest reading
      wc.reload();

      await pumpFull(t, wc, 1, size: const Size(400, 6000));
      await tapTab(t, 'Plan');
      wall -= 3 * 3600 * 1000; // the date or time was set back by hours

      final chip = find.byKey(const ValueKey('reviewDay:5'));
      await t.ensureVisible(chip);
      await t.pump();
      await t.tap(chip);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('clockBehindDialog')), findsOneWidget);
      expect(find.text(clockBehindText), findsOneWidget);
      expect(wc.reviewDay, 3, reason: 'nothing was written');
      expect(log(), contains('write.clockBehind'));
      expect(log(), isNot(contains('zone.error')));
      expect(log(), isNot(contains('flutter.error')));

      await t.tap(find.byKey(const ValueKey('clockBehindOk')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('clockBehindDialog')), findsNothing);

      // set the clock right: the same chip writes
      wall += 3 * 3600 * 1000;
      await t.tap(chip);
      await t.pump();
      expect(wc.reviewDay, 5);
      await t.pump(const Duration(seconds: 5));
    });

    test('noticeClockBehind takes only that exception', () {
      final before = clockBehindNotice.value;
      expect(noticeClockBehind(StateError('x')), isFalse);
      expect(clockBehindNotice.value, before);
      expect(noticeClockBehind(const ClockBehindException()), isTrue);
      expect(clockBehindNotice.value, before + 1);
    });
  });
}
