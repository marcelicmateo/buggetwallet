// The controller caches derived values per data version, and a tab switch does not rebuild the other tabs.
import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

void main() {
  test('period, payPeriods and spending are computed once per data change', () {
    final wc = demoWallet();
    final p = wc.period();
    expect(identical(wc.period(), p), isTrue);
    final periods = wc.payPeriods(count: 12);
    expect(identical(wc.payPeriods(count: 12), periods), isTrue);
    final s = wc.spending();
    expect(identical(wc.spending(), s), isTrue);
    expect(s.month, wc.today().substring(0, 7));
    expect(s.months.length, 13);
    expect(identical(wc.spending('not-a-month'), s), isTrue, reason: 'an unknown month falls back to this month');

    wc.addExpense(amount: -500, category: 'Groceries', note: 'x', date: wc.today());
    expect(identical(wc.period(), p), isFalse, reason: 'new data: recomputed');
    expect(identical(wc.spending(), s), isFalse);
    expect(wc.spending().transactions.length, s.transactions.length + 1);
  });

  testWidgets('switching tabs keeps the other pages as they are', (t) async {
    final wc = demoWallet();
    await pumpApp(t, HomeShell(wc: wc));
    final spending = t.widget<SpendingScreen>(find.byType(SpendingScreen, skipOffstage: false));
    await t.tap(find.text('Spending').last);
    await t.pump();
    expect(identical(t.widget<SpendingScreen>(find.byType(SpendingScreen)), spending), isTrue);
    expect(find.byType(TodayScreen), findsNothing);
    await t.tap(find.text('Today').last);
    await t.pump();
    expect(find.byType(TodayScreen), findsOneWidget);
  });
}
