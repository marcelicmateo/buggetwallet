// Plan › Join another wallet…: the warning, the join page over the open wallet, and what the controller does (set the old
// database aside before joining, never delete). All data is SYNTHETIC; the database, key store and set-aside are fakes.
import 'dart:async';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/platform.dart' as plat;
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/wallet_db.dart';
import 'package:budget_wallet/src/widgets/common.dart' show StatusLabel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'db_open_test.dart' show World, loadWith;
import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

/// A wallet whose database, key store and set-aside are fakes that write what they do into [events].
WalletController _wallet(List<String> events, {bool keySaved = true, Map<String, String>? asideKeys, List<String>? written}) {
  final wc = demoWallet();
  if (keySaved) wc.repo.setLocalValue('keyBackupConfirmed', '2026-10-20');
  wc.dbSetAside = (stamp) async => events.add('aside');
  wc.keyWriter = (k, {passphrase}) async {
    events.add('key');
    written?.add(await k.toText());
  };
  wc.keyAsideWriter = (stamp, k) async {
    events.add('keyAside');
    final slot = 'aside.$stamp';
    asideKeys?[slot] = await k.toText();
    return slot;
  };
  wc.keyAsideRemover = (slot) async {
    events.add('asideRemoved');
    asideKeys?.remove(slot);
  };
  wc.keyForgetter = () async => events.add('FORGET-KEY');
  wc.deviceIdWriter = (id) async {};
  wc.deviceIdReader = () async => null;
  wc.dbOpener = (dbKey, {deviceId}) async {
    events.add('open');
    return WalletDb(WalletRepo.inMemory(deviceId: deviceId), forget: () async => events.add('FORGET-DB'));
  };
  return wc;
}

