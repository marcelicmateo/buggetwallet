// Stage N2 (spec §3, coordinator clarification 1): the subs suggestion. `suggestPlan(txs, st, today, confirmed: [...])`;
// only bills with `confirmed && category == 'Bills & subscriptions'` count, the evidence is the bill ids. Kept in its
// own file so a signature mismatch cannot hide the other suggestion tests. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

RecurringBill _bill(String payee, int cents, {String status = 'confirmed', String category = 'Bills & subscriptions'}) => RecurringBill(
      id: RecurringBill.idFor(payee),
      payee: payee,
      label: payee,
      category: category,
      expectedAmount: cents,
      nextDue: '2026-11-01',
      status: status,
    );

void main() {
  const today = '2026-10-25';
  const st = WalletSettings();

  test('no bills: null', () {
    expect(suggestPlan(const [], st, today).subs, isNull);
    expect(suggestPlan(const [], st, today, confirmed: const []).subs, isNull);
  });

  test('sum of the confirmed bills in Bills & subscriptions; evidence = bill ids', () {
    final s = suggestPlan(const [], st, today, confirmed: [_bill('streamco', 1299), _bill('phonecom', 2500)]).subs!;
    expect(s.value, 3799);
    expect(s.basis, 'confirmedBills');
    expect(s.evidence.toSet(), {'rec:streamco', 'rec:phonecom'});
  });

  test('candidates, dismissed bills and bills in other categories are left out', () {
    final s = suggestPlan(const [], st, today,
        confirmed: [
          _bill('streamco', 1299),
          _bill('maybe', 5000, status: 'candidate'),
          _bill('nope', 7000, status: 'dismissed'),
          _bill('gym', 3000, category: 'Sport & fitness'),
          _bill('landlord', 40000, category: 'Rent'),
        ]).subs!;
    expect(s.value, 1299);
    expect(s.evidence, ['rec:streamco']);
  });

  test('only unconfirmed or other-category bills: null', () {
    final s = suggestPlan(const [], st, today,
        confirmed: [_bill('maybe', 5000, status: 'candidate'), _bill('gym', 3000, category: 'Sport & fitness')]);
    expect(s.subs, isNull);
  });

  test('planProposals turns the subs suggestion into a proposal against the setting', () {
    final s = suggestPlan(const [], st, today, confirmed: [_bill('streamco', 1299)]);
    final p = planProposals(s, const WalletSettings(subs: 1000)).single;
    expect((p.key, p.current, p.suggested, p.basis), ('subs', 1000, 1299, 'confirmedBills'));
    expect(planProposals(s, const WalletSettings(subs: 1299)), isEmpty);
  });
}
