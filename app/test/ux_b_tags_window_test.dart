// UX-B2: Settings › Tags and rules (moved from the Explore switch in ENG E7b). The section holds the Recommendations, Main tags, Tags and Rules sections and one Add button
// (main tag / tag / rule). A recommendation changes nothing until Accept; Dismiss hides it on this device for good. SYNTHETIC data.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/budget.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/tags_window.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 90));

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> tapKey(WidgetTester t, String key) async {
  final f = k(key);
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

/// Three rows from one unknown card payee (no rule, no pattern: nothing decides their main tag), one from another.
WalletController untaggedWallet() {
  final wc = emptyWallet();
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS ZZYX SHOP 0000 ZAGREB'),
    syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS ZZYX SHOP 0000 ZAGREB'),
    syntheticTx('2026-10-08', -1200, 'POS plaćanje', 'POS ZZYX SHOP 0000 ZAGREB'),
    syntheticTx('2026-10-09', -3000, 'POS plaćanje', 'POS QQWV ONCE 0000 ZAGREB'),
  ]));
  wc.reload();
  return wc;
}

void main() {
  group('the Tags and rules section', () {
    testWidgets('a Settings section; the window has its sections and one add button; the Explore switch has no Tags segment', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      await pumpApp(t, Scaffold(body: BudgetScreen(wc: wc)), size: const Size(400, 3000));
      expect(k('budgetTags'), findsNothing, reason: 'Tags and rules moved to Settings');
      await t.tap(k('budgetSpending'));
      await t.pump(const Duration(milliseconds: 300));
      expect(wc.budgetView, 'spending');
      await pumpApp(t, Scaffold(body: SettingsScreen(wc: wc)), size: const Size(400, 6000));
      wc.openSettings(SettingsSection.tags);
      await t.pump(const Duration(milliseconds: 600));
      expect(k('tagsRecommendations'), findsOneWidget);
      expect(k('categoriesPanel'), findsOneWidget);
      expect(k('tagsPanel'), findsOneWidget);
      expect(k('rulesPanel'), findsOneWidget);
      expect(k('tagsAdd'), findsOneWidget);
      for (final gone in ['categoryAdd', 'rulesAdd']) {
        expect(k(gone), findsNothing, reason: 'the panels have no add button of their own');
      }
      await settle(t);
    }, timeout: _timeout);

    testWidgets('the Settings list and the phone page group their sections under headings (ENG E7b)', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      await pumpApp(t, Scaffold(body: SettingsScreen(wc: wc)), size: const Size(1200, 900));
      await t.pump(const Duration(milliseconds: 300));
      for (final g in ['YOUR MONEY', 'DEVICES AND SAFETY', 'REMINDERS', 'APP']) {
        expect(find.text(g), findsOneWidget, reason: g);
      }
      expect(k('settingsNav:tags'), findsOneWidget);
      await pumpApp(t, Scaffold(body: SettingsScreen(wc: wc)), size: const Size(400, 900));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('YOUR MONEY'), findsOneWidget, reason: 'the phone page shows the groups too');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('no Recommendations section when there is nothing to recommend', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
      expect(k('tagsRecommendations'), findsNothing);
      expect(k('rulesPanel'), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);

    for (final (what, field) in [('main', 'categoryName'), ('tag', 'tagName'), ('rule', 'ruleText')]) {
      testWidgets('Add › $what opens that form and nothing else', (t) async {
        final wc = emptyWallet();
        addTearDown(wc.dispose);
        await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
        await tapKey(t, 'tagsAdd');
        for (final choice in ['main', 'tag', 'rule']) {
          expect(k('tagsAdd:$choice'), findsOneWidget, reason: 'the sheet offers all three');
        }
        await t.tap(k('tagsAdd:$what'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        await t.pump(const Duration(milliseconds: 400));
        expect(k(field), findsOneWidget);
        for (final other in {'categoryName', 'tagName', 'ruleText'}.difference({field})) {
          expect(k(other), findsNothing);
        }
        await settle(t);
      }, timeout: _timeout);
    }

    testWidgets('320 dp at text scale 2.0 with a recommendation, no overflow', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      await pumpApp(t, tagsWindow(wc), size: const Size(320, 640), textScale: 2);
      expect(k('tagsRecommendations'), findsOneWidget);
      expect(t.takeException(), isNull);
      await settle(t);
    }, timeout: _timeout);
  });

  group('recommendations', () {
    testWidgets('a payee that keeps coming back is offered; one payment is not', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      final key = wc.uncategorisedPayeeList().first.merchantKey;
      expect(wc.payeeRecommendations().map((p) => p.merchantKey), [key], reason: 'the single payment is left out');
      await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
      expect(find.textContaining('3 payments, no main tag'), findsOneWidget);
      expect(k('tagsRecPayee:$key'), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Accept opens the rule form with the payee and a main tag; nothing is written before Save', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      final key = wc.payeeRecommendations().single.merchantKey;
      await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
      await tapKey(t, 'tagsRecPayeeAccept:$key');
      expect(t.widget<DropdownButton<String>>(k('rulePayee')).value, key, reason: 'the payee is filled in');
      expect(wc.categorizer.merchantRules, isEmpty, reason: 'the form is open, nothing saved');
      await tapKey(t, 'ruleSave');
      expect(wc.categorizer.merchantRules[key], wc.setupMainTagIds().first);
      expect(k('tagsRecPayee:$key'), findsNothing, reason: 'a payee with a rule is no longer untagged');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('closing the form without saving leaves the card and writes nothing', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      final key = wc.payeeRecommendations().single.merchantKey;
      await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
      await tapKey(t, 'tagsRecPayeeAccept:$key');
      await t.tapAt(const Offset(200, 20)); // the barrier above the sheet
      await t.pump(const Duration(milliseconds: 400));
      expect(k('ruleText'), findsNothing);
      expect(k('tagsRecPayee:$key'), findsOneWidget);
      expect(wc.categorizer.merchantRules, isEmpty);
      expect(wc.settings.patternRules, isEmpty);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Dismiss hides the card, writes no rule, and stays hidden after a reload and in a new controller', (t) async {
      final wc = untaggedWallet();
      addTearDown(wc.dispose);
      final key = wc.payeeRecommendations().single.merchantKey;
      await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
      await tapKey(t, 'tagsRecPayeeDismiss:$key');
      expect(k('tagsRecPayee:$key'), findsNothing);
      expect(k('tagsRecommendations'), findsNothing, reason: 'the section goes with its last card');
      expect(wc.categorizer.merchantRules, isEmpty);
      wc.reload();
      expect(wc.payeeRecommendations(), isEmpty);
      final again = seamedController(wc.repo, key: VaultKey.generate());
      addTearDown(again.dispose);
      expect(again.payeeRecommendations(), isEmpty);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('a rule suggestion sits here: Accept makes the rule with an Undo', (t) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-08', -1200, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
      ]));
      for (final r in wc.repo.transactions()) {
        wc.repo.setCategory(r.id, 'Eating out');
      }
      wc.reload();
      await pumpApp(t, tagsWindow(wc), size: const Size(400, 3000));
      expect(k('ruleSuggest:konzum_zagreb'), findsOneWidget);
      expect(wc.categorizer.merchantRules, isEmpty, reason: 'shown, not applied');
      await tapKey(t, 'ruleSuggestMake:konzum_zagreb');
      expect(wc.categorizer.merchantRules['konzum_zagreb'], 'Eating out');
      await settle(t);
    }, timeout: _timeout);
  });
}
