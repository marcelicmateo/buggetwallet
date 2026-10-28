// M1: invariants of repo_sync_apply.dart that survived mutation testing. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  group('syncOpsAfter: ops in recorded files above what the snapshot covers', () {
    test('a file counts only when its seq is strictly above the cover of its device', () {
      final repo = WalletRepo.inMemory();
      repo.recordSyncFile('dev', 3, 10);
      expect(repo.syncOpsAfter({'dev': 3}), 0); // covered exactly
      expect(repo.syncOpsAfter({'dev': 2}), 10);
      expect(repo.syncOpsAfter({'dev': 4}), 0);
    });
    test('a device missing from the covers covers nothing, even its seq 1', () {
      final repo = WalletRepo.inMemory();
      repo.recordSyncFile('a', 1, 7);
      repo.recordSyncFile('b', 2, 5);
      expect(repo.syncOpsAfter({}), 12);
      expect(repo.syncOpsAfter({'b': 2}), 7);
      expect(repo.syncOpsAfter({'a': 1, 'b': 1}), 5);
    });
  });

  group('isEmpty', () {
    test('false as soon as one row of any entity exists, true on a new wallet', () {
      final repo = WalletRepo.inMemory();
      expect(repo.isEmpty, isTrue);
      repo.addWish('Bike', 10000);
      expect(repo.isEmpty, isFalse);
    });
  });
}
