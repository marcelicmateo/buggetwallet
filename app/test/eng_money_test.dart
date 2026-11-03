// ENG E7a: the Money timeline (spec §3/§5.6). Fixed clock (20 Oct 2026; the period ends 1 Nov), SYNTHETIC data only. Pins the order
// (coming up / Today line / past by day, newest first), the filters and account chips, what a row opens, the held figure and bill costs
// (core's numbers), the anchors, search, the lazy list and the layout at 320 dp x 2.0 in both themes.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/screens/money.dart';
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fonts.dart';
import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));
Finder _keyStarts(String p) => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(p));

WalletController _wallet() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  return wc;
}

/// Three payments on two days and one income; a cash row too.
void _rows(WalletController wc) {
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-18', -1850, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    syntheticTx('2026-10-18', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-12', -1200, 'POS plaćanje', 'POS SYNTHSHOP ZAGREB'),
    syntheticTx('2026-10-10', 120000, 'Plaća/Mirovina', 'Neto placa synthetic'),
  ]));
  wc.reload();
}

Future<void> _pump(WidgetTester t, WalletController wc,
    {Size size = const Size(400, 1400),
    double scale = 1,
    Brightness mode = Brightness.light,
    JumpRequest<BillsAnchor>? request,
    Listenable? search}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: MoneyScreen(wc: wc, request: request, searchRequest: search)),
  ));
  await t.pump();
}

/// The tests end with the controller's 3 s sync debounce run out (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: const Timeout(Duration(seconds: 90)));

