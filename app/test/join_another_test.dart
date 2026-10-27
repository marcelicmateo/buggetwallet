// Plan › Join another wallet…: the warning, the join page over the open wallet, and what the controller does (set the old
// database aside before joining, never delete). All data is SYNTHETIC; the database, key store and set-aside are fakes.
import 'dart:async';
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/platform.dart' as plat;
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/wallet_db.dart';
import 'package:budget_wallet/src/widgets/common.dart' show StatusLabel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'db_open_test.dart' show World, loadWith;
import 'support/plan_page.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

/// What the fake key store holds for the join-pending marker.
class _Markers {
  String? text, last;
  int cleared = 0;
}

Finder _key(String k) => find.byKey(ValueKey(k));

/// A wallet whose database, key store and set-aside are fakes that write what they do into [events].
WalletController _wallet(List<String> events, {bool keySaved = true, Map<String, String>? asideKeys, List<String>? written}) {
  final wc = demoWallet();
  if (keySaved) wc.repo.setLocalValue('keyBackupConfirmed', '2026-10-20');
  wc.seams.dbSetAside = (stamp) async => events.add('aside');
  wc.seams.dbExists = () async => true;
  wc.seams.joinMarkerWriter = (t) async {};
  wc.seams.joinMarkerClearer = () async {};
  wc.seams.keyWriter = (k, {passphrase}) async {
    events.add('key');
    written?.add(await k.toText());
  };
  wc.seams.keyAsideWriter = (stamp, k) async {
    events.add('keyAside');
    final slot = 'aside.$stamp';
    asideKeys?[slot] = await k.toText();
    return slot;
  };
  wc.seams.keyAsideRemover = (slot) async {
    events.add('asideRemoved');
    asideKeys?.remove(slot);
  };
  wc.seams.keyForgetter = () async => events.add('FORGET-KEY');
  wc.seams.deviceIdWriter = (id) async {};
  wc.seams.deviceIdReader = () async => null;
  wc.seams.dbOpener = (dbKey, {deviceId}) async {
    events.add('open');
    return WalletDb(WalletRepo.inMemory(deviceId: deviceId), forget: () async => events.add('FORGET-DB'));
  };
  return wc;
}

