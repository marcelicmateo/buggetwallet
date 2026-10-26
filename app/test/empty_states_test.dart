// Every tab with unusual wallets: empty, one transaction, everything on one day, future dates, odd goals and wishes,
// odd settings. Each is toured at 400 dp and at 320 dp with text scale 2.0: no exception, no overflow, and no
// "NaN", "Infinity", "null" or "Invalid" on screen. All data is SYNTHETIC.
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

NormalizedTransaction _bank(String date, int cents, String type, String desc) => NormalizedTransaction(
    id: transactionId(date, cents, desc, 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: 'EUR',
    bankType: type,
    description: desc);

final _bad = RegExp(r'NaN|Infinity|\bnull\b|Invalid|Exception|Error\b');

/// Everything painted on the current screen as plain text.
Iterable<String> _texts(WidgetTester tester) => find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText());

Future<Set<String>> _tour(WidgetTester tester, WalletController wc, {Size size = const Size(400, 900), double scale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(BudgetWalletApp(wc: wc));
  await tester.pump();
  final seen = <String>{};
  Future<void> scroll() async {
    seen.addAll(_texts(tester));
    final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).hitTestable();
    if (lists.evaluate().isEmpty) return;
    final pos = tester.state<ScrollableState>(lists.first).position;
    for (var i = 0; i < 40 && pos.pixels < pos.maxScrollExtent; i++) {
      pos.jumpTo((pos.pixels + 300).clamp(0, pos.maxScrollExtent));
      await tester.pump();
      seen.addAll(_texts(tester));
    }
  }

  await scroll();
  for (final tab in ['Budget', 'Bills', 'Save', 'Settings', 'Today']) {
    await tapTab(tester, tab);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await scroll();
  }
  await tester.pump(const Duration(seconds: 4)); // sync debounce
  return seen;
}

void _expectClean(WidgetTester tester, Set<String> seen) {
  expect(tester.takeException(), isNull);
  final bad = seen.where(_bad.hasMatch).toList();
  expect(bad, isEmpty, reason: 'suspicious text on screen: $bad');
}

typedef _Setup = void Function(WalletController wc);

void _scenario(String name, _Setup setup, {void Function(WidgetTester, Set<String>)? check}) {
  for (final (label, size, scale) in [('400 dp', const Size(400, 900), 1.0), ('320 dp, text 2.0', const Size(320, 640), 2.0)]) {
    testWidgets('$name ($label)', (tester) async {
      final wc = emptyWallet();
      setup(wc);
      wc.reload();
      final seen = await _tour(tester, wc, size: size, scale: scale);
      _expectClean(tester, seen);
      check?.call(tester, seen);
    });
  }
}

bool _has(Set<String> seen, Pattern p) => seen.any((s) => s.contains(p));

