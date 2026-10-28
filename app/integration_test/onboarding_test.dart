// First run through the UI: start a new wallet, the salary banner, joining with a wrong and a right key.
// Run: tools/emulator.sh test onboarding
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/key_store.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/setup_wizard.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/harness.dart';

void main() {
  Harness.init();

  itest('Start a new wallet: key stored, default goals, salary banner', (t) async {
    final wc = await Harness.start(t, wallet: false);
    expect(wc.hasWallet, isFalse);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Join my wallet from another device'), findsOneWidget);
    await Harness.shot(t, 'onboarding');

    await t.tap(find.text('Start a new wallet'));
    // Creating writes the key and opens the database (real I/O), which pumpAndSettle does not wait for.
    await waitFor(t, () => wc.hasWallet, what: 'wallet created');
    await t.pumpAndSettle();
    expect(wc.hasWallet, isTrue);
    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.text('SAFE TO SPEND TODAY'), findsOneWidget);

    // The save-key sheet opens right after create; the last 4 characters confirm it.
    final key = await wc.keyText();
    Harness.rememberKey(key);
    expect(find.byType(KeyBackupSheet), findsOneWidget);
    expect(find.text('Without this key, this wallet cannot be opened again on any device.'), findsOneWidget);
    await Harness.shot(t, 'onboarding-save-key');
    await t.tap(find.byKey(const ValueKey('keySaved')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('keyLast4')), key.substring(key.length - 4));
    await t.tap(find.byKey(const ValueKey('keyConfirm')));
    await t.pumpAndSettle();
    expect(find.byType(KeyBackupSheet), findsNothing);
    expect(wc.keyBackupConfirmed, isTrue);
    expect(find.byKey(const ValueKey('keyBackupRow')), findsNothing);

    // Then the "Set up my wallet" wizard: a screenshot per step, cash on hand in step 2, everything else skipped (nothing is written).
    expect(find.byType(SetupWizard), findsOneWidget);
    expect(find.text('Your bank files'), findsOneWidget);
    expect(wc.setupWizardState, 'step:1');
    await Harness.shot(t, 'onboarding-setup-1');
    await t.tap(find.byKey(const ValueKey('setupNext')));
    await t.pumpAndSettle();
    expect(find.text('Your accounts'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('setupCash')), '250');
    await t.tap(find.byKey(const ValueKey('setupCashAdd')));
    await t.pumpAndSettle();
    await Harness.shot(t, 'onboarding-setup-2');
    for (var n = 2; n <= 7; n++) {
      await t.tap(find.byKey(const ValueKey('setupSkip')));
      await t.pumpAndSettle();
      await Harness.shot(t, 'onboarding-setup-${n + 1}');
    }
    expect(find.text("Here's your wallet"), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('setupDone')));
    await t.pumpAndSettle();
    expect(find.byType(SetupWizard), findsNothing);
    expect(wc.setupWizardState, 'done');
    final cash = wc.accountsAll().single;
    expect((cash.name, cash.source, cash.currency, cash.opening, cash.openingDate), ('Cash', null, wc.currency, 25000, wc.today()));
    expect(find.byKey(const ValueKey('heldLine')), findsOneWidget);
    expect(key, startsWith('BW1-'));
    final stored = await KeyStore().read();
    expect(stored, isNotNull, reason: 'the key is kept on the device');
    expect(await stored!.toText(), key);
    expect(wc.goals.map((g) => g.name), ['Emergency fund', 'Yearly costs']);
    expect(wc.goals.map((g) => g.monthly), [10000, 10000]);

    // No salary yet: the banner asks for it and links to Plan.
    expect(find.text('Planning on 0\u00A0€ a month'), findsOneWidget);
    expect(find.textContaining('Enter your monthly salary in Budget'), findsOneWidget);
    await t.tap(find.text('Open Budget'));
    await t.pumpAndSettle();
    expect(find.text('PAYDAY PLAN'), findsOneWidget);
    await goTab(t, 'Today');
    await t.tap(find.text('Looks right'));
    await t.pumpAndSettle();
    expect(wc.settings.salaryConfirmed, isTrue);
    expect(find.text('Planning on 0\u00A0€ a month'), findsNothing);

    await scrollTo(t, find.textContaining('No transactions yet'), TodayScreen);
    expect(find.text('PBZ none · Revolut none'), findsOneWidget);
    await Harness.checkLog();
  });

  itest('Start a new wallet: the wizard can be closed early, cash is added later in Settings', (t) async {
    final wc = await Harness.start(t, wallet: false);
    await t.tap(find.text('Start a new wallet'));
    await waitFor(t, () => wc.hasWallet, what: 'wallet created');
    await t.pumpAndSettle();
    Harness.rememberKey(await wc.keyText());
    await t.tap(find.byKey(const ValueKey('keyLater')));
    await t.pumpAndSettle();
    expect(find.byType(SetupWizard), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('setupNext')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('setupSkip')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheetClose')));
    await t.pumpAndSettle();
    expect(find.byType(SetupWizard), findsNothing);
    expect(wc.setupWizardState, 'step:3', reason: 'closing early keeps the step');
    expect(wc.accountsAll(), isEmpty);
    expect(find.byKey(const ValueKey('heldLine')), findsNothing);

    // Settings › Accounts adds it any time.
    await goSettings(t, SettingsSection.accounts);
    await scrollTo(t, find.byKey(const ValueKey('accountAdd')), SettingsScreen);
    await t.tap(find.byKey(const ValueKey('accountAdd')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('accountOpening')), '40');
    await t.tap(find.byKey(const ValueKey('accountSave')));
    await t.pumpAndSettle();
    expect(wc.accountsAll().single.opening, 4000);
    await Harness.checkLog();
  });

  itest('Join: a wrong key is refused, the right key joins', (t) async {
    final other = await VaultKey.generate().toText(); // the "first device"'s key
    Harness.rememberKey(other);
    Harness.private(texts: ['BW1-NOT-A-REAL-KEY']);
    final wc = await Harness.start(t, wallet: false);

    await t.tap(find.text('Join my wallet from another device'));
    await t.pumpAndSettle();
    await t.enterText(field('Wallet key'), 'BW1-NOT-A-REAL-KEY');
    await t.tap(find.text('Join wallet'));
    await t.pumpAndSettle();
    expect(wc.hasWallet, isFalse);
    expect(find.byType(StatusLabel), findsOneWidget, reason: 'the error is shown');
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(await KeyStore().read(), isNull);

    await t.tap(find.text('Back'));
    await t.pumpAndSettle();
    expect(find.text('Start a new wallet'), findsOneWidget);
    await t.tap(find.text('Join my wallet from another device'));
    await t.pumpAndSettle();
    await t.enterText(field('Wallet key'), other);
    await t.tap(find.text('Join wallet'));
    // Joining writes the key and opens the database (real I/O), which pumpAndSettle does not wait for.
    await waitFor(t, () => wc.hasWallet, what: 'wallet joined');
    await t.pumpAndSettle();
    expect(wc.hasWallet, isTrue);
    expect(await wc.keyText(), other);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(SetupWizard), findsNothing, reason: 'the wizard is for a new wallet only');
    expect(wc.setupWizardState, isNull);
    expect(wc.goals, isEmpty, reason: 'a joined wallet gets its goals from sync, not new defaults');
    await Harness.checkLog(allowSevere: false);
  });
}
