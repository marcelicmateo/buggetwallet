// Stage RX5, moved by ENG E7a: the Bills & slips page (Expected bills with one state chip each, the bills database). Its Before payday,
// Per month / Per year and Until payday tiles went to the Money timeline (test/eng_money_test.dart), To review to Needs you
// (test/eng_needs_you_test.dart). Fixed clock (20 Oct 2026; the period ends 1 Nov), SYNTHETIC data only. Numbers come from core
// (`beforePayday`, `billsCost`); these tests pin what the tiles show per state, that the anchors still jump, exact cents, and that
// the page fits 320 dp at text 2.0, 360, 411 and 1280 dp, light and dark. Real fonts (Manrope, JetBrains Mono) (the test font is far wider).

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/fonts.dart';
import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 90));

Future<void> _loadFonts() async {
  await loadAppFonts();
}

Finder _key(String k) => find.byKey(ValueKey(k));

WalletController _wallet() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  return wc;
}

Future<void> _pump(WidgetTester t, WalletController wc,
    {Size size = const Size(400, 900), double scale = 1, Brightness mode = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: BillsScreen(wc: wc),
  ));
  await t.pump();
}

/// The tests end with the controller's 3 s sync debounce run out (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

Finder _in(String key, Finder f) => find.descendant(of: _key(key), matching: f);

void main() {
  setUpAll(_loadFonts);

  group('help behind the (i)', () {
    tw('Expected bills keep their help behind an info button, not on the page', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      expect(find.textContaining('Found in your imports'), findsNothing);
      await t.ensureVisible(_key('expectedInfo'));
      await t.tap(_key('expectedInfo'));
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
      expect(find.textContaining('Found in your imports'), findsOneWidget);
    });
  });

  group('rows', () {
    tw('a finished bill says All paid and has no "next" line', (t) async {
      final wc = _wallet();
      final id = wc.addRecurringBill(
          label: 'Synthetic loan', category: 'Groceries', amount: 2000, intervalDays: 30, firstDue: '2026-10-25', instalments: 1);
      await wc.skipRecurring(id);
      await _pump(t, wc);
      final b = wc.recurringBills().single;
      expect(b.finished, isTrue);
      expect(_in('bill:$id', find.text('All paid')), findsOneWidget);
      expect(_in('bill:$id', find.textContaining('next ')), findsNothing);
    });

    tw('an overdue bill: the row says Overdue (icon and word), no date chip', (t) async {
      final wc = _wallet();
      final id = wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      await _pump(t, wc);
      expect(_in('bill:$id', find.text('Overdue')), findsOneWidget);
      expect(_in('bill:$id', find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
      expect(_in('bill:$id', find.text('15 Oct')), findsNothing);
    });

    tw('a long bill held until paid: the Held chip with a lock and its whole amount', (t) async {
      final wc = _wallet();
      final id = wc.addRecurringBill(
          label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: addDays(wc.period().end, 40));
      await _pump(t, wc);
      expect(_in('bill:$id', find.text('Held')), findsOneWidget);
      expect(_in('bill:$id', find.byIcon(Icons.lock_outline)), findsOneWidget);
      expect(_in('bill:$id', find.text(moneyExact(60000, wc.currency))), findsOneWidget);
    });

    tw('a bill due: one date chip, no Overdue', (t) async {
      final wc = _wallet();
      final id =
          wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      expect(_in('bill:$id', find.text('25 Oct')), findsOneWidget);
      expect(_in('bill:$id', find.text('Overdue')), findsNothing);
    });

    tw('nothing: the empty note and Add bill', (t) async {
      final wc = _wallet();
      await _pump(t, wc);
      expect(find.textContaining('No repeating bills found yet'), findsOneWidget);
      expect(_key('billsAdd'), findsOneWidget);
    });
  });

  group('layout', () {
    const sizes = {
      '320 dp x 2.0': (Size(320, 640), 2.0),
      '360 dp x 1.0': (Size(360, 800), 1.0),
      '411 dp x 1.0': (Size(411, 850), 1.0),
      '1280 dp x 1.0': (Size(1280, 800), 1.0),
    };
    for (final mode in Brightness.values) {
      for (final e in sizes.entries) {
        tw('every state at ${e.key}, ${mode.name}: no overflow, nothing wider than the window', (t) async {
          final wc = _wallet();
          wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
          wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 4500, intervalDays: 30, firstDue: '2026-10-25');
          wc.addRecurringBill(
              label: 'Synthetic late bill with a long name',
              category: 'Groceries',
              amount: 123457,
              intervalDays: 30,
              firstDue: '2026-10-15');
          wc.addRecurringBill(
              label: 'Synthetic power',
              category: 'Groceries',
              amount: 12000,
              minAmount: 8000,
              maxAmount: 12000,
              intervalDays: 30,
              firstDue: '2026-10-27');
          wc.addRecurringBill(
              label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: addDays(wc.period().end, 40));
          wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-28', amount: 12000, category: 'Groceries');
          wc.repo.importBill(
              const NormalizedBill(source: BillSource.manual, externalId: 'rx5-slip', payee: 'Synthetic Slip Shop', total: 5000));
          wc.reload();
          await withErrors((errors) async {
            await _pump(t, wc, size: e.value.$1, scale: e.value.$2, mode: mode);
            await scrollThrough(t);
            expect(t.takeException(), isNull);
            errors.check();
          });
          for (final w in find.byType(Tile).evaluate()) {
            final r = t.getRect(find.byElementPredicate((x) => x == w));
            expect(r.right, lessThanOrEqualTo(e.value.$1.width + 0.5));
          }
        });
      }
    }
  });
}
