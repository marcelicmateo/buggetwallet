// HP-T2: invariants pinned from mutation testing of transfers. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

Tx _t(String id, String date, int amount, {String source = 'pbz', bool own = true, String currency = 'EUR'}) =>
    Tx(id: id, source: source, date: date, amount: amount, currency: currency, kindHint: own ? TxKind.ownTransfer : null, bankType: 'x');

void main() {
  group('openTransfers', () {
    test('zero amounts and 1-cent rows: zero is never open, one cent is', () {
      final open = openTransfers([_t('z', '2026-03-10', 0), _t('p', '2026-03-10', 1), _t('n', '2026-03-10', -1, source: 'rev')]);
      expect(open.map((t) => t.id), ['p', 'n']);
    });
  });

  group('planTransfers', () {
    test('1-cent transfer pairs (amount 1 is an inflow)', () {
      final p = planTransfers([_t('o', '2026-03-10', -1), _t('i', '2026-03-10', 1, source: 'rev')]);
      expect(p.transferTo, {'o': 'i', 'i': 'o'});
      expect(p.paired, 1);
    });

    test('older outflow (by date, not id) takes the only inflow', () {
      final p = planTransfers([
        _t('a', '2026-03-12', -5000),
        _t('z', '2026-03-10', -5000),
        _t('i', '2026-03-11', 5000, source: 'rev'),
      ]);
      expect(p.transferTo['z'], 'i');
      expect(p.transferTo['i'], 'z');
      expect(p.transferTo.containsKey('a'), isFalse);
      expect(p.paired, 1);
    });

    test('same date outflows: smallest id first', () {
      final p = planTransfers([
        _t('z', '2026-03-10', -5000),
        _t('a', '2026-03-10', -5000),
        _t('i', '2026-03-10', 5000, source: 'rev'),
      ]);
      expect(p.transferTo['a'], 'i');
      expect(p.transferTo.containsKey('z'), isFalse);
    });

    test('three days apart pairs, four does not, either way in time', () {
      for (final d in ['2026-03-13', '2026-03-07']) {
        expect(planTransfers([_t('o', '2026-03-10', -5000), _t('i', d, 5000, source: 'rev')]).paired, 1, reason: d);
      }
      for (final d in ['2026-03-14', '2026-03-06']) {
        expect(planTransfers([_t('o', '2026-03-10', -5000), _t('i', d, 5000, source: 'rev')]).isEmpty, isTrue, reason: d);
      }
    });

    test('equally far inflows: earlier date first, then smaller id, in any list order', () {
      final out = _t('o', '2026-03-10', -5000);
      for (final ins in [
        [_t('z', '2026-03-08', 5000, source: 'rev'), _t('a', '2026-03-12', 5000, source: 'rev')],
        [_t('a', '2026-03-12', 5000, source: 'rev'), _t('z', '2026-03-08', 5000, source: 'rev')],
      ]) {
        expect(planTransfers([out, ...ins]).transferTo['o'], 'z');
      }
      for (final ins in [
        [_t('b1', '2026-03-11', 5000, source: 'rev'), _t('b2', '2026-03-11', 5000, source: 'rev')],
        [_t('b2', '2026-03-11', 5000, source: 'rev'), _t('b1', '2026-03-11', 5000, source: 'rev')],
      ]) {
        expect(planTransfers([out, ...ins]).transferTo['o'], 'b1');
      }
      // closer beats earlier
      expect(planTransfers([out, _t('z', '2026-03-08', 5000, source: 'rev'), _t('a', '2026-03-11', 5000, source: 'rev')]).transferTo['o'],
          'a');
    });

    test('never on amount alone: unhinted pair, same source, other currency, other amount', () {
      expect(planTransfers([_t('o', '2026-03-10', -5000, own: false), _t('i', '2026-03-10', 5000, source: 'rev', own: false)]).isEmpty,
          isTrue);
      expect(planTransfers([_t('o', '2026-03-10', -5000), _t('i', '2026-03-10', 5000)]).isEmpty, isTrue);
      expect(planTransfers([_t('o', '2026-03-10', -5000), _t('i', '2026-03-10', 5000, source: 'rev', currency: 'USD')]).isEmpty, isTrue);
      expect(planTransfers([_t('o', '2026-03-10', -5000), _t('i', '2026-03-10', 5001, source: 'rev')]).isEmpty, isTrue);
    });

    test('one hinted side is enough in the second pass, but a both-hinted pair wins the inflow first', () {
      final p = planTransfers([
        _t('a', '2026-03-10', -5000, own: false), // unhinted card payment, would be the smaller id
        _t('b', '2026-03-10', -5000), // hinted
        _t('i', '2026-03-10', 5000, source: 'rev'),
      ]);
      expect(p.transferTo, {'b': 'i', 'i': 'b'});
      final q = planTransfers([_t('o', '2026-03-10', -5000, own: false), _t('i', '2026-03-10', 5000, source: 'rev')]);
      expect(q.transferTo, {'o': 'i', 'i': 'o'}, reason: 'the inflow carries the hint');
    });

    test('a stale link is cleared when no partner is found; a holding link is left alone', () {
      final holding = [
        const Tx(id: 'o', source: 'pbz', date: '2026-03-10', amount: -5000, kindHint: TxKind.ownTransfer, transferTo: 'i'),
        const Tx(id: 'i', source: 'rev', date: '2026-03-10', amount: 5000, transferTo: 'o'),
      ];
      expect(planTransfers(holding).isEmpty, isTrue);
      final stale = [
        holding[0],
        const Tx(id: 'i', source: 'rev', date: '2026-03-10', amount: 5000, transferTo: 'o', deleted: true),
      ];
      final p = planTransfers(stale);
      expect(p.transferTo, {'o': null});
      expect(p.reopened, 1);
      expect(p.paired, 0);
      // partner not here yet: keep
      expect(planTransfers([holding[0]]).isEmpty, isTrue);
    });
  });
}
