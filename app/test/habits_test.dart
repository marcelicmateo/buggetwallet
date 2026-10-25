// M4 Habits in the app: the weekly review (Today card, ReviewScreen), recurring bills and nudges in Plan, and the controller
// behind them. All data is SYNTHETIC (habitsWallet: Tuesday 20 Oct 2026).
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

/// The synthetic habits wallet, closed when the test ends (a pending sync timer would fail it).
WalletController hw({FakeNudges? nudges, bool confirmBill = false}) {
  final wc = habitsWallet(nudges: nudges, confirmBill: confirmBill);
  addTearDown(wc.dispose);
  return wc;
}

WalletController bw({bool budgets = true}) {
  final wc = budgetWallet(budgets: budgets);
  addTearDown(wc.dispose);
  return wc;
}

/// A widget test that lets the controller's 3 s sync debounce run out before it ends (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

String eur(String s) => s.replaceAll(' €', ' €');

Widget today(WalletController wc, {VoidCallback? openBills, VoidCallback? openSpending}) => Scaffold(
    body: TodayScreen(
        wc: wc, openPlan: () {}, openBills: openBills, openSpending: openSpending, clock: () => budgetToday, chooser: const FileChooser()));

void main() {
  group('controller', () {
    test('reviewState is cached per data version and day, due until the review is done', () {
      final wc = hw();
      final r = wc.reviewState();
      expect(identical(wc.reviewState(), r), isTrue);
      expect(r.due, isTrue);
      expect(r.count('categories'), 3, reason: 'three bank card rows in the last 7 days, no learned category');
      expect(r.count('pace'), 2, reason: 'Eating out over, Groceries behind pace');
      expect(r.count('wishlist'), 1);
      wc.markReviewDone();
      final after = wc.reviewState();
      expect(identical(after, r), isFalse);
      expect(after.due, isFalse);
      expect(after.streak, 1);
      expect(wc.lastReview, '2026-10-20');
    });

    test('confirming the guessed category of a row takes it off the review list', () {
      final wc = hw();
      final rows = wc.reviewRows();
      expect(rows.length, 3);
      wc.confirmCategory(rows.first.tx);
      expect(wc.reviewRows().length, 2);
      expect(wc.reviewState().count('categories'), 2);
    });

    test('the review rows are exactly the rows core counts for the categories step', () {
      final wc = hw();
      expect(wc.reviewRows().length, wc.reviewState().count('categories'));
      wc.confirmCategory(wc.reviewRows().first.tx);
      expect(wc.reviewRows().length, wc.reviewState().count('categories'));
    });

    test('confirming a row keeps its category and teaches the merchant', () {
      final wc = hw();
      final t = wc.reviewRows().firstWhere((t) => t.tx.description.contains('LIDL'));
      final cat = t.category;
      wc.confirmCategory(t.tx);
      expect(wc.txs.firstWhere((x) => x.tx.id == t.tx.id).tx.category, cat);
      expect(wc.categorizer.merchantRules.values, contains(cat));
    });

    test('review day: Sunday by default, changing it is kept and clamped to 1..7', () {
      final wc = hw();
      expect(wc.reviewDay, 7);
      wc.setReviewDay(3);
      expect(wc.reviewDay, 3);
      wc.setReviewDay(0);
      wc.setReviewDay(8);
      expect(wc.reviewDay, 3);
    });

    test('recurring: the gym is a candidate; confirm sets money aside until payday, dismiss hides, delete removes', () {
      final wc = hw();
      expect(wc.recurringBills().map((b) => b.status), ['candidate']);
      expect(wc.period().dueBills, isEmpty, reason: 'a candidate reserves nothing');
      final id = wc.recurringBills().single.id;
      wc.confirmRecurring(id);
      expect(wc.recurringBills().single.confirmed, isTrue);
      expect(wc.period().dueBills.length, 1);
      expect(wc.period().reservedBills, 2999);
      wc.deleteRecurring(id);
      expect(wc.recurringBills(), isEmpty);
      final other = hw();
      other.dismissRecurring(other.recurringBills().single.id);
      expect(other.recurringBills(), isEmpty);
    });

    test('nudges: on asks for permission and schedules, off cancels, a refusal leaves it off', () async {
      final fake = FakeNudges();
      final wc = hw(nudges: fake);
      expect(wc.nudgesEnabled, isFalse);
      await wc.rescheduleNudges();
      expect(fake.scheduled, isEmpty, reason: 'off: nothing is scheduled');
      expect(await wc.setNudges(true), isTrue);
      expect((fake.asked, fake.scheduled.length), (1, 1));
      expect(wc.nudgesEnabled, isTrue);
      await wc.rescheduleNudges();
      expect(fake.scheduled.length, 2);
      expect(await wc.setNudges(false), isFalse);
      expect((wc.nudgesEnabled, fake.cancelled), (false, 1));

      final no = FakeNudges(allow: false);
      final wc2 = hw(nudges: no);
      expect(await wc2.setNudges(true), isFalse);
      expect((wc2.nudgesEnabled, wc2.nudgesDenied), (false, true));
      expect(no.scheduled, isEmpty);
    });

    test('nudges are device-local: the setting is not a synced setting', () async {
      final wc = hw(nudges: FakeNudges());
      await wc.setNudges(true);
      expect(wc.repo.localValue('nudgesEnabled'), '1');
      expect(wc.settings.toMap().containsKey('nudgesEnabled'), isFalse);
    });
  });

  group('Today', () {
    tw('due: the review card lists the steps with work and Start review opens the review', (tester) async {
      final wc = hw();
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('reviewCard')), findsOneWidget);
      expect(find.text('3 categories to confirm · 2 behind pace · 1 wishlist decision'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('startReview')));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewScreen), findsOneWidget);
    });

    tw('not due: no card; reviewed today shows the streak line', (tester) async {
      final wc = hw();
      wc.markReviewDone();
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('reviewCard')), findsNothing);
      expect(find.textContaining('Reviewed · 1 week in a row'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsWidgets);
    });

    tw('a review that is not done yet shows no "Reviewed" line', (tester) async {
      await pumpApp(tester, today(hw()), size: const Size(400, 3000));
      expect(find.textContaining('Reviewed'), findsNothing);
    });

    tw('nothing to fix: the card says so', (tester) async {
      final wc = bw(budgets: false);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.byKey(const ValueKey('reviewCard')), findsOneWidget);
      expect(find.textContaining('Nothing to fix'), findsOneWidget);
    });

    tw('Due by payday: confirmed bills only, count and exact sum; a tap calls openBills; hidden at zero', (tester) async {
      var taps = 0;
      final wc = hw();
      await pumpApp(tester, today(wc, openBills: () => taps++), size: const Size(400, 3000));
      expect(find.textContaining('Due by payday'), findsNothing, reason: 'only a candidate so far');
      wc.confirmRecurring(wc.recurringBills().single.id);
      await pumpApp(tester, today(wc, openBills: () => taps++), size: const Size(400, 3000));
      expect(find.text(eur('Due by payday: 1 bill, 29.99 €')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('billsLine')));
      expect(taps, 1);
    });
  });

  group('bills the plan covers, and overdue ones', () {
    // Netflix is a subscription: a fixed category, already in the plan. The late gym is unpaid since the 9th of September.
    WalletController wallet() {
      final wc = hw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-07-27', '2026-08-27', '2026-09-27']) syntheticTx(d, -1299, 'POS plaćanje', 'POS NETFLIX.COM'),
        for (final d in const ['2026-06-10', '2026-07-10', '2026-08-10']) syntheticTx(d, -4500, 'POS plaćanje', 'POS SYNTHPOOL ZAGREB'),
      ]));
      wc.reload();
      wc.refreshRecurring();
      for (final b in wc.recurringBills()) {
        wc.confirmRecurring(b.id);
      }
      return wc;
    }

    test('core lists all three as due, reserves only the two that the plan does not count', () {
      final p = wallet().period();
      expect(p.dueBills.length, 3);
      expect(p.dueBills.where((b) => b.coveredByPlan).length, 1);
      expect(p.reservedBills, 2999 + 4500);
    });

    tw('Today: the sum leaves out the covered bill, which is named apart; the late one is marked overdue', (tester) async {
      await pumpApp(tester, today(wallet()), size: const Size(400, 3000));
      expect(find.text(eur('Due by payday: 2 bills, 74.99 € · 1 covered by your plan')), findsOneWidget);
      expect(find.byKey(const ValueKey('billsOverdue')), findsOneWidget);
      expect(find.textContaining('1 overdue'), findsOneWidget);
    });

    tw('Plan: covered and overdue are written on the bill rows', (tester) async {
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wallet())), size: const Size(400, 4000));
      expect(find.text('Covered by your plan'), findsOneWidget);
      expect(find.textContaining('Overdue'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsWidgets);
    });

    tw('only covered bills: no amount in the Today line', (tester) async {
      final wc = hw();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in const ['2026-07-27', '2026-08-27', '2026-09-27']) syntheticTx(d, -1299, 'POS plaćanje', 'POS NETFLIX.COM'),
      ]));
      wc.reload();
      wc.refreshRecurring();
      wc.confirmRecurring(wc.recurringBills().firstWhere((b) => b.coveredByPlan).id);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.text('Due by payday: 1 covered by your plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('billsOverdue')), findsNothing);
    });
  });

  group('ReviewScreen', () {
    Future<void> open(WidgetTester tester, WalletController wc, {Size size = const Size(400, 3000), double scale = 1}) =>
        pumpApp(tester, ReviewScreen(wc: wc), size: size, textScale: scale);

    tw('four steps with their counts; only finished ones are ticked', (tester) async {
      final wc = hw();
      await open(tester, wc);
      for (final t in ['Import', 'Confirm categories', 'Pace', 'Wishlist']) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.descendant(of: find.byKey(const ValueKey('step:categories')), matching: find.text('3')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('step:pace')), matching: find.text('2')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('step:wishlist')), matching: find.text('1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tick:open')), findsNWidgets(4));
      expect(find.byKey(const ValueKey('tick:done')), findsNothing);
      expect(find.text('Synthetic lamp'), findsOneWidget);
      expect(_keyed('looksRight:'), findsNWidgets(3));
      expect(find.text('Eating out'), findsWidgets);
    });

    tw('Looks right removes a row, the count drops and the step ticks when none are left', (tester) async {
      final wc = hw();
      await open(tester, wc);
      for (var left = 3; left > 0; left--) {
        expect(_keyed('looksRight:'), findsNWidgets(left));
        await tester.tap(_keyed('looksRight:').first);
        await tester.pump();
      }
      expect(_keyed('looksRight:'), findsNothing);
      expect(wc.reviewState().count('categories'), 0);
      expect(find.descendant(of: find.byKey(const ValueKey('step:categories')), matching: find.byKey(const ValueKey('tick:done'))),
          findsOneWidget);
      expect(find.textContaining('confirmed'), findsOneWidget);
    });

    tw('wishlist: Skip decides the wish and the step ticks', (tester) async {
      final wc = hw();
      await open(tester, wc);
      await tester.tap(find.byKey(const ValueKey('skipWish:wish-ready')));
      await tester.pump();
      expect(wc.wish.firstWhere((w) => w.id == 'wish-ready').status, 'skipped');
      expect(find.text('Synthetic lamp'), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('step:wishlist')), matching: find.byKey(const ValueKey('tick:done'))),
          findsOneWidget);
    });

    tw('pace: rows name the over and the behind categories; Got it ticks the step', (tester) async {
      final wc = hw();
      await open(tester, wc);
      expect(find.text('over budget'), findsOneWidget);
      expect(find.text('behind pace'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('paceGotIt')));
      await tester.pump();
      expect(
          find.descendant(of: find.byKey(const ValueKey('step:pace')), matching: find.byKey(const ValueKey('tick:done'))), findsOneWidget);
    });

    tw('Done writes the review, pops and the streak grows', (tester) async {
      final wc = hw();
      await pumpApp(
          tester, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => openReview(c, wc), child: const Text('go')))),
          size: const Size(400, 3000));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewScreen), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('reviewDone')));
      await tester.tap(find.byKey(const ValueKey('reviewDone')));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewScreen), findsNothing);
      expect(wc.reviewState().due, isFalse);
      expect(wc.reviewState().streak, 1);
      expect(find.text('Review done · 1 week in a row'), findsOneWidget);
    });

    tw('a pace row closes the review and asks for Spending', (tester) async {
      final wc = hw();
      var spending = 0;
      await pumpApp(
          tester,
          Builder(
              builder: (c) =>
                  Scaffold(body: TextButton(onPressed: () => openReview(c, wc, openSpending: () => spending++), child: const Text('go')))),
          size: const Size(400, 3000));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('over budget'));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewScreen), findsNothing);
      expect(spending, 1);
    });

    tw('a failing file chooser shows the standard message', (tester) async {
      final wc = hw();
      await pumpApp(tester, ReviewScreen(wc: wc, chooser: _FailingChooser()), size: const Size(400, 3000));
      await tester.tap(find.byKey(const ValueKey('reviewImport')));
      await tester.pump();
      expect(find.text(chooserFailedMessage), findsOneWidget);
      expect(find.byKey(const ValueKey('tick:done')), findsNothing);
    });

    tw('wide window: the review opens as a dialog', (tester) async {
      final wc = hw();
      await pumpApp(
          tester, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => openReview(c, wc), child: const Text('go')))),
          size: const Size(1280, 900));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(Dialog), matching: find.byType(ReviewScreen)), findsOneWidget);
      expect(tester.getSize(find.byType(ReviewScreen)).width, 560);
    });
  });

  group('Plan', () {
    Future<void> plan(WidgetTester tester, WalletController wc, {Size size = const Size(400, 6000), double scale = 1}) =>
        pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: size, textScale: scale);

    tw('review day chips: Sunday selected, a tap changes the day', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      expect(find.text('WEEKLY REVIEW'), findsOneWidget);
      for (final d in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) {
        expect(find.widgetWithText(ChoiceChip, d), findsOneWidget);
      }
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('reviewDay:7'))).selected, isTrue);
      await tester.ensureVisible(find.byKey(const ValueKey('reviewDay:5')));
      await tester.tap(find.byKey(const ValueKey('reviewDay:5')));
      await tester.pump();
      expect(wc.reviewDay, 5);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('reviewDay:5'))).selected, isTrue);
      expect(find.textContaining('from Friday'), findsOneWidget);
    });

    tw('expected bills: Confirm moves the candidate to Confirmed with its amount', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      expect(find.text('Looks like a monthly bill'), findsOneWidget);
      expect(find.text(eur('29.99 €')), findsOneWidget);
      await tester.ensureVisible(_keyed('confirm:'));
      await tester.tap(_keyed('confirm:'));
      await tester.pump();
      expect(find.text('Looks like a monthly bill'), findsNothing);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.byTooltip('Remove bill'), findsOneWidget);
      expect(wc.period().reservedBills, 2999);
    });

    tw('expected bills: Not a bill hides it; Remove deletes a confirmed one', (tester) async {
      final wc = hw();
      await plan(tester, wc);
      await tester.ensureVisible(_keyed('dismiss:'));
      await tester.tap(_keyed('dismiss:'));
      await tester.pump();
      expect(find.text('Looks like a monthly bill'), findsNothing);
      // The page is long: scroll the (lazy) list to the note before looking for it.
      await tester.scrollUntilVisible(find.textContaining('No repeating bills found yet'), -300, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('No repeating bills found yet'), findsOneWidget);

      final wc2 = hw(confirmBill: true);
      await plan(tester, wc2);
      await tester.ensureVisible(find.byTooltip('Remove bill'));
      await tester.tap(find.byTooltip('Remove bill'));
      await tester.pump();
      expect(wc2.recurringBills(), isEmpty);
      expect(find.text('Bill removed'), findsOneWidget);
    });

    tw('expected bills: Skip this cycle moves the due date on and the Today line stops counting the bill', (tester) async {
      final wc = hw(confirmBill: true);
      final bill = wc.recurringBills().single;
      expect(bill.nextDue, '2026-10-25');
      expect(wc.period().reservedBills, 2999, reason: 'unmatched payment: still reserved');
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.text(eur('Due by payday: 1 bill, 29.99 €')), findsOneWidget);
      await plan(tester, wc);
      expect(find.textContaining('next 25 Oct'), findsOneWidget);
      await tester.ensureVisible(find.byKey(ValueKey('skip:${bill.id}')));
      await tester.tap(find.byKey(ValueKey('skip:${bill.id}')));
      await tester.pumpAndSettle();
      expect(wc.recurringBills().single.nextDue, '2026-11-24');
      expect(wc.period().reservedBills, 0);
      // The page keeps its scroll position and may now be shorter: the row can sit outside the built window.
      expect(find.textContaining('next 24 Nov', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('next 25 Oct', skipOffstage: false), findsNothing);
      await pumpApp(tester, today(wc), size: const Size(400, 3000));
      expect(find.textContaining('Due by payday'), findsNothing);
    });

    tw('nudges switch: on asks, schedules and stays on; says amounts never show', (tester) async {
      final fake = FakeNudges();
      final wc = hw(nudges: fake);
      await plan(tester, wc);
      expect(find.textContaining('15:00 on weekdays and Sunday 11:00'), findsOneWidget);
      expect(find.textContaining('never shows amounts'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('nudgesSwitch')));
      await tester.tap(find.byKey(const ValueKey('nudgesSwitch')));
      await tester.pumpAndSettle();
      expect(wc.nudgesEnabled, isTrue);
      expect(fake.scheduled.length, 1);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('nudgesSwitch'))).value, isTrue);
    });

    tw('nudges switch: permission refused keeps it off and says how to allow it', (tester) async {
      final wc = hw(nudges: FakeNudges(allow: false));
      await plan(tester, wc);
      await tester.ensureVisible(find.byKey(const ValueKey('nudgesSwitch')));
      await tester.tap(find.byKey(const ValueKey('nudgesSwitch')));
      await tester.pumpAndSettle();
      expect(wc.nudgesEnabled, isFalse);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('nudgesSwitch'))).value, isFalse);
      expect(find.textContaining('Allow them for Budget Wallet'), findsOneWidget);
    });

    tw('nudges on a computer: the switch is off and disabled, with a note', (tester) async {
      final wc = hw(); // NoNudges
      await plan(tester, wc);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('nudgesSwitch'))).onChanged, isNull);
      expect(find.text('Reminders work in the phone app.'), findsOneWidget);
    });

    tw('Today\'s bills line scrolls Plan to Expected bills', (tester) async {
      final wc = hw();
      final notifier = ValueNotifier<int>(0);
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc, showBills: notifier)), size: const Size(400, 500));
      notifier.value++;
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('EXPECTED BILLS'), findsOneWidget, reason: 'the page moved down until the panel was built');
      expect(tester.getTopLeft(find.text('EXPECTED BILLS')).dy, lessThan(300));
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    final sizes = [
      ('320 dp at text 2.0', const Size(320, 640), 2.0),
      ('360 dp', const Size(360, 800), 1.0),
      ('1280 wide', const Size(1280, 900), 1.0)
    ];
    for (final (name, size, scale) in sizes) {
      tw('$name: Today with the review card and the bills line', (tester) async {
        final errors = Errors();
        final wc = hw(confirmBill: true);
        await pumpApp(tester, today(wc), size: size, textScale: scale);
        expect(find.byKey(const ValueKey('reviewCard')), findsOneWidget);
        await scrollThrough(tester);
        errors.check();
      });

      tw('$name: the review with every step filled', (tester) async {
        final errors = Errors();
        final wc = hw(confirmBill: true);
        await pumpApp(tester, ReviewScreen(wc: wc), size: size, textScale: scale);
        await scrollThrough(tester);
        errors.check();
      });

      tw('$name: Plan with the review day, expected bills and nudges', (tester) async {
        final errors = Errors();
        final wc = hw(confirmBill: true, nudges: FakeNudges());
        await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: size, textScale: scale);
        await scrollThrough(tester);
        errors.check();
      });
    }
  });
}

class _FailingChooser extends FileChooser {
  @override
  Future<List<PlatformFile>> pickBankFiles() async => throw StateError('no portal');
}

/// Rows share a key prefix and end in an id (`confirm:<id>`), so a test finds them by the prefix.
Finder _keyed(String prefix) => find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith(prefix));
