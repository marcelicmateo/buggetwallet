// Stage Q3 spec tests (docs/context/STAGE_Q_PLAN.md): amounts beyond the cap are refused at every entry point, and the worst
// case of summing capped amounts stays below 2^53. Written from the spec only. SYNTHETIC data.
// API relied on: isSafeCents(int), maxAmountCents, ImportSummary.tooLarge, addTransaction (ArgumentError over the cap),
// applyRemote quarantining an over-cap integer amount column like a wrong-type value.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

void main() {
  late WalletRepo r;
  setUp(() => r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch));
  tearDown(() => r.close());

  group('isSafeCents', () {
    test('the cap itself is safe in both signs; one cent more is not', () {
      expect(isSafeCents(maxAmountCents), isTrue);
      expect(isSafeCents(-maxAmountCents), isTrue);
      expect(isSafeCents(maxAmountCents + 1), isFalse);
      expect(isSafeCents(-maxAmountCents - 1), isFalse);
    });
    test('zero and ordinary amounts are safe; huge values are not', () {
      expect(isSafeCents(0), isTrue);
      expect(isSafeCents(-1250), isTrue);
      expect(isSafeCents(1 << 53), isFalse);
      expect(isSafeCents(-(1 << 53)), isFalse);
      expect(isSafeCents(9223372036854775807), isFalse);
      expect(isSafeCents(-9223372036854775808), isFalse);
    });
  });

  group('addTransaction', () {
    test('accepts exactly the cap in both signs', () {
      r.addTransaction(date: '2026-03-01', amount: maxAmountCents, category: 'Salary');
      r.addTransaction(date: '2026-03-02', amount: -maxAmountCents, category: 'Groceries');
      expect(r.transactions(includeHidden: true), hasLength(2));
    });
    test('refuses one cent over, in both signs, and writes nothing', () {
      expect(() => r.addTransaction(date: '2026-03-01', amount: maxAmountCents + 1, category: 'Salary'), throwsArgumentError);
      expect(() => r.addTransaction(date: '2026-03-01', amount: -maxAmountCents - 1, category: 'Groceries'), throwsArgumentError);
      expect(() => r.addTransaction(date: '2026-03-01', amount: 1 << 62, category: 'Groceries'), throwsArgumentError);
      expect(r.transactions(includeHidden: true), isEmpty);
    });
  });

  group('importBatch', () {
    test('rows over the cap are skipped and counted in tooLarge; the others import', () {
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-03-01', -1250, 'POS plaćanje', 'Synth Cafe'),
        n('2026-03-02', maxAmountCents + 1, 'Ostalo', 'Synth huge in'),
        n('2026-03-03', -maxAmountCents - 1, 'Ostalo', 'Synth huge out'),
        n('2026-03-04', maxAmountCents, 'Ostalo', 'Synth at cap in'),
        n('2026-03-05', -maxAmountCents, 'Ostalo', 'Synth at cap out'),
      ]));
      expect(s.tooLarge, 2);
      expect(s.added, 3);
      expect(r.transactions(includeHidden: true).map((t) => t.amount), unorderedEquals([-1250, maxAmountCents, -maxAmountCents]));
    });
    test('a batch of only over-cap rows adds nothing; a clean batch reports tooLarge 0', () {
      final bad = r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-03-02', 1 << 60, 'Ostalo', 'Synth huge')]));
      expect(bad.added, 0);
      expect(bad.tooLarge, 1);
      final ok = r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-03-06', -100, 'POS plaćanje', 'Synth Shop')]));
      expect(ok.tooLarge, 0);
    });
    test('importing the same over-cap row again is again skipped, never stored', () {
      final b = ImportBatch(source: 'pbz', transactions: [n('2026-03-02', maxAmountCents + 1, 'Ostalo', 'Synth huge')]);
      r.importBatch(b);
      expect(r.importBatch(b).tooLarge, 1);
      expect(r.transactions(includeHidden: true), isEmpty);
    });
  });

  group('sync: a synced amount is accepted up to legacyRowCapCents (10^12); beyond it the field is quarantined', () {
    const hlc = '001768035600000:00001:peer0001';
    Op tx(String id, int amount) =>
        Op('tx', id, {'amount': amount, 'date': '2026-03-01', 'description': 'synthetic', 'source': 'pbz'}, hlc);

    test('a value between the local cap and the legacy cap still applies (an older build could have written it)', () {
      r.applyRemote([tx('peer-1', maxAmountCents + 1), tx('peer-2', -maxAmountCents - 1)]);
      expect(r.transaction('peer-1')!.amount, maxAmountCents + 1);
      expect(r.transaction('peer-2')!.amount, -maxAmountCents - 1);
    });
    test('exactly the legacy cap applies, both signs', () {
      r.applyRemote([tx('peer-3', legacyRowCapCents), tx('peer-4', -legacyRowCapCents)]);
      expect(r.transaction('peer-3')!.amount, legacyRowCapCents);
      expect(r.transaction('peer-4')!.amount, -legacyRowCapCents);
    });
    test('one cent beyond the legacy cap, and huge values, are not applied; the op\'s other fields are', () {
      r.applyRemote([tx('peer-5', legacyRowCapCents + 1), tx('peer-6', -legacyRowCapCents - 1), tx('peer-7', 9007199254740991)]);
      for (final id in ['peer-5', 'peer-6', 'peer-7']) {
        final t = r.transaction(id);
        expect(t?.amount.abs() ?? 0, lessThanOrEqualTo(legacyRowCapCents), reason: id);
        expect(t?.amount ?? 0, 0, reason: '$id: the amount field is ignored, never stored');
      }
    });
  });

  test('worst case: many rows at the cap sum below 2^53', () {
    expect((1 << 53) ~/ maxAmountCents, greaterThan(50000), reason: 'a lifetime of rows must fit');
    for (var i = 0; i < 200; i++) {
      r.addTransaction(date: '2026-03-01', amount: maxAmountCents, category: 'Groceries'); // positive = money spent
    }
    final cz = r.categorizer();
    final m = monthSummary([for (final t in r.transactions()) cz.categorize(t)], '2026-03', currency: 'EUR');
    expect(m.out, 200 * maxAmountCents);
    expect(m.out, lessThan(1 << 53));
  });
}
