// Stage I (I8): WalletRepo.isWriteError marks what leaves a rolled-back write, so the app can say "Couldn't save".
// SYNTHETIC data only.
import 'package:sqlite3/common.dart' show SqliteException;
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  test('an error out of a rolled-back write is marked, nothing is saved', () {
    final repo = WalletRepo.inMemory();
    repo.db.execute("CREATE TEMP TRIGGER bw_fail BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'disk full'); END");
    Object? caught;
    try {
      repo.addTransaction(date: '2026-03-04', amount: -1250, category: 'Groceries');
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<SqliteException>());
    expect(WalletRepo.isWriteError(caught!), isTrue);
    expect(repo.transactions(), isEmpty, reason: 'rolled back');
  });

  test('a write SQLite already rolled back itself keeps its own error and its mark', () {
    final repo = WalletRepo.inMemory();
    // RAISE(ROLLBACK) ends the transaction inside SQLite, as SQLITE_FULL or IOERR can: a second ROLLBACK would throw.
    repo.db.execute("CREATE TEMP TRIGGER bw_fail BEFORE INSERT ON outbox BEGIN SELECT RAISE(ROLLBACK, 'disk full'); END");
    Object? caught;
    try {
      repo.addTransaction(date: '2026-03-04', amount: -1250, category: 'Groceries');
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<SqliteException>());
    expect((caught as SqliteException).message, contains('disk full'), reason: 'the original error, not the ROLLBACK one');
    expect(WalletRepo.isWriteError(caught), isTrue);
    expect(repo.db.autocommit, isTrue);
    expect(repo.transactions(), isEmpty);
  });

  test('a failed read and an unrelated error are not marked', () {
    final repo = WalletRepo.inMemory();
    repo.db.execute('DROP TABLE goals');
    Object? caught;
    try {
      repo.goals();
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<SqliteException>());
    expect(WalletRepo.isWriteError(caught!), isFalse);
    expect(WalletRepo.isWriteError(SqliteException(extendedResultCode: 1, message: 'x')), isFalse);
    expect(WalletRepo.isWriteError(StateError('x')), isFalse);
  });
}
