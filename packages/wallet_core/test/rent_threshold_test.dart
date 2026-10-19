// Bug 10: the rent cash threshold was hardcoded in categories.dart. It is now the synced setting
// `rentCashThreshold` (minor units, default 50000). All data is SYNTHETIC.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

Tx _atm(int cents) => Tx(id: 'atm$cents', source: 'pbz', date: '2026-01-10', amount: cents, bankType: 'Isplata ATM', description: 'ATM');

void main() {
  group('rentCashThreshold setting', () {
    test('default is 50000 and keeps the old rule', () {
      expect(const WalletSettings().rentCashThreshold, 50000);
      expect(WalletSettings.fromMap(const {}).rentCashThreshold, 50000);
      final cz = Categorizer();
      expect(cz.categoryOf(_atm(-50000)), 'Rent');
      expect(cz.categoryOf(_atm(-49999)), 'Cash');
    });

    test('round-trips through toMap/fromMap', () {
      final s = WalletSettings.fromMap(const {'rentCashThreshold': 30000});
      expect(s.rentCashThreshold, 30000);
      expect(WalletSettings.fromMap(s.toMap()).rentCashThreshold, 30000);
    });

    test('changing it changes which ATM withdrawal is rent', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-01-15', -55000, 'Isplata ATM', 'ATM ONE'),
        n('2026-01-16', -30000, 'Isplata ATM', 'ATM TWO'),
      ]));
      Map<int, String> cats() => {for (final t in r.transactions()) t.amount: r.categorizer().categoryOf(t)};
      expect(cats(), {-55000: 'Rent', -30000: 'Cash'});
      r.updateSettings({'rentCashThreshold': 30000});
      expect(cats(), {-55000: 'Rent', -30000: 'Rent'});
      r.updateSettings({'rentCashThreshold': 60000});
      expect(cats(), {-55000: 'Cash', -30000: 'Cash'});
      r.updateSettings({'rentCashThreshold': 0});
      expect(cats(), {-55000: 'Cash', -30000: 'Cash'}, reason: '0 turns the rule off');
    });

    test('a manual category still wins over the threshold', () {
      const t = Tx(id: 'x', source: 'pbz', date: '2026-01-10', amount: -90000, bankType: 'Isplata ATM', category: 'Cash');
      expect(Categorizer(rentCashThreshold: 10000).categoryOf(t), 'Cash');
    });

    test('syncs to a second device', () async {
      final dir = Directory.systemTemp.createTempSync('bw-rent-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final key = VaultKey.generate();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      final batch = ImportBatch(source: 'pbz', transactions: [n('2026-01-16', -30000, 'Isplata ATM', 'ATM TWO')]);
      a.importBatch(batch);
      b.importBatch(batch);
      expect(b.categorizer().categoryOf(b.transactions().single), 'Cash');
      a.updateSettings({'rentCashThreshold': 25000});
      await FolderSync(dir.path, key).run(a);
      await FolderSync(dir.path, key).run(b);
      expect(b.settings().rentCashThreshold, 25000);
      expect(b.categorizer().categoryOf(b.transactions().single), 'Rent');
    });
  });
}
