// The wallet key screens (HU 11): QR first with the text behind "Show as text", and on Android the window is secure
// (`bw/secure` setSecure) while a key view is open. The channel is mocked. The keys are random and SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/secure_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

Widget _opener(WalletController wc, {required bool sheet}) => Scaffold(
    body: Builder(
        builder: (c) => TextButton(
            onPressed: () => sheet ? openKeyBackup(c, wc) : showWalletKey(c, wc), child: Text(sheet ? 'open sheet' : 'open key'))));

void main() {
  late List<String> lines;
  late List<Object?> calls; // the argument of each setSecure call
  PlatformException? channelError;

  setUp(() {
    resetSecureWindowCount();
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
    calls = [];
    channelError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('bw/secure'),
        (call) async {
      expect(call.method, 'setSecure');
      calls.add(call.arguments);
      if (channelError != null) throw channelError!;
      return null;
    });
    addTearDown(() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('bw/secure'), null));
  });

  Future<void> open(WidgetTester t, String label) async {
    await t.tap(find.text(label));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500)); // the route is removed one frame after its animation ends
    await t.pump(const Duration(milliseconds: 50)); // the channel call after dispose
  }

  group('Android: the window is secure while the key is shown', () {
    testWidgets('save-key sheet: on when it opens, off when "Later" closes it', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, _opener(wc, sheet: true));
      expect(calls, isEmpty);
      await open(t, 'open sheet');
      expect(calls, [true]);
      await t.ensureVisible(find.byKey(const ValueKey('keyLater')));
      await t.tap(find.byKey(const ValueKey('keyLater')));
      await settle(t);
      expect(calls, [true, false]);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('save-key sheet dismissed by the back button: off again', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, _opener(wc, sheet: true));
      await open(t, 'open sheet');
      expect(calls, [true]);
      await t.binding.handlePopRoute(); // back
      await settle(t);
      expect(find.byKey(const ValueKey('keyQr')), findsNothing);
      expect(calls, [true, false]);
    });

    testWidgets('Plan › Show wallet key: on while the dialog is open, off after Done', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, _opener(wc, sheet: false));
      await open(t, 'open key');
      expect(find.text('Wallet key'), findsOneWidget);
      expect(calls, [true]);
      await t.tap(find.byKey(const ValueKey('walletKeyDone')));
      await settle(t);
      expect(calls, [true, false]);
    });

    testWidgets('the flag goes off when the screen is removed from the tree (dispose), not only on Done', (t) async {
      final wc = emptyWallet();
      await pumpApp(t, _opener(wc, sheet: false));
      await open(t, 'open key');
      expect(calls, [true]);
      await t.pumpWidget(const SizedBox()); // the whole app goes away with the dialog open
      await t.pump();
      expect(calls, [true, false]);
    });

    testWidgets('two key views at once: the flag stays on until the last one closes', (t) async {
      await t.pumpWidget(const Directionality(
          textDirection: TextDirection.ltr, child: Column(children: [SecureWindow(child: SizedBox()), SecureWindow(child: SizedBox())])));
      expect(calls, [true], reason: 'one switch-on for two views');
      await t
          .pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: Column(children: [SecureWindow(child: SizedBox())])));
      expect(calls, [true]);
      await t.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: SizedBox()));
      expect(calls, [true, false]);
    });

    testWidgets('a failing channel does not break the screen and is logged without values', (t) async {
      channelError = PlatformException(code: 'nope', message: 'secret /path/to/x');
      final wc = emptyWallet();
      await pumpApp(t, _opener(wc, sheet: true));
      await open(t, 'open sheet');
      expect(find.byKey(const ValueKey('keyQr')), findsOneWidget);
      expect(lines.join('\n'), contains('secure.failed'));
      expect(lines.join('\n'), isNot(contains('/path/to/x')));
      await t.ensureVisible(find.byKey(const ValueKey('keyLater')));
      await t.tap(find.byKey(const ValueKey('keyLater')));
      await settle(t);
      await t.pump(const Duration(seconds: 1));
    });
  });

  group('other platforms: the channel is not touched', () {
    for (final p in [TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.iOS]) {
      testWidgets('$p', (t) async {
        debugDefaultTargetPlatformOverride = p;
        try {
          final wc = emptyWallet();
          await pumpApp(t, _opener(wc, sheet: false));
          await open(t, 'open key');
          expect(find.byKey(const ValueKey('keyQr')), findsOneWidget);
          await t.tap(find.byKey(const ValueKey('walletKeyDone')));
          await settle(t);
          expect(calls, isEmpty);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  group('QR first, text on request', () {
    for (final sheet in [true, false]) {
      testWidgets(sheet ? 'save-key sheet' : 'wallet key dialog', (t) async {
        final wc = emptyWallet();
        final text = await wc.keyText();
        await pumpApp(t, _opener(wc, sheet: sheet));
        await open(t, sheet ? 'open sheet' : 'open key');
        expect(find.byKey(const ValueKey('keyQr')), findsOneWidget);
        expect(find.byKey(const ValueKey('keyText')), findsNothing);
        expect(find.text(text, findRichText: true), findsNothing);
        expect(find.text('Show as text'), findsOneWidget);
        await t.ensureVisible(find.byKey(const ValueKey('keyShowText')));
        await t.tap(find.byKey(const ValueKey('keyShowText')));
        await t.pump();
        expect(find.text('Hide text'), findsOneWidget);
        expect(find.text(text, findRichText: true), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('keyShowText')));
        await t.pump();
        expect(find.text(text, findRichText: true), findsNothing);
        expect(lines.join('\n'), isNot(contains(text)));
        expect(lines.join('\n'), contains('key.text'));
        await t.pump(const Duration(seconds: 1));
      });
    }

    for (final (name, size, scale) in [('320 dp at 2.0', const Size(320, 700), 2.0), ('wide', const Size(1280, 800), 1.0)]) {
      testWidgets('the dialog with its text shown fits $name', (t) async {
        final wc = emptyWallet();
        await pumpApp(t, _opener(wc, sheet: false), size: size, textScale: scale);
        await open(t, 'open key');
        await t.tap(find.byKey(const ValueKey('keyShowText')));
        await t.pump();
        expect(t.takeException(), isNull);
        expect(find.byKey(const ValueKey('walletKeyDone')), findsOneWidget);
      });
    }
  });
}
