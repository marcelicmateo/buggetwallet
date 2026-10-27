// Q3 × Q8: a synced IOU or repayment amount beyond the one cap is ignored like a wrong-typed field (found at the
// Stage Q merge: the IOU entities came after the cap table). All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

String _h(int millis) => Hlc(2000000000000 + millis, 0, 'peer').toString();

void main() {
  test('a synced IOU amount over the cap is ignored; at the cap it applies', () {
    final r = WalletRepo.inMemory();
    addTearDown(r.close);
    const base = {'person': 'Synthetic', 'direction': 'lent', 'amount': 1000, 'currency': 'EUR', 'date': '2026-03-01'};
    r.applyRemote([Op('iou', 'o1', base, _h(1))]);
    r.applyRemote([
      Op('iou', 'o1', {'amount': maxAmountCents + 1}, _h(2))
    ]);
    expect(r.ious().single.iou.amount, 1000);
    r.applyRemote([
      Op('iou', 'o1', {'amount': maxAmountCents}, _h(2))
    ]);
    expect(r.ious().single.iou.amount, maxAmountCents);
  });

  test('a synced repayment amount over the cap is ignored', () {
    final r = WalletRepo.inMemory();
    addTearDown(r.close);
    const base = {'person': 'Synthetic', 'direction': 'lent', 'amount': 1000, 'currency': 'EUR', 'date': '2026-03-01'};
    r.applyRemote([
      Op('iou', 'o1', base, _h(1)),
      Op('iou_part', 'r1', {'iou_id': 'o1', 'amount': 300, 'date': '2026-03-05'}, _h(1)),
      Op('iou_part', 'r1', {'amount': -maxAmountCents - 1}, _h(2)),
    ]);
    expect(r.ious().single.parts.single.amount, 300);
    expect(r.ious().single.outstanding, 700);
  });
}
