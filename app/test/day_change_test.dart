// The app stays open over midnight: periods, months and panels must move on to the new day (month end and payday).
// The controller takes a clock; every date here is SYNTHETIC.
import 'dart:convert';
import 'dart:io';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/spending.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/wallet.dart';

/// A wallet on 31 Oct 2026 with a saved period start of 10 Oct, a salary on 10 Oct and the next one already
/// in the data for 1 Nov (it counts once the clock reaches that day). Move [clock] to change the day.
class _Clock {
  DateTime now = DateTime(2026, 10, 31, 22, 30);
  DateTime call() => now;
}

WalletController _wallet(_Clock clock) {
  final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: clock.call);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-10', 150000, 'Plaća/Mirovina', 'Neto placa synthetic'),
    syntheticTx('2026-10-20', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    syntheticTx('2026-11-01', 150000, 'Plaća/Mirovina', 'Neto placa synthetic two'),
    syntheticTx('2026-11-01', -1500, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
  ]));
  wc.repo.updateSettings({'salary': 150000, 'rent': 55000, 'loan': 25000, 'periodStart': '2026-10-10', 'salaryConfirmed': true});
  wc.reload();
  return wc;
}

/// The whole app (its wallet listener rebuilds HomeShell), at phone size.
Future<void> _pumpApp(WidgetTester t, WalletController wc) async {
  t.view.physicalSize = const Size(400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(BudgetWalletApp(wc: wc));
  await t.pump();
}

void main() {
  test('today() follows the clock', () {
    final clock = _Clock();
    final wc = _wallet(clock);
    expect(wc.today(), '2026-10-31');
    clock.now = DateTime(2026, 11, 1, 0, 5);
    expect(wc.today(), '2026-11-01');
  });

  test('period(), payPeriods() and spending() are recomputed after the date moves', () {
    final clock = _Clock();
    final wc = _wallet(clock);
    final period = wc.period(), periods = wc.payPeriods(), spending = wc.spending();
    expect(identical(wc.period(), period), isTrue, reason: 'same day: cached');
    expect(spending.month, '2026-10');
    expect(spending.months.last, '2026-10');
    expect(periods, hasLength(1));

    clock.now = DateTime(2026, 11, 1, 0, 5);
    expect(identical(wc.period(), period), isFalse);
    expect(wc.period().daysLeft, period.daysLeft - 1);
    expect(wc.spending().month, '2026-11');
    expect(wc.spending().months.last, '2026-11');
    expect(wc.spending().summary.out, 1500, reason: 'November spending counts');
    expect(wc.payPeriods(), hasLength(2), reason: 'the 1 Nov salary starts a new pay period');
  });

  test('latestBySource gives the newest date per bank, cached', () {
    final wc = _wallet(_Clock());
    expect(wc.latestBySource, {'pbz': '2026-11-01'});
    expect(identical(wc.latestBySource, wc.latestBySource), isTrue);
    expect(wc.deliveries, (0, 0));
  });

  test('a payday crossing: the new salary is offered once its day has come', () {
    final clock = _Clock();
    final wc = _wallet(clock);
    expect(wc.newPayday(wc.period().start), isNull);
    clock.now = DateTime(2026, 11, 1, 8);
    expect(wc.newPayday(wc.period().start), '2026-11-01');
  });

  test('cached values of an old day are dropped, not kept', () {
    final clock = _Clock();
    final wc = _wallet(clock);
    final first = wc.period();
    clock.now = DateTime(2026, 11, 1, 8);
    wc.period();
    clock.now = DateTime(2026, 10, 31, 23); // back to the first day (clock corrected)
    expect(identical(wc.period(), first), isFalse, reason: 'the entry of the first day was dropped when the day changed');
  });

  test('checkDay notifies once per new day and not on the same day', () {
    final clock = _Clock();
    final wc = _wallet(clock);
    var n = 0;
    wc.addListener(() => n++);
    wc.checkDay();
    expect(n, 0);
    clock.now = DateTime(2026, 10, 31, 23, 59);
    wc.checkDay();
    expect(n, 0, reason: 'same day');
    clock.now = DateTime(2026, 11, 1);
    wc.checkDay();
    expect(n, 1);
    wc.checkDay();
    expect(n, 1);
  });

  testWidgets('Spending shows the new month after a tab switch, without any data change', (t) async {
    final clock = _Clock();
    final wc = _wallet(clock);
    await pumpApp(t, HomeShell(wc: wc));
    await t.tap(find.text('Spending').last);
    await t.pump();
    expect(find.textContaining('October 2026: '), findsOneWidget);
    expect(find.byType(SpendingScreen), findsOneWidget);

    clock.now = DateTime(2026, 11, 1, 0, 5); // midnight passes while the app is open: nothing notifies
    await t.tap(find.text('Goals').last);
    await t.pump();
    await t.tap(find.text('Spending').last);
    await t.pump();
    expect(find.textContaining('November 2026: '), findsOneWidget);
    expect(find.textContaining('October 2026: '), findsNothing);
  });

  testWidgets('a new day shows on the open tab when the app resumes', (t) async {
    final clock = _Clock();
    final wc = _wallet(clock);
    await _pumpApp(t, wc);
    await t.tap(find.text('Spending').last);
    await t.pump();
    expect(find.textContaining('October 2026: '), findsOneWidget);

    clock.now = DateTime(2026, 11, 1, 6);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(find.textContaining('November 2026: '), findsOneWidget);
  });

  testWidgets('a payday crossing shows the new-month offer on Today when the day is checked', (t) async {
    final clock = _Clock();
    final wc = _wallet(clock);
    await _pumpApp(t, wc);
    expect(find.textContaining('Salary landed on'), findsNothing);
    clock.now = DateTime(2026, 11, 1, 0, 1);
    wc.checkDay();
    await t.pump();
    expect(find.textContaining('Salary landed on'), findsOneWidget);
  });

  group('a sync that fails partway', () {
    test('changes it already applied are shown (reload after the error)', () async {
      final wc = emptyWallet();
      wc.syncFolder = '/not-used-by-the-fake-sync';
      expect(wc.settings.rent, isNot(61000));
      final before = wc.dataVersion;
      wc.syncRunner = (folder, key, repo) async {
        // File A applied, then reading the folder failed.
        final now = DateTime.now().millisecondsSinceEpoch;
        repo.applyRemote([
          Op('setting', 'rent', {'value': jsonEncode(61000), 'deleted': 0}, Hlc(now + 60000, 0, 'peer').toString())
        ]);
        throw const FileSystemException('listing the folder failed');
      };
      await wc.syncNow();
      expect(wc.syncError, isNotNull);
      expect(wc.dataVersion, greaterThan(before));
      expect(wc.settings.rent, 61000);
    });

    test('a failure before anything is applied does not reload', () async {
      final wc = emptyWallet();
      wc.syncFolder = '/not-used-by-the-fake-sync';
      final before = wc.dataVersion;
      wc.syncRunner = (folder, key, repo) async => throw const SyncException('The sync folder is missing.');
      await wc.syncNow();
      expect(wc.syncError, isNotNull);
      expect(wc.dataVersion, before);
    });

    test('a file-system failure before anything is applied does not reload (no access, read-only mount)', () async {
      final wc = emptyWallet();
      wc.syncFolder = '/not-used-by-the-fake-sync';
      final before = wc.dataVersion;
      wc.syncRunner = (folder, key, repo) async => throw const FileSystemException('cannot read vault.json');
      await wc.syncNow();
      await wc.syncNow();
      expect(wc.syncError, isNotNull);
      expect(wc.dataVersion, before);
    });
  });

  test('a day change inside a computation does not store the old day\'s value under the new day', () {
    final clock = _Clock();
    final wc = _wallet(clock);
    // The date moves past midnight on the second read, while period() is computing (effectiveSettings asks for the day).
    var reads = 0;
    final racing = WalletController.forTest(wc.repo, key: VaultKey.generate(), clock: () {
      reads++;
      return reads > 1 ? DateTime(2026, 11, 1, 0, 0, 1) : DateTime(2026, 10, 31, 23, 59, 59);
    });
    racing.reload();
    reads = 0;
    final first = racing.period();
    expect(identical(racing.period(), first), isFalse, reason: 'the value computed across midnight must not be cached');
    final settled = racing.period();
    expect(identical(racing.period(), settled), isTrue);
    expect(racing.spending().month, '2026-11');
  });
}
