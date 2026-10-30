// Stage I, I1 + I3 (spec: scratchpad I-spec.md, "App, part B"): Today over states, no negative figure anywhere, the ONE
// first-run setup panel, and the Plan payday ledger rows adding up. Fixed clock (Sunday 25 Oct 2026 12:00); every figure
// is worked out by hand from the settings below. SYNTHETIC data.
//
// Behaviour not built on v2 carries a FIXED skip string `BUG: I<n> - ...`; the lead lifts them at merge.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/plan_page.dart';
import 'support/wallet.dart';

// BUG: I1 - overSentence / no negative figures on Today (testWidgets takes a bool skip; the lead lifts it at merge)
const _skipOver = false;
// BUG: I1 - one setupPanel / setupLine on Today (testWidgets takes a bool skip; the lead lifts it at merge)
const _skipSetup = false;
// BUG: I3 - ledgerSetAside / ledgerSpendingMoney in Plan (testWidgets takes a bool skip; the lead lifts it at merge)
const _skipLedger = false;

const _nbsp = ' ';

/// Salary 2000, rent 500, loan 200, subs 50: flexible money 1250.00 for 2026-10-15 .. 2026-11-15 (31 days).
/// On the 25th: 21 days left. Today's allowance with [spentBefore] spent earlier = (125000 - spentBefore) / 21.
WalletController _wallet({
  DateTime? now,
  int spentBefore = 0,
  int spentToday = 0,
  bool confirmed = true,
  Map<String, Object?> settings = const {},
}) {
  final at = now ?? DateTime(2026, 10, 25, 12);
  final wc = WalletController.forTest(WalletRepo.inMemory(), clock: () => at);
  if (spentBefore > 0) wc.repo.addTransaction(date: '2026-10-20', amount: spentBefore, category: 'Groceries');
  if (spentToday > 0) wc.repo.addTransaction(date: addDays(isoDate(at), 0), amount: spentToday, category: 'Groceries');
  wc.repo.updateSettings({
    'salary': 200000,
    'rent': 50000,
    'loan': 20000,
    'subs': 5000,
    'periodStart': '2026-10-15',
    'paydayDay': 15,
    'salaryConfirmed': confirmed,
    ...settings,
  });
  wc.reload();
  return wc;
}

Future<void> _pumpToday(WidgetTester tester, WalletController wc, {DateTime? now}) async {
  final at = now ?? DateTime(2026, 10, 25, 12);
  await pumpApp(tester, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => at)), size: const Size(400, 3000));
}

/// Every Text on screen that shows a minus sign in front of a figure.
/// Transaction rows are left out: an expense there is a legitimate minus; the spec forbids negative allowance/budget figures.
List<String> _negatives(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(Scaffold), matching: find.byType(Text))))
        if (find.ancestor(of: find.byWidget(t), matching: find.byType(TxTile)).evaluate().isEmpty)
          if (RegExp(r'[−-]\s?\d').hasMatch(t.data ?? t.textSpan?.toPlainText() ?? '') && !RegExp(r'\d{4}-\d{2}').hasMatch(t.data ?? ''))
            t.data ?? t.textSpan!.toPlainText(),
    ];

/// The plain text of everything under the widget with [key] (the key may sit on a Muted, a KeyedSubtree or a StatusLabel).
String _under(WidgetTester tester, String key) => [
      for (final t in tester.widgetList<RichText>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(RichText))))
        t.text.toPlainText(),
    ].join(' ');

