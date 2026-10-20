// SYNTHETIC wallets for widget tests. Made-up amounts; merchants are well-known chains or generic names.
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

NormalizedTransaction _n(String date, int cents, String type, String desc, {String source = 'pbz'}) => NormalizedTransaction(
    id: transactionId(date, cents, desc, 0),
    source: source,
    date: date,
    amountMinor: cents,
    currency: 'EUR',
    bankType: type,
    description: desc);

/// One synthetic bank row (for wallets whose dates are fixed by a test clock).
NormalizedTransaction syntheticTx(String date, int cents, String type, String desc) => _n(date, cents, type, desc);

/// An empty in-memory wallet with a key (no sync folder, no timers).
WalletController emptyWallet({bool withKey = true}) =>
    WalletController.forTest(WalletRepo.inMemory(), key: withKey ? VaultKey.generate() : null);

/// A wallet that shows every optional Today/Wishlist panel: salary not confirmed, a new payday waiting,
/// the payday checklist, goals, recent rows, wishlist items waiting / ready / decided.
WalletController demoWallet() {
  final wc = emptyWallet();
  final today = wc.today();
  final start = addDays(today, -25);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    _n(start, 150000, 'Plaća/Mirovina', 'Neto placa synthetic'),
    _n(addDays(today, -1), 150000, 'Plaća/Mirovina', 'Neto placa synthetic two'),
    _n(addDays(start, 1), -55000, 'Isplata ATM', 'ATM SYNTHETIC STREET'),
    _n(addDays(start, 2), -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    _n(addDays(start, 3), -25000, 'Trajni nalog', 'Naplata kredita 0000000000'),
    _n(addDays(today, -2), -1999, 'POS plaćanje', 'PBZ POS PBZ7WOLT ZAGREB'),
  ]));
  wc.repo.saveGoal(name: 'Emergency fund with a long synthetic name', target: 300000, saved: 0, monthly: 10000, sort: 1);
  wc.repo.saveGoal(name: 'Yearly costs', target: 120000, saved: 0, monthly: 10000, sort: 2);
  wc.repo.updateSettings({'salary': 150000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'periodStart': start, 'salaryConfirmed': false});
  final now = DateTime.now().millisecondsSinceEpoch;
  wc.repo.addWish('Synthetic headphones with a long name', 12000);
  final decided = wc.repo.addWish('Synthetic jacket', 9000);
  wc.repo.decideWish(decided, 'skipped');
  // A wish added on another device 100 hours ago: ready to decide.
  wc.repo.applyRemote([
    Op('wish', 'wish-ready', {'name': 'Synthetic lamp', 'price': 8000, 'added': now - 100 * 3600000, 'status': 'waiting', 'deleted': 0},
        Hlc(now + 1000, 0, 'peer').toString()),
  ]);
  wc.reload();
  return wc;
}

/// A setting changed on another device, as a sync would apply it (newer HLC), then reloaded.
void remoteSetting(WalletController wc, String key, Object? value) {
  final now = DateTime.now().millisecondsSinceEpoch;
  wc.repo.applyRemote([
    Op('setting', key, {'value': jsonEncode(value), 'deleted': 0}, Hlc(now + 60000, 0, 'peer').toString())
  ]);
  wc.reload();
}

/// Pumps [child] in the app theme at a logical [size] and text scale.
Future<void> pumpApp(WidgetTester tester, Widget child, {Size size = const Size(400, 900), double textScale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: c!),
    home: child,
  ));
  await tester.pump();
}

/// The day [budgetWallet] lives on (day 20 of 31, so a monthly budget is about two thirds through its month).
final budgetToday = DateTime(2026, 10, 20, 12);

