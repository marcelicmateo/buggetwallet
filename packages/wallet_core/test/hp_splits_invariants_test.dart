// HP-T2: invariants pinned from mutation testing of repo_splits.dart. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;

import 'support/synthetic.dart';

Matcher _refusal(String text) => throwsA(isA<ArgumentError>().having((e) => e.message, 'message', text));

void main() {
  late WalletRepo r;
  setUp(() => r = WalletRepo.inMemory());
  tearDown(() => r.close());

  test('one-cent parts are real amounts: -3.00 splits into -0.01 and -2.99', () {
    final id = r.addTransaction(date: '2026-03-12', amount: 300, category: 'Shopping');
    r.setSplit(id, const [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -299, category: 'Shopping')]);
    expect(r.splitOf(id)!.map((p) => p.amount), [-1, -299]);
  });

  test('a zero part says so; the parts must add up exactly, to the cent', () {
    final id = r.addTransaction(date: '2026-03-12', amount: 300, category: 'Shopping');
    expect(() => r.setSplit(id, const [SplitPart(amount: 0, category: 'Groceries'), SplitPart(amount: -300, category: 'Shopping')]),
        _refusal('Every part needs an amount.'));
    expect(() => r.setSplit(id, const [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -298, category: 'Shopping')]),
        _refusal("The parts don't add up to the payment."));
    expect(() => r.setSplit(id, const [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -300, category: 'Shopping')]),
        _refusal("The parts don't add up to the payment."));
    expect(r.splitOf(id), isNull);
  });

  test('a 1-cent payment is not "0.00": it fails on the sum, not on the zero rule', () {
    final id = r.addTransaction(date: '2026-03-12', amount: 1, category: 'Shopping');
    expect(() => r.setSplit(id, const [SplitPart(amount: -1, category: 'Groceries'), SplitPart(amount: -1, category: 'Shopping')]),
        _refusal("The parts don't add up to the payment."));
  });

  test('a +1-cent income is not "0.00" either', () {
    final row = n('2026-03-12', 1, 'Ostalo', 'REFUND SYNTH');
    r.importBatch(ImportBatch(source: 'pbz', transactions: [row]));
    expect(() => r.setSplit(row.id, const [SplitPart(amount: 1, category: 'Shopping'), SplitPart(amount: 1, category: 'Groceries')]),
        _refusal("The parts don't add up to the payment."));
  });

  test('a part of the wrong sign is refused with the sign message', () {
    final id = r.addTransaction(date: '2026-03-12', amount: 300, category: 'Shopping');
    expect(() => r.setSplit(id, const [SplitPart(amount: 100, category: 'Groceries'), SplitPart(amount: -400, category: 'Shopping')]),
        _refusal('Every part of an expense is money out.'));
  });

  test('removeSplit writes once: a second call, and a call without a split, write nothing', () {
    final id = r.addTransaction(date: '2026-03-12', amount: 300, category: 'Shopping');
    final v0 = r.dataVersion;
    r.removeSplit(id);
    expect(r.dataVersion, v0, reason: 'no split: nothing written');
    r.setSplit(id, const [SplitPart(amount: -100, category: 'Groceries'), SplitPart(amount: -200, category: 'Shopping')]);
    final v1 = r.dataVersion;
    expect(v1, greaterThan(v0));
    r.removeSplit(id);
    final v2 = r.dataVersion;
    expect(v2, greaterThan(v1));
    expect(r.splitOf(id), isNull);
    final ops = r.pendingOps().length;
    r.removeSplit(id);
    expect(r.dataVersion, v2, reason: 'already removed: nothing written');
    expect(r.pendingOps().length, ops);
    // setting again undeletes it
    r.setSplit(id, const [SplitPart(amount: -100, category: 'Groceries'), SplitPart(amount: -200, category: 'Shopping')]);
    expect(r.splitOf(id), hasLength(2));
    expect(r.splits().keys, [id]);
  });
}
