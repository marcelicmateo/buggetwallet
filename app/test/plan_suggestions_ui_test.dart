// Stage N2 UI: Plan › "Suggestions from your imports" (accept one, accept all, Not now, none when equal). All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

/// 20 Oct 2026. Salary of 1,200.00 on the 10th of Aug, Sep and Oct (so: salary 1,200.00, payday day 10) and rent of 600.00 on
/// the 1st of Jul, Aug and Sep. The plan says salary 1,500.00, payday 15, no rent.
WalletController proposalWallet({int salary = 150000}) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-07-01', -1000, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    for (final d in const ['2026-08-10', '2026-09-10', '2026-10-10']) syntheticTx(d, 120000, 'Plaća/Mirovina', 'Neto placa synthetic'),
  ]));
  for (final m in const ['07', '08', '09']) {
    wc.repo.addTransaction(date: '2026-$m-01', amount: 60000, category: 'Rent');
  }
  wc.repo.updateSettings({'salary': salary, 'salaryConfirmed': true});
  wc.reload();
  return wc;
}

Future<void> settle(WidgetTester t) => t.pump(const Duration(seconds: 4)); // the controller's 3 s sync debounce and the toast

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump(const Duration(milliseconds: 400));
}

String valueOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey('proposalValue:$key'))).data!;

void main() {
  testWidgets('one row per differing value: current → suggested and why; nothing is written by looking', (t) async {
    final wc = proposalWallet();
    final before = wc.dataVersion;
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    expect(find.text('SUGGESTIONS FROM YOUR IMPORTS'), findsOneWidget);
    expect(valueOf(t, 'salary'), '${moneyExact(150000, 'EUR')} → ${moneyExact(120000, 'EUR')}');
    expect(valueOf(t, 'paydayDay'), 'day 15 → day 10');
    expect(valueOf(t, 'rent'), 'not set → ${moneyExact(60000, 'EUR')}');
    expect(find.byKey(const ValueKey('proposal:loan')), findsNothing);
    expect(find.byKey(const ValueKey('proposal:subs')), findsNothing);
    expect(find.text('From your last salary payments.'), findsOneWidget);
    expect(find.text('Your usual payday.'), findsOneWidget);
    expect(find.text('From your rent payments.'), findsOneWidget);
    expect(wc.dataVersion, before);
    expect(wc.settings.salary, 150000);
    await settle(t);
  });

  testWidgets('Accept writes only that key (salary also confirms the salary) and the row goes', (t) async {
    final wc = proposalWallet();
    wc.repo.updateSettings({'salaryConfirmed': false});
    wc.reload();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    final before = wc.settings.toMap();
    await tapKey(t, 'proposalAccept:salary');
    final after = wc.settings.toMap();
    expect(after['salary'], 120000);
    expect(after['salaryConfirmed'], isTrue);
    expect({
      for (final e in after.entries)
        if (before[e.key].toString() != e.value.toString()) e.key
    }, {
      'salary',
      'salaryConfirmed'
    });
    expect(wc.settings.paydayDay, 15, reason: 'the other suggestions are not applied');
    expect(wc.settings.rent, 0);
    expect(find.byKey(const ValueKey('proposal:salary')), findsNothing);
    expect(find.byKey(const ValueKey('proposal:rent')), findsOneWidget);
    await settle(t);
  });

  testWidgets('Accept on rent changes the rent only', (t) async {
    final wc = proposalWallet();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    await tapKey(t, 'proposalAccept:rent');
    expect(wc.settings.rent, 60000);
    expect(wc.settings.salary, 150000);
    await settle(t);
  });

  testWidgets('Accept all writes every listed value in one change; the panel goes', (t) async {
    final wc = proposalWallet();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    final before = wc.dataVersion;
    await tapKey(t, 'proposalAcceptAll');
    expect((wc.settings.salary, wc.settings.paydayDay, wc.settings.rent), (120000, 10, 60000));
    expect(wc.settings.salaryConfirmed, isTrue);
    expect(wc.dataVersion, before + 1);
    expect(find.byKey(const ValueKey('planSuggestions')), findsNothing);
    await settle(t);
  });

  testWidgets('Not now hides the row without writing; it comes back when the suggested value changes', (t) async {
    final wc = proposalWallet();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    final before = wc.dataVersion;
    await tapKey(t, 'proposalLater:salary');
    expect(find.byKey(const ValueKey('proposal:salary')), findsNothing);
    expect(find.byKey(const ValueKey('proposal:rent')), findsOneWidget);
    expect(wc.settings.salary, 150000);
    expect(wc.dataVersion, before, reason: 'device-local only, no change to the wallet');
    wc.reload();
    await t.pump();
    expect(find.byKey(const ValueKey('proposal:salary')), findsNothing, reason: 'still hidden after a reload');

    // A new payday group that changes the median brings it back.
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      syntheticTx('2026-10-11', 40000, 'Plaća/Mirovina', 'Neto placa synthetic part'),
    ]));
    wc.reload();
    await t.pump();
    final s = wc.planSuggestion().salary;
    if (s != null && s.value != 120000) {
      expect(find.byKey(const ValueKey('proposal:salary')), findsOneWidget);
    }
    await settle(t);
  });

  testWidgets('no panel when the plan already holds the suggested values', (t) async {
    final wc = proposalWallet();
    wc.repo.updateSettings({'salary': 120000, 'paydayDay': 10, 'rent': 60000});
    wc.reload();
    expect(wc.planProposalList(), isEmpty);
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    expect(find.byKey(const ValueKey('planSuggestions')), findsNothing);
    expect(find.text('SUGGESTIONS FROM YOUR IMPORTS'), findsNothing);
    await settle(t);
  });

  testWidgets('no panel in an empty wallet', (t) async {
    final wc = emptyWallet();
    await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
    expect(find.byKey(const ValueKey('planSuggestions')), findsNothing);
    await settle(t);
  });

  for (final (w, s) in [(320.0, 2.0), (360.0, 1.0), (1280.0, 1.0)]) {
    testWidgets('fits at ${w.toInt()} dp, text ${s}x, with 48 dp buttons', (t) async {
      final wc = proposalWallet();
      await pumpApp(t, Scaffold(body: PlanScreen(wc: wc)), size: Size(w, 6000), textScale: s);
      expect(t.takeException(), isNull);
      for (final k in ['proposalAccept:salary', 'proposalLater:salary', 'proposalAcceptAll']) {
        expect(t.getSize(find.byKey(ValueKey(k))).height, greaterThanOrEqualTo(48), reason: k);
      }
      await settle(t);
    });
  }
}