Future<void> _pumpPlan(WidgetTester tester, WalletController wc) async {
  await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 12000));
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
    expect(find.byType(PlanPage), findsOneWidget);
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
    expect(find.byType(PlanPage), findsOneWidget);
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
    expect(find.byType(PlanPage), findsOneWidget);
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
    late _Markers markers;
    setUp(() => markers = _Markers());

    WalletController wallet(List<String> events, {Map<String, String>? aside, List<String>? written}) {
      final wc = _wallet(events, asideKeys: aside, written: written);
      wc.seams.joinMarkerWriter = (t) async => markers.text = markers.last = t;
      wc.seams.joinMarkerClearer = () async {
        markers.cleared++;
        markers.text = null;
      };
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

    test('a failed key write puts the old key back first, then drops the slot and the marker; nothing else is touched', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final written = <String>[];
      final wc = wallet(events, aside: aside, written: written);
      final repo = wc.repo;
      final oldText = await wc.keyText();
      var calls = 0;
      wc.seams.keyWriter = (k, {passphrase}) async {
        events.add('key');
        if (++calls == 1) throw StateError('disk full');
        written.add(await k.toText());
      };
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(written, [oldText], reason: 'the old key is written back before the slot is given up');
      expect(events, ['keyAside', 'key', 'key', 'asideRemoved']);
      expect(aside, isEmpty);
      expect(markers.cleared, 1);
      expect(identical(wc.repo, repo), isTrue, reason: 'the old wallet is still open');
      expect(wc.hasWallet, isTrue);
    });

    test('a failed key write whose restore also fails keeps the slot and the marker', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final wc = wallet(events, aside: aside);
      wc.seams.keyWriter = (k, {passphrase}) async => throw StateError('disk full');
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(events, ['keyAside']);
      expect(aside, hasLength(1), reason: 'the old key stays in its slot: the key store may hold either key');
      expect(markers.cleared, 0);
      expect(markers.text, isNotNull);
    });

    test('a failing set-aside puts the old key back, reopens the old wallet, and only then drops the slot', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final written = <String>[];
      final wc = wallet(events, aside: aside, written: written);
      final oldText = await wc.keyText();
      final newText = await VaultKey.generate().toText();
      wc.seams.dbSetAside = (s) async => throw StateError('rename failed');
      await expectLater(wc.joinAnotherWallet(newText), throwsA(isA<StateError>()));
      expect(written, [newText, oldText], reason: 'the old key is written back');
      expect(events, ['keyAside', 'key', 'key', 'open', 'asideRemoved'], reason: 'the slot goes after the reopen worked');
      expect(aside, isEmpty);
      expect(markers.cleared, 1);
      expect(wc.hasWallet, isTrue);
    });

    test('a failing set-aside whose reopen also fails: onboarding with the notice, the slot stays, a later create still finds it',
        () async {
      final events = <String>[];
      final aside = <String, String>{};
      final wc = wallet(events, aside: aside);
      final oldText = await wc.keyText();
      var notified = 0;
      wc.addListener(() => notified++);
      wc.seams.dbSetAside = (s) async => throw StateError('rename failed');
      var opens = 0;
      wc.seams.dbOpener = (k, {deviceId}) async {
        opens++;
        throw StateError('cannot open');
      };
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(opens, 1);
      expect(wc.hasWallet, isFalse, reason: 'nothing is open: the app shows onboarding, not an empty wallet');
      expect(wc.hasUnopenedDb, isTrue, reason: 'onboarding says an older wallet is on this device');
      expect(notified, greaterThan(0), reason: 'listeners hear it');
      expect(aside.values.single, oldText, reason: 'the old key is still in its slot');
      expect(events, isNot(contains('asideRemoved')));
      // The owner then starts a new wallet: the older file is set aside, and the old key is still in the slot.
      wc.seams.dbSetAside = (s) async => events.add('aside');
      wc.seams.dbOpener = (k, {deviceId}) async => WalletDb(WalletRepo.inMemory(deviceId: deviceId));
      await wc.createWallet();
      expect(events, contains('aside'));
      expect(aside.values.single, oldText, reason: 'create did not touch the slot');
    });

    test('a partial set-aside (wallet.db gone) is not reopened as a new empty wallet: onboarding, slot kept', () async {
      final events = <String>[];
      final aside = <String, String>{};
      final wc = wallet(events, aside: aside);
      final oldText = await wc.keyText();
      wc.seams.dbSetAside = (s) async => throw StateError('side file rename failed');
      wc.seams.dbExists = () async => false; // the main file was moved, a side file was not and could not be moved back
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(events, isNot(contains('open')), reason: 'no new wallet.db next to the remains');
      expect(wc.hasWallet, isFalse);
      expect(wc.hasUnopenedDb, isTrue);
      expect(aside.values.single, oldText);
      expect(markers.cleared, 1, reason: 'the next start does not build a new wallet on the remains');
    });

    test('while the old wallet is being set aside no sync starts (a resume or a follow-up skips)', () async {
      final events = <String>[];
      final wc = wallet(events);
      wc.relayUrl = Uri.parse('http://homeserver:8787');
      var runs = 0;
      wc.seams.syncRunner = (relay, k, r) async {
        runs++;
        return const SyncReport(0, 0, 0, caughtUp: true);
      };
      final gate = Completer<void>();
      wc.seams.keyAsideWriter = (stamp, k) async {
        events.add('keyAside');
        await gate.future;
        return 'aside.$stamp';
      };
      final join = wc.joinAnotherWallet(await VaultKey.generate().toText());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, ['keyAside'], reason: 'the set-aside is under way');
      final before = runs;
      await wc.syncNow(trigger: 'resume');
      await wc.syncNow(quiet: true, trigger: 'relay');
      expect(runs, before, reason: 'skipped while joining');
      gate.complete();
      await join;
      expect(wc.hasWallet, isTrue);
    });

    test('the join marker is written before the new key and cleared when the join is done', () async {
      final events = <String>[];
      final wc = wallet(events);
      final relay = Uri.parse('http://homeserver:8787');
      wc.seams.syncRunner = (r, k, repo) async => const SyncReport(0, 0, 0);
      final order = <String>[];
      wc.seams.joinMarkerWriter = (t) async {
        order.add('marker');
        markers.text = markers.last = t;
      };
      wc.seams.keyWriter = (k, {passphrase}) async => order.add('key');
      await wc.joinAnotherWallet(await VaultKey.generate().toText(), relay: relay);
      expect(order, ['marker', 'key']);
      final m = jsonDecode(markers.last!) as Map<String, Object?>;
      expect(m['relay'], relay.toString());
      expect(m['id'], isA<String>());
      expect(m.containsKey('key'), isFalse, reason: 'no key in the marker');
      expect(markers.cleared, 1, reason: 'the join completed');
    });

    group('a start after a crash finishes the join from the marker', () {
      final marker = jsonEncode({'v': 1, 'relay': 'http://homeserver:8787', 'id': 'abc123marker'});

      test(
          'the new key was written but the old file never moved: it is set aside now and the new wallet opens with the fresh id and the relay',
          () async {
        final oldKey = VaultKey.generate();
        final w = World(hasFile: true, fileKey: await localDbKey(oldKey));
        final newKey = VaultKey.generate();
        var cleared = 0;
        final wc = await loadWith(w, key: newKey, joinMarker: marker, markerCleared: () => cleared++);
        expect(wc.hasWallet, isTrue);
        expect(wc.hasUnopenedDb, isFalse);
        expect(w.aside.values.single!.goals().single.name, 'Old goal', reason: 'the old wallet is set aside, whole');
        expect(w.ids.last, 'abc123marker', reason: 'the fresh device id from the marker');
        expect(wc.relayUrl.toString(), 'http://homeserver:8787');
        expect(cleared, 1);
        expect(wc.goals, isEmpty, reason: 'a new empty wallet, ready to sync');
      });

      test('the old file was moved but the join never opened: the new wallet opens with the fresh id and the relay', () async {
        final oldKey = VaultKey.generate();
        final w = World(hasFile: true, fileKey: await localDbKey(oldKey));
        await w.setAside('2026-10-25');
        var cleared = 0;
        final wc = await loadWith(w, key: VaultKey.generate(), joinMarker: marker, markerCleared: () => cleared++);
        expect(wc.hasWallet, isTrue);
        expect(w.ids.single, 'abc123marker', reason: 'not the old install id');
        expect(wc.relayUrl.toString(), 'http://homeserver:8787');
        expect(w.aside, hasLength(1), reason: 'nothing more was moved');
        expect(cleared, 1);
      });

      test('a start without the marker is unchanged: a key that opens nothing leaves the file alone (onboarding notice)', () async {
        final w = World(hasFile: true, fileKey: await localDbKey(VaultKey.generate()));
        final wc = await loadWith(w, key: VaultKey.generate());
        expect(wc.hasWallet, isFalse);
        expect(wc.hasUnopenedDb, isTrue);
        expect(w.aside, isEmpty);
      });

      test('the join had finished but the marker was not cleared: the marker is cleared, the relay filled in if missing, nothing moved',
          () async {
        final key = VaultKey.generate();
        final w = World(hasFile: true, fileKey: await localDbKey(key));
        var cleared = 0;
        final wc = await loadWith(w, key: key, joinMarker: marker, markerCleared: () => cleared++);
        expect(wc.hasWallet, isTrue);
        expect(w.aside, isEmpty);
        expect(cleared, 1);
        expect(wc.relayUrl.toString(), 'http://homeserver:8787');
      });
    });

    group('sync around the set-aside', () {
      test('a pending change is pushed before the old wallet is set aside', () async {
        final events = <String>[];
        final wc = wallet(events);
        wc.relayUrl = Uri.parse('http://homeserver:8787');
        expect(wc.repo.pendingOps(), isNotEmpty, reason: 'precondition: unsent changes');
        wc.seams.syncRunner = (relay, k, r) async {
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
        wc.seams.syncRunner = (relay, k, r) async {
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
        wc.seams.syncRunner = (r, k, repo) async => const SyncReport(0, 0, 0);
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
