// PS: the payday auto-save. Every goal with a monthly amount is paid once per pay period without a tap (a salary or a started
// month sets the period; none, nothing is paid). Skipping or lowering a goal for one period, or taking money out of it, moves
// exactly that money in or out of the period's spending money; moving it to another goal leaves spending money alone.
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

int _saved(WalletController wc, String name) => wc.goals.firstWhere((g) => g.name.startsWith(name)).saved;
String _id(WalletController wc, String name) => wc.goals.firstWhere((g) => g.name.startsWith(name)).id;

void main() {
  test('goals are paid by themselves, once per pay period', () {
    final wc = demoWallet();
    expect(wc.goals.map((g) => g.saved), [10000, 10000], reason: 'paid on the first load');
    wc.reload();
    wc.reload();
    expect(wc.goals.map((g) => g.saved), [10000, 10000], reason: 'a reload in the same period pays nothing more');
    // The next salary starts the next period: paid once more.
    wc.startNewMonth(addDays(wc.today(), 1));
    expect(wc.goals.map((g) => g.saved), [20000, 20000]);
  });

  test('a wallet without a salary or a started month pays nothing; so does a goal without a monthly amount', () {
    final wc = emptyWallet();
    wc.repo.saveGoal(name: 'Trip', target: 100000, saved: 0, monthly: 5000);
    wc.reload();
    expect(wc.goals.single.saved, 0);
    wc.repo.saveGoal(name: 'Open', target: 0, saved: 0, monthly: 0);
    wc.startNewMonth(wc.today());
    expect(_saved(wc, 'Trip'), 5000);
    expect(_saved(wc, 'Open'), 0, reason: 'monthly 0: no row');
  });

  test('a goal made in the middle of the period is paid once', () {
    final wc = demoWallet();
    wc.saveGoal(name: 'Bike', target: 50000, saved: 0, monthly: 4000);
    wc.reload();
    expect(_saved(wc, 'Bike'), 4000);
  });

  test('skip raises spending money by exactly the amount; lowering twice, the last one wins', () {
    final wc = demoWallet();
    final before = wc.period().flexBudget;
    final id = _id(wc, 'Yearly');
    wc.setGoalPeriodAmount(id, 0);
    expect(_saved(wc, 'Yearly'), 0);
    expect(wc.period().flexBudget, before + 10000);
    wc.setGoalPeriodAmount(id, 2500);
    wc.setGoalPeriodAmount(id, 4000);
    expect(_saved(wc, 'Yearly'), 4000);
    expect(wc.period().flexBudget, before + 6000);
    expect(wc.goalPeriodAmounts()[id], 4000);
    expect(() => wc.setGoalPeriodAmount(id, -1), throwsArgumentError);
    expect(() => wc.setGoalPeriodAmount(id, Goal.maxContribution + 1), throwsArgumentError);
  });

  test('take out to spending raises this period\'s spending money; a move to another goal does not', () {
    final wc = demoWallet();
    final before = wc.period().flexBudget;
    final a = _id(wc, 'Emergency'), b = _id(wc, 'Yearly');
    wc.takeOutOfGoal(a, 3000);
    expect(_saved(wc, 'Emergency'), 7000);
    expect(wc.period().flexBudget, before + 3000);
    wc.takeOutOfGoal(a, 2000, toGoalId: b);
    expect(_saved(wc, 'Emergency'), 5000);
    expect(_saved(wc, 'Yearly'), 12000);
    expect(wc.period().flexBudget, before + 3000, reason: 'a move leaves spending money alone');
    expect(() => wc.takeOutOfGoal(a, 5001), throwsArgumentError, reason: 'more than is saved');
    expect(() => wc.takeOutOfGoal(a, 100, toGoalId: a), throwsArgumentError);
    expect(_saved(wc, 'Emergency'), 5000);
  });

  test('a take out after the period ended, before a new one is started, still counts in that period', () {
    final wc = WalletController.forTest(WalletRepo.inMemory(), clock: () => DateTime(2026, 11, 20, 12));
    addTearDown(wc.dispose);
    wc.repo.updateSettings({'salary': 200000, 'periodStart': '2026-10-15', 'paydayDay': 15, 'salaryConfirmed': true});
    wc.saveGoal(name: 'Synthetic goal', target: 100000, saved: 5000, monthly: 1000);
    final before = wc.period().flexBudget;
    wc.takeOutOfGoal(_id(wc, 'Synthetic'), 2000);
    expect(wc.period().flexBudget, before + 2000, reason: 'dated on the period\'s last day (14 Nov), not today (20 Nov)');
  });
}
