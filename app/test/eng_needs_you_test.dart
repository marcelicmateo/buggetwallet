// ENG E7a: Needs you, one queue for every suggestion (spec §3, §5.6). Fixed clock (20 Oct 2026), SYNTHETIC data only. Each source of the
// queue is shown once and its action does what the old tile did, with an Undo where the answer can be taken back; the Overview badge is
// the queue's length and no item is also an attention tile on Overview; the weekly review shows its steps; the pane stands from 1280 dp.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/device_list.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/bill_sheet.dart';
import 'package:budget_wallet/src/screens/goal_planner.dart';
import 'package:budget_wallet/src/screens/key_backup.dart';
import 'package:budget_wallet/src/screens/needs_you.dart';
import 'package:budget_wallet/src/screens/review.dart';
import 'package:budget_wallet/src/screens/rules_panel.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/fonts.dart';
import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));
Finder _card(String id) => _key('needs:$id');
Finder _primary(String id) => _key('needsPrimary:$id');
Finder _alt(String id) => _key('needsAlt:$id');

/// A clean wallet: salary confirmed, the key prompt put off, so the queue starts empty.
WalletController _wallet({bool salary = true}) {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': salary, 'periodStart': '2026-10-01'});
  wc.snoozeKeyBackup();
  wc.markReviewDone(); // the weekly review is its own test
  return wc;
}

List<String> _ids(WalletController wc) => [for (final i in wc.needsYouItems()) i.id];

Future<void> _pump(WidgetTester t, WalletController wc,
    {Size size = const Size(400, 2000), double scale = 1, Brightness mode = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: Scaffold(body: NeedsYouScreen(wc: wc)),
  ));
  await t.pump();
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump(const Duration(milliseconds: 500));
  await t.pump(const Duration(milliseconds: 500));
}

Future<void> _undo(WidgetTester t) async {
  await t.tap(_key('toastUndo'));
  await t.pump(const Duration(milliseconds: 500));
  await t.pump(const Duration(milliseconds: 500));
}

/// The tests end with the controller's 3 s sync debounce run out (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: const Timeout(Duration(seconds: 90)));

