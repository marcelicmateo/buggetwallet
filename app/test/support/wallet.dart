// SYNTHETIC wallets for widget tests. Made-up amounts; merchants are well-known chains or generic names.
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
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