void main() {
  _scenario('empty wallet: no transactions, goals, wishes or settings', (wc) {}, check: (t, seen) {
    expect(_has(seen, 'No transactions yet'), isTrue);
    expect(_has(seen, 'No goals yet.'), isTrue);
    expect(_has(seen, 'Your wishlist is empty'), isTrue);
    expect(_has(seen, 'Enter your monthly salary in Budget'), isTrue, reason: 'salary 0 asks for the number instead of dividing by it');
  });

  _scenario('one income transaction only', (wc) {
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank(wc.today(), 150000, 'Plaća/Mirovina', 'Neto placa synthetic')]));
  });

  _scenario('one expense only, no salary', (wc) {
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank(wc.today(), -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL ZAGREB')]));
  });

  _scenario('everything happened on one day (today), zero days of history', (wc) {
    final d = wc.today();
    wc.repo.updateSettings({'salary': 150000, 'rent': 50000, 'periodStart': d});
    for (final c in [1000, 2000, 300]) {
      wc.repo.addTransaction(date: d, amount: c, category: 'Shopping', note: 'Item $c');
    }
  }, check: (t, seen) => expect(_has(seen, 'Spent 33.00\u00A0€ today'), isTrue, reason: '10.00 + 20.00 + 3.00 spent today'));

  _scenario('all bank rows on the first day of the period', (wc) {
    final d = wc.today();
    wc.repo.updateSettings({'salary': 150000, 'periodStart': d});
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      _bank(d, 150000, 'Plaća/Mirovina', 'Neto placa synthetic'),
      for (var i = 1; i <= 8; i++) _bank(d, -100 * i, 'POS plaćanje', 'PBZ POS PBZ7LIDL STORE $i'),
    ]));
  });

  _scenario('a future-dated expense does not count as spent today', (wc) {
    wc.repo.updateSettings({'salary': 150000, 'periodStart': addDays(wc.today(), -5)});
    wc.repo.addTransaction(date: addDays(wc.today(), 5), amount: 9900, category: 'Shopping', note: 'Future thing');
  }, check: (t, seen) {
    expect(_has(seen, 'Spent 99.00\u00A0€ today'), isFalse);
    expect(_has(seen, 'Future thing'), isTrue, reason: 'still listed somewhere, not dropped');
  });

  _scenario('a bank row dated far in the future and one far in the past', (wc) {
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      _bank(addDays(wc.today(), 400), -5000, 'POS plaćanje', 'PBZ POS PBZ7SPAR FUTURE'),
      _bank('2001-01-01', -5000, 'POS plaćanje', 'PBZ POS PBZ7SPAR PAST'),
      _bank(wc.today(), 150000, 'Plaća/Mirovina', 'Neto placa synthetic'),
    ]));
  });

  _scenario('period start in the future', (wc) {
    wc.repo.updateSettings({'salary': 150000, 'rent': 50000, 'periodStart': addDays(wc.today(), 10)});
    wc.repo.addTransaction(date: wc.today(), amount: 1500, category: 'Groceries', note: 'Today thing');
  });

  _scenario('period start two years ago', (wc) {
    wc.repo.updateSettings({'salary': 150000, 'rent': 50000, 'periodStart': addDays(wc.today(), -730)});
    wc.repo.addTransaction(date: wc.today(), amount: 1500, category: 'Groceries', note: 'Today thing');
  });

  _scenario('salary smaller than rent + loan + subscriptions', (wc) {
    wc.repo.updateSettings({'salary': 50000, 'rent': 60000, 'loan': 30000, 'subs': 5000, 'salaryConfirmed': true});
    wc.repo.addTransaction(date: wc.today(), amount: 1500, category: 'Groceries', note: 'Today thing');
  });

  _scenario('odd goals: target 0, saved above target, monthly 0, empty name, huge target', (wc) {
    wc.repo.saveGoal(name: 'Zero target', target: 0, saved: 0, monthly: 0, sort: 1);
    wc.repo.saveGoal(name: 'Overfunded', target: 10000, saved: 25000, monthly: 5000, sort: 2);
    wc.repo.saveGoal(name: 'No monthly', target: 100000, saved: 100, monthly: 0, sort: 3);
    wc.repo.saveGoal(name: '', target: 5000, saved: 0, monthly: 5000, sort: 4);
    wc.repo.saveGoal(name: 'Huge', target: 100000000000, saved: 1, monthly: 1, sort: 5);
    wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true});
  }, check: (t, seen) {
    expect(_has(seen, 'Zero target'), isTrue);
    expect(_has(seen, 'Overfunded'), isTrue);
  });

  _scenario('odd wishes: price 0, empty name, huge price, added in the future, very long name', (wc) {
    wc.repo.addWish('Free thing', 0);
    wc.repo.addWish('', 1);
    wc.repo.addWish('Huge price', 100000000000);
    wc.repo.addWish('Long ${'name ' * 60}', 4500);
    final future = DateTime.now().millisecondsSinceEpoch + 10 * 24 * 3600000;
    wc.repo.applyRemote([
      Op('wish', 'wish-future', {'name': 'Clock skew', 'price': 3000, 'added': future, 'status': 'waiting', 'deleted': 0},
          Hlc(future, 0, 'peer').toString()),
    ]);
  }, check: (t, seen) => expect(_has(seen, RegExp(r'\d+d( \d+h)? left')), isTrue));

  _scenario('transfers and fees only (nothing is spending)', (wc) {
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      _bank(wc.today(), -10000, 'Prijenos', 'Prijenos na Revolut synthetic'),
      _bank(wc.today(), -150, 'Naknada', 'Naknada za vodjenje racuna'),
    ]));
  });

  testWidgets('a wallet with no key shows onboarding without errors on a narrow screen', (tester) async {
    final wc = emptyWallet(withKey: false);
    final seen = await _tour0(tester, wc);
    _expectClean(tester, seen);
  });
}

Future<Set<String>> _tour0(WidgetTester tester, WalletController wc) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(BudgetWalletApp(wc: wc));
  await tester.pump();
  return _texts(tester).toSet();
}