void main() {
  setUpAll(loadAppFonts);

  group('the timeline', () {
    tw('nothing yet: Nothing due, the Today line, an empty note; no cost strip', (t) async {
      final wc = _wallet();
      await _pump(t, wc);
      expect(find.text('Nothing due'), findsOneWidget);
      expect(_key('moneyToday'), findsOneWidget);
      expect(find.textContaining('No payments yet'), findsOneWidget);
      expect(_key('recurringCost'), findsNothing);
      expect(_key('moneyAccounts'), findsNothing);
      for (final f in MoneyFilter.values) {
        expect(_key('moneyFilter:${f.name}'), findsOneWidget);
      }
    });

    tw('coming up above the Today line (soonest first), payments below it by day, newest first', (t) async {
      final wc = _wallet();
      _rows(wc);
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-27');
      wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-24', amount: 12000, category: 'Groceries');
      await _pump(t, wc);
      double y(Finder f) => t.getTopLeft(f.first).dy;
      final repair = find.text('Synthetic repair'), phone = find.text('Synthetic phone');
      final today = _key('moneyToday');
      final d18 = _key('moneyDay:2026-10-18'), d12 = _key('moneyDay:2026-10-12'), d10 = _key('moneyDay:2026-10-10');
      expect(repair, findsOneWidget);
      expect(phone, findsOneWidget);
      expect(y(repair), lessThan(y(phone)), reason: '24 Oct before 27 Oct');
      expect(y(phone), lessThan(y(today)));
      expect(y(today), lessThan(y(d18)));
      expect(y(d18), lessThan(y(d12)));
      expect(y(d12), lessThan(y(d10)));
      // The signed amounts: a cost is negative, to the cent; the head holds core's Before payday.
      expect(find.text(moneyExactSigned(-12000, wc.currency)), findsOneWidget);
      expect(find.text(moneyExactSigned(-2999, wc.currency)), findsOneWidget);
      expect(find.text('${moneyExact(wc.period().beforePayday, wc.currency)} held'), findsOneWidget);
      expect(wc.period().beforePayday, 14999);
      // Rows of one day sit under one heading.
      expect(_keyStarts('moneyTx:'), findsNWidgets(4));
      expect(find.text('Wed 18 Oct').evaluate().length + find.textContaining('18 Oct').evaluate().length, greaterThan(0));
    });

    tw('an overdue bill is a coming-up row that says Overdue', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      await _pump(t, wc);
      // The period runs to 15 Nov: the next cycle (14 Nov) is a row too, not late.
      expect(find.text('Synthetic gym'), findsNWidgets(2));
      expect(_keyStarts('upLate:'), findsOneWidget);
      expect(find.descendant(of: _keyStarts('upLate:'), matching: find.textContaining('Overdue', findRichText: true)), findsOneWidget);
    });

    tw('a yearly bill held until paid is in the held figure, as core counts it', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(
          label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: addDays(wc.period().end, 40));
      await _pump(t, wc);
      expect(wc.period().beforePayday, 60000);
      expect(find.text('${moneyExact(60000, wc.currency)} held'), findsOneWidget);
    });

    tw('the coming-up head opens Upcoming; the long bill held until paid is listed there apart', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(
          label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: addDays(wc.period().end, 40));
      await _pump(t, wc);
      await t.tap(_key('comingUpPanel'));
      await t.pump(const Duration(milliseconds: 600));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('Upcoming'), findsWidgets);
      final held = find.byKey(ValueKey('upcomingHeld:${wc.recurringBills().single.id}'));
      await t.scrollUntilVisible(held, 200, scrollable: find.byType(Scrollable).last);
      expect(held, findsOneWidget);
    });

    tw('a payment dated after today sits above the Today line with the coming-up rows and opens its sheet', (t) async {
      final wc = _wallet();
      _rows(wc);
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-25', -3300, 'POS plaćanje', 'POS FUTURESHOP ZAGREB')]));
      wc.reload();
      await _pump(t, wc);
      final row = find.byKey(ValueKey('up:tx:${wc.wholeTxs.firstWhere((x) => x.date == '2026-10-25').tx.id}'));
      expect(row, findsOneWidget);
      expect(t.getTopLeft(row).dy, lessThan(t.getTopLeft(_key('moneyToday')).dy));
      expect(_keyStarts('moneyTx:'), findsNWidgets(4), reason: 'the future row is not among the past ones');
      await t.tap(row);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(TxSheet), findsOneWidget);
    });

    tw('a filter or account with nothing in it says so', (t) async {
      final wc = _wallet();
      _rows(wc);
      await _pump(t, wc);
      await t.tap(_key('moneyFilter:planned'));
      await t.pump();
      expect(find.text('Nothing matches this filter.'), findsOneWidget);
      await t.tap(_key('moneyFilter:all'));
      await t.pump();
      expect(find.text('Nothing matches this filter.'), findsNothing);
      final empty = _wallet();
      await _pump(t, empty);
      expect(find.textContaining('No payments yet'), findsOneWidget);
    });

    tw('a big amount in the head (1,234,567.89 held, a big balance) does not overflow at 320 dp x 2.0', (t) async {
      final wc = _wallet();
      await wc.addAccount(name: 'Current', source: 'pbz', currency: 'EUR', opening: 123456789, openingDate: '2026-01-01');
      wc.addPlannedCost(title: 'Synthetic yacht', date: '2026-10-28', amount: 123456789, category: 'Groceries');
      await withErrors((errors) async {
        await _pump(t, wc, size: const Size(320, 700), scale: 2);
        expect(wc.period().beforePayday, 123456789);
        expect(find.text('${moneyExact(123456789, wc.currency)} held'), findsOneWidget);
        expect(find.text(moneyExact(123456789, 'EUR')), findsOneWidget, reason: 'the balance');
        expect(t.takeException(), isNull);
        errors.check();
      });
    });

    tw('a covered bill (Rent) is a row but not in the held figure', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic rent', category: 'Rent', amount: 55000, intervalDays: 30, firstDue: '2026-10-25');
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-26');
      await _pump(t, wc);
      expect(find.text('Synthetic rent'), findsOneWidget);
      expect(find.text('Synthetic phone'), findsOneWidget);
      expect(wc.period().beforePayday, 2999);
      expect(find.text('${moneyExact(2999, wc.currency)} held'), findsOneWidget);
    });

    tw('a weekly bill: one row per cycle', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic weekly', category: 'Groceries', amount: 2000, intervalDays: 7, firstDue: '2026-10-21');
      await _pump(t, wc);
      final dues = wc.upcomingItems(wc.period().start, addDays(wc.period().end, -1)).where((i) => i.kind == UpcomingKind.bill).length;
      expect(dues, greaterThan(1));
      expect(find.text('Synthetic weekly'), findsNWidgets(dues));
    });

    tw('the bill costs are one strip: Per month and Per year, "about" when approximate, exact cents', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic rent', category: 'Groceries', amount: 123457, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc, size: const Size(320, 1200), scale: 2);
      final cost = wc.billsCost()!;
      expect(_key('recurringCost'), findsOneWidget);
      expect(find.text(moneyExact(cost.monthly, wc.currency)), findsOneWidget);
      expect(find.text(moneyExact(cost.yearly, wc.currency)), findsOneWidget);
      expect(find.textContaining('about'), findsNothing);
      expect(t.takeException(), isNull);
    });

    tw('an approximate cost says "about" on both', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(
          label: 'Synthetic power',
          category: 'Groceries',
          amount: 12000,
          minAmount: 8000,
          maxAmount: 12000,
          intervalDays: 30,
          firstDue: '2026-10-25');
      await _pump(t, wc);
      expect(wc.billsCost()!.approximate, isTrue);
      expect(find.textContaining('about '), findsNWidgets(2));
    });

    tw('the cost strip and the Bills & slips chip open the bills page', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      await t.tap(_key('recurringCost'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(BillsScreen), findsOneWidget);
      expect(_key('billsAdd'), findsOneWidget);
      expect(find.text('EXPECTED BILLS'), findsOneWidget);
      t.state<NavigatorState>(find.byType(Navigator).first).pop();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(_key('billsOpen'));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(BillsScreen), findsOneWidget);
    });
  });

  group('filters and accounts', () {
    Future<WalletController> mixed(WidgetTester t) async {
      final wc = _wallet();
      _rows(wc);
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-27');
      wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-24', amount: 12000, category: 'Groceries');
      wc.addRecurringBill(
          label: 'Synthetic side job',
          category: 'Extra income',
          amount: 8000,
          intervalDays: 30,
          firstDue: '2026-10-29',
          direction: RecurringBill.directionIn,
          payee: 'Synthetic payer');
      await _pump(t, wc);
      return wc;
    }

    tw('Out keeps costs and negative payments; In keeps incomes and positive payments', (t) async {
      await mixed(t);
      await t.tap(_key('moneyFilter:out'));
      await t.pump();
      expect(find.text('Synthetic repair'), findsOneWidget);
      expect(find.text('Synthetic phone'), findsOneWidget);
      expect(find.text('Synthetic side job'), findsNothing);
      expect(_keyStarts('moneyTx:'), findsNWidgets(3));
      await t.tap(_key('moneyFilter:income'));
      await t.pump();
      expect(find.text('Synthetic repair'), findsNothing);
      expect(find.text('Synthetic side job'), findsOneWidget);
      expect(_keyStarts('moneyTx:'), findsOneWidget);
    });

    tw('Bills keeps bill rows; Planned keeps planned costs and no past payments', (t) async {
      await mixed(t);
      await t.tap(_key('moneyFilter:bills'));
      await t.pump();
      expect(find.text('Synthetic phone'), findsOneWidget);
      expect(find.text('Synthetic repair'), findsNothing);
      expect(_keyStarts('moneyTx:'), findsNothing, reason: 'no payment is linked to a bill');
      await t.tap(_key('moneyFilter:planned'));
      await t.pump();
      expect(find.text('Synthetic repair'), findsOneWidget);
      expect(find.text('Synthetic phone'), findsNothing);
      expect(_keyStarts('moneyTx:'), findsNothing);
      await t.tap(_key('moneyFilter:all'));
      await t.pump();
      expect(_keyStarts('moneyTx:'), findsNWidgets(4));
    });

    tw('an account card filters the payments by account and hides costs that have no account', (t) async {
      final wc = _wallet();
      _rows(wc);
      final bank = await wc.addAccount(name: 'Current', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-01-01');
      final cash = await wc.addAccount(name: 'Cash', currency: 'EUR', opening: 5000, openingDate: '2026-01-01');
      wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-24', amount: 12000, category: 'Groceries');
      await _pump(t, wc);
      expect(_key('moneyAccount:$bank'), findsOneWidget);
      expect(find.text(moneyExact(5000, wc.currency)), findsOneWidget, reason: 'the cash balance, to the cent');
      await t.tap(_key('moneyAccount:$bank'));
      await t.pump();
      expect(_keyStarts('moneyTx:'), findsNWidgets(4));
      expect(find.text('Synthetic repair'), findsNothing);
      await t.tap(_key('moneyAccount:$cash'));
      await t.pump();
      expect(_keyStarts('moneyTx:'), findsNothing);
      await t.tap(_key('moneyAccount:$cash'));
      await t.pump();
      expect(_keyStarts('moneyTx:'), findsNWidgets(4));
      expect(find.text('Synthetic repair'), findsOneWidget);
    });
  });

  group('rows open their sheets', () {
    tw('a payment opens its sheet', (t) async {
      final wc = _wallet();
      _rows(wc);
      await _pump(t, wc);
      await t.tap(_keyStarts('moneyTx:').first);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(TxSheet), findsOneWidget);
    });

    tw('a planned cost opens its entry sheet; a bill row opens the repeating bill form', (t) async {
      final wc = _wallet();
      wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-24', amount: 12000, category: 'Groceries');
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-27');
      await _pump(t, wc);
      await t.tap(find.text('Synthetic repair'));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('entryPaid')), findsOneWidget);
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 600));
      await t.tap(find.text('Synthetic phone'));
      await t.pump(const Duration(milliseconds: 600));
      expect(_key('recurringSheet'), findsOneWidget);
    });
  });

  group('anchors', () {
    for (final a in [BillsAnchor.expected, BillsAnchor.slips]) {
      tw('${a.name} opens Bills & slips there', (t) async {
        final wc = _wallet();
        final request = JumpRequest<BillsAnchor>();
        addTearDown(request.dispose);
        await _pump(t, wc, request: request, size: const Size(400, 500));
        request.request(a);
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 300));
        }
        expect(find.byType(BillsScreen), findsOneWidget);
        expect(t.widget<BillsScreen>(find.byType(BillsScreen)).anchor, a);
      });
    }

    tw('a request made before the page existed still lands', (t) async {
      final wc = _wallet();
      final request = JumpRequest<BillsAnchor>()..request(BillsAnchor.expected);
      addTearDown(request.dispose);
      await _pump(t, wc, request: request);
      await t.pump(const Duration(milliseconds: 600));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(BillsScreen), findsOneWidget);
    });
  });

  group('search', () {
    tw('the shell search (app bar, rail, Ctrl+F: the request) opens the search pane inside Money, which has no search icon of its own',
        (t) async {
      final wc = _wallet();
      _rows(wc);
      final press = ValueNotifier<int>(0);
      addTearDown(press.dispose);
      await _pump(t, wc, search: press);
      expect(find.byType(SearchPane), findsNothing);
      expect(_key('moneySearch'), findsNothing, reason: 'one search per screen');
      press.value++;
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(SearchPane), findsOneWidget);
      await t.tap(find.byTooltip('Close search').first);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(SearchPane), findsNothing);
      press.value++;
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(SearchPane), findsOneWidget);
    });
  });

  group('lazy list', () {
    tw('a thousand payments build only the rows that are on screen', (t) async {
      final wc = _wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (var i = 0; i < 1000; i++)
          syntheticTx(addDays('2026-10-19', -(i % 300)), -(100 + i), 'POS plaćanje', 'POS SYNTHSHOP $i ZAGREB'),
      ]));
      wc.reload();
      await _pump(t, wc, size: const Size(400, 800));
      final built = _keyStarts('moneyTx:').evaluate().length;
      expect(built, inInclusiveRange(1, 40));
    });
  });

  group('layout', () {
    const sizes = {
      '320 dp x 2.0': (Size(320, 640), 2.0),
      '360 dp x 1.0': (Size(360, 800), 1.0),
      '1280 dp x 1.0': (Size(1280, 800), 1.0),
    };
    for (final mode in Brightness.values) {
      for (final e in sizes.entries) {
        tw('every kind of row at ${e.key}, ${mode.name}: no overflow', (t) async {
          final wc = _wallet();
          _rows(wc);
          await wc.addAccount(
              name: 'Current account with a long synthetic name',
              source: 'pbz',
              currency: 'EUR',
              opening: 123457,
              openingDate: '2026-01-01');
          wc.addRecurringBill(
              label: 'Synthetic late bill with a long name',
              category: 'Groceries',
              amount: 123457,
              intervalDays: 30,
              firstDue: '2026-10-15');
          wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-27');
          wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-24', amount: 12000, category: 'Groceries');
          wc.addRecurringBill(
              label: 'Synthetic side job',
              category: 'Extra income',
              amount: 8000,
              intervalDays: 30,
              firstDue: '2026-10-29',
              direction: RecurringBill.directionIn,
              payee: 'Synthetic payer');
          await withErrors((errors) async {
            await _pump(t, wc, size: e.value.$1, scale: e.value.$2, mode: mode);
            await t.pump(const Duration(milliseconds: 300));
            expect(t.takeException(), isNull);
            errors.check();
          });
        });
      }
    }
  });
}
