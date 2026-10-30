// HP-T2: invariants pinned from mutation testing of matching and transfers. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/matching.dart' show matchDays;
import 'package:wallet_core/wallet_core.dart';

String _h(int millis, [String node = 'n', int counter = 0]) => Hlc(millis, counter, node).toString();

Tx _manual(String id, String date, int amount, {String? to, String? category = 'Eating out'}) =>
    Tx(id: id, source: 'manual', date: date, amount: amount, manual: true, matchedTo: to, category: category);
Tx _bank(String id, String date, int amount, {String? category}) =>
    Tx(id: id, source: 'pbz', date: date, amount: amount, bankType: 'POS plaćanje', description: 'POS EXAMPLE', category: category);
bool _all(Tx _) => true;

void main() {
  group('MatchPlan / SeenBank', () {
    test('isEmpty needs both maps empty', () {
      expect(const MatchPlan({}, {}, 0).isEmpty, isTrue);
      expect(const MatchPlan({'m': null}, {}, 0).isEmpty, isFalse);
      expect(const MatchPlan({}, {'b': 'Eating out'}, 0).isEmpty, isFalse);
      expect(const MatchPlan({'m': 'b'}, {'b': 'x'}, 1).isEmpty, isFalse);
    });

    test('matchDays is 3: a bank row 3 days away replaces the entry, 4 days does not', () {
      final w = {'m': _h(100), 'b': _h(1000)};
      expect(matchDays, 3);
      expect(planMatches([_manual('m', '2026-03-10', -990)], [_bank('b', '2026-03-13', -990)], _all, w).matchedTo, {'m': 'b'});
      expect(planMatches([_manual('m', '2026-03-10', -990)], [_bank('b', '2026-03-07', -990)], _all, w).matchedTo, {'m': 'b'});
      expect(planMatches([_manual('m', '2026-03-10', -990)], [_bank('b', '2026-03-14', -990)], _all, w).isEmpty, isTrue);
      expect(planMatches([_manual('m', '2026-03-10', -990)], [_bank('b', '2026-03-06', -990)], _all, w).isEmpty, isTrue);
    });

    test('recorded: a valid seen_bank value is recorded, null or damaged falls back', () {
      final e = _h(500);
      expect(SeenBank.of(e, null).recorded, isFalse);
      expect(SeenBank.of(e, SeenBank.encode([_h(100)])).recorded, isTrue);
      expect(SeenBank.of(e, SeenBank.encode([])).recorded, isTrue);
      expect(SeenBank.of(e, 'not json').recorded, isFalse);
      expect(SeenBank.of(e, '{"a":1}').recorded, isFalse);
    });

    test('fallback: a bank row written exactly at the entry clock was not unseen; strictly later is', () {
      final e = _h(500, 'a');
      final s = SeenBank.of(e, null);
      expect(s.unseen(e), isFalse);
      expect(s.unseen(_h(499, 'a')), isFalse);
      expect(s.unseen(_h(500, 'a', 1)), isTrue);
      expect(s.unseen(_h(501, 'a')), isTrue);
    });

    test('recorded: per node the highest clock counts, wherever it sits in the list', () {
      final e = _h(500);
      for (final list in [
        [_h(100, 'x'), _h(300, 'x')],
        [_h(300, 'x'), _h(100, 'x')],
      ]) {
        final s = SeenBank.of(e, '[${list.map((v) => '"$v"').join(',')}]');
        expect(s.unseen(_h(300, 'x')), isFalse, reason: '$list');
        expect(s.unseen(_h(200, 'x')), isFalse, reason: '$list');
        expect(s.unseen(_h(301, 'x')), isTrue, reason: '$list');
        expect(s.unseen(_h(1, 'other')), isTrue, reason: 'a node not listed was not on the device');
      }
    });

    test('the oldest entry (date, not id) takes the only bank row', () {
      final w = {'z': _h(100), 'a': _h(101), 'b': _h(1000)};
      final p =
          planMatches([_manual('a', '2026-03-12', -990), _manual('z', '2026-03-10', -990)], [_bank('b', '2026-03-10', -990)], _all, w);
      expect(p.matchedTo, {'z': 'b'});
      expect(p.added, 1);
    });

    test('same date entries: the smallest id goes first', () {
      final w = {'a': _h(100), 'z': _h(101), 'b': _h(1000)};
      final p =
          planMatches([_manual('z', '2026-03-10', -990), _manual('a', '2026-03-10', -990)], [_bank('b', '2026-03-10', -990)], _all, w);
      expect(p.matchedTo, {'a': 'b'});
    });

    test('equally far bank rows: the earlier date wins, then the smaller id, whatever the list order', () {
      final m = [_manual('m', '2026-03-10', -990)];
      final w = {'m': _h(100), 'z': _h(1000), 'a': _h(1001), 'b1': _h(1002), 'b2': _h(1003)};
      for (final bank in [
        [_bank('z', '2026-03-08', -990), _bank('a', '2026-03-12', -990)],
        [_bank('a', '2026-03-12', -990), _bank('z', '2026-03-08', -990)],
      ]) {
        expect(planMatches(m, bank, _all, w).matchedTo, {'m': 'z'});
      }
      for (final bank in [
        [_bank('b1', '2026-03-11', -990), _bank('b2', '2026-03-11', -990)],
        [_bank('b2', '2026-03-11', -990), _bank('b1', '2026-03-11', -990)],
      ]) {
        expect(planMatches(m, bank, _all, w).matchedTo, {'m': 'b1'});
      }
      // closer beats earlier
      expect(planMatches(m, [_bank('z', '2026-03-08', -990), _bank('a', '2026-03-11', -990)], _all, w).matchedTo, {'m': 'a'});
    });

    test('encode keeps the highest clock per node, sorted', () {
      final v = SeenBank.encode([_h(100, 'b'), _h(300, 'a'), _h(200, 'a'), _h(150, 'b')]);
      expect(v, '["${_h(150, 'b')}","${_h(300, 'a')}"]');
      expect(SeenBank.encode([_h(100, 'a'), _h(100, 'a', 1)]), '["${_h(100, 'a', 1)}"]');
    });
  });
}
