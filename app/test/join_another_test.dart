// Plan › Join another wallet…: the warning, the join page over the open wallet, and what the controller does (set the old
// database aside before joining, never delete). All data is SYNTHETIC; the database, key store and set-aside are fakes.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/platform.dart' as plat;
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/wallet_db.dart';
import 'package:budget_wallet/src/widgets/common.dart' show StatusLabel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

/// A wallet whose database, key store and set-aside are fakes that write what they do into [events].
WalletController _wallet(List<String> events) {
  final wc = demoWallet();
  wc.dbSetAside = (stamp) async => events.add('aside');
  wc.keyWriter = (k, {passphrase}) async => events.add('key');
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
    expect(find.textContaining('only thing that opens the set-aside copy'), findsOneWidget);
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
    expect(events, ['aside', 'key', 'open']);
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

  group('controller', () {
    test('joinAnotherWallet: key and relay are checked before anything is touched', () async {
      final events = <String>[];
      final wc = _wallet(events);
      final repo = wc.repo;
      await expectLater(wc.joinAnotherWallet('not a key'), throwsA(anything));
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText(), relay: Uri.parse('ftp://nope')), throwsA(anything));
      expect(events, isEmpty);
      expect(wc.hasWallet, isTrue);
      expect(identical(wc.repo, repo), isTrue);
    });

    test('a failure after the set-aside leaves no wallet open (onboarding) and the old database aside', () async {
      final events = <String>[];
      final wc = _wallet(events);
      wc.keyWriter = (k, {passphrase}) async => throw StateError('disk full');
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(events, ['aside']);
      expect(wc.hasWallet, isFalse, reason: 'the app shows first-run onboarding, not an empty wallet');
    });

    test('a failing set-aside reopens the old wallet and rethrows', () async {
      final events = <String>[];
      final wc = _wallet(events);
      wc.dbSetAside = (s) async => throw StateError('rename failed');
      await expectLater(wc.joinAnotherWallet(await VaultKey.generate().toText()), throwsA(isA<StateError>()));
      expect(events, ['open'], reason: 'the old database is opened again; no key written');
      expect(wc.hasWallet, isTrue);
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