/// A wallet with a fixed clock (20 Oct 2026): 6 months of history (Groceries 290, Eating out 85 a month) and this month
/// Groceries 252, Eating out 112, Shopping 60. With [budgets]: Groceries 300 (48 left) and [eatingOutBudget] for Eating out
/// (default 100: over by 12). Without: nothing budgeted.
WalletController budgetWallet({bool budgets = true, int eatingOutBudget = 10000, int groceriesBudget = 30000}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  for (final m in const ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09']) {
    wc.repo.addManual(date: '$m-10', amount: 29000, category: 'Groceries');
    wc.repo.addManual(date: '$m-12', amount: 8500, category: 'Eating out');
  }
  wc.repo.addManual(date: '2026-10-03', amount: 15200, category: 'Groceries');
  wc.repo.addManual(date: '2026-10-12', amount: 10000, category: 'Groceries');
  wc.repo.addManual(date: '2026-10-08', amount: 11200, category: 'Eating out');
  wc.repo.addManual(date: '2026-10-09', amount: 6000, category: 'Shopping');
  wc.repo.updateSettings({
    'salary': 150000,
    'salaryConfirmed': true,
    'periodStart': '2026-10-01',
    if (budgets) 'categoryBudgets': {'Groceries': groceriesBudget, 'Eating out': eatingOutBudget},
  });
  wc.reload();
  return wc;
}

/// A reminders stand-in: records what the app asked for, no plugin.
class FakeNudges implements NudgePlatform {
  final bool allow;
  final bool canShow;
  int asked = 0, cancelled = 0;
  final List<List<NudgeSlot>> scheduled = [];
  FakeNudges({this.allow = true, this.canShow = true});
  @override
  bool get supported => canShow;
  @override
  Future<bool> requestPermission() async {
    asked++;
    return allow;
  }

  @override
  Future<int> schedule(List<NudgeSlot> slots) async {
    scheduled.add(slots);
    return slots.length;
  }

  @override
  Future<void> cancelAll() async => cancelled++;
}

/// The data of [budgetWallet] (Tuesday 20 Oct 2026; Groceries behind pace, Eating out over) plus what the weekly review and the bills need:
/// three card payments in the last week without a learned category, a monthly gym payment three months running (a bill
/// candidate), and a wish that finished waiting. The review is due (never done), the review day is Sunday.
WalletController habitsWallet({FakeNudges? nudges, bool confirmBill = false}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday, nudges: nudges);
  for (final m in const ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09']) {
    wc.repo.addManual(date: '$m-10', amount: 29000, category: 'Groceries');
    wc.repo.addManual(date: '$m-12', amount: 8500, category: 'Eating out');
  }
  wc.repo.addManual(date: '2026-10-03', amount: 15200, category: 'Groceries');
  wc.repo.addManual(date: '2026-10-12', amount: 10000, category: 'Groceries');
  wc.repo.addManual(date: '2026-10-08', amount: 11200, category: 'Eating out');
  wc.repo.addManual(date: '2026-10-09', amount: 6000, category: 'Shopping');
  wc.repo.updateSettings({
    'salary': 150000,
    'salaryConfirmed': true,
    'periodStart': '2026-10-01',
    'categoryBudgets': {'Groceries': 30000, 'Eating out': 10000},
  });
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-18', -1850, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    syntheticTx('2026-10-19', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-19', -1500, 'POS plaćanje', 'PBZ POS PBZ7WOLT ZAGREB'),
    for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) syntheticTx(d, -2999, 'POS plaćanje', 'POS SYNTHGYM ZAGREB'),
  ]));
  wc.repo.applyRemote([
    Op(
        'wish',
        'wish-ready',
        {
          'name': 'Synthetic lamp',
          'price': 8000,
          'added': budgetToday.millisecondsSinceEpoch - 100 * 3600000,
          'status': 'waiting',
          'deleted': 0
        },
        Hlc(budgetToday.millisecondsSinceEpoch + 1000, 0, 'peer').toString()),
  ]);
  wc.reload();
  wc.refreshRecurring();
  if (confirmBill) {
    wc.confirmRecurring(wc.recurringBills().first.id);
  }
  return wc;
}
