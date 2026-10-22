// The core surface after the Stage G clean-up: isIsoDate / requireIsoDate, PlannedCost.isBill, parseMoneyCents,
// BudgetKind, the renamed repo verbs. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  group('isIsoDate', () {
    test('accepts real calendar dates written YYYY-MM-DD only', () {
      expect(isIsoDate('2026-02-28'), isTrue);
      expect(isIsoDate('2024-02-29'), isTrue, reason: 'leap day');
      expect(isIsoDate('2026-02-30'), isFalse, reason: 'no such day');
      expect(isIsoDate('2026-13-01'), isFalse);
      expect(isIsoDate('2026-1-05'), isFalse, reason: 'not zero padded');
      expect(isIsoDate('26-01-05'), isFalse);
      expect(isIsoDate('2026-01-05T00:00'), isFalse);
      expect(isIsoDate(''), isFalse);
      expect(isIsoDate('bad'), isFalse);
    });

    test('requireIsoDate throws ArgumentError for anything else and the repo writes use it', () {
      expect(() => requireIsoDate('2026-02-30'), throwsArgumentError);
      expect(() => requireIsoDate('2026-02-27'), returnsNormally);
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      expect(() => r.markReviewDone('2026-02-30'), throwsArgumentError);
      expect(() => r.refreshRecurring('nope'), throwsArgumentError);
      expect(() => backupFileName('2026-02-30'), throwsArgumentError);
    });
  });

  group('PlannedCost.isBill', () {
    test('true only for a bill source with a ref', () {
      const base = PlannedCost(id: 'p', title: 't', date: '2026-01-05');
      expect(base.isBill, isFalse);
      expect(const PlannedCost(id: 'p', title: 't', date: '2026-01-05', source: PlannedSource.bill, sourceRef: 'b1').isBill, isTrue);
      expect(const PlannedCost(id: 'p', title: 't', date: '2026-01-05', source: PlannedSource.bill).isBill, isFalse);
      expect(const PlannedCost(id: 'p', title: 't', date: '2026-01-05', source: PlannedSource.calendar, sourceRef: 'x').isBill, isFalse);
    });

    test('the repo marks a confirmed bill\'s planned row as a bill', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final (id, _) = r.importBill(
          const NormalizedBill(source: BillSource.manual, date: '2026-01-05', dueDate: '2099-01-05', total: 1250, payee: 'Synthetic'));
      r.updateBill(id, category: 'Home');
      r.confirmBill(id);
      final rows = r.plannedCosts(includeClosed: true);
      expect(rows.where((p) => p.isBill).map((p) => p.id), [WalletRepo.billPlannedId(id)]);
      r.addPlanned(title: 'Not a bill', date: '2026-01-07', amount: 100);
      expect(r.plannedCosts().where((p) => !p.isBill).single.title, 'Not a bill');
    });
  });

  group('parseMoneyCents', () {
    test('the app input rule: decimals, thousands groups, signs and currency marks', () {
      expect(parseMoneyCents('12'), 1200);
      expect(parseMoneyCents('12.5'), 1250);
      expect(parseMoneyCents('12,50'), 1250);
      expect(parseMoneyCents('1.234,56'), 123456);
      expect(parseMoneyCents('1,234.56'), 123456);
      expect(parseMoneyCents('1,234'), 123400, reason: 'three digits after a comma group thousands');
      expect(parseMoneyCents(' 80 € '), 8000);
      expect(parseMoneyCents('\$0.10'), 10);
      expect(parseMoneyCents('.5'), 50);
      expect(parseMoneyCents('0'), 0);
      expect(parseMoneyCents('-0'), 0);
      expect(parseMoneyCents('+7'), 700);
      expect(parseMoneyCents('0.005'), 1, reason: 'rounded to the cent');
      expect(parseMoneyCents('0.004'), 0);
    });

    test('null for what is not an amount: blank, negative, exponent, a zero thousands group, beyond the cap', () {
      expect(parseMoneyCents(''), isNull);
      expect(parseMoneyCents('abc'), isNull);
      expect(parseMoneyCents('-5'), isNull);
      expect(parseMoneyCents('1e3'), isNull);
      expect(parseMoneyCents('0,005'), isNull);
      expect(parseMoneyCents('1.2.3'), isNull);
      expect(parseMoneyCents('${maxAmountCents ~/ 100}'), maxAmountCents);
      expect(parseMoneyCents('${maxAmountCents ~/ 100 + 1}'), isNull);
      expect(parseMoneyCents('Infinity'), isNull);
    });
  });

  group('names', () {
    test('BudgetKind is the budget kind of a category; TxKind and UpcomingKind are others', () {
      expect(kindOf('Salary'), BudgetKind.income);
      expect(kindOf('Groceries'), BudgetKind.flex);
      expect(BudgetKind.values, hasLength(5));
      expect(TxKind.values, isNotEmpty);
      expect(UpcomingKind.values, isNotEmpty);
    });

    test('blob queue verbs: markBlobUploaded / markBlobDeleted', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final hash = 'a' * 64;
      r.putCachedBlob(hash, [1, 2, 3], queue: true);
      expect(r.queuedBlobs(), [hash]);
      r.markBlobUploaded(hash);
      expect(r.queuedBlobs(), isEmpty);
      r.db.execute('INSERT INTO blob_delete(hash) VALUES(?)', [hash]); // device-local queue, never synced
      expect(r.blobDeletes(), [hash]);
      r.markBlobDeleted(hash);
      expect(r.blobDeletes(), isEmpty);
    });
  });
}