Future<void> _pumpPlan(WidgetTester tester, WalletController wc) async {
  await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 12000));
  await tester.pump();
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.ensureVisible(_key('joinAnother'));
  await tester.pump();
  await tester.tap(_key('joinAnother'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Plan has "Join another wallet…" and the warning says what happens', (tester) async {
    final events = <String>[];
    final wc = _wallet(events);
    await _pumpPlan(tester, wc);
    expect(find.text('Join another wallet…'), findsOneWidget);
    await _openDialog(tester);
    final warning = tester.widget<Text>(_key('joinAnotherWarning')).data!;
    expect(warning, contains('sets this wallet aside on this device'));
    expect(warning, contains('not deleted'));
    expect(warning, contains('stays only here'));
    expect(warning, contains('synced'));
    expect(warning, contains('backed up'));
    expect(find.textContaining('kept on this device with its key; reopening it is not in the app yet'), findsOneWidget);
    expect(find.textContaining('only thing that opens'), findsNothing, reason: 'no promise of a reopen path the app does not have');
    expect(events, isEmpty, reason: 'the warning changes nothing');
  });

  testWidgets('Cancel in the warning keeps the wallet open and unchanged', (tester) async {
    final events = <String>[];
    final wc = _wallet(events);
    final repo = wc.repo;
    final goals = wc.goals.length;
    await _pumpPlan(tester, wc);
    await _openDialog(tester);
    await tester.tap(_key('joinAnotherCancel'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(PlanScreen), findsOneWidget);
    expect(events, isEmpty);
    expect(wc.hasWallet, isTrue);
    expect(identical(wc.repo, repo), isTrue);
    expect(wc.goals.length, goals);
  });

  testWidgets('Continue shows the join page; Cancel there still leaves the wallet open and unchanged', (tester) async {
    final events = <String>[];
    final wc = _wallet(events);
    final repo = wc.repo;
    await _pumpPlan(tester, wc);
    await _openDialog(tester);
    await tester.tap(_key('joinAnotherConfirm'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(_key('startWallet'), findsNothing, reason: 'only the join step');
    expect(_key('joinStart'), findsNothing);
    expect(find.widgetWithText(TextField, 'Wallet key'), findsOneWidget);
    expect(_key('relayAddress'), findsOneWidget);
    expect(_key('joinWallet'), findsOneWidget);
    expect(_key('replaceNote'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(events, isEmpty, reason: 'nothing is set aside before the join itself');
    await tester.tap(_key('joinBack'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(PlanScreen), findsOneWidget);
    expect(events, isEmpty);
    expect(wc.hasWallet, isTrue);
    expect(identical(wc.repo, repo), isTrue);
  });

  testWidgets('a wrong key shows its error and nothing is set aside', (tester) async {
    final events = <String>[];
    final wc = _wallet(events);
    final repo = wc.repo;
    await _pumpPlan(tester, wc);
    await _openDialog(tester);
    await tester.tap(_key('joinAnotherConfirm'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Wallet key'), 'not a key');
    await tester.tap(_key('joinWallet'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.byType(StatusLabel), findsOneWidget);
    expect(events, isEmpty);
    expect(wc.hasWallet, isTrue);
    expect(identical(wc.repo, repo), isTrue);
  });

  testWidgets('joining sets the old database aside before the key is written, never deletes, and closes the page', (tester) async {
    final events = <String>[];
    final wc = _wallet(events);
    final old = wc.repo;
    final text = await tester.runAsync(() => VaultKey.generate().toText()) ?? '';
    await _pumpPlan(tester, wc);
    await _openDialog(tester);
    await tester.tap(_key('joinAnotherConfirm'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Wallet key'), text);
    await tester.tap(_key('joinWallet'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(events, ['keyAside', 'key', 'aside', 'open']);
    expect(events.where((e) => e.startsWith('FORGET')), isEmpty, reason: 'nothing is deleted');
    expect(wc.hasWallet, isTrue);
    expect(identical(wc.repo, old), isFalse, reason: 'the joined wallet has its own database');
    expect(wc.goals, isEmpty);
    expect(find.byType(OnboardingScreen), findsNothing, reason: 'the join page closed');
    expect(find.byType(PlanScreen), findsOneWidget);
    expect(find.text('Joined. Your old wallet is set aside on this device.'), findsOneWidget);
    wc.dispose(); // the join restarted the sync timers
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the sheet offers Continue only after this wallet\'s key was saved (last-four check)', (tester) async {
    final events = <String>[];
    final wc = _wallet(events, keySaved: false);
    final keyText = await tester.runAsync(wc.keyText) ?? '';
    await _pumpPlan(tester, wc);
    await _openDialog(tester);
    expect(_key('joinAnotherConfirm'), findsNothing);
    expect(_key('joinAnotherSaveKey'), findsOneWidget);
    expect(_key('joinAnotherSaveNote'), findsOneWidget);
    await tester.runAsync(() => wc.confirmKeyBackup(keyText.substring(keyText.length - 4)));
    await tester.pump();
    expect(_key('joinAnotherConfirm'), findsOneWidget, reason: 'confirmed: Continue appears');
    expect(_key('joinAnotherSaveKey'), findsNothing);
    expect(events, isEmpty);
  });

  group('controller', () {
    WalletController wallet(List<String> events, {Map<String, String>? aside, List<String>? written}) {
      final wc = _wallet(events, asideKeys: aside, written: written);
      addTearDown(wc.dispose);
      return wc;
    }

    test('joinAnotherWallet: key, relay, own key saved and "not the open wallet" are checked before anything is touched', () async {
      final events = <String>[];
      final wc = wallet(events);
      final repo = wc.repo;
      await expectLater(wc.joinAnotherWallet('not a key'), throwsA(anything));
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText(), relay: Uri.parse('ftp://nope')), throwsA(anything));
      expect(events, isEmpty);
      expect(wc.hasWallet, isTrue);
      expect(identical(wc.repo, repo), isTrue);
    });

    test('the open wallet\'s own key is refused: "This wallet is already open.", nothing touched', () async {
      final events = <String>[];
      final wc = wallet(events);
      final repo = wc.repo;
      await expectLater(wc.joinAnotherWallet(await wc.keyText()), throwsA(isA<WalletAlreadyOpen>()));
      expect(const WalletAlreadyOpen().toString(), 'This wallet is already open.');
      expect(events, isEmpty);
      expect(identical(wc.repo, repo), isTrue);
      expect(wc.hasWallet, isTrue);
    });

    test('a wallet whose key was not saved cannot be set aside', () async {
      final events = <String>[];
      final wc = _wallet(events, keySaved: false);
      addTearDown(wc.dispose);
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<KeyNotSaved>()));
      expect(events, isEmpty);
      expect(wc.hasWallet, isTrue);
    });

    test('the old key ends up under the aside slot, before the new key is written', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final written = <String>[];
      final wc = wallet(events, aside: aside, written: written);
      final oldText = await wc.keyText();
      final newText = await VaultKey.generate().toText();
      await wc.joinAnotherWallet(newText);
      expect(aside.values.single, oldText, reason: 'the old key is kept, the slot is named after the set-aside stamp');
      expect(aside.keys.single, startsWith('aside.2'));
      expect(written, [newText]);
      expect(events, ['keyAside', 'key', 'aside', 'open']);
    });

    test('the new key is written before the file is set aside; a failed key write touches nothing and drops the slot', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final wc = wallet(events, aside: aside);
      final repo = wc.repo;
      wc.keyWriter = (k, {passphrase}) async => throw StateError('disk full');
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(events, ['keyAside', 'asideRemoved']);
      expect(aside, isEmpty);
      expect(identical(wc.repo, repo), isTrue, reason: 'the old wallet is still open');
      expect(wc.hasWallet, isTrue);
    });

    test('a failing set-aside puts the old key back, drops the slot and opens the old wallet again', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final written = <String>[];
      final wc = wallet(events, aside: aside, written: written);
      final oldText = await wc.keyText();
      final newText = await VaultKey.generate().toText();
      wc.dbSetAside = (s) async => throw StateError('rename failed');
      await expectLater(wc.joinAnotherWallet(newText), throwsA(isA<StateError>()));
      expect(written, [newText, oldText], reason: 'the old key is written back');
      expect(events, ['keyAside', 'key', 'key', 'asideRemoved', 'open']);
      expect(aside, isEmpty);
      expect(wc.hasWallet, isTrue);
    });

    test('a failing set-aside whose reopen also fails leaves no wallet open (onboarding)', () async {
      final events = <String>[];
      final wc = wallet(events);
      var notified = 0;
      wc.addListener(() => notified++);
      wc.dbSetAside = (s) async => throw StateError('rename failed');
      var opens = 0;
      wc.dbOpener = (k, {deviceId}) async {
        opens++;
        throw StateError('cannot open');
      };
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(opens, 1);
      expect(wc.hasWallet, isFalse, reason: 'nothing is open: the app shows onboarding, not an empty wallet');
      expect(notified, greaterThan(0), reason: 'listeners hear it');
    });

    test('a crash after the key write (set-aside and key restore both fail): the next start takes the key-mismatch path', () async {
      final oldKey = VaultKey.generate();
      final w = World(hasFile: true, fileKey: await localDbKey(oldKey));
      final wc = await loadWith(w, key: oldKey);
      wc.repo.setLocalValue('keyBackupConfirmed', '2026-10-20');
      var stored = await oldKey.toText(); // what the key store holds
      var writes = 0;
      wc.keyWriter = (k, {passphrase}) async {
        if (++writes > 1) throw StateError('crashed');
        stored = await k.toText();
      };
      wc.keyAsideWriter = (stamp, k) async => 'aside.$stamp';
      wc.keyAsideRemover = (slot) async {};
      wc.dbSetAside = (s) async => throw StateError('crashed');
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(stored, isNot(await oldKey.toText()), reason: 'the new key was written first');
      expect(w.aside, isEmpty, reason: 'the old file was never moved');
      expect(w.hasFile, isTrue);
      // Restart: the stored (new) key does not open the old file.
      final again = await loadWith(w, key: await VaultKey.parse(stored));
      expect(again.hasUnopenedDb, isTrue);
      expect(w.aside, isEmpty, reason: 'start-up leaves the file untouched');
      expect(w.hasFile, isTrue, reason: 'nothing deleted');
    });

    group('sync around the set-aside', () {
      test('a pending change is pushed before the old wallet is set aside', () async {
        final events = <String>[];
        final wc = wallet(events);
        wc.relayUrl = Uri.parse('http://homeserver:8787');
        expect(wc.repo.pendingOps(), isNotEmpty, reason: 'precondition: unsent changes');
        wc.syncRunner = (relay, k, r) async {
          events.add('sync');
          return const SyncReport(0, 0, 0, caughtUp: true);
        };
        await wc.joinAnotherWallet(await VaultKey.generate().toText());
        expect(events.indexOf('sync'), lessThan(events.indexOf('keyAside')), reason: 'pushed first');
        expect(events.indexOf('sync'), lessThan(events.indexOf('aside')));
      });

      test('a sync that is running is awaited before anything is closed', () async {
        final events = <String>[];
        final wc = wallet(events);
        wc.relayUrl = Uri.parse('http://homeserver:8787');
        final gate = Completer<void>();
        wc.syncRunner = (relay, k, r) async {
          events.add('sync start');
          await gate.future;
          events.add('sync end');
          return const SyncReport(0, 0, 0, caughtUp: true);
        };
        final running = wc.syncNow();
        await Future<void>.delayed(Duration.zero);
        expect(events, ['sync start']);
        final join = wc.joinAnotherWallet(await VaultKey.generate().toText());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events, ['sync start'], reason: 'the old key and database are untouched while the sync runs');
        gate.complete();
        await running;
        await join;
        expect(events.indexOf('sync end'), lessThan(events.indexOf('keyAside')));
        expect(events.indexOf('sync end'), lessThan(events.indexOf('aside')));
      });

      test('the old wallet\'s sync status does not carry over, also with the same relay address', () async {
        final events = <String>[];
        final wc = wallet(events);
        final relay = Uri.parse('http://homeserver:8787');
        wc.relayUrl = relay;
        wc.syncError = 'old problem';
        wc.syncCaughtUp = true;
        wc.syncBadFiles = 3;
        wc.syncRelayInstance = 'abcd1234abcd1234';
        wc.syncRelayBytes = 10;
        wc.lastSync = DateTime(2026, 10, 1);
        wc.syncRunner = (r, k, repo) async => const SyncReport(0, 0, 0);
        await wc.joinAnotherWallet(await VaultKey.generate().toText(), relay: relay);
        expect(wc.syncError, isNull);
        expect(wc.syncBadFiles, 0);
        expect(wc.syncRelayInstance, isNull);
        expect(wc.syncRelayBytes, isNull);
        expect(wc.syncCaughtUp, isFalse, reason: 'the new wallet has not caught up yet');
        expect(wc.lastSync, isNot(DateTime(2026, 10, 1)));
        expect(wc.relayUrl, relay, reason: 'the join sets the typed address for the new wallet');
      });
    });
  });

  testWidgets('not offered on the web (no set-aside path there)', (tester) async {
    plat.debugIsWebOverride = true;
    addTearDown(() => plat.debugIsWebOverride = null);
    final wc = _wallet([]);
    await _pumpPlan(tester, wc);
    expect(_key('joinAnother'), findsNothing);
    expect(find.text('Join another wallet…'), findsNothing);
  });
}
