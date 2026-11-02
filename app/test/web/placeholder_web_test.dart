// The controller holds a throwaway database while no wallet is open (first run, locked, another tab). On the web it must come
// from the loaded sqlite3.wasm: `WalletRepo.inMemory()` throws there, which left the app blank on a fresh browser.
// Real sqlite3mc.wasm (fetched by make as test/sqlite3.wasm). SYNTHETIC data.
@TestOn('browser')
library;

import 'package:budget_wallet/src/wallet_db_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  test('after claimWalletDb the placeholder repo works like an empty wallet and takes writes', () async {
    sqliteWasmUri = Uri.parse('/sqlite3.wasm');
    await claimWalletDb();
    final repo = placeholderRepo();
    expect(repo.isEmpty, isTrue);
    repo.addTransaction(date: '2026-10-01', amount: -1250, category: 'Groceries');
    expect(repo.transactions(), hasLength(1));
    repo.close();
    // Nothing of it reached the browser's file system: no wallet.db exists, so the next start still says "no wallet".
    expect(await walletDbExists(), isFalse);
    // A second one (forget the browser, then back to the placeholder) is a new, empty database.
    final again = placeholderRepo();
    expect(again.isEmpty, isTrue);
    again.close();
  });
}