void main() {
  setUpAll(loadAppFonts);

  group('the queue', () {
    tw('nothing: All decided, none left, no badge on Overview', (t) async {
      final wc = _wallet();
      expect(wc.needsYouItems(), isEmpty);
      await _pump(t, wc);
      expect(_key('needsYouEmpty'), findsOneWidget);
      expect(find.text('All decided'), findsOneWidget);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday))));
      await t.pump();
      expect(_key('needsYouBadge'), findsNothing);
      expect(_key('needsYouTile'), findsNothing);
    });

    tw('ordered by urgency: the same list on every call, the sync stop first, heads-ups last', (t) async {
      final wc = _wallet(salary: false);
      wc.sync.deviceStop = DeviceStop.pending;
      wc.repo.importBill(const NormalizedBill(source: BillSource.manual, externalId: 'q1', payee: 'Synthetic Slip Shop', total: 5000));
      wc.reload();
      final kinds = [for (final i in wc.needsYouItems()) i.kind.index];
      expect(kinds, [...kinds]..sort());
      expect(wc.needsYouItems().first.kind, NeedsYouKind.deviceStop);
      expect(_ids(wc), _ids(wc));
      expect(_ids(wc).toSet().length, _ids(wc).length, reason: 'every id once');
    });

    tw('the queue is cached per data version: the same list object until something changes', (t) async {
      final wc = _wallet();
      wc.repo.importBill(const NormalizedBill(source: BillSource.manual, externalId: 'q2', payee: 'Synthetic Slip Shop', total: 5000));
      wc.reload();
      expect(wc.needsYouItems().single.kind, NeedsYouKind.billReview);
      final a = wc.needsYouItems().single, b = wc.needsYouItems().single;
      expect(identical(a, b), isTrue);
    });
  });

  group('each source once, with its action', () {
    tw('a bill to check: Check bill opens the bill', (t) async {
      final wc = _wallet();
      wc.repo.importBill(const NormalizedBill(source: BillSource.manual, externalId: 'q3', payee: 'Synthetic Slip Shop', total: 5000));
      wc.reload();
      final id = wc.billLists().review.single.id;
      expect(_ids(wc), ['bill:$id']);
      await _pump(t, wc);
      expect(_card('bill:$id'), findsOneWidget);
      expect(find.descendant(of: _card('bill:$id'), matching: find.text('Synthetic Slip Shop')), findsOneWidget);
      expect(find.descendant(of: _card('bill:$id'), matching: find.text(moneyExact(5000, 'EUR'))), findsOneWidget);
      await _tap(t, _primary('bill:$id'));
      expect(find.byType(BillSheet), findsOneWidget);
    });

    tw('a bill past its date: Open bills opens Bills & slips', (t) async {
      final wc = _wallet();
      wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      expect(_ids(wc), ['overdue']);
      await _pump(t, wc);
      expect(find.text('1 bill is overdue'), findsOneWidget);
      await _tap(t, _primary('overdue'));
      expect(_key('billsPage'), findsOneWidget);
    });

    tw('a payee rule suggestion: Accept makes the rule, Undo takes it back; Dismiss hides it, Undo shows it again', (t) async {
      final wc = _wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-08', -1200, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
      ]));
      for (final r in wc.repo.transactions()) {
        wc.repo.setCategory(r.id, 'Eating out');
      }
      wc.reload();
      const id = 'rule:konzum_zagreb';
      expect(_ids(wc), [id]);
      await _pump(t, wc);
      await _tap(t, _primary(id));
      expect(_card(id), findsNothing);
      expect(wc.needsYouItems(), isEmpty);
      await _undo(t);
      expect(_card(id), findsOneWidget);
      await _tap(t, _alt(id));
      expect(_card(id), findsNothing);
      expect(wc.ruleSuggestOff, contains('konzum_zagreb'));
      await _undo(t);
      expect(_card(id), findsOneWidget);
      expect(wc.ruleSuggestOff, isEmpty);
    });

    tw('a payee with no main tag: Make rule opens the rule form; Dismiss hides it, Undo shows it again', (t) async {
      final wc = _wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS ZZYX SHOP 0000 ZAGREB'),
        syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS ZZYX SHOP 0000 ZAGREB'),
      ]));
      wc.reload();
      final id = 'payee:${wc.payeeRecommendations().single.merchantKey}';
      expect(_ids(wc), contains(id));
      await _pump(t, wc);
      await _tap(t, _primary(id));
      expect(find.byType(RuleFormSheet), findsOneWidget);
      t.state<NavigatorState>(find.byType(Navigator).first).pop();
      await t.pump(const Duration(milliseconds: 500));
      await _tap(t, _alt(id));
      expect(_card(id), findsNothing);
      await _undo(t);
      expect(_card(id), findsOneWidget);
    });

    tw('a plan suggestion: Accept writes that value and Undo puts the old one back; Not now hides it, Undo shows it', (t) async {
      final wc = _wallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-07-01', -1000, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        for (final d in const ['2026-08-10', '2026-09-10', '2026-10-10']) syntheticTx(d, 120000, 'Plaća/Mirovina', 'Neto placa synthetic'),
      ]));
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true});
      wc.reload();
      final salary = wc.planProposalList().firstWhere((p) => p.key == 'salary');
      expect(salary.suggested, 120000);
      await _pump(t, wc);
      await _tap(t, _primary('plan:salary'));
      expect(wc.settings.salary, 120000);
      expect(_card('plan:salary'), findsNothing);
      await _undo(t);
      expect(wc.settings.salary, 150000);
      expect(_card('plan:salary'), findsOneWidget);
      await _tap(t, _alt('plan:salary'));
      expect(_card('plan:salary'), findsNothing);
      expect(wc.settings.salary, 150000, reason: 'Not now writes nothing');
      await _undo(t);
      expect(_card('plan:salary'), findsOneWidget);
    });

    tw('the wallet key: Save now opens the sheet; Later puts it off 7 days, Undo brings it back', (t) async {
      final wc = _wallet();
      wc.unsnoozeKeyBackup();
      expect(_ids(wc), ['keyBackup']);
      await _pump(t, wc);
      await _tap(t, _alt('keyBackup'));
      expect(_card('keyBackup'), findsNothing);
      await _undo(t);
      expect(_card('keyBackup'), findsOneWidget);
      await _tap(t, _primary('keyBackup'));
      expect(find.byType(KeyBackupSheet), findsOneWidget);
    });

    tw('finish setting up: Continue opens the wizard; No thanks leaves it out, Undo brings it back', (t) async {
      final wc = _wallet();
      wc.markSetupWizardPending();
      expect(_ids(wc), ['wizard']);
      await _pump(t, wc);
      await _tap(t, _alt('wizard'));
      expect(wc.setupWizardOpen, isFalse);
      expect(_card('wizard'), findsNothing);
      await _undo(t);
      expect(wc.setupWizardOpen, isTrue);
      expect(_card('wizard'), findsOneWidget);
      await _tap(t, _primary('wizard'));
      expect(_key('setupWizard'), findsOneWidget);
    });

    tw('the salary to confirm: Looks right confirms it, Undo takes it back', (t) async {
      final wc = _wallet(salary: false);
      expect(_ids(wc), ['salary']);
      await _pump(t, wc);
      expect(find.text(moneyExact(150000, 'EUR')), findsOneWidget);
      await _tap(t, _primary('salary'));
      expect(wc.settings.salaryConfirmed, isTrue);
      expect(_card('salary'), findsNothing);
      await _undo(t);
      expect(wc.settings.salaryConfirmed, isFalse);
      expect(_card('salary'), findsOneWidget);
    });

    tw('a pay period that ended: one button starts the next', (t) async {
      final wc = _wallet();
      wc.repo.updateSettings({'periodStart': '2026-09-10', 'paydayDay': 10});
      wc.reload();
      expect(HeroEnded.of(wc), isTrue);
      expect(_ids(wc), contains('periodEnded'));
      await _pump(t, wc);
      await _tap(t, _primary('periodEnded'));
      expect(wc.settings.periodStart, '2026-10-10');
      expect(_card('periodEnded'), findsNothing);
    });

    tw('the weekly review: the card, the four steps, and Start review opens it', (t) async {
      final wc = habitsWallet();
      wc.snoozeKeyBackup();
      expect(wc.reviewState().due, isTrue);
      expect(_ids(wc), contains('review'));
      await _pump(t, wc);
      expect(_key('needsYouReview'), findsOneWidget);
      for (final label in ['Import', 'Decide', 'Pace', 'Done']) {
        expect(find.textContaining(label), findsWidgets);
      }
      final now = wc.needsYouReviewSteps().where((s) => s.state == 1);
      expect(now, hasLength(1));
      expect(wc.needsYouReviewSteps().last.state, isNot(2), reason: 'Done only once the review is done');
      await _tap(t, _primary('review'));
      expect(find.byType(ReviewScreen), findsOneWidget);
    });

    tw('this device waits for approval: Open Sync; another device wants to join', (t) async {
      final wc = _wallet();
      wc.sync.deviceStop = DeviceStop.pending;
      wc.sync.deviceList = const DeviceList([], [PendingRow('fp-1', 'Synthetic phone')]);
      expect(_ids(wc), ['deviceStop', 'newDevice:fp-1']);
      await _pump(t, wc);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.text('Synthetic phone wants to join'), findsOneWidget);
      var opened = 0;
      wc.tabHook = (tab, via) => opened++;
      await _tap(t, _primary('deviceStop'));
      expect(opened, 1);
    });

    tw('a goal that is ready: Open planner', (t) async {
      final wc = budgetWallet();
      wc.snoozeKeyBackup();
      final id = wc.addBigGoal(name: 'Boat', price: 20000000, financed: true, property: true)!;
      final g = wc.goalOf(id)!;
      wc.saveGoalDraft(id, GoalDraft.of(g)..monthly = 100000);
      wc.repo.saveGoal(id: id, name: 'Boat', target: 0, saved: 5200000, monthly: 100000);
      wc.reload();
      expect(wc.goalReady(wc.goalOf(id)!), isTrue);
      expect(_ids(wc), contains('goal:$id'));
      await _pump(t, wc);
      expect(find.text('Boat is ready to buy'), findsOneWidget);
      await _tap(t, _primary('goal:$id'));
      expect(find.byType(GoalPlannerScreen), findsOneWidget);
    });

    tw('a loan payment?: Yes matches it and Undo unmatches; No answers it', (t) async {
      final wc = budgetWallet();
      wc.snoozeKeyBackup();
      final id = wc.addLoan(Loan(
          id: '',
          name: 'Car loan',
          principal: 1200000,
          rateBp: 600,
          months: 12,
          firstDue: '2026-09-15',
          payeeKey: wc.payeeKeyOf('LENDER SYNTHETIC')))!;
      wc.repo.importBatch(
          ImportBatch(source: 'pbz', transactions: [syntheticTx('2026-09-15', -103000, 'Trajni nalog', 'LENDER SYNTHETIC 123')]));
      wc.reload();
      final tx = wc.loanAsks(id).single.payment.txId;
      expect(_ids(wc), contains('loanAsk:$tx'));
      await _pump(t, wc);
      await _tap(t, _primary('loanAsk:$tx'));
      expect(wc.loanView(id)!.payments.single.txId, tx);
      expect(_card('loanAsk:$tx'), findsNothing);
      await _undo(t);
      expect(wc.loanView(id)!.payments, isEmpty);
      expect(wc.loanAsks(id), isEmpty, reason: 'Undo answers No: the row is not asked about again');
    });

    tw('a loan that ended: the freed payment goes to a goal, Undo puts it back', (t) async {
      final wc = budgetWallet();
      wc.snoozeKeyBackup();
      final loan = wc.addLoan(Loan(
          id: '',
          name: 'Car loan',
          principal: 1200000,
          rateBp: 600,
          months: 12,
          firstDue: '2026-08-15',
          payeeKey: wc.payeeKeyOf('LENDER SYNTHETIC')))!;
      final goal = wc.repo.saveGoal(name: 'Reserve', target: 100000, saved: 0, monthly: 10000);
      wc.reload();
      expect(wc.closeLoanNow(loan), isNull);
      final e = wc.loanEnded().single;
      expect(_ids(wc), contains('loanEnded:$loan'));
      await _pump(t, wc);
      expect(find.text('Add to Reserve'), findsOneWidget);
      await _tap(t, _primary('loanEnded:$loan'));
      expect(wc.goalOf(goal)!.monthly, 10000 + e.payment);
      expect(_card('loanEnded:$loan'), findsNothing);
      await _undo(t);
      expect(wc.goalOf(goal)!.monthly, 10000);
      expect(_card('loanEnded:$loan'), findsOneWidget);
    });

    tw('an account to check: Check balance opens the question', (t) async {
      final wc = _wallet();
      final id = await wc.addAccount(name: 'PBZ current', source: 'pbz', currency: 'EUR', opening: -50000, openingDate: '2026-07-01');
      expect(_ids(wc), ['balance:$id']);
      await _pump(t, wc);
      expect(find.text('PBZ current'), findsOneWidget);
      await _tap(t, _primary('balance:$id'));
      expect(_key('bankCheckSheet'), findsOneWidget);
    });

    tw('a bill without a category and a heads-up: one card each, Open opens the bill', (t) async {
      final repo = WalletRepo.inMemory(now: () => budgetToday.millisecondsSinceEpoch);
      final wc = seamedController(repo, key: VaultKey.generate(), clock: () => budgetToday);
      addTearDown(wc.dispose);
      repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
      final (billId, _) = repo.importBill(const NormalizedBill(
          source: BillSource.manual, externalId: 'q-gas', payee: 'Synth Gas', total: 2500, dueDate: '2026-10-26', date: '2026-10-20'));
      repo.linkBill(billId, repo.addTransaction(date: '2026-10-19', amount: 2500, category: 'Groceries'));
      repo.confirmBill(billId);
      repo.unlinkBill(billId);
      wc.snoozeKeyBackup();
      wc.saveHeadsUp(cents: 1000, days: 14);
      wc.reload();
      final n = wc.plannedNeedingCategory().single;
      expect(_ids(wc), contains('category:${n.id}'));
      await _pump(t, wc);
      await _tap(t, _primary('category:${n.id}'));
      expect(find.byType(BillSheet), findsOneWidget);
    });

    tw('devices that disagree: Choose opens the page', (t) async {
      final wc = _wallet();
      final clock = Hlc(DateTime.now().millisecondsSinceEpoch - 5000, 0, 'peer1234').toString();
      Op op(String v) => Op('setting', 'paydayDay', {'value': v, 'deleted': 0}, clock);
      wc.repo.applyRemote([op('10')], match: false);
      wc.repo.applyRemote([op('25')], match: false, repair: true);
      wc.reload();
      expect(_ids(wc), contains('conflicts'));
      await _pump(t, wc);
      await _tap(t, _primary('conflicts'));
      expect(find.text('Choose the right values'), findsWidgets);
    });
  });

  group('Overview', () {
    Future<void> overview(WidgetTester t, WalletController wc, {Size size = const Size(400, 2400)}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday))));
      await t.pump();
    }

    WalletController busy() {
      final wc = habitsWallet();
      wc.unsnoozeKeyBackup();
      wc.markSetupWizardPending();
      wc.sync.deviceStop = DeviceStop.pending;
      wc.addRecurringBill(label: 'Synthetic gym', category: 'Groceries', amount: 3000, intervalDays: 30, firstDue: '2026-10-15');
      wc.repo.importBill(const NormalizedBill(source: BillSource.manual, externalId: 'q9', payee: 'Synthetic Slip Shop', total: 5000));
      wc.reload();
      return wc;
    }

    tw('the badge is the queue length and one tile says how many; no item is also an attention tile', (t) async {
      final wc = busy();
      final n = wc.needsYouItems().length;
      expect(n, greaterThan(4));
      await overview(t, wc);
      expect(t.widget<Text>(find.descendant(of: _key('needsYouBadge'), matching: find.byType(Text))).data, '$n');
      expect(find.descendant(of: _key('needsYouTile'), matching: find.text('$n')), findsOneWidget);
      for (final gone in [
        'periodEndedPanel',
        'setupPanel',
        'setupLine',
        'keyBackupRow',
        'wizardRow',
        'deviceStopLine',
        'billsToReview',
        'billsLine',
        'reviewCard',
        'startReview',
        'keySaveNow'
      ]) {
        expect(_key(gone), findsNothing, reason: gone);
      }
      expect(_keyStartsWith('balanceWarn:'), findsNothing);
      expect(_keyStartsWith('needsCategory:'), findsNothing);
      expect(_keyStartsWith('headsUp:'), findsNothing);
      // The number tiles are still there.
      expect(_key('leftTile'), findsOneWidget);
    });

    tw('the badge opens the queue; answering a card changes the count', (t) async {
      final wc = busy();
      final n = wc.needsYouItems().length;
      await overview(t, wc);
      await t.tap(_key('overviewNeedsYou'));
      await t.pump(const Duration(milliseconds: 600));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(NeedsYouScreen), findsOneWidget);
      expect(find.text('$n left'), findsOneWidget);
    });

    tw('from 1280 dp the queue stands beside Overview (rail | Overview | Needs you), the tile is not repeated, other tabs have no pane',
        (t) async {
      final wc = busy();
      await pumpFull(t, wc, 1.0, size: const Size(1440, 1000));
      await t.pump(const Duration(milliseconds: 600));
      expect(_key('needsYouPane'), findsOneWidget);
      expect(_key('needsYouTile'), findsNothing);
      expect(find.byType(NeedsYouCard), findsWidgets);
      expect(find.text('${wc.needsYouItems().length} left'), findsOneWidget);
      expect(t.getTopLeft(_key('needsYouPane')).dx, greaterThan(t.getTopRight(_key('heroTile')).dx));
      await tapTab(t, 'Bills');
      await t.pump(const Duration(milliseconds: 600));
      expect(_key('needsYouPane'), findsNothing);
      await tapTab(t, 'Today');
      await t.pump(const Duration(milliseconds: 600));
      expect(_key('needsYouPane'), findsOneWidget);
      // A card in the pane answers like on the page.
      await _tap(t, _alt('keyBackup'));
      expect(wc.needsYouItems().any((i) => i.kind == NeedsYouKind.keyBackup), isFalse);
    });

    tw('below 1280 dp there is no pane', (t) async {
      final wc = busy();
      await overview(t, wc, size: const Size(1100, 900));
      expect(_key('needsYouPane'), findsNothing);
      expect(_key('needsYouTile'), findsOneWidget);
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
        tw('every card kind at ${e.key}, ${mode.name}: no overflow', (t) async {
          final wc = habitsWallet();
          wc.unsnoozeKeyBackup();
          wc.markSetupWizardPending();
          wc.sync.deviceStop = DeviceStop.pending;
          wc.addRecurringBill(
              label: 'Synthetic late bill, a long name', category: 'Groceries', amount: 123457, intervalDays: 30, firstDue: '2026-10-15');
          wc.repo.importBill(const NormalizedBill(
              source: BillSource.manual, externalId: 'q10', payee: 'Synthetic Slip Shop with a long name', total: 123457));
          wc.reload();
          await withErrors((errors) async {
            await _pump(t, wc, size: e.value.$1, scale: e.value.$2, mode: mode);
            await scrollThrough(t);
            expect(t.takeException(), isNull);
            errors.check();
          });
        });
      }
    }
  });
}

Finder _keyStartsWith(String p) =>
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(p));

/// Whether the pay period has ended, as Overview's hero asks.
abstract final class HeroEnded {
  static bool of(WalletController wc) => wc.period().paydayPassed;
}
