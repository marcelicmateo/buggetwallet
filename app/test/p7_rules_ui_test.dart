// Stage P7 UI: Plan › Rules. The list (payee, text, payee-tags and built-in rules, the counts), Add rule (contains with an amount range,
// a range alone refused, core's message under the field), Edit with the "changes N payments" preview, delete with Undo, move, the
// "Make a rule…" link in the payment sheet, and the layouts. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/rules_panel.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 90));

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> tapKey(WidgetTester t, String key, {bool last = false}) async {
  final f = last ? find.byKey(ValueKey(key)).last : find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

const konzum = 'konzum_zagreb';

/// Three KONZUM rows (1850, 940, 1200), one LIDL row (3000) and one PLODINE row (500), all EUR, all Groceries by the built-in rules.
WalletController rulesWallet() {
  final wc = emptyWallet();
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-08', -1200, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-09', -3000, 'POS plaćanje', 'POS LIDL 0000 ZAGREB'),
    syntheticTx('2026-10-10', -500, 'POS plaćanje', 'POS PLODINE 0000 ZAGREB'),
  ]));
  wc.reload();
  return wc;
}

Widget rulesPanel(WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: RulesPanel(wc: wc))));

String patternId(WalletController wc, String text) => wc.settings.patternRules.firstWhere((p) => p.pattern == text).id;

Future<void> pickMain(WidgetTester t, String id) async {
  // The payment sheet under the form has a picker of its own (key txCategory); the form's is the last.
  final picker = find.byKey(const ValueKey('txCategory')).last;
  await t.ensureVisible(picker);
  await t.tap(picker);
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.byKey(ValueKey('pick:$id')).last);
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> pumpVariant(WidgetTester t, Widget child,
    {required Size size, double scale = 1, Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: child,
  ));
  await t.pump();
}

