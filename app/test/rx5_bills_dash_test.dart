// Stage RX5: the Bills tab as a Paper Tiles dashboard (Before payday, Per month, Per year, Until payday, To review, Expected bills with
// one state chip each). Fixed clock (20 Oct 2026; the period ends 1 Nov), SYNTHETIC data only. Numbers come from core
// (`beforePayday`, `billsCost`); these tests pin what the tiles show per state, that the anchors still jump, exact cents, and that
// the page fits 320 dp at text 2.0, 360, 411 and 1280 dp, light and dark. Real Plex fonts (the test font is far wider).
import 'dart:io';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bills_tab.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 90));

Future<void> _loadFonts() async {
  for (final (fam, prefix) in [('Inter', 'Inter'), ('IBM Plex Mono', 'IBMPlexMono')]) {
    final l = FontLoader(fam);
    for (final w in ['Regular', 'Medium', 'SemiBold']) {
      l.addFont(File('assets/fonts/$prefix-$w.ttf').readAsBytes().then(ByteData.sublistView));
    }
    await l.load();
  }
}

Finder _key(String k) => find.byKey(ValueKey(k));

WalletController _wallet() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  return wc;
}

Future<void> _pump(WidgetTester t, WalletController wc,
    {Size size = const Size(400, 900), double scale = 1, Brightness mode = Brightness.light, JumpRequest<BillsAnchor>? request}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: BillsScreen(wc: wc, request: request)),
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

  group('tiles per state', () {
    tw('nothing: Before payday says Nothing due, no calendar, no cost tiles, no review', (t) async {
      final wc = _wallet();
      await _pump(t, wc);
      expect(_in('comingUpPanel', find.text(moneyExact(0, wc.currency))), findsOneWidget);
      expect(_in('comingUpPanel', find.text('Nothing due')), findsOneWidget);
      expect(_key('untilPaydayTile'), findsNothing);
      expect(_key('recurringCost'), findsNothing);
      expect(_key('billsReviewPanel'), findsNothing);
      expect(find.textContaining('No repeating bills found yet'), findsOneWidget);
      expect(_key('billsAdd'), findsOneWidget);
    });

    tw('a bill due: core\'s number and count, the calendar, one date chip, the cost tiles', (t) async {
      final wc = _wallet();
      final id =
          wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      final p = wc.period();
      expect(p.beforePayday, 2999);
      expect(p.beforePaydayCount, 1);
      expect(_in('comingUpPanel', find.text(moneyExact(2999, wc.currency))), findsOneWidget);
      expect(_in('comingUpPanel', find.text('1 cost')), findsOneWidget);
      expect(_key('untilPaydayTile'), findsOneWidget);
      // One bill on its day: its amount shows on the day (a single cost, nothing is added up).
      expect(_in('untilPaydayTile', find.text(moneyExact(2999, wc.currency))), findsOneWidget);
      final chip = _in('bill:$id', find.text('25 Oct'));
      expect(chip, findsOneWidget);
      expect(_in('bill:$id', find.text('Overdue')), findsNothing);
      final cost = wc.billsCost()!;
      expect(_in('recurringCost', find.text(moneyExact(cost.monthly, wc.currency))), findsOneWidget);
      expect(find.text(moneyExact(cost.yearly, wc.currency)), findsOneWidget);
      expect(find.text('about'), findsNothing);
    });

    tw('two costs on one day: the calendar shows how many, never a sum', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 4500, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      expect(_in('untilPaydayTile', find.text('2×')), findsOneWidget);
      expect(_in('untilPaydayTile', find.text(moneyExact(7499, wc.currency))), findsNothing);
      expect(_in('comingUpPanel', find.text(moneyExact(wc.period().beforePayday, wc.currency))), findsOneWidget);
      expect(_in('comingUpPanel', find.text('2 costs')), findsOneWidget);
    });

    tw('a planned cost before payday is in Before payday and on the calendar', (t) async {
      final wc = _wallet();
      wc.addPlannedCost(title: 'Synthetic repair', date: '2026-10-28', amount: 12000, category: 'Groceries');
      await _pump(t, wc);
      expect(wc.period().beforePayday, 12000);
      expect(_in('comingUpPanel', find.text(moneyExact(12000, wc.currency))), findsOneWidget);
      expect(_in('untilPaydayTile', find.text(moneyExact(12000, wc.currency))), findsOneWidget);
    });

    tw('an overdue bill: the row says Overdue (icon and word), no date chip', (t) async {
      final wc = _wallet();
      final id = wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      await _pump(t, wc);
      expect(_in('bill:$id', find.text('Overdue')), findsOneWidget);
      expect(_in('bill:$id', find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
      expect(_in('bill:$id', find.text('15 Oct')), findsNothing);
    });

    tw('a long bill held until paid: the Held chip with a lock and its whole amount; core counts it in Before payday', (t) async {
      final wc = _wallet();
      final id = wc.addRecurringBill(
          label: 'Car cover', category: 'Car & transport', amount: 60000, intervalDays: 365, firstDue: addDays(wc.period().end, 40));
      await _pump(t, wc);
      expect(wc.period().beforePayday, 60000);
      expect(_in('bill:$id', find.text('Held')), findsOneWidget);
      expect(_in('bill:$id', find.byIcon(Icons.lock_outline)), findsOneWidget);
      expect(_in('bill:$id', find.text(moneyExact(60000, wc.currency))), findsOneWidget);
      expect(_in('comingUpPanel', find.text(moneyExact(60000, wc.currency))), findsOneWidget);
      expect(_key('untilPaydayTile'), findsOneWidget, reason: 'the tile shows whenever Before payday counts a cost');
      // Upcoming ends at payday: the held bill is listed there apart.
      await t.tap(_key('comingUpPanel'));
      await t.pump(const Duration(milliseconds: 600));
      await t.pump(const Duration(milliseconds: 600));
      // "Set aside" now counts the held bill too (= Before payday), so the Held panel sits lower: scroll to it.
      final held = find.byKey(ValueKey('upcomingHeld:${wc.recurringBills().single.id}'));
      await t.scrollUntilVisible(held, 200, scrollable: find.byType(Scrollable).last);
      expect(held, findsOneWidget);
    });

    tw('a slip to review: an attention tile that lists it', (t) async {
      final wc = _wallet();
      wc.repo
          .importBill(const NormalizedBill(source: BillSource.manual, externalId: 'rx5-slip', payee: 'Synthetic Slip Shop', total: 5000));
      wc.reload();
      await _pump(t, wc);
      expect(_key('billsReviewPanel'), findsOneWidget);
      expect(t.widget<Tile>(_key('billsReviewPanel')).attention, isTrue);
      expect(_in('billsReviewPanel', find.text('TO REVIEW')), findsOneWidget);
      expect(_in('billsReviewPanel', find.text('1 to check')), findsOneWidget);
      expect(_in('billsReviewPanel', find.text('Synthetic Slip Shop')), findsOneWidget);
      expect(find.text('Synthetic Slip Shop'), findsOneWidget, reason: 'listed once');
    });

    tw('an approximate cost: "about" on each tile, one word', (t) async {
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
      expect(find.text('about'), findsNWidgets(2));
    });

    tw('exact cents on the tiles: never rounded, scaled down to fit', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic rent', category: 'Groceries', amount: 123457, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc, size: const Size(320, 900), scale: 2);
      expect(wc.period().beforePayday, 123457);
      expect(_in('comingUpPanel', find.text(moneyExact(123457, wc.currency))), findsOneWidget);
      expect(moneyExact(123457, wc.currency), contains('1,234.57'));
      expect(_in('comingUpPanel', find.byType(FittedBox)), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    tw('a tap on Before payday opens Upcoming', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      await t.tap(_key('comingUpPanel'));
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
      expect(find.text('Upcoming'), findsWidgets);
    });
  });

  group('the calendar holds exactly what Before payday counts', () {
    List<CalDay> marked(BillsCalendar c) => [
          for (final d in c.days)
            if (d.kind == CalKind.bill || d.kind == CalKind.planned) d
        ];

    tw('a Rent bill (covered by the plan) is not counted and not on the calendar', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic rent', category: 'Rent', amount: 55000, intervalDays: 30, firstDue: '2026-10-25');
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-26');
      await _pump(t, wc);
      final p = wc.period();
      expect(p.dueCycles.length, 2);
      expect(p.reservedCycles.length, 1, reason: 'core leaves the covered one out');
      expect(p.beforePaydayCount, 1);
      final cal = billsCalendar(wc);
      expect(marked(cal).length, 1);
      expect(cal.days.firstWhere((d) => d.label == '25').kind, CalKind.none);
      expect(cal.days.firstWhere((d) => d.label == '26').kind, CalKind.bill);
      expect(_in('comingUpPanel', find.text('1 cost')), findsOneWidget);
    });

    tw('an overdue bill next to a due one: both counted, the overdue one on today\'s cell with the warning icon', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic late', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-26');
      await _pump(t, wc);
      final p = wc.period();
      expect(p.beforePaydayCount, 2);
      expect(_in('comingUpPanel', find.text('2 costs')), findsOneWidget);
      final cal = billsCalendar(wc);
      expect(marked(cal).length, 2, reason: 'one mark per counted cost: the overdue one on today, the due one on its day');
      final first = cal.days.first;
      expect((first.today, first.overdue, first.kind), (true, true, CalKind.bill));
      expect(first.amount, moneyExact(3000, wc.currency));
      expect(cal.days.where((d) => d.overdue).length, 1);
      expect(cal.spoken, contains('Synthetic late overdue'));
      expect(_in('untilPaydayTile', find.byIcon(Icons.warning_amber_rounded)), findsNWidgets(2), reason: 'the cell and the legend');
      expect(_in('untilPaydayTile', find.text('Overdue')), findsOneWidget, reason: 'the legend says the word');
    });

    tw('only an overdue bill: the tile still shows (the count says 1 cost)', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic late', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      await _pump(t, wc);
      expect(wc.period().beforePaydayCount, 1);
      expect(_key('untilPaydayTile'), findsOneWidget);
    });

    tw('a weekly bill: one mark per cycle', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic weekly', category: 'Groceries', amount: 2000, intervalDays: 7, firstDue: '2026-10-21');
      await _pump(t, wc);
      final p = wc.period();
      final dues = [for (final c in p.reservedCycles) c.due]..sort();
      expect(dues.length, p.beforePaydayCount);
      for (var k = 1; k < dues.length; k++) {
        expect(addDays(dues[k - 1], 7), dues[k], reason: 'one cycle a week');
      }
      final cal = billsCalendar(wc);
      expect(marked(cal).length, dues.length, reason: 'one mark per cycle (a past cycle sits on today)');
      expect(_in('comingUpPanel', find.text('${dues.length} costs')), findsOneWidget);
    });

    tw('a cycle paid in full in parts is not on the calendar and not counted', (t) async {
      final wc = _wallet();
      wc.repo
          .importBatch(ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-10-15', -10000, 'POS plaćanje', 'POS ZORBLEX ZAGREB')]));
      wc.reload();
      final payee = wc.recentPayees().firstWhere((p) => p.key.toLowerCase().contains('zorblex')).key;
      wc.addRecurringBill(
          label: 'Zorblex plan', category: 'Groceries', amount: 10000, intervalDays: 30, firstDue: '2026-10-25', payee: payee);
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-26');
      await _pump(t, wc);
      final p = wc.period();
      expect(p.dueCycles.length, 2);
      expect(p.reservedCycles.length, 1, reason: 'the paid cycle reserves 0');
      expect(marked(billsCalendar(wc)).map((d) => d.label), ['26']);
      expect(_in('comingUpPanel', find.text('1 cost')), findsOneWidget);
    });
  });

  group('help behind the (i)', () {
    tw('Before payday and Expected bills keep their help behind an info button, not on the page', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
      await _pump(t, wc);
      expect(find.textContaining('come off your daily money'), findsNothing);
      expect(find.textContaining('Found in your imports'), findsNothing);
      await t.tap(_key('beforePaydayInfo'));
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
      expect(find.text('These come off your daily money until they are paid.'), findsOneWidget);
      await t.tap(_key('sheetClose'));
      await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('infoText')), findsNothing);
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

    tw('Today\'s Overdue tile opens Bills at the Expected bills rows (where the Overdue chips are)', (t) async {
      final wc = _wallet();
      wc.snoozeKeyBackup();
      wc.addRecurringBill(label: 'Synthetic late', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      t.view.physicalSize = const Size(400, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(BudgetWalletApp(wc: wc));
      await t.pump();
      await t.ensureVisible(_key('billsLine'));
      await t.tap(_key('billsLine'));
      for (var i = 0; i < 14; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(BillsScreen), findsOneWidget);
      expect(_in('billsPage', find.text('EXPECTED BILLS')), findsOneWidget);
      expect(t.getTopLeft(find.text('EXPECTED BILLS')).dy, lessThan(350), reason: 'scrolled to Expected bills, not to the top');
    });
  });

  group('calendar cells', () {
    Future<void> strip(WidgetTester t, List<CalDay> days, {Size size = const Size(320, 700), double scale = 2}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(28), child: CalendarStrip(days: days, startWeekday: 1))),
      ));
      await t.pump();
    }

    double ratio(WidgetTester t, String label) {
      final text = find.text(label);
      final box = find.ancestor(of: text, matching: find.byType(FittedBox)).first;
      return t.getSize(box).width / t.getSize(text).width;
    }

    testWidgets('320 dp at 2.0: a long amount is left out and the day number keeps the size it has without one', (t) async {
      await withErrors((errors) async {
        await strip(t, const [CalDay('25', kind: CalKind.bill, amount: '1,234.57 €'), CalDay('26', kind: CalKind.bill)]);
        expect(find.text('1,234.57 €'), findsNothing, reason: 'it would shrink below 80 %: left out');
        expect(ratio(t, '25'), closeTo(ratio(t, '26'), 0.001));
        expect(t.takeException(), isNull);
        errors.check();
      });
    });

    testWidgets('400 dp at 1.0: a short amount shows at its own size beside an unchanged day number', (t) async {
      await strip(t, const [CalDay('25', kind: CalKind.bill, amount: '30 €'), CalDay('26', kind: CalKind.bill)],
          size: const Size(400, 700), scale: 1);
      expect(find.text('30 €'), findsOneWidget);
      expect(ratio(t, '25'), closeTo(ratio(t, '26'), 0.001));
      expect(ratio(t, '30 €'), greaterThanOrEqualTo(0.8));
    });
  });

  group('anchors', () {
    for (final a in BillsAnchor.values) {
      tw('a jump to ${a.name} scrolls there', (t) async {
        final wc = _wallet();
        wc.addRecurringBill(label: 'Synthetic phone', category: 'Groceries', amount: 2999, intervalDays: 30, firstDue: '2026-10-25');
        wc.repo
            .importBill(const NormalizedBill(source: BillSource.manual, externalId: 'rx5-slip', payee: 'Synthetic Slip Shop', total: 5000));
        wc.reload();
        final request = JumpRequest<BillsAnchor>();
        addTearDown(request.dispose);
        await _pump(t, wc, size: const Size(400, 500), request: request);
        request.request(a);
        for (var i = 0; i < 12; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        final target = switch (a) {
          BillsAnchor.comingUp => _key('comingUpPanel'),
          BillsAnchor.review => _key('billsReviewPanel'),
          BillsAnchor.expected => find.text('EXPECTED BILLS'),
          BillsAnchor.slips => find.text('Import bill file').first,
        };
        expect(target, findsWidgets);
        final y = t.getTopLeft(target.first).dy;
        expect(y, inInclusiveRange(0, 500), reason: '${a.name} is on screen');
        expect(t.takeException(), isNull);
      });
    }
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
