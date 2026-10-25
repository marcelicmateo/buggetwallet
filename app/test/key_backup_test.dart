// "Save your wallet key" (S3): prompt after create, confirm with the last 4 characters, "Later" for 7 days, Today row,
// copy + 60 s clear, layout, and that the logs never hold the key. All data is synthetic.
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/platform.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

DateTime day = DateTime(2026, 10, 20, 12);

/// A wallet without a key yet (onboarding), a fake key store and a fake clipboard.
({WalletController wc, List<String?> clip}) fresh() {
  final wc = WalletController.forTest(WalletRepo.inMemory(), clock: () => day);
  wc.keyWriter = (k, {passphrase}) async {};
  final clip = <String?>[null];
  wc.clipboardWrite = (t) async => clip[0] = t;
  wc.clipboardRead = () async => clip[0];
  return (wc: wc, clip: clip);
}

WalletController keyed() {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => day);
  final clip = <String?>[null];
  wc.clipboardWrite = (t) async => clip[0] = t;
  wc.clipboardRead = () async => clip[0];
  return wc;
}

/// Like HomeShell: the page is built again when the data version moves.
Widget todayOf(WalletController wc) => ListenableBuilder(
    listenable: wc,
    builder: (_, __) => Scaffold(body: TodayScreen(key: ValueKey(wc.dataVersion), wc: wc, openPlan: () {}, clock: () => day)));

Widget opener(WalletController wc) =>
    Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openKeyBackup(c, wc), child: const Text('open'))));

