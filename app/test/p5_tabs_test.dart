// P5: the five tabs (Today, Budget, Bills, Save, Settings): what each one holds, the links that open them, Settings on one page and in
// two panes. The panels themselves are tested where they were (they moved unchanged). All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/budget.dart';
import 'package:budget_wallet/src/screens/goals.dart';
import 'package:budget_wallet/src/screens/save.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/wishlist.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/widgets/rebuild_when_shown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

/// A widget test that lets the controller's 3 s sync debounce run out before it ends (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

Finder _key(String k) => find.byKey(ValueKey(k));

WalletController _wallet({bool bill = false}) {
  final wc = habitsWallet(confirmBill: bill);
  addTearDown(wc.dispose);
  return wc;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

/// The distance of [f] from the top of the window (what is higher is above).
double _top(WidgetTester t, Finder f) => t.getTopLeft(f).dy;

Future<void> _scrollInto(WidgetTester t, Finder f, Type screen) async {
  await t.scrollUntilVisible(f, 300, scrollable: find.descendant(of: find.byType(screen), matching: find.byType(Scrollable)).first);
  await _settle(t);
}

void main() {
  group('the bar', () {
    tw('five destinations in order, with their keys, labels and icons', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      final nav = find.byType(NavigationBar);
      expect(nav, findsOneWidget);
      expect(t.widget<NavigationBar>(nav).destinations.length, 5);
      final labels = [for (final d in t.widgetList<NavigationDestination>(find.byType(NavigationDestination))) d.label];
      expect(labels, ['Today', 'Budget', 'Bills', 'Save', 'Settings']);
      for (final name in Tabs.names) {
        expect(_key('tab:$name'), findsOneWidget);
      }
      // Outlined when not selected, filled when selected.
      expect(find.byIcon(Icons.account_balance_wallet), findsOneWidget);
      expect(find.byIcon(Icons.bar_chart_outlined), findsOneWidget);
      expect(find.byIcon(Icons.receipt_long_outlined), findsOneWidget);
      expect(find.byIcon(Icons.savings_outlined), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      await tapTab(t, 'Save');
      expect(find.byIcon(Icons.savings), findsOneWidget);
      expect(find.byIcon(Icons.savings_outlined), findsNothing);
    });

    tw('the rail has the same five, in the same order', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(900, 800));
      final rail = t.widget<NavigationRail>(find.byType(NavigationRail));
      expect([for (final d in rail.destinations) (d.label as Text).data], ['Today', 'Budget', 'Bills', 'Save', 'Settings']);
      for (final name in Tabs.names) {
        expect(_key('tab:$name'), findsOneWidget);
      }
    });
  });

  group('Budget', () {
    tw('Budget opens on Spending; the payday plan is one tap away behind the switch', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      await tapTab(t, 'Budget');
      expect(find.byType(SpendingScreen), findsOneWidget);
      expect(_key('budgetSwitch'), findsOneWidget);
      expect(_key('outTile'), findsOneWidget);
      expect(_key('planHeading'), findsNothing, reason: 'Plan is the other page');
      await t.tap(_key('budgetPlan'));
      await t.pump(const Duration(milliseconds: 300));
      expect(_key('planHeading'), findsOneWidget);
      expect(_key('planEdit'), findsOneWidget);
      expect(_key('outTile'), findsNothing);
      expect(t.takeException(), isNull);
    });

    tw('Insights and search stay on the page', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      await tapTab(t, 'Budget');
      expect(_key('insightsOpen'), findsOneWidget);
      expect(_key('searchOpen'), findsOneWidget);
    });
  });

  group('Save', () {
    tw('Goals first, then the wishlist, in one scroll', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      await tapTab(t, 'Save');
      expect(find.byType(SaveScreen), findsOneWidget);
      expect(find.byType(GoalsScreen), findsOneWidget);
      expect(find.byType(WishlistScreen), findsOneWidget);
      final goals = find.text('GOALS'), check = find.text('CAN I AFFORD IT?');
      expect(goals, findsOneWidget);
      await _scrollInto(t, check, SaveScreen);
      expect(check, findsOneWidget);
      expect(t.getTopLeft(find.byType(GoalsScreen)).dy, lessThan(t.getTopLeft(find.byType(WishlistScreen)).dy));
      expect(find.descendant(of: _key('savePage'), matching: find.byType(GoalsScreen)), findsOneWidget, reason: 'one scroll for both');
      expect(find.descendant(of: _key('savePage'), matching: find.byType(WishlistScreen)), findsOneWidget);
    });

    tw('a wish opened from a toast scrolls into view on Save', (t) async {
      final wc = _wallet();
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      final id = wc.addWish('Synthetic highlighted wish', 9000);
      await _settle(t);
      wc.openWish(id);
      await _settle(t);
      expect(find.byType(SaveScreen), findsOneWidget, reason: 'Save is the tab shown');
      expect(find.text('Synthetic highlighted wish'), findsOneWidget);
    });
  });

  group('Bills', () {
    tw('Before payday, Expected bills and the bills database, with Add bill', (t) async {
      final wc = _wallet(bill: true);
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await tapTab(t, 'Bills');
      expect(find.byType(BillsScreen), findsOneWidget);
      expect(_key('comingUpPanel'), findsOneWidget);
      expect(find.text('BEFORE PAYDAY'), findsOneWidget);
      expect(_key('billsAdd'), findsOneWidget);
      expect(find.text('Add bill'), findsOneWidget, reason: 'one Add bill, in the Expected bills tile (no second button)');
      expect(_key('addRecurring'), findsNothing);
      expect(find.text('EXPECTED BILLS'), findsOneWidget);
      await _scrollInto(t, _key('importBill'), BillsScreen);
      expect(t.takeException(), isNull);
    });

    tw('Before payday shows core\'s number and count; each bill has one state chip with its date', (t) async {
      final wc = _wallet(bill: true);
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await tapTab(t, 'Bills');
      final p = wc.period();
      expect(p.dueCycles, isNotEmpty);
      final tile = _key('comingUpPanel');
      expect(find.descendant(of: tile, matching: find.text(moneyExact(p.beforePayday, wc.currency))), findsOneWidget);
      final n = p.beforePaydayCount;
      expect(find.descendant(of: tile, matching: find.text('$n ${n == 1 ? 'cost' : 'costs'}')), findsOneWidget);
      for (final x in p.dueCycles) {
        final row = _key('bill:${x.bill.id}');
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(shortDateOrRaw(x.due))), findsOneWidget);
      }
      expect(find.textContaining('29.99'), findsWidgets);
    });

    tw('no bills before payday: the tile says Nothing due', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      await tapTab(t, 'Bills');
      expect(find.descendant(of: _key('comingUpPanel'), matching: find.text('Nothing due')), findsOneWidget);
    });

    tw('Add bill opens the repeating bill form', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      await tapTab(t, 'Bills');
      await t.tap(_key('billsAdd'));
      await t.pumpAndSettle();
      expect(_key('recurringSheet'), findsOneWidget);
    });

    tw('Today\'s Overdue tile (an unpaid bill past its date) opens the Bills tab', (t) async {
      final wc = _wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-06-10', '2026-07-10', '2026-08-10']) syntheticTx(d, -4500, 'POS plaćanje', 'POS SYNTHPOOL ZAGREB'),
      ]));
      wc.reload();
      wc.refreshRecurring();
      for (final b in wc.recurringBills()) {
        wc.confirmRecurring(b.id);
      }
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await _scrollInto(t, _key('billsLine'), TodayScreen);
      await t.tap(_key('billsLine'));
      await t.pumpAndSettle();
      expect(find.byType(BillsScreen), findsOneWidget);
      expect(find.byType(TodayScreen), findsNothing);
    });

    tw('a slip to review: Today\'s line opens Bills at To review, which lists it', (t) async {
      final wc = _wallet();
      wc.repo.importBill(const NormalizedBill(source: BillSource.manual, externalId: 'p5-slip', payee: 'Synthetic Slip Shop', total: 5000));
      wc.reload();
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await _scrollInto(t, _key('billsToReview'), TodayScreen);
      await t.tap(_key('billsToReview'));
      await t.pumpAndSettle();
      expect(find.byType(BillsScreen), findsOneWidget);
      expect(find.text('TO REVIEW'), findsOneWidget);
      expect(_key('billsReviewPanel'), findsOneWidget);
      expect(find.text('Synthetic Slip Shop'), findsOneWidget, reason: 'listed once: the database panel leaves To review to this panel');
      expect(t.takeException(), isNull);
    });
  });

  group('review fixes', () {
    tw('search: a wish result opens Save on that wish; an expected bill opens Bills at Expected bills', (t) async {
      final wc = _wallet(bill: true); // a confirmed SYNTHGYM bill and a "Synthetic lamp" wish
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await t.tap(_key('appBarSearch'));
      await t.pumpAndSettle();
      await t.enterText(_key('searchField'), 'synth');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Synthetic lamp'));
      await t.tap(find.text('Synthetic lamp'));
      await t.pumpAndSettle();
      expect(find.byType(SaveScreen), findsOneWidget);
      expect(wc.highlightWish.value, isNull, reason: 'Save took the highlight');
      final y = t.getTopLeft(find.text('Synthetic lamp')).dy;
      expect(y, inInclusiveRange(0, 900), reason: 'the wish is on screen');

      await tapTab(t, 'Budget');
      await t.pumpAndSettle();
      await t.tap(_key('appBarSearch'));
      await t.pumpAndSettle();
      await t.enterText(_key('searchField'), 'synth');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      final bill = find.textContaining('Confirmed');
      await t.ensureVisible(bill);
      await t.tap(bill);
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(BillsScreen), findsOneWidget);
      expect(find.text('EXPECTED BILLS'), findsOneWidget);
      expect(_top(t, find.text('EXPECTED BILLS')), lessThan(400), reason: 'scrolled to Expected bills');
    });

    tw('a long bill held until paid shows the Held chip with its whole amount, and core counts it in Before payday', (t) async {
      final wc = _wallet();
      final due = addDays(wc.period().end, 40);
      final id = wc.addRecurringBill(label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: due);
      final p = wc.period();
      final held = p.dueCycles.where((c) => c.bill.id == id).single;
      expect(held.reserve, 60000, reason: 'core holds the whole yearly amount');
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await tapTab(t, 'Bills');
      expect(find.descendant(of: _key('bill:$id'), matching: find.text('Held')), findsOneWidget);
      expect(find.descendant(of: _key('bill:$id'), matching: find.text(moneyExact(60000, wc.currency))), findsOneWidget);
      expect(_key('billHeld:$id'), findsOneWidget);
      expect(p.beforePayday, 60000, reason: 'core holds the whole yearly amount from the start');
      expect(find.descendant(of: _key('comingUpPanel'), matching: find.text(moneyExact(60000, wc.currency))), findsOneWidget);
    });

    tw('a device-local switch still updates Settings while shown, and after the tab was hidden', (t) async {
      final wc = habitsWallet(nudges: FakeNudges());
      addTearDown(wc.dispose);
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await tapTab(t, 'Settings');
      await _scrollInto(t, _key('nudgesSwitch'), SettingsScreen);
      bool on() => t.widget<SwitchListTile>(_key('nudgesSwitch')).value;
      expect(on(), isFalse);
      await wc.setNudges(true);
      await t.pump();
      expect(on(), isTrue, reason: 'shown: rebuilt at once');
      await tapTab(t, 'Today');
      await wc.setNudges(false);
      await t.pump();
      await tapTab(t, 'Settings');
      await t.pump();
      await _scrollInto(t, _key('nudgesSwitch'), SettingsScreen);
      expect(on(), isFalse, reason: 'hidden when it changed: rebuilt when shown again');
    });

    tw('switching tabs without a change does not rebuild; a change or a theme change while hidden does, on show', (t) async {
      final wc = _wallet();
      var builds = 0;
      // The same widget instance every time, like the shell's pages: only what changes around it reaches it.
      final page = RebuildWhenShown(
          listenable: wc,
          builder: (context) {
            builds++;
            return Text(Theme.of(context).brightness.name);
          });
      Widget tabs(int shown, {Brightness b = Brightness.light}) => MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(
              body: IndexedStack(index: shown, children: [
            for (final i in [0, 1]) TickerMode(enabled: i == shown, child: i == 1 ? page : const SizedBox()),
          ])));
      Future<void> show(int i, {Brightness b = Brightness.light}) async {
        await t.pumpWidget(tabs(i, b: b));
        await t.pump(const Duration(seconds: 1));
      }

      await show(0);
      final first = builds;
      await show(1);
      await show(0);
      await show(1);
      await show(0);
      expect(builds, first, reason: 'showing and hiding again with no change rebuilt nothing');
      wc.setThemeMode('dark'); // a change while hidden
      await t.pump();
      expect(builds, first, reason: 'hidden: not rebuilt now');
      await show(1);
      expect(builds, first + 1, reason: 'rebuilt when shown');
      await show(0);
      await show(1);
      expect(builds, first + 1, reason: 'no change since: not rebuilt');
      await show(0, b: Brightness.dark); // a theme change while hidden
      expect(builds, first + 1);
      await show(1, b: Brightness.dark);
      expect(builds, first + 2, reason: 'the theme changed while hidden: rebuilt when shown');
      expect(find.text('dark'), findsOneWidget);
      wc.setThemeMode('light');
      await t.pump();
      expect(builds, first + 3, reason: 'shown: rebuilt at once');
    });

    test('billPaidThisPeriod follows the data: a payment in the period makes it true, deleting it or an older one false', () {
      final wc = _wallet();
      final start = wc.period().start;
      NormalizedTransaction pay(String date, String name) => syntheticTx(date, -3000, 'POS plaćanje', 'POS $name ZAGREB');
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [pay(start, 'ZORBLEXM'), pay(addDays(start, -5), 'ZORBLEXO')]));
      wc.reload();
      String key(String s) => wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains(s)).key;
      String add(String label, String payee, String due) =>
          wc.addRecurringBill(label: label, category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: due, payee: key(payee));
      final inPeriod = add('Zorblex now', 'zorblexm', start);
      final old = add('Zorblex old', 'zorblexo', addDays(start, -5));
      RecurringBill bill(String id) => wc.recurringBills().firstWhere((b) => b.id == id);
      expect(bill(inPeriod).lastPaidTx, isNotNull);
      expect(bill(old).lastPaidTx, isNotNull);
      expect(wc.billPaidThisPeriod(bill(inPeriod)), isTrue);
      expect(wc.billPaidThisPeriod(bill(old)), isFalse, reason: 'paid before the period started');
      wc.repo.deleteTransaction(bill(inPeriod).lastPaidTx!);
      wc.reload();
      expect(wc.billPaidThisPeriod(bill(inPeriod)), isFalse, reason: 'the payment is gone: the map was rebuilt for the new data');
    });
  });

  group('links from Today', () {
    tw('the payday link ("Open Budget") opens Budget', (t) async {
      final wc = habitsWallet();
      wc.updateSettings({'salaryConfirmed': false});
      addTearDown(wc.dispose);
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      final open = find.text('Open Budget');
      await _scrollInto(t, open, TodayScreen);
      await t.ensureVisible(open);
      await t.pump();
      await t.tap(open);
      await t.pumpAndSettle();
      expect(find.byType(BudgetScreen), findsOneWidget);
      expect(wc.budgetView, 'plan', reason: 'the link picks the Plan page');
      expect(_key('planHeading'), findsOneWidget);
    });

    tw('a link to a Settings place selects the Settings tab', (t) async {
      final wc = _wallet();
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      wc.openSettings(SettingsSection.income);
      await t.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(_key('expectedIncomePanel'), findsOneWidget);
    });
  });

  group('Settings on one page', () {
    tw('every section is on the one page, no section list', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(400, 900));
      await tapTab(t, 'Settings');
      expect(_key('settingsPage'), findsOneWidget);
      expect(find.byKey(const ValueKey('settingsNav:accounts')), findsNothing);
      // The first widget of each section, in page order, found by scrolling down the one page.
      final marks = <Finder>[
        _key('accountAdd'),
        _key('categoriesPanel'),
        _key('tagsPanel'),
        _key('rulesPanel'),
        _key('budgetsPanel'),
        _key('expectedIncomePanel'),
        _key('planImport'),
        _key('relayAddress'),
        find.text('Back up now'),
        _key('calendarsPanel'),
        find.text('Salary landed: start new month'),
        _key('themeMode'),
        find.text('Clear logs'),
      ];
      var last = -1.0;
      for (final f in marks) {
        await _scrollInto(t, f, SettingsScreen);
        expect(f, findsOneWidget, reason: '$f');
        last = t.getTopLeft(f).dy;
      }
      expect(last, greaterThan(0));
      expect(t.takeException(), isNull);
    });

    tw('a link scrolls the page to its section', (t) async {
      final wc = _wallet();
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      await tapTab(t, 'Settings');
      wc.openSettings(SettingsSection.sync);
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(_key('relayAddress'), findsOneWidget);
      expect(t.getTopLeft(_key('relayAddress')).dy, lessThan(900));
    });

    for (final (name, size, scale) in [('320 dp at text 2.0', const Size(320, 640), 2.0), ('dark 600 dp', const Size(600, 900), 1.0)]) {
      tw('$name: scrolled through without overflow', (t) async {
        await withErrors((errors) async {
          await pumpFull(t, _wallet(bill: true), scale, size: size);
          for (final tab in ['Budget', 'Bills', 'Save', 'Settings']) {
            await tapTab(t, tab);
            await scrollThrough(t);
          }
          errors.check();
        });
      });
    }
  });

  group('Settings in two panes', () {
    const wide = Size(1300, 900); // content = window - rail (220) = 1080 >= 1040

    tw('the section list on the left, the first section on the right', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: wide);
      await tapTab(t, 'Settings');
      expect(_key('settingsList'), findsOneWidget);
      expect(_key('settingsPane'), findsOneWidget);
      for (final s in SettingsSection.listed) {
        expect(_key('settingsNav:${s.name}'), findsOneWidget, reason: s.title);
        expect(find.text(s.title), findsWidgets);
        expect(find.text(s.sub), findsOneWidget);
      }
      expect(_key('accountAdd'), findsOneWidget, reason: 'Accounts is the first section');
      expect(_key('relayAddress'), findsNothing, reason: 'the others are not on the page');
    });

    tw('tapping a section shows it and leaves the others out', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: wide);
      await tapTab(t, 'Settings');
      await t.tap(_key('settingsNav:sync'));
      await t.pumpAndSettle();
      expect(_key('relayAddress'), findsOneWidget);
      expect(_key('accountAdd'), findsNothing);
      await t.tap(_key('settingsNav:look'));
      await t.pumpAndSettle();
      expect(_key('themeMode'), findsOneWidget);
      expect(_key('relayAddress'), findsNothing);
      await t.tap(_key('settingsNav:backup'));
      await t.pumpAndSettle();
      expect(find.text('Back up now'), findsOneWidget);
      expect(find.text('Plain files, not encrypted.'), findsOneWidget, reason: 'Backup and export share a section');
    });

    tw('a deep link selects its section; Currencies is inside Accounts', (t) async {
      final wc = _wallet();
      await pumpFull(t, wc, 1.0, size: wide);
      wc.openSettings(SettingsSection.income);
      await t.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(_key('expectedIncomePanel'), findsOneWidget);
      expect(_key('accountAdd'), findsNothing);
      wc.openSettings(SettingsSection.currencies);
      await t.pumpAndSettle();
      expect(_key('accountAdd'), findsOneWidget);
      expect(_key('expectedIncomePanel'), findsNothing);
    });

    tw('the chosen section is marked with more than colour', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: wide);
      await tapTab(t, 'Settings');
      Finder arrow(String s) => find.descendant(of: _key('settingsNav:$s'), matching: find.byIcon(Icons.chevron_right));
      expect(arrow('accounts'), findsOneWidget);
      expect(arrow('sync'), findsNothing);
      await t.tap(_key('settingsNav:sync'));
      await t.pumpAndSettle();
      expect(arrow('sync'), findsOneWidget);
      expect(arrow('accounts'), findsNothing);
    });

    tw('1039 dp of content is one page, 1040 is two panes', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: wide);
      await tapTab(t, 'Settings');
      final rail = t.getSize(find.byType(NavigationRail)).width;
      for (final (c, panes) in [(1039.0, false), (1040.0, true), (1041.0, true)]) {
        t.view.physicalSize = Size(rail + c, 900);
        await t.pump();
        expect(_key('settingsList').evaluate().isNotEmpty, panes, reason: 'content $c');
      }
    });

    tw('the selected section survives a resize to one page and back', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: wide);
      await tapTab(t, 'Settings');
      await t.tap(_key('settingsNav:sync'));
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(700, 900);
      await t.pump();
      expect(_key('settingsPage'), findsOneWidget);
      t.view.physicalSize = wide;
      await t.pump();
      await t.pumpAndSettle();
      expect(_key('relayAddress'), findsOneWidget);
    });

    tw('text 1.3 at 1280 wide is one page (the rail grows): scrolled through, then Accounts is found again from the top', (t) async {
      await pumpFull(t, demoWallet(clock: pinnedNoon), 1.3, size: const Size(1280, 720));
      await tapTab(t, 'Settings');
      expect(_key('settingsPage'), findsOneWidget);
      await scrollThrough(t);
      await tapTab(t, 'Save');
      await tapTab(t, 'Settings');
      await _scrollInto(t, _key('accountAdd'), SettingsScreen);
      expect(_key('accountAdd'), findsOneWidget);
    });

    tw('1040 dp: every section, scrolled through, without overflow', (t) async {
      await withErrors((errors) async {
        await pumpFull(t, _wallet(bill: true), 1.0, size: wide);
        for (final tab in ['Budget', 'Bills', 'Save', 'Settings']) {
          await tapTab(t, tab);
          await scrollThrough(t);
        }
        for (final s in SettingsSection.listed) {
          await t.tap(_key('settingsNav:${s.name}'));
          await t.pumpAndSettle();
          await scrollThrough(t);
        }
        errors.check();
      });
    });
  });

  group('keys', () {
    tw('Ctrl+1..5 switch the five tabs', (t) async {
      await pumpFull(t, _wallet(), 1.0, size: const Size(1300, 900));
      await t.pump();
      Future<void> ctrl(LogicalKeyboardKey k) async {
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(k);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pump();
      }

      final screens = <(LogicalKeyboardKey, Type)>[
        (LogicalKeyboardKey.digit2, SpendingScreen),
        (LogicalKeyboardKey.digit3, BillsScreen),
        (LogicalKeyboardKey.digit4, SaveScreen),
        (LogicalKeyboardKey.digit5, SettingsScreen),
        (LogicalKeyboardKey.digit1, TodayScreen),
      ];
      for (final (k, type) in screens) {
        await ctrl(k);
        expect(find.byType(type), findsOneWidget, reason: '$type');
      }
      await ctrl(LogicalKeyboardKey.comma);
      expect(find.byType(SettingsScreen), findsOneWidget, reason: 'Ctrl+, opens Settings');
    });
  });
}
