// KL-UI2: search also finds rules by their pattern / payee text and category label (a "Rules" section, rows `searchRule:<id>`),
// and a tap opens the rule's edit form. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/rules_panel.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 60));

Finder _k(String key) => find.byKey(ValueKey(key));

Future<WalletController> _wallet() async {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  wc.repo.setMerchantPattern('Groceries', 'zorbaplex', match: 'contains');
  wc.repo.setMerchantPattern('Eating out', '^quillmart', match: 'regex');
  wc.repo.setMerchantRule('zorbaplex_cafe', 'Eating out');
  wc.reload();
  return wc;
}

Future<void> _search(WidgetTester t, WalletController wc, String q, {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(t, Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {})), size: size, textScale: scale);
  await t.enterText(_k('searchField'), q);
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

void main() {
  testWidgets('a pattern text finds its rule, with the match bold and the category label under it', (t) async {
    final wc = await _wallet();
    await _search(t, wc, 'zorba');
    final rules = wc.search('zorba').rules;
    expect(rules, hasLength(2));
    for (final r in rules) {
      expect(_k('searchRule:${r.id}'), findsOneWidget);
    }
    expect(find.text('RULES'), findsOneWidget);
    // The match is a bold span inside the rule's text.
    final bolds = find.descendant(
        of: _k('searchRule:${rules.first.id}'),
        matching: find.byWidgetPredicate((w) {
          if (w is! RichText) return false;
          var bold = false;
          w.text.visitChildren((s) {
            if (s is TextSpan && s.style?.fontWeight == FontWeight.w800) bold = true;
            return true;
          });
          return bold;
        }));
    expect(bolds, findsWidgets);
    expect(find.textContaining('→ Groceries', findRichText: true), findsOneWidget);
    expect(find.textContaining('→ Eating out', findRichText: true), findsOneWidget);
  }, timeout: _timeout);

  testWidgets('a category label finds the rules that put payments there', (t) async {
    final wc = await _wallet();
    await _search(t, wc, 'eating');
    final ids = wc.search('eating').rules.map((r) => r.id).toList();
    // Our two rules, and maybe a built-in rule that also puts payments in Eating out.
    expect(ids.where((id) => !id.startsWith('builtIn:')), hasLength(2));
    for (final id in ids) {
      expect(_k('searchRule:$id'), findsOneWidget);
    }
    expect(_k('searchRule:${wc.rulesList.firstWhere((r) => r.text == 'zorbaplex').id}'), findsNothing);
  }, timeout: _timeout);

  testWidgets('no match: no Rules section; with a filter on, no rules are listed', (t) async {
    final wc = await _wallet();
    await _search(t, wc, 'nomatchhere');
    expect(find.text('RULES'), findsNothing);
    expect(wc.search('zorba').rules, isNotEmpty);
    expect(wc.searchFiltered('zorba', const SearchFilter(uncategorised: true)).rules, isEmpty);
  }, timeout: _timeout);

  testWidgets('a tap opens the rule in its edit form', (t) async {
    final wc = await _wallet();
    await _search(t, wc, 'quill');
    final r = wc.search('quill').rules.single;
    await t.tap(_k('searchRule:${r.id}'));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(RuleFormSheet), findsOneWidget);
    expect(t.takeException(), isNull);
  }, timeout: _timeout);

  testWidgets('a row fits 320 dp at text 2.0', (t) async {
    final wc = await _wallet();
    await _search(t, wc, 'zorba', size: const Size(320, 2400), scale: 2);
    expect(t.takeException(), isNull);
    expect(find.text('RULES'), findsOneWidget);
  }, timeout: _timeout);
}