void main() {
  late List<String> lines;
  setUp(() {
    day = DateTime(2026, 10, 20, 12);
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  group('controller', () {
    testWidgets('row is due until confirmed; Later hides it for exactly 7 days', (t) async {
      final wc = keyed();
      expect(wc.keyBackupRowVisible, isTrue);
      wc.snoozeKeyBackup();
      expect(wc.keyBackupRowVisible, isFalse);
      day = DateTime(2026, 10, 26, 23, 59);
      expect(wc.keyBackupRowVisible, isFalse, reason: 'day 6');
      day = DateTime(2026, 10, 27, 0, 1);
      expect(wc.keyBackupRowVisible, isTrue, reason: 'day 7');
    });

    testWidgets('last 4 characters: case, spaces and dashes are ignored; wrong, short and long are refused', (t) async {
      final wc = keyed();
      final text = await wc.keyText();
      final last4 = text.substring(text.length - 4);
      expect(await wc.confirmKeyBackup(''), isFalse);
      expect(await wc.confirmKeyBackup('ABC'), isFalse);
      expect(await wc.confirmKeyBackup(text), isFalse, reason: 'the whole key is not 4 characters');
      expect(await wc.confirmKeyBackup('${last4[0]}${last4[1]}${last4[2]}${last4[3] == 'A' ? 'B' : 'A'}'), isFalse);
      expect(wc.keyBackupConfirmed, isFalse);
      expect(await wc.confirmKeyBackup(' ${last4.toLowerCase().split('').join('-')} '), isTrue);
      expect(wc.keyBackupConfirmed, isTrue);
      expect(wc.keyBackupRowVisible, isFalse);
    });

    testWidgets('a joined device counts as confirmed', (t) async {
      final f = fresh();
      final text = await VaultKey.generate().toText();
      await f.wc.joinWallet(text);
      expect(f.wc.keyBackupConfirmed, isTrue);
      expect(f.wc.keyBackupRowVisible, isFalse);
      expect(f.wc.takeKeyBackupPrompt(), isFalse);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('createWallet asks for the prompt once', (t) async {
      final f = fresh();
      await f.wc.createWallet();
      expect(f.wc.takeKeyBackupPrompt(), isTrue);
      expect(f.wc.takeKeyBackupPrompt(), isFalse);
      expect(f.wc.keyBackupRowVisible, isTrue);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('copy clears the clipboard after 60 s, but only while it still holds the key', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => clip[0];
      final text = await wc.keyText();
      await wc.copyKeyBackup();
      expect(clip[0], text);
      await t.pump(const Duration(seconds: 59));
      expect(clip[0], text);
      await t.pump(const Duration(seconds: 2));
      expect(clip[0], '');

      await wc.copyKeyBackup();
      clip[0] = 'something else the owner copied';
      await t.pump(const Duration(seconds: 61));
      expect(clip[0], 'something else the owner copied');
    });

    testWidgets('background app reads null from the clipboard: still cleared', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => null;
      await wc.copyKeyBackup();
      expect(clip[0], isNotEmpty);
      await t.pump(const Duration(seconds: 61));
      expect(clip[0], '');
    });

    testWidgets('a failing clipboard read still clears', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => throw StateError('no access');
      await wc.copyKeyBackup();
      await t.pump(const Duration(seconds: 61));
      expect(clip[0], '');
    });

    testWidgets('in the background at 60 s: cleared on the next resume', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => null;
      final text = await wc.keyText();
      await wc.copyKeyBackup();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump(const Duration(seconds: 61));
      expect(clip[0], text, reason: 'not cleared while in the background');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(clip[0], '');
    });

    testWidgets('dispose with a pending clear empties the clipboard at once', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => clip[0];
      await wc.copyKeyBackup();
      expect(clip[0], isNotEmpty);
      wc.dispose();
      await t.pump();
      expect(clip[0], '');
    });

    testWidgets('a second copy restarts the 60 s', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => clip[0];
      final text = await wc.keyText();
      await wc.copyKeyBackup();
      await t.pump(const Duration(seconds: 40));
      await wc.copyKeyBackup();
      await t.pump(const Duration(seconds: 40));
      expect(clip[0], text);
      await t.pump(const Duration(seconds: 21));
      expect(clip[0], '');
    });
  });

  group('screens', () {
    testWidgets('create wallet → the prompt opens before the first Today; wrong then right last 4', (t) async {
      final f = fresh();
      t.view.physicalSize = const Size(400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(BudgetWalletApp(wc: f.wc));
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Save your wallet key'), findsWidgets);
      expect(find.text('Without this key, this wallet cannot be opened again on any device.'), findsOneWidget);
      expect(find.byKey(const ValueKey('keyQr')), findsOneWidget);
      expect(find.byKey(const ValueKey('keyText')), findsNothing, reason: 'QR first; the text is behind "Show as text"');
      await t.tap(find.byKey(const ValueKey('keyShowText')));
      await t.pump();
      expect(find.byType(SelectableText), findsNothing, reason: 'Copy key is the only copy path (it clears the clipboard)');
      final shown = (t.widget(find.byKey(const ValueKey('keyText'))) as Text).data!;
      expect(shown, await f.wc.keyText());
      expect(find.text('The passphrase only unlocks this browser.'), findsNothing);

      await t.tap(find.byKey(const ValueKey('keySaved')));
      await t.pump();
      expect(find.text('Type the last 4 characters of the key to confirm.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('keyLast4')), 'ZZZZ');
      await t.tap(find.byKey(const ValueKey('keyConfirm')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.textContaining("That doesn't match the end of your key.", findRichText: true), findsOneWidget);
      expect(f.wc.keyBackupConfirmed, isFalse);

      final tail = shown.replaceAll('-', '');
      await t.enterText(find.byKey(const ValueKey('keyLast4')), tail.substring(tail.length - 4).toLowerCase());
      await t.tap(find.byKey(const ValueKey('keyConfirm')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(f.wc.keyBackupConfirmed, isTrue);
      expect(find.byKey(const ValueKey('keyText')), findsNothing);
      expect(find.byKey(const ValueKey('keyBackupRow')), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Later in the prompt snoozes; Today shows no row for 7 days', (t) async {
      final f = fresh();
      await f.wc.createWallet();
      await pumpApp(t, todayOf(f.wc));
      expect(find.byKey(const ValueKey('keyBackupRow')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('keySaveNow')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.byKey(const ValueKey('keyLater')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('keyBackupRow')), findsNothing);
      day = DateTime(2026, 10, 27, 8);
      f.wc.reload();
      await pumpApp(t, todayOf(f.wc));
      expect(find.byKey(const ValueKey('keyBackupRow')), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Today row: shown for an existing wallet, its own Later, gone once confirmed or on a joined device', (t) async {
      final wc = keyed();
      await pumpApp(t, todayOf(wc));
      expect(find.text('Save your wallet key'), findsOneWidget);
      expect(find.byKey(const ValueKey('keySaveNow')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('keyRowLater')));
      await t.pump();
      expect(find.byKey(const ValueKey('keyBackupRow')), findsNothing);

      final done = keyed();
      await done.confirmKeyBackup((await done.keyText()).substring((await done.keyText()).length - 4));
      await pumpApp(t, todayOf(done));
      expect(find.byKey(const ValueKey('keyBackupRow')), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Copy key button copies and the sheet says it is cleared in 60 seconds', (t) async {
      final wc = keyed();
      final clip = <String?>[null];
      wc.clipboardWrite = (x) async => clip[0] = x;
      wc.clipboardRead = () async => clip[0];
      await pumpApp(t, opener(wc));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.byKey(const ValueKey('keyCopy')));
      await t.pump();
      expect(clip[0], await wc.keyText());
      expect(find.text('Copy key clears the clipboard after 60 seconds. Clipboard history on some phones may keep it.'), findsOneWidget);
      await t.pump(const Duration(seconds: 61));
      expect(clip[0], '');
    });

    testWidgets('web: says the passphrase only unlocks this browser', (t) async {
      debugIsWebOverride = true;
      addTearDown(() => debugIsWebOverride = null);
      await pumpApp(t, opener(keyed()));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('The passphrase only unlocks this browser.'), findsOneWidget);
    });

    for (final (name, size, scale) in [
      ('320 dp @ 2.0', const Size(320, 700), 2.0),
      ('360 dp', const Size(360, 800), 1.0),
      ('wide window', const Size(1280, 800), 1.0),
    ]) {
      testWidgets('layout: sheet and Today row fit at $name, also while asking for the last 4', (t) async {
        final wc = keyed();
        await pumpApp(t, opener(wc), size: size, textScale: scale);
        await t.tap(find.text('open'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        await t.ensureVisible(find.byKey(const ValueKey('keyShowText')));
        await t.tap(find.byKey(const ValueKey('keyShowText')));
        await t.pump();
        expect(find.byKey(const ValueKey('keyText')), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.ensureVisible(find.byKey(const ValueKey('keySaved')));
        await t.tap(find.byKey(const ValueKey('keySaved')));
        await t.pump();
        await t.ensureVisible(find.byKey(const ValueKey('keyConfirm')));
        expect(t.takeException(), isNull);
        await t.tap(find.byKey(const ValueKey('keyLater')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));

        final w2 = keyed();
        await pumpApp(t, todayOf(w2), size: size, textScale: scale);
        expect(find.byKey(const ValueKey('keyBackupRow')), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pump(const Duration(seconds: 4));
      });
    }
  });

  group('logs', () {
    testWidgets('only key.backup action words; no key, no fragment, no typed characters', (t) async {
      final wc = keyed();
      final text = await wc.keyText();
      final plain = text.replaceAll('-', '');
      final last4 = plain.substring(plain.length - 4);
      await pumpApp(t, opener(wc));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.byKey(const ValueKey('keyCopy')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('keySaved')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('keyLast4')), 'QQQQ');
      await t.tap(find.byKey(const ValueKey('keyConfirm')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('keyLast4')), last4);
      await t.tap(find.byKey(const ValueKey('keyConfirm')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      wc.snoozeKeyBackup();
      await t.pump(const Duration(seconds: 61));

      final log = lines.join('\n');
      for (final a in ['shown', 'copied', 'confirmed', 'snoozed']) {
        expect(log, contains('key.backup'));
        expect(log, contains(a));
      }
      expect(log, isNot(contains(text)));
      expect(log, isNot(contains('BW1')));
      expect(log, isNot(contains(last4)));
      expect(log, isNot(contains('QQQQ')));
      for (var i = 0; i + 6 <= plain.length; i += 3) {
        expect(log, isNot(contains(plain.substring(i, i + 6))));
      }
    });
  });

  group('key text (owner note: 0 and O look alike)', () {
    const sample = 'OOILO2345JKLMNOPQRSTUVWXYZ'; // synthetic; the real alphabet is A-Z and 2-7
    for (final selectable in [false, true]) {
      testWidgets('shows a mono key and says there is no zero or one (selectable: $selectable)', (t) async {
        t.view.physicalSize = const Size(320, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
          home: Scaffold(body: SingleChildScrollView(child: KeyDisplay(text: sample, selectable: selectable))),
        ));
        expect(find.byKey(const ValueKey('keyHint')), findsNothing, reason: 'nothing while the text is hidden');
        await t.tap(find.byKey(const ValueKey('keyShowText')));
        await t.pump();
        final style = selectable
            ? (t.widget(find.byKey(const ValueKey('keyText'))) as SelectableText).style!
            : (t.widget(find.byKey(const ValueKey('keyText'))) as Text).style!;
        expect(style.fontFamily, monoFamily);
        expect(style.letterSpacing, greaterThan(0));
        final hint = (t.widget(find.byKey(const ValueKey('keyHint'))) as Muted).text;
        expect(hint, keyAlphabetHint);
        expect(hint, contains('no zero or one'));
        expect(hint, contains('letter O'));
        expect(t.takeException(), isNull);
      });
    }
  });
}