void main() {
  group('the list', () {
    testWidgets('shows each kind with its main tag, tags, range and count; built-ins are collapsed', (t) async {
      final wc = rulesWallet();
      final holiday = await wc.addTag('Holiday');
      final kids = await wc.addTag('Kids');
      wc.repo.setMerchantRule(konzum, 'Eating out');
      await wc.repo.setRuleTag(konzum, holiday, true);
      await wc.repo.setRuleTag('other_shop', kids, true);
      wc.repo.setMerchantPattern('Shopping', 'lidl', match: 'contains', minCents: 1200, maxCents: 3000);
      wc.repo.setMerchantPattern('Cash', r'^plod');
      wc.reload();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2400));

      expect(k('ruleText:payee:$konzum'), findsOneWidget);
      expect(find.descendant(of: k('rule:payee:$konzum'), matching: find.text('→ Eating out')), findsOneWidget);
      expect(find.descendant(of: k('rule:payee:$konzum'), matching: find.text('#Holiday')), findsOneWidget);
      expect(find.descendant(of: k('rule:payee:$konzum'), matching: find.text('used by 3 payments')), findsOneWidget);

      final lidl = patternId(wc, 'lidl');
      expect(find.descendant(of: k('rule:$lidl'), matching: find.text('lidl')), findsOneWidget);
      expect(find.descendant(of: k('rule:$lidl'), matching: find.text('Description contains')), findsOneWidget);
      expect(find.descendant(of: k('rule:$lidl'), matching: find.text('→ Shopping')), findsOneWidget);
      expect(find.descendant(of: k('rule:$lidl'), matching: find.text('12.00–30.00 €')), findsOneWidget);
      expect(find.descendant(of: k('rule:$lidl'), matching: find.text('used by 1 payment')), findsOneWidget);
      final plod = patternId(wc, r'^plod');
      expect(find.descendant(of: k('rule:$plod'), matching: find.text('Pattern')), findsOneWidget);
      expect(find.descendant(of: k('rule:$plod'), matching: find.text('→ Cash')), findsOneWidget);

      // A payee that only has tags: no main tag, no count.
      expect(find.descendant(of: k('rule:payeeTags:other_shop'), matching: find.text('#Kids')), findsOneWidget);
      expect(k('ruleCount:payeeTags:other_shop'), findsNothing);

      // Built-ins: folded until the toggle is tapped.
      expect(k('rule:builtIn:0'), findsNothing);
      expect(find.textContaining('Built in (read-only)'), findsOneWidget);
      await tapKey(t, 'builtInToggle');
      expect(k('rule:builtIn:0'), findsOneWidget);
      expect(find.descendant(of: k('rule:builtIn:0'), matching: find.byType(PopupMenuButton<Object?>)), findsNothing);
      expect(t.takeException(), isNull);
      wc.dispose();
    });

    testWidgets('an empty list says so', (t) async {
      final wc = rulesWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 1600));
      expect(k('rulesEmpty'), findsOneWidget);
      expect(k('builtInToggle'), findsOneWidget);
      wc.dispose();
    });

    test('the list and the counts are computed once per data version', () {
      final wc = rulesWallet();
      wc.repo.setMerchantPattern('Shopping', 'lidl', match: 'contains');
      wc.reload();
      expect(identical(wc.rulesList, wc.rulesList), isTrue);
      expect(identical(wc.ruleUseCounts(), wc.ruleUseCounts()), isTrue);
      final before = wc.rulesList;
      wc.reload();
      expect(identical(wc.rulesList, before), isFalse, reason: 'a new data version builds it again');
      wc.dispose();
    });
  });

  group('Add rule', () {
    testWidgets('a description-contains rule with an amount range', (t) async {
      final wc = rulesWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 1600));
      await tapKey(t, 'rulesAdd');
      expect(k('ruleMode:contains'), findsOneWidget);
      await t.enterText(k('ruleText'), '  LÍDL ');
      await t.enterText(k('ruleMin'), '12');
      await t.enterText(k('ruleMax'), '30,00');
      await pickMain(t, 'Shopping');
      await tapKey(t, 'ruleSave');
      final p = wc.settings.patternRules.single;
      expect((p.pattern, p.match, p.category, p.minCents, p.maxCents), ('LÍDL', 'contains', 'Shopping', 1200, 3000));
      expect(k('ruleText'), findsNothing, reason: 'the form closed');
      expect(find.text('LÍDL'), findsOneWidget);
      expect(find.textContaining('12.00–30.00'), findsOneWidget);
      await settle(t);
      wc.dispose();
    });

    testWidgets('a range without text is refused', (t) async {
      final wc = rulesWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 1600));
      await tapKey(t, 'rulesAdd');
      await t.enterText(k('ruleMin'), '10');
      await pickMain(t, 'Shopping');
      await tapKey(t, 'ruleSave');
      expect(find.text('Add text to match: rules never use the amount alone.'), findsOneWidget);
      expect(wc.settings.patternRules, isEmpty);
      expect(k('ruleText'), findsOneWidget, reason: 'the form stays open');
      wc.dispose();
    });

    testWidgets("core's message shows under the field, and a bad range under its fields", (t) async {
      final wc = rulesWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 1800));
      await tapKey(t, 'rulesAdd');
      await tapKey(t, 'ruleMode:regex');
      expect(k('ruleMin'), findsNothing, reason: 'a range works with description contains only');
      await t.enterText(k('ruleText'), '(');
      await pickMain(t, 'Shopping');
      await tapKey(t, 'ruleSave');
      expect(find.text('Pattern does not compile.'), findsOneWidget);
      expect(wc.settings.patternRules, isEmpty);

      await tapKey(t, 'ruleMode:contains');
      await t.enterText(k('ruleText'), 'shop');
      await t.enterText(k('ruleMin'), '50');
      await t.enterText(k('ruleMax'), '20');
      await tapKey(t, 'ruleSave');
      expect(find.text('The lower amount is above the upper one.'), findsOneWidget);
      expect(wc.settings.patternRules, isEmpty);

      await t.enterText(k('ruleMin'), 'abc');
      await tapKey(t, 'ruleSave');
      expect(find.text('Enter an amount, like 12.50.'), findsOneWidget);
      wc.dispose();
    });

    testWidgets('switching to regex clears a typed range and says why', (t) async {
      final wc = rulesWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 1800));
      await tapKey(t, 'rulesAdd');
      await t.enterText(k('ruleMin'), '10');
      await tapKey(t, 'ruleMode:regex');
      expect(find.text("Amount ranges work with 'description contains' only."), findsOneWidget);
      expect(k('ruleMin'), findsNothing);
      await tapKey(t, 'ruleMode:contains');
      expect((t.widget(k('ruleMin')) as TextField).controller!.text, '');
      expect(k('rangeNote'), findsNothing);
      wc.dispose();
    });

    testWidgets('a payee rule with a tag', (t) async {
      final wc = rulesWallet();
      final holiday = await wc.addTag('Holiday');
      wc.reload();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'rulesAdd');
      await tapKey(t, 'ruleMode:payee');
      expect(k('ruleMin'), findsNothing, reason: 'payee rules have no range');
      await t.tap(k('rulePayee'));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const ValueKey('payeeItem:$konzum')).last);
      await t.pump(const Duration(milliseconds: 400));
      await pickMain(t, 'Eating out');
      await tapKey(t, 'rtag:$holiday');
      await tapKey(t, 'ruleSave');
      expect(wc.repo.merchantRules()[konzum], 'Eating out');
      expect(wc.repo.ruleTags()[konzum], {holiday});
      expect(k('rule:payee:$konzum'), findsOneWidget);
      await settle(t);
      wc.dispose();
    });

    testWidgets('no main tag picked is refused', (t) async {
      final wc = rulesWallet();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 1600));
      await tapKey(t, 'rulesAdd');
      await t.enterText(k('ruleText'), 'lidl');
      await tapKey(t, 'ruleSave');
      expect(k('ruleCatError'), findsOneWidget);
      expect(wc.settings.patternRules, isEmpty);
      wc.dispose();
    });
  });

  group('Edit, delete, move', () {
    testWidgets('an edit shows how many payments change before it saves', (t) async {
      final wc = rulesWallet();
      wc.repo.setMerchantPattern('Groceries', 'lidl', match: 'contains');
      wc.reload();
      final id = patternId(wc, 'lidl');
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'ruleMenu:$id');
      await tapKey(t, 'ruleEdit:$id');
      expect(find.text('Edit rule'), findsOneWidget);
      expect(k('ruleMode:contains'), findsNothing, reason: 'the kind of an existing rule stays');
      await pickMain(t, 'Shopping');
      await tapKey(t, 'rulePreview');
      expect(find.text('This changes the main tag of 1 payment.'), findsOneWidget);
      await t.enterText(k('ruleMin'), '40');
      await t.pump();
      expect(k('rulePreviewText'), findsNothing, reason: 'a changed form drops the old count');
      await t.enterText(k('ruleMin'), '');
      await t.pump();
      expect(k('rulePreviewText'), findsOneWidget, reason: 'back to the previewed values');
      await tapKey(t, 'ruleSave');
      expect(wc.settings.patternRules.single.category, 'Shopping');
      expect(wc.settings.patternRules.single.id, id, reason: 'a main tag change keeps the row');
      await settle(t);
      wc.dispose();
    });

    testWidgets('Save without a preview shows the count first; the second tap saves', (t) async {
      final wc = rulesWallet();
      wc.repo.setMerchantPattern('Groceries', 'lidl', match: 'contains');
      wc.reload();
      final id = patternId(wc, 'lidl');
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'ruleMenu:$id');
      await tapKey(t, 'ruleEdit:$id');
      await pickMain(t, 'Shopping');
      await tapKey(t, 'ruleSave');
      expect(find.text('This changes the main tag of 1 payment.'), findsOneWidget);
      expect(wc.settings.patternRules.single.category, 'Groceries', reason: 'nothing written yet');
      await tapKey(t, 'ruleSave');
      expect(wc.settings.patternRules.single.category, 'Shopping');
      await settle(t);
      wc.dispose();
    });

    testWidgets('a range edit that changes nothing saves at once, and an edit can clear the range', (t) async {
      final wc = rulesWallet();
      wc.repo.setMerchantPattern('Groceries', 'konzum', match: 'contains', minCents: 1000, maxCents: 2000);
      wc.reload();
      final id = patternId(wc, 'konzum');
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'ruleMenu:$id');
      await tapKey(t, 'ruleEdit:$id');
      expect((t.widget(k('ruleMin')) as TextField).controller!.text, '10');
      expect((t.widget(k('ruleMax')) as TextField).controller!.text, '20');
      await t.enterText(k('ruleMin'), '');
      await t.enterText(k('ruleMax'), '');
      await tapKey(t, 'ruleSave');
      final p = wc.settings.patternRules.single;
      expect((p.minCents, p.maxCents), (null, null));
      await settle(t);
      wc.dispose();
    });

    testWidgets('editing a payee rule changes its main tag and tags', (t) async {
      final wc = rulesWallet();
      final holiday = await wc.addTag('Holiday');
      wc.repo.setMerchantRule(konzum, 'Eating out');
      wc.reload();
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'ruleMenu:payee:$konzum');
      await tapKey(t, 'ruleEdit:payee:$konzum');
      expect(k('rulePayeeFixed'), findsOneWidget);
      await pickMain(t, 'Shopping');
      await tapKey(t, 'rtag:$holiday');
      await tapKey(t, 'rulePreview');
      expect(find.text('This changes the main tag of 3 payments.'), findsOneWidget);
      await tapKey(t, 'ruleSave');
      expect(wc.repo.merchantRules()[konzum], 'Shopping');
      expect(wc.repo.ruleTags()[konzum], {holiday});
      await settle(t);
      wc.dispose();
    });

    testWidgets('delete removes the rule and Undo brings it back', (t) async {
      final wc = rulesWallet();
      wc.repo.setMerchantPattern('Shopping', 'lidl', match: 'contains', minCents: 1200, maxCents: 3000);
      wc.reload();
      final id = patternId(wc, 'lidl');
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'ruleMenu:$id');
      await tapKey(t, 'ruleDelete:$id');
      expect(wc.settings.patternRules, isEmpty);
      expect(k('rulesEmpty'), findsOneWidget);
      expect(find.text('Rule removed'), findsOneWidget);
      await t.tap(k('toastUndo'));
      await t.pump(const Duration(milliseconds: 400));
      final p = wc.settings.patternRules.single;
      expect((p.pattern, p.match, p.category, p.minCents, p.maxCents), ('lidl', 'contains', 'Shopping', 1200, 3000));
      expect(k('rule:$id'), findsOneWidget);
      await settle(t);
      wc.dispose();
    });

    testWidgets('move up and down change the order; the ends are off', (t) async {
      final wc = rulesWallet();
      wc.repo.setMerchantPattern('Shopping', 'aaa', match: 'contains');
      wc.repo.setMerchantPattern('Cash', 'bbb', match: 'contains');
      wc.reload();
      final a = patternId(wc, 'aaa'), b = patternId(wc, 'bbb');
      expect(wc.settings.patternRules.map((p) => p.pattern), ['aaa', 'bbb']);
      await pumpApp(t, rulesPanel(wc), size: const Size(400, 2000));
      await tapKey(t, 'ruleMenu:$a');
      expect(t.widget<PopupMenuItem<Object?>>(find.byKey(ValueKey('ruleUp:$a'))).enabled, isFalse);
      expect(t.widget<PopupMenuItem<Object?>>(find.byKey(ValueKey('ruleDown:$a'))).enabled, isTrue);
      await tapKey(t, 'ruleDown:$a');
      expect(wc.settings.patternRules.map((p) => p.pattern), ['bbb', 'aaa']);
      expect(t.getTopLeft(k('rule:$b')).dy, lessThan(t.getTopLeft(k('rule:$a')).dy), reason: 'the list follows');
      await tapKey(t, 'ruleMenu:$a');
      await tapKey(t, 'ruleUp:$a');
      expect(wc.settings.patternRules.map((p) => p.pattern), ['aaa', 'bbb']);
      await settle(t);
      wc.dispose();
    });
  });

  group('Make a rule… in the payment sheet', () {
    testWidgets('opens Add rule with the payee and the payment main tag', (t) async {
      final wc = rulesWallet();
      final row = wc.txs.firstWhere((x) => x.tx.description.contains('KONZUM'));
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 3200));
      await tapKey(t, 'makeRule');
      expect(find.text('Add rule'), findsOneWidget);
      expect(t.widget<DropdownButton<String>>(k('rulePayee')).value, konzum);
      expect(t.widget<DropdownButton<String>>(find.byKey(const ValueKey('txCategory')).last).value, 'Groceries');
      expect(k('ruleMode:payee'), findsOneWidget);
      await pickMain(t, 'Eating out');
      await tapKey(t, 'ruleSave');
      expect(wc.repo.merchantRules()[konzum], 'Eating out');
      await settle(t);
      wc.dispose();
    });

    testWidgets('a hand-added payment without a note has no link', (t) async {
      final wc = rulesWallet();
      wc.repo.addTransaction(date: '2026-10-11', amount: -700, category: 'Cash', note: '', currency: 'EUR');
      wc.reload();
      final row = wc.txs.firstWhere((x) => x.tx.manual);
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 3200));
      expect(k('makeRule'), findsNothing);
      wc.dispose();
    });
  });

  group('layouts', () {
    for (final (name, size, scale, brightness) in [
      ('320 dp at text 2.0', const Size(320, 4200), 2.0, Brightness.light),
      ('400 dp dark', const Size(400, 3200), 1.0, Brightness.dark),
      ('1280 wide', const Size(1280, 2000), 1.0, Brightness.light),
    ]) {
      testWidgets('the Rules list and the form fit at $name', (t) async {
        final wc = rulesWallet();
        final holiday = await wc.addTag('Holiday');
        await wc.addTag('A long tag name for a small phone');
        wc.repo.setMerchantRule(konzum, 'Eating out');
        await wc.repo.setRuleTag(konzum, holiday, true);
        wc.repo.setMerchantPattern('Shopping', 'a long text that is looked for in a description',
            match: 'contains', minCents: 123456, maxCents: 7890123);
        wc.repo.setMerchantPattern('Cash', r'^(plodine|konzum)\s+\d{4}$');
        wc.reload();
        await pumpVariant(t, rulesPanel(wc), size: size, scale: scale, brightness: brightness);
        expect(t.takeException(), isNull);
        await tapKey(t, 'builtInToggle');
        expect(t.takeException(), isNull);
        final id = patternId(wc, 'a long text that is looked for in a description');
        await tapKey(t, 'ruleMenu:$id');
        expect(t.takeException(), isNull);
        await t.tapAt(const Offset(2, 2));
        await t.pump(const Duration(milliseconds: 400));
        await tapKey(t, 'rulesAdd');
        expect(t.takeException(), isNull);
        await tapKey(t, 'ruleMode:payee');
        await tapKey(t, 'rulePreview');
        expect(t.takeException(), isNull);
        await tapKey(t, 'ruleMode:regex');
        await t.enterText(k('ruleText'), '(');
        await tapKey(t, 'ruleSave');
        expect(t.takeException(), isNull);
        expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, brightness);
        await settle(t);
        wc.dispose();
      }, timeout: _timeout);
    }
  });
}