void main() {
  group('I1: over today', () {
    // Spent 80.00 today. Allowance today 125000 / 21 = 5952 (59.52). Over today by 8000 - 5952 = 2048 (20.48).
    // Allowance tomorrow = (125000 - 8000) / 20 = 5850 (58.50).
    testWidgets('the sentence names what is over and what tomorrow starts at', (tester) async {
      final wc = _wallet(spentToday: 8000);
      await _pumpToday(tester, wc);
      final s = find.byKey(const ValueKey('overSentence'));
      expect(s, findsOneWidget);
      expect(_under(tester, 'overSentence'), "You're 20.48$_nbsp€ over for today. Nothing more today; tomorrow starts at 58.50$_nbsp€.");
    }, skip: _skipOver);

    testWidgets('payday tomorrow: over today is over the period too, so no "tomorrow starts at" figure is promised', (tester) async {
      // 14 Nov: 1 day left (payday 15 Nov). Today's allowance is everything left, so being over today means being over the
      // plan: the period sentence wins and names no figure for tomorrow (allowanceTomorrow is null here).
      final at = DateTime(2026, 11, 14, 12);
      final wc = _wallet(now: at, spentBefore: 120000, spentToday: 9000);
      await _pumpToday(tester, wc, now: at);
      final text = _under(tester, 'overSentence');
      expect(text, contains('over the plan for this period.'));
      expect(text, isNot(contains('tomorrow starts at')));
    }, skip: _skipOver);

    testWidgets('not over today: no overSentence', (tester) async {
      await _pumpToday(tester, _wallet(spentToday: 2000));
      expect(find.byKey(const ValueKey('overSentence')), findsNothing);
      // the check can fail: the same page with an overspend does show it (see the first test)
    }, skip: _skipOver);

    testWidgets('over the period: "You\'re X over the plan for this period." (spent 1300.00 of 1250.00)', (tester) async {
      final wc = _wallet(spentBefore: 130000);
      await _pumpToday(tester, wc);
      expect(find.byKey(const ValueKey('overSentence')), findsOneWidget);
      expect(_under(tester, 'overSentence'), contains("You're 50$_nbsp€ over the plan for this period."));
    }, skip: _skipOver);

    testWidgets('no negative figure on Today, over today or over the period', (tester) async {
      for (final wc in [_wallet(spentToday: 8000), _wallet(spentBefore: 130000), _wallet(spentBefore: 130000, spentToday: 3000)]) {
        await _pumpToday(tester, wc);
        expect(_negatives(tester), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }, skip: _skipOver);

    testWidgets('control: the negative-figure probe does find a minus', (tester) async {
      await pumpApp(tester, const Scaffold(body: Text('−12 €')));
      expect(_negatives(tester), ['−12 €']);
    });
  });

  group('I1: the first-run setup panel', () {
    // demoWallet: key not saved, salary not confirmed, a new payday waiting: three open steps.
    Future<void> pumpDemo(WidgetTester tester, WalletController wc) => pumpApp(
        tester,
        Scaffold(
            body: ListenableBuilder(
                listenable: wc, builder: (_, __) => TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => wc.now))),
        size: const Size(400, 3000));

    testWidgets('three open steps are ONE panel listing all of them', (tester) async {
      await pumpDemo(tester, demoWallet());
      final panel = find.byKey(const ValueKey('setupPanel'));
      expect(panel, findsOneWidget);
      for (final part in ['Save your wallet key', 'Planning on', 'Salary landed on']) {
        expect(find.descendant(of: panel, matching: find.textContaining(part)), findsOneWidget, reason: part);
      }
      expect(find.byKey(const ValueKey('setupLine')), findsNothing);
      // not three separate panels: the steps are not found outside the panel
      expect(find.textContaining('Save your wallet key'), findsOneWidget);
    }, skip: _skipSetup);

    testWidgets('after the owner dismisses it, one collapsed line; tapping the line opens the panel again', (tester) async {
      final wc = demoWallet();
      await pumpDemo(tester, wc);
      // Assumption (not in the spec): the dismiss control is the panel's own Hide button (key setupHide).
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('setupPanel')), matching: find.byKey(const ValueKey('setupHide'))));
      await tester.pump();
      expect(find.byKey(const ValueKey('setupPanel')), findsNothing);
      expect(find.byKey(const ValueKey('setupLine')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setupLine')));
      await tester.pump();
      expect(find.byKey(const ValueKey('setupPanel')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupLine')), findsNothing);
    }, skip: _skipSetup);

    testWidgets('the collapsed state is device-local and survives a restart of the controller', (tester) async {
      final wc = demoWallet();
      await pumpDemo(tester, wc);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('setupPanel')), matching: find.byKey(const ValueKey('setupHide'))));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      final again = WalletController.forTest(wc.repo, key: wc.key);
      await pumpDemo(tester, again);
      expect(find.byKey(const ValueKey('setupLine')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupPanel')), findsNothing);
    }, skip: _skipSetup);

    testWidgets('nothing open: neither the panel nor the line', (tester) async {
      final wc = _wallet(confirmed: true); // no key, salary confirmed, no new payday
      await _pumpToday(tester, wc);
      expect(find.byKey(const ValueKey('setupPanel')), findsNothing);
      expect(find.byKey(const ValueKey('setupLine')), findsNothing);
    }, skip: _skipSetup);

    testWidgets('only one step open (salary): the panel lists just that step', (tester) async {
      final wc = _wallet(confirmed: false);
      await _pumpToday(tester, wc);
      final panel = find.byKey(const ValueKey('setupPanel'));
      expect(panel, findsOneWidget);
      expect(find.descendant(of: panel, matching: find.textContaining('Planning on')), findsOneWidget);
      expect(find.descendant(of: panel, matching: find.textContaining('Save your wallet key')), findsNothing);
    }, skip: _skipSetup);
  });

  group('I3: the Plan payday ledger adds up', () {
    Future<void> pumpPlan(WidgetTester tester, WalletController wc) async {
      await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 4000));
    }

    String valueOf(WidgetTester tester, String key) {
      final texts = tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))).toList();
      return texts.last.data ?? texts.last.textSpan!.toPlainText();
    }

    testWidgets('a planned cost before payday shows as "Before payday", and the rows sum to the total', (tester) async {
      // Reserved: a 90.00 planned cost on 30 Oct (before payday). Spending money = 1250.00 - 90.00 = 1160.00.
      final wc = _wallet();
      wc.repo.addPlanned(title: 'Synthetic dentist', date: '2026-10-30', amount: 9000, category: 'Health');
      wc.reload();
      await pumpPlan(tester, wc);
      expect(find.byKey(const ValueKey('ledgerSetAside')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('ledgerSetAside')), matching: find.textContaining('Before payday')),
          findsOneWidget);
      expect(valueOf(tester, 'ledgerSetAside'), contains('90'));
      expect(valueOf(tester, 'ledgerSetAside'), anyOf(contains('−'), contains('-')));
      // salary 2000 - rent 500 - loan 200 - subs 50 - set aside 90 = 1160
      expect(find.textContaining('1,160'), findsWidgets);
    }, skip: _skipLedger);

    testWidgets('nothing set aside: no row', (tester) async {
      await pumpPlan(tester, _wallet());
      expect(find.byKey(const ValueKey('ledgerSetAside')), findsNothing);
    }, skip: _skipLedger);

    testWidgets('a negative total reads "Over by X" in red, never a minus', (tester) async {
      // Salary 1000, rent 900, loan 300: spending money -200.
      final wc = _wallet(settings: {'salary': 100000, 'rent': 90000, 'loan': 30000, 'subs': 0});
      await pumpPlan(tester, wc);
      final row = find.byKey(const ValueKey('ledgerSpendingMoney'));
      expect(row, findsOneWidget);
      final over = find.descendant(of: row, matching: find.textContaining('Over by'));
      expect(over, findsOneWidget);
      expect(tester.widget<Text>(over).style?.color, anyOf(WalletColors.light.bad, WalletColors.light.neg));
      final shown = tester.widget<Text>(over).data ?? '';
      expect(shown, contains('200'));
      expect(shown, isNot(contains('−')));
      expect(shown, isNot(contains('-')));
    }, skip: _skipLedger);

    testWidgets('a positive total keeps the plain figure on the ledgerSpendingMoney row', (tester) async {
      await pumpPlan(tester, _wallet());
      final row = find.byKey(const ValueKey('ledgerSpendingMoney'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('Over by')), findsNothing);
      expect(find.descendant(of: row, matching: find.textContaining('1,250')), findsOneWidget);
    }, skip: _skipLedger);
  });
}
